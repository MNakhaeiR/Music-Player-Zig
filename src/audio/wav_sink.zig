//! An output that renders to a .wav file as fast as the machine can manage.
//!
//! Useful for three things: checking exactly what the DSP chain does to a
//! file, bouncing a playlist to a single track, and running the whole engine
//! under a test without waiting in real time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Atomic = std.atomic.Value;

const backend = @import("backend.zig");
const fmt_mod = @import("format.zig");

pub const WavSink = struct {
    gpa: Allocator,
    io: Io,
    render: backend.RenderFn,
    userdata: ?*anyopaque,

    fmt: backend.Format,
    block_frames: u32,
    buf: []f32,
    byte_buf: []u8,

    file: File,
    writer: File.Writer,
    write_buf: []u8,
    path: []u8,

    /// How many frames to render in total; 0 means "until stopped".
    limit_frames: u64,
    frames_written: Atomic(u64) = .init(0),

    thread: ?std.Thread = null,
    running: Atomic(bool) = .init(false),
    /// Set when the render thread has produced everything it was asked for.
    complete: Atomic(bool) = .init(false),
    write_failed: Atomic(bool) = .init(false),

    describe_buf: [160]u8 = undefined,
    describe_len: usize = 0,

    /// Output word size. 24-bit keeps headroom for the float chain without
    /// doubling the file size.
    const out_format: fmt_mod.SampleFormat = .i24_pcm;

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
        return self(ptr).block_frames;
    }
    fn vDescribe(ptr: *anyopaque) []const u8 {
        const s = self(ptr);
        return s.describe_buf[0..s.describe_len];
    }
    fn vKind(_: *anyopaque) backend.Kind {
        return .wav_file;
    }
    fn vFramesWritten(ptr: *anyopaque) u64 {
        return self(ptr).frames_written.load(.monotonic);
    }

    inline fn self(ptr: *anyopaque) *WavSink {
        return @ptrCast(@alignCast(ptr));
    }

    /// True once the requested number of frames has been rendered.
    pub fn isComplete(s: *const WavSink) bool {
        return s.complete.load(.acquire);
    }

    fn startImpl(s: *WavSink) backend.Error!void {
        if (s.thread != null) return;
        s.running.store(true, .release);
        s.thread = std.Thread.spawn(.{}, loop, .{s}) catch {
            s.running.store(false, .release);
            return error.DeviceFailure;
        };
    }

    fn stopImpl(s: *WavSink) void {
        s.running.store(false, .release);
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
    }

    fn deinitImpl(s: *WavSink) void {
        s.stopImpl();
        s.finalize();
        const gpa = s.gpa;
        gpa.free(s.buf);
        gpa.free(s.byte_buf);
        gpa.free(s.write_buf);
        gpa.free(s.path);
        gpa.destroy(s);
    }

    fn loop(s: *WavSink) void {
        while (s.running.load(.acquire)) {
            const remaining: u64 = if (s.limit_frames == 0)
                s.block_frames
            else blk: {
                const done = s.frames_written.load(.monotonic);
                if (done >= s.limit_frames) break :blk 0;
                break :blk @min(s.limit_frames - done, s.block_frames);
            };
            if (remaining == 0) {
                s.complete.store(true, .release);
                break;
            }

            const frames: usize = @intCast(remaining);
            const samples = frames * s.fmt.channels;
            s.render(s.userdata, s.buf[0..samples], s.fmt.channels);

            const n = fmt_mod.encodeFromFloat(out_format, s.buf[0..samples], s.byte_buf);
            s.writer.interface.writeAll(s.byte_buf[0..n]) catch {
                s.write_failed.store(true, .release);
                s.complete.store(true, .release);
                break;
            };
            _ = s.frames_written.fetchAdd(frames, .monotonic);
        }
    }

    /// Flush and patch the RIFF sizes, which are only known once the render
    /// has finished.
    fn finalize(s: *WavSink) void {
        s.writer.interface.flush() catch {};

        const frames = s.frames_written.load(.monotonic);
        const bytes_per_frame = @as(u64, out_format.bytesPerSample()) * s.fmt.channels;
        const data_size: u32 = @intCast(@min(frames * bytes_per_frame, std.math.maxInt(u32) - 64));
        const riff_size: u32 = 4 + (8 + 40) + (8 + data_size);

        var le: [4]u8 = undefined;
        std.mem.writeInt(u32, &le, riff_size, .little);
        _ = s.file.writePositionalAll(s.io, &le, 4) catch {};
        std.mem.writeInt(u32, &le, data_size, .little);
        // RIFF(12) + fmt chunk header(8) + fmt body(40) + "data"(4) = 64
        _ = s.file.writePositionalAll(s.io, &le, 64) catch {};

        s.file.close(s.io);
    }
};

pub fn open(
    gpa: Allocator,
    io: Io,
    options: backend.Options,
    render: backend.RenderFn,
    userdata: ?*anyopaque,
) backend.Error!backend.Backend {
    const path = options.output_path orelse return error.NoDevice;
    const sample_rate = options.sample_rate orelse 48_000;
    const channels = options.channels orelse 2;
    if (sample_rate == 0 or channels == 0) return error.UnsupportedFormat;

    // Render in reasonably large blocks; there is no latency to worry about.
    const block_frames: u32 = 8192;

    const s = gpa.create(WavSink) catch return error.OutOfMemory;
    errdefer gpa.destroy(s);

    const buf = gpa.alloc(f32, @as(usize, block_frames) * channels) catch
        return error.OutOfMemory;
    errdefer gpa.free(buf);

    const byte_buf = gpa.alloc(
        u8,
        @as(usize, block_frames) * channels * WavSink.out_format.bytesPerSample(),
    ) catch return error.OutOfMemory;
    errdefer gpa.free(byte_buf);

    const write_buf = gpa.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
    errdefer gpa.free(write_buf);

    const path_copy = gpa.dupe(u8, path) catch return error.OutOfMemory;
    errdefer gpa.free(path_copy);

    const dir: Dir = .cwd();
    const file = dir.createFile(io, path, .{ .truncate = true }) catch
        return error.DeviceFailure;
    errdefer file.close(io);

    s.* = .{
        .gpa = gpa,
        .io = io,
        .render = render,
        .userdata = userdata,
        .fmt = .{ .sample_rate = sample_rate, .channels = channels },
        .block_frames = block_frames,
        .buf = buf,
        .byte_buf = byte_buf,
        .file = file,
        .writer = file.writer(io, write_buf),
        .write_buf = write_buf,
        .path = path_copy,
        .limit_frames = options.render_frames,
    };

    // Write a header with placeholder sizes; `finalize` patches them.
    writeHeader(&s.writer.interface, sample_rate, channels) catch
        return error.DeviceFailure;

    const text = std.fmt.bufPrint(
        &s.describe_buf,
        "wav file {s} ({d} Hz {d}ch {s})",
        .{ path_copy, sample_rate, channels, WavSink.out_format.label() },
    ) catch "wav file";
    s.describe_len = text.len;

    return .{ .ptr = s, .vtable = &WavSink.vtable };
}

/// A 40-byte WAVE_FORMAT_EXTENSIBLE `fmt ` chunk, which is what a 24-bit file
/// is supposed to use.
fn writeHeader(w: *Io.Writer, sample_rate: u32, channels: u8) !void {
    const bits: u16 = @as(u16, WavSink.out_format.bytesPerSample()) * 8;
    const block_align: u16 = @as(u16, WavSink.out_format.bytesPerSample()) * channels;

    try w.writeAll("RIFF");
    try w.writeInt(u32, 0, .little); // patched later
    try w.writeAll("WAVE");

    try w.writeAll("fmt ");
    try w.writeInt(u32, 40, .little);
    try w.writeInt(u16, 0xFFFE, .little); // WAVE_FORMAT_EXTENSIBLE
    try w.writeInt(u16, channels, .little);
    try w.writeInt(u32, sample_rate, .little);
    try w.writeInt(u32, sample_rate * block_align, .little);
    try w.writeInt(u16, block_align, .little);
    try w.writeInt(u16, bits, .little);
    try w.writeInt(u16, 22, .little); // cbSize
    try w.writeInt(u16, bits, .little); // valid bits
    try w.writeInt(u32, switch (channels) {
        1 => 0x4,
        2 => 0x3,
        6 => 0x3F,
        8 => 0x63F,
        else => 0,
    }, .little);
    try w.writeInt(u16, 0x0001, .little); // KSDATAFORMAT_SUBTYPE_PCM
    try w.writeInt(u16, 0, .little);
    try w.writeAll(&[_]u8{
        0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
        0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    });

    try w.writeAll("data");
    try w.writeInt(u32, 0, .little); // patched later
}

const testing = std.testing;

const Sine = struct {
    phase: f64 = 0,
    step: f64,

    fn render(userdata: ?*anyopaque, out: []f32, channels: u8) void {
        const s: *Sine = @ptrCast(@alignCast(userdata.?));
        const frames = out.len / channels;
        for (0..frames) |f| {
            const v: f32 = @floatCast(0.5 * @sin(s.phase));
            s.phase += s.step;
            for (out[f * channels ..][0..channels]) |*o| o.* = v;
        }
    }
};

test "renders a playable wav file" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The sink resolves paths against the current directory, which during a
    // test run is the build root.
    const path = try std.fmt.allocPrint(
        gpa,
        ".zig-cache/tmp/{s}/out.wav",
        .{tmp.sub_path},
    );
    defer gpa.free(path);

    const sr: u32 = 48_000;
    var sine: Sine = .{ .step = 2.0 * std.math.pi * 440.0 / @as(f64, @floatFromInt(sr)) };

    const be = try open(gpa, io, .{
        .sample_rate = sr,
        .channels = 2,
        .output_path = path,
        .render_frames = sr / 2, // half a second
    }, Sine.render, &sine);

    try testing.expectEqual(backend.Kind.wav_file, be.kind());
    try be.start();

    // Offline rendering is fast, but wait for it rather than assuming.
    const sink: *WavSink = @ptrCast(@alignCast(be.ptr));
    var waited: u32 = 0;
    while (!sink.isComplete() and waited < 400) : (waited += 1) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(sink.isComplete());
    try testing.expectEqual(@as(u64, sr / 2), be.framesWritten());

    be.deinit(); // closes and patches the header

    // Read it back with our own WAV decoder.
    const bytes = try Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);

    const wav = @import("../decode/wav.zig");
    var dec = try wav.Wav.open(bytes);
    try testing.expectEqual(@as(u32, sr), dec.stream.sample_rate);
    try testing.expectEqual(@as(u8, 2), dec.stream.channels);
    try testing.expectEqual(@as(u8, 24), dec.bits_per_sample);
    try testing.expectEqual(@as(u64, sr / 2), dec.total_frames);

    const out = try gpa.alloc(f32, @as(usize, sr / 2) * 2);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, sr / 2), try dec.readFrames(out));

    var peak: f32 = 0;
    for (out) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);
}

test "a sink with no path is rejected" {
    var sine: Sine = .{ .step = 0 };
    try testing.expectError(
        error.NoDevice,
        open(testing.allocator, testing.io, .{}, Sine.render, &sine),
    );
}
