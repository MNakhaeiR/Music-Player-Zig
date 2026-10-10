//! A ten-band graphic equalizer built from cascaded biquads.
//!
//! The outer bands are shelves so that energy below 31 Hz and above 16 kHz
//! follows the slider instead of falling off a cliff; the eight bands in
//! between are peaking filters at the ISO third-octave centres.

const std = @import("std");
const biquad = @import("biquad.zig");

pub const band_count = 10;

/// ISO centre frequencies, in Hz.
pub const centers: [band_count]f32 = .{
    31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
};

pub const min_gain_db: f32 = -12.0;
pub const max_gain_db: f32 = 12.0;

/// Per-band gains, in dB.
pub const Gains = [band_count]f32;

pub const Preset = enum {
    flat,
    rock,
    pop,
    jazz,
    classical,
    dance,
    acoustic,
    electronic,
    bass_boost,
    treble_boost,
    vocal,
    loudness,

    pub fn gains(p: Preset) Gains {
        return switch (p) {
            .flat => .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .rock => .{ 5, 4, 3, 1, -1, -1, 1, 3, 4, 5 },
            .pop => .{ -1, 0, 2, 4, 4, 2, 0, -1, -1, -1 },
            .jazz => .{ 4, 3, 1, 2, -1, -1, 0, 1, 3, 4 },
            .classical => .{ 4, 3, 2, 0, -1, -1, 0, 2, 3, 4 },
            .dance => .{ 6, 5, 3, 0, 0, -2, -3, -1, 2, 4 },
            .acoustic => .{ 3, 3, 2, 1, 1, 0, 1, 2, 2, 1 },
            .electronic => .{ 5, 4, 1, 0, -2, 1, 0, 1, 4, 5 },
            .bass_boost => .{ 9, 7, 5, 3, 1, 0, 0, 0, 0, 0 },
            .treble_boost => .{ 0, 0, 0, 0, 0, 1, 3, 5, 7, 8 },
            .vocal => .{ -3, -2, 0, 3, 5, 5, 3, 1, -1, -2 },
            .loudness => .{ 7, 5, 2, 0, -2, -2, 0, 2, 5, 7 },
        };
    }

    pub fn label(p: Preset) []const u8 {
        return switch (p) {
            .flat => "Flat",
            .rock => "Rock",
            .pop => "Pop",
            .jazz => "Jazz",
            .classical => "Classical",
            .dance => "Dance",
            .acoustic => "Acoustic",
            .electronic => "Electronic",
            .bass_boost => "Bass Boost",
            .treble_boost => "Treble Boost",
            .vocal => "Vocal",
            .loudness => "Loudness",
        };
    }

    pub fn fromName(name: []const u8) ?Preset {
        inline for (comptime std.enums.values(Preset)) |p| {
            if (std.ascii.eqlIgnoreCase(name, @tagName(p))) return p;
        }
        return null;
    }
};

pub const Equalizer = struct {
    sections: [band_count]biquad.Stereo8 = @splat(.{}),
    gains_db: Gains = @splat(0),
    sample_rate: u32 = 48_000,
    enabled: bool = false,
    /// Extra output trim, in dB. `autoPreamp` keeps boosts from clipping.
    preamp_db: f32 = 0,
    preamp_linear: f32 = 1,
    /// Set when `preamp_db` should track the band gains automatically.
    auto_preamp: bool = true,

    pub fn init(sample_rate: u32) Equalizer {
        var eq: Equalizer = .{ .sample_rate = sample_rate };
        eq.retune();
        return eq;
    }

    pub fn setSampleRate(eq: *Equalizer, sample_rate: u32) void {
        if (eq.sample_rate == sample_rate) return;
        eq.sample_rate = sample_rate;
        eq.reset();
        eq.retune();
    }

    pub fn setPreset(eq: *Equalizer, p: Preset) void {
        eq.gains_db = p.gains();
        eq.retune();
    }

    pub fn setBand(eq: *Equalizer, index: usize, gain_db: f32) void {
        if (index >= band_count) return;
        eq.gains_db[index] = std.math.clamp(gain_db, min_gain_db, max_gain_db);
        eq.retuneBand(index);
        eq.updatePreamp();
    }

    pub fn nudgeBand(eq: *Equalizer, index: usize, delta_db: f32) void {
        if (index >= band_count) return;
        eq.setBand(index, eq.gains_db[index] + delta_db);
    }

    pub fn setPreampDb(eq: *Equalizer, db: f32) void {
        eq.auto_preamp = false;
        eq.preamp_db = std.math.clamp(db, -24.0, 12.0);
        eq.preamp_linear = std.math.pow(f32, 10.0, eq.preamp_db / 20.0);
    }

    /// Recompute every section from the current gains.
    pub fn retune(eq: *Equalizer) void {
        for (0..band_count) |i| eq.retuneBand(i);
        eq.updatePreamp();
    }

    fn retuneBand(eq: *Equalizer, index: usize) void {
        const gain = std.math.clamp(eq.gains_db[index], min_gain_db, max_gain_db);
        const kind: biquad.Kind = switch (index) {
            0 => .low_shelf,
            band_count - 1 => .high_shelf,
            else => .peaking,
        };
        // Q ~= 1.4 keeps adjacent third-octave bands from stacking up too
        // much; shelves want a gentler slope.
        const q: f32 = if (kind == .peaking) 1.41 else 0.7;
        eq.sections[index].setCoeffs(biquad.design(.{
            .kind = kind,
            .freq = centers[index],
            .q = q,
            .gain_db = gain,
        }, eq.sample_rate));
    }

    fn updatePreamp(eq: *Equalizer) void {
        if (!eq.auto_preamp) return;
        // Back off by the worst-case boost so a heavy preset cannot clip.
        var peak: f32 = 0;
        for (eq.gains_db) |g| peak = @max(peak, g);
        eq.preamp_db = -peak * 0.75;
        eq.preamp_linear = std.math.pow(f32, 10.0, eq.preamp_db / 20.0);
    }

    pub fn reset(eq: *Equalizer) void {
        for (&eq.sections) |*s| s.reset();
    }

    pub fn isFlat(eq: *const Equalizer) bool {
        for (eq.gains_db) |g| {
            if (@abs(g) > 0.01) return false;
        }
        return true;
    }

    /// Process an interleaved block in place. A disabled or flat EQ is a
    /// no-op, so leaving it on costs nothing.
    pub fn process(eq: *Equalizer, samples: []f32, channels: usize) void {
        if (!eq.enabled or eq.isFlat()) return;
        for (&eq.sections) |*s| s.processInterleaved(samples, channels);
        if (eq.preamp_linear != 1.0) {
            for (samples) |*v| v.* *= eq.preamp_linear;
        }
    }

    /// Combined magnitude response of the whole cascade, in dB, including the
    /// preamp. The UI uses this to draw the curve.
    pub fn responseDbAt(eq: *const Equalizer, freq: f64) f64 {
        var total: f64 = 0;
        for (eq.sections) |s| total += s.coeffs.magnitudeDbAt(freq, eq.sample_rate);
        return total + @as(f64, eq.preamp_db);
    }
};

const testing = std.testing;

test "a flat equalizer does not touch the signal" {
    var eq = Equalizer.init(48_000);
    eq.enabled = true;
    var buf = [_]f32{ 0.3, -0.4, 0.5, -0.6, 0.7, -0.8 };
    const want = buf;
    eq.process(&buf, 2);
    try testing.expectEqualSlices(f32, &want, &buf);
}

test "presets round trip by name" {
    try testing.expectEqual(Preset.rock, Preset.fromName("rock").?);
    try testing.expectEqual(Preset.bass_boost, Preset.fromName("BASS_BOOST").?);
    try testing.expect(Preset.fromName("nope") == null);
}

test "band gains are clamped" {
    var eq = Equalizer.init(44_100);
    eq.setBand(0, 999);
    try testing.expectEqual(max_gain_db, eq.gains_db[0]);
    eq.setBand(1, -999);
    try testing.expectEqual(min_gain_db, eq.gains_db[1]);
    eq.setBand(99, 5); // out of range index is ignored
}

test "a boosted band raises the response at its centre" {
    var eq = Equalizer.init(48_000);
    eq.auto_preamp = false;
    eq.preamp_db = 0;
    eq.preamp_linear = 1;
    eq.setBand(5, 9); // 1 kHz
    const at_center = eq.responseDbAt(centers[5]);
    const far_away = eq.responseDbAt(60);
    try testing.expect(at_center > 6.0);
    try testing.expect(at_center < 12.0);
    try testing.expect(@abs(far_away) < 2.0);
}

test "bass boost lifts low frequencies and leaves highs alone" {
    var eq = Equalizer.init(48_000);
    eq.auto_preamp = false;
    eq.preamp_db = 0;
    eq.preamp_linear = 1;
    eq.setPreset(.bass_boost);
    try testing.expect(eq.responseDbAt(40) > 6.0);
    try testing.expect(@abs(eq.responseDbAt(12_000)) < 2.0);
}

test "auto preamp backs off when bands are boosted" {
    var eq = Equalizer.init(48_000);
    eq.setPreset(.bass_boost);
    try testing.expect(eq.preamp_db < -4.0);
    try testing.expect(eq.preamp_linear < 1.0);

    eq.setPreset(.flat);
    try testing.expectApproxEqAbs(@as(f32, 0), eq.preamp_db, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), eq.preamp_linear, 1e-6);
}

test "processing a boosted band actually changes amplitude" {
    const sr: u32 = 48_000;
    var eq = Equalizer.init(sr);
    eq.enabled = true;
    eq.auto_preamp = false;
    eq.preamp_db = 0;
    eq.preamp_linear = 1;
    eq.setBand(5, 12);

    const n = 8192;
    var peak: f32 = 0;
    var i: usize = 0;
    var frame: [2]f32 = undefined;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr));
        const x: f32 = @floatCast(0.25 * @sin(2.0 * std.math.pi * 1000.0 * t));
        frame = .{ x, x };
        eq.process(&frame, 2);
        if (i > n / 2) peak = @max(peak, @abs(frame[0]));
    }
    // 12 dB of boost on a 0.25 amplitude tone lands near 1.0.
    try testing.expect(peak > 0.7);
    try testing.expect(peak < 1.2);
}

test "sample rate changes retune the filters" {
    var eq = Equalizer.init(44_100);
    eq.setBand(9, 6);
    const before = eq.sections[9].coeffs;
    eq.setSampleRate(96_000);
    const after = eq.sections[9].coeffs;
    try testing.expect(before.b0 != after.b0);
    try testing.expectEqual(@as(u32, 96_000), eq.sample_rate);
}
