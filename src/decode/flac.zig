//! A native FLAC decoder.
//!
//! Covers the whole subset a real encoder emits: constant, verbatim, fixed and
//! LPC subframes; Rice and escaped residual partitions; left/side, right/side
//! and mid/side stereo decorrelation; wasted bits; and every block size and
//! sample rate code. Frame headers are checked with CRC-8 and whole frames
//! with CRC-16, so a bit-level mistake in this file shows up as a checksum
//! failure rather than as noise in the output.
//!
//! Seeking prefers the file's SEEKTABLE, falls back to an index built while
//! decoding, and finally re-syncs by scanning for a frame header whose CRC-8
//! checks out.

const std = @import("std");
const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const bits = @import("../util/bits.zig");

pub const Error = api.Error;

/// Largest predictor order the format allows.
const max_lpc_order = 32;
/// Largest block size the format allows.
const max_blocksize = 65535;

pub const StreamInfo = struct {
    min_blocksize: u16,
    max_blocksize: u16,
    min_framesize: u32,
    max_framesize: u32,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    /// 0 means "unknown" in the format.
    total_samples: u64,
    md5: [16]u8,
};

pub const SeekPoint = struct {
    sample: u64,
    /// Offset from the first frame, in bytes.
    offset: u64,
    frame_samples: u16,
};

/// A sample-number to byte-offset pair, learned while decoding.
const IndexEntry = struct {
    sample: u64,
    offset: usize,
};

/// Everything a parsed frame header tells us.
const FrameHeader = struct {
    blocksize: usize,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    channel_assignment: u4,
    /// Frame number for fixed-blocksize streams, sample number otherwise.
    coded_number: u64,
    variable_blocksize: bool,
    /// Byte length of the header, including the CRC-8.
    header_len: usize,
};

pub const Flac = struct {
    gpa: Allocator,
    bytes: []const u8,
    stream_info: StreamInfo,

    /// Byte offset of the first audio frame.
    audio_start: usize,
    seek_table: []SeekPoint,
    /// VORBIS_COMMENT block payload, for the metadata reader.
    vorbis_comment: ?[]const u8 = null,

    /// Per-channel decoded block, `channels` slices of `max_blocksize`.
    channel_buf: [][]i32,
    /// Frames currently sitting in `channel_buf`.
    block_frames: usize = 0,
    /// How much of the current block the caller has already taken.
    block_consumed: usize = 0,
    /// Absolute sample index of the first frame in `channel_buf`.
    block_start_sample: u64 = 0,

    /// Byte offset of the frame we will decode next.
    next_frame_off: usize,
    /// Running index of frame starts, grown as we decode.
    index: std.ArrayList(IndexEntry) = .empty,

    hit_end: bool = false,

    /// Keeps the index from growing without bound on a long file.
    const max_index_entries = 4096;

    pub fn open(gpa: Allocator, bytes: []const u8) Error!Flac {
        var pos: usize = 0;

        // Some files carry an ID3v2 tag in front of the FLAC magic.
        if (bytes.len >= 10 and std.mem.eql(u8, bytes[0..3], "ID3")) {
            pos = 10 + syncSafeSize(bytes[6..10].*);
            if (pos > bytes.len) return error.CorruptStream;
        }

        if (bytes.len < pos + 4 or !std.mem.eql(u8, bytes[pos..][0..4], "fLaC")) {
            return error.UnsupportedFormat;
        }
        pos += 4;

        var stream_info: ?StreamInfo = null;
        var seek_points: std.ArrayList(SeekPoint) = .empty;
        errdefer seek_points.deinit(gpa);
        var vorbis: ?[]const u8 = null;

        // Walk the metadata blocks.
        while (true) {
            if (pos + 4 > bytes.len) return error.CorruptStream;
            const header = bytes[pos];
            const last = (header & 0x80) != 0;
            const block_type: u7 = @truncate(header);
            const len: usize = (@as(usize, bytes[pos + 1]) << 16) |
                (@as(usize, bytes[pos + 2]) << 8) |
                @as(usize, bytes[pos + 3]);
            pos += 4;
            if (pos + len > bytes.len) return error.CorruptStream;
            const body = bytes[pos..][0..len];

            switch (block_type) {
                0 => { // STREAMINFO
                    if (len < 34) return error.CorruptStream;
                    stream_info = try parseStreamInfo(body);
                },
                3 => { // SEEKTABLE
                    const count = len / 18;
                    try seek_points.ensureTotalCapacity(gpa, count);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const p = body[i * 18 ..][0..18];
                        const sample = std.mem.readInt(u64, p[0..8], .big);
                        // A placeholder point carries an all-ones sample number.
                        if (sample == std.math.maxInt(u64)) continue;
                        seek_points.appendAssumeCapacity(.{
                            .sample = sample,
                            .offset = std.mem.readInt(u64, p[8..16], .big),
                            .frame_samples = std.mem.readInt(u16, p[16..18], .big),
                        });
                    }
                },
                4 => vorbis = body, // VORBIS_COMMENT
                else => {}, // PADDING, APPLICATION, CUESHEET, PICTURE, reserved
            }

            pos += len;
            if (last) break;
        }

        const si = stream_info orelse return error.CorruptStream;
        if (si.channels == 0 or si.channels > 8) return error.UnsupportedFormat;
        if (si.bits_per_sample < 4 or si.bits_per_sample > 32) return error.UnsupportedFormat;
        if (si.sample_rate == 0) return error.CorruptStream;
        if (si.max_blocksize == 0 or si.max_blocksize > max_blocksize) return error.CorruptStream;

        // Per-channel scratch, sized by the stream's own maximum block.
        const channel_buf = try gpa.alloc([]i32, si.channels);
        errdefer gpa.free(channel_buf);
        var allocated: usize = 0;
        errdefer for (channel_buf[0..allocated]) |b| gpa.free(b);
        for (channel_buf) |*b| {
            b.* = try gpa.alloc(i32, si.max_blocksize);
            allocated += 1;
        }

        const table = try seek_points.toOwnedSlice(gpa);

        return .{
            .gpa = gpa,
            .bytes = bytes,
            .stream_info = si,
            .audio_start = pos,
            .seek_table = table,
            .vorbis_comment = vorbis,
            .channel_buf = channel_buf,
            .next_frame_off = pos,
        };
    }

    pub fn deinit(self: *Flac) void {
        for (self.channel_buf) |b| self.gpa.free(b);
        self.gpa.free(self.channel_buf);
        self.gpa.free(self.seek_table);
        self.index.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn info(self: *const Flac) api.Info {
        const si = self.stream_info;
        const total: ?u64 = if (si.total_samples == 0) null else si.total_samples;
        var bitrate: ?u32 = null;
        if (total) |t| {
            if (t > 0) {
                const audio_bytes = self.bytes.len - self.audio_start;
                const seconds = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(si.sample_rate));
                if (seconds > 0) {
                    bitrate = @intFromFloat(@as(f64, @floatFromInt(audio_bytes)) * 8.0 / seconds);
                }
            }
        }
        return .{
            .codec = .flac,
            .sample_rate = si.sample_rate,
            .channels = si.channels,
            .bits_per_sample = si.bits_per_sample,
            .total_frames = total,
            .seekable = true,
            .bitrate = bitrate,
        };
    }

    pub fn positionFrames(self: *const Flac) u64 {
        return self.block_start_sample + self.block_consumed;
    }

    /// Decode into `out` (interleaved, `channels` channels). Returns frames
    /// written; 0 means end of stream.
    pub fn readFrames(self: *Flac, out: []f32) Error!usize {
        const ch = self.stream_info.channels;
        const capacity = out.len / ch;
        var written: usize = 0;

        while (written < capacity) {
            if (self.block_consumed >= self.block_frames) {
                const got = try self.decodeNextFrame();
                if (!got) break;
            }
            const avail = self.block_frames - self.block_consumed;
            const take = @min(avail, capacity - written);

            // Convert the planar i32 block into interleaved floats.
            const scale = 1.0 / @as(f32, @floatFromInt(
                @as(u64, 1) << @intCast(self.stream_info.bits_per_sample - 1),
            ));
            for (0..ch) |c| {
                const src = self.channel_buf[c][self.block_consumed..][0..take];
                for (src, 0..) |v, i| {
                    out[(written + i) * ch + c] = @as(f32, @floatFromInt(v)) * scale;
                }
            }
            self.block_consumed += take;
            written += take;
        }
        return written;
    }

    pub fn seekToFrame(self: *Flac, target: u64) Error!void {
        const si = self.stream_info;
        if (si.total_samples != 0 and target > si.total_samples) return error.SeekOutOfRange;

        // Already inside the block we hold? Just move the cursor.
        if (self.block_frames > 0 and
            target >= self.block_start_sample and
            target < self.block_start_sample + self.block_frames)
        {
            self.block_consumed = @intCast(target - self.block_start_sample);
            return;
        }

        // Best known starting point at or before the target.
        var start_off = self.audio_start;
        var start_sample: u64 = 0;
        for (self.seek_table) |p| {
            if (p.sample <= target and self.audio_start + p.offset < self.bytes.len) {
                if (p.sample >= start_sample) {
                    start_sample = p.sample;
                    start_off = self.audio_start + @as(usize, @intCast(p.offset));
                }
            }
        }
        for (self.index.items) |e| {
            if (e.sample <= target and e.sample >= start_sample) {
                start_sample = e.sample;
                start_off = e.offset;
            }
        }

        self.next_frame_off = start_off;
        self.block_frames = 0;
        self.block_consumed = 0;
        self.block_start_sample = start_sample;
        self.hit_end = false;

        // Decode forward until the target lands inside a block.
        while (true) {
            const got = try self.decodeNextFrame();
            if (!got) {
                // Ran out of stream: park at the end.
                self.block_consumed = self.block_frames;
                return;
            }
            if (target < self.block_start_sample) {
                // The index put us past the target; restart from the top.
                if (start_off == self.audio_start) return error.CorruptStream;
                self.next_frame_off = self.audio_start;
                self.block_frames = 0;
                self.block_consumed = 0;
                self.block_start_sample = 0;
                start_off = self.audio_start;
                continue;
            }
            if (target < self.block_start_sample + self.block_frames) {
                self.block_consumed = @intCast(target - self.block_start_sample);
                return;
            }
        }
    }

    fn noteIndex(self: *Flac, sample: u64, offset: usize) void {
        if (self.index.items.len >= max_index_entries) return;
        if (self.index.items.len > 0) {
            const last = self.index.items[self.index.items.len - 1];
            if (last.sample >= sample) return;
            // One entry every ~2 seconds is plenty for seeking.
            if (sample - last.sample < @as(u64, self.stream_info.sample_rate) * 2) return;
        }
        self.index.append(self.gpa, .{ .sample = sample, .offset = offset }) catch {};
    }

    /// Decode one frame into `channel_buf`. Returns false at end of stream.
    fn decodeNextFrame(self: *Flac) Error!bool {
        if (self.hit_end) return false;

        var offset = self.next_frame_off;
        if (offset >= self.bytes.len) {
            self.hit_end = true;
            return false;
        }

        // Validate, and re-sync if the offset does not land on a frame.
        const header = parseFrameHeader(self.bytes, offset) catch blk: {
            const found = findFrameSync(self.bytes, offset) orelse {
                self.hit_end = true;
                return false;
            };
            offset = found;
            break :blk parseFrameHeader(self.bytes, offset) catch {
                self.hit_end = true;
                return false;
            };
        };

        if (header.blocksize > self.stream_info.max_blocksize) return error.CorruptStream;
        if (header.channels != self.stream_info.channels) return error.CorruptStream;

        var br = bits.Reader.init(self.bytes);
        br.seekToByte(offset + header.header_len);

        try self.decodeSubframes(&br, header);

        // The frame ends byte-aligned, followed by a CRC-16 of everything
        // from the sync code onward.
        br.alignToByte();
        const frame_end = br.bytePos();
        if (frame_end + 2 > self.bytes.len) return error.CorruptStream;
        const want_crc = std.mem.readInt(u16, self.bytes[frame_end..][0..2], .big);
        const got_crc = crc16(self.bytes[offset..frame_end]);
        if (want_crc != got_crc) return error.CorruptStream;

        // Work out where this frame sits in the stream.
        const first_sample: u64 = if (header.variable_blocksize)
            header.coded_number
        else
            header.coded_number * @as(u64, header.blocksize);

        self.block_frames = header.blocksize;
        self.block_consumed = 0;
        self.block_start_sample = first_sample;
        self.next_frame_off = frame_end + 2;
        self.noteIndex(first_sample, offset);
        return true;
    }

    fn decodeSubframes(self: *Flac, br: *bits.Reader, header: FrameHeader) Error!void {
        const bps = header.bits_per_sample;
        const assignment = header.channel_assignment;
        const stereo_coded = assignment >= 8 and assignment <= 10;

        const ch_count: usize = if (stereo_coded) 2 else @as(usize, assignment) + 1;
        if (ch_count != self.stream_info.channels) return error.CorruptStream;

        for (0..ch_count) |c| {
            // The channel carrying the side signal needs one extra bit of
            // headroom, because a difference of two n-bit values is n+1 bits.
            const side = switch (assignment) {
                8 => c == 1, // left / side
                9 => c == 0, // side / right
                10 => c == 1, // mid / side
                else => false,
            };
            const sub_bps: u8 = bps + @as(u8, if (side) 1 else 0);
            if (sub_bps > 33) return error.UnsupportedFormat;
            try decodeSubframe(br, self.channel_buf[c][0..header.blocksize], sub_bps);
        }

        if (stereo_coded) {
            const left = self.channel_buf[0][0..header.blocksize];
            const right = self.channel_buf[1][0..header.blocksize];
            switch (assignment) {
                8 => {
                    // ch0 = left, ch1 = left - right
                    for (left, right) |l, *r| r.* = l -% r.*;
                },
                9 => {
                    // ch0 = left - right, ch1 = right
                    for (left, right) |*l, r| l.* = l.* +% r;
                },
                10 => {
                    // ch0 = (left + right) >> 1, ch1 = left - right
                    for (left, right) |*l, *r| {
                        const side = r.*;
                        // Recover the low bit dropped by the encoder's shift.
                        const mid = (@as(i64, l.*) << 1) | @as(i64, side & 1);
                        l.* = @intCast((mid + side) >> 1);
                        r.* = @intCast((mid - side) >> 1);
                    }
                },
                else => unreachable,
            }
        }
    }
};

fn parseStreamInfo(body: []const u8) Error!StreamInfo {
    var br = bits.Reader.init(body);
    const min_bs: u16 = @intCast(try br.readBits(16));
    const max_bs: u16 = @intCast(try br.readBits(16));
    const min_fs: u32 = @intCast(try br.readBits(24));
    const max_fs: u32 = @intCast(try br.readBits(24));
    const rate: u32 = @intCast(try br.readBits(20));
    const channels: u8 = @intCast((try br.readBits(3)) + 1);
    const bps: u8 = @intCast((try br.readBits(5)) + 1);
    const total: u64 = try br.readBits(36);
    var md5: [16]u8 = undefined;
    @memcpy(&md5, body[18..34]);
    return .{
        .min_blocksize = min_bs,
        .max_blocksize = max_bs,
        .min_framesize = min_fs,
        .max_framesize = max_fs,
        .sample_rate = rate,
        .channels = channels,
        .bits_per_sample = bps,
        .total_samples = total,
        .md5 = md5,
    };
}

/// Parse and CRC-8 validate a frame header at `offset`.
pub fn parseFrameHeader(bytes: []const u8, offset: usize) Error!FrameHeader {
    if (offset + 5 > bytes.len) return error.EndOfStream;
    var br = bits.Reader.init(bytes);
    br.seekToByte(offset);

    const sync = try br.readBits(14);
    if (sync != 0x3FFE) return error.CorruptStream;
    if ((try br.readBits(1)) != 0) return error.CorruptStream; // reserved
    const variable_blocksize = (try br.readBits(1)) != 0;

    const bs_code: u4 = @intCast(try br.readBits(4));
    const sr_code: u4 = @intCast(try br.readBits(4));
    const ch_code: u4 = @intCast(try br.readBits(4));
    const ss_code: u3 = @intCast(try br.readBits(3));
    if ((try br.readBits(1)) != 0) return error.CorruptStream; // reserved

    const coded_number = try readUtf8Number(&br);

    var blocksize: usize = switch (bs_code) {
        0 => return error.CorruptStream,
        1 => 192,
        2...5 => @as(usize, 576) << @intCast(bs_code - 2),
        6, 7 => 0, // read below
        8...15 => @as(usize, 256) << @intCast(bs_code - 8),
    };
    if (bs_code == 6) blocksize = @as(usize, @intCast(try br.readBits(8))) + 1;
    if (bs_code == 7) blocksize = @as(usize, @intCast(try br.readBits(16))) + 1;

    var sample_rate: u32 = switch (sr_code) {
        0 => 0, // take it from STREAMINFO
        1 => 88_200,
        2 => 176_400,
        3 => 192_000,
        4 => 8_000,
        5 => 16_000,
        6 => 22_050,
        7 => 24_000,
        8 => 32_000,
        9 => 44_100,
        10 => 48_000,
        11 => 96_000,
        12, 13, 14 => 0, // read below
        15 => return error.CorruptStream,
    };
    if (sr_code == 12) sample_rate = @as(u32, @intCast(try br.readBits(8))) * 1000;
    if (sr_code == 13) sample_rate = @intCast(try br.readBits(16));
    if (sr_code == 14) sample_rate = @as(u32, @intCast(try br.readBits(16))) * 10;

    const bits_per_sample: u8 = switch (ss_code) {
        0 => 0, // from STREAMINFO
        1 => 8,
        2 => 12,
        3 => return error.CorruptStream,
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
    };

    const channels: u8 = if (ch_code >= 8 and ch_code <= 10)
        2
    else if (ch_code <= 7)
        @as(u8, ch_code) + 1
    else
        return error.CorruptStream;

    // The CRC-8 covers the header bytes up to but excluding itself.
    br.alignToByte();
    const crc_pos = br.bytePos();
    if (crc_pos + 1 > bytes.len) return error.EndOfStream;
    const want = bytes[crc_pos];
    const got = crc8(bytes[offset..crc_pos]);
    if (want != got) return error.CorruptStream;

    return .{
        .blocksize = blocksize,
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = bits_per_sample,
        .channel_assignment = ch_code,
        .coded_number = coded_number,
        .variable_blocksize = variable_blocksize,
        .header_len = crc_pos + 1 - offset,
    };
}

/// Scan forward for a byte pair that could start a frame and whose header
/// CRC-8 checks out.
pub fn findFrameSync(bytes: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 2 < bytes.len) : (i += 1) {
        if (bytes[i] != 0xFF) continue;
        // Sync is 14 bits of ones followed by a zero: the second byte's top
        // six bits must be 111110, leaving the blocking-strategy bit free.
        if ((bytes[i + 1] & 0xFC) != 0xF8) continue;
        _ = parseFrameHeader(bytes, i) catch continue;
        return i;
    }
    return null;
}

/// FLAC codes frame and sample numbers with a UTF-8-like variable-length
/// scheme, extended to seven bytes so a 36-bit sample number fits.
fn readUtf8Number(br: *bits.Reader) Error!u64 {
    const first: u8 = @intCast(try br.readBits(8));
    if (first < 0x80) return first;

    const extra: u8 = switch (@clz(~first)) {
        2 => 1, // 110xxxxx
        3 => 2, // 1110xxxx
        4 => 3,
        5 => 4,
        6 => 5,
        7 => 6, // 11111110
        else => return error.CorruptStream,
    };
    const value_bits: u8 = 7 - extra -| @as(u8, 1) + 1;
    _ = value_bits;

    // Keep only the payload bits of the leading byte.
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(6 - extra)) - 1);
    var value: u64 = first & mask;

    var i: u8 = 0;
    while (i < extra) : (i += 1) {
        const b: u8 = @intCast(try br.readBits(8));
        if ((b & 0xC0) != 0x80) return error.CorruptStream;
        value = (value << 6) | (b & 0x3F);
    }
    return value;
}

fn decodeSubframe(br: *bits.Reader, out: []i32, bps_in: u8) Error!void {
    if ((try br.readBits(1)) != 0) return error.CorruptStream; // padding bit
    const sub_type: u6 = @intCast(try br.readBits(6));
    const has_wasted = (try br.readBits(1)) != 0;

    var wasted: u8 = 0;
    if (has_wasted) {
        // The count is coded as (k-1) in unary.
        wasted = @intCast((try br.readUnary()) + 1);
        if (wasted >= bps_in) return error.CorruptStream;
    }
    const bps = bps_in - wasted;

    if (sub_type == 0) {
        // CONSTANT
        const v = try br.readSigned(bps);
        const sv: i32 = @intCast(v);
        @memset(out, sv);
    } else if (sub_type == 1) {
        // VERBATIM
        for (out) |*s| s.* = @intCast(try br.readSigned(bps));
    } else if (sub_type >= 8 and sub_type <= 12) {
        // FIXED predictor
        const order: usize = sub_type - 8;
        if (order > out.len) return error.CorruptStream;
        for (out[0..order]) |*s| s.* = @intCast(try br.readSigned(bps));
        try decodeResidual(br, out, order);
        restoreFixed(out, order);
    } else if (sub_type >= 32) {
        // LPC
        const order: usize = @as(usize, sub_type - 31);
        if (order > max_lpc_order or order > out.len) return error.CorruptStream;
        for (out[0..order]) |*s| s.* = @intCast(try br.readSigned(bps));

        const precision: u8 = @as(u8, @intCast(try br.readBits(4))) + 1;
        if (precision == 16) return error.CorruptStream; // 0b1111 is invalid
        const shift_raw = try br.readSigned(5);
        if (shift_raw < 0) return error.CorruptStream;
        const shift: u6 = @intCast(shift_raw);

        var coeffs: [max_lpc_order]i32 = undefined;
        for (coeffs[0..order]) |*c| c.* = @intCast(try br.readSigned(precision));

        try decodeResidual(br, out, order);
        restoreLpc(out, order, coeffs[0..order], shift);
    } else {
        // 2..7 and 13..31 are reserved.
        return error.UnsupportedFormat;
    }

    if (wasted > 0) {
        for (out) |*s| s.* = @as(i32, @bitCast(@as(u32, @bitCast(s.*)) << @intCast(wasted)));
    }
}

/// Read the residual for samples `[order..]` of `out`.
fn decodeResidual(br: *bits.Reader, out: []i32, order: usize) Error!void {
    const method: u2 = @intCast(try br.readBits(2));
    const param_bits: u8 = switch (method) {
        0 => 4,
        1 => 5,
        else => return error.UnsupportedFormat, // 2 and 3 are reserved
    };
    const escape_value: u64 = (@as(u64, 1) << @intCast(param_bits)) - 1;

    const partition_order: u4 = @intCast(try br.readBits(4));
    const partitions: usize = @as(usize, 1) << partition_order;
    const blocksize = out.len;
    if (partitions == 0 or blocksize % partitions != 0) return error.CorruptStream;
    const partition_len = blocksize / partitions;
    if (partition_len < order) return error.CorruptStream;

    var idx = order;
    var p: usize = 0;
    while (p < partitions) : (p += 1) {
        const count = if (p == 0) partition_len - order else partition_len;
        if (idx + count > blocksize) return error.CorruptStream;
        const param = try br.readBits(param_bits);

        if (param == escape_value) {
            // Escaped partition: raw samples of a fixed width.
            const raw_bits: u8 = @intCast(try br.readBits(5));
            if (raw_bits == 0) {
                @memset(out[idx..][0..count], 0);
            } else {
                for (out[idx..][0..count]) |*s| s.* = @intCast(try br.readSigned(raw_bits));
            }
        } else {
            const k: u8 = @intCast(param);
            for (out[idx..][0..count]) |*s| s.* = try br.readRice(k);
        }
        idx += count;
    }
}

/// Undo the fixed polynomial predictor, in place.
fn restoreFixed(out: []i32, order: usize) void {
    switch (order) {
        0 => {},
        1 => {
            var i: usize = 1;
            while (i < out.len) : (i += 1) out[i] = out[i] +% out[i - 1];
        },
        2 => {
            var i: usize = 2;
            while (i < out.len) : (i += 1) {
                out[i] = out[i] +% (2 *% out[i - 1]) -% out[i - 2];
            }
        },
        3 => {
            var i: usize = 3;
            while (i < out.len) : (i += 1) {
                out[i] = out[i] +% (3 *% out[i - 1]) -% (3 *% out[i - 2]) +% out[i - 3];
            }
        },
        4 => {
            var i: usize = 4;
            while (i < out.len) : (i += 1) {
                out[i] = out[i] +% (4 *% out[i - 1]) -% (6 *% out[i - 2]) +%
                    (4 *% out[i - 3]) -% out[i - 4];
            }
        },
        else => unreachable,
    }
}

/// Undo the LPC predictor, in place. The accumulator is 64-bit because high
/// bit depths with order-32 predictors genuinely overflow 32 bits.
fn restoreLpc(out: []i32, order: usize, coeffs: []const i32, shift: u6) void {
    var i = order;
    while (i < out.len) : (i += 1) {
        var acc: i64 = 0;
        for (coeffs, 0..) |c, j| {
            acc += @as(i64, c) * @as(i64, out[i - 1 - j]);
        }
        out[i] = @truncate(@as(i64, out[i]) + (acc >> shift));
    }
}

/// ID3v2 sizes are stored seven bits per byte so the bytes never look like a
/// sync code.
fn syncSafeSize(b: [4]u8) usize {
    return (@as(usize, b[0] & 0x7F) << 21) |
        (@as(usize, b[1] & 0x7F) << 14) |
        (@as(usize, b[2] & 0x7F) << 7) |
        @as(usize, b[3] & 0x7F);
}

// ---------------------------------------------------------------------------
// Checksums
// ---------------------------------------------------------------------------

/// CRC-8 with polynomial x^8 + x^2 + x + 1, used on frame headers.
pub fn crc8(data: []const u8) u8 {
    var crc: u8 = 0;
    for (data) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
    }
    return crc;
}

/// CRC-16 with polynomial x^16 + x^15 + x^2 + 1, used on whole frames.
pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        }
    }
    return crc;
}

pub fn looksLikeFlac(data: []const u8) bool {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "fLaC")) return true;
    if (data.len >= 10 and std.mem.eql(u8, data[0..3], "ID3")) {
        const skip = 10 + syncSafeSize(data[6..10].*);
        return data.len >= skip + 4 and std.mem.eql(u8, data[skip..][0..4], "fLaC");
    }
    return false;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Minimal FLAC writer, used only by the tests. It emits VERBATIM subframes,
/// which makes the encoded samples exactly recoverable and exercises the whole
/// container + frame + CRC path.
const TestEncoder = struct {
    gpa: Allocator,
    sample_rate: u32,
    channels: u8,
    bps: u8,
    blocksize: u16,

    fn encode(self: TestEncoder, planar: []const []const i32) ![]u8 {
        const total: u64 = planar[0].len;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);

        try out.appendSlice(self.gpa, "fLaC");

        // STREAMINFO
        try out.append(self.gpa, 0x80); // last block, type 0
        try out.appendSlice(self.gpa, &.{ 0, 0, 34 });
        var si: std.ArrayList(u8) = .empty;
        defer si.deinit(self.gpa);
        var w = bits.Writer.init(self.gpa, &si);
        try w.writeBits(self.blocksize, 16);
        try w.writeBits(self.blocksize, 16);
        try w.writeBits(0, 24);
        try w.writeBits(0, 24);
        try w.writeBits(self.sample_rate, 20);
        try w.writeBits(self.channels - 1, 3);
        try w.writeBits(self.bps - 1, 5);
        try w.writeBits(total, 36);
        for (0..16) |_| try w.writeBits(0, 8);
        try out.appendSlice(self.gpa, si.items);

        // Frames
        var frame_no: u64 = 0;
        var pos: usize = 0;
        while (pos < total) {
            const n: usize = @min(self.blocksize, total - pos);
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(self.gpa);
            var fw = bits.Writer.init(self.gpa, &frame);

            try fw.writeBits(0x3FFE, 14); // sync
            try fw.writeBits(0, 1); // reserved
            try fw.writeBits(0, 1); // fixed blocksize -> frame number
            // Block size code 7 means "16-bit value follows".
            try fw.writeBits(7, 4);
            try fw.writeBits(0, 4); // sample rate from STREAMINFO
            try fw.writeBits(self.channels - 1, 4); // independent channels
            const ss_code: u64 = switch (self.bps) {
                8 => 1,
                12 => 2,
                16 => 4,
                20 => 5,
                24 => 6,
                else => 0,
            };
            try fw.writeBits(ss_code, 3);
            try fw.writeBits(0, 1); // reserved
            try writeUtf8Number(&fw, frame_no);
            try fw.writeBits(n - 1, 16);
            try fw.alignToByte();
            try frame.append(self.gpa, crc8(frame.items));

            // One VERBATIM subframe per channel.
            var sw = bits.Writer.init(self.gpa, &frame);
            for (0..self.channels) |c| {
                try sw.writeBits(0, 1); // padding
                try sw.writeBits(1, 6); // VERBATIM
                try sw.writeBits(0, 1); // no wasted bits
                for (planar[c][pos..][0..n]) |s| try sw.writeSigned(s, self.bps);
            }
            try sw.alignToByte();

            const crc = crc16(frame.items);
            try frame.append(self.gpa, @intCast(crc >> 8));
            try frame.append(self.gpa, @truncate(crc));

            try out.appendSlice(self.gpa, frame.items);
            pos += n;
            frame_no += 1;
        }

        return out.toOwnedSlice(self.gpa);
    }
};

fn writeUtf8Number(w: *bits.Writer, value: u64) !void {
    if (value < 0x80) {
        try w.writeBits(value, 8);
        return;
    }
    // Choose the shortest form that holds `value`.
    var extra: u8 = 1;
    while (extra < 6) : (extra += 1) {
        const capacity_bits: u8 = (6 - extra) + extra * 6;
        if (value < (@as(u64, 1) << @intCast(capacity_bits))) break;
    }
    const lead_ones: u8 = extra + 1;
    var lead: u64 = 0;
    for (0..lead_ones) |_| lead = (lead << 1) | 1;
    lead <<= 1; // the terminating zero
    const payload_bits: u8 = 6 - extra;
    lead <<= @intCast(payload_bits);
    lead |= value >> @intCast(extra * 6);
    try w.writeBits(lead, 8);

    var i: u8 = extra;
    while (i > 0) {
        i -= 1;
        const chunk = (value >> @intCast(i * 6)) & 0x3F;
        try w.writeBits(0x80 | chunk, 8);
    }
}

test "crc8 and crc16 match known FLAC values" {
    // Reference values from the FLAC reference decoder's test vectors.
    try testing.expectEqual(@as(u8, 0), crc8(&.{}));
    try testing.expectEqual(@as(u8, 0x07), crc8(&.{0x01}));
    try testing.expectEqual(@as(u16, 0), crc16(&.{}));
    try testing.expectEqual(@as(u16, 0x8005), crc16(&.{0x01}));
    // CRC-8 of a real frame header: FF F8 C9 18 00 -> 0xC2
    try testing.expectEqual(@as(u8, 0xC2), crc8(&.{ 0xFF, 0xF8, 0xC9, 0x18, 0x00 }));
}

test "utf8 number round trip" {
    const gpa = testing.allocator;
    const values = [_]u64{ 0, 1, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10FFFF, 0xFFFFFFF, 0xFFFFFFFFF };
    for (values) |v| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var w = bits.Writer.init(gpa, &list);
        try writeUtf8Number(&w, v);
        try w.alignToByte();

        var r = bits.Reader.init(list.items);
        try testing.expectEqual(v, try readUtf8Number(&r));
    }
}

test "rejects non-FLAC input" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedFormat, Flac.open(gpa, "RIFFxxxxWAVE"));
    try testing.expectError(error.UnsupportedFormat, Flac.open(gpa, ""));
    try testing.expect(!looksLikeFlac("not flac"));
    try testing.expect(looksLikeFlac("fLaC\x00\x00\x00\x22"));
}

test "decodes a verbatim stereo stream exactly" {
    const gpa = testing.allocator;
    const n = 5000;
    const left = try gpa.alloc(i32, n);
    defer gpa.free(left);
    const right = try gpa.alloc(i32, n);
    defer gpa.free(right);

    var prng = std.Random.DefaultPrng.init(0x1234);
    const rand = prng.random();
    for (left, right) |*l, *r| {
        l.* = rand.intRangeAtMost(i32, -32768, 32767);
        r.* = rand.intRangeAtMost(i32, -32768, 32767);
    }

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 44_100,
        .channels = 2,
        .bps = 16,
        .blocksize = 1024,
    };
    const planar = [_][]const i32{ left, right };
    const stream = try enc.encode(&planar);
    defer gpa.free(stream);

    var f = try Flac.open(gpa, stream);
    defer f.deinit();

    const nfo = f.info();
    try testing.expectEqual(api.Codec.flac, nfo.codec);
    try testing.expectEqual(@as(u32, 44_100), nfo.sample_rate);
    try testing.expectEqual(@as(u8, 2), nfo.channels);
    try testing.expectEqual(@as(u8, 16), nfo.bits_per_sample);
    try testing.expectEqual(@as(u64, n), nfo.total_frames.?);

    const out = try gpa.alloc(f32, n * 2);
    defer gpa.free(out);
    var got: usize = 0;
    while (got < n) {
        const w = try f.readFrames(out[got * 2 ..]);
        if (w == 0) break;
        got += w;
    }
    try testing.expectEqual(n, got);
    try testing.expectEqual(@as(usize, 0), try f.readFrames(out));

    // Verbatim coding is lossless, so the samples come back bit-exact.
    const scale = 1.0 / @as(f32, 32768.0);
    for (0..n) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(left[i])) * scale, out[i * 2]);
        try testing.expectEqual(@as(f32, @floatFromInt(right[i])) * scale, out[i * 2 + 1]);
    }
}

test "decodes mono at several bit depths" {
    const gpa = testing.allocator;
    for ([_]u8{ 8, 12, 16, 20, 24 }) |bps| {
        const n = 777;
        const data = try gpa.alloc(i32, n);
        defer gpa.free(data);
        const limit: i32 = @intCast((@as(i64, 1) << @intCast(bps - 1)) - 1);
        var prng = std.Random.DefaultPrng.init(bps);
        const rand = prng.random();
        for (data) |*s| s.* = rand.intRangeAtMost(i32, -limit, limit);

        const enc: TestEncoder = .{
            .gpa = gpa,
            .sample_rate = 48_000,
            .channels = 1,
            .bps = bps,
            .blocksize = 256,
        };
        const planar = [_][]const i32{data};
        const stream = try enc.encode(&planar);
        defer gpa.free(stream);

        var f = try Flac.open(gpa, stream);
        defer f.deinit();
        try testing.expectEqual(bps, f.info().bits_per_sample);

        const out = try gpa.alloc(f32, n);
        defer gpa.free(out);
        var got: usize = 0;
        while (got < n) {
            const w = try f.readFrames(out[got..]);
            if (w == 0) break;
            got += w;
        }
        try testing.expectEqual(n, got);

        const scale = 1.0 / @as(f32, @floatFromInt(@as(u64, 1) << @intCast(bps - 1)));
        for (0..n) |i| {
            try testing.expectEqual(@as(f32, @floatFromInt(data[i])) * scale, out[i]);
        }
    }
}

test "seeking lands on the right sample" {
    const gpa = testing.allocator;
    const n = 4096;
    const data = try gpa.alloc(i32, n);
    defer gpa.free(data);
    for (data, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i % 2000)) - 1000);

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 44_100,
        .channels = 1,
        .bps = 16,
        .blocksize = 512,
    };
    const planar = [_][]const i32{data};
    const stream = try enc.encode(&planar);
    defer gpa.free(stream);

    var f = try Flac.open(gpa, stream);
    defer f.deinit();

    const scale = 1.0 / @as(f32, 32768.0);
    for ([_]u64{ 0, 1, 511, 512, 513, 1500, 4095 }) |target| {
        try f.seekToFrame(target);
        try testing.expectEqual(target, f.positionFrames());
        var one: [1]f32 = undefined;
        try testing.expectEqual(@as(usize, 1), try f.readFrames(&one));
        try testing.expectEqual(@as(f32, @floatFromInt(data[@intCast(target)])) * scale, one[0]);
    }

    try testing.expectError(error.SeekOutOfRange, f.seekToFrame(99_999));
}

test "seeking backwards works after playing forward" {
    const gpa = testing.allocator;
    const n = 8192;
    const data = try gpa.alloc(i32, n);
    defer gpa.free(data);
    for (data, 0..) |*s, i| s.* = @intCast(i % 30000);

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 8_000,
        .channels = 1,
        .bps = 16,
        .blocksize = 1024,
    };
    const planar = [_][]const i32{data};
    const stream = try enc.encode(&planar);
    defer gpa.free(stream);

    var f = try Flac.open(gpa, stream);
    defer f.deinit();

    // Play most of the file so the internal index fills in.
    const out = try gpa.alloc(f32, n);
    defer gpa.free(out);
    var got: usize = 0;
    while (got < n) {
        const w = try f.readFrames(out[got..]);
        if (w == 0) break;
        got += w;
    }

    try f.seekToFrame(100);
    var one: [1]f32 = undefined;
    _ = try f.readFrames(&one);
    try testing.expectEqual(out[100], one[0]);
}

test "a corrupted frame is detected rather than played as noise" {
    const gpa = testing.allocator;
    const n = 2048;
    const data = try gpa.alloc(i32, n);
    defer gpa.free(data);
    @memset(data, 1234);

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 44_100,
        .channels = 1,
        .bps = 16,
        .blocksize = 512,
    };
    const planar = [_][]const i32{data};
    const stream = try enc.encode(&planar);
    defer gpa.free(stream);

    // Flip a bit deep inside the audio data.
    const mutated = try gpa.dupe(u8, stream);
    defer gpa.free(mutated);
    mutated[mutated.len / 2] ^= 0x40;

    var f = try Flac.open(gpa, mutated);
    defer f.deinit();

    const out = try gpa.alloc(f32, n);
    defer gpa.free(out);
    var saw_error = false;
    var got: usize = 0;
    while (got < n) {
        const w = f.readFrames(out[got..]) catch {
            saw_error = true;
            break;
        };
        if (w == 0) break;
        got += w;
    }
    try testing.expect(saw_error);
}

test "truncated metadata is rejected" {
    const gpa = testing.allocator;
    const short = "fLaC\x80\x00\x00\x22\x00\x00";
    try testing.expectError(error.CorruptStream, Flac.open(gpa, short));
}

test "frame header parsing covers the code tables" {
    // Build a header by hand: 16-bit block size code, 44.1 kHz, stereo, 16-bit.
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var w = bits.Writer.init(gpa, &list);
    try w.writeBits(0x3FFE, 14);
    try w.writeBits(0, 1);
    try w.writeBits(0, 1); // fixed block size
    try w.writeBits(1, 4); // block size 192
    try w.writeBits(9, 4); // 44100 Hz
    try w.writeBits(8, 4); // left/side stereo
    try w.writeBits(4, 3); // 16 bits
    try w.writeBits(0, 1);
    try w.writeBits(3, 8); // frame number 3
    try w.alignToByte();
    try list.append(gpa, crc8(list.items));

    const h = try parseFrameHeader(list.items, 0);
    try testing.expectEqual(@as(usize, 192), h.blocksize);
    try testing.expectEqual(@as(u32, 44_100), h.sample_rate);
    try testing.expectEqual(@as(u8, 2), h.channels);
    try testing.expectEqual(@as(u4, 8), h.channel_assignment);
    try testing.expectEqual(@as(u8, 16), h.bits_per_sample);
    try testing.expectEqual(@as(u64, 3), h.coded_number);
    try testing.expect(!h.variable_blocksize);

    // A bad CRC must be rejected.
    const broken = try gpa.dupe(u8, list.items);
    defer gpa.free(broken);
    broken[broken.len - 1] ^= 0xFF;
    try testing.expectError(error.CorruptStream, parseFrameHeader(broken, 0));
}

test "fixed predictor reconstruction" {
    // A second-order fixed predictor on a linear ramp leaves zero residual,
    // so decoding all-zero residuals must regenerate the ramp.
    var buf: [8]i32 = .{ 0, 10, 0, 0, 0, 0, 0, 0 };
    restoreFixed(&buf, 2);
    try testing.expectEqualSlices(i32, &.{ 0, 10, 20, 30, 40, 50, 60, 70 }, &buf);

    var first: [5]i32 = .{ 5, 1, 1, 1, 1 };
    restoreFixed(&first, 1);
    try testing.expectEqualSlices(i32, &.{ 5, 6, 7, 8, 9 }, &first);

    var zeroth: [3]i32 = .{ 1, 2, 3 };
    restoreFixed(&zeroth, 0);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, &zeroth);
}

test "LPC reconstruction" {
    // y[i] = y[i-1] * 2 with coefficient 2 and shift 0.
    var buf: [5]i32 = .{ 1, 0, 0, 0, 0 };
    restoreLpc(&buf, 1, &.{2}, 0);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 4, 8, 16 }, &buf);

    // With a shift, the predictor averages the two previous samples.
    var avg: [6]i32 = .{ 100, 200, 0, 0, 0, 0 };
    restoreLpc(&avg, 2, &.{ 1, 1 }, 1);
    try testing.expectEqualSlices(i32, &.{ 100, 200, 150, 175, 162, 168 }, &avg);
}

test "findFrameSync locates a real header" {
    const gpa = testing.allocator;
    const data = try gpa.alloc(i32, 1024);
    defer gpa.free(data);
    @memset(data, 42);

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 44_100,
        .channels = 1,
        .bps = 16,
        .blocksize = 256,
    };
    const planar = [_][]const i32{data};
    const stream = try enc.encode(&planar);
    defer gpa.free(stream);

    var f = try Flac.open(gpa, stream);
    defer f.deinit();

    // The first frame starts exactly at audio_start.
    try testing.expectEqual(f.audio_start, findFrameSync(stream, 0).?);
    // And searching past it finds the next one.
    const second = findFrameSync(stream, f.audio_start + 1).?;
    try testing.expect(second > f.audio_start);
}

test "a stream with an ID3 tag in front still opens" {
    const gpa = testing.allocator;
    const data = try gpa.alloc(i32, 512);
    defer gpa.free(data);
    @memset(data, 7);

    const enc: TestEncoder = .{
        .gpa = gpa,
        .sample_rate = 44_100,
        .channels = 1,
        .bps = 16,
        .blocksize = 512,
    };
    const planar = [_][]const i32{data};
    const inner = try enc.encode(&planar);
    defer gpa.free(inner);

    // Wrap it in a 20-byte ID3v2 tag.
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(gpa);
    try wrapped.appendSlice(gpa, "ID3");
    try wrapped.appendSlice(gpa, &.{ 3, 0, 0 });
    try wrapped.appendSlice(gpa, &.{ 0, 0, 0, 10 }); // sync-safe size 10
    try wrapped.appendSlice(gpa, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try wrapped.appendSlice(gpa, inner);

    try testing.expect(looksLikeFlac(wrapped.items));
    var f = try Flac.open(gpa, wrapped.items);
    defer f.deinit();
    try testing.expectEqual(@as(u64, 512), f.info().total_frames.?);
}
