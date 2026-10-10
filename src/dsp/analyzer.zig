//! Spectrum analysis and level metering for the UI.
//!
//! The audio thread must never block, so it only ever does three cheap things
//! here: downmix a block to mono, push it into a wait-free ring, and store
//! peak/RMS values into atomics. All the expensive work — the FFT, the band
//! mapping, the smoothing — happens on the UI thread in `update`, at frame
//! rate rather than at audio rate. If the UI falls behind, the ring simply
//! drops the oldest audio; a visualizer missing a frame is not a glitch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

const fft = @import("fft.zig");
const Ring = @import("../audio/ring.zig").Ring;
const time = @import("../util/time.zig");

/// Dynamic range the bars span, in dB below full scale.
pub const floor_db: f32 = -72.0;

pub const Analyzer = struct {
    gpa: Allocator,
    sample_rate: u32,

    /// Mono audio handed over from the audio thread.
    feed: Ring,

    fft_size: usize,
    window: []f32,
    /// Rolling window of the most recent `fft_size` mono samples.
    history: []f32,
    scratch: []fft.Complex,
    spectrum: []f32,

    /// Smoothed, normalized band levels in 0..1.
    bands: []f32,
    /// Slowly falling peak markers, one per band.
    band_peaks: []f32,

    /// Peak and RMS of the last block, per channel, written by the audio
    /// thread as raw f32 bits.
    peak_bits: [8]Atomic(u32) = @splat(.init(0)),
    rms_bits: [8]Atomic(u32) = @splat(.init(0)),
    channels: Atomic(u8) = .init(2),

    /// Decayed peak markers for the level meters.
    meter_peak_hold: [8]f32 = @splat(0),

    /// How fast bars rise and fall, per `update` call.
    attack: f32 = 0.55,
    decay: f32 = 0.16,
    peak_decay: f32 = 0.012,

    pub fn init(
        gpa: Allocator,
        sample_rate: u32,
        fft_size: usize,
        band_count: usize,
    ) Allocator.Error!Analyzer {
        std.debug.assert(std.math.isPowerOfTwo(fft_size));
        std.debug.assert(band_count >= 1);

        var feed = try Ring.init(gpa, fft_size * 4);
        errdefer feed.deinit(gpa);

        const window = try gpa.alloc(f32, fft_size);
        errdefer gpa.free(window);
        fft.fillWindow(.hann, window);

        const history = try gpa.alloc(f32, fft_size);
        errdefer gpa.free(history);
        @memset(history, 0);

        const scratch = try gpa.alloc(fft.Complex, fft_size);
        errdefer gpa.free(scratch);

        const spectrum = try gpa.alloc(f32, fft_size / 2 + 1);
        errdefer gpa.free(spectrum);
        @memset(spectrum, 0);

        const bands = try gpa.alloc(f32, band_count);
        errdefer gpa.free(bands);
        @memset(bands, 0);

        const band_peaks = try gpa.alloc(f32, band_count);
        errdefer gpa.free(band_peaks);
        @memset(band_peaks, 0);

        return .{
            .gpa = gpa,
            .sample_rate = @max(sample_rate, 1),
            .feed = feed,
            .fft_size = fft_size,
            .window = window,
            .history = history,
            .scratch = scratch,
            .spectrum = spectrum,
            .bands = bands,
            .band_peaks = band_peaks,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.feed.deinit(self.gpa);
        self.gpa.free(self.window);
        self.gpa.free(self.history);
        self.gpa.free(self.scratch);
        self.gpa.free(self.spectrum);
        self.gpa.free(self.bands);
        self.gpa.free(self.band_peaks);
        self.* = undefined;
    }

    pub fn setSampleRate(self: *Analyzer, sample_rate: u32) void {
        self.sample_rate = @max(sample_rate, 1);
    }

    pub fn reset(self: *Analyzer) void {
        self.feed.clear();
        @memset(self.history, 0);
        @memset(self.bands, 0);
        @memset(self.band_peaks, 0);
        @memset(self.spectrum, 0);
        self.meter_peak_hold = @splat(0);
        for (&self.peak_bits) |*p| p.store(0, .monotonic);
        for (&self.rms_bits) |*p| p.store(0, .monotonic);
    }

    /// Audio-thread entry point. Wait-free: no locks, no allocation, and a
    /// bounded amount of work per block.
    pub fn pushAudio(self: *Analyzer, samples: []const f32, channels: usize) void {
        if (channels == 0) return;
        const frames = samples.len / channels;
        if (frames == 0) return;
        self.channels.store(@intCast(@min(channels, 8)), .monotonic);

        // Per-channel peak and mean square for the level meters.
        var peak: [8]f32 = @splat(0);
        var sumsq: [8]f32 = @splat(0);
        const tracked = @min(channels, 8);

        // Downmix to mono in small batches so the ring write stays one call
        // per batch instead of one per frame.
        var batch: [256]f32 = undefined;
        var n: usize = 0;
        const inv_ch = 1.0 / @as(f32, @floatFromInt(channels));

        var f: usize = 0;
        while (f < frames) : (f += 1) {
            const frame = samples[f * channels ..][0..channels];
            var sum: f32 = 0;
            for (frame, 0..) |s, ch| {
                sum += s;
                if (ch < tracked) {
                    const a = @abs(s);
                    peak[ch] = @max(peak[ch], a);
                    sumsq[ch] += s * s;
                }
            }
            batch[n] = sum * inv_ch;
            n += 1;
            if (n == batch.len) {
                _ = self.feed.write(batch[0..n]);
                n = 0;
            }
        }
        if (n > 0) _ = self.feed.write(batch[0..n]);

        const inv_frames = 1.0 / @as(f32, @floatFromInt(frames));
        for (0..tracked) |ch| {
            self.peak_bits[ch].store(@bitCast(peak[ch]), .monotonic);
            self.rms_bits[ch].store(@bitCast(@sqrt(sumsq[ch] * inv_frames)), .monotonic);
        }
    }

    pub fn channelPeak(self: *const Analyzer, ch: usize) f32 {
        if (ch >= 8) return 0;
        return @bitCast(self.peak_bits[ch].load(.monotonic));
    }

    pub fn channelRms(self: *const Analyzer, ch: usize) f32 {
        if (ch >= 8) return 0;
        return @bitCast(self.rms_bits[ch].load(.monotonic));
    }

    pub fn channelCount(self: *const Analyzer) usize {
        return self.channels.load(.monotonic);
    }

    /// Peak hold value for a channel's meter, in 0..1 after dB normalization.
    pub fn meterLevel(self: *const Analyzer, ch: usize) f32 {
        return normalizeDb(self.channelRms(ch));
    }

    pub fn meterPeak(self: *const Analyzer, ch: usize) f32 {
        if (ch >= 8) return 0;
        return self.meter_peak_hold[ch];
    }

    /// UI-thread entry point: drain pending audio, run one FFT and update the
    /// smoothed band values. Returns true if a new transform ran.
    pub fn update(self: *Analyzer) bool {
        // Slide the newest audio into the rolling history window.
        var pending = self.feed.readable();
        var refreshed = false;
        if (pending > 0) {
            // More than a full window is waiting: keep only the newest part.
            if (pending > self.fft_size) {
                _ = self.feed.discard(pending - self.fft_size);
                pending = self.fft_size;
            }
            const keep = self.fft_size - pending;
            if (keep > 0) {
                std.mem.copyForwards(f32, self.history[0..keep], self.history[pending..]);
            }
            _ = self.feed.read(self.history[keep..]);
            refreshed = true;
        }

        fft.realMagnitudeSpectrum(self.history, self.window, self.scratch, self.spectrum);

        const gain_correction = 1.0 / fft.Window.hann.coherentGain();
        const bin_hz = @as(f32, @floatFromInt(self.sample_rate)) /
            @as(f32, @floatFromInt(self.fft_size));

        for (self.bands, 0..) |*band, i| {
            const range = bandRange(i, self.bands.len);
            var lo_bin: usize = @intFromFloat(@max(1.0, @floor(range.lo / bin_hz)));
            var hi_bin: usize = @intFromFloat(@ceil(range.hi / bin_hz));
            lo_bin = @min(lo_bin, self.spectrum.len - 1);
            hi_bin = std.math.clamp(hi_bin, lo_bin + 1, self.spectrum.len);

            // Peak within the band reads better than an average: it keeps
            // narrow tones visible instead of smearing them away.
            var mag: f32 = 0;
            for (self.spectrum[lo_bin..hi_bin]) |m| mag = @max(mag, m);
            mag *= gain_correction;

            const level = normalizeDb(mag);
            const coef = if (level > band.*) self.attack else self.decay;
            band.* += (level - band.*) * coef;
            band.* = std.math.clamp(band.*, 0, 1);

            if (band.* >= self.band_peaks[i]) {
                self.band_peaks[i] = band.*;
            } else {
                self.band_peaks[i] = @max(0, self.band_peaks[i] - self.peak_decay);
            }
        }

        // Level meter peak holds fall at the same slow rate.
        const ch_count = self.channelCount();
        for (0..@min(ch_count, 8)) |ch| {
            const p = normalizeDb(self.channelPeak(ch));
            if (p >= self.meter_peak_hold[ch]) {
                self.meter_peak_hold[ch] = p;
            } else {
                self.meter_peak_hold[ch] = @max(0, self.meter_peak_hold[ch] - self.peak_decay);
            }
        }

        return refreshed;
    }

    pub fn bandLevel(self: *const Analyzer, i: usize) f32 {
        if (i >= self.bands.len) return 0;
        return self.bands[i];
    }

    pub fn bandPeak(self: *const Analyzer, i: usize) f32 {
        if (i >= self.band_peaks.len) return 0;
        return self.band_peaks[i];
    }

    pub fn bandCount(self: *const Analyzer) usize {
        return self.bands.len;
    }
};

/// Lowest and highest frequency covered by band `i` of `n`, log-spaced across
/// the audible range.
pub fn bandRange(i: usize, n: usize) struct { lo: f32, hi: f32 } {
    const lo_hz: f32 = 28.0;
    const hi_hz: f32 = 18_000.0;
    const log_lo = std.math.log2(lo_hz);
    const log_hi = std.math.log2(hi_hz);
    const span = log_hi - log_lo;
    const nf: f32 = @floatFromInt(n);
    const a = log_lo + span * @as(f32, @floatFromInt(i)) / nf;
    const b = log_lo + span * @as(f32, @floatFromInt(i + 1)) / nf;
    return .{
        .lo = std.math.pow(f32, 2.0, a),
        .hi = std.math.pow(f32, 2.0, b),
    };
}

/// Map a linear amplitude onto 0..1 across `floor_db`..0 dBFS.
pub fn normalizeDb(amp: f32) f32 {
    const db = time.amplitudeToDb(amp);
    return std.math.clamp((db - floor_db) / -floor_db, 0, 1);
}

const testing = std.testing;

test "normalizeDb spans the dynamic range" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), normalizeDb(1.0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalizeDb(0.0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), normalizeDb(time.dbToAmplitude(floor_db / 2)), 1e-3);
}

test "band ranges tile the spectrum without gaps" {
    const n = 24;
    var prev_hi: f32 = 0;
    for (0..n) |i| {
        const r = bandRange(i, n);
        try testing.expect(r.hi > r.lo);
        if (i > 0) try testing.expectApproxEqRel(prev_hi, r.lo, 1e-5);
        prev_hi = r.hi;
    }
    try testing.expectApproxEqRel(@as(f32, 28.0), bandRange(0, n).lo, 1e-5);
    try testing.expectApproxEqRel(@as(f32, 18_000.0), bandRange(n - 1, n).hi, 1e-4);
}

test "silence drives every band to zero" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 1024, 20);
    defer an.deinit();

    const silence: [2048]f32 = @splat(0);
    an.pushAudio(&silence, 2);
    for (0..40) |_| _ = an.update();

    for (0..an.bandCount()) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0), an.bandLevel(i), 1e-3);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), an.channelPeak(0), 1e-6);
}

test "a tone lights up the band containing it" {
    const gpa = testing.allocator;
    const sr: u32 = 48_000;
    const bands = 24;
    var an = try Analyzer.init(gpa, sr, 2048, bands);
    defer an.deinit();

    const freq: f32 = 1000.0;
    var block: [4096]f32 = undefined;
    for (0..block.len / 2) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sr));
        const v = 0.9 * @sin(2.0 * std.math.pi * freq * t);
        block[i * 2] = v;
        block[i * 2 + 1] = v;
    }

    // Feed repeatedly so the smoothers settle.
    for (0..30) |_| {
        an.pushAudio(&block, 2);
        _ = an.update();
    }

    // Find which band owns 1 kHz and confirm it is the loudest.
    var target: usize = 0;
    for (0..bands) |i| {
        const r = bandRange(i, bands);
        if (freq >= r.lo and freq < r.hi) target = i;
    }
    try testing.expect(an.bandLevel(target) > 0.8);

    var loudest: usize = 0;
    for (0..bands) |i| {
        if (an.bandLevel(i) > an.bandLevel(loudest)) loudest = i;
    }
    try testing.expectEqual(target, loudest);
}

test "metering reports peak and RMS of a sine" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 512, 12);
    defer an.deinit();

    const frames = 4800;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        const v = 0.8 * @sin(2.0 * std.math.pi * 100.0 * t);
        buf[i * 2] = v;
        buf[i * 2 + 1] = v * 0.5;
    }
    an.pushAudio(buf, 2);

    try testing.expectApproxEqAbs(@as(f32, 0.8), an.channelPeak(0), 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.4), an.channelPeak(1), 0.02);
    // RMS of a sine is its amplitude over sqrt(2).
    try testing.expectApproxEqAbs(@as(f32, 0.8 / std.math.sqrt2), an.channelRms(0), 0.02);
    try testing.expectEqual(@as(usize, 2), an.channelCount());
}

test "bars fall back toward zero once the signal stops" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 512, 16);
    defer an.deinit();

    var loud: [1024]f32 = undefined;
    for (&loud, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        s.* = 0.9 * @sin(2.0 * std.math.pi * 500.0 * t);
    }
    for (0..20) |_| {
        an.pushAudio(&loud, 1);
        _ = an.update();
    }
    var busiest: usize = 0;
    for (0..an.bandCount()) |i| {
        if (an.bandLevel(i) > an.bandLevel(busiest)) busiest = i;
    }
    const lit = an.bandLevel(busiest);
    try testing.expect(lit > 0.5);

    const silence: [1024]f32 = @splat(0);
    for (0..200) |_| {
        an.pushAudio(&silence, 1);
        _ = an.update();
    }
    try testing.expect(an.bandLevel(busiest) < lit * 0.2);
}

test "peak markers hold above the live level then decay" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 512, 8);
    defer an.deinit();

    var loud: [1024]f32 = undefined;
    for (&loud, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        s.* = 0.9 * @sin(2.0 * std.math.pi * 300.0 * t);
    }
    for (0..20) |_| {
        an.pushAudio(&loud, 1);
        _ = an.update();
    }
    var busiest: usize = 0;
    for (0..an.bandCount()) |i| {
        if (an.bandLevel(i) > an.bandLevel(busiest)) busiest = i;
    }
    const held = an.bandPeak(busiest);
    try testing.expect(held > 0.5);

    const silence: [1024]f32 = @splat(0);
    for (0..5) |_| {
        an.pushAudio(&silence, 1);
        _ = an.update();
    }
    // The bar drops faster than the marker.
    try testing.expect(an.bandPeak(busiest) > an.bandLevel(busiest));
    try testing.expect(an.bandPeak(busiest) <= held);
}

test "a slow consumer just drops old audio" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 256, 8);
    defer an.deinit();

    // Push far more than the ring can hold without ever calling update.
    const big = try gpa.alloc(f32, 100_000);
    defer gpa.free(big);
    @memset(big, 0.1);
    an.pushAudio(big, 1);
    // No crash, and the ring is simply full rather than corrupt.
    try testing.expect(an.feed.readable() <= an.feed.capacity());
    _ = an.update();
}

test "reset clears everything" {
    const gpa = testing.allocator;
    var an = try Analyzer.init(gpa, 48_000, 256, 8);
    defer an.deinit();

    var loud: [512]f32 = @splat(0.8);
    an.pushAudio(&loud, 1);
    _ = an.update();
    an.reset();

    try testing.expect(an.feed.isEmpty());
    for (0..an.bandCount()) |i| {
        try testing.expectEqual(@as(f32, 0), an.bandLevel(i));
        try testing.expectEqual(@as(f32, 0), an.bandPeak(i));
    }
    try testing.expectEqual(@as(f32, 0), an.channelPeak(0));
}
