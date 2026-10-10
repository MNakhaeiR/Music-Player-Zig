//! Second-order IIR sections and the RBJ "Audio EQ Cookbook" designers.
//!
//! Filters are evaluated in transposed direct form II, which keeps the state
//! small (two values per channel) and behaves well in 32-bit float.

const std = @import("std");

/// Normalized coefficients for `y = b0*x + b1*x' + b2*x'' - a1*y' - a2*y''`.
pub const Coeffs = struct {
    b0: f32 = 1,
    b1: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,

    /// The filter that does nothing.
    pub const passthrough: Coeffs = .{};

    /// Magnitude response at `freq` Hz, as a linear gain. Used by the UI to
    /// draw the EQ curve and by the tests to verify the designers.
    pub fn magnitudeAt(c: Coeffs, freq: f64, sample_rate: u32) f64 {
        const w = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(sample_rate));
        const cos1 = @cos(w);
        const sin1 = @sin(w);
        const cos2 = @cos(2.0 * w);
        const sin2 = @sin(2.0 * w);

        const num_re = @as(f64, c.b0) + @as(f64, c.b1) * cos1 + @as(f64, c.b2) * cos2;
        const num_im = -@as(f64, c.b1) * sin1 - @as(f64, c.b2) * sin2;
        const den_re = 1.0 + @as(f64, c.a1) * cos1 + @as(f64, c.a2) * cos2;
        const den_im = -@as(f64, c.a1) * sin1 - @as(f64, c.a2) * sin2;

        const num = @sqrt(num_re * num_re + num_im * num_im);
        const den = @sqrt(den_re * den_re + den_im * den_im);
        if (den == 0) return std.math.inf(f64);
        return num / den;
    }

    pub fn magnitudeDbAt(c: Coeffs, freq: f64, sample_rate: u32) f64 {
        const m = c.magnitudeAt(freq, sample_rate);
        if (m <= 1e-12) return -240.0;
        return 20.0 * std.math.log10(m);
    }
};

/// Which kind of response `design` should produce.
pub const Kind = enum {
    peaking,
    low_shelf,
    high_shelf,
    low_pass,
    high_pass,
    band_pass,
    notch,
    all_pass,
};

pub const Design = struct {
    kind: Kind,
    freq: f32,
    /// Quality factor. For shelves this doubles as the slope parameter S.
    q: f32 = 0.7071067811865476,
    /// Gain in dB. Only meaningful for peaking and shelf filters.
    gain_db: f32 = 0,
};

/// Build normalized coefficients. `freq` is clamped into the open interval
/// (0, nyquist) so a nonsensical request degrades into a stable filter rather
/// than producing NaNs on the audio thread.
pub fn design(d: Design, sample_rate: u32) Coeffs {
    const fs: f64 = @floatFromInt(sample_rate);
    if (fs <= 0) return .passthrough;

    const nyquist = fs * 0.5;
    const f0 = std.math.clamp(@as(f64, d.freq), 1.0, nyquist * 0.999);
    const q = @max(@as(f64, d.q), 1e-4);

    const a_gain = std.math.pow(f64, 10.0, @as(f64, d.gain_db) / 40.0);
    const w0 = 2.0 * std.math.pi * f0 / fs;
    const cs = @cos(w0);
    const sn = @sin(w0);
    const alpha = sn / (2.0 * q);

    var b0: f64 = 1;
    var b1: f64 = 0;
    var b2: f64 = 0;
    var a0: f64 = 1;
    var a1: f64 = 0;
    var a2: f64 = 0;

    switch (d.kind) {
        .peaking => {
            b0 = 1 + alpha * a_gain;
            b1 = -2 * cs;
            b2 = 1 - alpha * a_gain;
            a0 = 1 + alpha / a_gain;
            a1 = -2 * cs;
            a2 = 1 - alpha / a_gain;
        },
        .low_shelf, .high_shelf => {
            // `alpha` for shelves uses the slope form; with S == q == 1 this
            // is the steepest shelf that does not overshoot.
            const s = @max(@as(f64, d.q), 1e-4);
            const sh_alpha = (sn / 2.0) * @sqrt((a_gain + 1.0 / a_gain) * (1.0 / s - 1.0) + 2.0);
            const two_sqrt_a_alpha = 2.0 * @sqrt(a_gain) * sh_alpha;
            const ap1 = a_gain + 1.0;
            const am1 = a_gain - 1.0;
            if (d.kind == .low_shelf) {
                b0 = a_gain * (ap1 - am1 * cs + two_sqrt_a_alpha);
                b1 = 2 * a_gain * (am1 - ap1 * cs);
                b2 = a_gain * (ap1 - am1 * cs - two_sqrt_a_alpha);
                a0 = ap1 + am1 * cs + two_sqrt_a_alpha;
                a1 = -2 * (am1 + ap1 * cs);
                a2 = ap1 + am1 * cs - two_sqrt_a_alpha;
            } else {
                b0 = a_gain * (ap1 + am1 * cs + two_sqrt_a_alpha);
                b1 = -2 * a_gain * (am1 + ap1 * cs);
                b2 = a_gain * (ap1 + am1 * cs - two_sqrt_a_alpha);
                a0 = ap1 - am1 * cs + two_sqrt_a_alpha;
                a1 = 2 * (am1 - ap1 * cs);
                a2 = ap1 - am1 * cs - two_sqrt_a_alpha;
            }
        },
        .low_pass => {
            b0 = (1 - cs) / 2;
            b1 = 1 - cs;
            b2 = (1 - cs) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .high_pass => {
            b0 = (1 + cs) / 2;
            b1 = -(1 + cs);
            b2 = (1 + cs) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .band_pass => {
            // Constant 0 dB peak gain.
            b0 = alpha;
            b1 = 0;
            b2 = -alpha;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .notch => {
            b0 = 1;
            b1 = -2 * cs;
            b2 = 1;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .all_pass => {
            b0 = 1 - alpha;
            b1 = -2 * cs;
            b2 = 1 + alpha;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
    }

    if (a0 == 0 or !std.math.isFinite(a0)) return .passthrough;
    return .{
        .b0 = @floatCast(b0 / a0),
        .b1 = @floatCast(b1 / a0),
        .b2 = @floatCast(b2 / a0),
        .a1 = @floatCast(a1 / a0),
        .a2 = @floatCast(a2 / a0),
    };
}

/// A biquad section with independent state for up to `max_channels` channels.
pub fn Section(comptime max_channels: usize) type {
    return struct {
        const Self = @This();

        coeffs: Coeffs = .passthrough,
        s1: [max_channels]f32 = @splat(0),
        s2: [max_channels]f32 = @splat(0),

        pub fn setCoeffs(self: *Self, c: Coeffs) void {
            self.coeffs = c;
        }

        pub fn reset(self: *Self) void {
            self.s1 = @splat(0);
            self.s2 = @splat(0);
        }

        /// Process one sample on `ch`. Transposed direct form II.
        pub fn processSample(self: *Self, ch: usize, x: f32) f32 {
            const c = self.coeffs;
            const y = c.b0 * x + self.s1[ch];
            self.s1[ch] = c.b1 * x - c.a1 * y + self.s2[ch];
            self.s2[ch] = c.b2 * x - c.a2 * y;
            return y;
        }

        /// Process an interleaved block in place.
        pub fn processInterleaved(self: *Self, samples: []f32, channels: usize) void {
            std.debug.assert(channels <= max_channels);
            if (channels == 0) return;
            const frames = samples.len / channels;
            var f: usize = 0;
            while (f < frames) : (f += 1) {
                const frame = samples[f * channels ..][0..channels];
                for (frame, 0..) |*s, ch| s.* = self.processSample(ch, s.*);
            }
        }
    };
}

/// The section type used throughout the player (7.1 is the widest layout we
/// bother to support).
pub const Stereo8 = Section(8);

const testing = std.testing;

test "passthrough preserves the signal" {
    var sec: Stereo8 = .{};
    var buf = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    const want = buf;
    sec.processInterleaved(&buf, 2);
    try testing.expectEqualSlices(f32, &want, &buf);
}

test "peaking filter hits the requested gain at its centre" {
    const sr: u32 = 48_000;
    for ([_]f32{ -12, -6, 3, 9 }) |gain| {
        const c = design(.{ .kind = .peaking, .freq = 1000, .q = 1.0, .gain_db = gain }, sr);
        try testing.expectApproxEqAbs(@as(f64, gain), c.magnitudeDbAt(1000, sr), 0.05);
        // Far from the centre frequency the filter is transparent.
        try testing.expectApproxEqAbs(@as(f64, 0), c.magnitudeDbAt(40, sr), 0.5);
    }
}

test "shelves reach their gain in the band and unity outside" {
    const sr: u32 = 44_100;
    const low = design(.{ .kind = .low_shelf, .freq = 120, .q = 0.9, .gain_db = 6 }, sr);
    try testing.expectApproxEqAbs(@as(f64, 6), low.magnitudeDbAt(20, sr), 0.6);
    try testing.expectApproxEqAbs(@as(f64, 0), low.magnitudeDbAt(10_000, sr), 0.2);

    const high = design(.{ .kind = .high_shelf, .freq = 8000, .q = 0.9, .gain_db = -6 }, sr);
    try testing.expectApproxEqAbs(@as(f64, -6), high.magnitudeDbAt(20_000, sr), 0.6);
    try testing.expectApproxEqAbs(@as(f64, 0), high.magnitudeDbAt(100, sr), 0.2);
}

test "low pass attenuates above the corner" {
    const sr: u32 = 48_000;
    const c = design(.{ .kind = .low_pass, .freq = 1000 }, sr);
    // Butterworth Q gives -3 dB at the corner.
    try testing.expectApproxEqAbs(@as(f64, -3.01), c.magnitudeDbAt(1000, sr), 0.15);
    try testing.expect(c.magnitudeDbAt(8000, sr) < -30.0);
    try testing.expectApproxEqAbs(@as(f64, 0), c.magnitudeDbAt(50, sr), 0.1);
}

test "high pass attenuates below the corner" {
    const sr: u32 = 48_000;
    const c = design(.{ .kind = .high_pass, .freq = 1000 }, sr);
    try testing.expectApproxEqAbs(@as(f64, -3.01), c.magnitudeDbAt(1000, sr), 0.15);
    try testing.expect(c.magnitudeDbAt(100, sr) < -30.0);
}

test "measured response matches the predicted response" {
    // Run a sine through the filter and compare the settled amplitude with
    // what `magnitudeAt` claims it should be.
    const sr: u32 = 48_000;
    const c = design(.{ .kind = .peaking, .freq = 2000, .q = 2.0, .gain_db = 10 }, sr);
    var sec: Stereo8 = .{};
    sec.setCoeffs(c);

    const freq: f64 = 2000;
    const n: usize = 4096;
    var peak: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr));
        const x: f32 = @floatCast(@sin(2.0 * std.math.pi * freq * t));
        const y = sec.processSample(0, x);
        // Skip the transient.
        if (i > n / 2) peak = @max(peak, @abs(y));
    }
    const predicted = c.magnitudeAt(freq, sr);
    try testing.expectApproxEqAbs(predicted, @as(f64, peak), 0.02);
}

test "degenerate requests stay stable" {
    const c = design(.{ .kind = .low_pass, .freq = 1e9, .q = 0 }, 48_000);
    try testing.expect(std.math.isFinite(c.b0));
    try testing.expect(std.math.isFinite(c.a1));
    const zero_rate = design(.{ .kind = .peaking, .freq = 1000 }, 0);
    try testing.expectEqual(@as(f32, 1), zero_rate.b0);
}
