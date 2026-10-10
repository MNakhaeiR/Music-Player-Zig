//! An output that paces itself in real time and throws the audio away.
//!
//! This is what makes the whole player testable: the engine, the DSP chain,
//! the playlist logic and the UI all behave exactly as they would with real
//! hardware, just without a speaker. It is also the last-resort fallback when
//! no audio device can be opened, so the player still runs (and still advances
//! through a playlist) on a machine with no sound card.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Atomic = std.atomic.Value;

const backend = @import("backend.zig");

pub const NullSink = struct {
    gpa: Allocator,
    io: Io,
    render: backend.RenderFn,
    userdata: ?*anyopaque,

    fmt: backend.Format,
    block_frames: u32,
    buf: []f32,

    thread: ?std.Thread = null,
    running: Atomic(bool) = .init(false),
    frames_written: Atomic(u64) = .init(0),
    describe_buf: [64]u8 = undefined,
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
        return self(ptr).block_frames;
    }
    fn vDescribe(ptr: *anyopaque) []const u8 {
        const s = self(ptr);
        return s.describe_buf[0..s.describe_len];
    }
    fn vKind(_: *anyopaque) backend.Kind {
        return .null_sink;
    }
    fn vFramesWritten(ptr: *anyopaque) u64 {
        return self(ptr).frames_written.load(.monotonic);
    }

    inline fn self(ptr: *anyopaque) *NullSink {
        return @ptrCast(@alignCast(ptr));
    }

    fn startImpl(s: *NullSink) backend.Error!void {
        if (s.thread != null) return;
        s.running.store(true, .release);
        s.thread = std.Thread.spawn(.{}, loop, .{s}) catch {
            s.running.store(false, .release);
            return error.DeviceFailure;
        };
    }

    fn stopImpl(s: *NullSink) void {
        s.running.store(false, .release);
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
    }

    fn deinitImpl(s: *NullSink) void {
        s.stopImpl();
        const gpa = s.gpa;
        gpa.free(s.buf);
        gpa.destroy(s);
    }

    fn loop(s: *NullSink) void {
        const frames_per_block: u64 = s.block_frames;
        const ns_per_block: i96 = @intCast(
            (frames_per_block * std.time.ns_per_s) / s.fmt.sample_rate,
        );

        // Track an ideal schedule rather than sleeping a fixed amount, so
        // drift from sleep overshoot does not accumulate.
        var next: Io.Timestamp = .now(s.io, .awake);

        while (s.running.load(.acquire)) {
            s.render(s.userdata, s.buf, s.fmt.channels);
            _ = s.frames_written.fetchAdd(frames_per_block, .monotonic);

            next = next.addDuration(.fromNanoseconds(ns_per_block));
            const now: Io.Timestamp = .now(s.io, .awake);
            const remaining = now.durationTo(next);
            if (remaining.nanoseconds > 0) {
                s.io.sleep(remaining, .awake) catch break;
            } else if (remaining.nanoseconds < -ns_per_block * 4) {
                // Fell a long way behind (debugger, heavy load): give up on
                // catching up and resynchronize.
                next = now;
            }
        }
    }
};

pub fn open(
    gpa: Allocator,
    io: Io,
    options: backend.Options,
    render: backend.RenderFn,
    userdata: ?*anyopaque,
) backend.Error!backend.Backend {
    const sample_rate = options.sample_rate orelse 48_000;
    const channels = options.channels orelse 2;
    if (sample_rate == 0 or channels == 0) return error.UnsupportedFormat;

    const latency_ms = @max(options.latency_ms, 5);
    const block_frames: u32 = @intCast(@max(
        64,
        (@as(u64, sample_rate) * latency_ms) / 1000,
    ));

    const s = gpa.create(NullSink) catch return error.OutOfMemory;
    errdefer gpa.destroy(s);

    const buf = gpa.alloc(f32, @as(usize, block_frames) * channels) catch
        return error.OutOfMemory;
    errdefer gpa.free(buf);
    @memset(buf, 0);

    s.* = .{
        .gpa = gpa,
        .io = io,
        .render = render,
        .userdata = userdata,
        .fmt = .{ .sample_rate = sample_rate, .channels = channels },
        .block_frames = block_frames,
        .buf = buf,
    };

    const text = std.fmt.bufPrint(
        &s.describe_buf,
        "null sink {d} Hz {d}ch",
        .{ sample_rate, channels },
    ) catch "null sink";
    s.describe_len = text.len;

    return .{ .ptr = s, .vtable = &NullSink.vtable };
}

const testing = std.testing;

const Counter = struct {
    frames: Atomic(u64) = .init(0),
    calls: Atomic(u32) = .init(0),
    /// Written by the callback so the test can confirm the buffer is writable.
    last_value: Atomic(u32) = .init(0),

    fn render(userdata: ?*anyopaque, out: []f32, channels: u8) void {
        const c: *Counter = @ptrCast(@alignCast(userdata.?));
        const frames = out.len / channels;
        for (out, 0..) |*v, i| v.* = @floatFromInt(i % 16);
        _ = c.frames.fetchAdd(frames, .monotonic);
        _ = c.calls.fetchAdd(1, .monotonic);
        c.last_value.store(@bitCast(out[0]), .monotonic);
    }
};

test "the null sink pulls audio at roughly real time" {
    const gpa = testing.allocator;
    const io = testing.io;

    var counter: Counter = .{};
    const be = try open(gpa, io, .{
        .sample_rate = 48_000,
        .channels = 2,
        .latency_ms = 10,
    }, Counter.render, &counter);
    defer be.deinit();

    try testing.expectEqual(@as(u32, 48_000), be.format().sample_rate);
    try testing.expectEqual(@as(u8, 2), be.format().channels);
    try testing.expectEqual(backend.Kind.null_sink, be.kind());
    try testing.expect(be.describe().len > 0);

    try be.start();
    // 150 ms of wall clock should produce roughly 150 ms of audio.
    try io.sleep(.fromMilliseconds(150), .awake);
    be.stop();

    const frames = counter.frames.load(.monotonic);
    try testing.expect(counter.calls.load(.monotonic) >= 5);
    // Generous bounds: this is a timing test on a shared machine.
    try testing.expect(frames > 48_000 / 20); // > 50 ms worth
    try testing.expect(frames < 48_000); // < 1 s worth
    try testing.expectEqual(frames, be.framesWritten());
}

test "start is idempotent and stop is safe to repeat" {
    const gpa = testing.allocator;
    const io = testing.io;

    var counter: Counter = .{};
    const be = try open(gpa, io, .{ .latency_ms = 5 }, Counter.render, &counter);
    defer be.deinit();

    try be.start();
    try be.start();
    be.stop();
    be.stop();
}

test "a zero sample rate is rejected" {
    const gpa = testing.allocator;
    const io = testing.io;
    var counter: Counter = .{};
    try testing.expectError(
        error.UnsupportedFormat,
        open(gpa, io, .{ .sample_rate = 0 }, Counter.render, &counter),
    );
}
