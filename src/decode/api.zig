//! Types shared by every decoder, kept in their own file so the concrete
//! decoders and the dispatching union can both depend on them without a
//! circular import.

const std = @import("std");

pub const Error = error{
    /// The container or codec is not one we handle.
    UnsupportedFormat,
    /// The stream is malformed.
    CorruptStream,
    /// The stream ended in the middle of something.
    EndOfStream,
    /// A seek target is outside the stream.
    SeekOutOfRange,
    OutOfMemory,
};

pub const Codec = enum {
    wav,
    flac,
    mp3,
    tone,

    pub fn label(c: Codec) []const u8 {
        return switch (c) {
            .wav => "WAV",
            .flac => "FLAC",
            .mp3 => "MP3",
            .tone => "TONE",
        };
    }
};

/// What a decoder reports about its stream.
pub const Info = struct {
    codec: Codec,
    sample_rate: u32,
    channels: u8,
    /// Source bit depth. Reported for display; output is always f32.
    bits_per_sample: u8,
    /// Total frames, or null when the stream length is unknown.
    total_frames: ?u64,
    /// Whether `seekToFrame` is supported.
    seekable: bool,
    /// Average bitrate in bits per second, when meaningful.
    bitrate: ?u32 = null,

    pub fn durationSeconds(self: Info) ?f64 {
        const frames = self.total_frames orelse return null;
        if (self.sample_rate == 0) return null;
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};
