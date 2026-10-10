//! Tag reading for the three metadata formats the supported containers use:
//! ID3v2 (MP3, and sometimes WAV or FLAC), Vorbis comments (FLAC) and RIFF
//! INFO (WAV).
//!
//! Every string is normalized to UTF-8 and owned by the `Tags` struct, so the
//! caller can drop the file mapping and keep the tags.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tags = struct {
    gpa: Allocator,
    title: ?[]u8 = null,
    artist: ?[]u8 = null,
    album: ?[]u8 = null,
    album_artist: ?[]u8 = null,
    genre: ?[]u8 = null,
    date: ?[]u8 = null,
    comment: ?[]u8 = null,
    track: ?u32 = null,
    track_total: ?u32 = null,
    disc: ?u32 = null,
    /// ReplayGain adjustments, in dB, if the file carries them.
    gain_track_db: ?f32 = null,
    gain_album_db: ?f32 = null,

    pub fn init(gpa: Allocator) Tags {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tags) void {
        const fields = [_]*?[]u8{
            &self.title,     &self.artist,  &self.album,
            &self.album_artist, &self.genre, &self.date,
            &self.comment,
        };
        for (fields) |f| {
            if (f.*) |v| self.gpa.free(v);
            f.* = null;
        }
    }

    /// Take ownership of `value`, replacing whatever was there. An empty or
    /// whitespace-only value is discarded rather than stored.
    fn setOwned(self: *Tags, field: *?[]u8, value: []u8) void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n\x00");
        if (trimmed.len == 0) {
            self.gpa.free(value);
            return;
        }
        // Keep only the trimmed span, reusing the allocation when possible.
        if (trimmed.ptr == value.ptr and trimmed.len == value.len) {
            if (field.*) |old| self.gpa.free(old);
            field.* = value;
            return;
        }
        const copy = self.gpa.dupe(u8, trimmed) catch {
            self.gpa.free(value);
            return;
        };
        self.gpa.free(value);
        if (field.*) |old| self.gpa.free(old);
        field.* = copy;
    }

    fn setFromSlice(self: *Tags, field: *?[]u8, value: []const u8) void {
        const copy = self.gpa.dupe(u8, value) catch return;
        self.setOwned(field, copy);
    }

    pub fn hasAny(self: *const Tags) bool {
        return self.title != null or self.artist != null or self.album != null;
    }

    /// Title for display, falling back to the file's base name.
    pub fn displayTitle(self: *const Tags, path: []const u8) []const u8 {
        if (self.title) |t| return t;
        return baseName(path);
    }

    pub fn displayArtist(self: *const Tags) []const u8 {
        return self.artist orelse self.album_artist orelse "Unknown artist";
    }

    pub fn displayAlbum(self: *const Tags) []const u8 {
        return self.album orelse "";
    }

    /// The ReplayGain value to apply, preferring the album value so a whole
    /// record keeps its internal dynamics.
    pub fn replayGainDb(self: *const Tags, prefer_album: bool) ?f32 {
        if (prefer_album) return self.gain_album_db orelse self.gain_track_db;
        return self.gain_track_db orelse self.gain_album_db;
    }
};

pub fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const name = path[start..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) return name[0..dot];
    }
    return name;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

pub const Block = union(enum) {
    id3: []const u8,
    vorbis_comment: []const u8,
    riff_info: []const u8,
};

/// Parse whichever tag block the container produced. Unparseable data yields
/// empty tags rather than an error: bad metadata should never stop playback.
pub fn parse(gpa: Allocator, block: Block) Tags {
    var tags = Tags.init(gpa);
    switch (block) {
        .id3 => |b| parseId3(&tags, b) catch {},
        .vorbis_comment => |b| parseVorbis(&tags, b) catch {},
        .riff_info => |b| parseRiffInfo(&tags, b) catch {},
    }
    return tags;
}

const ParseError = error{ Malformed, OutOfMemory };

// ---------------------------------------------------------------------------
// ID3v2
// ---------------------------------------------------------------------------

fn parseId3(tags: *Tags, data: []const u8) ParseError!void {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return error.Malformed;
    const major = data[3];
    const flags = data[5];
    const size = syncSafe(data[6..10].*);

    var pos: usize = 10;
    const end = @min(data.len, 10 + size);

    // Skip the extended header when present.
    if (flags & 0x40 != 0) {
        if (major >= 4) {
            if (pos + 4 > end) return error.Malformed;
            pos += syncSafe(data[pos..][0..4].*);
        } else {
            if (pos + 4 > end) return error.Malformed;
            pos += 4 + std.mem.readInt(u32, data[pos..][0..4], .big);
        }
        if (pos > end) return error.Malformed;
    }

    const id_len: usize = if (major <= 2) 3 else 4;
    const size_len: usize = if (major <= 2) 3 else 4;
    const flag_len: usize = if (major <= 2) 0 else 2;

    while (pos + id_len + size_len + flag_len <= end) {
        const id = data[pos..][0..id_len];
        // Padding at the end of the tag is all zeros.
        if (id[0] == 0) break;

        var frame_size: usize = 0;
        const size_bytes = data[pos + id_len ..][0..size_len];
        if (major >= 4) {
            // v2.4 uses sync-safe frame sizes. Some encoders get this wrong
            // and write a plain integer; fall back if the sync-safe reading
            // would run past the tag.
            frame_size = syncSafe(size_bytes[0..4].*);
            const plain = std.mem.readInt(u32, size_bytes[0..4], .big);
            const after_sync = pos + id_len + size_len + flag_len + frame_size;
            if (after_sync > end and pos + id_len + size_len + flag_len + plain <= end) {
                frame_size = plain;
            }
        } else if (major == 3) {
            frame_size = std.mem.readInt(u32, size_bytes[0..4], .big);
        } else {
            frame_size = (@as(usize, size_bytes[0]) << 16) |
                (@as(usize, size_bytes[1]) << 8) |
                @as(usize, size_bytes[2]);
        }

        const body_start = pos + id_len + size_len + flag_len;
        if (frame_size == 0 or body_start + frame_size > end) break;
        const body = data[body_start..][0..frame_size];

        try applyId3Frame(tags, id, body);
        pos = body_start + frame_size;
    }
}

fn applyId3Frame(tags: *Tags, id: []const u8, body: []const u8) ParseError!void {
    const Field = enum { title, artist, album, album_artist, genre, date, track, disc, comment, txxx, none };

    const field: Field = blk: {
        // v2.3 / v2.4 four-character identifiers.
        if (id.len == 4) {
            if (std.mem.eql(u8, id, "TIT2")) break :blk .title;
            if (std.mem.eql(u8, id, "TPE1")) break :blk .artist;
            if (std.mem.eql(u8, id, "TALB")) break :blk .album;
            if (std.mem.eql(u8, id, "TPE2")) break :blk .album_artist;
            if (std.mem.eql(u8, id, "TCON")) break :blk .genre;
            if (std.mem.eql(u8, id, "TDRC")) break :blk .date;
            if (std.mem.eql(u8, id, "TYER")) break :blk .date;
            if (std.mem.eql(u8, id, "TDAT")) break :blk .none;
            if (std.mem.eql(u8, id, "TRCK")) break :blk .track;
            if (std.mem.eql(u8, id, "TPOS")) break :blk .disc;
            if (std.mem.eql(u8, id, "COMM")) break :blk .comment;
            if (std.mem.eql(u8, id, "TXXX")) break :blk .txxx;
            break :blk .none;
        }
        // v2.2 three-character identifiers.
        if (std.mem.eql(u8, id, "TT2")) break :blk .title;
        if (std.mem.eql(u8, id, "TP1")) break :blk .artist;
        if (std.mem.eql(u8, id, "TAL")) break :blk .album;
        if (std.mem.eql(u8, id, "TP2")) break :blk .album_artist;
        if (std.mem.eql(u8, id, "TCO")) break :blk .genre;
        if (std.mem.eql(u8, id, "TYE")) break :blk .date;
        if (std.mem.eql(u8, id, "TRK")) break :blk .track;
        if (std.mem.eql(u8, id, "TPA")) break :blk .disc;
        if (std.mem.eql(u8, id, "COM")) break :blk .comment;
        break :blk .none;
    };
    if (field == .none) return;

    if (body.len < 1) return;
    const encoding = body[0];
    var payload = body[1..];

    // COMM and TXXX carry extra leading fields before the value.
    if (field == .comment) {
        // Three-byte language code, then a description terminated by the
        // encoding's null.
        if (payload.len < 3) return;
        payload = payload[3..];
        payload = skipTerminatedString(payload, encoding);
    }

    if (field == .txxx) {
        const desc_end = findTerminator(payload, encoding);
        const desc_raw = payload[0..desc_end];
        const value_raw = skipTerminatedString(payload, encoding);
        const desc = decodeText(tags.gpa, encoding, desc_raw) catch return;
        defer tags.gpa.free(desc);
        const value = decodeText(tags.gpa, encoding, value_raw) catch return;
        defer tags.gpa.free(value);
        applyReplayGain(tags, desc, value);
        return;
    }

    const text = decodeText(tags.gpa, encoding, payload) catch return;

    switch (field) {
        .title => tags.setOwned(&tags.title, text),
        .artist => tags.setOwned(&tags.artist, text),
        .album => tags.setOwned(&tags.album, text),
        .album_artist => tags.setOwned(&tags.album_artist, text),
        .genre => tags.setOwned(&tags.genre, decodeGenre(tags.gpa, text)),
        .date => tags.setOwned(&tags.date, text),
        .comment => tags.setOwned(&tags.comment, text),
        .track => {
            defer tags.gpa.free(text);
            const parsed = parseSlashPair(text);
            tags.track = parsed.first;
            if (parsed.second) |t| tags.track_total = t;
        },
        .disc => {
            defer tags.gpa.free(text);
            tags.disc = parseSlashPair(text).first;
        },
        .txxx, .none => tags.gpa.free(text),
    }
}

/// ID3v1 numeric genres can appear in a v2 TCON frame as "(17)" or "17".
fn decodeGenre(gpa: Allocator, text: []u8) []u8 {
    const inner = std.mem.trim(u8, text, "()");
    const n = std.fmt.parseInt(u8, inner, 10) catch return text;
    const name = id3v1Genre(n) orelse return text;
    const copy = gpa.dupe(u8, name) catch return text;
    gpa.free(text);
    return copy;
}

fn findTerminator(data: []const u8, encoding: u8) usize {
    if (encoding == 1 or encoding == 2) {
        // UTF-16: the terminator is two zero bytes on an even boundary.
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            if (data[i] == 0 and data[i + 1] == 0) return i;
        }
        return data.len;
    }
    return std.mem.indexOfScalar(u8, data, 0) orelse data.len;
}

fn skipTerminatedString(data: []const u8, encoding: u8) []const u8 {
    const t = findTerminator(data, encoding);
    const skip: usize = if (encoding == 1 or encoding == 2) 2 else 1;
    const next = @min(data.len, t + skip);
    return data[next..];
}

/// Convert an ID3 text payload to owned UTF-8.
fn decodeText(gpa: Allocator, encoding: u8, raw: []const u8) ParseError![]u8 {
    // Trim the trailing terminator that many encoders include in the frame
    // size. This has to respect the encoding's unit width: in UTF-16 the high
    // byte of an ASCII character is itself zero, so trimming single bytes
    // would eat the last real character and leave an odd-length buffer.
    var data = raw;
    if (encoding == 1 or encoding == 2) {
        if (data.len % 2 != 0) data = data[0 .. data.len - 1];
        while (data.len >= 2 and data[data.len - 1] == 0 and data[data.len - 2] == 0) {
            data = data[0 .. data.len - 2];
        }
    } else {
        while (data.len > 0 and data[data.len - 1] == 0) data = data[0 .. data.len - 1];
    }

    return switch (encoding) {
        // ISO-8859-1: every byte is a code point below 256.
        0 => latin1ToUtf8(gpa, data),
        1 => blk: {
            // UTF-16 with a byte-order mark.
            if (data.len < 2) break :blk gpa.dupe(u8, "");
            const big_endian = data[0] == 0xFE and data[1] == 0xFF;
            const has_bom = big_endian or (data[0] == 0xFF and data[1] == 0xFE);
            const body = if (has_bom) data[2..] else data;
            break :blk utf16ToUtf8(gpa, body, big_endian);
        },
        2 => utf16ToUtf8(gpa, data, true), // UTF-16BE, no BOM
        3 => gpa.dupe(u8, data), // already UTF-8
        else => latin1ToUtf8(gpa, data),
    };
}

fn latin1ToUtf8(gpa: Allocator, data: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, data.len);
    for (data) |b| {
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
        } else {
            // Two-byte UTF-8 for U+0080..U+00FF.
            try out.append(gpa, 0xC0 | (b >> 6));
            try out.append(gpa, 0x80 | (b & 0x3F));
        }
    }
    return out.toOwnedSlice(gpa);
}

fn utf16ToUtf8(gpa: Allocator, data: []const u8, big_endian: bool) ParseError![]u8 {
    const count = data.len / 2;
    const units = try gpa.alloc(u16, count);
    defer gpa.free(units);
    for (0..count) |i| {
        const pair = data[i * 2 ..][0..2];
        units[i] = std.mem.readInt(u16, pair, if (big_endian) .big else .little);
    }
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // Lone surrogates and other junk: fall back to a lossy read so the
        // rest of the tag still shows up.
        else => lossyUtf16(gpa, units),
    };
}

fn lossyUtf16(gpa: Allocator, units: []const u16) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (units) |u| {
        if (u == 0) continue;
        var buf: [4]u8 = undefined;
        const codepoint: u21 = if (u >= 0xD800 and u <= 0xDFFF) 0xFFFD else u;
        const n = std.unicode.utf8Encode(codepoint, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn syncSafe(b: [4]u8) usize {
    return (@as(usize, b[0] & 0x7F) << 21) |
        (@as(usize, b[1] & 0x7F) << 14) |
        (@as(usize, b[2] & 0x7F) << 7) |
        @as(usize, b[3] & 0x7F);
}

const SlashPair = struct { first: ?u32, second: ?u32 };

/// Parse "5" or "5/12" as used by track and disc numbers.
fn parseSlashPair(text: []const u8) SlashPair {
    const trimmed = std.mem.trim(u8, text, " \t\x00");
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        return .{
            .first = std.fmt.parseInt(u32, std.mem.trim(u8, trimmed[0..slash], " "), 10) catch null,
            .second = std.fmt.parseInt(u32, std.mem.trim(u8, trimmed[slash + 1 ..], " "), 10) catch null,
        };
    }
    return .{
        .first = std.fmt.parseInt(u32, trimmed, 10) catch null,
        .second = null,
    };
}

// ---------------------------------------------------------------------------
// Vorbis comments
// ---------------------------------------------------------------------------

fn parseVorbis(tags: *Tags, data: []const u8) ParseError!void {
    if (data.len < 8) return error.Malformed;

    // Lengths come straight off disk, so every offset is computed in 64 bits
    // and bounds-checked before use; a hostile or truncated file must not be
    // able to overflow a usize.
    const vendor_len = std.mem.readInt(u32, data[0..4], .little);
    var pos: u64 = 4 + @as(u64, vendor_len);
    if (pos + 4 > data.len) return error.Malformed;

    const count = std.mem.readInt(u32, data[@intCast(pos)..][0..4], .little);
    pos += 4;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 4 > data.len) return error.Malformed;
        const len = std.mem.readInt(u32, data[@intCast(pos)..][0..4], .little);
        pos += 4;
        if (pos + @as(u64, len) > data.len) return error.Malformed;
        const entry = data[@intCast(pos)..][0..len];
        pos += len;

        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];
        applyVorbisField(tags, key, value);
    }
}

fn applyVorbisField(tags: *Tags, key: []const u8, value: []const u8) void {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(key, "TITLE")) {
        tags.setFromSlice(&tags.title, value);
    } else if (eq(key, "ARTIST")) {
        tags.setFromSlice(&tags.artist, value);
    } else if (eq(key, "ALBUM")) {
        tags.setFromSlice(&tags.album, value);
    } else if (eq(key, "ALBUMARTIST") or eq(key, "ALBUM ARTIST")) {
        tags.setFromSlice(&tags.album_artist, value);
    } else if (eq(key, "GENRE")) {
        tags.setFromSlice(&tags.genre, value);
    } else if (eq(key, "DATE") or eq(key, "YEAR")) {
        tags.setFromSlice(&tags.date, value);
    } else if (eq(key, "COMMENT") or eq(key, "DESCRIPTION")) {
        tags.setFromSlice(&tags.comment, value);
    } else if (eq(key, "TRACKNUMBER")) {
        const p = parseSlashPair(value);
        tags.track = p.first;
        if (p.second) |t| tags.track_total = t;
    } else if (eq(key, "TRACKTOTAL") or eq(key, "TOTALTRACKS")) {
        tags.track_total = std.fmt.parseInt(u32, std.mem.trim(u8, value, " "), 10) catch null;
    } else if (eq(key, "DISCNUMBER")) {
        tags.disc = parseSlashPair(value).first;
    } else {
        applyReplayGain(tags, key, value);
    }
}

/// ReplayGain values are stored as a string like "-7.26 dB" under a key that
/// is spelled the same way in Vorbis comments and in ID3 TXXX frames.
fn applyReplayGain(tags: *Tags, key: []const u8, value: []const u8) void {
    const eq = std.ascii.eqlIgnoreCase;
    const is_track = eq(key, "REPLAYGAIN_TRACK_GAIN");
    const is_album = eq(key, "REPLAYGAIN_ALBUM_GAIN");
    if (!is_track and !is_album) return;

    var text = std.mem.trim(u8, value, " \t");
    // Drop a trailing "dB" / "db".
    if (text.len > 2 and std.ascii.eqlIgnoreCase(text[text.len - 2 ..], "db")) {
        text = std.mem.trim(u8, text[0 .. text.len - 2], " \t");
    }
    const db = std.fmt.parseFloat(f32, text) catch return;
    if (!std.math.isFinite(db)) return;
    if (is_track) tags.gain_track_db = db else tags.gain_album_db = db;
}

// ---------------------------------------------------------------------------
// RIFF INFO
// ---------------------------------------------------------------------------

fn parseRiffInfo(tags: *Tags, data: []const u8) ParseError!void {
    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const raw_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        const size = @min(@as(usize, raw_size), data.len - body_start);
        const body = data[body_start..][0..size];

        // RIFF INFO strings are nominally ASCII but in practice often
        // Latin-1, so decode them the same way.
        const value = latin1ToUtf8(tags.gpa, std.mem.sliceTo(body, 0)) catch body_err: {
            break :body_err try tags.gpa.dupe(u8, "");
        };

        if (std.mem.eql(u8, id, "INAM")) {
            tags.setOwned(&tags.title, value);
        } else if (std.mem.eql(u8, id, "IART")) {
            tags.setOwned(&tags.artist, value);
        } else if (std.mem.eql(u8, id, "IPRD")) {
            tags.setOwned(&tags.album, value);
        } else if (std.mem.eql(u8, id, "ICRD")) {
            tags.setOwned(&tags.date, value);
        } else if (std.mem.eql(u8, id, "IGNR")) {
            tags.setOwned(&tags.genre, value);
        } else if (std.mem.eql(u8, id, "ICMT")) {
            tags.setOwned(&tags.comment, value);
        } else if (std.mem.eql(u8, id, "ITRK") or std.mem.eql(u8, id, "IPRT")) {
            defer tags.gpa.free(value);
            tags.track = parseSlashPair(value).first;
        } else {
            tags.gpa.free(value);
        }

        pos = body_start + size + (size & 1);
        if (size == 0) break;
    }
}

/// The ID3v1 genre list, which v2 tags still reference numerically.
fn id3v1Genre(n: u8) ?[]const u8 {
    const names = [_][]const u8{
        "Blues",             "Classic Rock",    "Country",         "Dance",
        "Disco",             "Funk",            "Grunge",          "Hip-Hop",
        "Jazz",              "Metal",           "New Age",         "Oldies",
        "Other",             "Pop",             "R&B",             "Rap",
        "Reggae",            "Rock",            "Techno",          "Industrial",
        "Alternative",       "Ska",             "Death Metal",     "Pranks",
        "Soundtrack",        "Euro-Techno",     "Ambient",         "Trip-Hop",
        "Vocal",             "Jazz+Funk",       "Fusion",          "Trance",
        "Classical",         "Instrumental",    "Acid",            "House",
        "Game",              "Sound Clip",      "Gospel",          "Noise",
        "Alternative Rock",  "Bass",            "Soul",            "Punk",
        "Space",             "Meditative",      "Instrumental Pop", "Instrumental Rock",
        "Ethnic",            "Gothic",          "Darkwave",        "Techno-Industrial",
        "Electronic",        "Pop-Folk",        "Eurodance",       "Dream",
        "Southern Rock",     "Comedy",          "Cult",            "Gangsta",
        "Top 40",            "Christian Rap",   "Pop/Funk",        "Jungle",
        "Native American",   "Cabaret",         "New Wave",        "Psychedelic",
        "Rave",              "Showtunes",       "Trailer",         "Lo-Fi",
        "Tribal",            "Acid Punk",       "Acid Jazz",       "Polka",
        "Retro",             "Musical",         "Rock & Roll",     "Hard Rock",
    };
    if (n >= names.len) return null;
    return names[n];
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "base name strips directories and extension" {
    try testing.expectEqualStrings("song", baseName("C:\\music\\song.flac"));
    try testing.expectEqualStrings("song", baseName("/home/x/song.mp3"));
    try testing.expectEqualStrings("song", baseName("song"));
    try testing.expectEqualStrings(".hidden", baseName(".hidden"));
}

test "display helpers fall back sensibly" {
    const gpa = testing.allocator;
    var tags = Tags.init(gpa);
    defer tags.deinit();

    try testing.expectEqualStrings("track01", tags.displayTitle("a/track01.wav"));
    try testing.expectEqualStrings("Unknown artist", tags.displayArtist());
    try testing.expectEqualStrings("", tags.displayAlbum());

    tags.setFromSlice(&tags.title, "Real Title");
    try testing.expectEqualStrings("Real Title", tags.displayTitle("a/track01.wav"));
}

test "empty values are not stored" {
    const gpa = testing.allocator;
    var tags = Tags.init(gpa);
    defer tags.deinit();
    tags.setFromSlice(&tags.title, "   ");
    try testing.expect(tags.title == null);
    tags.setFromSlice(&tags.title, "  padded  ");
    try testing.expectEqualStrings("padded", tags.title.?);
}

test "slash pairs" {
    try testing.expectEqual(@as(?u32, 5), parseSlashPair("5").first);
    const pair = parseSlashPair("3/12");
    try testing.expectEqual(@as(?u32, 3), pair.first);
    try testing.expectEqual(@as(?u32, 12), pair.second);
    try testing.expect(parseSlashPair("abc").first == null);
}

test "latin-1 becomes valid UTF-8" {
    const gpa = testing.allocator;
    // 0xE9 is 'e' with an acute accent in Latin-1.
    const out = try latin1ToUtf8(gpa, &[_]u8{ 'c', 'a', 'f', 0xE9 });
    defer gpa.free(out);
    try testing.expectEqualStrings("caf\u{00E9}", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "vorbis comments populate every field" {
    const gpa = testing.allocator;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    const vendor = "reference libFLAC";
    try appendU32(gpa, &payload, @intCast(vendor.len));
    try payload.appendSlice(gpa, vendor);

    const entries = [_][]const u8{
        "TITLE=Blue Monk",
        "ARTIST=Thelonious Monk",
        "ALBUM=Monk's Music",
        "ALBUMARTIST=Monk Quartet",
        "GENRE=Jazz",
        "DATE=1957",
        "TRACKNUMBER=4/7",
        "DISCNUMBER=1",
        "COMMENT=hello",
        "REPLAYGAIN_TRACK_GAIN=-7.26 dB",
        "REPLAYGAIN_ALBUM_GAIN=-6.10 dB",
    };
    try appendU32(gpa, &payload, entries.len);
    for (entries) |e| {
        try appendU32(gpa, &payload, @intCast(e.len));
        try payload.appendSlice(gpa, e);
    }

    var tags = parse(gpa, .{ .vorbis_comment = payload.items });
    defer tags.deinit();

    try testing.expectEqualStrings("Blue Monk", tags.title.?);
    try testing.expectEqualStrings("Thelonious Monk", tags.artist.?);
    try testing.expectEqualStrings("Monk's Music", tags.album.?);
    try testing.expectEqualStrings("Monk Quartet", tags.album_artist.?);
    try testing.expectEqualStrings("Jazz", tags.genre.?);
    try testing.expectEqualStrings("1957", tags.date.?);
    try testing.expectEqualStrings("hello", tags.comment.?);
    try testing.expectEqual(@as(?u32, 4), tags.track);
    try testing.expectEqual(@as(?u32, 7), tags.track_total);
    try testing.expectEqual(@as(?u32, 1), tags.disc);
    try testing.expectApproxEqAbs(@as(f32, -7.26), tags.gain_track_db.?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -6.10), tags.gain_album_db.?, 1e-4);
    try testing.expect(tags.hasAny());

    // Album gain is preferred when asked for.
    try testing.expectApproxEqAbs(@as(f32, -6.10), tags.replayGainDb(true).?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -7.26), tags.replayGainDb(false).?, 1e-4);
}

test "malformed vorbis data yields empty tags rather than failing" {
    const gpa = testing.allocator;
    var tags = parse(gpa, .{ .vorbis_comment = "\xFF\xFF\xFF\xFF garbage" });
    defer tags.deinit();
    try testing.expect(!tags.hasAny());
}

test "id3v2.3 text frames" {
    const gpa = testing.allocator;
    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(gpa);

    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    try appendId3Frame(gpa, &frames, "TIT2", 0, "So What");
    try appendId3Frame(gpa, &frames, "TPE1", 0, "Miles Davis");
    try appendId3Frame(gpa, &frames, "TALB", 3, "Kind of Blue");
    try appendId3Frame(gpa, &frames, "TRCK", 0, "1/5");
    try appendId3Frame(gpa, &frames, "TYER", 0, "1959");
    try appendId3Frame(gpa, &frames, "TCON", 0, "(8)"); // numeric genre

    try tag.appendSlice(gpa, "ID3");
    try tag.appendSlice(gpa, &.{ 3, 0, 0 });
    try appendSyncSafe(gpa, &tag, @intCast(frames.items.len));
    try tag.appendSlice(gpa, frames.items);

    var tags = parse(gpa, .{ .id3 = tag.items });
    defer tags.deinit();

    try testing.expectEqualStrings("So What", tags.title.?);
    try testing.expectEqualStrings("Miles Davis", tags.artist.?);
    try testing.expectEqualStrings("Kind of Blue", tags.album.?);
    try testing.expectEqual(@as(?u32, 1), tags.track);
    try testing.expectEqual(@as(?u32, 5), tags.track_total);
    try testing.expectEqualStrings("1959", tags.date.?);
    // Genre 8 is Jazz in the ID3v1 list.
    try testing.expectEqualStrings("Jazz", tags.genre.?);
}

test "id3v2.4 sync-safe frame sizes" {
    const gpa = testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    try appendId3Frame24(gpa, &frames, "TIT2", 3, "Giant Steps");

    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(gpa);
    try tag.appendSlice(gpa, "ID3");
    try tag.appendSlice(gpa, &.{ 4, 0, 0 });
    try appendSyncSafe(gpa, &tag, @intCast(frames.items.len));
    try tag.appendSlice(gpa, frames.items);

    var tags = parse(gpa, .{ .id3 = tag.items });
    defer tags.deinit();
    try testing.expectEqualStrings("Giant Steps", tags.title.?);
}

test "id3 UTF-16 text with a BOM" {
    const gpa = testing.allocator;
    // "Naïve" in UTF-16LE with a BOM.
    const utf16 = [_]u8{ 0xFF, 0xFE, 'N', 0, 'a', 0, 0xEF, 0x00, 'v', 0, 'e', 0 };
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    try frames.appendSlice(gpa, "TIT2");
    try appendBigU32(gpa, &frames, @intCast(utf16.len + 1));
    try frames.appendSlice(gpa, &.{ 0, 0 });
    try frames.append(gpa, 1); // UTF-16 with BOM
    try frames.appendSlice(gpa, &utf16);

    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(gpa);
    try tag.appendSlice(gpa, "ID3");
    try tag.appendSlice(gpa, &.{ 3, 0, 0 });
    try appendSyncSafe(gpa, &tag, @intCast(frames.items.len));
    try tag.appendSlice(gpa, frames.items);

    var tags = parse(gpa, .{ .id3 = tag.items });
    defer tags.deinit();
    try testing.expectEqualStrings("Na\u{00EF}ve", tags.title.?);
}

test "id3 TXXX carries replay gain" {
    const gpa = testing.allocator;
    const payload = "REPLAYGAIN_TRACK_GAIN\x00-3.50 dB";
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    try frames.appendSlice(gpa, "TXXX");
    try appendBigU32(gpa, &frames, @intCast(payload.len + 1));
    try frames.appendSlice(gpa, &.{ 0, 0 });
    try frames.append(gpa, 0); // Latin-1
    try frames.appendSlice(gpa, payload);

    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(gpa);
    try tag.appendSlice(gpa, "ID3");
    try tag.appendSlice(gpa, &.{ 3, 0, 0 });
    try appendSyncSafe(gpa, &tag, @intCast(frames.items.len));
    try tag.appendSlice(gpa, frames.items);

    var tags = parse(gpa, .{ .id3 = tag.items });
    defer tags.deinit();
    try testing.expectApproxEqAbs(@as(f32, -3.50), tags.gain_track_db.?, 1e-4);
}

test "riff info chunks" {
    const gpa = testing.allocator;
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(gpa);
    try appendRiffField(gpa, &info, "INAM", "Field Recording");
    try appendRiffField(gpa, &info, "IART", "Someone");
    try appendRiffField(gpa, &info, "ICRD", "2024");
    try appendRiffField(gpa, &info, "ITRK", "7");

    var tags = parse(gpa, .{ .riff_info = info.items });
    defer tags.deinit();
    try testing.expectEqualStrings("Field Recording", tags.title.?);
    try testing.expectEqualStrings("Someone", tags.artist.?);
    try testing.expectEqualStrings("2024", tags.date.?);
    try testing.expectEqual(@as(?u32, 7), tags.track);
}

test "a truncated id3 tag does not read past the end" {
    const gpa = testing.allocator;
    var tags = parse(gpa, .{ .id3 = "ID3\x03\x00\x00\x7F\x7F\x7F\x7FTIT2\xFF\xFF\xFF\xFF\x00\x00" });
    defer tags.deinit();
    try testing.expect(!tags.hasAny());
}

// --- test helpers ---------------------------------------------------------

fn appendU32(gpa: Allocator, list: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn appendBigU32(gpa: Allocator, list: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(gpa, &b);
}

fn appendSyncSafe(gpa: Allocator, list: *std.ArrayList(u8), v: u32) !void {
    try list.append(gpa, @intCast((v >> 21) & 0x7F));
    try list.append(gpa, @intCast((v >> 14) & 0x7F));
    try list.append(gpa, @intCast((v >> 7) & 0x7F));
    try list.append(gpa, @intCast(v & 0x7F));
}

fn appendId3Frame(
    gpa: Allocator,
    list: *std.ArrayList(u8),
    id: []const u8,
    encoding: u8,
    text: []const u8,
) !void {
    try list.appendSlice(gpa, id);
    try appendBigU32(gpa, list, @intCast(text.len + 1));
    try list.appendSlice(gpa, &.{ 0, 0 });
    try list.append(gpa, encoding);
    try list.appendSlice(gpa, text);
}

fn appendId3Frame24(
    gpa: Allocator,
    list: *std.ArrayList(u8),
    id: []const u8,
    encoding: u8,
    text: []const u8,
) !void {
    try list.appendSlice(gpa, id);
    try appendSyncSafe(gpa, list, @intCast(text.len + 1));
    try list.appendSlice(gpa, &.{ 0, 0 });
    try list.append(gpa, encoding);
    try list.appendSlice(gpa, text);
}

fn appendRiffField(
    gpa: Allocator,
    list: *std.ArrayList(u8),
    id: []const u8,
    text: []const u8,
) !void {
    try list.appendSlice(gpa, id);
    const size: u32 = @intCast(text.len + 1);
    try appendU32(gpa, list, size);
    try list.appendSlice(gpa, text);
    try list.append(gpa, 0);
    if (size & 1 != 0) try list.append(gpa, 0);
}
