//! Volume, balance and mute.
//!
//! The applied gain always walks toward its target over a few milliseconds.
//! Jumping straight to a new value produces an audible click ("zipper noise")
//! because it is a step discontinuity in the waveform, so every control here
//! is smoothed.

const std = @import("std");
const time = @import("../util/time.zig");

pub const Gain = struct {
    /// Where the control is set, as a linear multiplier.
    target: f32 = 1.0,
    /// Where the smoother has actually reached.
    current: f32 = 1.0,
    /// Stereo balance: -1 is hard left, 0 centred, +1 hard right.
    balance: f32 = 0.0,
    muted: bool = false,
    /// One-pole smoothing coefficient, derived from the ramp time.
    coef: f32 = 0.0,
    sample_rate: u32 = 48_000,

    /// How long a volume change takes to settle, in milliseconds.
    pub const ramp_ms: f32 = 12.0;

    pub fn init(sample_rate: u32) Gain {
        var g: Gain = .{ .sample_rate = sample_rate };
        g.setSampleRate(sample_rate);
        return g;
    }

    pub fn setSampleRate(g: *Gain, sample_rate: u32) void {
        g.sample_rate = @max(sample_rate, 1);
        const samples = ramp_ms * 0.001 * @as(f32, @floatFromInt(g.sample_rate));
        // One-pole step response reaching ~99% in `samples`.
        g.coef = if (samples <= 1) 1.0 else 1.0 - std.math.exp(-5.0 / samples);
    }

    /// Set the volume as a 0..1 linear fraction, shaped so the control feels
    /// even to the ear. Human loudness perception is roughly logarithmic, so a
    /// linear fader spends most of its travel in a range that sounds the same;
    /// cubing the position spreads the audible change evenly instead.
    pub fn setVolume(g: *Gain, fraction: f32) void {
        const f = std.math.clamp(fraction, 0.0, 1.0);
        g.target = f * f * f;
    }

    /// Recover the 0..1 fader position from the stored linear gain.
    pub fn volume(g: *const Gain) f32 {
        return std.math.cbrt(g.target);
    }

    pub fn nudgeVolume(g: *Gain, delta: f32) void {
        g.setVolume(g.volume() + delta);
    }

    pub fn setVolumeDb(g: *Gain, db: f32) void {
        g.target = time.dbToAmplitude(std.math.clamp(db, -60.0, 12.0));
    }

    pub fn volumeDb(g: *const Gain) f32 {
        return time.amplitudeToDb(g.target);
    }

    pub fn setBalance(g: *Gain, b: f32) void {
        g.balance = std.math.clamp(b, -1.0, 1.0);
    }

    pub fn nudgeBalance(g: *Gain, delta: f32) void {
        g.setBalance(g.balance + delta);
    }

    pub fn toggleMute(g: *Gain) void {
        g.muted = !g.muted;
    }

    /// Jump the smoother to its target. Use after a seek or a track change,
    /// where there is no waveform continuity to protect.
    pub fn snap(g: *Gain) void {
        g.current = g.effectiveTarget();
    }

    fn effectiveTarget(g: *const Gain) f32 {
        return if (g.muted) 0.0 else g.target;
    }

    /// Per-channel trim from the balance control. Constant-power panning
    /// keeps the perceived loudness steady as the image moves.
    fn channelTrim(g: *const Gain, ch: usize, channels: usize) f32 {
        if (channels != 2 or g.balance == 0) return 1.0;
        // Map balance to an angle in [0, pi/2] and take sin/cos.
        const angle = (g.balance + 1.0) * 0.25 * std.math.pi;
        return if (ch == 0) @cos(angle) * std.math.sqrt2 else @sin(angle) * std.math.sqrt2;
    }

    /// Apply volume, mute and balance to an interleaved block in place.
    pub fn process(g: *Gain, samples: []f32, channels: usize) void {
        if (channels == 0) return;
        const target = g.effectiveTarget();
        const frames = samples.len / channels;

        var trims: [8]f32 = @splat(1.0);
        const tracked = @min(channels, trims.len);
        for (0..tracked) |ch| trims[ch] = g.channelTrim(ch, channels);

        // Fast path: already settled and nothing to pan.
        if (@abs(g.current - target) < 1e-6 and g.balance == 0) {
            g.current = target;
            if (target == 1.0) return;
            for (samples) |*s| s.* *= target;
            return;
        }

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            g.current += (target - g.current) * g.coef;
            const frame = samples[f * channels ..][0..channels];
            for (frame, 0..) |*s, ch| {
                const trim = if (ch < tracked) trims[ch] else 1.0;
                s.* *= g.current * trim;
            }
        }
        if (@abs(g.current - target) < 1e-7) g.current = target;
    }
};

const testing = std.testing;

test "unity gain leaves the signal alone" {
    var g = Gain.init(48_000);
    g.snap();
    var buf = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    const want = buf;
    g.process(&buf, 2);
    try testing.expectEqualSlices(f32, &want, &buf);
}

test "volume is cubic in the fader position" {
    var g = Gain.init(48_000);
    g.setVolume(1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g.target, 1e-6);
    g.setVolume(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.125), g.target, 1e-6);
    g.setVolume(0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), g.target, 1e-6);
    // Out of range requests clamp.
    g.setVolume(5.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g.target, 1e-6);
}

test "volume round trips through the fader position" {
    var g = Gain.init(48_000);
    for ([_]f32{ 0.1, 0.35, 0.8, 1.0 }) |v| {
        g.setVolume(v);
        try testing.expectApproxEqAbs(v, g.volume(), 1e-5);
    }
}

test "muting fades to silence rather than cutting" {
    var g = Gain.init(48_000);
    g.setVolume(1.0);
    g.snap();
    g.toggleMute();
    try testing.expect(g.muted);

    // One short block in: already heading down but not yet silent.
    var buf: [64]f32 = @splat(1.0);
    g.process(&buf, 2);
    try testing.expect(buf[0] > 0.5); // no instant jump to zero
    try testing.expect(buf[63] < buf[0]); // but clearly on the way down

    // After a few hundred milliseconds it is silent.
    var long: [48_000]f32 = @splat(1.0);
    g.process(&long, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.0), long[47_999], 1e-4);
}

test "a volume change ramps instead of stepping" {
    var g = Gain.init(48_000);
    g.setVolume(1.0);
    g.snap();
    g.setVolume(0.0);

    var buf: [8]f32 = @splat(1.0);
    g.process(&buf, 1);
    // Monotonically decreasing, and the first sample is not already zero.
    try testing.expect(buf[0] > 0.9);
    for (buf[1..], 0..) |v, i| try testing.expect(v <= buf[i]);
}

test "balance pans without changing total power" {
    var g = Gain.init(48_000);
    g.setVolume(1.0);
    g.snap();

    g.setBalance(-1.0); // hard left
    var buf = [_]f32{ 1.0, 1.0 };
    g.process(&buf, 2);
    try testing.expect(buf[0] > 1.3); // left boosted toward sqrt(2)
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[1], 1e-5);

    g.setBalance(0.0);
    g.snap();
    var centred = [_]f32{ 1.0, 1.0 };
    g.process(&centred, 2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), centred[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), centred[1], 1e-4);
}

test "decibel setters agree with the getters" {
    var g = Gain.init(48_000);
    g.setVolumeDb(-6.0);
    try testing.expectApproxEqAbs(@as(f32, -6.0), g.volumeDb(), 1e-3);
    g.setVolumeDb(0.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g.target, 1e-5);
}

test "nudging stays inside the legal range" {
    var g = Gain.init(48_000);
    g.setVolume(0.95);
    g.nudgeVolume(0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g.volume(), 1e-5);
    g.setVolume(0.02);
    g.nudgeVolume(-0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), g.volume(), 1e-5);

    g.setBalance(0.9);
    g.nudgeBalance(0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g.balance, 1e-6);
}
