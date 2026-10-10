//! WASAPI output: the modern Windows audio path.
//!
//! Runs in shared mode so the player coexists with everything else on the
//! machine, and event-driven so the audio thread sleeps until the device needs
//! another period rather than polling. The device's own mix format is adopted
//! verbatim — in shared mode that format is guaranteed to be accepted, and it
//! means Windows does no hidden resampling of its own; the engine's resampler
//! handles the conversion instead, where we can control its quality.
//!
//! Zig has no COM support, so the handful of interfaces needed here are
//! declared by hand: an `extern struct` holding a vtable pointer, with the
//! methods in exactly the order the interface defines them (IUnknown's three
//! always first).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const build_options = @import("build_options");

const backend = @import("backend.zig");
const fmt_mod = @import("format.zig");

pub const available = builtin.os.tag == .windows and build_options.enable_wasapi;

// ---------------------------------------------------------------------------
// Win32 / COM declarations
// ---------------------------------------------------------------------------

const HRESULT = i32;
const HANDLE = *anyopaque;
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

const CLSID_MMDeviceEnumerator: GUID = .{
    .Data1 = 0xBCDE0395,
    .Data2 = 0xE52F,
    .Data3 = 0x467C,
    .Data4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E },
};
const IID_IMMDeviceEnumerator: GUID = .{
    .Data1 = 0xA95664D2,
    .Data2 = 0x9614,
    .Data3 = 0x4F35,
    .Data4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 },
};
const IID_IAudioClient: GUID = .{
    .Data1 = 0x1CB9AD4C,
    .Data2 = 0xDBFA,
    .Data3 = 0x4C32,
    .Data4 = .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 },
};
const IID_IAudioRenderClient: GUID = .{
    .Data1 = 0xF294ACFC,
    .Data2 = 0x3146,
    .Data3 = 0x4483,
    .Data4 = .{ 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2 },
};
const KSDATAFORMAT_SUBTYPE_PCM: GUID = .{
    .Data1 = 0x00000001,
    .Data2 = 0x0000,
    .Data3 = 0x0010,
    .Data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
};
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: GUID = .{
    .Data1 = 0x00000003,
    .Data2 = 0x0000,
    .Data3 = 0x0010,
    .Data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
};

const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
const PKEY_Device_FriendlyName: PROPERTYKEY = .{
    .fmtid = .{
        .Data1 = 0xA45C254E,
        .Data2 = 0xDF1C,
        .Data3 = 0x4EFD,
        .Data4 = .{ 0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0 },
    },
    .pid = 14,
};

/// Only the `pwszVal` arm is ever read here; the union is padded to the real
/// 16-byte payload so the struct size matches the ABI.
const PROPVARIANT = extern struct {
    vt: u16,
    wReserved1: u16,
    wReserved2: u16,
    wReserved3: u16,
    data: extern union {
        pwszVal: ?[*:0]u16,
        pad: [16]u8,
    },
};
const VT_LPWSTR: u16 = 31;

/// `mmreg.h` declares this under `#pragma pack(1)`, so it is exactly 18 bytes
/// with no trailing padding. That matters: `WAVEFORMATEXTENSIBLE` places its
/// extension fields immediately after, which is why its documented `cbSize` is
/// 22 and its total size 40. Letting Zig pad this to 20 would shift every
/// extension field and silently misread the subformat GUID.
const WAVEFORMATEX = extern struct {
    wFormatTag: u16 align(1),
    nChannels: u16 align(1),
    nSamplesPerSec: u32 align(1),
    nAvgBytesPerSec: u32 align(1),
    nBlockAlign: u16 align(1),
    wBitsPerSample: u16 align(1),
    cbSize: u16 align(1),
};

const WAVEFORMATEXTENSIBLE = extern struct {
    Format: WAVEFORMATEX,
    wValidBitsPerSample: u16,
    dwChannelMask: u32,
    SubFormat: GUID,
};

const WAVE_FORMAT_PCM: u16 = 1;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

const AUDCLNT_SHAREMODE_SHARED: u32 = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x00040000;
const AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED: HRESULT = @bitCast(@as(u32, 0x88890019));
const AUDCLNT_E_DEVICE_IN_USE: HRESULT = @bitCast(@as(u32, 0x8889000A));

const eRender: u32 = 0;
const eConsole: u32 = 0;
const DEVICE_STATE_ACTIVE: u32 = 0x1;
const CLSCTX_ALL: u32 = 23;
const STGM_READ: u32 = 0;

const COINIT_MULTITHREADED: u32 = 0;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
const S_FALSE: HRESULT = 1;

const WAIT_OBJECT_0: u32 = 0;
const INFINITE: u32 = 0xFFFFFFFF;
const THREAD_PRIORITY_TIME_CRITICAL: i32 = 15;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.winapi) HRESULT;

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

// --- COM interfaces --------------------------------------------------------

const IMMDeviceEnumerator = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IMMDeviceEnumerator, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        EnumAudioEndpoints: *const fn (*IMMDeviceEnumerator, u32, u32, *?*IMMDeviceCollection) callconv(.winapi) HRESULT,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, u32, u32, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: *const fn (*IMMDeviceEnumerator, [*:0]const u16, *?*IMMDevice) callconv(.winapi) HRESULT,
        RegisterEndpointNotificationCallback: *const anyopaque,
        UnregisterEndpointNotificationCallback: *const anyopaque,
    };

    fn release(self: *IMMDeviceEnumerator) void {
        _ = self.v.Release(self);
    }
};

const IMMDeviceCollection = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IMMDeviceCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMDeviceCollection) callconv(.winapi) u32,
        Release: *const fn (*IMMDeviceCollection) callconv(.winapi) u32,
        GetCount: *const fn (*IMMDeviceCollection, *u32) callconv(.winapi) HRESULT,
        Item: *const fn (*IMMDeviceCollection, u32, *?*IMMDevice) callconv(.winapi) HRESULT,
    };

    fn release(self: *IMMDeviceCollection) void {
        _ = self.v.Release(self);
    }
};

const IMMDevice = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IMMDevice, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMDevice) callconv(.winapi) u32,
        Release: *const fn (*IMMDevice) callconv(.winapi) u32,
        Activate: *const fn (*IMMDevice, *const GUID, u32, ?*PROPVARIANT, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: *const fn (*IMMDevice, u32, *?*IPropertyStore) callconv(.winapi) HRESULT,
        GetId: *const fn (*IMMDevice, *?[*:0]u16) callconv(.winapi) HRESULT,
        GetState: *const fn (*IMMDevice, *u32) callconv(.winapi) HRESULT,
    };

    fn release(self: *IMMDevice) void {
        _ = self.v.Release(self);
    }
};

const IPropertyStore = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IPropertyStore, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IPropertyStore) callconv(.winapi) u32,
        Release: *const fn (*IPropertyStore) callconv(.winapi) u32,
        GetCount: *const fn (*IPropertyStore, *u32) callconv(.winapi) HRESULT,
        GetAt: *const fn (*IPropertyStore, u32, *PROPERTYKEY) callconv(.winapi) HRESULT,
        GetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *PROPVARIANT) callconv(.winapi) HRESULT,
        SetValue: *const anyopaque,
        Commit: *const anyopaque,
    };

    fn release(self: *IPropertyStore) void {
        _ = self.v.Release(self);
    }
};

const IAudioClient = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IAudioClient) callconv(.winapi) u32,
        Release: *const fn (*IAudioClient) callconv(.winapi) u32,
        Initialize: *const fn (*IAudioClient, u32, u32, i64, i64, *const WAVEFORMATEX, ?*const GUID) callconv(.winapi) HRESULT,
        GetBufferSize: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        GetStreamLatency: *const fn (*IAudioClient, *i64) callconv(.winapi) HRESULT,
        GetCurrentPadding: *const fn (*IAudioClient, *u32) callconv(.winapi) HRESULT,
        IsFormatSupported: *const fn (*IAudioClient, u32, *const WAVEFORMATEX, *?*WAVEFORMATEX) callconv(.winapi) HRESULT,
        GetMixFormat: *const fn (*IAudioClient, *?*WAVEFORMATEX) callconv(.winapi) HRESULT,
        GetDevicePeriod: *const fn (*IAudioClient, *i64, *i64) callconv(.winapi) HRESULT,
        Start: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        Reset: *const fn (*IAudioClient) callconv(.winapi) HRESULT,
        SetEventHandle: *const fn (*IAudioClient, HANDLE) callconv(.winapi) HRESULT,
        GetService: *const fn (*IAudioClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    fn release(self: *IAudioClient) void {
        _ = self.v.Release(self);
    }
};

const IAudioRenderClient = extern struct {
    v: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IAudioRenderClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        Release: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        GetBuffer: *const fn (*IAudioRenderClient, u32, *?[*]u8) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioRenderClient, u32, u32) callconv(.winapi) HRESULT,
    };

    fn release(self: *IAudioRenderClient) void {
        _ = self.v.Release(self);
    }
};

// ---------------------------------------------------------------------------
// COM apartment handling
// ---------------------------------------------------------------------------

/// Initialize COM for the calling thread, remembering whether we were the one
/// who did it so `CoUninitialize` is only called when it is ours to call.
const Apartment = struct {
    owned: bool,

    fn enter() Apartment {
        const hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        // S_FALSE means the thread was already initialized; RPC_E_CHANGED_MODE
        // means someone else picked an apartment type. Either way we can use
        // COM, but we must not tear it down.
        return .{ .owned = hr >= 0 and hr != S_FALSE };
    }

    fn leave(self: Apartment) void {
        if (self.owned) CoUninitialize();
    }
};

// ---------------------------------------------------------------------------
// The backend
// ---------------------------------------------------------------------------

/// Which word size the device wants in its shared buffer.
const OutputWord = union(enum) {
    /// Floats, which is what the Windows mixer uses natively — a plain copy.
    float32,
    /// Integer PCM of the given width; converted on the way out.
    integer: fmt_mod.SampleFormat,
};

pub const Wasapi = struct {
    gpa: Allocator,
    render_fn: backend.RenderFn,
    userdata: ?*anyopaque,

    apartment: Apartment,
    client: *IAudioClient,
    render_client: *IAudioRenderClient,
    event: HANDLE,

    fmt: backend.Format,
    word: OutputWord,
    buffer_frames: u32,
    /// Interleaved float scratch the render callback writes into.
    scratch: []f32,

    thread: ?std.Thread = null,
    running: Atomic(bool) = .init(false),
    frames_written: Atomic(u64) = .init(0),
    /// Set if the device disappears mid-stream.
    device_lost: Atomic(bool) = .init(false),

    describe_buf: [256]u8 = undefined,
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
        return self(ptr).buffer_frames;
    }
    fn vDescribe(ptr: *anyopaque) []const u8 {
        const s = self(ptr);
        return s.describe_buf[0..s.describe_len];
    }
    fn vKind(_: *anyopaque) backend.Kind {
        return .wasapi;
    }
    fn vFramesWritten(ptr: *anyopaque) u64 {
        return self(ptr).frames_written.load(.monotonic);
    }

    inline fn self(ptr: *anyopaque) *Wasapi {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn deviceLost(s: *const Wasapi) bool {
        return s.device_lost.load(.acquire);
    }

    fn startImpl(s: *Wasapi) backend.Error!void {
        if (s.thread != null) return;

        // Pre-roll one buffer of silence so the device never starts on
        // whatever happened to be in the shared buffer.
        s.fillOnce(s.buffer_frames, true);

        if (failed(s.client.v.Start(s.client))) return error.DeviceFailure;
        s.running.store(true, .release);
        s.thread = std.Thread.spawn(.{}, loop, .{s}) catch {
            s.running.store(false, .release);
            _ = s.client.v.Stop(s.client);
            return error.DeviceFailure;
        };
    }

    fn stopImpl(s: *Wasapi) void {
        if (s.thread == null) return;
        s.running.store(false, .release);
        // Wake the audio thread so it notices and exits promptly.
        _ = SetEvent(s.event);
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
        _ = s.client.v.Stop(s.client);
        _ = s.client.v.Reset(s.client);
    }

    fn deinitImpl(s: *Wasapi) void {
        s.stopImpl();
        s.render_client.release();
        s.client.release();
        _ = CloseHandle(s.event);
        const gpa = s.gpa;
        const apartment = s.apartment;
        gpa.free(s.scratch);
        gpa.destroy(s);
        apartment.leave();
    }

    /// Pull one buffer's worth of audio and hand it to the device.
    fn fillOnce(s: *Wasapi, frames: u32, silence: bool) void {
        if (frames == 0) return;
        var ptr: ?[*]u8 = null;
        if (failed(s.render_client.v.GetBuffer(s.render_client, frames, &ptr))) return;
        const dest = ptr orelse {
            _ = s.render_client.v.ReleaseBuffer(s.render_client, 0, 0);
            return;
        };

        const channels = s.fmt.channels;
        const samples = @as(usize, frames) * channels;

        if (silence) {
            @memset(s.scratch[0..samples], 0);
        } else {
            s.render_fn(s.userdata, s.scratch[0..samples], channels);
        }

        switch (s.word) {
            .float32 => {
                const bytes = std.mem.sliceAsBytes(s.scratch[0..samples]);
                @memcpy(dest[0..bytes.len], bytes);
            },
            .integer => |sf| {
                const need = samples * sf.bytesPerSample();
                _ = fmt_mod.encodeFromFloat(sf, s.scratch[0..samples], dest[0..need]);
            },
        }

        _ = s.render_client.v.ReleaseBuffer(s.render_client, frames, 0);
        _ = s.frames_written.fetchAdd(frames, .monotonic);
    }

    fn loop(s: *Wasapi) void {
        // COM must be initialized per thread, even just to call methods.
        const apartment = Apartment.enter();
        defer apartment.leave();

        // Audio deadlines are hard: a late buffer is an audible click. Ask the
        // scheduler to treat this thread accordingly.
        _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

        while (s.running.load(.acquire)) {
            // A 2 second timeout rather than INFINITE so a wedged device
            // cannot hang shutdown forever.
            const wait = WaitForSingleObject(s.event, 2000);
            if (!s.running.load(.acquire)) break;
            if (wait != WAIT_OBJECT_0) continue;

            var padding: u32 = 0;
            if (failed(s.client.v.GetCurrentPadding(s.client, &padding))) {
                s.device_lost.store(true, .release);
                break;
            }
            if (padding > s.buffer_frames) continue;
            const avail = s.buffer_frames - padding;
            if (avail == 0) continue;

            s.fillOnce(avail, false);
        }
    }
};

/// Decide how to write into the device's buffer, given its mix format.
fn classifyFormat(wfx: *const WAVEFORMATEX) ?struct { word: OutputWord, channels: u8, rate: u32 } {
    var tag = wfx.wFormatTag;
    var bits = wfx.wBitsPerSample;

    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        if (wfx.cbSize < 22) return null;
        const ext: *const WAVEFORMATEXTENSIBLE = @ptrCast(@alignCast(wfx));
        if (std.mem.eql(u8, std.mem.asBytes(&ext.SubFormat), std.mem.asBytes(&KSDATAFORMAT_SUBTYPE_IEEE_FLOAT))) {
            tag = WAVE_FORMAT_IEEE_FLOAT;
        } else if (std.mem.eql(u8, std.mem.asBytes(&ext.SubFormat), std.mem.asBytes(&KSDATAFORMAT_SUBTYPE_PCM))) {
            tag = WAVE_FORMAT_PCM;
        } else {
            return null;
        }
        // The container width is what the buffer uses, even when fewer bits
        // are valid.
        bits = wfx.wBitsPerSample;
    }

    const word: OutputWord = switch (tag) {
        WAVE_FORMAT_IEEE_FLOAT => if (bits == 32) .float32 else return null,
        WAVE_FORMAT_PCM => switch (bits) {
            8 => .{ .integer = .u8_pcm },
            16 => .{ .integer = .i16_pcm },
            24 => .{ .integer = .i24_pcm },
            32 => .{ .integer = .i32_pcm },
            else => return null,
        },
        else => return null,
    };

    if (wfx.nChannels == 0 or wfx.nChannels > 8) return null;
    if (wfx.nSamplesPerSec == 0) return null;

    return .{
        .word = word,
        .channels = @intCast(wfx.nChannels),
        .rate = wfx.nSamplesPerSec,
    };
}

pub fn open(
    gpa: Allocator,
    options: backend.Options,
    render: backend.RenderFn,
    userdata: ?*anyopaque,
) backend.Error!backend.Backend {
    if (!available) return error.NoDevice;

    const apartment = Apartment.enter();
    errdefer apartment.leave();

    var enum_ptr: ?*anyopaque = null;
    if (failed(CoCreateInstance(
        &CLSID_MMDeviceEnumerator,
        null,
        CLSCTX_ALL,
        &IID_IMMDeviceEnumerator,
        &enum_ptr,
    ))) return error.NoDevice;
    const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return error.NoDevice));
    defer enumerator.release();

    // Pick the device.
    var device_opt: ?*IMMDevice = null;
    if (options.device_id) |id| {
        var wide_buf: [512]u16 = undefined;
        // Check the length first: utf8ToUtf16Le panics on a short buffer
        // rather than returning an error. One UTF-16 unit per UTF-8 byte is a
        // safe upper bound, since multi-byte sequences only ever shrink.
        if (id.len + 1 > wide_buf.len) return error.NoDevice;
        const n = std.unicode.utf8ToUtf16Le(wide_buf[0 .. wide_buf.len - 1], id) catch
            return error.NoDevice;
        wide_buf[n] = 0;
        const wide: [*:0]const u16 = @ptrCast(&wide_buf);
        if (failed(enumerator.v.GetDevice(enumerator, wide, &device_opt))) {
            return error.NoDevice;
        }
    } else {
        if (failed(enumerator.v.GetDefaultAudioEndpoint(
            enumerator,
            eRender,
            eConsole,
            &device_opt,
        ))) return error.NoDevice;
    }
    const device = device_opt orelse return error.NoDevice;
    defer device.release();

    // Activate the audio client.
    var client_ptr: ?*anyopaque = null;
    if (failed(device.v.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr))) {
        return error.DeviceFailure;
    }
    const client: *IAudioClient = @ptrCast(@alignCast(client_ptr orelse return error.DeviceFailure));
    errdefer client.release();

    // Adopt the device's mix format.
    var mix_opt: ?*WAVEFORMATEX = null;
    if (failed(client.v.GetMixFormat(client, &mix_opt))) return error.DeviceFailure;
    const mix = mix_opt orelse return error.DeviceFailure;
    defer CoTaskMemFree(mix);

    const classified = classifyFormat(mix) orelse return error.UnsupportedFormat;

    // Buffer duration is in 100 ns units. Never go below the device's own
    // period or Initialize fails.
    var default_period: i64 = 0;
    var min_period: i64 = 0;
    _ = client.v.GetDevicePeriod(client, &default_period, &min_period);
    const requested: i64 = @as(i64, @intCast(@max(options.latency_ms, 1))) * 10_000;
    const duration = @max(requested, default_period);

    var hr = client.v.Initialize(
        client,
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        duration,
        0,
        mix,
        null,
    );
    if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
        // Retry with the device's preferred duration, which is always legal.
        hr = client.v.Initialize(
            client,
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            default_period,
            0,
            mix,
            null,
        );
    }
    if (failed(hr)) {
        return if (hr == AUDCLNT_E_DEVICE_IN_USE) error.NoDevice else error.DeviceFailure;
    }

    var buffer_frames: u32 = 0;
    if (failed(client.v.GetBufferSize(client, &buffer_frames)) or buffer_frames == 0) {
        return error.DeviceFailure;
    }

    const event = CreateEventW(null, 0, 0, null) orelse return error.DeviceFailure;
    errdefer _ = CloseHandle(event);
    if (failed(client.v.SetEventHandle(client, event))) return error.DeviceFailure;

    var rc_ptr: ?*anyopaque = null;
    if (failed(client.v.GetService(client, &IID_IAudioRenderClient, &rc_ptr))) {
        return error.DeviceFailure;
    }
    const render_client: *IAudioRenderClient = @ptrCast(@alignCast(rc_ptr orelse return error.DeviceFailure));
    errdefer render_client.release();

    const s = gpa.create(Wasapi) catch return error.OutOfMemory;
    errdefer gpa.destroy(s);

    const scratch = gpa.alloc(f32, @as(usize, buffer_frames) * classified.channels) catch
        return error.OutOfMemory;
    errdefer gpa.free(scratch);
    @memset(scratch, 0);

    s.* = .{
        .gpa = gpa,
        .render_fn = render,
        .userdata = userdata,
        .apartment = apartment,
        .client = client,
        .render_client = render_client,
        .event = event,
        .fmt = .{ .sample_rate = classified.rate, .channels = classified.channels },
        .word = classified.word,
        .buffer_frames = buffer_frames,
        .scratch = scratch,
    };

    // Describe the device for the UI.
    var name_buf: [160]u8 = undefined;
    const name = friendlyName(device, &name_buf) orelse "default output";
    const word_label = switch (classified.word) {
        .float32 => "f32",
        .integer => |sf| sf.label(),
    };
    const latency_ms = (@as(u64, buffer_frames) * 1000) / classified.rate;
    const text = std.fmt.bufPrint(&s.describe_buf, "WASAPI {s} — {d} Hz {d}ch {s}, {d} frames ({d} ms)", .{
        name, classified.rate, classified.channels, word_label, buffer_frames, latency_ms,
    }) catch "WASAPI shared mode";
    s.describe_len = text.len;

    return .{ .ptr = s, .vtable = &Wasapi.vtable };
}

/// Read a device's friendly name into `buf` as UTF-8.
fn friendlyName(device: *IMMDevice, buf: []u8) ?[]const u8 {
    var store_opt: ?*IPropertyStore = null;
    if (failed(device.v.OpenPropertyStore(device, STGM_READ, &store_opt))) return null;
    const store = store_opt orelse return null;
    defer store.release();

    var prop: PROPVARIANT = std.mem.zeroes(PROPVARIANT);
    if (failed(store.v.GetValue(store, &PKEY_Device_FriendlyName, &prop))) return null;
    defer _ = PropVariantClear(&prop);

    if (prop.vt != VT_LPWSTR) return null;
    const wide = prop.data.pwszVal orelse return null;
    const len = std.mem.len(wide);
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return null;
    return buf[0..n];
}

/// Append every active render device to `out`. Strings are allocated in
/// `arena`, which the caller owns.
pub fn appendDevices(
    gpa: Allocator,
    arena: Allocator,
    out: *std.ArrayList(backend.Device),
) !void {
    if (!available) return;

    const apartment = Apartment.enter();
    defer apartment.leave();

    var enum_ptr: ?*anyopaque = null;
    if (failed(CoCreateInstance(
        &CLSID_MMDeviceEnumerator,
        null,
        CLSCTX_ALL,
        &IID_IMMDeviceEnumerator,
        &enum_ptr,
    ))) return;
    const enumerator: *IMMDeviceEnumerator = @ptrCast(@alignCast(enum_ptr orelse return));
    defer enumerator.release();

    // Remember the default so it can be marked in the list.
    var default_id_buf: [512]u8 = undefined;
    var default_id: ?[]const u8 = null;
    var default_opt: ?*IMMDevice = null;
    if (!failed(enumerator.v.GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &default_opt))) {
        if (default_opt) |d| {
            defer d.release();
            default_id = deviceId(d, &default_id_buf);
        }
    }

    var collection_opt: ?*IMMDeviceCollection = null;
    if (failed(enumerator.v.EnumAudioEndpoints(
        enumerator,
        eRender,
        DEVICE_STATE_ACTIVE,
        &collection_opt,
    ))) return;
    const collection = collection_opt orelse return;
    defer collection.release();

    var count: u32 = 0;
    if (failed(collection.v.GetCount(collection, &count))) return;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var device_opt: ?*IMMDevice = null;
        if (failed(collection.v.Item(collection, i, &device_opt))) continue;
        const device = device_opt orelse continue;
        defer device.release();

        var id_buf: [512]u8 = undefined;
        const id = deviceId(device, &id_buf) orelse continue;
        var name_buf: [256]u8 = undefined;
        const name = friendlyName(device, &name_buf) orelse "Unknown device";

        // Query the mix format so the listing can show the device's rate.
        var rate: u32 = 0;
        var channels: u8 = 0;
        var client_ptr: ?*anyopaque = null;
        if (!failed(device.v.Activate(device, &IID_IAudioClient, CLSCTX_ALL, null, &client_ptr))) {
            if (client_ptr) |cp| {
                const client: *IAudioClient = @ptrCast(@alignCast(cp));
                defer client.release();
                var mix_opt: ?*WAVEFORMATEX = null;
                if (!failed(client.v.GetMixFormat(client, &mix_opt))) {
                    if (mix_opt) |mix| {
                        defer CoTaskMemFree(mix);
                        rate = mix.nSamplesPerSec;
                        channels = @intCast(@min(mix.nChannels, 8));
                    }
                }
            }
        }

        const is_default = if (default_id) |d| std.mem.eql(u8, d, id) else false;
        try out.append(gpa, .{
            .id = try arena.dupe(u8, id),
            .name = try arena.dupe(u8, name),
            .kind = .wasapi,
            .is_default = is_default,
            .channels = channels,
            .sample_rate = rate,
        });
    }
}

fn deviceId(device: *IMMDevice, buf: []u8) ?[]const u8 {
    var wide_opt: ?[*:0]u16 = null;
    if (failed(device.v.GetId(device, &wide_opt))) return null;
    const wide = wide_opt orelse return null;
    defer CoTaskMemFree(@ptrCast(wide));
    const len = std.mem.len(wide);
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return null;
    return buf[0..n];
}

const testing = std.testing;

test "format classification covers the shapes Windows reports" {
    // Plain 32-bit float stereo, which is the usual shared-mode mix format.
    const f32_stereo: WAVEFORMATEX = .{
        .wFormatTag = WAVE_FORMAT_IEEE_FLOAT,
        .nChannels = 2,
        .nSamplesPerSec = 48_000,
        .nAvgBytesPerSec = 48_000 * 8,
        .nBlockAlign = 8,
        .wBitsPerSample = 32,
        .cbSize = 0,
    };
    const a = classifyFormat(&f32_stereo).?;
    try testing.expectEqual(OutputWord.float32, a.word);
    try testing.expectEqual(@as(u8, 2), a.channels);
    try testing.expectEqual(@as(u32, 48_000), a.rate);

    // 16-bit integer PCM.
    var s16 = f32_stereo;
    s16.wFormatTag = WAVE_FORMAT_PCM;
    s16.wBitsPerSample = 16;
    const b = classifyFormat(&s16).?;
    try testing.expectEqual(fmt_mod.SampleFormat.i16_pcm, b.word.integer);

    // Extensible wrapping float.
    const ext: WAVEFORMATEXTENSIBLE = .{
        .Format = .{
            .wFormatTag = WAVE_FORMAT_EXTENSIBLE,
            .nChannels = 6,
            .nSamplesPerSec = 44_100,
            .nAvgBytesPerSec = 44_100 * 24,
            .nBlockAlign = 24,
            .wBitsPerSample = 32,
            .cbSize = 22,
        },
        .wValidBitsPerSample = 32,
        .dwChannelMask = 0x3F,
        .SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    };
    const c = classifyFormat(&ext.Format).?;
    try testing.expectEqual(OutputWord.float32, c.word);
    try testing.expectEqual(@as(u8, 6), c.channels);

    // Extensible wrapping 24-bit PCM.
    var ext_pcm = ext;
    ext_pcm.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
    ext_pcm.Format.wBitsPerSample = 24;
    const d = classifyFormat(&ext_pcm.Format).?;
    try testing.expectEqual(fmt_mod.SampleFormat.i24_pcm, d.word.integer);
}

test "nonsense formats are rejected rather than guessed at" {
    var bad: WAVEFORMATEX = .{
        .wFormatTag = WAVE_FORMAT_PCM,
        .nChannels = 2,
        .nSamplesPerSec = 48_000,
        .nAvgBytesPerSec = 0,
        .nBlockAlign = 0,
        .wBitsPerSample = 20, // not a container width we handle
        .cbSize = 0,
    };
    try testing.expect(classifyFormat(&bad) == null);

    bad.wBitsPerSample = 16;
    bad.nChannels = 0;
    try testing.expect(classifyFormat(&bad) == null);

    bad.nChannels = 2;
    bad.nSamplesPerSec = 0;
    try testing.expect(classifyFormat(&bad) == null);

    // An unknown format tag.
    bad.nSamplesPerSec = 48_000;
    bad.wFormatTag = 0x1234;
    try testing.expect(classifyFormat(&bad) == null);
}

test "COM struct layouts match the Win32 ABI" {
    // These sizes are what the C headers produce on x86-64; getting them wrong
    // corrupts memory in ways that are very hard to debug, so pin them.
    // The pair of WAVEFORMAT sizes is the load-bearing one: Microsoft
    // documents `cbSize = 22` for the extensible form, which is exactly
    // 40 - 18 and only holds if WAVEFORMATEX carries no trailing padding.
    try testing.expectEqual(@as(usize, 18), @sizeOf(WAVEFORMATEX));
    try testing.expectEqual(@as(usize, 40), @sizeOf(WAVEFORMATEXTENSIBLE));
    try testing.expectEqual(
        @as(usize, 22),
        @sizeOf(WAVEFORMATEXTENSIBLE) - @sizeOf(WAVEFORMATEX),
    );
    try testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try testing.expectEqual(@as(usize, 24), @sizeOf(PROPVARIANT));
    try testing.expectEqual(@as(usize, 20), @sizeOf(PROPERTYKEY));
    // The payload pointer sits right after the four 16-bit header fields.
    try testing.expectEqual(@as(usize, 8), @offsetOf(PROPVARIANT, "data"));
    try testing.expectEqual(@as(usize, 18), @offsetOf(WAVEFORMATEXTENSIBLE, "wValidBitsPerSample"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(WAVEFORMATEXTENSIBLE, "SubFormat"));
}

test "subformat GUIDs match the documented values" {
    // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT is 00000003-0000-0010-8000-00AA00389B71.
    try testing.expectEqual(@as(u32, 3), KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.Data1);
    try testing.expectEqual(@as(u32, 1), KSDATAFORMAT_SUBTYPE_PCM.Data1);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
        &KSDATAFORMAT_SUBTYPE_PCM.Data4,
    );
}
