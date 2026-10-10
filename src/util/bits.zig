//! MSB-first bit reader over a byte slice, with the primitives FLAC needs:
//! unary codes, two's-complement fields of arbitrary width, and Rice codes.

const std = @import("std");

pub const Error = error{
    /// Ran off the end of the buffer.
    EndOfStream,
    /// A code in the stream is impossible (e.g. an unterminated unary run).
    CorruptStream,
};

/// Guard against a corrupt stream turning a unary read into a near-infinite
/// loop. No legitimate FLAC residual needs a quotient anywhere near this.
const max_unary: u32 = 1 << 24;

pub const Reader = struct {
    data: []const u8,
    /// Absolute position, in bits, from the start of `data`.
    bit_pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn bitsLeft(r: *const Reader) usize {
        const total = r.data.len * 8;
        return if (r.bit_pos >= total) 0 else total - r.bit_pos;
    }

    pub fn isByteAligned(r: *const Reader) bool {
        return r.bit_pos % 8 == 0;
    }

    /// Byte offset of the read cursor, rounded down.
    pub fn bytePos(r: *const Reader) usize {
        return r.bit_pos / 8;
    }

    pub fn seekToBit(r: *Reader, bit: usize) void {
        r.bit_pos = bit;
    }

    pub fn seekToByte(r: *Reader, byte: usize) void {
        r.bit_pos = byte * 8;
    }

    /// Discard bits up to the next byte boundary.
    pub fn alignToByte(r: *Reader) void {
        const rem = r.bit_pos % 8;
        if (rem != 0) r.bit_pos += 8 - rem;
    }

    pub fn skipBits(r: *Reader, n: usize) Error!void {
        if (r.bitsLeft() < n) return error.EndOfStream;
        r.bit_pos += n;
    }

    pub fn readBit(r: *Reader) Error!u1 {
        if (r.bitsLeft() == 0) return error.EndOfStream;
        const byte = r.data[r.bit_pos >> 3];
        const shift: u3 = @intCast(7 - (r.bit_pos & 7));
        r.bit_pos += 1;
        return @truncate(byte >> shift);
    }

    /// Read `n` bits (0..64) as an unsigned value, most significant bit first.
    pub fn readBits(r: *Reader, n: u8) Error!u64 {
        if (n == 0) return 0;
        if (n > 64) return error.CorruptStream;
        if (r.bitsLeft() < n) return error.EndOfStream;

        var result: u64 = 0;
        var remaining: usize = n;
        while (remaining > 0) {
            const byte_idx = r.bit_pos >> 3;
            const bit_off: usize = r.bit_pos & 7;
            const avail = 8 - bit_off;
            const take = @min(avail, remaining);

            const shift: u3 = @intCast(avail - take);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(take)) - 1);
            const chunk: u8 = (r.data[byte_idx] >> shift) & mask;

            result = (result << @intCast(take)) | chunk;
            r.bit_pos += take;
            remaining -= take;
        }
        return result;
    }

    /// Read `n` bits as a two's-complement signed value.
    pub fn readSigned(r: *Reader, n: u8) Error!i64 {
        if (n == 0) return 0;
        if (n > 64) return error.CorruptStream;
        const raw = try r.readBits(n);
        // Park the value at the top of an i64 and shift back down, which
        // sign-extends for free.
        const shift: u6 = @intCast(64 - @as(u16, n));
        const parked: i64 = @bitCast(raw << shift);
        return parked >> shift;
    }

    /// Count zero bits up to and including the terminating one bit, returning
    /// the number of zeros.
    pub fn readUnary(r: *Reader) Error!u32 {
        var count: u32 = 0;
        while (true) {
            if (r.bitsLeft() == 0) return error.EndOfStream;
            const byte_idx = r.bit_pos >> 3;
            const bit_off: u3 = @intCast(r.bit_pos & 7);
            // Shift the already-consumed bits out of the way.
            const rest: u8 = r.data[byte_idx] << bit_off;
            if (rest == 0) {
                const skipped = 8 - @as(usize, bit_off);
                count += @intCast(skipped);
                r.bit_pos += skipped;
                if (count > max_unary) return error.CorruptStream;
                continue;
            }
            const lead: u32 = @clz(rest);
            count += lead;
            // Consume the zeros and the stop bit.
            r.bit_pos += @as(usize, lead) + 1;
            if (count > max_unary) return error.CorruptStream;
            return count;
        }
    }

    /// Read one Rice-coded residual with parameter `k`.
    ///
    /// The quotient arrives as a unary run, the remainder as `k` raw bits, and
    /// the combined value is zigzag-encoded (even values are non-negative, odd
    /// values are negative) so small magnitudes stay short regardless of sign.
    pub fn readRice(r: *Reader, k: u8) Error!i32 {
        const q: u64 = try r.readUnary();
        const rem: u64 = if (k == 0) 0 else try r.readBits(k);
        if (k >= 64) return error.CorruptStream;
        const value: u64 = (q << @intCast(k)) | rem;
        if (value > std.math.maxInt(u32)) return error.CorruptStream;
        const v: u32 = @intCast(value);
        return if (v & 1 != 0)
            -@as(i32, @intCast((v >> 1) + 1))
        else
            @intCast(v >> 1);
    }
};

/// Bit writer, MSB-first. Used by the test suite to build bitstreams, and by
/// the FLAC writer in the offline exporter.
pub const Writer = struct {
    list: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    /// Bits already filled in the byte under construction.
    partial: u8 = 0,
    partial_bits: u4 = 0,

    pub fn init(gpa: std.mem.Allocator, list: *std.ArrayList(u8)) Writer {
        return .{ .list = list, .gpa = gpa };
    }

    pub fn writeBits(w: *Writer, value: u64, n: u8) !void {
        if (n == 0) return;
        std.debug.assert(n <= 64);
        var i: u8 = n;
        while (i > 0) {
            i -= 1;
            const bit: u1 = @truncate(value >> @intCast(i));
            w.partial = (w.partial << 1) | bit;
            w.partial_bits += 1;
            if (w.partial_bits == 8) {
                try w.list.append(w.gpa, w.partial);
                w.partial = 0;
                w.partial_bits = 0;
            }
        }
    }

    pub fn writeSigned(w: *Writer, value: i64, n: u8) !void {
        const mask: u64 = if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        try w.writeBits(@as(u64, @bitCast(value)) & mask, n);
    }

    pub fn writeUnary(w: *Writer, zeros: u32) !void {
        var i: u32 = 0;
        while (i < zeros) : (i += 1) try w.writeBits(0, 1);
        try w.writeBits(1, 1);
    }

    pub fn writeRice(w: *Writer, value: i32, k: u8) !void {
        const zigzag: u32 = if (value < 0)
            (@as(u32, @intCast(-(value + 1))) << 1) | 1
        else
            @as(u32, @intCast(value)) << 1;
        const q = zigzag >> @intCast(k);
        try w.writeUnary(q);
        if (k > 0) try w.writeBits(zigzag & ((@as(u32, 1) << @intCast(k)) - 1), k);
    }

    /// Pad with zeros to the next byte boundary.
    pub fn alignToByte(w: *Writer) !void {
        while (w.partial_bits != 0) try w.writeBits(0, 1);
    }

    pub fn bitsPending(w: *const Writer) u4 {
        return w.partial_bits;
    }
};

const testing = std.testing;

test "readBits crossing byte boundaries" {
    // 1010 1100 0011 0101
    const data = [_]u8{ 0b1010_1100, 0b0011_0101 };
    var r = Reader.init(&data);
    try testing.expectEqual(@as(u64, 0b101), try r.readBits(3));
    try testing.expectEqual(@as(u64, 0b01100), try r.readBits(5));
    try testing.expectEqual(@as(u64, 0b0011_0101), try r.readBits(8));
    try testing.expectEqual(@as(usize, 0), r.bitsLeft());
    try testing.expectError(error.EndOfStream, r.readBits(1));
}

test "readBits of full width" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67 };
    var r = Reader.init(&data);
    try testing.expectEqual(@as(u64, 0xDEADBEEF01234567), try r.readBits(64));
}

test "readBit walks the stream" {
    const data = [_]u8{0b1001_0110};
    var r = Reader.init(&data);
    const want = [_]u1{ 1, 0, 0, 1, 0, 1, 1, 0 };
    for (want) |bit| try testing.expectEqual(bit, try r.readBit());
    try testing.expectError(error.EndOfStream, r.readBit());
}

test "signed fields sign-extend" {
    // 4-bit fields: 0111 = 7, 1111 = -1, 1000 = -8, 0000 = 0
    const data = [_]u8{ 0b0111_1111, 0b1000_0000 };
    var r = Reader.init(&data);
    try testing.expectEqual(@as(i64, 7), try r.readSigned(4));
    try testing.expectEqual(@as(i64, -1), try r.readSigned(4));
    try testing.expectEqual(@as(i64, -8), try r.readSigned(4));
    try testing.expectEqual(@as(i64, 0), try r.readSigned(4));
}

test "unary codes" {
    // Bit stream 1 | 01 | 0001, then one unused zero to fill the byte.
    const data = [_]u8{0b1010_0010};
    var r = Reader.init(&data);
    try testing.expectEqual(@as(u32, 0), try r.readUnary());
    try testing.expectEqual(@as(u32, 1), try r.readUnary());
    try testing.expectEqual(@as(u32, 3), try r.readUnary());
    try testing.expectEqual(@as(usize, 7), r.bit_pos);
}

test "unary run spanning several zero bytes" {
    const data = [_]u8{ 0, 0, 0b0000_0001 };
    var r = Reader.init(&data);
    try testing.expectEqual(@as(u32, 23), try r.readUnary());
}

test "unterminated unary run is rejected" {
    const data = [_]u8{ 0, 0, 0 };
    var r = Reader.init(&data);
    try testing.expectError(error.EndOfStream, r.readUnary());
}

test "byte alignment helpers" {
    const data = [_]u8{ 0xFF, 0x0F };
    var r = Reader.init(&data);
    _ = try r.readBits(3);
    try testing.expect(!r.isByteAligned());
    r.alignToByte();
    try testing.expect(r.isByteAligned());
    try testing.expectEqual(@as(usize, 1), r.bytePos());
    try testing.expectEqual(@as(u64, 0x0F), try r.readBits(8));
}

test "writer and reader round trip raw fields" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    var w = Writer.init(gpa, &list);
    try w.writeBits(0b1101, 4);
    try w.writeBits(0x1234, 16);
    try w.writeSigned(-300, 12);
    try w.writeBits(1, 1);
    try w.alignToByte();

    var r = Reader.init(list.items);
    try testing.expectEqual(@as(u64, 0b1101), try r.readBits(4));
    try testing.expectEqual(@as(u64, 0x1234), try r.readBits(16));
    try testing.expectEqual(@as(i64, -300), try r.readSigned(12));
    try testing.expectEqual(@as(u64, 1), try r.readBits(1));
}

test "rice codes round trip across parameters and signs" {
    const gpa = testing.allocator;
    const values = [_]i32{ 0, 1, -1, 2, -2, 7, -7, 100, -100, 5000, -5000, 1 << 20 };
    for ([_]u8{ 0, 1, 2, 5, 12 }) |k| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var w = Writer.init(gpa, &list);
        for (values) |v| try w.writeRice(v, k);
        try w.alignToByte();

        var r = Reader.init(list.items);
        for (values) |want| {
            try testing.expectEqual(want, try r.readRice(k));
        }
    }
}

test "unary round trip" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var w = Writer.init(gpa, &list);
    for ([_]u32{ 0, 1, 5, 17, 64 }) |z| try w.writeUnary(z);
    try w.alignToByte();

    var r = Reader.init(list.items);
    for ([_]u32{ 0, 1, 5, 17, 64 }) |want| {
        try testing.expectEqual(want, try r.readUnary());
    }
}

test "seeking repositions the cursor" {
    const data = [_]u8{ 0xAA, 0xBB, 0xCC };
    var r = Reader.init(&data);
    r.seekToByte(2);
    try testing.expectEqual(@as(u64, 0xCC), try r.readBits(8));
    r.seekToBit(4);
    try testing.expectEqual(@as(u64, 0xA), try r.readBits(4));
}

test "skipBits respects the end of the buffer" {
    const data = [_]u8{ 1, 2 };
    var r = Reader.init(&data);
    try r.skipBits(15);
    try testing.expectError(error.EndOfStream, r.skipBits(2));
}
