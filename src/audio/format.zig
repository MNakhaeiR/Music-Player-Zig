//! Sample formats and conversion to the player's canonical representation:
//! interleaved 32-bit float, nominally in [-1, 1].

const std = @import("std");

/// Every storage format the decoders can hand back.
pub const SampleFormat = enum {
    u8_pcm,
    i16_pcm,
    i24_pcm,
    i32_pcm,
    f32_le,
    f64_le,

    pub fn bytesPerSample(f: SampleFormat) u8 {
        return switch (f) {
            .u8_pcm => 1,
            .i16_pcm => 2,
            .i24_pcm => 3,
            .i32_pcm => 4,
            .f32_le => 4,
            .f64_le => 8,
        };
    }

    pub fn label(f: SampleFormat) []const u8 {
        return switch (f) {
            .u8_pcm => "u8",
            .i16_pcm => "s16",
            .i24_pcm => "s24",
            .i32_pcm => "s32",
            .f32_le => "f32",
            .f64_le => "f64",
        };
    }
};

/// Describes a stream of interleaved frames.
pub const StreamFormat = struct {
    sample_rate: u32,
    channels: u8,

    pub fn eql(a: StreamFormat, b: StreamFormat) bool {
        return a.sample_rate == b.sample_rate and a.channels == b.channels;
    }
};

/// Decode `in` (packed little-endian samples of `fmt`) into normalized floats.
/// Returns the number of samples written, limited by the shorter of the two
/// buffers.
pub fn decodeToFloat(fmt: SampleFormat, in: []const u8, out: []f32) usize {
    const stride = fmt.bytesPerSample();
    const n = @min(in.len / stride, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const raw = in[i * stride ..][0..stride];
        out[i] = switch (fmt) {
            .u8_pcm => (@as(f32, @floatFromInt(raw[0])) - 128.0) / 128.0,
            .i16_pcm => blk: {
                const v = std.mem.readInt(i16, raw[0..2], .little);
                break :blk @as(f32, @floatFromInt(v)) / 32768.0;
            },
            .i24_pcm => blk: {
                // Sign-extend the 24-bit little-endian value.
                const bits: u24 = @as(u24, raw[0]) |
                    (@as(u24, raw[1]) << 8) |
                    (@as(u24, raw[2]) << 16);
                const v: i24 = @bitCast(bits);
                break :blk @as(f32, @floatFromInt(v)) / 8388608.0;
            },
            .i32_pcm => blk: {
                const v = std.mem.readInt(i32, raw[0..4], .little);
                break :blk @as(f32, @floatFromInt(v)) / 2147483648.0;
            },
            .f32_le => @bitCast(std.mem.readInt(u32, raw[0..4], .little)),
            .f64_le => blk: {
                const v: f64 = @bitCast(std.mem.readInt(u64, raw[0..8], .little));
                break :blk @floatCast(v);
            },
        };
    }
    return n;
}

/// Encode normalized floats back into `fmt`, with hard clipping at full scale.
/// Returns bytes written.
pub fn encodeFromFloat(fmt: SampleFormat, in: []const f32, out: []u8) usize {
    const stride = fmt.bytesPerSample();
    const n = @min(in.len, out.len / stride);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dst = out[i * stride ..][0..stride];
        const x = std.math.clamp(in[i], -1.0, 1.0);
        switch (fmt) {
            .u8_pcm => dst[0] = @intFromFloat(@round(x * 127.0) + 128.0),
            .i16_pcm => std.mem.writeInt(i16, dst[0..2], clampRound(i16, x * 32767.0), .little),
            .i24_pcm => {
                const v = clampRound(i32, x * 8388607.0);
                const bits: u24 = @bitCast(@as(i24, @intCast(v)));
                dst[0] = @truncate(bits);
                dst[1] = @truncate(bits >> 8);
                dst[2] = @truncate(bits >> 16);
            },
            .i32_pcm => std.mem.writeInt(i32, dst[0..4], clampRound(i32, x * 2147483520.0), .little),
            .f32_le => std.mem.writeInt(u32, dst[0..4], @bitCast(x), .little),
            .f64_le => std.mem.writeInt(u64, dst[0..8], @bitCast(@as(f64, x)), .little),
        }
    }
    return n * stride;
}

fn clampRound(comptime T: type, x: f32) T {
    const lo: f32 = @floatFromInt(std.math.minInt(T));
    const hi: f32 = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(std.math.clamp(@round(x), lo, hi));
}

/// Remap `src_channels` interleaved channels onto `dst_channels`.
///
/// Mono widens to every output channel, stereo folds to mono by averaging, and
/// anything else copies the channels it can and zero-fills the rest. `dst` must
/// hold `frames * dst_channels` samples.
pub fn remapChannels(
    src: []const f32,
    src_channels: u8,
    dst: []f32,
    dst_channels: u8,
    frames: usize,
) void {
    std.debug.assert(src.len >= frames * src_channels);
    std.debug.assert(dst.len >= frames * dst_channels);
    if (src_channels == dst_channels) {
        @memcpy(dst[0 .. frames * dst_channels], src[0 .. frames * dst_channels]);
        return;
    }
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        const in = src[f * src_channels ..][0..src_channels];
        const out = dst[f * dst_channels ..][0..dst_channels];
        if (src_channels == 1) {
            for (out) |*o| o.* = in[0];
        } else if (dst_channels == 1) {
            var sum: f32 = 0;
            for (in) |v| sum += v;
            out[0] = sum / @as(f32, @floatFromInt(src_channels));
        } else {
            const shared = @min(src_channels, dst_channels);
            @memcpy(out[0..shared], in[0..shared]);
            if (dst_channels > shared) @memset(out[shared..], 0);
        }
    }
}

test "round trip i16" {
    const samples = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0 };
    var bytes: [10]u8 = undefined;
    const written = encodeFromFloat(.i16_pcm, &samples, &bytes);
    try std.testing.expectEqual(@as(usize, 10), written);

    var back: [5]f32 = undefined;
    const read = decodeToFloat(.i16_pcm, &bytes, &back);
    try std.testing.expectEqual(@as(usize, 5), read);
    for (samples, back) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 1.0 / 32767.0);
    }
}

test "round trip 24-bit preserves sign" {
    const samples = [_]f32{ 0.0, 0.25, -0.25, 0.999, -0.999 };
    var bytes: [15]u8 = undefined;
    _ = encodeFromFloat(.i24_pcm, &samples, &bytes);
    var back: [5]f32 = undefined;
    _ = decodeToFloat(.i24_pcm, &bytes, &back);
    for (samples, back) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 1e-5);
    }
}

test "u8 midpoint is silence" {
    const bytes = [_]u8{ 128, 255, 0 };
    var out: [3]f32 = undefined;
    _ = decodeToFloat(.u8_pcm, &bytes, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try std.testing.expect(out[1] > 0.9);
    try std.testing.expect(out[2] < -0.9);
}

test "channel remapping" {
    // mono -> stereo duplicates
    const mono = [_]f32{ 1.0, -1.0 };
    var stereo: [4]f32 = undefined;
    remapChannels(&mono, 1, &stereo, 2, 2);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, -1.0, -1.0 }, &stereo);

    // stereo -> mono averages
    const src = [_]f32{ 1.0, 0.0, -0.5, 0.5 };
    var dst: [2]f32 = undefined;
    remapChannels(&src, 2, &dst, 1, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.0 }, &dst);

    // stereo -> 4ch copies what it can and zero-fills
    var quad: [8]f32 = undefined;
    remapChannels(&src, 2, &quad, 4, 2);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0, 0.0, -0.5, 0.5, 0.0, 0.0 }, &quad);
}
