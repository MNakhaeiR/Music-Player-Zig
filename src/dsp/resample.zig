//! Streaming sample-rate conversion with a polyphase windowed-sinc kernel.
//!
//! The coefficient table is built once per rate change: `phases` sub-filters
//! of `taps` coefficients each. Output positions advance through the input in
//! Q32 fixed point, so even a wildly irrational ratio such as 44100 -> 48000
//! never accumulates drift.
//!
//! When downsampling, the kernel's cutoff is lowered to the output Nyquist so
//! nothing aliases back into the audible band.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Quality = enum {
    /// 16 taps — cheap, fine for a visualizer or a preview.
    low,
    /// 32 taps — the default; transparent for music playback.
    medium,
    /// 64 taps — archival-grade conversion.
    high,

    pub fn taps(q: Quality) usize {
        return switch (q) {
            .low => 16,
            .medium => 32,
            .high => 64,
        };
    }

    pub fn phases(q: Quality) usize {
        return switch (q) {
            .low => 128,
            .medium => 256,
            .high => 512,
        };
    }

    pub fn label(q: Quality) []const u8 {
        return switch (q) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const Result = struct {
    /// Input frames consumed from the caller's buffer.
    consumed: usize,
    /// Output frames written.
    produced: usize,
};

pub const Resampler = struct {
    gpa: Allocator,
    in_rate: u32,
    out_rate: u32,
    channels: usize,
    quality: Quality,

    /// `phases * taps` coefficients, phase-major.
    table: []f32,
    taps: usize,
    phases: usize,
    phase_shift: u6,

    /// History + pending input, interleaved. Holds `taps + chunk` frames.
    buf: []f32,
    buf_frames: usize,
    capacity_frames: usize,

    /// Position within `buf`, in Q32 frames.
    pos: u64,
    /// Input frames per output frame, in Q32.
    step: u64,

    /// True when input and output rates match and we can memcpy.
    bypass: bool,

    const q32: u64 = 1 << 32;
    /// Frames of fresh input accepted per `process` call.
    const chunk_frames: usize = 2048;

    pub fn init(
        gpa: Allocator,
        in_rate: u32,
        out_rate: u32,
        channels: usize,
        quality: Quality,
    ) Allocator.Error!Resampler {
        std.debug.assert(channels >= 1);
        const taps = quality.taps();
        const phases = quality.phases();
        const phase_shift: u6 = @intCast(32 - std.math.log2_int(usize, phases));

        const table = try gpa.alloc(f32, taps * phases);
        errdefer gpa.free(table);

        const capacity_frames = taps + chunk_frames;
        const buf = try gpa.alloc(f32, capacity_frames * channels);
        errdefer gpa.free(buf);

        var self: Resampler = .{
            .gpa = gpa,
            .in_rate = in_rate,
            .out_rate = out_rate,
            .channels = channels,
            .quality = quality,
            .table = table,
            .taps = taps,
            .phases = phases,
            .phase_shift = phase_shift,
            .buf = buf,
            .buf_frames = 0,
            .capacity_frames = capacity_frames,
            .pos = 0,
            .step = q32,
            .bypass = false,
        };
        self.configure(in_rate, out_rate);
        return self;
    }

    pub fn deinit(self: *Resampler) void {
        self.gpa.free(self.table);
        self.gpa.free(self.buf);
        self.* = undefined;
    }

    /// Point the resampler at a new rate pair, rebuilding the kernel and
    /// clearing the history.
    pub fn configure(self: *Resampler, in_rate: u32, out_rate: u32) void {
        self.in_rate = @max(in_rate, 1);
        self.out_rate = @max(out_rate, 1);
        self.bypass = self.in_rate == self.out_rate;
        self.step = @intCast((@as(u64, self.in_rate) * q32) / @as(u64, self.out_rate));
        self.buildTable();
        self.reset();
    }

    pub fn setQuality(self: *Resampler, quality: Quality) Allocator.Error!void {
        if (quality == self.quality) return;
        const taps = quality.taps();
        const phases = quality.phases();
        const table = try self.gpa.alloc(f32, taps * phases);
        const capacity_frames = taps + chunk_frames;
        const buf = try self.gpa.alloc(f32, capacity_frames * self.channels);

        self.gpa.free(self.table);
        self.gpa.free(self.buf);
        self.table = table;
        self.buf = buf;
        self.taps = taps;
        self.phases = phases;
        self.phase_shift = @intCast(32 - std.math.log2_int(usize, phases));
        self.capacity_frames = capacity_frames;
        self.quality = quality;
        self.buildTable();
        self.reset();
    }

    pub fn reset(self: *Resampler) void {
        @memset(self.buf, 0);
        // Pre-load `taps` frames of silence so the very first output has a
        // full window of history behind it.
        self.buf_frames = self.taps;
        self.pos = @as(u64, self.half() - 1) * q32;
    }

    fn half(self: *const Resampler) usize {
        return self.taps / 2;
    }

    /// Latency introduced by the kernel, in output frames.
    pub fn latencyFrames(self: *const Resampler) usize {
        if (self.bypass) return 0;
        const in_latency = self.half();
        return in_latency * self.out_rate / self.in_rate;
    }

    fn buildTable(self: *Resampler) void {
        const taps_f: f64 = @floatFromInt(self.taps);
        const h = self.half();
        // Leave a little transition band so the passband stays flat.
        const ratio = @as(f64, @floatFromInt(self.out_rate)) / @as(f64, @floatFromInt(self.in_rate));
        const cutoff = @min(1.0, ratio) * 0.92;

        var p: usize = 0;
        while (p < self.phases) : (p += 1) {
            const frac = @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(self.phases));
            const row = self.table[p * self.taps ..][0..self.taps];
            var sum: f64 = 0;
            var j: usize = 0;
            while (j < self.taps) : (j += 1) {
                // Tap j covers input offset k = j - (half - 1) relative to
                // floor(position); the sample sits at distance (k - frac).
                const k = @as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(h - 1));
                const x = k - frac;
                // Blackman window over the kernel's full span.
                const wpos = (x + @as(f64, @floatFromInt(h))) / taps_f;
                const w = if (wpos <= 0 or wpos >= 1)
                    0.0
                else
                    0.42 - 0.5 * @cos(2.0 * std.math.pi * wpos) +
                        0.08 * @cos(4.0 * std.math.pi * wpos);
                const v = cutoff * sinc(cutoff * x) * w;
                row[j] = @floatCast(v);
                sum += v;
            }
            // Normalize for unity DC gain so steady signals keep their level.
            if (sum > 1e-9) {
                const inv: f32 = @floatCast(1.0 / sum);
                for (row) |*c| c.* *= inv;
            }
        }
    }

    fn sinc(x: f64) f64 {
        if (@abs(x) < 1e-9) return 1.0;
        const pix = std.math.pi * x;
        return @sin(pix) / pix;
    }

    /// Estimate the output frames a given input length will produce. Useful
    /// for sizing buffers; the real count can differ by one.
    pub fn estimateOutputFrames(self: *const Resampler, in_frames: usize) usize {
        if (self.bypass) return in_frames;
        const n = (@as(u64, in_frames) * @as(u64, self.out_rate)) / @as(u64, self.in_rate);
        return @intCast(n + 2);
    }

    /// Convert as much of `input` as fits in `output`.
    ///
    /// Both buffers are interleaved with `self.channels` channels. Call
    /// repeatedly until `consumed` reaches your input length; a single call
    /// takes at most `chunk_frames` of new input.
    pub fn process(self: *Resampler, input: []const f32, output: []f32) Result {
        const ch = self.channels;
        const in_frames = input.len / ch;
        const out_capacity = output.len / ch;
        if (out_capacity == 0) return .{ .consumed = 0, .produced = 0 };

        if (self.bypass) {
            const n = @min(in_frames, out_capacity);
            @memcpy(output[0 .. n * ch], input[0 .. n * ch]);
            return .{ .consumed = n, .produced = n };
        }

        // Append what we can of the new input to the working buffer.
        const room = self.capacity_frames - self.buf_frames;
        const take = @min(in_frames, room);
        if (take > 0) {
            @memcpy(self.buf[self.buf_frames * ch ..][0 .. take * ch], input[0 .. take * ch]);
            self.buf_frames += take;
        }

        const h = self.half();
        var produced: usize = 0;
        // The window needs indices [i - (h-1), i + h], so stop once i + h
        // would run past the data we hold.
        while (produced < out_capacity) {
            const i: usize = @intCast(self.pos >> 32);
            if (i + h >= self.buf_frames) break;

            const phase: usize = @intCast((self.pos >> self.phase_shift) & (self.phases - 1));
            const row = self.table[phase * self.taps ..][0..self.taps];
            const base = (i + 1 - h) * ch;

            var c: usize = 0;
            while (c < ch) : (c += 1) {
                var acc: f32 = 0;
                var j: usize = 0;
                while (j < self.taps) : (j += 1) {
                    acc += row[j] * self.buf[base + j * ch + c];
                }
                output[produced * ch + c] = acc;
            }
            produced += 1;
            self.pos += self.step;
        }

        // Retire the history we no longer need.
        const i_now: usize = @intCast(self.pos >> 32);
        if (i_now >= h - 1) {
            const keep_from = i_now - (h - 1);
            if (keep_from > 0) {
                const remaining = self.buf_frames - keep_from;
                std.mem.copyForwards(
                    f32,
                    self.buf[0 .. remaining * ch],
                    self.buf[keep_from * ch .. self.buf_frames * ch],
                );
                self.buf_frames = remaining;
                self.pos -= @as(u64, keep_from) * q32;
            }
        }

        return .{ .consumed = take, .produced = produced };
    }

    /// Push silence through the filter to flush the tail of a finished stream.
    pub fn drain(self: *Resampler, output: []f32) usize {
        if (self.bypass) return 0;
        const ch = self.channels;
        const pad_frames = self.taps;
        const room = self.capacity_frames - self.buf_frames;
        const pad = @min(pad_frames, room);
        if (pad > 0) {
            @memset(self.buf[self.buf_frames * ch ..][0 .. pad * ch], 0);
            self.buf_frames += pad;
        }
        const res = self.process(&.{}, output);
        return res.produced;
    }
};

const testing = std.testing;

test "matching rates bypass the filter" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 48_000, 48_000, 2, .medium);
    defer rs.deinit();
    try testing.expect(rs.bypass);

    const in = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var out: [6]f32 = undefined;
    const res = rs.process(&in, &out);
    try testing.expectEqual(@as(usize, 3), res.consumed);
    try testing.expectEqual(@as(usize, 3), res.produced);
    try testing.expectEqualSlices(f32, &in, &out);
}

test "upsampling produces roughly the expected frame count" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 44_100, 48_000, 1, .medium);
    defer rs.deinit();

    const in_frames = 4410;
    const in = try gpa.alloc(f32, in_frames);
    defer gpa.free(in);
    @memset(in, 0);

    const out = try gpa.alloc(f32, 8192);
    defer gpa.free(out);

    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < in_frames) {
        const res = rs.process(in[consumed..], out[produced..]);
        if (res.consumed == 0 and res.produced == 0) break;
        consumed += res.consumed;
        produced += res.produced;
    }
    // 4410 input frames at 44.1k -> ~4800 output frames at 48k.
    try testing.expect(produced > 4700);
    try testing.expect(produced < 4900);
}

test "DC survives conversion at unity gain" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 44_100, 48_000, 1, .high);
    defer rs.deinit();

    const in = try gpa.alloc(f32, 8192);
    defer gpa.free(in);
    @memset(in, 0.5);

    const out = try gpa.alloc(f32, 16384);
    defer gpa.free(out);

    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < in.len) {
        const res = rs.process(in[consumed..], out[produced..]);
        if (res.consumed == 0 and res.produced == 0) break;
        consumed += res.consumed;
        produced += res.produced;
    }
    try testing.expect(produced > 1000);
    // Skip the leading ramp where the window still straddles the primed
    // silence, then the output should sit on the input level.
    const settled = out[rs.taps * 2 .. produced];
    for (settled) |v| try testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-3);
}

test "a sine keeps its amplitude and frequency through conversion" {
    const gpa = testing.allocator;
    const in_rate: u32 = 48_000;
    const out_rate: u32 = 44_100;
    var rs = try Resampler.init(gpa, in_rate, out_rate, 1, .high);
    defer rs.deinit();

    const freq: f64 = 1000.0;
    const in_frames: usize = 48_000;
    const in = try gpa.alloc(f32, in_frames);
    defer gpa.free(in);
    for (in, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(in_rate));
        s.* = @floatCast(0.5 * @sin(2.0 * std.math.pi * freq * t));
    }

    const out = try gpa.alloc(f32, 64_000);
    defer gpa.free(out);

    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < in_frames) {
        const res = rs.process(in[consumed..], out[produced..]);
        if (res.consumed == 0 and res.produced == 0) break;
        consumed += res.consumed;
        produced += res.produced;
    }
    try testing.expect(produced > 40_000);

    // Amplitude should be preserved once past the startup transient.
    const settled = out[500 .. produced - 10];
    var peak: f32 = 0;
    for (settled) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);

    // Count zero crossings to confirm the frequency came through intact.
    var crossings: usize = 0;
    for (settled[1..], 0..) |v, i| {
        if ((settled[i] < 0) != (v < 0)) crossings += 1;
    }
    const seconds = @as(f64, @floatFromInt(settled.len)) / @as(f64, @floatFromInt(out_rate));
    const measured = @as(f64, @floatFromInt(crossings)) / (2.0 * seconds);
    try testing.expectApproxEqAbs(freq, measured, 2.0);
}

test "downsampling suppresses content above the new Nyquist" {
    const gpa = testing.allocator;
    const in_rate: u32 = 96_000;
    const out_rate: u32 = 24_000; // Nyquist drops to 12 kHz
    var rs = try Resampler.init(gpa, in_rate, out_rate, 1, .high);
    defer rs.deinit();

    // A 20 kHz tone cannot be represented at 24 kHz and must be filtered out
    // rather than folded down to 4 kHz.
    const in_frames: usize = 96_000;
    const in = try gpa.alloc(f32, in_frames);
    defer gpa.free(in);
    for (in, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(in_rate));
        s.* = @floatCast(@sin(2.0 * std.math.pi * 20_000.0 * t));
    }

    const out = try gpa.alloc(f32, 32_000);
    defer gpa.free(out);

    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < in_frames) {
        const res = rs.process(in[consumed..], out[produced..]);
        if (res.consumed == 0 and res.produced == 0) break;
        consumed += res.consumed;
        produced += res.produced;
    }

    var peak: f32 = 0;
    for (out[200 .. produced - 10]) |v| peak = @max(peak, @abs(v));
    // Better than 40 dB of rejection on the out-of-band tone.
    try testing.expect(peak < 0.01);
}

test "stereo channels stay independent" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 22_050, 44_100, 2, .medium);
    defer rs.deinit();

    const in_frames = 2048;
    const in = try gpa.alloc(f32, in_frames * 2);
    defer gpa.free(in);
    for (0..in_frames) |i| {
        in[i * 2] = 0.8; // left is a constant
        in[i * 2 + 1] = -0.4; // right is a different constant
    }

    const out = try gpa.alloc(f32, 8192 * 2);
    defer gpa.free(out);

    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < in_frames) {
        const res = rs.process(in[consumed * 2 ..], out[produced * 2 ..]);
        if (res.consumed == 0 and res.produced == 0) break;
        consumed += res.consumed;
        produced += res.produced;
    }
    try testing.expect(produced > 3000);
    for (rs.taps * 2..produced - 1) |f| {
        try testing.expectApproxEqAbs(@as(f32, 0.8), out[f * 2], 1e-3);
        try testing.expectApproxEqAbs(@as(f32, -0.4), out[f * 2 + 1], 1e-3);
    }
}

test "reconfiguring switches rates cleanly" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 44_100, 48_000, 2, .low);
    defer rs.deinit();
    try testing.expect(!rs.bypass);
    rs.configure(48_000, 48_000);
    try testing.expect(rs.bypass);
    rs.configure(8_000, 48_000);
    try testing.expect(!rs.bypass);
    try testing.expectEqual(@as(u32, 8_000), rs.in_rate);
}

test "quality changes rebuild the kernel" {
    const gpa = testing.allocator;
    var rs = try Resampler.init(gpa, 44_100, 48_000, 1, .low);
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 16), rs.taps);
    try rs.setQuality(.high);
    try testing.expectEqual(@as(usize, 64), rs.taps);
    try testing.expectEqual(@as(usize, 512), rs.phases);
    try testing.expectEqual(rs.taps * rs.phases, rs.table.len);
}
