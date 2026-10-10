//! The audio output abstraction.
//!
//! A backend owns a thread that pulls audio from a callback and hands it to
//! the operating system. The callback runs on that thread and must be
//! real-time safe: no allocation, no locks, no syscalls, no file I/O. If it
//! ever blocks, the listener hears a dropout.
//!
//! Three concrete backends live alongside this file:
//!   * `wasapi`   — the real Windows output, event-driven and low latency.
//!   * `winmm`    — the older waveOut API, as a fallback.
//!   * `null_sink`— paces itself in real time and discards the audio, which
//!                  makes the whole player testable without hardware.
//!   * `wav_sink` — renders as fast as it can into a .wav file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const build_options = @import("build_options");

pub const Error = error{
    /// No usable output device.
    NoDevice,
    /// The device rejected every format we offered.
    UnsupportedFormat,
    /// The platform API failed for a reason we cannot act on.
    DeviceFailure,
    OutOfMemory,
};

/// Negotiated output format.
pub const Format = struct {
    sample_rate: u32,
    channels: u8,

    pub fn eql(a: Format, b: Format) bool {
        return a.sample_rate == b.sample_rate and a.channels == b.channels;
    }
};

/// Fill `out` with `out.len / channels` interleaved frames of float audio.
///
/// Called on the backend's audio thread. Must always fill the whole buffer:
/// write silence rather than returning short, since whatever is left in the
/// buffer gets played either way.
pub const RenderFn = *const fn (userdata: ?*anyopaque, out: []f32, channels: u8) void;

pub const Kind = enum {
    wasapi,
    winmm,
    null_sink,
    wav_file,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .wasapi => "WASAPI",
            .winmm => "WinMM",
            .null_sink => "null",
            .wav_file => "wav",
        };
    }

    pub fn fromName(name: []const u8) ?Kind {
        if (std.ascii.eqlIgnoreCase(name, "wasapi")) return .wasapi;
        if (std.ascii.eqlIgnoreCase(name, "winmm")) return .winmm;
        if (std.ascii.eqlIgnoreCase(name, "null")) return .null_sink;
        if (std.ascii.eqlIgnoreCase(name, "wav")) return .wav_file;
        return null;
    }
};

/// A device as reported by a backend's enumerator.
pub const Device = struct {
    /// Backend-specific handle. Owned by the `DeviceList`.
    id: []const u8,
    /// Human-readable name. Owned by the `DeviceList`.
    name: []const u8,
    kind: Kind,
    is_default: bool,
    channels: u8,
    sample_rate: u32,
};

pub const DeviceList = struct {
    gpa: Allocator,
    items: []Device,
    /// Backing store for every string the devices point into.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DeviceList) void {
        self.gpa.free(self.items);
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Runtime interface implemented by each backend.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) Error!void,
        stop: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
        format: *const fn (ptr: *anyopaque) Format,
        /// Hardware buffer size, in frames.
        bufferFrames: *const fn (ptr: *anyopaque) u32,
        /// Human-readable description of the active device.
        describe: *const fn (ptr: *anyopaque) []const u8,
        kind: *const fn (ptr: *anyopaque) Kind,
        /// Frames the backend has handed to the device so far. Used to
        /// convert the engine's decode position into a playback position.
        framesWritten: *const fn (ptr: *anyopaque) u64,
    };

    pub fn start(self: Backend) Error!void {
        return self.vtable.start(self.ptr);
    }
    pub fn stop(self: Backend) void {
        self.vtable.stop(self.ptr);
    }
    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn format(self: Backend) Format {
        return self.vtable.format(self.ptr);
    }
    pub fn bufferFrames(self: Backend) u32 {
        return self.vtable.bufferFrames(self.ptr);
    }
    pub fn describe(self: Backend) []const u8 {
        return self.vtable.describe(self.ptr);
    }
    pub fn kind(self: Backend) Kind {
        return self.vtable.kind(self.ptr);
    }
    pub fn framesWritten(self: Backend) u64 {
        return self.vtable.framesWritten(self.ptr);
    }
};

/// What the caller asks for when opening an output.
pub const Options = struct {
    /// Preferred backend, or null to try the best available in order.
    kind: ?Kind = null,
    /// Backend-specific device id from `listDevices`, or null for the default.
    device_id: ?[]const u8 = null,
    /// Preferred rate. A backend may return something else; check `format()`.
    sample_rate: ?u32 = null,
    channels: ?u8 = null,
    /// Target buffer size in milliseconds. Smaller is lower latency but more
    /// vulnerable to dropouts.
    latency_ms: u32 = 40,
    /// For `.wav_file`, where to write.
    output_path: ?[]const u8 = null,
    /// For `.wav_file`, how many frames to render before stopping. 0 renders
    /// until the render callback reports silence forever (caller-driven).
    render_frames: u64 = 0,
};

const wasapi = @import("wasapi.zig");
const winmm = @import("winmm.zig");
const null_sink = @import("null_sink.zig");
const wav_sink = @import("wav_sink.zig");

/// Backends worth trying, in descending order of preference.
pub fn preferenceOrder() []const Kind {
    if (@import("builtin").os.tag == .windows) {
        if (build_options.enable_wasapi and build_options.enable_winmm) {
            return &.{ .wasapi, .winmm, .null_sink };
        } else if (build_options.enable_wasapi) {
            return &.{ .wasapi, .null_sink };
        } else if (build_options.enable_winmm) {
            return &.{ .winmm, .null_sink };
        }
    }
    return &.{.null_sink};
}

/// Open an output. With no `kind` set, each backend in `preferenceOrder` is
/// tried until one works, so a machine with no sound card still plays (into
/// the null sink) rather than refusing to start.
pub fn open(
    gpa: Allocator,
    io: Io,
    options: Options,
    render: RenderFn,
    userdata: ?*anyopaque,
) Error!Backend {
    if (options.kind) |k| return openKind(gpa, io, k, options, render, userdata);

    var last_err: Error = error.NoDevice;
    for (preferenceOrder()) |k| {
        return openKind(gpa, io, k, options, render, userdata) catch |e| {
            last_err = e;
            continue;
        };
    }
    return last_err;
}

fn openKind(
    gpa: Allocator,
    io: Io,
    k: Kind,
    options: Options,
    render: RenderFn,
    userdata: ?*anyopaque,
) Error!Backend {
    return switch (k) {
        .wasapi => if (wasapi.available)
            wasapi.open(gpa, options, render, userdata)
        else
            error.NoDevice,
        .winmm => if (winmm.available)
            winmm.open(gpa, options, render, userdata)
        else
            error.NoDevice,
        .null_sink => null_sink.open(gpa, io, options, render, userdata),
        .wav_file => wav_sink.open(gpa, io, options, render, userdata),
    };
}

/// Enumerate every output device across all compiled-in backends.
pub fn listDevices(gpa: Allocator) Error!DeviceList {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: std.ArrayList(Device) = .empty;
    errdefer items.deinit(gpa);

    if (wasapi.available) {
        wasapi.appendDevices(gpa, a, &items) catch {};
    }
    if (winmm.available) {
        winmm.appendDevices(gpa, a, &items) catch {};
    }
    items.append(gpa, .{
        .id = "null",
        .name = "Null output (discards audio)",
        .kind = .null_sink,
        .is_default = items.items.len == 0,
        .channels = 2,
        .sample_rate = 48_000,
    }) catch {};

    return .{
        .gpa = gpa,
        .items = try items.toOwnedSlice(gpa),
        .arena = arena,
    };
}

const testing = std.testing;

test "kind names round trip" {
    for ([_]Kind{ .wasapi, .winmm, .null_sink, .wav_file }) |k| {
        try testing.expectEqual(k, Kind.fromName(k.label()).?);
    }
    try testing.expect(Kind.fromName("coreaudio") == null);
}

test "format equality" {
    const a: Format = .{ .sample_rate = 48_000, .channels = 2 };
    try testing.expect(a.eql(.{ .sample_rate = 48_000, .channels = 2 }));
    try testing.expect(!a.eql(.{ .sample_rate = 44_100, .channels = 2 }));
    try testing.expect(!a.eql(.{ .sample_rate = 48_000, .channels = 1 }));
}

test "preference order always ends in a backend that cannot fail" {
    const order = preferenceOrder();
    try testing.expect(order.len >= 1);
    try testing.expectEqual(Kind.null_sink, order[order.len - 1]);
}

test "device enumeration includes the null sink" {
    const gpa = testing.allocator;
    var list = try listDevices(gpa);
    defer list.deinit();
    try testing.expect(list.items.len >= 1);

    var saw_null = false;
    for (list.items) |d| {
        if (d.kind == .null_sink) saw_null = true;
        try testing.expect(d.name.len > 0);
        try testing.expect(d.id.len > 0);
    }
    try testing.expect(saw_null);
}
