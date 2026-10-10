//! A wait-free single-producer / single-consumer ring buffer of `f32` samples.
//!
//! The decoder thread is the only producer; the audio callback is the only
//! consumer. Neither ever blocks or allocates, which is what keeps the output
//! callback real-time safe.
//!
//! Capacity is rounded up to a power of two so the index wrap is a mask. The
//! two cursors are monotonically increasing sample counts (they are only
//! reduced modulo capacity when indexing), which makes "full" and "empty"
//! unambiguous without wasting a slot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

pub const Ring = struct {
    buf: []f32,
    mask: usize,
    /// Total samples ever written. Only the producer stores; both load.
    write_pos: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    /// Total samples ever read. Only the consumer stores; both load.
    read_pos: Atomic(usize) align(std.atomic.cache_line) = .init(0),

    pub fn init(gpa: Allocator, min_capacity: usize) Allocator.Error!Ring {
        const cap = std.math.ceilPowerOfTwoAssert(usize, @max(min_capacity, 2));
        const buf = try gpa.alloc(f32, cap);
        @memset(buf, 0);
        return .{ .buf = buf, .mask = cap - 1 };
    }

    pub fn deinit(r: *Ring, gpa: Allocator) void {
        gpa.free(r.buf);
        r.* = undefined;
    }

    pub fn capacity(r: *const Ring) usize {
        return r.buf.len;
    }

    /// Samples available to read right now. Safe from either thread.
    pub fn readable(r: *const Ring) usize {
        const w = r.write_pos.load(.acquire);
        const rd = r.read_pos.load(.acquire);
        return w - rd;
    }

    /// Free space for writing right now. Safe from either thread.
    pub fn writable(r: *const Ring) usize {
        return r.buf.len - r.readable();
    }

    pub fn isEmpty(r: *const Ring) bool {
        return r.readable() == 0;
    }

    /// Producer side. Copies as much of `src` as fits and returns the count.
    pub fn write(r: *Ring, src: []const f32) usize {
        const w = r.write_pos.load(.monotonic);
        const rd = r.read_pos.load(.acquire);
        const free = r.buf.len - (w - rd);
        const n = @min(free, src.len);
        if (n == 0) return 0;

        const start = w & r.mask;
        const first = @min(n, r.buf.len - start);
        @memcpy(r.buf[start .. start + first], src[0..first]);
        if (n > first) @memcpy(r.buf[0 .. n - first], src[first..n]);

        // Publish the data before the cursor so the consumer never reads
        // samples we have not finished writing.
        r.write_pos.store(w + n, .release);
        return n;
    }

    /// Producer side. Writes `n` zeroed samples; returns how many fit.
    pub fn writeSilence(r: *Ring, n_requested: usize) usize {
        const w = r.write_pos.load(.monotonic);
        const rd = r.read_pos.load(.acquire);
        const free = r.buf.len - (w - rd);
        const n = @min(free, n_requested);
        if (n == 0) return 0;

        const start = w & r.mask;
        const first = @min(n, r.buf.len - start);
        @memset(r.buf[start .. start + first], 0);
        if (n > first) @memset(r.buf[0 .. n - first], 0);

        r.write_pos.store(w + n, .release);
        return n;
    }

    /// Consumer side. Fills as much of `dst` as is available and returns the
    /// count. The untouched tail of `dst` is left alone — see `readOrSilence`.
    pub fn read(r: *Ring, dst: []f32) usize {
        const rd = r.read_pos.load(.monotonic);
        const w = r.write_pos.load(.acquire);
        const avail = w - rd;
        const n = @min(avail, dst.len);
        if (n == 0) return 0;

        const start = rd & r.mask;
        const first = @min(n, r.buf.len - start);
        @memcpy(dst[0..first], r.buf[start .. start + first]);
        if (n > first) @memcpy(dst[first..n], r.buf[0 .. n - first]);

        r.read_pos.store(rd + n, .release);
        return n;
    }

    /// Consumer side, for the audio callback: always fills `dst` completely,
    /// padding with silence on underrun. Returns the number of real samples.
    pub fn readOrSilence(r: *Ring, dst: []f32) usize {
        const n = r.read(dst);
        if (n < dst.len) @memset(dst[n..], 0);
        return n;
    }

    /// Discard up to `n` samples without copying them. Consumer side.
    pub fn discard(r: *Ring, n_requested: usize) usize {
        const rd = r.read_pos.load(.monotonic);
        const w = r.write_pos.load(.acquire);
        const n = @min(w - rd, n_requested);
        r.read_pos.store(rd + n, .release);
        return n;
    }

    /// Drop everything buffered. Only safe when the producer is parked, which
    /// is exactly the case during a seek or a track change.
    pub fn clear(r: *Ring) void {
        r.read_pos.store(r.write_pos.load(.acquire), .release);
    }
};

test "write and read round trip" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 8);
    defer ring.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 8), ring.capacity());
    try std.testing.expect(ring.isEmpty());

    const src = [_]f32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(usize, 5), ring.write(&src));
    try std.testing.expectEqual(@as(usize, 5), ring.readable());
    try std.testing.expectEqual(@as(usize, 3), ring.writable());

    var dst: [5]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 5), ring.read(&dst));
    try std.testing.expectEqualSlices(f32, &src, &dst);
    try std.testing.expect(ring.isEmpty());
}

test "write refuses to overflow" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 4);
    defer ring.deinit(gpa);

    const src = [_]f32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(@as(usize, 4), ring.write(&src));
    try std.testing.expectEqual(@as(usize, 0), ring.write(&src));
}

test "wrapping preserves order" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 4);
    defer ring.deinit(gpa);

    // Walk the cursors past the end of the backing array several times.
    var expect: f32 = 0;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        const src = [_]f32{ expect, expect + 1, expect + 2 };
        try std.testing.expectEqual(@as(usize, 3), ring.write(&src));
        var dst: [3]f32 = undefined;
        try std.testing.expectEqual(@as(usize, 3), ring.read(&dst));
        try std.testing.expectEqualSlices(f32, &src, &dst);
        expect += 3;
    }
}

test "readOrSilence pads an underrun" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 8);
    defer ring.deinit(gpa);

    _ = ring.write(&[_]f32{ 9, 9 });
    var dst: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), ring.readOrSilence(&dst));
    try std.testing.expectEqualSlices(f32, &.{ 9, 9, 0, 0 }, &dst);
}

test "clear and discard" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 16);
    defer ring.deinit(gpa);

    _ = ring.write(&[_]f32{ 1, 2, 3, 4, 5, 6 });
    try std.testing.expectEqual(@as(usize, 2), ring.discard(2));
    try std.testing.expectEqual(@as(usize, 4), ring.readable());
    ring.clear();
    try std.testing.expect(ring.isEmpty());
}

test "concurrent producer and consumer see every sample in order" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa, 64);
    defer ring.deinit(gpa);

    const total: usize = 50_000;

    const Producer = struct {
        fn run(r: *Ring, n: usize) void {
            var i: usize = 0;
            var chunk: [7]f32 = undefined;
            while (i < n) {
                const len = @min(chunk.len, n - i);
                for (chunk[0..len], 0..) |*c, k| c.* = @floatFromInt(i + k);
                const wrote = r.write(chunk[0..len]);
                i += wrote;
                if (wrote == 0) std.Thread.yield() catch {};
            }
        }
    };

    var thread = try std.Thread.spawn(.{}, Producer.run, .{ &ring, total });
    defer thread.join();

    var got: usize = 0;
    var dst: [11]f32 = undefined;
    while (got < total) {
        const n = ring.read(&dst);
        if (n == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        for (dst[0..n], 0..) |v, k| {
            try std.testing.expectEqual(@as(f32, @floatFromInt(got + k)), v);
        }
        got += n;
    }
    try std.testing.expectEqual(total, got);
}
