//! The queue, and the order it is played in.
//!
//! Playback order is kept as a separate permutation of track indices rather
//! than by shuffling the tracks themselves. That way the list the user sees
//! never jumps around when shuffle is toggled, and turning shuffle off
//! restores the original order exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;

const api = @import("../decode/api.zig");
const tags_mod = @import("../meta/tags.zig");

pub const RepeatMode = enum {
    off,
    all,
    one,

    pub fn label(r: RepeatMode) []const u8 {
        return switch (r) {
            .off => "off",
            .all => "all",
            .one => "one",
        };
    }

    pub fn cycle(r: RepeatMode) RepeatMode {
        return switch (r) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
    }
};

/// One entry in the queue. Every string is owned by the playlist's arena.
pub const Track = struct {
    path: []const u8,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    /// Null until the track has been opened at least once.
    duration_s: ?f64 = null,
    track_no: ?u32 = null,
    codec: ?api.Codec = null,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    /// ReplayGain for this track, in dB, if it carried one.
    gain_db: ?f32 = null,

    pub fn displayTitle(t: Track) []const u8 {
        return t.title orelse tags_mod.baseName(t.path);
    }

    pub fn displayArtist(t: Track) []const u8 {
        return t.artist orelse "";
    }
};

pub const SortField = enum { path, title, artist, album, duration, track_no };

pub const Playlist = struct {
    gpa: Allocator,
    /// Owns every string the tracks point at, so a track can be removed or
    /// reordered without any per-string bookkeeping.
    arena: std.heap.ArenaAllocator,
    tracks: std.ArrayList(Track) = .empty,

    /// Playback order: a permutation of indices into `tracks`.
    order: std.ArrayList(usize) = .empty,
    /// Where we are within `order`.
    order_pos: usize = 0,
    /// True once playback has a position at all.
    has_current: bool = false,

    shuffle: bool = false,
    repeat: RepeatMode = .off,
    prng: std.Random.DefaultPrng,

    pub fn init(gpa: Allocator, seed: u64) Playlist {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Playlist) void {
        self.tracks.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Playlist) usize {
        return self.tracks.items.len;
    }

    pub fn isEmpty(self: *const Playlist) bool {
        return self.tracks.items.len == 0;
    }

    /// Duplicate `text` into the playlist's arena.
    pub fn intern(self: *Playlist, text: []const u8) Allocator.Error![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }

    /// Append a track by path. Strings are copied.
    pub fn append(self: *Playlist, path: []const u8) Allocator.Error!usize {
        const owned = try self.intern(path);
        const index = self.tracks.items.len;
        try self.tracks.append(self.gpa, .{ .path = owned });
        try self.order.append(self.gpa, index);
        if (self.shuffle) self.placeNewlyAddedRandomly(self.order.items.len - 1);
        return index;
    }

    /// Append a fully populated track, copying every string it holds.
    pub fn appendTrack(self: *Playlist, t: Track) Allocator.Error!usize {
        const index = try self.append(t.path);
        var copy = &self.tracks.items[index];
        if (t.title) |v| copy.title = try self.intern(v);
        if (t.artist) |v| copy.artist = try self.intern(v);
        if (t.album) |v| copy.album = try self.intern(v);
        copy.duration_s = t.duration_s;
        copy.track_no = t.track_no;
        copy.codec = t.codec;
        copy.sample_rate = t.sample_rate;
        copy.channels = t.channels;
        copy.gain_db = t.gain_db;
        return index;
    }

    /// Fill in what we learned from actually opening a track.
    pub fn updateMetadata(
        self: *Playlist,
        index: usize,
        info: api.Info,
        tags: *const tags_mod.Tags,
    ) Allocator.Error!void {
        if (index >= self.tracks.items.len) return;
        const t = &self.tracks.items[index];
        t.duration_s = info.durationSeconds();
        t.codec = info.codec;
        t.sample_rate = info.sample_rate;
        t.channels = info.channels;
        if (tags.title) |v| t.title = try self.intern(v);
        if (tags.artist) |v| t.artist = try self.intern(v);
        if (tags.album) |v| t.album = try self.intern(v);
        if (tags.track) |v| t.track_no = v;
        if (tags.replayGainDb(false)) |v| t.gain_db = v;
    }

    /// Drop everything, including the interned strings.
    pub fn clear(self: *Playlist) void {
        self.tracks.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.order_pos = 0;
        self.has_current = false;
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn currentIndex(self: *const Playlist) ?usize {
        if (!self.has_current or self.order.items.len == 0) return null;
        if (self.order_pos >= self.order.items.len) return null;
        return self.order.items[self.order_pos];
    }

    pub fn current(self: *const Playlist) ?*const Track {
        const i = self.currentIndex() orelse return null;
        return &self.tracks.items[i];
    }

    pub fn at(self: *const Playlist, index: usize) ?*const Track {
        if (index >= self.tracks.items.len) return null;
        return &self.tracks.items[index];
    }

    /// Start playback at a specific track index, regardless of order.
    pub fn jumpTo(self: *Playlist, index: usize) ?usize {
        if (index >= self.tracks.items.len) return null;
        for (self.order.items, 0..) |t, pos| {
            if (t == index) {
                self.order_pos = pos;
                self.has_current = true;
                return index;
            }
        }
        return null;
    }

    /// Begin at the start of the current order.
    pub fn start(self: *Playlist) ?usize {
        if (self.order.items.len == 0) return null;
        self.order_pos = 0;
        self.has_current = true;
        return self.order.items[0];
    }

    /// Advance according to shuffle and repeat. Returns the new track index,
    /// or null when the queue is finished.
    pub fn next(self: *Playlist) ?usize {
        if (self.order.items.len == 0) return null;
        if (!self.has_current) return self.start();

        if (self.repeat == .one) return self.currentIndex();

        if (self.order_pos + 1 < self.order.items.len) {
            self.order_pos += 1;
            return self.currentIndex();
        }

        if (self.repeat == .all) {
            // A fresh shuffle each time through keeps repeat-all from
            // replaying the same random order forever.
            if (self.shuffle) self.reshuffle(null);
            self.order_pos = 0;
            return self.currentIndex();
        }

        return null;
    }

    /// Advance but ignore repeat-one, so an explicit "skip" always moves.
    pub fn skipForward(self: *Playlist) ?usize {
        const saved = self.repeat;
        if (self.repeat == .one) self.repeat = .all;
        defer self.repeat = saved;
        return self.next();
    }

    pub fn previous(self: *Playlist) ?usize {
        if (self.order.items.len == 0) return null;
        if (!self.has_current) return self.start();
        if (self.order_pos > 0) {
            self.order_pos -= 1;
            return self.currentIndex();
        }
        if (self.repeat == .all) {
            self.order_pos = self.order.items.len - 1;
            return self.currentIndex();
        }
        return self.currentIndex();
    }

    /// Whether `next` would return something without wrapping.
    pub fn hasNext(self: *const Playlist) bool {
        if (self.order.items.len == 0) return false;
        if (self.repeat != .off) return true;
        if (!self.has_current) return true;
        return self.order_pos + 1 < self.order.items.len;
    }

    /// What `next` would return, without moving. Used to pre-open the
    /// following track for gapless playback.
    pub fn peekNext(self: *const Playlist) ?usize {
        if (self.order.items.len == 0) return null;
        if (!self.has_current) return self.order.items[0];
        if (self.repeat == .one) return self.currentIndex();
        if (self.order_pos + 1 < self.order.items.len) {
            return self.order.items[self.order_pos + 1];
        }
        if (self.repeat == .all) {
            // After a wrap the order may be reshuffled, so this is a guess;
            // it is only used as a prefetch hint.
            return self.order.items[0];
        }
        return null;
    }

    pub fn setShuffle(self: *Playlist, on: bool) void {
        if (self.shuffle == on) return;
        self.shuffle = on;
        const keep = self.currentIndex();
        if (on) {
            self.reshuffle(keep);
        } else {
            self.resetOrder();
            if (keep) |k| _ = self.jumpTo(k);
        }
    }

    pub fn toggleShuffle(self: *Playlist) void {
        self.setShuffle(!self.shuffle);
    }

    /// Rebuild `order` as a random permutation. If `keep_first` is given, that
    /// track is moved to the front so the track playing right now continues.
    fn reshuffle(self: *Playlist, keep_first: ?usize) void {
        self.resetOrder();
        const items = self.order.items;
        if (items.len > 1) {
            self.prng.random().shuffle(usize, items);
        }
        if (keep_first) |k| {
            for (items, 0..) |t, i| {
                if (t == k) {
                    std.mem.swap(usize, &items[0], &items[i]);
                    break;
                }
            }
            self.order_pos = 0;
            self.has_current = true;
        }
    }

    fn resetOrder(self: *Playlist) void {
        self.order.clearRetainingCapacity();
        self.order.ensureTotalCapacity(self.gpa, self.tracks.items.len) catch return;
        for (0..self.tracks.items.len) |i| self.order.appendAssumeCapacity(i);
        self.order_pos = @min(self.order_pos, self.order.items.len -| 1);
    }

    /// When shuffling, a track appended mid-playback should land somewhere
    /// after the current position rather than always at the end.
    fn placeNewlyAddedRandomly(self: *Playlist, added_at: usize) void {
        const items = self.order.items;
        if (items.len < 2) return;
        const lower = if (self.has_current) self.order_pos + 1 else 0;
        if (lower >= items.len) return;
        const pos = self.prng.random().intRangeLessThan(usize, lower, items.len);
        std.mem.swap(usize, &items[added_at], &items[pos]);
    }

    pub fn setRepeat(self: *Playlist, mode: RepeatMode) void {
        self.repeat = mode;
    }

    pub fn cycleRepeat(self: *Playlist) void {
        self.repeat = self.repeat.cycle();
    }

    /// Remove a track, keeping playback pointed at the same song if possible.
    pub fn remove(self: *Playlist, index: usize) void {
        if (index >= self.tracks.items.len) return;
        const playing = self.currentIndex();

        _ = self.tracks.orderedRemove(index);

        // Drop it from the order and renumber everything above it.
        var w: usize = 0;
        for (self.order.items) |t| {
            if (t == index) continue;
            self.order.items[w] = if (t > index) t - 1 else t;
            w += 1;
        }
        self.order.shrinkRetainingCapacity(w);

        if (self.order.items.len == 0) {
            self.order_pos = 0;
            self.has_current = false;
            return;
        }
        if (playing) |p| {
            if (p == index) {
                // The playing track is gone; stay at the same slot, which is
                // now the following track.
                self.order_pos = @min(self.order_pos, self.order.items.len - 1);
            } else {
                _ = self.jumpTo(if (p > index) p - 1 else p);
            }
        } else {
            self.order_pos = @min(self.order_pos, self.order.items.len - 1);
        }
    }

    /// Move a track to a new position in the visible list.
    pub fn move(self: *Playlist, from: usize, to: usize) void {
        const n = self.tracks.items.len;
        if (from >= n or to >= n or from == to) return;
        const playing = self.currentIndex();

        const t = self.tracks.orderedRemove(from);
        self.tracks.insert(self.gpa, to, t) catch {
            // Put it back where it was rather than losing it.
            self.tracks.insert(self.gpa, from, t) catch {};
            return;
        };

        // Rewrite the order to follow the new indices.
        for (self.order.items) |*o| o.* = remapAfterMove(o.*, from, to);
        if (playing) |p| _ = self.jumpTo(remapAfterMove(p, from, to));
    }

    pub fn sortBy(self: *Playlist, field: SortField, ascending: bool) void {
        const playing = self.currentIndex();
        const Ctx = struct {
            field: SortField,
            ascending: bool,

            fn lessThan(ctx: @This(), a: Track, b: Track) bool {
                const order = compare(ctx.field, a, b);
                return if (ctx.ascending) order else !order;
            }

            fn compare(by: SortField, a: Track, b: Track) bool {
                return switch (by) {
                    .path => std.ascii.lessThanIgnoreCase(a.path, b.path),
                    .title => std.ascii.lessThanIgnoreCase(a.displayTitle(), b.displayTitle()),
                    .artist => std.ascii.lessThanIgnoreCase(a.displayArtist(), b.displayArtist()),
                    .album => std.ascii.lessThanIgnoreCase(a.album orelse "", b.album orelse ""),
                    .duration => (a.duration_s orelse 0) < (b.duration_s orelse 0),
                    .track_no => (a.track_no orelse 0) < (b.track_no orelse 0),
                };
            }
        };

        // Find the playing track by identity so the cursor survives the sort.
        const playing_path: ?[]const u8 = if (playing) |p| self.tracks.items[p].path else null;

        std.mem.sort(Track, self.tracks.items, Ctx{
            .field = field,
            .ascending = ascending,
        }, Ctx.lessThan);

        if (self.shuffle) {
            self.reshuffle(null);
        } else {
            self.resetOrder();
        }
        if (playing_path) |path| {
            for (self.tracks.items, 0..) |t, i| {
                if (t.path.ptr == path.ptr) {
                    _ = self.jumpTo(i);
                    break;
                }
            }
        }
    }

    /// Sum of the durations we know about.
    pub fn totalDurationSeconds(self: *const Playlist) f64 {
        var total: f64 = 0;
        for (self.tracks.items) |t| total += t.duration_s orelse 0;
        return total;
    }
};

fn remapAfterMove(index: usize, from: usize, to: usize) usize {
    if (index == from) return to;
    if (from < to) {
        return if (index > from and index <= to) index - 1 else index;
    }
    return if (index >= to and index < from) index + 1 else index;
}

const testing = std.testing;

fn makeList(gpa: Allocator, n: usize) !Playlist {
    var pl = Playlist.init(gpa, 0x1234);
    var buf: [32]u8 = undefined;
    for (0..n) |i| {
        const path = try std.fmt.bufPrint(&buf, "track{d:0>2}.flac", .{i});
        _ = try pl.append(path);
    }
    return pl;
}

test "appending and reading back" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();

    try testing.expectEqual(@as(usize, 3), pl.count());
    try testing.expect(!pl.isEmpty());
    try testing.expectEqualStrings("track00.flac", pl.at(0).?.path);
    try testing.expectEqualStrings("track00", pl.at(0).?.displayTitle());
    try testing.expect(pl.at(99) == null);
    try testing.expect(pl.currentIndex() == null);
}

test "sequential playback to the end" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();

    try testing.expectEqual(@as(usize, 0), pl.start().?);
    try testing.expectEqual(@as(usize, 1), pl.next().?);
    try testing.expectEqual(@as(usize, 2), pl.next().?);
    try testing.expect(pl.next() == null); // repeat is off
}

test "repeat all wraps around" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();
    pl.setRepeat(.all);

    _ = pl.start();
    _ = pl.next();
    _ = pl.next();
    try testing.expectEqual(@as(usize, 0), pl.next().?);
    try testing.expect(pl.hasNext());
}

test "repeat one stays put but an explicit skip still moves" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();
    pl.setRepeat(.one);

    _ = pl.start();
    try testing.expectEqual(@as(usize, 0), pl.next().?);
    try testing.expectEqual(@as(usize, 0), pl.next().?);
    // The user pressing "next" should not be trapped by repeat-one.
    try testing.expectEqual(@as(usize, 1), pl.skipForward().?);
}

test "repeat cycles through its three modes" {
    var r: RepeatMode = .off;
    r = r.cycle();
    try testing.expectEqual(RepeatMode.all, r);
    r = r.cycle();
    try testing.expectEqual(RepeatMode.one, r);
    r = r.cycle();
    try testing.expectEqual(RepeatMode.off, r);
}

test "previous walks backwards and stops at the start" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();

    _ = pl.start();
    _ = pl.next();
    _ = pl.next();
    try testing.expectEqual(@as(usize, 1), pl.previous().?);
    try testing.expectEqual(@as(usize, 0), pl.previous().?);
    // Already at the start with repeat off: stay rather than wrap.
    try testing.expectEqual(@as(usize, 0), pl.previous().?);

    pl.setRepeat(.all);
    try testing.expectEqual(@as(usize, 2), pl.previous().?);
}

test "shuffle visits every track exactly once" {
    const gpa = testing.allocator;
    const n = 50;
    var pl = try makeList(gpa, n);
    defer pl.deinit();

    pl.setShuffle(true);
    try testing.expect(pl.shuffle);

    var seen: [n]bool = @splat(false);
    var i = pl.start().?;
    seen[i] = true;
    var visited: usize = 1;
    while (pl.next()) |t| {
        try testing.expect(!seen[t]); // no repeats within one pass
        seen[t] = true;
        visited += 1;
        i = t;
    }
    try testing.expectEqual(n, visited);
    for (seen) |s| try testing.expect(s);
}

test "shuffle actually reorders" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 40);
    defer pl.deinit();
    pl.setShuffle(true);

    var in_place: usize = 0;
    for (pl.order.items, 0..) |t, i| {
        if (t == i) in_place += 1;
    }
    // A random permutation of 40 leaves about one element fixed on average.
    try testing.expect(in_place < 10);
}

test "toggling shuffle keeps playing the same track" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 20);
    defer pl.deinit();

    _ = pl.start();
    _ = pl.next();
    _ = pl.next();
    const playing = pl.currentIndex().?;

    pl.setShuffle(true);
    try testing.expectEqual(playing, pl.currentIndex().?);

    pl.setShuffle(false);
    try testing.expectEqual(playing, pl.currentIndex().?);
    // With shuffle off the order is the identity again.
    for (pl.order.items, 0..) |t, i| try testing.expectEqual(i, t);
}

test "jumpTo selects a track in either order" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 10);
    defer pl.deinit();

    try testing.expectEqual(@as(usize, 7), pl.jumpTo(7).?);
    try testing.expectEqual(@as(usize, 7), pl.currentIndex().?);
    pl.setShuffle(true);
    try testing.expectEqual(@as(usize, 3), pl.jumpTo(3).?);
    try testing.expectEqual(@as(usize, 3), pl.currentIndex().?);
    try testing.expect(pl.jumpTo(99) == null);
}

test "removing the playing track moves to the next one" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 5);
    defer pl.deinit();

    _ = pl.jumpTo(2);
    pl.remove(2);
    try testing.expectEqual(@as(usize, 4), pl.count());
    // Slot 2 now holds what used to be track 3.
    try testing.expectEqualStrings("track03.flac", pl.current().?.path);
}

test "removing another track keeps playback on the same song" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 5);
    defer pl.deinit();

    _ = pl.jumpTo(3);
    const path_before = pl.current().?.path;
    pl.remove(0);
    try testing.expectEqualStrings(path_before, pl.current().?.path);
    try testing.expectEqual(@as(usize, 2), pl.currentIndex().?);
}

test "removing the last track empties the queue" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 1);
    defer pl.deinit();
    _ = pl.start();
    pl.remove(0);
    try testing.expect(pl.isEmpty());
    try testing.expect(pl.currentIndex() == null);
    try testing.expect(pl.next() == null);
}

test "moving a track rewrites the order consistently" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 5);
    defer pl.deinit();

    _ = pl.jumpTo(1);
    const playing = pl.current().?.path;

    pl.move(0, 4); // first track to the end
    try testing.expectEqualStrings("track01.flac", pl.at(0).?.path);
    try testing.expectEqualStrings("track00.flac", pl.at(4).?.path);
    try testing.expectEqualStrings(playing, pl.current().?.path);

    pl.move(4, 0); // and back
    try testing.expectEqualStrings("track00.flac", pl.at(0).?.path);
    try testing.expectEqualStrings(playing, pl.current().?.path);
}

test "move index remapping" {
    // Moving 0 -> 3 shifts 1,2,3 down by one.
    try testing.expectEqual(@as(usize, 3), remapAfterMove(0, 0, 3));
    try testing.expectEqual(@as(usize, 0), remapAfterMove(1, 0, 3));
    try testing.expectEqual(@as(usize, 2), remapAfterMove(3, 0, 3));
    try testing.expectEqual(@as(usize, 4), remapAfterMove(4, 0, 3));
    // Moving 3 -> 0 shifts 0,1,2 up by one.
    try testing.expectEqual(@as(usize, 0), remapAfterMove(3, 3, 0));
    try testing.expectEqual(@as(usize, 1), remapAfterMove(0, 3, 0));
    try testing.expectEqual(@as(usize, 3), remapAfterMove(2, 3, 0));
}

test "sorting by title keeps the playing track selected" {
    const gpa = testing.allocator;
    var pl = Playlist.init(gpa, 7);
    defer pl.deinit();

    _ = try pl.appendTrack(.{ .path = "c.flac", .title = "Cherry", .duration_s = 30 });
    _ = try pl.appendTrack(.{ .path = "a.flac", .title = "Apple", .duration_s = 10 });
    _ = try pl.appendTrack(.{ .path = "b.flac", .title = "Banana", .duration_s = 20 });

    _ = pl.jumpTo(0); // playing "Cherry"
    pl.sortBy(.title, true);

    try testing.expectEqualStrings("Apple", pl.at(0).?.title.?);
    try testing.expectEqualStrings("Banana", pl.at(1).?.title.?);
    try testing.expectEqualStrings("Cherry", pl.at(2).?.title.?);
    try testing.expectEqualStrings("Cherry", pl.current().?.title.?);

    pl.sortBy(.duration, true);
    try testing.expectEqual(@as(f64, 10), pl.at(0).?.duration_s.?);
    try testing.expectEqual(@as(f64, 30), pl.at(2).?.duration_s.?);
}

test "total duration adds up and ignores unknowns" {
    const gpa = testing.allocator;
    var pl = Playlist.init(gpa, 0);
    defer pl.deinit();
    _ = try pl.appendTrack(.{ .path = "a", .duration_s = 100 });
    _ = try pl.appendTrack(.{ .path = "b", .duration_s = 50.5 });
    _ = try pl.appendTrack(.{ .path = "c" }); // unknown length
    try testing.expectApproxEqAbs(@as(f64, 150.5), pl.totalDurationSeconds(), 1e-9);
}

test "metadata from a decode is folded in" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 1);
    defer pl.deinit();

    var tags = tags_mod.Tags.init(gpa);
    defer tags.deinit();
    tags.title = try gpa.dupe(u8, "Real Title");
    tags.artist = try gpa.dupe(u8, "Real Artist");
    tags.track = 4;

    try pl.updateMetadata(0, .{
        .codec = .flac,
        .sample_rate = 44_100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_frames = 441_000,
        .seekable = true,
    }, &tags);

    const t = pl.at(0).?;
    try testing.expectEqualStrings("Real Title", t.title.?);
    try testing.expectEqualStrings("Real Artist", t.artist.?);
    try testing.expectEqual(@as(?u32, 4), t.track_no);
    try testing.expectApproxEqAbs(@as(f64, 10.0), t.duration_s.?, 1e-9);
    try testing.expectEqual(api.Codec.flac, t.codec.?);
}

test "clear releases everything" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 10);
    defer pl.deinit();
    _ = pl.start();
    pl.clear();
    try testing.expect(pl.isEmpty());
    try testing.expect(pl.currentIndex() == null);
    // And it is reusable afterwards.
    _ = try pl.append("new.flac");
    try testing.expectEqual(@as(usize, 1), pl.count());
}

test "peekNext predicts the next track" {
    const gpa = testing.allocator;
    var pl = try makeList(gpa, 3);
    defer pl.deinit();

    try testing.expectEqual(@as(usize, 0), pl.peekNext().?);
    _ = pl.start();
    try testing.expectEqual(@as(usize, 1), pl.peekNext().?);
    _ = pl.next();
    _ = pl.next();
    try testing.expect(pl.peekNext() == null);
    pl.setRepeat(.all);
    try testing.expect(pl.peekNext() != null);
}

test "an empty playlist answers every query safely" {
    const gpa = testing.allocator;
    var pl = Playlist.init(gpa, 0);
    defer pl.deinit();

    try testing.expect(pl.start() == null);
    try testing.expect(pl.next() == null);
    try testing.expect(pl.previous() == null);
    try testing.expect(pl.current() == null);
    try testing.expect(!pl.hasNext());
    pl.setShuffle(true);
    pl.remove(0);
    pl.move(0, 1);
    pl.sortBy(.title, true);
    try testing.expectEqual(@as(f64, 0), pl.totalDurationSeconds());
}
