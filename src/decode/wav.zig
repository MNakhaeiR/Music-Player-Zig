//! RIFF/WAVE reader.
//!
//! Handles integer PCM at 8/16/24/32 bits, IEEE float at 32/64 bits, and
//! WAVE_FORMAT_EXTENSIBLE (which is how anything above 16 bits or above two
//! channels is normally tagged). Chunks are walked rather than assumed to be
//! in a fixed order, because plenty of encoders put `LIST`, `fact` or `id3 `
//! chunks before `data`.

const std = @import("std");
const api = @import("api.zig");
const fmt = @import("../audio/format.zig");

const SampleFormat = fmt.SampleFormat;
const StreamFormat = fmt.StreamFormat;

/// WAVE format tags.
const WAVE_FORMAT_PCM: u16 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_ALAW: u16 = 0x0006;
const WAVE_FORMAT_MULAW: u16 = 0x0007;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

/// First four bytes of the KSDATAFORMAT_SUBTYPE_* GUIDs; the remaining twelve
/// are the fixed `0000-0010-8000-00AA00389B71` tail shared by all of them.
const subtype_tail = [_]u8{
    0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
    0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
};

pub const Wav = struct {
    bytes: []const u8,
    /// Offset and length of the `data` chunk payload.
    data_start: usize,
    data_len: usize,

    sample_fmt: SampleFormat,
    stream: StreamFormat,
    bits_per_sample: u8,
    bytes_per_frame: usize,

    total_frames: u64,
    pos: u64 = 0,

    /// Raw tag chunks, handed to the metadata reader if present.
    id3_chunk: ?[]const u8 = null,
    list_info: ?[]const u8 = null,

    pub fn open(bytes: []const u8) api.Error!Wav {
        if (bytes.len < 12) return error.UnsupportedFormat;
        if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.UnsupportedFormat;
        if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.UnsupportedFormat;

        // The RIFF size field is frequently wrong (streamed or truncated
        // files), so trust the actual buffer length instead.
        var have_fmt = false;
        var sample_fmt: SampleFormat = .i16_pcm;
        var stream: StreamFormat = .{ .sample_rate = 44_100, .channels = 2 };
        var bits: u8 = 16;
        var block_align: usize = 0;

        var data_start: usize = 0;
        var data_len: usize = 0;
        var id3_chunk: ?[]const u8 = null;
        var list_info: ?[]const u8 = null;

        var pos: usize = 12;
        while (pos + 8 <= bytes.len) {
            const id = bytes[pos..][0..4];
            const raw_size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
            const body = pos + 8;
            // Clamp: a truncated file can claim more than it holds.
            const size: usize = @min(@as(usize, raw_size), bytes.len - body);

            if (std.mem.eql(u8, id, "fmt ")) {
                if (size < 16) return error.CorruptStream;
                const chunk = bytes[body..][0..size];
                var tag = std.mem.readInt(u16, chunk[0..2], .little);
                const channels = std.mem.readInt(u16, chunk[2..4], .little);
                const rate = std.mem.readInt(u32, chunk[4..8], .little);
                block_align = std.mem.readInt(u16, chunk[12..14], .little);
                bits = @intCast(std.mem.readInt(u16, chunk[14..16], .little));

                if (tag == WAVE_FORMAT_EXTENSIBLE) {
                    if (size < 40) return error.CorruptStream;
                    const valid_bits = std.mem.readInt(u16, chunk[18..20], .little);
                    if (valid_bits != 0) bits = @intCast(valid_bits);
                    const guid = chunk[24..40];
                    if (!std.mem.eql(u8, guid[4..16], &subtype_tail)) {
                        return error.UnsupportedFormat;
                    }
                    tag = std.mem.readInt(u16, guid[0..2], .little);
                }

                if (channels == 0 or channels > 8) return error.UnsupportedFormat;
                if (rate == 0) return error.CorruptStream;

                sample_fmt = switch (tag) {
                    WAVE_FORMAT_PCM => switch (bits) {
                        8 => .u8_pcm,
                        16 => .i16_pcm,
                        24 => .i24_pcm,
                        32 => .i32_pcm,
                        else => return error.UnsupportedFormat,
                    },
                    WAVE_FORMAT_IEEE_FLOAT => switch (bits) {
                        32 => .f32_le,
                        64 => .f64_le,
                        else => return error.UnsupportedFormat,
                    },
                    // A-law and mu-law would need a lookup table expansion;
                    // they essentially never show up in a music library.
                    WAVE_FORMAT_ALAW, WAVE_FORMAT_MULAW => return error.UnsupportedFormat,
                    else => return error.UnsupportedFormat,
                };
                stream = .{ .sample_rate = rate, .channels = @intCast(channels) };
                have_fmt = true;
            } else if (std.mem.eql(u8, id, "data")) {
                data_start = body;
                // Size 0 or 0xFFFFFFFF means "to the end" in streamed files.
                data_len = if (raw_size == 0 or raw_size == 0xFFFF_FFFF)
                    bytes.len - body
                else
                    size;
            } else if (std.mem.eql(u8, id, "id3 ") or std.mem.eql(u8, id, "ID3 ")) {
                id3_chunk = bytes[body..][0..size];
            } else if (std.mem.eql(u8, id, "LIST")) {
                if (size >= 4 and std.mem.eql(u8, bytes[body..][0..4], "INFO")) {
                    list_info = bytes[body + 4 ..][0 .. size - 4];
                }
            }

            // Chunks are word-aligned: an odd size is followed by a pad byte.
            const advance = 8 + size + (size & 1);
            if (advance == 0) break;
            pos += advance;
        }

        if (!have_fmt) return error.CorruptStream;
        if (data_len == 0) return error.CorruptStream;

        const computed_frame = @as(usize, sample_fmt.bytesPerSample()) * stream.channels;
        // Trust `block_align` only when it agrees with the sample format;
        // some encoders write nonsense there.
        const bytes_per_frame = if (block_align == computed_frame) block_align else computed_frame;
        if (bytes_per_frame == 0) return error.CorruptStream;

        return .{
            .bytes = bytes,
            .data_start = data_start,
            .data_len = data_len - (data_len % bytes_per_frame),
            .sample_fmt = sample_fmt,
            .stream = stream,
            .bits_per_sample = bits,
            .bytes_per_frame = bytes_per_frame,
            .total_frames = (data_len / bytes_per_frame),
            .id3_chunk = id3_chunk,
            .list_info = list_info,
        };
    }

    pub fn info(self: *const Wav) api.Info {
        return .{
            .codec = .wav,
            .sample_rate = self.stream.sample_rate,
            .channels = self.stream.channels,
            .bits_per_sample = self.bits_per_sample,
            .total_frames = self.total_frames,
            .seekable = true,
            .bitrate = @intCast(@as(u64, self.stream.sample_rate) *
                @as(u64, self.bytes_per_frame) * 8),
        };
    }

    /// Decode interleaved float frames into `out`, which must be a whole
    /// number of frames long. Returns frames written; 0 means end of stream.
    pub fn readFrames(self: *Wav, out: []f32) api.Error!usize {
        const ch = self.stream.channels;
        if (ch == 0) return error.CorruptStream;
        const want = @min(out.len / ch, self.total_frames - self.pos);
        if (want == 0) return 0;

        const byte_off = self.data_start + @as(usize, @intCast(self.pos)) * self.bytes_per_frame;
        const byte_len = want * self.bytes_per_frame;
        if (byte_off + byte_len > self.bytes.len) return error.EndOfStream;

        const src = self.bytes[byte_off..][0..byte_len];
        const written = fmt.decodeToFloat(self.sample_fmt, src, out[0 .. want * ch]);
        const frames = written / ch;
        self.pos += frames;
        return frames;
    }

    pub fn seekToFrame(self: *Wav, frame: u64) api.Error!void {
        if (frame > self.total_frames) return error.SeekOutOfRange;
        self.pos = frame;
    }

    pub fn positionFrames(self: *const Wav) u64 {
        return self.pos;
    }

    /// Cheap check used by format probing.
    pub fn looksLikeWav(bytes: []const u8) bool {
        return bytes.len >= 12 and
            std.mem.eql(u8, bytes[0..4], "RIFF") and
            std.mem.eql(u8, bytes[8..12], "WAVE");
    }
};

// ---------------------------------------------------------------------------
// Test helpers: build WAV files in memory so the suite needs no fixtures.
// ---------------------------------------------------------------------------

/// Assemble a minimal WAV file. Exposed for tests and for the offline
/// renderer, which writes its output with the same layout.
pub fn buildWav(
    gpa: std.mem.Allocator,
    sample_fmt: SampleFormat,
    stream: StreamFormat,
    pcm: []const u8,
) std.mem.Allocator.Error![]u8 {
    const extensible = stream.channels > 2 or sample_fmt == .i24_pcm or
        sample_fmt == .i32_pcm or sample_fmt == .f64_le;
    const fmt_size: u32 = if (extensible) 40 else 16;
    const bits: u16 = @as(u16, sample_fmt.bytesPerSample()) * 8;
    const block_align: u16 = @as(u16, sample_fmt.bytesPerSample()) * stream.channels;
    const byte_rate: u32 = stream.sample_rate * block_align;
    const data_size: u32 = @intCast(pcm.len);
    const riff_size: u32 = 4 + (8 + fmt_size) + (8 + data_size) + (data_size & 1);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    try list.appendSlice(gpa, "RIFF");
    try appendU32(gpa, &list, riff_size);
    try list.appendSlice(gpa, "WAVE");

    try list.appendSlice(gpa, "fmt ");
    try appendU32(gpa, &list, fmt_size);
    const tag: u16 = if (extensible)
        WAVE_FORMAT_EXTENSIBLE
    else switch (sample_fmt) {
        .f32_le, .f64_le => WAVE_FORMAT_IEEE_FLOAT,
        else => WAVE_FORMAT_PCM,
    };
    try appendU16(gpa, &list, tag);
    try appendU16(gpa, &list, stream.channels);
    try appendU32(gpa, &list, stream.sample_rate);
    try appendU32(gpa, &list, byte_rate);
    try appendU16(gpa, &list, block_align);
    try appendU16(gpa, &list, bits);
    if (extensible) {
        try appendU16(gpa, &list, 22); // cbSize
        try appendU16(gpa, &list, bits); // valid bits
        try appendU32(gpa, &list, defaultChannelMask(stream.channels));
        const sub: u16 = switch (sample_fmt) {
            .f32_le, .f64_le => WAVE_FORMAT_IEEE_FLOAT,
            else => WAVE_FORMAT_PCM,
        };
        try appendU16(gpa, &list, sub);
        try appendU16(gpa, &list, 0);
        try list.appendSlice(gpa, &subtype_tail);
    }

    try list.appendSlice(gpa, "data");
    try appendU32(gpa, &list, data_size);
    try list.appendSlice(gpa, pcm);
    if (data_size & 1 != 0) try list.append(gpa, 0);

    return list.toOwnedSlice(gpa);
}

fn defaultChannelMask(channels: u8) u32 {
    return switch (channels) {
        1 => 0x4, // centre
        2 => 0x3, // front left + right
        4 => 0x33,
        6 => 0x3F,
        8 => 0x63F,
        else => 0,
    };
}

fn appendU16(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn appendU32(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

const testing = std.testing;

/// Build a WAV holding `frames` frames of a sine at `freq`.
fn sineWav(
    gpa: std.mem.Allocator,
    sample_fmt: SampleFormat,
    stream: StreamFormat,
    frames: usize,
    freq: f64,
) ![]u8 {
    const samples = try gpa.alloc(f32, frames * stream.channels);
    defer gpa.free(samples);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(stream.sample_rate));
        const v: f32 = @floatCast(0.5 * @sin(2.0 * std.math.pi * freq * t));
        for (0..stream.channels) |c| samples[i * stream.channels + c] = v;
    }
    const pcm = try gpa.alloc(u8, samples.len * sample_fmt.bytesPerSample());
    defer gpa.free(pcm);
    _ = fmt.encodeFromFloat(sample_fmt, samples, pcm);
    return buildWav(gpa, sample_fmt, stream, pcm);
}

test "rejects non-WAV input" {
    try testing.expectError(error.UnsupportedFormat, Wav.open("not audio at all"));
    try testing.expectError(error.UnsupportedFormat, Wav.open(""));
    try testing.expect(!Wav.looksLikeWav("RIFFxxxxAVI "));
}

test "reads a 16-bit stereo file" {
    const gpa = testing.allocator;
    const stream: StreamFormat = .{ .sample_rate = 44_100, .channels = 2 };
    const bytes = try sineWav(gpa, .i16_pcm, stream, 1000, 440);
    defer gpa.free(bytes);

    var w = try Wav.open(bytes);
    const nfo = w.info();
    try testing.expectEqual(api.Codec.wav, nfo.codec);
    try testing.expectEqual(@as(u32, 44_100), nfo.sample_rate);
    try testing.expectEqual(@as(u8, 2), nfo.channels);
    try testing.expectEqual(@as(u8, 16), nfo.bits_per_sample);
    try testing.expectEqual(@as(u64, 1000), nfo.total_frames.?);
    try testing.expect(nfo.seekable);
    try testing.expectApproxEqAbs(@as(f64, 1000.0 / 44_100.0), nfo.durationSeconds().?, 1e-9);

    const out = try gpa.alloc(f32, 1000 * 2);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1000), try w.readFrames(out));
    try testing.expectEqual(@as(usize, 0), try w.readFrames(out));

    // Left and right carry the same tone, and it is a real signal.
    var peak: f32 = 0;
    for (out) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);
    for (0..1000) |i| try testing.expectEqual(out[i * 2], out[i * 2 + 1]);
}

test "every supported sample format decodes" {
    const gpa = testing.allocator;
    const formats = [_]SampleFormat{ .u8_pcm, .i16_pcm, .i24_pcm, .i32_pcm, .f32_le, .f64_le };
    for (formats) |sf| {
        const stream: StreamFormat = .{ .sample_rate = 48_000, .channels = 2 };
        const bytes = try sineWav(gpa, sf, stream, 480, 1000);
        defer gpa.free(bytes);

        var w = try Wav.open(bytes);
        try testing.expectEqual(sf, w.sample_fmt);
        try testing.expectEqual(@as(u64, 480), w.total_frames);

        const out = try gpa.alloc(f32, 480 * 2);
        defer gpa.free(out);
        try testing.expectEqual(@as(usize, 480), try w.readFrames(out));

        var peak: f32 = 0;
        for (out) |v| peak = @max(peak, @abs(v));
        // 8-bit quantization is coarse; everything else should be tight.
        const tol: f32 = if (sf == .u8_pcm) 0.02 else 0.005;
        try testing.expectApproxEqAbs(@as(f32, 0.5), peak, tol);
    }
}

test "multichannel files use the extensible header" {
    const gpa = testing.allocator;
    const stream: StreamFormat = .{ .sample_rate = 48_000, .channels = 6 };
    const bytes = try sineWav(gpa, .i24_pcm, stream, 256, 220);
    defer gpa.free(bytes);

    var w = try Wav.open(bytes);
    try testing.expectEqual(@as(u8, 6), w.stream.channels);
    try testing.expectEqual(@as(u8, 24), w.bits_per_sample);
    try testing.expectEqual(SampleFormat.i24_pcm, w.sample_fmt);

    const out = try gpa.alloc(f32, 256 * 6);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 256), try w.readFrames(out));
}

test "partial reads advance the cursor" {
    const gpa = testing.allocator;
    const stream: StreamFormat = .{ .sample_rate = 8000, .channels = 1 };
    const bytes = try sineWav(gpa, .i16_pcm, stream, 100, 100);
    defer gpa.free(bytes);

    var w = try Wav.open(bytes);
    var out: [30]f32 = undefined;
    try testing.expectEqual(@as(usize, 30), try w.readFrames(&out));
    try testing.expectEqual(@as(u64, 30), w.positionFrames());
    try testing.expectEqual(@as(usize, 30), try w.readFrames(&out));
    try testing.expectEqual(@as(usize, 30), try w.readFrames(&out));
    // Only 10 frames left.
    try testing.expectEqual(@as(usize, 10), try w.readFrames(&out));
    try testing.expectEqual(@as(usize, 0), try w.readFrames(&out));
}

test "seeking is exact" {
    const gpa = testing.allocator;
    const stream: StreamFormat = .{ .sample_rate = 8000, .channels = 1 };
    const bytes = try sineWav(gpa, .i16_pcm, stream, 800, 50);
    defer gpa.free(bytes);

    var w = try Wav.open(bytes);
    var first: [800]f32 = undefined;
    _ = try w.readFrames(&first);

    try w.seekToFrame(400);
    try testing.expectEqual(@as(u64, 400), w.positionFrames());
    var mid: [100]f32 = undefined;
    try testing.expectEqual(@as(usize, 100), try w.readFrames(&mid));
    for (0..100) |i| try testing.expectEqual(first[400 + i], mid[i]);

    try w.seekToFrame(0);
    var again: [10]f32 = undefined;
    _ = try w.readFrames(&again);
    for (0..10) |i| try testing.expectEqual(first[i], again[i]);

    try testing.expectError(error.SeekOutOfRange, w.seekToFrame(10_000));
}

test "chunks before data are skipped and tags captured" {
    const gpa = testing.allocator;
    // Hand-build a file with a LIST/INFO chunk between fmt and data.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    const pcm = [_]u8{ 0, 0, 0xFF, 0x7F, 0, 0x80, 0, 0 }; // 4 mono i16 frames
    try list.appendSlice(gpa, "RIFF");
    try appendU32(gpa, &list, 0); // deliberately wrong; must be ignored
    try list.appendSlice(gpa, "WAVE");

    try list.appendSlice(gpa, "fmt ");
    try appendU32(gpa, &list, 16);
    try appendU16(gpa, &list, WAVE_FORMAT_PCM);
    try appendU16(gpa, &list, 1);
    try appendU32(gpa, &list, 22_050);
    try appendU32(gpa, &list, 44_100);
    try appendU16(gpa, &list, 2);
    try appendU16(gpa, &list, 16);

    // An odd-sized chunk, to exercise the pad byte.
    try list.appendSlice(gpa, "LIST");
    try appendU32(gpa, &list, 13);
    try list.appendSlice(gpa, "INFOINAMhi!!!"[0..13]);
    try list.append(gpa, 0); // pad

    try list.appendSlice(gpa, "data");
    try appendU32(gpa, &list, pcm.len);
    try list.appendSlice(gpa, &pcm);

    var w = try Wav.open(list.items);
    try testing.expectEqual(@as(u32, 22_050), w.stream.sample_rate);
    try testing.expectEqual(@as(u64, 4), w.total_frames);
    try testing.expect(w.list_info != null);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try w.readFrames(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[2], 1e-4);
}

test "a truncated data chunk is clamped instead of overrunning" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "RIFF");
    try appendU32(gpa, &list, 0);
    try list.appendSlice(gpa, "WAVE");
    try list.appendSlice(gpa, "fmt ");
    try appendU32(gpa, &list, 16);
    try appendU16(gpa, &list, WAVE_FORMAT_PCM);
    try appendU16(gpa, &list, 2);
    try appendU32(gpa, &list, 44_100);
    try appendU32(gpa, &list, 176_400);
    try appendU16(gpa, &list, 4);
    try appendU16(gpa, &list, 16);
    try list.appendSlice(gpa, "data");
    try appendU32(gpa, &list, 1_000_000); // claims far more than it holds
    try list.appendSlice(gpa, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });

    var w = try Wav.open(list.items);
    try testing.expectEqual(@as(u64, 2), w.total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try w.readFrames(&out));
}

test "unsupported codecs are reported rather than guessed at" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "RIFF");
    try appendU32(gpa, &list, 0);
    try list.appendSlice(gpa, "WAVE");
    try list.appendSlice(gpa, "fmt ");
    try appendU32(gpa, &list, 16);
    try appendU16(gpa, &list, WAVE_FORMAT_MULAW);
    try appendU16(gpa, &list, 1);
    try appendU32(gpa, &list, 8000);
    try appendU32(gpa, &list, 8000);
    try appendU16(gpa, &list, 1);
    try appendU16(gpa, &list, 8);
    try list.appendSlice(gpa, "data");
    try appendU32(gpa, &list, 4);
    try list.appendSlice(gpa, &[_]u8{ 1, 2, 3, 4 });

    try testing.expectError(error.UnsupportedFormat, Wav.open(list.items));
}

test "a file with no data chunk is corrupt" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "RIFF");
    try appendU32(gpa, &list, 0);
    try list.appendSlice(gpa, "WAVE");
    try list.appendSlice(gpa, "fmt ");
    try appendU32(gpa, &list, 16);
    try appendU16(gpa, &list, WAVE_FORMAT_PCM);
    try appendU16(gpa, &list, 1);
    try appendU32(gpa, &list, 8000);
    try appendU32(gpa, &list, 16000);
    try appendU16(gpa, &list, 2);
    try appendU16(gpa, &list, 16);
    try testing.expectError(error.CorruptStream, Wav.open(list.items));
}
