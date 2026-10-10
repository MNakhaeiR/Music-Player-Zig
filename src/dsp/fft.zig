//! In-place iterative radix-2 FFT plus the window functions the spectrum
//! analyzer needs. No allocation happens during a transform; the twiddle
//! factors are computed on the fly from a per-stage rotation, which is plenty
//! accurate for a visualizer and keeps the struct tiny.

const std = @import("std");

pub const Complex = struct {
    re: f32 = 0,
    im: f32 = 0,

    pub fn magnitude(c: Complex) f32 {
        return @sqrt(c.re * c.re + c.im * c.im);
    }

    pub fn magnitudeSquared(c: Complex) f32 {
        return c.re * c.re + c.im * c.im;
    }
};

/// Reverse the low `bits` bits of `x`.
fn reverseBits(x: usize, bits: u6) usize {
    var v = x;
    var r: usize = 0;
    var i: u6 = 0;
    while (i < bits) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

/// Forward FFT of `data`, whose length must be a power of two. The result
/// replaces the input in standard (not bit-reversed) order.
pub fn forward(data: []Complex) void {
    transform(data, false);
}

/// Inverse FFT, scaled by 1/N so `inverse(forward(x)) == x`.
pub fn inverse(data: []Complex) void {
    transform(data, true);
    const scale = 1.0 / @as(f32, @floatFromInt(data.len));
    for (data) |*c| {
        c.re *= scale;
        c.im *= scale;
    }
}

fn transform(data: []Complex, comptime invert: bool) void {
    const n = data.len;
    if (n <= 1) return;
    std.debug.assert(std.math.isPowerOfTwo(n));
    const bits: u6 = @intCast(std.math.log2_int(usize, n));

    // Decimation in time: permute into bit-reversed order first.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const j = reverseBits(i, bits);
        if (j > i) std.mem.swap(Complex, &data[i], &data[j]);
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = (if (invert) 2.0 else -2.0) * std.math.pi / @as(f64, @floatFromInt(len));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var start: usize = 0;
        while (start < n) : (start += len) {
            // Rotate the twiddle factor incrementally within the butterfly.
            var cur_r: f64 = 1;
            var cur_i: f64 = 0;
            var k: usize = 0;
            const half = len / 2;
            while (k < half) : (k += 1) {
                const a = data[start + k];
                const b = data[start + k + half];
                const tr: f32 = @floatCast(@as(f64, b.re) * cur_r - @as(f64, b.im) * cur_i);
                const ti: f32 = @floatCast(@as(f64, b.re) * cur_i + @as(f64, b.im) * cur_r);
                data[start + k] = .{ .re = a.re + tr, .im = a.im + ti };
                data[start + k + half] = .{ .re = a.re - tr, .im = a.im - ti };
                const next_r = cur_r * wr - cur_i * wi;
                cur_i = cur_r * wi + cur_i * wr;
                cur_r = next_r;
            }
        }
    }
}

pub const Window = enum {
    rectangular,
    hann,
    hamming,
    blackman_harris,

    /// Coherent gain, i.e. the mean of the window. Divide a magnitude
    /// spectrum by this to recover the true amplitude of a tone.
    pub fn coherentGain(w: Window) f32 {
        return switch (w) {
            .rectangular => 1.0,
            .hann => 0.5,
            .hamming => 0.54,
            .blackman_harris => 0.35875,
        };
    }
};

/// Fill `out` with `len` window coefficients (periodic form).
pub fn fillWindow(w: Window, out: []f32) void {
    const n = out.len;
    if (n == 0) return;
    const nf: f32 = @floatFromInt(n);
    for (out, 0..) |*v, i| {
        const x = @as(f32, @floatFromInt(i)) / nf;
        const two_pi_x = 2.0 * std.math.pi * x;
        v.* = switch (w) {
            .rectangular => 1.0,
            .hann => 0.5 - 0.5 * @cos(two_pi_x),
            .hamming => 0.54 - 0.46 * @cos(two_pi_x),
            .blackman_harris => 0.35875 -
                0.48829 * @cos(two_pi_x) +
                0.14128 * @cos(2.0 * two_pi_x) -
                0.01168 * @cos(3.0 * two_pi_x),
        };
    }
}

/// Magnitude spectrum of a real signal.
///
/// `scratch` must hold at least `signal.len` complex values and `window` must
/// either be empty or match `signal.len`. Writes `signal.len / 2 + 1` bins
/// into `out`, normalized so a full-scale sine reads 1.0 in its bin.
pub fn realMagnitudeSpectrum(
    signal: []const f32,
    window: []const f32,
    scratch: []Complex,
    out: []f32,
) void {
    const n = signal.len;
    std.debug.assert(scratch.len >= n);
    std.debug.assert(window.len == 0 or window.len == n);
    const bins = @min(out.len, n / 2 + 1);

    for (signal, 0..) |s, i| {
        const w: f32 = if (window.len == 0) 1.0 else window[i];
        scratch[i] = .{ .re = s * w, .im = 0 };
    }
    forward(scratch[0..n]);

    // A real signal of amplitude A puts A*N/2 into its bin, so scale by 2/N.
    const scale = 2.0 / @as(f32, @floatFromInt(n));
    var i: usize = 0;
    while (i < bins) : (i += 1) {
        out[i] = scratch[i].magnitude() * scale;
    }
    // DC and Nyquist are not mirrored, so they must not be doubled.
    if (bins > 0) out[0] *= 0.5;
    if (bins == n / 2 + 1 and bins > 1) out[bins - 1] *= 0.5;
}

const testing = std.testing;

test "forward then inverse is the identity" {
    var data: [64]Complex = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    for (&data) |*c| c.* = .{ .re = rand.float(f32) * 2 - 1, .im = rand.float(f32) * 2 - 1 };
    const original = data;

    forward(&data);
    inverse(&data);
    for (original, data) |want, got| {
        try testing.expectApproxEqAbs(want.re, got.re, 1e-4);
        try testing.expectApproxEqAbs(want.im, got.im, 1e-4);
    }
}

test "impulse transforms to a flat spectrum" {
    var data: [32]Complex = @splat(.{});
    data[0] = .{ .re = 1, .im = 0 };
    forward(&data);
    for (data) |c| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), c.re, 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0.0), c.im, 1e-5);
    }
}

test "DC transforms to a single bin" {
    var data: [16]Complex = @splat(.{ .re = 1, .im = 0 });
    forward(&data);
    try testing.expectApproxEqAbs(@as(f32, 16.0), data[0].re, 1e-4);
    for (data[1..]) |c| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), c.magnitude(), 1e-4);
    }
}

test "a sine lands in the expected bin with the expected amplitude" {
    const n = 1024;
    const sr: f32 = 48_000;
    const bin: usize = 64;
    const freq = @as(f32, @floatFromInt(bin)) * sr / @as(f32, n);

    var signal: [n]f32 = undefined;
    for (&signal, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        s.* = 0.5 * @sin(2.0 * std.math.pi * freq * t);
    }

    var scratch: [n]Complex = undefined;
    var spectrum: [n / 2 + 1]f32 = undefined;
    realMagnitudeSpectrum(&signal, &.{}, &scratch, &spectrum);

    // Amplitude 0.5 with a rectangular window and an exact bin frequency.
    try testing.expectApproxEqAbs(@as(f32, 0.5), spectrum[bin], 1e-3);
    // Neighbouring bins should be essentially empty.
    try testing.expect(spectrum[bin - 4] < 1e-3);
    try testing.expect(spectrum[bin + 4] < 1e-3);
}

test "windowed sine recovers amplitude after correcting for coherent gain" {
    const n = 2048;
    const sr: f32 = 44_100;
    const bin: usize = 100;
    const freq = @as(f32, @floatFromInt(bin)) * sr / @as(f32, n);

    var signal: [n]f32 = undefined;
    for (&signal, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sr;
        s.* = 0.25 * @sin(2.0 * std.math.pi * freq * t);
    }
    var win: [n]f32 = undefined;
    fillWindow(.hann, &win);

    var scratch: [n]Complex = undefined;
    var spectrum: [n / 2 + 1]f32 = undefined;
    realMagnitudeSpectrum(&signal, &win, &scratch, &spectrum);

    const corrected = spectrum[bin] / Window.hann.coherentGain();
    try testing.expectApproxEqAbs(@as(f32, 0.25), corrected, 5e-3);
}

test "window shapes" {
    var win: [8]f32 = undefined;
    fillWindow(.rectangular, &win);
    for (win) |v| try testing.expectEqual(@as(f32, 1.0), v);

    fillWindow(.hann, &win);
    try testing.expectApproxEqAbs(@as(f32, 0.0), win[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), win[4], 1e-6);

    // Every window is non-negative and peaks at or below 1.
    for ([_]Window{ .hamming, .blackman_harris }) |w| {
        fillWindow(w, &win);
        for (win) |v| {
            try testing.expect(v >= -1e-6);
            try testing.expect(v <= 1.0 + 1e-6);
        }
    }
}

test "tiny inputs are handled" {
    var one: [1]Complex = .{.{ .re = 3, .im = 4 }};
    forward(&one);
    try testing.expectEqual(@as(f32, 3), one[0].re);
    var none: [0]Complex = .{};
    forward(&none);
}
