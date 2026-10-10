//! MPEG audio (layer I/II/III) decoding.
//!
//! The frame-level work is done by minimp3, a public-domain C decoder vendored
//! under `vendor/minimp3`. Writing a correct MP3 frame decoder from scratch is
//! a large project in its own right — Huffman tables, the bit reservoir, the
//! IMDCT and the polyphase synthesis bank — and getting it subtly wrong sounds
//! like quiet distortion rather than an obvious failure. Leaning on a decoder
//! that is already bit-exact against the conformance vectors is the right
//! trade here; the Zig side keeps ownership of all memory and presents the
//! same interface as the native WAV and FLAC readers.
//!
//! Build with `-Dmp3=false` to drop the dependency; MP3 files are then simply
//! reported as an unsupported format.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const api = @import("api.zig");

pub const enabled = build_options.enable_mp3;

const c = if (enabled) struct {
    extern fn zmp_mp3_state_size() usize;
    extern fn zmp_mp3_state_align() usize;
    extern fn zmp_mp3_open(state: *anyopaque, buf: [*]const u8, len: usize) c_int;
    extern fn zmp_mp3_close(state: *anyopaque) void;
    extern fn zmp_mp3_info(
        state: *anyopaque,
        rate: *c_int,
        channels: *c_int,
        samples: *u64,
        bitrate_kbps: *c_int,
        layer: *c_int,
    ) void;
    extern fn zmp_mp3_read(state: *anyopaque, out: [*]i16, max_samples: usize) usize;
    extern fn zmp_mp3_seek(state: *anyopaque, sample: u64) c_int;
} else struct {};

/// Samples buffered per `readFrames` call before conversion to float.
const scratch_samples = 4608;

pub const Mp3 = struct {
    gpa: Allocator,
    /// Opaque minimp3 state, allocated here so C never calls malloc.
    state: []align(16) u8 = &.{},
    bytes: []const u8 = &.{},

    sample_rate: u32 = 0,
    channels: u8 = 0,
    layer: u8 = 0,
    bitrate_kbps: u32 = 0,
    /// Total interleaved samples, i.e. frames * channels.
    total_samples: u64 = 0,
    pos_samples: u64 = 0,

    scratch: []i16 = &.{},
    /// Offset of the ID3v2 block, when the file starts with one.
    id3: ?[]const u8 = null,
    open_ok: bool = false,

    pub fn open(gpa: Allocator, bytes: []const u8) api.Error!Mp3 {
        if (!enabled) return error.UnsupportedFormat;

        const size = c.zmp_mp3_state_size();
        const state = gpa.alignedAlloc(u8, .@"16", size) catch return error.OutOfMemory;
        errdefer gpa.free(state);
        @memset(state, 0);

        const scratch = gpa.alloc(i16, scratch_samples) catch return error.OutOfMemory;
        errdefer gpa.free(scratch);

        if (c.zmp_mp3_open(state.ptr, bytes.ptr, bytes.len) != 0) {
            return error.CorruptStream;
        }
        errdefer c.zmp_mp3_close(state.ptr);

        var rate: c_int = 0;
        var channels: c_int = 0;
        var samples: u64 = 0;
        var bitrate: c_int = 0;
        var layer: c_int = 0;
        c.zmp_mp3_info(state.ptr, &rate, &channels, &samples, &bitrate, &layer);

        if (rate <= 0 or channels <= 0 or channels > 2) return error.UnsupportedFormat;

        return .{
            .gpa = gpa,
            .state = state,
            .bytes = bytes,
            .sample_rate = @intCast(rate),
            .channels = @intCast(channels),
            .layer = @intCast(@max(layer, 0)),
            .bitrate_kbps = @intCast(@max(bitrate, 0)),
            .total_samples = samples,
            .scratch = scratch,
            .id3 = id3Block(bytes),
            .open_ok = true,
        };
    }

    pub fn deinit(self: *Mp3) void {
        if (enabled and self.open_ok) c.zmp_mp3_close(self.state.ptr);
        if (self.state.len > 0) self.gpa.free(self.state);
        if (self.scratch.len > 0) self.gpa.free(self.scratch);
        self.* = undefined;
    }

    pub fn info(self: *const Mp3) api.Info {
        const frames: ?u64 = if (self.channels == 0 or self.total_samples == 0)
            null
        else
            self.total_samples / self.channels;
        return .{
            .codec = .mp3,
            .sample_rate = self.sample_rate,
            .channels = self.channels,
            // MP3 is lossy and has no native word size; 16 is what we hand out.
            .bits_per_sample = 16,
            .total_frames = frames,
            .seekable = true,
            .bitrate = if (self.bitrate_kbps == 0) null else self.bitrate_kbps * 1000,
        };
    }

    pub fn positionFrames(self: *const Mp3) u64 {
        if (self.channels == 0) return 0;
        return self.pos_samples / self.channels;
    }

    pub fn readFrames(self: *Mp3, out: []f32) api.Error!usize {
        if (!enabled) return error.UnsupportedFormat;
        const ch = self.channels;
        if (ch == 0) return error.CorruptStream;

        const capacity_frames = out.len / ch;
        var written_frames: usize = 0;

        while (written_frames < capacity_frames) {
            const want_samples = @min(
                self.scratch.len,
                (capacity_frames - written_frames) * ch,
            );
            // Always ask for a whole number of frames.
            const aligned = (want_samples / ch) * ch;
            if (aligned == 0) break;

            const got = c.zmp_mp3_read(self.state.ptr, self.scratch.ptr, aligned);
            if (got == 0) break;

            const frames = got / ch;
            const dst = out[written_frames * ch ..][0 .. frames * ch];
            for (dst, self.scratch[0 .. frames * ch]) |*d, s| {
                d.* = @as(f32, @floatFromInt(s)) / 32768.0;
            }
            written_frames += frames;
            self.pos_samples += frames * ch;
        }
        return written_frames;
    }

    pub fn seekToFrame(self: *Mp3, frame: u64) api.Error!void {
        if (!enabled) return error.UnsupportedFormat;
        const ch = self.channels;
        if (ch == 0) return error.CorruptStream;
        const target = frame * ch;
        if (self.total_samples != 0 and target > self.total_samples) {
            return error.SeekOutOfRange;
        }
        if (c.zmp_mp3_seek(self.state.ptr, target) != 0) return error.CorruptStream;
        self.pos_samples = target;
    }

    pub fn id3_block(self: *const Mp3) ?[]const u8 {
        return self.id3;
    }
};

/// Locate a leading ID3v2 tag, if any.
fn id3Block(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..3], "ID3")) return null;
    const size = (@as(usize, bytes[6] & 0x7F) << 21) |
        (@as(usize, bytes[7] & 0x7F) << 14) |
        (@as(usize, bytes[8] & 0x7F) << 7) |
        @as(usize, bytes[9] & 0x7F);
    const end = @min(bytes.len, 10 + size);
    return bytes[0..end];
}

/// Recognize MPEG audio from its leading bytes.
///
/// A bare MPEG stream has no magic number, only a per-frame sync word, so this
/// looks for an ID3 tag or a plausible frame header near the start. A single
/// sync word can occur by chance, so a second header is required at the
/// distance the first one's bitrate implies.
pub fn looksLikeMp3(bytes: []const u8) bool {
    if (!enabled) return false;

    var start: usize = 0;
    if (bytes.len >= 10 and std.mem.eql(u8, bytes[0..3], "ID3")) {
        const size = (@as(usize, bytes[6] & 0x7F) << 21) |
            (@as(usize, bytes[7] & 0x7F) << 14) |
            (@as(usize, bytes[8] & 0x7F) << 7) |
            @as(usize, bytes[9] & 0x7F);
        // An ID3v2 tag at the very start is effectively an MP3 marker; FLAC
        // and WAV are probed before this function is reached.
        start = 10 + size;
        if (start >= bytes.len) return true;
    }

    // Scan a bounded window for a frame header with a valid follow-up.
    const window_end = @min(bytes.len, start + 8192);
    var i = start;
    while (i + 4 <= window_end) : (i += 1) {
        const h = frameHeader(bytes[i..]) orelse continue;
        const next = i + h.frame_bytes;
        if (next + 4 > bytes.len) {
            // Near the end of a small file, one good header is enough.
            return h.frame_bytes > 0;
        }
        if (frameHeader(bytes[next..]) != null) return true;
    }
    return false;
}

const Header = struct { frame_bytes: usize };

const bitrate_table = [3][16]u16{
    // Layer I
    .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 },
    // Layer II
    .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 },
    // Layer III
    .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 },
};

const rate_table = [3]u32{ 44_100, 48_000, 32_000 };

/// Validate four bytes as an MPEG audio frame header and return its length.
fn frameHeader(b: []const u8) ?Header {
    if (b.len < 4) return null;
    if (b[0] != 0xFF or (b[1] & 0xE0) != 0xE0) return null;

    const version_bits: u2 = @truncate(b[1] >> 3);
    if (version_bits == 1) return null; // reserved
    const layer_bits: u2 = @truncate(b[1] >> 1);
    if (layer_bits == 0) return null; // reserved
    const layer: usize = 4 - @as(usize, layer_bits); // 1, 2 or 3

    const bitrate_index: u4 = @truncate(b[2] >> 4);
    if (bitrate_index == 0 or bitrate_index == 15) return null; // free/bad
    const rate_index: u2 = @truncate(b[2] >> 2);
    if (rate_index == 3) return null; // reserved

    var sample_rate = rate_table[rate_index];
    // MPEG2 halves the rate; MPEG2.5 quarters it.
    switch (version_bits) {
        3 => {}, // MPEG1
        2 => sample_rate /= 2, // MPEG2
        0 => sample_rate /= 4, // MPEG2.5
        else => unreachable,
    }

    const bitrate: u32 = @as(u32, bitrate_table[layer - 1][bitrate_index]) * 1000;
    if (bitrate == 0) return null;
    const padding: usize = if ((b[2] & 0x02) != 0) 1 else 0;

    const frame_bytes: usize = if (layer == 1)
        (((12 * bitrate) / sample_rate) + padding) * 4
    else blk: {
        // Layer III at MPEG2/2.5 uses 576 samples per frame instead of 1152.
        const samples_per_frame: u32 = if (layer == 3 and version_bits != 3) 576 else 1152;
        break :blk ((samples_per_frame / 8) * bitrate) / sample_rate + padding;
    };

    if (frame_bytes < 4 or frame_bytes > 5000) return null;
    return .{ .frame_bytes = frame_bytes };
}

const testing = std.testing;

test "id3 block is located and sized" {
    const padding = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const tag = "ID3\x03\x00\x00\x00\x00\x00\x0A" ++ padding ++ "payload";
    const block = id3Block(tag).?;
    try testing.expectEqual(@as(usize, 20), block.len);
    try testing.expect(id3Block("no tag here") == null);
}

test "frame header validation rejects noise" {
    try testing.expect(frameHeader(&[_]u8{ 0x00, 0x00, 0x00, 0x00 }) == null);
    try testing.expect(frameHeader(&[_]u8{ 0xFF, 0x00, 0x00, 0x00 }) == null);
    // Reserved layer.
    try testing.expect(frameHeader(&[_]u8{ 0xFF, 0xF9, 0x90, 0x00 }) == null);
    // Free-format bitrate index.
    try testing.expect(frameHeader(&[_]u8{ 0xFF, 0xFB, 0x00, 0x00 }) == null);
}

test "a known MPEG1 layer III header is measured correctly" {
    // FF FB 90 00: MPEG1 Layer III, 128 kbps, 44100 Hz, no padding.
    const h = frameHeader(&[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }).?;
    // 1152 / 8 * 128000 / 44100 = 417
    try testing.expectEqual(@as(usize, 417), h.frame_bytes);

    // With the padding bit set it is one byte longer.
    const padded = frameHeader(&[_]u8{ 0xFF, 0xFB, 0x92, 0x00 }).?;
    try testing.expectEqual(@as(usize, 418), padded.frame_bytes);
}

test "probing needs two consecutive headers" {
    if (!enabled) return error.SkipZigTest;
    // A lone sync word in random data must not be mistaken for MP3.
    var buf: [1024]u8 = @splat(0x5A);
    buf[100] = 0xFF;
    buf[101] = 0xFB;
    buf[102] = 0x90;
    buf[103] = 0x00;
    try testing.expect(!looksLikeMp3(&buf));

    // Two headers the right distance apart is convincing.
    var good: [2048]u8 = @splat(0);
    const hdr = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    @memcpy(good[0..4], &hdr);
    @memcpy(good[417..421], &hdr);
    try testing.expect(looksLikeMp3(&good));
}

test "an ID3 tag at the start is treated as MP3" {
    if (!enabled) return error.SkipZigTest;
    const tag = "ID3\x03\x00\x00\x00\x00\x00\x00";
    try testing.expect(looksLikeMp3(tag));
}
