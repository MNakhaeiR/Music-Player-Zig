//! DSP microbenchmarks.
//!
//! The number that matters for a music player is the real-time factor: how
//! many seconds of audio a stage can process per second of CPU. Anything in
//! the audio callback needs a very large margin, because it has to finish
//! inside one device period every single time, not merely on average.
//!
//!   zig build bench

const std = @import("std");
const Io = std.Io;
const zmp = @import("zmp");

const fft = zmp.dsp.fft;
const biquad = zmp.dsp.biquad;
const Equalizer = zmp.dsp.equalizer.Equalizer;
const Resampler = zmp.dsp.resample.Resampler;
const Chain = zmp.dsp.chain.Chain;
const Limiter = zmp.dsp.limiter.Limiter;
const Ring = zmp.audio.ring.Ring;

const sample_rate: u32 = 48_000;
const channels: usize = 2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buffer: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    try out.print("zmp DSP benchmarks — {d} Hz, {d} channels, {s}\n\n", .{
        sample_rate,
        channels,
        @tagName(@import("builtin").mode),
    });
    try out.print("{s:<34} {s:>12} {s:>14}\n", .{ "stage", "ns/frame", "x real time" });
    try out.print("{s:-<34} {s:->12} {s:->14}\n", .{ "", "", "" });

    try benchBiquad(gpa, io, out);
    try benchEqualizer(gpa, io, out);
    try benchLimiter(gpa, io, out);
    try benchChain(gpa, io, out);
    try benchResampler(gpa, io, out, .medium);
    try benchResampler(gpa, io, out, .high);
    try benchFft(gpa, io, out, 1024);
    try benchFft(gpa, io, out, 4096);
    try benchRing(gpa, io, out);

    try out.print("\n", .{});
    try out.print("A stage must stay far above 1x: the audio callback has to finish\n", .{});
    try out.print("within one device period on every single invocation.\n", .{});
}

/// Run `body` over `total_frames` and report the throughput.
fn report(
    out: *Io.Writer,
    io: Io,
    label: []const u8,
    total_frames: usize,
    start: Io.Timestamp,
) !void {
    const now: Io.Timestamp = .now(io, .awake);
    const elapsed_ns = start.durationTo(now).toNanoseconds();
    const ns: f64 = @floatFromInt(@max(elapsed_ns, 1));
    const frames: f64 = @floatFromInt(total_frames);

    const ns_per_frame = ns / frames;
    const audio_seconds = frames / @as(f64, @floatFromInt(sample_rate));
    const cpu_seconds = ns / 1e9;
    const realtime = audio_seconds / cpu_seconds;

    try out.print("{s:<34} {d:>12.2} {d:>13.0}x\n", .{ label, ns_per_frame, realtime });
    try out.flush();
}

fn makeSignal(gpa: std.mem.Allocator, frames: usize) ![]f32 {
    const buf = try gpa.alloc(f32, frames * channels);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_rate));
        const v: f32 = @floatCast(0.4 * @sin(2.0 * std.math.pi * 440.0 * t) +
            0.2 * @sin(2.0 * std.math.pi * 3000.0 * t));
        for (0..channels) |c| buf[i * channels + c] = v;
    }
    return buf;
}

fn benchBiquad(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const frames = 2_000_000;
    const block = 1024;
    const signal = try makeSignal(gpa, block);
    defer gpa.free(signal);
    const work = try gpa.dupe(f32, signal);
    defer gpa.free(work);

    var section: biquad.Stereo8 = .{};
    section.setCoeffs(biquad.design(.{
        .kind = .peaking,
        .freq = 1000,
        .q = 1.0,
        .gain_db = 6,
    }, sample_rate));

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        @memcpy(work, signal);
        section.processInterleaved(work, channels);
    }
    try report(out, io, "one biquad section", done, start);
}

fn benchEqualizer(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const frames = 1_000_000;
    const block = 1024;
    const signal = try makeSignal(gpa, block);
    defer gpa.free(signal);
    const work = try gpa.dupe(f32, signal);
    defer gpa.free(work);

    var eq = Equalizer.init(sample_rate);
    eq.enabled = true;
    eq.setPreset(.rock);

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        @memcpy(work, signal);
        eq.process(work, channels);
    }
    try report(out, io, "10-band equalizer", done, start);
}

fn benchLimiter(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const frames = 1_000_000;
    const block = 1024;
    const signal = try makeSignal(gpa, block);
    defer gpa.free(signal);
    const work = try gpa.dupe(f32, signal);
    defer gpa.free(work);

    var lim = try Limiter.init(gpa, sample_rate, channels);
    defer lim.deinit();

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        @memcpy(work, signal);
        lim.process(work, channels);
    }
    try report(out, io, "look-ahead limiter", done, start);
}

fn benchChain(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const frames = 1_000_000;
    const block = 1024;
    const signal = try makeSignal(gpa, block);
    defer gpa.free(signal);
    const work = try gpa.dupe(f32, signal);
    defer gpa.free(work);

    var chain = try Chain.init(gpa, sample_rate, channels);
    defer chain.deinit();
    chain.eq.enabled = true;
    chain.eq.setPreset(.loudness);
    chain.gain.setVolume(0.8);
    chain.reset();

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        @memcpy(work, signal);
        chain.process(work, channels);
    }
    try report(out, io, "full chain (eq+gain+limiter)", done, start);
}

fn benchResampler(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    quality: zmp.dsp.resample.Quality,
) !void {
    const frames = 500_000;
    const block = 1024;
    const signal = try makeSignal(gpa, block);
    defer gpa.free(signal);

    // 44.1 kHz into 48 kHz, the conversion a player does most often.
    var rs = try Resampler.init(gpa, 44_100, 48_000, channels, quality);
    defer rs.deinit();

    const dest = try gpa.alloc(f32, block * channels * 2);
    defer gpa.free(dest);

    var label_buf: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(
        &label_buf,
        "resampler 44.1->48 ({s}, {d} tap)",
        .{ quality.label(), rs.taps },
    );

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        var consumed: usize = 0;
        while (consumed < block) {
            const res = rs.process(signal[consumed * channels ..], dest);
            if (res.consumed == 0 and res.produced == 0) break;
            consumed += res.consumed;
        }
    }
    try report(out, io, label, done, start);
}

fn benchFft(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, comptime size: usize) !void {
    const iterations = 4000;
    const scratch = try gpa.alloc(fft.Complex, size);
    defer gpa.free(scratch);
    const signal = try gpa.alloc(f32, size);
    defer gpa.free(signal);
    const window = try gpa.alloc(f32, size);
    defer gpa.free(window);
    const spectrum = try gpa.alloc(f32, size / 2 + 1);
    defer gpa.free(spectrum);

    fft.fillWindow(.hann, window);
    for (signal, 0..) |*s, i| {
        s.* = @floatCast(@sin(@as(f64, @floatFromInt(i)) * 0.01));
    }

    var label_buf: [48]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "FFT magnitude ({d} point)", .{size});

    const start: Io.Timestamp = .now(io, .awake);
    for (0..iterations) |_| {
        fft.realMagnitudeSpectrum(signal, window, scratch, spectrum);
    }
    // One transform covers `size` frames of audio.
    try report(out, io, label, iterations * size, start);
}

fn benchRing(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const frames = 4_000_000;
    const block = 512;
    var ring = try Ring.init(gpa, block * channels * 4);
    defer ring.deinit(gpa);

    const src = try gpa.alloc(f32, block * channels);
    defer gpa.free(src);
    @memset(src, 0.25);
    const dst = try gpa.alloc(f32, block * channels);
    defer gpa.free(dst);

    const start: Io.Timestamp = .now(io, .awake);
    var done: usize = 0;
    while (done < frames) : (done += block) {
        _ = ring.write(src);
        _ = ring.read(dst);
    }
    try report(out, io, "ring buffer write+read", done, start);
}
