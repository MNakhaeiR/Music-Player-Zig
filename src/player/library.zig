//! Turning command-line arguments into a queue: directory scanning, M3U
//! playlists, and the metadata pre-pass.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const decoder_mod = @import("../decode/decoder.zig");
const tags_mod = @import("../meta/tags.zig");
const Playlist = @import("playlist.zig").Playlist;

pub const Error = error{
    NotFound,
    AccessDenied,
    ReadFailed,
    OutOfMemory,
};

pub const ScanResult = struct {
    /// Tracks appended to the playlist.
    added: usize = 0,
    /// Entries skipped because nothing could play them.
    skipped: usize = 0,
    /// Directories visited.
    directories: usize = 0,

    pub fn merge(self: *ScanResult, other: ScanResult) void {
        self.added += other.added;
        self.skipped += other.skipped;
        self.directories += other.directories;
    }
};

pub const ScanOptions = struct {
    /// Walk directories recursively.
    recursive: bool = true,
    /// Sort each directory's files by name, so albums land in track order.
    sort: bool = true,
    /// Stop after this many files, as a guard against pointing the player at
    /// a whole drive.
    max_files: usize = 100_000,
};

/// True for the playlist container formats we can read.
pub fn isPlaylistFile(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "m3u") or std.ascii.eqlIgnoreCase(ext, "m3u8");
}

/// Add whatever `path` refers to — a single file, a directory tree, or an M3U
/// playlist — to `list`.
pub fn add(
    gpa: Allocator,
    io: Io,
    list: *Playlist,
    path: []const u8,
    options: ScanOptions,
) Error!ScanResult {
    const cwd: Dir = .cwd();
    const st = cwd.statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.ReadFailed,
    };

    if (st.kind == .directory) {
        return scanDirectory(gpa, io, list, path, options);
    }
    if (isPlaylistFile(path)) {
        return loadM3u(gpa, io, list, path);
    }
    if (!decoder_mod.extensionLooksPlayable(path)) {
        // Named explicitly, so try it anyway — the extension may just be
        // wrong, and probing looks at the content.
        _ = list.append(path) catch return error.OutOfMemory;
        return .{ .added = 1 };
    }
    _ = list.append(path) catch return error.OutOfMemory;
    return .{ .added = 1 };
}

fn scanDirectory(
    gpa: Allocator,
    io: Io,
    list: *Playlist,
    root: []const u8,
    options: ScanOptions,
) Error!ScanResult {
    var dir = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            else => error.ReadFailed,
        };
    };
    defer dir.close(io);

    var result: ScanResult = .{ .directories = 1 };

    // Collect paths first so they can be sorted before being appended.
    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |p| gpa.free(p);
        found.deinit(gpa);
    }

    if (options.recursive) {
        var walker = dir.walk(gpa) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) {
                if (entry.kind == .directory) result.directories += 1;
                continue;
            }
            if (!decoder_mod.extensionLooksPlayable(entry.path)) {
                result.skipped += 1;
                continue;
            }
            if (found.items.len >= options.max_files) break;
            const joined = std.fs.path.join(gpa, &.{ root, entry.path }) catch
                return error.OutOfMemory;
            found.append(gpa, joined) catch {
                gpa.free(joined);
                return error.OutOfMemory;
            };
        }
    } else {
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!decoder_mod.extensionLooksPlayable(entry.name)) {
                result.skipped += 1;
                continue;
            }
            if (found.items.len >= options.max_files) break;
            const joined = std.fs.path.join(gpa, &.{ root, entry.name }) catch
                return error.OutOfMemory;
            found.append(gpa, joined) catch {
                gpa.free(joined);
                return error.OutOfMemory;
            };
        }
    }

    if (options.sort) {
        std.mem.sort([]const u8, found.items, {}, lessThanNatural);
    }

    for (found.items) |p| {
        _ = list.append(p) catch return error.OutOfMemory;
        result.added += 1;
    }
    return result;
}

/// Compare paths so that "track2" sorts before "track10" — digit runs are
/// compared as numbers rather than character by character.
pub fn lessThanNatural(_: void, a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            // Skip leading zeros so "007" and "7" compare equal in value.
            var si = i;
            while (si < a.len and a[si] == '0') si += 1;
            var sj = j;
            while (sj < b.len and b[sj] == '0') sj += 1;

            var ei = si;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = sj;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;

            const la = ei - si;
            const lb = ej - sj;
            if (la != lb) return la < lb;
            const cmp = std.mem.order(u8, a[si..ei], b[sj..ej]);
            if (cmp != .eq) return cmp == .lt;
            i = ei;
            j = ej;
            continue;
        }
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
        i += 1;
        j += 1;
    }
    return (a.len - i) < (b.len - j);
}

/// Read an M3U or M3U8 playlist. Relative entries resolve against the
/// playlist's own directory, which is what every other player does.
pub fn loadM3u(
    gpa: Allocator,
    io: Io,
    list: *Playlist,
    path: []const u8,
) Error!ScanResult {
    const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    };
    defer gpa.free(bytes);

    const base = std.fs.path.dirname(path) orelse ".";
    var result: ScanResult = .{};

    // Extended M3U carries "#EXTINF:<seconds>,<artist> - <title>" before each
    // entry; use it so the queue shows real names before anything is decoded.
    var pending_duration: ?f64 = null;
    var pending_title: ?[]const u8 = null;
    var pending_artist: ?[]const u8 = null;

    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;

        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                const rest = line["#EXTINF:".len..];
                const comma = std.mem.indexOfScalar(u8, rest, ',');
                const secs_text = if (comma) |c| rest[0..c] else rest;
                pending_duration = std.fmt.parseFloat(f64, std.mem.trim(u8, secs_text, " ")) catch null;
                if (pending_duration) |d| {
                    // A negative length means "unknown" in the wild.
                    if (d < 0) pending_duration = null;
                }
                if (comma) |c| {
                    const label = std.mem.trim(u8, rest[c + 1 ..], " ");
                    if (std.mem.indexOf(u8, label, " - ")) |dash| {
                        pending_artist = label[0..dash];
                        pending_title = label[dash + 3 ..];
                    } else if (label.len > 0) {
                        pending_title = label;
                    }
                }
            }
            continue;
        }

        // Resolve the entry against the playlist's directory unless it is
        // already absolute.
        const resolved = if (std.fs.path.isAbsolute(line))
            gpa.dupe(u8, line) catch return error.OutOfMemory
        else
            std.fs.path.join(gpa, &.{ base, line }) catch return error.OutOfMemory;
        defer gpa.free(resolved);

        _ = list.appendTrack(.{
            .path = resolved,
            .title = pending_title,
            .artist = pending_artist,
            .duration_s = pending_duration,
        }) catch return error.OutOfMemory;
        result.added += 1;

        pending_duration = null;
        pending_title = null;
        pending_artist = null;
    }

    return result;
}

/// Write the queue as an extended M3U8.
pub fn saveM3u(io: Io, list: *const Playlist, path: []const u8) Error!void {
    const file = Dir.cwd().createFile(io, path, .{ .truncate = true }) catch |err| {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            else => error.ReadFailed,
        };
    };
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    const w = &writer.interface;

    w.writeAll("#EXTM3U\n") catch return error.ReadFailed;
    for (list.tracks.items) |t| {
        const seconds: i64 = if (t.duration_s) |d| @intFromFloat(@round(d)) else -1;
        const artist = t.displayArtist();
        if (artist.len > 0) {
            w.print("#EXTINF:{d},{s} - {s}\n", .{ seconds, artist, t.displayTitle() }) catch
                return error.ReadFailed;
        } else {
            w.print("#EXTINF:{d},{s}\n", .{ seconds, t.displayTitle() }) catch
                return error.ReadFailed;
        }
        w.print("{s}\n", .{t.path}) catch return error.ReadFailed;
    }
    w.flush() catch return error.ReadFailed;
}

/// Open every track just long enough to read its length and tags.
///
/// This is what lets the queue show real durations and titles immediately. It
/// is deliberately a separate pass: scanning a large directory stays fast, and
/// the caller decides whether the wait is worth it.
pub fn loadMetadata(
    gpa: Allocator,
    io: Io,
    list: *Playlist,
    /// Called after each track so a caller can show progress.
    progress: ?*const fn (done: usize, total: usize) void,
) void {
    const total = list.count();
    for (0..total) |i| {
        defer if (progress) |p| p(i + 1, total);

        const path = list.tracks.items[i].path;
        var dec = decoder_mod.Decoder.openFile(gpa, io, path) catch continue;
        defer dec.deinit();

        var tags: tags_mod.Tags = if (dec.tagBlock()) |block| tags_mod.parse(gpa, switch (block) {
            .id3 => |b| .{ .id3 = b },
            .vorbis_comment => |b| .{ .vorbis_comment = b },
            .riff_info => |b| .{ .riff_info = b },
        }) else tags_mod.Tags.init(gpa);
        defer tags.deinit();

        list.updateMetadata(i, dec.info(), &tags) catch {};
    }
}

const testing = std.testing;

test "playlist file detection" {
    try testing.expect(isPlaylistFile("set.m3u"));
    try testing.expect(isPlaylistFile("set.M3U8"));
    try testing.expect(!isPlaylistFile("song.flac"));
    try testing.expect(!isPlaylistFile("noext"));
}

test "natural ordering puts track 2 before track 10" {
    const paths = [_][]const u8{
        "track10.flac", "track2.flac", "track1.flac", "track20.flac",
    };
    var sorted = paths;
    std.mem.sort([]const u8, &sorted, {}, lessThanNatural);
    try testing.expectEqualStrings("track1.flac", sorted[0]);
    try testing.expectEqualStrings("track2.flac", sorted[1]);
    try testing.expectEqualStrings("track10.flac", sorted[2]);
    try testing.expectEqualStrings("track20.flac", sorted[3]);
}

test "natural ordering handles leading zeros and case" {
    try testing.expect(lessThanNatural({}, "07 - a.flac", "10 - b.flac"));
    try testing.expect(lessThanNatural({}, "a.flac", "B.flac"));
    try testing.expect(!lessThanNatural({}, "B.flac", "a.flac"));
    // Equal numeric value, so it falls through to the rest of the string.
    try testing.expect(lessThanNatural({}, "007a", "7b"));
    try testing.expect(lessThanNatural({}, "abc", "abcd"));
}

test "scanning a directory tree finds playable files in order" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Lay out an album with a cover image and a nested disc directory.
    const files = [_][]const u8{
        "02 - second.wav",
        "10 - tenth.wav",
        "01 - first.wav",
        "cover.jpg",
        "notes.txt",
    };
    for (files) |name| {
        const f = try tmp.dir.createFile(io, name, .{});
        f.close(io);
    }
    var sub = try tmp.dir.createDirPathOpen(io, "disc2", .{});
    sub.close(io);
    const nested = try tmp.dir.createFile(io, "disc2/03 - nested.flac", .{});
    nested.close(io);

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var list = Playlist.init(gpa, 0);
    defer list.deinit();

    const result = try add(gpa, io, &list, root, .{});
    try testing.expectEqual(@as(usize, 4), result.added);
    try testing.expectEqual(@as(usize, 4), list.count());
    // Non-audio files are skipped, not queued.
    try testing.expect(result.skipped >= 2);

    // Natural order across the whole tree.
    try testing.expect(std.mem.endsWith(u8, list.at(0).?.path, "01 - first.wav"));
    try testing.expect(std.mem.endsWith(u8, list.at(1).?.path, "02 - second.wav"));
    try testing.expect(std.mem.endsWith(u8, list.at(2).?.path, "10 - tenth.wav"));
    try testing.expect(std.mem.endsWith(u8, list.at(3).?.path, "03 - nested.flac"));
}

test "non-recursive scanning stays in the top directory" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const top = try tmp.dir.createFile(io, "top.wav", .{});
    top.close(io);
    var sub = try tmp.dir.createDirPathOpen(io, "deeper", .{});
    sub.close(io);
    const nested = try tmp.dir.createFile(io, "deeper/nested.wav", .{});
    nested.close(io);

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var list = Playlist.init(gpa, 0);
    defer list.deinit();
    const result = try add(gpa, io, &list, root, .{ .recursive = false });
    try testing.expectEqual(@as(usize, 1), result.added);
    try testing.expect(std.mem.endsWith(u8, list.at(0).?.path, "top.wav"));
}

test "a missing path reports NotFound" {
    const gpa = testing.allocator;
    var list = Playlist.init(gpa, 0);
    defer list.deinit();
    try testing.expectError(
        error.NotFound,
        add(gpa, testing.io, &list, "no/such/path/at/all", .{}),
    );
}

test "m3u round trip preserves paths and metadata" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir_path);
    const m3u_path = try std.fmt.allocPrint(gpa, "{s}/set.m3u8", .{dir_path});
    defer gpa.free(m3u_path);

    var saved = Playlist.init(gpa, 0);
    defer saved.deinit();
    _ = try saved.appendTrack(.{
        .path = "music/one.flac",
        .title = "One",
        .artist = "Someone",
        .duration_s = 123.4,
    });
    _ = try saved.appendTrack(.{ .path = "music/two.mp3", .title = "Two" });

    try saveM3u(io, &saved, m3u_path);

    var loaded = Playlist.init(gpa, 0);
    defer loaded.deinit();
    const result = try loadM3u(gpa, io, &loaded, m3u_path);

    try testing.expectEqual(@as(usize, 2), result.added);
    try testing.expectEqualStrings("One", loaded.at(0).?.title.?);
    try testing.expectEqualStrings("Someone", loaded.at(0).?.artist.?);
    try testing.expectApproxEqAbs(@as(f64, 123.0), loaded.at(0).?.duration_s.?, 0.5);
    try testing.expectEqualStrings("Two", loaded.at(1).?.title.?);
    // Unknown duration round-trips as unknown rather than as -1 seconds.
    try testing.expect(loaded.at(1).?.duration_s == null);

    // Relative entries resolve against the playlist's own directory.
    try testing.expect(std.mem.indexOf(u8, loaded.at(0).?.path, "music") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.at(0).?.path, tmp.sub_path[0..8]) != null);
}

test "m3u comments and blank lines are ignored" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const content =
        "#EXTM3U\n" ++
        "\n" ++
        "# just a comment\n" ++
        "/abs/one.flac\n" ++
        "#EXTINF:-1,Unknown Length\n" ++
        "/abs/two.flac\n";
    const f = try tmp.dir.createFile(io, "x.m3u", .{});
    try f.writeStreamingAll(io, content);
    f.close(io);

    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/x.m3u", .{tmp.sub_path});
    defer gpa.free(path);

    var list = Playlist.init(gpa, 0);
    defer list.deinit();
    const result = try loadM3u(gpa, io, &list, path);
    try testing.expectEqual(@as(usize, 2), result.added);
    try testing.expect(list.at(1).?.duration_s == null);
    try testing.expectEqualStrings("Unknown Length", list.at(1).?.title.?);
}

test "scan results merge" {
    var a: ScanResult = .{ .added = 2, .skipped = 1, .directories = 1 };
    a.merge(.{ .added = 3, .skipped = 4, .directories = 2 });
    try testing.expectEqual(@as(usize, 5), a.added);
    try testing.expectEqual(@as(usize, 5), a.skipped);
    try testing.expectEqual(@as(usize, 3), a.directories);
}
