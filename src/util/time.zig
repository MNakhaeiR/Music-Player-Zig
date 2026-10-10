//! Small helpers for turning sample counts and seconds into human strings.

const std = @import("std");

/// Format seconds as `m:ss`, or `h:mm:ss` once the duration passes an hour.
/// Writes into `buf` and returns the populated slice.
pub fn formatClock(buf: []u8, seconds: f64) []const u8 {
    if (!std.math.isFinite(seconds) or seconds < 0) {
        return std.fmt.bufPrint(buf, "--:--", .{}) catch "--:--";
    }
    const total: u64 = @intFromFloat(@floor(seconds));
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "--:--";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "--:--";
}

/// Convert a frame count at `sample_rate` into seconds.
pub fn framesToSeconds(frames: u64, sample_rate: u32) f64 {
    if (sample_rate == 0) return 0;
    return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(sample_rate));
}

/// Convert seconds into a frame count at `sample_rate`, clamped at zero.
pub fn secondsToFrames(seconds: f64, sample_rate: u32) u64 {
    if (seconds <= 0) return 0;
    return @intFromFloat(seconds * @as(f64, @floatFromInt(sample_rate)));
}

/// Convert a linear amplitude to decibels, with a floor so silence is finite.
pub fn amplitudeToDb(amp: f32) f32 {
    if (amp <= 1e-7) return -140.0;
    return 20.0 * std.math.log10(amp);
}

/// Convert decibels to a linear amplitude multiplier.
pub fn dbToAmplitude(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

test formatClock {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0:00", formatClock(&buf, 0));
    try std.testing.expectEqualStrings("0:07", formatClock(&buf, 7.4));
    try std.testing.expectEqualStrings("3:21", formatClock(&buf, 201.0));
    try std.testing.expectEqualStrings("1:00:00", formatClock(&buf, 3600.0));
    try std.testing.expectEqualStrings("2:03:04", formatClock(&buf, 7384.0));
    try std.testing.expectEqualStrings("--:--", formatClock(&buf, -1));
}

test "frame/second round trip" {
    try std.testing.expectEqual(@as(u64, 44100), secondsToFrames(1.0, 44100));
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), framesToSeconds(120_000, 48_000), 1e-9);
}

test "decibel conversions invert" {
    for ([_]f32{ -60, -24, -6, 0 }) |db| {
        try std.testing.expectApproxEqAbs(db, amplitudeToDb(dbToAmplitude(db)), 1e-3);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dbToAmplitude(0), 1e-6);
}
