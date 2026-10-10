//! Format probing and the decoder front end.
//!
//! Probing looks at the bytes rather than the file extension, so a mislabelled
//! file still plays and a `.wav` that is really a FLAC is handled correctly.
//! The extension is only used as a tie-breaker hint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const api = @import("api.zig");
const wav_mod = @import("wav.zig");
const flac_mod = @import("flac.zig");
const tone_mod = @import("tone.zig");
const mp3_mod = @import("mp3.zig");
const Source = @import("source.zig").Source;

pub const Error = api.Error;
pub const Info = api.Info;
pub const Codec = api.Codec;

/// Identify the codec from a file's leading bytes.
pub fn probe(bytes: []const u8) ?Codec {
    if (wav_mod.Wav.looksLikeWav(bytes)) return .wav;
    if (flac_mod.looksLikeFlac(bytes)) return .flac;
    if (mp3_mod.looksLikeMp3(bytes)) return .mp3;
    return null;
}

/// True when the extension is one we might be able to play. Used to filter
/// directory scans before opening anything.
pub fn extensionLooksPlayable(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    const known = [_][]const u8{ "wav", "wave", "flac", "mp3", "mp2" };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(ext, k)) return true;
    }
    return false;
}

/// A decoder for one open stream. Holds the `Source` so the mapped bytes stay
/// alive for as long as anything is decoding from them.
pub const Decoder = struct {
    source: Source,
    impl: Impl,

    pub const Impl = union(Codec) {
        wav: wav_mod.Wav,
        flac: flac_mod.Flac,
        mp3: mp3_mod.Mp3,
        tone: tone_mod.Tone,
    };

    /// Open a file by path. On success the decoder owns the source.
    pub fn openFile(gpa: Allocator, io: Io, path: []const u8) (Error || @import("source.zig").Error)!Decoder {
        var source = try Source.open(gpa, io, path);
        errdefer source.deinit();
        const impl = try openImpl(gpa, source.bytes);
        return .{ .source = source, .impl = impl };
    }

    /// Open from bytes we do not own. Mainly for tests.
    pub fn openBytes(gpa: Allocator, bytes: []const u8) Error!Decoder {
        return .{
            .source = Source.fromBytes(bytes),
            .impl = try openImpl(gpa, bytes),
        };
    }

    /// A synthesized stream, for `--tone` and for trying the output path
    /// without any media on hand.
    pub fn openTone(spec: tone_mod.Spec) Decoder {
        return .{
            .source = Source.fromBytes(&.{}),
            .impl = .{ .tone = tone_mod.Tone.init(spec) },
        };
    }

    fn openImpl(gpa: Allocator, bytes: []const u8) Error!Impl {
        const codec = probe(bytes) orelse return error.UnsupportedFormat;
        return switch (codec) {
            .wav => .{ .wav = try wav_mod.Wav.open(bytes) },
            .flac => .{ .flac = try flac_mod.Flac.open(gpa, bytes) },
            .mp3 => .{ .mp3 = try mp3_mod.Mp3.open(gpa, bytes) },
            .tone => unreachable, // never probed from bytes
        };
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.impl) {
            .wav => {},
            .flac => |*f| f.deinit(),
            .mp3 => |*m| m.deinit(),
            .tone => {},
        }
        self.source.deinit();
        self.* = undefined;
    }

    pub fn info(self: *const Decoder) Info {
        return switch (self.impl) {
            .wav => |*w| w.info(),
            .flac => |*f| f.info(),
            .mp3 => |*m| m.info(),
            .tone => |*t| t.info(),
        };
    }

    /// Decode interleaved float frames. Returns 0 at end of stream.
    pub fn readFrames(self: *Decoder, out: []f32) Error!usize {
        return switch (self.impl) {
            .wav => |*w| w.readFrames(out),
            .flac => |*f| f.readFrames(out),
            .mp3 => |*m| m.readFrames(out),
            .tone => |*t| t.readFrames(out),
        };
    }

    pub fn seekToFrame(self: *Decoder, frame: u64) Error!void {
        return switch (self.impl) {
            .wav => |*w| w.seekToFrame(frame),
            .flac => |*f| f.seekToFrame(frame),
            .mp3 => |*m| m.seekToFrame(frame),
            .tone => |*t| t.seekToFrame(frame),
        };
    }

    pub fn positionFrames(self: *const Decoder) u64 {
        return switch (self.impl) {
            .wav => |*w| w.positionFrames(),
            .flac => |*f| f.positionFrames(),
            .mp3 => |*m| m.positionFrames(),
            .tone => |*t| t.positionFrames(),
        };
    }

    /// The raw tag block for this stream, if the container carries one.
    pub fn tagBlock(self: *const Decoder) ?TagBlock {
        return switch (self.impl) {
            .wav => |*w| blk: {
                if (w.id3_chunk) |c| break :blk .{ .id3 = c };
                if (w.list_info) |c| break :blk .{ .riff_info = c };
                break :blk null;
            },
            .flac => |*f| if (f.vorbis_comment) |c|
                .{ .vorbis_comment = c }
            else
                null,
            .mp3 => |*m| if (m.id3_block()) |c| .{ .id3 = c } else null,
            .tone => null,
        };
    }
};

pub const TagBlock = union(enum) {
    id3: []const u8,
    vorbis_comment: []const u8,
    riff_info: []const u8,
};

const testing = std.testing;

test "probe recognizes containers by content" {
    try testing.expectEqual(Codec.wav, probe("RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try testing.expectEqual(Codec.flac, probe("fLaC\x00\x00\x00\x22").?);
    try testing.expect(probe("nothing here at all") == null);
    try testing.expect(probe("") == null);
}

test "extension filter" {
    try testing.expect(extensionLooksPlayable("song.flac"));
    try testing.expect(extensionLooksPlayable("song.FLAC"));
    try testing.expect(extensionLooksPlayable("a/b/c.wav"));
    try testing.expect(extensionLooksPlayable("x.mp3"));
    try testing.expect(!extensionLooksPlayable("cover.jpg"));
    try testing.expect(!extensionLooksPlayable("README"));
}

test "opening an unknown format fails cleanly" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedFormat, Decoder.openBytes(gpa, "random bytes"));
}

test "a WAV opens through the dispatcher" {
    const gpa = testing.allocator;
    const pcm = [_]u8{ 0, 0, 0, 0x40, 0, 0, 0, 0xC0 }; // 2 stereo i16 frames
    const bytes = try wav_mod.buildWav(gpa, .i16_pcm, .{ .sample_rate = 44_100, .channels = 2 }, &pcm);
    defer gpa.free(bytes);

    var dec = try Decoder.openBytes(gpa, bytes);
    defer dec.deinit();

    try testing.expectEqual(Codec.wav, dec.info().codec);
    try testing.expectEqual(@as(u64, 2), dec.info().total_frames.?);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec.readFrames(&out));
    try testing.expectEqual(@as(u64, 2), dec.positionFrames());
    try dec.seekToFrame(0);
    try testing.expectEqual(@as(u64, 0), dec.positionFrames());
}

test "a tone source behaves like any other stream" {
    var dec = Decoder.openTone(.{
        .sample_rate = 48_000,
        .channels = 2,
        .frames = 4800,
        .shape = .{ .sine = .{ .freq = 440 } },
    });
    defer dec.deinit();

    const nfo = dec.info();
    try testing.expectEqual(Codec.tone, nfo.codec);
    try testing.expectEqual(@as(u64, 4800), nfo.total_frames.?);

    var out: [200]f32 = undefined;
    try testing.expectEqual(@as(usize, 100), try dec.readFrames(&out));
    var peak: f32 = 0;
    for (out) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak > 0.1);
}
