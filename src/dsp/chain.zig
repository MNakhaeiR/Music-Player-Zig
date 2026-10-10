//! The per-output processing chain.
//!
//! Signal order, and why:
//!   1. equalizer — tone shaping belongs before the fader so the EQ sees a
//!      consistent level and its own make-up gain stays meaningful.
//!   2. gain      — volume, mute and balance.
//!   3. limiter   — last, so it can guarantee the ceiling for whatever the
//!      stages above produced.
//!   4. analyzer  — taps the final signal, which is what the listener hears.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Equalizer = @import("equalizer.zig").Equalizer;
const Preset = @import("equalizer.zig").Preset;
const Gain = @import("gain.zig").Gain;
const Limiter = @import("limiter.zig").Limiter;
const Analyzer = @import("analyzer.zig").Analyzer;

pub const Chain = struct {
    eq: Equalizer,
    gain: Gain,
    limiter: Limiter,
    /// Optional: the chain runs fine headless, which is how the offline
    /// renderer and most of the tests use it.
    analyzer: ?*Analyzer = null,

    sample_rate: u32,
    channels: usize,

    pub fn init(
        gpa: Allocator,
        sample_rate: u32,
        channels: usize,
    ) Allocator.Error!Chain {
        var limiter = try Limiter.init(gpa, sample_rate, channels);
        errdefer limiter.deinit();
        return .{
            .eq = Equalizer.init(sample_rate),
            .gain = Gain.init(sample_rate),
            .limiter = limiter,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *Chain) void {
        self.limiter.deinit();
        self.* = undefined;
    }

    /// Re-point the chain at a new output format. Allocates, so keep it off
    /// the audio thread.
    pub fn reconfigure(
        self: *Chain,
        sample_rate: u32,
        channels: usize,
    ) Allocator.Error!void {
        self.eq.setSampleRate(sample_rate);
        self.gain.setSampleRate(sample_rate);
        try self.limiter.reconfigure(sample_rate, channels);
        if (self.analyzer) |an| an.setSampleRate(sample_rate);
        self.sample_rate = sample_rate;
        self.channels = channels;
    }

    /// Clear filter state without changing any setting. Use on seek and track
    /// change, where waveform continuity is already broken.
    pub fn reset(self: *Chain) void {
        self.eq.reset();
        self.gain.snap();
        self.limiter.reset();
        if (self.analyzer) |an| an.reset();
    }

    /// Total latency the chain adds, in frames.
    pub fn latencyFrames(self: *const Chain) usize {
        return self.limiter.latencyFrames();
    }

    /// Process an interleaved block in place. Real-time safe: no allocation,
    /// no locks, no syscalls.
    pub fn process(self: *Chain, samples: []f32, channels: usize) void {
        self.eq.process(samples, channels);
        self.gain.process(samples, channels);
        self.limiter.process(samples, channels);
        if (self.analyzer) |an| an.pushAudio(samples, channels);
    }
};

const testing = std.testing;

test "a default chain is close to transparent" {
    const gpa = testing.allocator;
    var chain = try Chain.init(gpa, 48_000, 2);
    defer chain.deinit();
    chain.reset();

    const frames = 2048;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        const v: f32 = @floatCast(0.4 * @sin(2.0 * std.math.pi * 440.0 * t));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    const original = try gpa.dupe(f32, buf);
    defer gpa.free(original);

    chain.process(buf, 2);

    // EQ off and volume at unity, so only the limiter's delay applies.
    const d = chain.latencyFrames();
    for (d..frames) |i| {
        try testing.expectApproxEqAbs(original[(i - d) * 2], buf[i * 2], 1e-5);
    }
}

test "volume is applied through the chain" {
    const gpa = testing.allocator;
    var chain = try Chain.init(gpa, 48_000, 1);
    defer chain.deinit();
    chain.gain.setVolume(0.5); // -> 0.125 linear
    chain.reset();

    const buf = try gpa.alloc(f32, 4096);
    defer gpa.free(buf);
    @memset(buf, 0.8);
    chain.process(buf, 1);

    try testing.expectApproxEqAbs(@as(f32, 0.1), buf[2048], 1e-3);
}

test "the chain never lets the output past the ceiling" {
    const gpa = testing.allocator;
    var chain = try Chain.init(gpa, 48_000, 2);
    defer chain.deinit();
    chain.eq.enabled = true;
    chain.eq.auto_preamp = false;
    chain.eq.preamp_db = 0;
    chain.eq.preamp_linear = 1;
    chain.eq.setBand(4, 12); // a big boost at 500 Hz
    chain.limiter.ceiling = 0.95;
    chain.reset();

    const frames = 48_000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        // Already at full scale before the boost.
        const v: f32 = @floatCast(@sin(2.0 * std.math.pi * 500.0 * t));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    chain.process(buf, 2);

    var peak: f32 = 0;
    for (buf[chain.latencyFrames() * 2 ..]) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak <= 0.95 + 1e-4);
}

test "the analyzer sees the processed signal" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 512, 12);
    defer an.deinit();

    var chain = try Chain.init(gpa, 48_000, 1);
    defer chain.deinit();
    chain.analyzer = &an;
    chain.gain.setVolume(1.0);
    chain.reset();

    const buf = try gpa.alloc(f32, 4096);
    defer gpa.free(buf);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        s.* = 0.7 * @sin(2.0 * std.math.pi * 440.0 * t);
    }
    chain.process(buf, 1);

    try testing.expect(an.channelPeak(0) > 0.6);
    try testing.expect(!an.feed.isEmpty());
}

test "reconfiguring follows a format change" {
    const gpa = testing.allocator;
    var chain = try Chain.init(gpa, 44_100, 2);
    defer chain.deinit();
    try chain.reconfigure(96_000, 2);

    try testing.expectEqual(@as(u32, 96_000), chain.sample_rate);
    try testing.expectEqual(@as(u32, 96_000), chain.eq.sample_rate);
    try testing.expectEqual(@as(u32, 96_000), chain.limiter.sample_rate);
}
