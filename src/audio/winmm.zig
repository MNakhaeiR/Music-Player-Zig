//! waveOut output: the older Windows multimedia API, kept as a fallback.
//!
//! WASAPI is the better path — lower latency, no hidden resampling — but
//! waveOut still works everywhere, including inside remote desktop sessions
//! and on virtualized audio stacks where opening a WASAPI endpoint sometimes
//! fails. It takes 16-bit integer PCM and does its own rate conversion, so the
//! player can simply ask for the source's rate and let the driver cope.
//!
//! The driver signals an event each time one of several queued buffers has
//! been consumed; the audio thread refills whichever buffers are marked done
//! and requeues them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const build_options = @import("build_options");

const backend = @import("backend.zig");
const fmt_mod = @import("format.zig");

pub const available = builtin.os.tag == .windows and build_options.enable_winmm;

const HANDLE = *anyopaque;
const MMRESULT = u32;
const MMSYSERR_NOERROR: MMRESULT = 0;

/// Byte-packed, exactly as `mmreg.h` declares it — see the note in wasapi.zig.
const WAVEFORMATEX = extern struct {
    wFormatTag: u16 align(1),
    nChannels: u16 align(1),
    nSamplesPerSec: u32 align(1),
    nAvgBytesPerSec: u32 align(1),
    nBlockAlign: u16 align(1),
    wBitsPerSample: u16 align(1),
    cbSize: u16 align(1),
};

const WAVEHDR = extern struct {
    lpData: [*]u8,
    dwBufferLength: u32,
    dwBytesRecorded: u32,
    dwUser: usize,
    dwFlags: u32,
    dwLoops: u32,
    lpNext: ?*WAVEHDR,
    reserved: usize,
};

const WAVEOUTCAPSW = extern struct {
    wMid: u16,
    wPid: u16,
    vDriverVersion: u32,
    szPname: [32]u16,
    dwFormats: u32,
    wChannels: u16,
    wReserved1: u16,
    dwSupport: u32,
};

const WAVE_FORMAT_PCM: u16 = 1;
const WAVE_MAPPER: u32 = 0xFFFFFFFF;
const CALLBACK_EVENT: u32 = 0x00050000;
const WHDR_DONE: u32 = 0x00000001;
const WHDR_PREPARED: u32 = 0x00000002;
const WAIT_OBJECT_0: u32 = 0;
const THREAD_PRIORITY_TIME_CRITICAL: i32 = 15;

extern "winmm" fn waveOutOpen(
    phwo: *?HANDLE,
    uDeviceID: u32,
    pwfx: *const WAVEFORMATEX,
    dwCallback: usize,
    dwInstance: usize,
    fdwOpen: u32,
) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutClose(hwo: HANDLE) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutPrepareHeader(hwo: HANDLE, pwh: *WAVEHDR, cbwh: u32) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutUnprepareHeader(hwo: HANDLE, pwh: *WAVEHDR, cbwh: u32) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutWrite(hwo: HANDLE, pwh: *WAVEHDR, cbwh: u32) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutReset(hwo: HANDLE) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutPause(hwo: HANDLE) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutRestart(hwo: HANDLE) callconv(.winapi) MMRESULT;
extern "winmm" fn waveOutGetNumDevs() callconv(.winapi) u32;
extern "winmm" fn waveOutGetDevCapsW(uDeviceID: usize, pwoc: *WAVEOUTCAPSW, cbwoc: u32) callconv(.winapi) MMRESULT;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
extern "kernel32" fn SetThreadPriority(hThread: HANDLE, nPriority: i32) callconv(.winapi) i32;

/// Buffers kept in flight. More buffers means more robustness against a late
/// refill, at the cost of latency.
const buffer_count = 4;

/// waveOut takes integer PCM; 16-bit is universally supported.
const out_format: fmt_mod.SampleFormat = .i16_pcm;

pub const WinMM = struct {
    gpa: Allocator,
    render_fn: backend.RenderFn,
    userdata: ?*anyopaque,

    handle: HANDLE,
    event: HANDLE,

    fmt: backend.Format,
    block_frames: u32,

    headers: [buffer_count]WAVEHDR,
    /// One contiguous allocation carved into `buffer_count` blocks.
    pcm: []u8,
    scratch: []f32,
    prepared: usize = 0,

    thread: ?std.Thread = null,
    running: Atomic(bool) = .init(false),
    frames_written: Atomic(u64) = .init(0),

    describe_buf: [224]u8 = undefined,
    describe_len: usize = 0,

    const vtable: backend.Backend.VTable = .{
        .start = vStart,
        .stop = vStop,
        .deinit = vDeinit,
        .format = vFormat,
        .bufferFrames = vBufferFrames,
        .describe = vDescribe,
        .kind = vKind,
        .framesWritten = vFramesWritten,
    };

    fn vStart(ptr: *anyopaque) backend.Error!void {
        return self(ptr).startImpl();
    }
    fn vStop(ptr: *anyopaque) void {
        self(ptr).stopImpl();
    }
    fn vDeinit(ptr: *anyopaque) void {
        self(ptr).deinitImpl();
    }
    fn vFormat(ptr: *anyopaque) backend.Format {
        return self(ptr).fmt;
    }
    fn vBufferFrames(ptr: *anyopaque) u32 {
        return self(ptr).block_frames * buffer_count;
    }
    fn vDescribe(ptr: *anyopaque) []const u8 {
        const s = self(ptr);
        return s.describe_buf[0..s.describe_len];
    }
    fn vKind(_: *anyopaque) backend.Kind {
        return .winmm;
    }
    fn vFramesWritten(ptr: *anyopaque) u64 {
        return self(ptr).frames_written.load(.monotonic);
    }

    inline fn self(ptr: *anyopaque) *WinMM {
        return @ptrCast(@alignCast(ptr));
    }

    fn blockBytes(s: *const WinMM) usize {
        return @as(usize, s.block_frames) * s.fmt.channels * out_format.bytesPerSample();
    }

    fn startImpl(s: *WinMM) backend.Error!void {
        if (s.thread != null) return;
        s.running.store(true, .release);
        s.thread = std.Thread.spawn(.{}, loop, .{s}) catch {
            s.running.store(false, .release);
            return error.DeviceFailure;
        };
    }

    fn stopImpl(s: *WinMM) void {
        if (s.thread == null) return;
        s.running.store(false, .release);
        _ = SetEvent(s.event);
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
        // Reset marks every queued buffer done so unprepare can succeed.
        _ = waveOutReset(s.handle);
    }

    fn deinitImpl(s: *WinMM) void {
        s.stopImpl();
        for (s.headers[0..s.prepared]) |*h| {
            _ = waveOutUnprepareHeader(s.handle, h, @sizeOf(WAVEHDR));
        }
        _ = waveOutClose(s.handle);
        _ = CloseHandle(s.event);
        const gpa = s.gpa;
        gpa.free(s.pcm);
        gpa.free(s.scratch);
        gpa.destroy(s);
    }

    fn loop(s: *WinMM) void {
        _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

        const samples = @as(usize, s.block_frames) * s.fmt.channels;
        const bytes = s.blockBytes();

        while (s.running.load(.acquire)) {
            var queued_any = false;
            for (&s.headers, 0..) |*h, i| {
                // The driver sets WHDR_DONE when it has finished with a
                // buffer; we also set it by hand at startup so the first pass
                // fills every buffer.
                if (h.dwFlags & WHDR_DONE == 0) continue;

                s.render_fn(s.userdata, s.scratch[0..samples], s.fmt.channels);
                const dest = s.pcm[i * bytes ..][0..bytes];
                _ = fmt_mod.encodeFromFloat(out_format, s.scratch[0..samples], dest);

                h.dwFlags &= ~WHDR_DONE;
                h.dwBufferLength = @intCast(bytes);
                if (waveOutWrite(s.handle, h, @sizeOf(WAVEHDR)) != MMSYSERR_NOERROR) {
                    // Put the flag back so we do not spin on a failing buffer.
                    h.dwFlags |= WHDR_DONE;
                    continue;
                }
                _ = s.frames_written.fetchAdd(s.block_frames, .monotonic);
                queued_any = true;
            }

            if (!queued_any) {
                // Everything is in flight; wait for the driver to free one.
                const wait = WaitForSingleObject(s.event, 200);
                if (!s.running.load(.acquire)) break;
                _ = wait;
            }
        }
    }
};

pub fn open(
    gpa: Allocator,
    options: backend.Options,
    render: backend.RenderFn,
    userdata: ?*anyopaque,
) backend.Error!backend.Backend {
    if (!available) return error.NoDevice;

    const sample_rate = options.sample_rate orelse 48_000;
    const channels = options.channels orelse 2;
    if (sample_rate == 0 or channels == 0 or channels > 2) {
        // waveOut multichannel support is inconsistent; stay with mono/stereo.
        return error.UnsupportedFormat;
    }

    // Split the requested latency across the queued buffers.
    const latency_ms = @max(options.latency_ms, 20);
    const block_frames: u32 = @intCast(@max(
        256,
        (@as(u64, sample_rate) * latency_ms) / (1000 * buffer_count),
    ));

    const device_index: u32 = blk: {
        const id = options.device_id orelse break :blk WAVE_MAPPER;
        break :blk std.fmt.parseInt(u32, id, 10) catch WAVE_MAPPER;
    };

    const wfx: WAVEFORMATEX = .{
        .wFormatTag = WAVE_FORMAT_PCM,
        .nChannels = channels,
        .nSamplesPerSec = sample_rate,
        .nAvgBytesPerSec = sample_rate * channels * out_format.bytesPerSample(),
        .nBlockAlign = @as(u16, channels) * out_format.bytesPerSample(),
        .wBitsPerSample = @as(u16, out_format.bytesPerSample()) * 8,
        .cbSize = 0,
    };

    const event = CreateEventW(null, 0, 0, null) orelse return error.DeviceFailure;
    errdefer _ = CloseHandle(event);

    var handle_opt: ?HANDLE = null;
    if (waveOutOpen(
        &handle_opt,
        device_index,
        &wfx,
        @intFromPtr(event),
        0,
        CALLBACK_EVENT,
    ) != MMSYSERR_NOERROR) {
        return error.NoDevice;
    }
    const handle = handle_opt orelse return error.NoDevice;
    errdefer _ = waveOutClose(handle);

    const s = gpa.create(WinMM) catch return error.OutOfMemory;
    errdefer gpa.destroy(s);

    const samples = @as(usize, block_frames) * channels;
    const bytes_per_block = samples * out_format.bytesPerSample();

    const pcm = gpa.alloc(u8, bytes_per_block * buffer_count) catch
        return error.OutOfMemory;
    errdefer gpa.free(pcm);
    @memset(pcm, 0);

    const scratch = gpa.alloc(f32, samples) catch return error.OutOfMemory;
    errdefer gpa.free(scratch);
    @memset(scratch, 0);

    s.* = .{
        .gpa = gpa,
        .render_fn = render,
        .userdata = userdata,
        .handle = handle,
        .event = event,
        .fmt = .{ .sample_rate = sample_rate, .channels = channels },
        .block_frames = block_frames,
        .headers = undefined,
        .pcm = pcm,
        .scratch = scratch,
    };

    for (&s.headers, 0..) |*h, i| {
        h.* = .{
            .lpData = pcm[i * bytes_per_block ..].ptr,
            .dwBufferLength = @intCast(bytes_per_block),
            .dwBytesRecorded = 0,
            .dwUser = 0,
            .dwFlags = 0,
            .dwLoops = 0,
            .lpNext = null,
            .reserved = 0,
        };
        if (waveOutPrepareHeader(handle, h, @sizeOf(WAVEHDR)) != MMSYSERR_NOERROR) {
            return error.DeviceFailure;
        }
        s.prepared = i + 1;
        // Mark it free so the first pass of the audio loop fills it. The
        // driver uses this same flag to hand buffers back.
        h.dwFlags |= WHDR_DONE;
    }

    var name_buf: [128]u8 = undefined;
    const name = deviceName(device_index, &name_buf) orelse "default output";
    const text = std.fmt.bufPrint(
        &s.describe_buf,
        "WinMM {s} — {d} Hz {d}ch s16, {d}x{d} frames ({d} ms)",
        .{
            name,
            sample_rate,
            channels,
            buffer_count,
            block_frames,
            (@as(u64, block_frames) * buffer_count * 1000) / sample_rate,
        },
    ) catch "WinMM waveOut";
    s.describe_len = text.len;

    return .{ .ptr = s, .vtable = &WinMM.vtable };
}

fn deviceName(index: u32, buf: []u8) ?[]const u8 {
    if (!available) return null;
    var caps: WAVEOUTCAPSW = std.mem.zeroes(WAVEOUTCAPSW);
    const id: usize = if (index == WAVE_MAPPER)
        @bitCast(@as(isize, -1))
    else
        index;
    if (waveOutGetDevCapsW(id, &caps, @sizeOf(WAVEOUTCAPSW)) != MMSYSERR_NOERROR) return null;
    const wide = std.mem.sliceTo(&caps.szPname, 0);
    const n = std.unicode.utf16LeToUtf8(buf, wide) catch return null;
    return buf[0..n];
}

pub fn appendDevices(
    gpa: Allocator,
    arena: Allocator,
    out: *std.ArrayList(backend.Device),
) !void {
    if (!available) return;
    const count = waveOutGetNumDevs();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var caps: WAVEOUTCAPSW = std.mem.zeroes(WAVEOUTCAPSW);
        if (waveOutGetDevCapsW(i, &caps, @sizeOf(WAVEOUTCAPSW)) != MMSYSERR_NOERROR) continue;

        var name_buf: [128]u8 = undefined;
        const wide = std.mem.sliceTo(&caps.szPname, 0);
        const n = std.unicode.utf16LeToUtf8(&name_buf, wide) catch continue;

        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}", .{i}) catch continue;

        try out.append(gpa, .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, name_buf[0..n]),
            .kind = .winmm,
            .is_default = false,
            .channels = @intCast(@min(caps.wChannels, 8)),
            // waveOut caps advertise a bitmask of supported rates rather than
            // a current one; 0 means "unreported".
            .sample_rate = 0,
        });
    }
}

const testing = std.testing;

test "WAVEHDR and WAVEFORMATEX match the Win32 ABI" {
    try testing.expectEqual(@as(usize, 18), @sizeOf(WAVEFORMATEX));

    // On x86-64, DWORD_PTR is 8 bytes, which is what sets the layout:
    // lpData 0, dwBufferLength 8, dwBytesRecorded 12, dwUser 16, dwFlags 24,
    // dwLoops 28, lpNext 32, reserved 40.
    try testing.expectEqual(@as(usize, 48), @sizeOf(WAVEHDR));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WAVEHDR, "lpData"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WAVEHDR, "dwBufferLength"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(WAVEHDR, "dwUser"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(WAVEHDR, "dwFlags"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(WAVEHDR, "lpNext"));

    // wMid 0, wPid 2, vDriverVersion 4, szPname 8..72, dwFormats 72,
    // wChannels 76, wReserved1 78, dwSupport 80.
    try testing.expectEqual(@as(usize, 84), @sizeOf(WAVEOUTCAPSW));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WAVEOUTCAPSW, "szPname"));
    try testing.expectEqual(@as(usize, 72), @offsetOf(WAVEOUTCAPSW, "dwFormats"));
}

test "multichannel requests are declined so we fall through to WASAPI" {
    if (!available) return error.SkipZigTest;
    const Noop = struct {
        fn render(_: ?*anyopaque, out: []f32, _: u8) void {
            @memset(out, 0);
        }
    };
    try testing.expectError(error.UnsupportedFormat, open(
        testing.allocator,
        .{ .channels = 6 },
        Noop.render,
        null,
    ));
}
