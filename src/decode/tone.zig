//! A synthesized signal source.
//!
//! It plugs into the same decoder interface as the file formats, which makes
//! it useful for three things: checking the output path works without any
//! media on hand (`zmp --tone sine:440`), exercising the DSP chain in tests,
//! and generating reference material for the offline renderer.

const std = @import("std");
const api = @import("api.zig");

pub const Shape = union(enum) {
    sine: struct { freq: f32 = 440 },
    square: struct { freq: f32 = 440 },
    saw: struct { freq: f32 = 440 },
    /// Logarithmic frequency sweep across the whole stream.
    sweep: struct { start: f32 = 20, end: f32 = 20_000 },
    white_noise,
    /// Equal energy per octave; the usual signal for checking a spectrum
    /// display, because it should draw a flat line.
    pink_noise,
    silence,

    pub fn label(s: Shape) []const u8 {
        return switch (s) {
            .sine => "sine",
            .square => "square",
            .saw => "saw",
            .sweep => "sweep",
            .white_noise => "white",
            .pink_noise => "pink",
            .silence => "silence",
        };
    }
};

pub const Spec = struct {
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
    frames: u64 = 48_000 * 5,
    shape: Shape = .{ .sine = .{} },
    amplitude: f32 = 0.5,
};

/// Parse a `shape[:arg]` spec, e.g. `sine:440`, `sweep:20-20000`, `pink`.
pub fn parseShape(text: []const u8) ?Shape {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const name = if (colon) |c| text[0..c] else text;
    const arg = if (colon) |c| text[c + 1 ..] else "";

    if (std.ascii.eqlIgnoreCase(name, "sine")) {
        return .{ .sine = .{ .freq = parseFloat(arg) orelse 440 } };
    } else if (std.ascii.eqlIgnoreCase(name, "square")) {
        return .{ .square = .{ .freq = parseFloat(arg) orelse 440 } };
    } else if (std.ascii.eqlIgnoreCase(name, "saw")) {
        return .{ .saw = .{ .freq = parseFloat(arg) orelse 440 } };
    } else if (std.ascii.eqlIgnoreCase(name, "sweep")) {
        if (std.mem.indexOfScalar(u8, arg, '-')) |dash| {
            return .{ .sweep = .{
                .start = parseFloat(arg[0..dash]) orelse 20,
                .end = parseFloat(arg[dash + 1 ..]) orelse 20_000,
            } };
        }
        return .{ .sweep = .{} };
    } else if (std.ascii.eqlIgnoreCase(name, "white") or
        std.ascii.eqlIgnoreCase(name, "noise"))
    {
        return .white_noise;
    } else if (std.ascii.eqlIgnoreCase(name, "pink")) {
        return .pink_noise;
    } else if (std.ascii.eqlIgnoreCase(name, "silence")) {
        return .silence;
    }
    return null;
}

fn parseFloat(text: []const u8) ?f32 {
    if (text.len == 0) return null;
    return std.fmt.parseFloat(f32, text) catch null;
}

pub const Tone = struct {
    spec: Spec,
    pos: u64 = 0,
    prng: std.Random.DefaultPrng,
    /// Running state for the pink-noise filter (Voss-McCartney style).
    pink: [7]f32 = @splat(0),

    pub fn init(spec: Spec) Tone {
        return .{
            .spec = spec,
            .prng = std.Random.DefaultPrng.init(0x7A1E_5EED),
        };
    }

    pub fn info(self: *const Tone) api.Info {
        return .{
            .codec = .tone,
            .sample_rate = self.spec.sample_rate,
            .channels = self.spec.channels,
            .bits_per_sample = 32,
            .total_frames = self.spec.frames,
            .seekable = true,
            .bitrate = null,
        };
    }

    pub fn positionFrames(self: *const Tone) u64 {
        return self.pos;
    }

    pub fn seekToFrame(self: *Tone, frame: u64) api.Error!void {
        if (frame > self.spec.frames) return error.SeekOutOfRange;
        self.pos = frame;
        self.pink = @splat(0);
    }

    pub fn readFrames(self: *Tone, out: []f32) api.Error!usize {
        const ch = self.spec.channels;
        if (ch == 0) return error.CorruptStream;
        const want = @min(out.len / ch, self.spec.frames - self.pos);
        if (want == 0) return 0;

        const sr: f64 = @floatFromInt(self.spec.sample_rate);
        const rand = self.prng.random();
        const amp = self.spec.amplitude;

        var i: usize = 0;
        while (i < want) : (i += 1) {
            const n = self.pos + i;
            const t = @as(f64, @floatFromInt(n)) / sr;
            const v: f32 = switch (self.spec.shape) {
                .sine => |s| @floatCast(@sin(2.0 * std.math.pi * @as(f64, s.freq) * t)),
                .square => |s| blk: {
                    const phase = @mod(@as(f64, s.freq) * t, 1.0);
                    break :blk if (phase < 0.5) 1.0 else -1.0;
                },
                .saw => |s| blk: {
                    const phase = @mod(@as(f64, s.freq) * t, 1.0);
                    break :blk @floatCast(2.0 * phase - 1.0);
                },
                .sweep => |s| blk: {
                    const total = @as(f64, @floatFromInt(self.spec.frames)) / sr;
                    if (total <= 0) break :blk 0;
                    const frac = @min(t / total, 1.0);
                    // Exponential sweep: constant octaves per second.
                    const f0: f64 = @max(1.0, s.start);
                    const f1: f64 = @max(f0 + 1.0, s.end);
                    const k = std.math.log(f64, std.math.e, f1 / f0);
                    const phase = 2.0 * std.math.pi * f0 * total / k *
                        (std.math.exp(k * frac) - 1.0);
                    break :blk @floatCast(@sin(phase));
                },
                .white_noise => rand.float(f32) * 2.0 - 1.0,
                .pink_noise => self.nextPink(rand),
                .silence => 0,
            };
            const sample = v * amp;
            const frame = out[i * ch ..][0..ch];
            for (frame) |*s| s.* = sample;
        }
        self.pos += want;
        return want;
    }

    /// Paul Kellet's filter approximation: a cascade of one-pole sections that
    /// gives roughly -3 dB per octave across the audible range.
    fn nextPink(self: *Tone, rand: std.Random) f32 {
        const white = rand.float(f32) * 2.0 - 1.0;
        self.pink[0] = 0.99886 * self.pink[0] + white * 0.0555179;
        self.pink[1] = 0.99332 * self.pink[1] + white * 0.0750759;
        self.pink[2] = 0.96900 * self.pink[2] + white * 0.1538520;
        self.pink[3] = 0.86650 * self.pink[3] + white * 0.3104856;
        self.pink[4] = 0.55000 * self.pink[4] + white * 0.5329522;
        self.pink[5] = -0.7616 * self.pink[5] - white * 0.0168980;
        const out = self.pink[0] + self.pink[1] + self.pink[2] + self.pink[3] +
            self.pink[4] + self.pink[5] + self.pink[6] + white * 0.5362;
        self.pink[6] = white * 0.115926;
        return std.math.clamp(out * 0.11, -1.0, 1.0);
    }
};

const testing = std.testing;

test "a sine has the requested frequency and amplitude" {
    const sr: u32 = 48_000;
    var t = Tone.init(.{
        .sample_rate = sr,
        .channels = 1,
        .frames = sr,
        .shape = .{ .sine = .{ .freq = 1000 } },
        .amplitude = 0.5,
    });

    const buf = try testing.allocator.alloc(f32, sr);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(usize, sr), try t.readFrames(buf));
    try testing.expectEqual(@as(usize, 0), try t.readFrames(buf));

    var peak: f32 = 0;
    for (buf) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.001);

    // 1000 Hz over one second is 2000 zero crossings.
    var crossings: usize = 0;
    for (buf[1..], 0..) |v, i| {
        if ((buf[i] < 0) != (v < 0)) crossings += 1;
    }
    try testing.expectApproxEqAbs(@as(f32, 2000), @as(f32, @floatFromInt(crossings)), 2);
}

test "stereo frames carry the same signal on both channels" {
    var t = Tone.init(.{ .channels = 2, .frames = 100, .shape = .{ .sine = .{} } });
    var buf: [200]f32 = undefined;
    try testing.expectEqual(@as(usize, 100), try t.readFrames(&buf));
    for (0..100) |i| try testing.expectEqual(buf[i * 2], buf[i * 2 + 1]);
}

test "square and saw hit their rails" {
    var sq = Tone.init(.{ .channels = 1, .frames = 1000, .shape = .{ .square = .{ .freq = 100 } }, .amplitude = 1.0 });
    var buf: [1000]f32 = undefined;
    _ = try sq.readFrames(&buf);
    for (buf) |v| try testing.expect(@abs(@abs(v) - 1.0) < 1e-6);

    var saw = Tone.init(.{ .channels = 1, .frames = 1000, .shape = .{ .saw = .{ .freq = 50 } }, .amplitude = 1.0 });
    _ = try saw.readFrames(&buf);
    var lo: f32 = 1;
    var hi: f32 = -1;
    for (buf) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try testing.expect(lo < -0.9);
    try testing.expect(hi > 0.9);
}

test "noise stays in range and is not constant" {
    for ([_]Shape{ .white_noise, .pink_noise }) |shape| {
        var t = Tone.init(.{ .channels = 1, .frames = 4096, .shape = shape, .amplitude = 1.0 });
        var buf: [4096]f32 = undefined;
        _ = try t.readFrames(&buf);
        var lo: f32 = 10;
        var hi: f32 = -10;
        for (buf) |v| {
            try testing.expect(v >= -1.0001 and v <= 1.0001);
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        try testing.expect(hi - lo > 0.1);
    }
}

test "silence is silent" {
    var t = Tone.init(.{ .channels = 2, .frames = 64, .shape = .silence });
    var buf: [128]f32 = undefined;
    _ = try t.readFrames(&buf);
    for (buf) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "a sweep rises in frequency" {
    const sr: u32 = 48_000;
    var t = Tone.init(.{
        .sample_rate = sr,
        .channels = 1,
        .frames = sr,
        .shape = .{ .sweep = .{ .start = 100, .end = 8000 } },
        .amplitude = 1.0,
    });
    const buf = try testing.allocator.alloc(f32, sr);
    defer testing.allocator.free(buf);
    _ = try t.readFrames(buf);

    // Count crossings in the first and last tenth of the sweep.
    const tenth = sr / 10;
    var early: usize = 0;
    for (buf[1..tenth], 0..) |v, i| {
        if ((buf[i] < 0) != (v < 0)) early += 1;
    }
    var late: usize = 0;
    const tail = buf[sr - tenth ..];
    for (tail[1..], 0..) |v, i| {
        if ((tail[i] < 0) != (v < 0)) late += 1;
    }
    try testing.expect(late > early * 5);
}

test "seeking repositions the generator" {
    var t = Tone.init(.{ .channels = 1, .frames = 1000, .shape = .{ .sine = .{ .freq = 100 } } });
    var all: [1000]f32 = undefined;
    _ = try t.readFrames(&all);

    try t.seekToFrame(500);
    try testing.expectEqual(@as(u64, 500), t.positionFrames());
    var part: [100]f32 = undefined;
    _ = try t.readFrames(&part);
    for (0..100) |i| try testing.expectApproxEqAbs(all[500 + i], part[i], 1e-6);

    try testing.expectError(error.SeekOutOfRange, t.seekToFrame(5000));
}

test "shape specs parse" {
    try testing.expectEqual(@as(f32, 440), parseShape("sine").?.sine.freq);
    try testing.expectEqual(@as(f32, 1000), parseShape("sine:1000").?.sine.freq);
    try testing.expectEqual(@as(f32, 50), parseShape("SQUARE:50").?.square.freq);
    const sweep = parseShape("sweep:30-15000").?.sweep;
    try testing.expectEqual(@as(f32, 30), sweep.start);
    try testing.expectEqual(@as(f32, 15000), sweep.end);
    try testing.expectEqual(Shape.pink_noise, parseShape("pink").?);
    try testing.expectEqual(Shape.white_noise, parseShape("noise").?);
    try testing.expect(parseShape("trombone") == null);
}
