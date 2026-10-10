//! A look-ahead brickwall peak limiter — the last thing in the chain.
//!
//! EQ boosts and resampler overshoot can push a stream past full scale, where
//! the hardware would clip it into harsh distortion. The limiter sees peaks
//! coming before they reach the output (it delays the audio by the look-ahead
//! window) and rides the gain down smoothly in advance, so loud passages stay
//! under the ceiling without an audible edge.
//!
//! The sliding-window maximum uses a monotonic deque, so tracking the upcoming
//! peak costs O(1) amortized per frame regardless of the window size.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Limiter = struct {
    gpa: Allocator,
    channels: usize,
    sample_rate: u32,

    /// Ceiling as a linear amplitude (0.98 ~= -0.18 dBFS).
    ceiling: f32 = 0.98,
    enabled: bool = true,

    /// Interleaved delay line holding the look-ahead window.
    delay: []f32,
    delay_frames: usize,
    delay_pos: usize = 0,

    /// Monotonic deque over the upcoming frame peaks.
    dq_val: []f32,
    dq_pos: []u64,
    dq_head: usize = 0,
    dq_tail: usize = 0,
    frame_counter: u64 = 0,

    /// Smoothed gain reduction, 1.0 meaning "not limiting".
    gain: f32 = 1.0,
    attack_coef: f32 = 0,
    release_coef: f32 = 0,

    /// Largest reduction applied since the last `takeReduction`, for metering.
    max_reduction: f32 = 1.0,

    pub const lookahead_ms: f32 = 2.0;
    pub const release_ms: f32 = 60.0;

    pub fn init(
        gpa: Allocator,
        sample_rate: u32,
        channels: usize,
    ) Allocator.Error!Limiter {
        std.debug.assert(channels >= 1);
        const sr = @max(sample_rate, 1);
        const frames = @max(2, @as(usize, @intFromFloat(
            lookahead_ms * 0.001 * @as(f32, @floatFromInt(sr)),
        )));

        const delay = try gpa.alloc(f32, frames * channels);
        errdefer gpa.free(delay);
        @memset(delay, 0);

        // One slot per window position, plus one so head != tail stays an
        // unambiguous "non-empty" test.
        const dq_val = try gpa.alloc(f32, frames + 2);
        errdefer gpa.free(dq_val);
        const dq_pos = try gpa.alloc(u64, frames + 2);
        errdefer gpa.free(dq_pos);

        var self: Limiter = .{
            .gpa = gpa,
            .channels = channels,
            .sample_rate = sr,
            .delay = delay,
            .delay_frames = frames,
            .dq_val = dq_val,
            .dq_pos = dq_pos,
        };
        self.updateCoeffs();
        return self;
    }

    pub fn deinit(self: *Limiter) void {
        self.gpa.free(self.delay);
        self.gpa.free(self.dq_val);
        self.gpa.free(self.dq_pos);
        self.* = undefined;
    }

    /// Rebuild for a new rate or channel count. Reallocates, so call it off
    /// the audio thread.
    pub fn reconfigure(
        self: *Limiter,
        sample_rate: u32,
        channels: usize,
    ) Allocator.Error!void {
        if (self.sample_rate == sample_rate and self.channels == channels) {
            self.reset();
            return;
        }
        const gpa = self.gpa;
        const ceiling = self.ceiling;
        const enabled = self.enabled;
        var fresh = try Limiter.init(gpa, sample_rate, channels);
        fresh.ceiling = ceiling;
        fresh.enabled = enabled;
        self.deinit();
        self.* = fresh;
    }

    fn updateCoeffs(self: *Limiter) void {
        const sr: f32 = @floatFromInt(self.sample_rate);
        // Attack spans the look-ahead window so the gain is fully down by the
        // time the peak arrives at the output.
        const attack_samples = @max(1.0, lookahead_ms * 0.001 * sr);
        self.attack_coef = 1.0 - std.math.exp(-5.0 / attack_samples);
        const release_samples = @max(1.0, release_ms * 0.001 * sr);
        self.release_coef = 1.0 - std.math.exp(-5.0 / release_samples);
    }

    pub fn setCeilingDb(self: *Limiter, db: f32) void {
        const clamped = std.math.clamp(db, -24.0, 0.0);
        self.ceiling = std.math.pow(f32, 10.0, clamped / 20.0);
    }

    pub fn ceilingDb(self: *const Limiter) f32 {
        return 20.0 * std.math.log10(@max(self.ceiling, 1e-6));
    }

    pub fn reset(self: *Limiter) void {
        @memset(self.delay, 0);
        self.delay_pos = 0;
        self.dq_head = 0;
        self.dq_tail = 0;
        self.frame_counter = 0;
        self.gain = 1.0;
        self.max_reduction = 1.0;
    }

    /// Latency the limiter adds, in frames.
    pub fn latencyFrames(self: *const Limiter) usize {
        return if (self.enabled) self.delay_frames else 0;
    }

    /// Peak gain reduction since the last call, as a linear multiplier.
    pub fn takeReduction(self: *Limiter) f32 {
        const r = self.max_reduction;
        self.max_reduction = 1.0;
        return r;
    }

    fn pushPeak(self: *Limiter, value: f32) void {
        const cap = self.dq_val.len;
        // Drop any pending peaks this one dominates; they can never be the
        // window maximum again.
        while (self.dq_tail != self.dq_head) {
            const last = (self.dq_tail + cap - 1) % cap;
            if (self.dq_val[last] <= value) {
                self.dq_tail = last;
            } else break;
        }
        self.dq_val[self.dq_tail] = value;
        self.dq_pos[self.dq_tail] = self.frame_counter;
        self.dq_tail = (self.dq_tail + 1) % cap;

        // Expire anything that has fallen out of the window. The window spans
        // `delay_frames + 1` frames: the frame about to be emitted plus every
        // frame still sitting in the delay line. Leaving out the emitted frame
        // would mean riding the gain for peaks that have already gone past.
        const oldest_valid = self.frame_counter -| self.delay_frames;
        while (self.dq_head != self.dq_tail and self.dq_pos[self.dq_head] < oldest_valid) {
            self.dq_head = (self.dq_head + 1) % cap;
        }
    }

    fn windowPeak(self: *const Limiter) f32 {
        if (self.dq_head == self.dq_tail) return 0;
        return self.dq_val[self.dq_head];
    }

    /// Process an interleaved block in place.
    ///
    /// The output lags the input by `latencyFrames()`; that delay is constant,
    /// so it only shifts the whole stream rather than distorting it.
    pub fn process(self: *Limiter, samples: []f32, channels: usize) void {
        if (channels != self.channels or channels == 0) return;
        if (!self.enabled) return;

        const frames = samples.len / channels;
        var f: usize = 0;
        while (f < frames) : (f += 1) {
            const frame = samples[f * channels ..][0..channels];

            // Peak of the incoming frame feeds the look-ahead window.
            var peak: f32 = 0;
            for (frame) |s| peak = @max(peak, @abs(s));
            self.pushPeak(peak);

            // Swap the incoming frame into the delay line, taking out the
            // frame that is now due.
            const slot = self.delay[self.delay_pos * channels ..][0..channels];
            var out: [8]f32 = undefined;
            const n = @min(channels, out.len);
            @memcpy(out[0..n], slot[0..n]);
            @memcpy(slot, frame);
            self.delay_pos = (self.delay_pos + 1) % self.delay_frames;

            // Target gain needed to hold the loudest peak in the window under
            // the ceiling.
            const upcoming = self.windowPeak();
            const target: f32 = if (upcoming > self.ceiling)
                self.ceiling / upcoming
            else
                1.0;

            // Clamp down quickly, recover slowly.
            const coef = if (target < self.gain) self.attack_coef else self.release_coef;
            self.gain += (target - self.gain) * coef;
            self.gain = std.math.clamp(self.gain, 0.0, 1.0);

            // The smoother is only asymptotic, so on its own it would let a
            // sample slip over the ceiling. Take the stricter of the smoothed
            // gain and the exact gain this frame needs: the look-ahead has
            // already walked the smoother down to roughly the right value, so
            // this bound almost never binds and the result is still a smooth
            // envelope — but the ceiling becomes a guarantee rather than a
            // target.
            var out_peak: f32 = 0;
            for (out[0..n]) |v| out_peak = @max(out_peak, @abs(v));
            const exact: f32 = if (out_peak > self.ceiling) self.ceiling / out_peak else 1.0;
            const applied = @min(self.gain, exact);
            self.max_reduction = @min(self.max_reduction, applied);

            for (frame, 0..) |*s, ch| {
                s.* = (if (ch < n) out[ch] else 0) * applied;
            }

            self.frame_counter += 1;
        }
    }
};

const testing = std.testing;

test "quiet material passes through untouched apart from the delay" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 2);
    defer lim.deinit();

    const frames = 4096;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        const v: f32 = @floatCast(0.3 * @sin(2.0 * std.math.pi * 440.0 * t));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }
    const original = try gpa.dupe(f32, buf);
    defer gpa.free(original);

    lim.process(buf, 2);

    // Gain never moved off unity, and the output is the input delayed.
    try testing.expectApproxEqAbs(@as(f32, 1.0), lim.gain, 1e-6);
    const d = lim.latencyFrames();
    for (d..frames) |i| {
        try testing.expectApproxEqAbs(original[(i - d) * 2], buf[i * 2], 1e-6);
    }
}

test "a hot signal is held under the ceiling" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 2);
    defer lim.deinit();
    lim.ceiling = 0.9;

    const frames = 48_000;
    const buf = try gpa.alloc(f32, frames * 2);
    defer gpa.free(buf);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        // Twice full scale.
        const v: f32 = @floatCast(2.0 * @sin(2.0 * std.math.pi * 220.0 * t));
        buf[i * 2] = v;
        buf[i * 2 + 1] = v;
    }

    lim.process(buf, 2);

    // Allow the first few look-ahead windows to settle, then nothing may
    // exceed the ceiling.
    var peak: f32 = 0;
    for (buf[lim.latencyFrames() * 2 ..]) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak <= 0.9 + 1e-4);
    // And it should actually be working, not just muting everything.
    try testing.expect(peak > 0.8);
}

test "look-ahead catches a transient before it lands" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 1);
    defer lim.deinit();
    lim.ceiling = 0.5;

    const frames = 2048;
    const buf = try gpa.alloc(f32, frames);
    defer gpa.free(buf);
    @memset(buf, 0.1);
    // A single enormous spike well past the start.
    buf[1000] = 4.0;

    lim.process(buf, 1);

    var peak: f32 = 0;
    for (buf) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak <= 0.5 + 1e-4);
}

test "gain recovers after the loud part ends" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 1);
    defer lim.deinit();
    lim.ceiling = 0.5;

    const loud = try gpa.alloc(f32, 4800);
    defer gpa.free(loud);
    @memset(loud, 2.0);
    lim.process(loud, 1);
    try testing.expect(lim.gain < 0.3);

    // A quarter second of near-silence is plenty for a 60 ms release.
    const quiet = try gpa.alloc(f32, 12_000);
    defer gpa.free(quiet);
    @memset(quiet, 0.01);
    lim.process(quiet, 1);
    try testing.expect(lim.gain > 0.99);
}

test "disabled limiter is a true no-op" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 1);
    defer lim.deinit();
    lim.enabled = false;

    var buf = [_]f32{ 3.0, -3.0, 0.5 };
    const want = buf;
    lim.process(&buf, 1);
    try testing.expectEqualSlices(f32, &want, &buf);
    try testing.expectEqual(@as(usize, 0), lim.latencyFrames());
}

test "reduction metering reports and then clears" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 1);
    defer lim.deinit();
    lim.ceiling = 0.5;

    const buf = try gpa.alloc(f32, 2400);
    defer gpa.free(buf);
    @memset(buf, 2.0);
    lim.process(buf, 1);

    const r = lim.takeReduction();
    try testing.expect(r < 0.5);
    try testing.expectEqual(@as(f32, 1.0), lim.takeReduction());
}

test "ceiling setter and getter agree" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 48_000, 2);
    defer lim.deinit();
    lim.setCeilingDb(-3.0);
    try testing.expectApproxEqAbs(@as(f32, -3.0), lim.ceilingDb(), 1e-3);
    lim.setCeilingDb(-100.0); // clamps
    try testing.expectApproxEqAbs(@as(f32, -24.0), lim.ceilingDb(), 1e-3);
}

test "reconfiguring keeps settings and resizes the window" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 44_100, 2);
    defer lim.deinit();
    lim.setCeilingDb(-6.0);
    const before = lim.delay_frames;

    try lim.reconfigure(96_000, 2);
    try testing.expect(lim.delay_frames > before);
    try testing.expectApproxEqAbs(@as(f32, -6.0), lim.ceilingDb(), 1e-3);
    try testing.expectEqual(@as(u32, 96_000), lim.sample_rate);
}

test "sliding window maximum matches a brute force scan" {
    const gpa = testing.allocator;
    var lim = try Limiter.init(gpa, 8_000, 1); // 2 ms -> 16 frames
    defer lim.deinit();
    // The window is the emitted frame plus everything in the delay line.
    const w = lim.delay_frames + 1;

    var prng = std.Random.DefaultPrng.init(0xabcdef);
    const rand = prng.random();
    var history: [512]f32 = undefined;

    for (0..history.len) |i| {
        const v = rand.float(f32);
        history[i] = v;
        lim.pushPeak(v);

        const start = if (i + 1 > w) i + 1 - w else 0;
        var want: f32 = 0;
        for (history[start .. i + 1]) |h| want = @max(want, h);
        try testing.expectEqual(want, lim.windowPeak());

        lim.frame_counter += 1;
    }
}
