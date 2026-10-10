//! The playback engine: threads, buffering, and everything that has to happen
//! on a deadline.
//!
//! Three threads touch this object, with a strict division of labour:
//!
//!   UI / CLI thread  owns the playlist and issues commands. May block.
//!   decoder thread   opens files, decodes, resamples and fills the ring.
//!                    May block and allocate.
//!   audio thread     (inside the backend) drains the ring, runs the DSP
//!                    chain and hands bytes to the device. Must never block,
//!                    allocate, lock or make a syscall.
//!
//! Two things make that safe without locks on the audio path:
//!
//!   * The ring buffer is wait-free single-producer / single-consumer, so the
//!     decoder and the audio thread never contend.
//!   * Settings that the audio thread owns (volume, EQ, limiter) are changed
//!     by pushing commands onto another wait-free queue, which the audio
//!     thread drains at the top of each callback. Mutating the filter
//!     coefficients directly from the UI thread would be a data race on
//!     values the audio thread reads mid-block.
//!
//! The DSP chain deliberately runs in the audio callback rather than in the
//! decoder, so a volume or EQ change is heard immediately instead of after the
//! whole buffer has drained.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Atomic = std.atomic.Value;

const api = @import("../decode/api.zig");
const decoder_mod = @import("../decode/decoder.zig");
const source_mod = @import("../decode/source.zig");
const tags_mod = @import("../meta/tags.zig");

const backend_mod = @import("../audio/backend.zig");
const Ring = @import("../audio/ring.zig").Ring;
const fmt_mod = @import("../audio/format.zig");

const Chain = @import("../dsp/chain.zig").Chain;
const Analyzer = @import("../dsp/analyzer.zig").Analyzer;
const equalizer = @import("../dsp/equalizer.zig");
const resample = @import("../dsp/resample.zig");
const tone_mod = @import("../decode/tone.zig");

const Playlist = @import("playlist.zig").Playlist;
const RepeatMode = @import("playlist.zig").RepeatMode;

pub const Error = error{
    NoOutputDevice,
    OutOfMemory,
    AlreadyStarted,
};

pub const State = enum(u8) {
    stopped,
    playing,
    paused,

    pub fn label(s: State) []const u8 {
        return switch (s) {
            .stopped => "stopped",
            .playing => "playing",
            .paused => "paused",
        };
    }
};

/// Why the engine stopped advancing, for the UI to report.
pub const TrackError = enum(u8) {
    none,
    unsupported_format,
    corrupt_stream,
    not_found,
    access_denied,
    read_failed,

    pub fn label(e: TrackError) []const u8 {
        return switch (e) {
            .none => "",
            .unsupported_format => "unsupported format",
            .corrupt_stream => "corrupt stream",
            .not_found => "file not found",
            .access_denied => "access denied",
            .read_failed => "read failed",
        };
    }
};

// ---------------------------------------------------------------------------
// Wait-free SPSC queue, used for both command passing and track markers
// ---------------------------------------------------------------------------

fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        items: [capacity]T = undefined,
        head: Atomic(usize) align(std.atomic.cache_line) = .init(0),
        tail: Atomic(usize) align(std.atomic.cache_line) = .init(0),

        /// Producer side. Returns false when full.
        pub fn push(q: *Self, item: T) bool {
            const h = q.head.load(.monotonic);
            const t = q.tail.load(.acquire);
            if (h - t >= capacity) return false;
            q.items[h & mask] = item;
            q.head.store(h + 1, .release);
            return true;
        }

        /// Consumer side.
        pub fn pop(q: *Self) ?T {
            const t = q.tail.load(.monotonic);
            const h = q.head.load(.acquire);
            if (t == h) return null;
            const item = q.items[t & mask];
            q.tail.store(t + 1, .release);
            return item;
        }

        /// Consumer side: look at the next item without removing it.
        pub fn peek(q: *Self) ?T {
            const t = q.tail.load(.monotonic);
            const h = q.head.load(.acquire);
            if (t == h) return null;
            return q.items[t & mask];
        }

        pub fn len(q: *const Self) usize {
            return q.head.load(.acquire) - q.tail.load(.acquire);
        }
    };
}

/// Settings owned by the audio thread, changed by message passing.
const AudioCommand = union(enum) {
    set_volume: f32,
    nudge_volume: f32,
    set_volume_db: f32,
    set_balance: f32,
    set_mute: bool,
    toggle_mute,
    set_eq_enabled: bool,
    set_eq_band: struct { index: u8, gain_db: f32 },
    nudge_eq_band: struct { index: u8, delta_db: f32 },
    set_eq_preset: equalizer.Preset,
    set_eq_preamp_db: f32,
    set_limiter_enabled: bool,
    set_limiter_ceiling_db: f32,
    /// ReplayGain for the track that is about to start.
    set_track_gain_db: f32,
    /// Clear filter state after a discontinuity.
    reset_dsp,
};

/// Requests that need file access, handled on the decoder thread.
const DecodeRequest = union(enum) {
    play_index: usize,
    play_current,
    next_track,
    previous_track,
    seek_to_seconds: f64,
    seek_by_seconds: f64,
    stop,
    /// The playlist changed; re-evaluate what should be playing.
    requeue,
};

/// Published by the decoder when the stream crosses into a new track or jumps
/// to a new position, so the audio thread can keep the reported position
/// honest without knowing anything about decoding.
const Marker = struct {
    /// Output frame count at which this becomes the active state.
    at_out_frame: u64,
    track_index: u32,
    /// Source position, in seconds, at that point.
    start_seconds: f64,
    /// Source format, so the UI can show it.
    sample_rate: u32,
    channels: u8,
    bits: u8,
    codec: api.Codec,
    duration_s: f64,
    has_duration: bool,
};

/// Handshake used to drain the pipeline before a seek. The ring is
/// single-producer / single-consumer, so it can only be cleared safely while
/// the consumer is parked.
const FlushState = enum(u8) { running, requested, acked };

pub const Options = struct {
    /// Audio buffered ahead of the device, in milliseconds. Larger is safer
    /// against stalls, smaller makes seeking feel snappier.
    buffer_ms: u32 = 1500,
    /// Device buffer target.
    latency_ms: u32 = 40,
    backend_kind: ?backend_mod.Kind = null,
    device_id: ?[]const u8 = null,
    /// Ask the backend for this rate. Hardware backends report whatever they
    /// actually opened; the file and null sinks honour it exactly, which is
    /// how an offline render avoids a pointless resampling pass.
    output_sample_rate: ?u32 = null,
    output_channels: ?u8 = null,
    output_path: ?[]const u8 = null,
    render_frames: u64 = 0,
    resample_quality: resample.Quality = .medium,
    /// Apply ReplayGain tags when a track carries them.
    use_replaygain: bool = true,
    /// Prefer album gain over track gain, keeping an album's relative levels.
    replaygain_album_mode: bool = false,
    /// Bands in the spectrum analyzer; 0 disables it.
    analyzer_bands: usize = 28,
    analyzer_fft_size: usize = 2048,
    initial_volume: f32 = 0.7,
    /// Where to begin the first track, in seconds. Consumed once, so a later
    /// track change still starts from the beginning.
    initial_offset_s: f64 = 0,
    /// Settings for a synthesized source, used for queue entries whose path
    /// begins with `tone://`.
    tone_spec: ?tone_mod.Spec = null,
};

/// Queue entries with this prefix are generated rather than read from disk.
pub const tone_scheme = "tone://";

pub const Status = struct {
    state: State,
    track_index: ?usize,
    position_s: f64,
    duration_s: ?f64,

    out_sample_rate: u32,
    out_channels: u8,
    src_sample_rate: u32,
    src_channels: u8,
    src_bits: u8,
    codec: ?api.Codec,

    volume: f32,
    volume_db: f32,
    muted: bool,
    balance: f32,

    eq_enabled: bool,
    eq_gains: equalizer.Gains,
    eq_preamp_db: f32,
    limiter_enabled: bool,
    gain_reduction_db: f32,

    /// How full the decode-ahead buffer is, 0..1.
    buffer_fill: f32,
    underruns: u64,
    decode_errors: u64,
    last_error: TrackError,
    resampling: bool,
    replaygain_db: f32,
};

/// Seed the shuffle PRNG from the wall clock, so repeat listens of the same
/// album do not come out in the same "random" order every session.
fn shuffleSeed(io: Io) u64 {
    const now: Io.Timestamp = .now(io, .real);
    return @bitCast(@as(i64, @truncate(now.toNanoseconds())));
}

pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    options: Options,

    /// Guards `playlist`, which both the UI and decoder threads read.
    /// The audio thread never touches it.
    playlist_mutex: Io.Mutex = .init,
    playlist: Playlist,

    backend: ?backend_mod.Backend = null,
    out_format: backend_mod.Format = .{ .sample_rate = 48_000, .channels = 2 },

    ring: Ring,
    chain: Chain,
    analyzer: ?Analyzer = null,
    resampler: resample.Resampler,

    /// Decoder-thread-owned.
    decoder: ?decoder_mod.Decoder = null,
    decode_buf: []f32 = &.{},
    resample_buf: []f32 = &.{},
    remap_buf: []f32 = &.{},

    state: Atomic(State) = .init(.stopped),
    flush: Atomic(FlushState) = .init(.running),
    quit: Atomic(bool) = .init(false),

    commands: SpscQueue(AudioCommand, 256) = .{},
    markers: SpscQueue(Marker, 32) = .{},
    requests: SpscQueue(DecodeRequest, 64) = .{},

    /// Real output frames handed to the device since the engine started.
    out_frames_consumed: Atomic(u64) = .init(0),
    /// Frames the decoder has written to the ring, in output frames.
    out_frames_produced: Atomic(u64) = .init(0),

    /// Active marker state, published by the audio thread for the UI.
    active_track: Atomic(u32) = .init(std.math.maxInt(u32)),
    active_start_frame: Atomic(u64) = .init(0),
    active_start_seconds_bits: Atomic(u64) = .init(0),
    active_rate: Atomic(u32) = .init(0),
    active_channels: Atomic(u8) = .init(0),
    active_bits: Atomic(u8) = .init(0),
    active_codec: Atomic(u8) = .init(0),
    active_has_codec: Atomic(bool) = .init(false),
    active_duration_bits: Atomic(u64) = .init(0),
    active_has_duration: Atomic(bool) = .init(false),

    underruns: Atomic(u64) = .init(0),
    decode_errors: Atomic(u64) = .init(0),
    last_error: Atomic(TrackError) = .init(.none),
    /// Set by the decoder when the queue runs out, so the UI can stop.
    reached_end: Atomic(bool) = .init(false),
    /// True while a decoder is open and feeding the ring. The audio thread
    /// uses it to tell a real underrun ("audio was due and did not arrive")
    /// from the ordinary silence of having nothing queued.
    active_stream: Atomic(bool) = .init(false),
    /// True while the queue still has audio coming. Unlike `active_stream`
    /// this stays set across a gapless hand-off, where the old decoder is
    /// closed before the new one opens; an offline sink uses it to know
    /// whether waiting for more data is worthwhile.
    queue_active: Atomic(bool) = .init(false),

    /// True when the output has no hardware clock (an offline render). Such a
    /// sink pulls as fast as the CPU allows, so it would outrun the decoder
    /// and write silence; the render callback is allowed to wait for data
    /// instead, which is safe precisely because there is no deadline to miss.
    offline: bool = false,

    /// Audio-thread-only: pause/resume ramp, to avoid a click.
    fade_gain: f32 = 0,
    fade_coef: f32 = 0,

    replaygain_db: Atomic(u32) = .init(0),

    decode_thread: ?std.Thread = null,

    /// Frames decoded per pass. A few milliseconds, so the loop reacts
    /// promptly to commands.
    const decode_block_frames: usize = 1024;
    /// Ramp length for pause and resume.
    const fade_ms: f32 = 8.0;

    pub fn init(gpa: Allocator, io: Io, options: Options) Error!*Engine {
        const self = gpa.create(Engine) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);

        // Sized once the output format is known; start with a placeholder.
        var ring = Ring.init(gpa, 1024) catch return error.OutOfMemory;
        errdefer ring.deinit(gpa);

        var chain = Chain.init(gpa, 48_000, 2) catch return error.OutOfMemory;
        errdefer chain.deinit();

        var resampler = resample.Resampler.init(gpa, 48_000, 48_000, 2, options.resample_quality) catch
            return error.OutOfMemory;
        errdefer resampler.deinit();

        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .playlist = Playlist.init(gpa, shuffleSeed(io)),
            .ring = ring,
            .chain = chain,
            .resampler = resampler,
        };
        self.chain.gain.setVolume(options.initial_volume);
        self.chain.gain.snap();
        return self;
    }

    pub fn deinit(self: *Engine) void {
        self.shutdown();

        if (self.backend) |be| be.deinit();
        if (self.decoder) |*d| d.deinit();
        if (self.analyzer) |*a| a.deinit();

        self.chain.deinit();
        self.resampler.deinit();
        self.ring.deinit(self.gpa);
        self.playlist.deinit();

        const gpa = self.gpa;
        if (self.decode_buf.len > 0) gpa.free(self.decode_buf);
        if (self.resample_buf.len > 0) gpa.free(self.resample_buf);
        if (self.remap_buf.len > 0) gpa.free(self.remap_buf);
        gpa.destroy(self);
    }

    fn shutdown(self: *Engine) void {
        self.quit.store(true, .release);
        self.state.store(.stopped, .release);
        // A parked decoder thread must not be left waiting on the flush
        // handshake, which only the audio thread can complete.
        self.flush.store(.running, .release);
        if (self.decode_thread) |t| {
            t.join();
            self.decode_thread = null;
        }
        if (self.backend) |be| be.stop();
    }

    /// Open the output device and start the decoder thread.
    pub fn start(self: *Engine) Error!void {
        if (self.backend != null) return error.AlreadyStarted;

        const be = backend_mod.open(self.gpa, self.io, .{
            .kind = self.options.backend_kind,
            .device_id = self.options.device_id,
            .latency_ms = self.options.latency_ms,
            .sample_rate = self.options.output_sample_rate,
            .channels = self.options.output_channels,
            .output_path = self.options.output_path,
            .render_frames = self.options.render_frames,
        }, renderCallback, self) catch return error.NoOutputDevice;
        errdefer be.deinit();

        self.backend = be;
        self.out_format = be.format();
        self.offline = be.kind() == .wav_file;

        try self.reconfigureForOutput();

        be.start() catch return error.NoOutputDevice;

        self.decode_thread = std.Thread.spawn(.{}, decodeLoop, .{self}) catch
            return error.OutOfMemory;
        return;
    }

    fn reconfigureForOutput(self: *Engine) Error!void {
        const rate = self.out_format.sample_rate;
        const ch = self.out_format.channels;

        // Decode-ahead buffer.
        const ring_frames = (@as(usize, rate) * self.options.buffer_ms) / 1000;
        const ring = Ring.init(self.gpa, @max(ring_frames, 4096) * ch) catch
            return error.OutOfMemory;
        self.ring.deinit(self.gpa);
        self.ring = ring;

        self.chain.reconfigure(rate, ch) catch return error.OutOfMemory;

        if (self.options.analyzer_bands > 0) {
            if (self.analyzer) |*a| a.deinit();
            self.analyzer = Analyzer.init(
                self.gpa,
                rate,
                self.options.analyzer_fft_size,
                self.options.analyzer_bands,
            ) catch return error.OutOfMemory;
            self.chain.analyzer = &self.analyzer.?;
        }

        self.resampler.deinit();
        self.resampler = resample.Resampler.init(
            self.gpa,
            rate,
            rate,
            ch,
            self.options.resample_quality,
        ) catch return error.OutOfMemory;

        // Working buffers. The resampler can produce slightly more than the
        // ratio suggests, so leave headroom.
        const gpa = self.gpa;
        if (self.decode_buf.len > 0) gpa.free(self.decode_buf);
        if (self.resample_buf.len > 0) gpa.free(self.resample_buf);
        if (self.remap_buf.len > 0) gpa.free(self.remap_buf);
        self.decode_buf = gpa.alloc(f32, decode_block_frames * 8) catch
            return error.OutOfMemory;
        self.remap_buf = gpa.alloc(f32, decode_block_frames * 8) catch
            return error.OutOfMemory;
        self.resample_buf = gpa.alloc(f32, decode_block_frames * 8 * 4) catch
            return error.OutOfMemory;

        const fade_samples = fade_ms * 0.001 * @as(f32, @floatFromInt(rate));
        self.fade_coef = if (fade_samples <= 1) 1.0 else 1.0 - std.math.exp(-5.0 / fade_samples);
        return;
    }

    // -----------------------------------------------------------------------
    // Public control surface (UI / CLI thread)
    // -----------------------------------------------------------------------

    pub fn lockPlaylist(self: *Engine) *Playlist {
        self.playlist_mutex.lockUncancelable(self.io);
        return &self.playlist;
    }

    pub fn unlockPlaylist(self: *Engine) void {
        self.playlist_mutex.unlock(self.io);
    }

    fn request(self: *Engine, req: DecodeRequest) void {
        _ = self.requests.push(req);
    }

    fn command(self: *Engine, cmd: AudioCommand) void {
        _ = self.commands.push(cmd);
    }

    pub fn play(self: *Engine) void {
        self.reached_end.store(false, .release);
        if (self.state.load(.acquire) == .stopped) {
            self.request(.play_current);
        }
        self.state.store(.playing, .release);
    }

    pub fn pause(self: *Engine) void {
        if (self.state.load(.acquire) == .playing) {
            self.state.store(.paused, .release);
        }
    }

    pub fn togglePause(self: *Engine) void {
        switch (self.state.load(.acquire)) {
            .playing => self.pause(),
            .paused, .stopped => self.play(),
        }
    }

    pub fn stop(self: *Engine) void {
        self.state.store(.stopped, .release);
        self.request(.stop);
    }

    pub fn nextTrack(self: *Engine) void {
        self.reached_end.store(false, .release);
        self.request(.next_track);
    }

    pub fn previousTrack(self: *Engine) void {
        self.reached_end.store(false, .release);
        self.request(.previous_track);
    }

    pub fn playIndex(self: *Engine, index: usize) void {
        self.reached_end.store(false, .release);
        self.request(.{ .play_index = index });
        self.state.store(.playing, .release);
    }

    pub fn seekTo(self: *Engine, seconds: f64) void {
        self.request(.{ .seek_to_seconds = seconds });
    }

    pub fn seekBy(self: *Engine, seconds: f64) void {
        self.request(.{ .seek_by_seconds = seconds });
    }

    /// Tell the engine the playlist changed under it.
    pub fn playlistChanged(self: *Engine) void {
        self.request(.requeue);
    }

    pub fn setVolume(self: *Engine, fraction: f32) void {
        self.command(.{ .set_volume = fraction });
    }
    pub fn nudgeVolume(self: *Engine, delta: f32) void {
        self.command(.{ .nudge_volume = delta });
    }
    pub fn setVolumeDb(self: *Engine, db: f32) void {
        self.command(.{ .set_volume_db = db });
    }
    pub fn setBalance(self: *Engine, b: f32) void {
        self.command(.{ .set_balance = b });
    }
    pub fn toggleMute(self: *Engine) void {
        self.command(.toggle_mute);
    }
    pub fn setEqEnabled(self: *Engine, on: bool) void {
        self.command(.{ .set_eq_enabled = on });
    }
    pub fn setEqBand(self: *Engine, index: u8, gain_db: f32) void {
        self.command(.{ .set_eq_band = .{ .index = index, .gain_db = gain_db } });
    }
    pub fn nudgeEqBand(self: *Engine, index: u8, delta_db: f32) void {
        self.command(.{ .nudge_eq_band = .{ .index = index, .delta_db = delta_db } });
    }
    pub fn setEqPreset(self: *Engine, preset: equalizer.Preset) void {
        self.command(.{ .set_eq_preset = preset });
    }
    pub fn setEqPreampDb(self: *Engine, db: f32) void {
        self.command(.{ .set_eq_preamp_db = db });
    }
    pub fn setLimiterEnabled(self: *Engine, on: bool) void {
        self.command(.{ .set_limiter_enabled = on });
    }
    pub fn setLimiterCeilingDb(self: *Engine, db: f32) void {
        self.command(.{ .set_limiter_ceiling_db = db });
    }

    /// True once the queue has been played to the end.
    pub fn finished(self: *const Engine) bool {
        return self.reached_end.load(.acquire);
    }

    /// Everything the UI needs for one frame, read without locking.
    pub fn status(self: *Engine) Status {
        const consumed = self.out_frames_consumed.load(.acquire);
        const start_frame = self.active_start_frame.load(.acquire);
        const start_seconds: f64 = @bitCast(self.active_start_seconds_bits.load(.acquire));
        const rate = self.out_format.sample_rate;

        const elapsed: f64 = if (consumed > start_frame)
            @as(f64, @floatFromInt(consumed - start_frame)) / @as(f64, @floatFromInt(rate))
        else
            0;

        const track_raw = self.active_track.load(.acquire);
        const duration: ?f64 = if (self.active_has_duration.load(.acquire))
            @bitCast(self.active_duration_bits.load(.acquire))
        else
            null;

        var position = start_seconds + elapsed;
        if (duration) |d| position = @min(position, d);

        const src_rate = self.active_rate.load(.acquire);

        return .{
            .state = self.state.load(.acquire),
            .track_index = if (track_raw == std.math.maxInt(u32)) null else track_raw,
            .position_s = position,
            .duration_s = duration,
            .out_sample_rate = rate,
            .out_channels = self.out_format.channels,
            .src_sample_rate = src_rate,
            .src_channels = self.active_channels.load(.acquire),
            .src_bits = self.active_bits.load(.acquire),
            .codec = if (self.active_has_codec.load(.acquire))
                @enumFromInt(self.active_codec.load(.acquire))
            else
                null,
            .volume = self.chain.gain.volume(),
            .volume_db = self.chain.gain.volumeDb(),
            .muted = self.chain.gain.muted,
            .balance = self.chain.gain.balance,
            .eq_enabled = self.chain.eq.enabled,
            .eq_gains = self.chain.eq.gains_db,
            .eq_preamp_db = self.chain.eq.preamp_db,
            .limiter_enabled = self.chain.limiter.enabled,
            .gain_reduction_db = 0,
            .buffer_fill = blk: {
                const cap = self.ring.capacity();
                if (cap == 0) break :blk 0;
                break :blk @as(f32, @floatFromInt(self.ring.readable())) /
                    @as(f32, @floatFromInt(cap));
            },
            .underruns = self.underruns.load(.monotonic),
            .decode_errors = self.decode_errors.load(.monotonic),
            .last_error = self.last_error.load(.monotonic),
            .resampling = src_rate != 0 and src_rate != rate,
            .replaygain_db = @bitCast(self.replaygain_db.load(.monotonic)),
        };
    }

    /// Frames the output has handed to the device or file so far.
    pub fn outputFramesWritten(self: *const Engine) u64 {
        if (self.backend) |be| return be.framesWritten();
        return 0;
    }

    /// Real output frames the engine has actually fed to the output, as
    /// opposed to silence padding.
    pub fn renderedFrames(self: *const Engine) u64 {
        return self.out_frames_consumed.load(.acquire);
    }

    pub fn backendDescription(self: *const Engine) []const u8 {
        if (self.backend) |be| return be.describe();
        return "no output";
    }

    pub fn analyzerPtr(self: *Engine) ?*Analyzer {
        if (self.analyzer) |*a| return a;
        return null;
    }

    // -----------------------------------------------------------------------
    // Audio thread
    // -----------------------------------------------------------------------

    fn renderCallback(userdata: ?*anyopaque, out: []f32, channels: u8) void {
        const self: *Engine = @ptrCast(@alignCast(userdata.?));
        self.render(out, channels);
    }

    fn render(self: *Engine, out: []f32, channels: u8) void {
        self.drainCommands();

        // Seek handshake: acknowledge and go quiet so the decoder can safely
        // reset the ring.
        //
        // A real-time sink has to return immediately — the device needs its
        // buffer now — so it emits silence for the duration of the flush. An
        // offline sink must instead wait: it pulls as fast as memory allows,
        // so returning silence here would write hundreds of thousands of
        // empty frames into the file (and, since its output length is fixed,
        // could consume the entire render before any audio was decoded).
        switch (self.flush.load(.acquire)) {
            .requested => {
                self.flush.store(.acked, .release);
                self.fade_gain = 0;
                if (!self.offline or !self.waitForFlush()) {
                    @memset(out, 0);
                    return;
                }
            },
            .acked => {
                if (!self.offline or !self.waitForFlush()) {
                    @memset(out, 0);
                    return;
                }
            },
            .running => {},
        }

        const state = self.state.load(.acquire);
        const playing = state == .playing;

        // Fully faded out and not playing: emit silence without touching the
        // ring, so a paused stream keeps its place.
        if (!playing and self.fade_gain < 1e-4) {
            @memset(out, 0);
            self.fade_gain = 0;
            return;
        }

        // An offline sink has no deadline, so rather than recording an
        // underrun and emitting silence it waits for the decoder to catch up.
        if (self.offline and playing) {
            var waited: u32 = 0;
            while (self.ring.readable() < out.len) {
                if (self.quit.load(.acquire)) break;
                if (self.state.load(.acquire) != .playing) break;
                // The queue is finished for good.
                if (self.reached_end.load(.acquire)) break;
                // Nothing more is coming but something is buffered: take the
                // final partial block instead of waiting for a full one.
                if (!self.queue_active.load(.acquire) and self.ring.readable() > 0) break;
                // Note that `queue_active` is also false before the first
                // track has been opened, which is exactly when the sink must
                // wait rather than race ahead writing silence.
                if (waited > 10_000) break; // 10 s, in case the decoder wedged
                waited += 1;
                self.io.sleep(.fromMilliseconds(1), .awake) catch break;
            }
        }

        const got = self.ring.read(out);
        if (got < out.len) {
            @memset(out[got..], 0);
            if (playing and self.active_stream.load(.acquire) and !self.offline) {
                _ = self.underruns.fetchAdd(1, .monotonic);
            }
        }

        // Pause and resume ramp. A hard cut is a step discontinuity in the
        // waveform, which is audible as a click. There is no speaker behind an
        // offline render, so it skips the ramp and stays sample-exact.
        const target: f32 = if (playing) 1.0 else 0.0;
        if (self.offline) {
            self.fade_gain = target;
            if (target == 0.0) @memset(out, 0);
        } else {
            const frames = out.len / channels;
            var f: usize = 0;
            while (f < frames) : (f += 1) {
                self.fade_gain += (target - self.fade_gain) * self.fade_coef;
                const g = self.fade_gain;
                for (out[f * channels ..][0..channels]) |*s| s.* *= g;
            }
        }

        self.chain.process(out, channels);

        const real_frames = got / channels;
        if (real_frames > 0) {
            const consumed = self.out_frames_consumed.fetchAdd(real_frames, .monotonic) +
                real_frames;
            self.advanceMarkers(consumed);
        }
    }

    /// Offline sinks only: block until the decoder has finished flushing the
    /// pipeline. Returns false if it gave up, in which case the caller should
    /// emit silence for this block.
    fn waitForFlush(self: *Engine) bool {
        var waited: u32 = 0;
        while (self.flush.load(.acquire) != .running) {
            if (self.quit.load(.acquire)) return false;
            if (waited > 5_000) return false; // 5 s
            waited += 1;
            self.io.sleep(.fromMilliseconds(1), .awake) catch return false;
        }
        return true;
    }

    fn advanceMarkers(self: *Engine, consumed: u64) void {
        while (self.markers.peek()) |m| {
            if (m.at_out_frame > consumed) break;
            _ = self.markers.pop();
            self.active_track.store(m.track_index, .release);
            self.active_start_frame.store(m.at_out_frame, .release);
            self.active_start_seconds_bits.store(@bitCast(m.start_seconds), .release);
            self.active_rate.store(m.sample_rate, .release);
            self.active_channels.store(m.channels, .release);
            self.active_bits.store(m.bits, .release);
            self.active_codec.store(@intFromEnum(m.codec), .release);
            self.active_has_codec.store(true, .release);
            self.active_duration_bits.store(@bitCast(m.duration_s), .release);
            self.active_has_duration.store(m.has_duration, .release);
        }
    }

    fn drainCommands(self: *Engine) void {
        while (self.commands.pop()) |cmd| switch (cmd) {
            .set_volume => |v| self.chain.gain.setVolume(v),
            .nudge_volume => |d| self.chain.gain.nudgeVolume(d),
            .set_volume_db => |db| self.chain.gain.setVolumeDb(db),
            .set_balance => |b| self.chain.gain.setBalance(b),
            .set_mute => |m| self.chain.gain.muted = m,
            .toggle_mute => self.chain.gain.toggleMute(),
            .set_eq_enabled => |on| self.chain.eq.enabled = on,
            .set_eq_band => |b| self.chain.eq.setBand(b.index, b.gain_db),
            .nudge_eq_band => |b| self.chain.eq.nudgeBand(b.index, b.delta_db),
            .set_eq_preset => |p| self.chain.eq.setPreset(p),
            .set_eq_preamp_db => |db| self.chain.eq.setPreampDb(db),
            .set_limiter_enabled => |on| self.chain.limiter.enabled = on,
            .set_limiter_ceiling_db => |db| self.chain.limiter.setCeilingDb(db),
            .set_track_gain_db => |db| {
                // ReplayGain rides on the limiter-protected output stage, so
                // an aggressive positive gain cannot clip.
                self.replaygain_db.store(@bitCast(db), .monotonic);
            },
            .reset_dsp => self.chain.reset(),
        };
    }

    // -----------------------------------------------------------------------
    // Decoder thread
    // -----------------------------------------------------------------------

    fn decodeLoop(self: *Engine) void {
        while (!self.quit.load(.acquire)) {
            var did_work = false;

            while (self.requests.pop()) |req| {
                self.handleRequest(req);
                did_work = true;
            }

            if (self.state.load(.acquire) == .playing and self.decoder != null) {
                did_work = self.fillRing() or did_work;
            }

            if (!did_work) {
                // Nothing to do: idle briefly. The ring holds enough audio
                // that this latency is invisible.
                self.io.sleep(.fromMilliseconds(4), .awake) catch break;
            }
        }
    }

    fn handleRequest(self: *Engine, req: DecodeRequest) void {
        switch (req) {
            .stop => {
                self.closeDecoder();
                self.flushPipeline();
                self.state.store(.stopped, .release);
            },
            .play_current => {
                if (self.decoder == null) {
                    const index = blk: {
                        const pl = self.lockPlaylist();
                        defer self.unlockPlaylist();
                        break :blk pl.currentIndex() orelse pl.start();
                    };
                    if (index) |i| {
                        const offset = self.options.initial_offset_s;
                        self.options.initial_offset_s = 0;
                        self.startTrack(i, offset, true);
                    } else {
                        self.state.store(.stopped, .release);
                    }
                }
            },
            .play_index => |i| {
                const ok = blk: {
                    const pl = self.lockPlaylist();
                    defer self.unlockPlaylist();
                    break :blk pl.jumpTo(i) != null;
                };
                if (ok) self.startTrack(i, 0, true);
            },
            .next_track => {
                const index = blk: {
                    const pl = self.lockPlaylist();
                    defer self.unlockPlaylist();
                    break :blk pl.skipForward();
                };
                if (index) |i| {
                    self.startTrack(i, 0, true);
                } else {
                    self.endOfQueue();
                }
            },
            .previous_track => {
                // Pressing "previous" near the start of a track goes to the
                // previous track; later in a track it restarts the current
                // one, which is what every other player does.
                const status_now = self.status();
                if (status_now.position_s > 3.0) {
                    if (status_now.track_index) |i| {
                        self.startTrack(i, 0, true);
                        return;
                    }
                }
                const index = blk: {
                    const pl = self.lockPlaylist();
                    defer self.unlockPlaylist();
                    break :blk pl.previous();
                };
                if (index) |i| self.startTrack(i, 0, true);
            },
            .seek_to_seconds => |target| self.performSeek(target),
            .seek_by_seconds => |delta| {
                const now = self.status().position_s;
                self.performSeek(now + delta);
            },
            .requeue => {
                // If what was playing has gone, move to whatever is current.
                const index = blk: {
                    const pl = self.lockPlaylist();
                    defer self.unlockPlaylist();
                    break :blk pl.currentIndex();
                };
                if (index == null) {
                    self.closeDecoder();
                    self.flushPipeline();
                    self.state.store(.stopped, .release);
                }
            },
        }
    }

    fn performSeek(self: *Engine, target_seconds: f64) void {
        var dec = &(self.decoder orelse return);
        const info = dec.info();
        if (!info.seekable) return;

        var seconds = @max(target_seconds, 0);
        if (info.durationSeconds()) |d| seconds = @min(seconds, @max(d - 0.05, 0));

        const frame = @as(u64, @intFromFloat(
            seconds * @as(f64, @floatFromInt(info.sample_rate)),
        ));
        dec.seekToFrame(frame) catch {
            dec.seekToFrame(0) catch return;
            seconds = 0;
        };

        const track = blk: {
            const pl = self.lockPlaylist();
            defer self.unlockPlaylist();
            break :blk pl.currentIndex() orelse 0;
        };

        self.flushPipeline();
        self.resampler.reset();
        _ = self.commands.push(.reset_dsp);
        self.publishMarker(track, seconds, info, true);
    }

    /// Park the audio thread, empty the ring, and reset the frame counters so
    /// position reporting restarts cleanly.
    fn flushPipeline(self: *Engine) void {
        // With no backend running there is no consumer to coordinate with.
        if (self.backend == null) {
            self.ring.clear();
            return;
        }

        self.flush.store(.requested, .release);
        // Wait for the audio thread to confirm it has stopped reading. If it
        // never does (device stalled, or we are shutting down), give up after
        // a bounded wait rather than deadlocking.
        var spins: u32 = 0;
        while (self.flush.load(.acquire) != .acked) {
            if (self.quit.load(.acquire)) break;
            if (spins > 400) break; // ~400 ms
            spins += 1;
            self.io.sleep(.fromMilliseconds(1), .awake) catch break;
        }

        self.ring.clear();
        const consumed = self.out_frames_consumed.load(.acquire);
        self.out_frames_produced.store(consumed, .release);
        while (self.markers.pop()) |_| {}

        self.flush.store(.running, .release);
    }

    fn closeDecoder(self: *Engine) void {
        self.active_stream.store(false, .release);
        if (self.decoder) |*d| {
            d.deinit();
            self.decoder = null;
        }
    }

    fn endOfQueue(self: *Engine) void {
        self.queue_active.store(false, .release);
        self.closeDecoder();
        self.flushPipeline();
        self.state.store(.stopped, .release);
        self.reached_end.store(true, .release);
    }

    /// Open `index` and begin decoding it. `flush_first` is false for a
    /// gapless hand-off, where the previous track's audio must stay in the
    /// ring and keep playing.
    fn startTrack(self: *Engine, index: usize, start_seconds: f64, flush_first: bool) void {
        self.closeDecoder();

        // The playlist arena owns the path string and the UI thread can
        // reallocate the track list, so copy what we need while still holding
        // the lock rather than keeping a borrowed slice.
        var path_buf: [4096]u8 = undefined;
        var path_len: usize = 0;
        var queued_duration: f64 = 0;
        {
            const pl = self.lockPlaylist();
            defer self.unlockPlaylist();
            const t = pl.at(index) orelse {
                self.endOfQueue();
                return;
            };
            if (t.path.len >= path_buf.len) {
                self.noteError(.read_failed);
                return;
            }
            @memcpy(path_buf[0..t.path.len], t.path);
            path_len = t.path.len;
            queued_duration = t.duration_s orelse 0;
        }
        const path_copy = path_buf[0..path_len];

        var dec = if (std.mem.startsWith(u8, path_copy, tone_scheme)) blk: {
            // A synthesized source has no file behind it; it is queued under a
            // pseudo-path and generated at the output's own format so nothing
            // has to be resampled.
            var spec = self.options.tone_spec orelse tone_mod.Spec{};
            spec.sample_rate = self.out_format.sample_rate;
            spec.channels = self.out_format.channels;
            const seconds = if (queued_duration > 0) queued_duration else 10.0;
            spec.frames = @intFromFloat(seconds * @as(f64, @floatFromInt(spec.sample_rate)));
            break :blk decoder_mod.Decoder.openTone(spec);
        } else decoder_mod.Decoder.openFile(self.gpa, self.io, path_copy) catch |err| {
            self.noteError(switch (err) {
                error.UnsupportedFormat => .unsupported_format,
                error.CorruptStream => .corrupt_stream,
                error.FileNotFound => .not_found,
                error.AccessDenied => .access_denied,
                else => .read_failed,
            });
            // A bad file should not stop the queue; move on.
            self.skipAfterFailure(index);
            return;
        };

        const info = dec.info();
        if (info.channels == 0 or info.sample_rate == 0) {
            dec.deinit();
            self.noteError(.corrupt_stream);
            self.skipAfterFailure(index);
            return;
        }

        if (start_seconds > 0) {
            const frame: u64 = @intFromFloat(
                start_seconds * @as(f64, @floatFromInt(info.sample_rate)),
            );
            dec.seekToFrame(frame) catch {};
        }

        // Fold the file's tags into the queue entry.
        var tags: tags_mod.Tags = if (dec.tagBlock()) |block| tags_mod.parse(self.gpa, switch (block) {
            .id3 => |b| .{ .id3 = b },
            .vorbis_comment => |b| .{ .vorbis_comment = b },
            .riff_info => |b| .{ .riff_info = b },
        }) else tags_mod.Tags.init(self.gpa);
        defer tags.deinit();
        {
            const pl = self.lockPlaylist();
            defer self.unlockPlaylist();
            pl.updateMetadata(index, info, &tags) catch {};
        }

        const gain_db: f32 = if (self.options.use_replaygain)
            tags.replayGainDb(self.options.replaygain_album_mode) orelse 0
        else
            0;

        self.decoder = dec;
        self.active_stream.store(true, .release);
        self.queue_active.store(true, .release);

        if (flush_first) {
            self.flushPipeline();
            _ = self.commands.push(.reset_dsp);
        }

        self.configureResampler(info);
        _ = self.commands.push(.{ .set_track_gain_db = gain_db });
        self.applyTrackGain(gain_db);
        self.publishMarker(index, start_seconds, info, flush_first);
    }

    /// Move past a track that could not be opened, stopping if nothing is left.
    fn skipAfterFailure(self: *Engine, failed_index: usize) void {
        _ = failed_index;
        const next = blk: {
            const pl = self.lockPlaylist();
            defer self.unlockPlaylist();
            break :blk pl.skipForward();
        };
        if (next) |n| {
            // Guard against a queue of entirely unreadable files spinning
            // forever: the error counter grows and the UI can show it.
            if (self.decode_errors.load(.monotonic) < 1000) {
                self.startTrack(n, 0, true);
                return;
            }
        }
        self.endOfQueue();
    }

    fn noteError(self: *Engine, e: TrackError) void {
        self.last_error.store(e, .monotonic);
        _ = self.decode_errors.fetchAdd(1, .monotonic);
    }

    /// ReplayGain is applied as a volume trim rather than baked into the
    /// decode, so toggling it does not require re-reading the file.
    fn applyTrackGain(self: *Engine, gain_db: f32) void {
        self.replaygain_db.store(@bitCast(gain_db), .monotonic);
    }

    fn configureResampler(self: *Engine, info: api.Info) void {
        const out_rate = self.out_format.sample_rate;
        const out_ch = self.out_format.channels;
        // The resampler works in the output channel layout, so remapping
        // happens first and the filter only ever sees `out_ch` channels.
        if (self.resampler.channels != out_ch) {
            self.resampler.deinit();
            self.resampler = resample.Resampler.init(
                self.gpa,
                info.sample_rate,
                out_rate,
                out_ch,
                self.options.resample_quality,
            ) catch {
                self.noteError(.read_failed);
                return;
            };
        } else {
            self.resampler.configure(info.sample_rate, out_rate);
        }
    }

    fn publishMarker(
        self: *Engine,
        index: usize,
        start_seconds: f64,
        info: api.Info,
        immediate: bool,
    ) void {
        const at: u64 = if (immediate)
            self.out_frames_consumed.load(.acquire)
        else
            self.out_frames_produced.load(.acquire);

        const marker: Marker = .{
            .at_out_frame = at,
            .track_index = @intCast(index),
            .start_seconds = start_seconds,
            .sample_rate = info.sample_rate,
            .channels = info.channels,
            .bits = info.bits_per_sample,
            .codec = info.codec,
            .duration_s = info.durationSeconds() orelse 0,
            .has_duration = info.total_frames != null,
        };

        if (!self.markers.push(marker)) {
            // Marker queue full (many very short tracks in a row): apply it
            // directly so the UI does not fall behind.
            self.active_track.store(marker.track_index, .release);
            self.active_start_frame.store(at, .release);
            self.active_start_seconds_bits.store(@bitCast(start_seconds), .release);
            self.active_rate.store(info.sample_rate, .release);
            self.active_channels.store(info.channels, .release);
            self.active_bits.store(info.bits_per_sample, .release);
            self.active_codec.store(@intFromEnum(info.codec), .release);
            self.active_has_codec.store(true, .release);
            self.active_duration_bits.store(@bitCast(marker.duration_s), .release);
            self.active_has_duration.store(marker.has_duration, .release);
        }
    }

    /// Decode, convert and push one block. Returns true if anything moved.
    fn fillRing(self: *Engine) bool {
        const out_ch: usize = self.out_format.channels;
        const need = decode_block_frames * out_ch;
        if (self.ring.writable() < need) return false;

        var dec = &(self.decoder orelse return false);
        const info = dec.info();
        const src_ch: usize = info.channels;

        const frames_wanted = decode_block_frames;
        const decoded = dec.readFrames(self.decode_buf[0 .. frames_wanted * src_ch]) catch |err| {
            self.noteError(switch (err) {
                error.CorruptStream => .corrupt_stream,
                error.UnsupportedFormat => .unsupported_format,
                else => .read_failed,
            });
            self.advanceAfterTrackEnd();
            return true;
        };

        if (decoded == 0) {
            self.advanceAfterTrackEnd();
            return true;
        }

        // Channel layout first, then rate.
        const mapped: []const f32 = if (src_ch == out_ch)
            self.decode_buf[0 .. decoded * src_ch]
        else blk: {
            fmt_mod.remapChannels(
                self.decode_buf[0 .. decoded * src_ch],
                @intCast(src_ch),
                self.remap_buf,
                @intCast(out_ch),
                decoded,
            );
            break :blk self.remap_buf[0 .. decoded * out_ch];
        };

        if (self.resampler.bypass) {
            self.pushToRing(mapped);
            return true;
        }

        var consumed: usize = 0;
        while (consumed < decoded) {
            const res = self.resampler.process(
                mapped[consumed * out_ch ..],
                self.resample_buf,
            );
            if (res.produced > 0) {
                self.pushToRing(self.resample_buf[0 .. res.produced * out_ch]);
            }
            if (res.consumed == 0 and res.produced == 0) break;
            consumed += res.consumed;
        }
        return true;
    }

    fn pushToRing(self: *Engine, samples: []const f32) void {
        var written: usize = 0;
        while (written < samples.len) {
            const n = self.ring.write(samples[written..]);
            if (n == 0) {
                // The ring filled mid-block. Wait for the audio thread rather
                // than dropping audio.
                if (self.quit.load(.acquire)) return;
                if (self.state.load(.acquire) != .playing) return;
                self.io.sleep(.fromMilliseconds(2), .awake) catch return;
                continue;
            }
            written += n;
        }
        const frames = samples.len / self.out_format.channels;
        _ = self.out_frames_produced.fetchAdd(frames, .monotonic);
    }

    /// The current file ran out. Hand over to the next track without
    /// flushing, which is what makes playback gapless.
    fn advanceAfterTrackEnd(self: *Engine) void {
        const next = blk: {
            const pl = self.lockPlaylist();
            defer self.unlockPlaylist();
            break :blk pl.next();
        };
        if (next) |i| {
            // No flush: the ring still holds the tail of the previous track,
            // and the marker takes effect only once the audio thread reaches
            // the hand-off point.
            self.startTrack(i, 0, false);
        } else {
            self.drainAndStop();
        }
    }

    /// Let the ring empty out before declaring the queue finished, so the last
    /// second of the final track is actually heard.
    fn drainAndStop(self: *Engine) void {
        self.closeDecoder();
        // Nothing more is coming, which releases an offline sink from waiting
        // for a full block.
        self.queue_active.store(false, .release);

        // Let the output consume what is still buffered before reporting the
        // end; otherwise the last second of the final track is never heard,
        // and for a render it never reaches the file.
        var spins: u32 = 0;
        var last_written: u64 = 0;
        var stalled: u32 = 0;
        while (!self.ring.isEmpty() and !self.quit.load(.acquire)) {
            if (self.state.load(.acquire) != .playing) break;
            if (spins > 2000) break; // 10 s ceiling
            spins += 1;

            // Give up early if the output has stopped consuming, so a sink
            // that hit its own frame limit cannot stall us.
            if (self.backend) |be| {
                const written = be.framesWritten();
                if (written == last_written) {
                    stalled += 1;
                    if (stalled > 40) break; // ~200 ms of no progress
                } else {
                    stalled = 0;
                    last_written = written;
                }
            }
            self.io.sleep(.fromMilliseconds(5), .awake) catch break;
        }
        self.state.store(.stopped, .release);
        self.reached_end.store(true, .release);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const wav_mod = @import("../decode/wav.zig");

/// Write a sine wav into `dir` and return the path, caller frees.
fn writeTestWav(
    gpa: Allocator,
    io: Io,
    sub_path: []const u8,
    seconds: f64,
    freq: f64,
    rate: u32,
) ![]u8 {
    const frames: usize = @intFromFloat(seconds * @as(f64, @floatFromInt(rate)));
    const samples = try gpa.alloc(f32, frames * 2);
    defer gpa.free(samples);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        const v: f32 = @floatCast(0.5 * @sin(2.0 * std.math.pi * freq * t));
        samples[i * 2] = v;
        samples[i * 2 + 1] = v;
    }
    const pcm = try gpa.alloc(u8, samples.len * 2);
    defer gpa.free(pcm);
    _ = fmt_mod.encodeFromFloat(.i16_pcm, samples, pcm);

    const bytes = try wav_mod.buildWav(gpa, .i16_pcm, .{
        .sample_rate = rate,
        .channels = 2,
    }, pcm);
    defer gpa.free(bytes);

    const file = try Io.Dir.cwd().createFile(io, sub_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);

    return gpa.dupe(u8, sub_path);
}

test "SPSC queue basics" {
    var q: SpscQueue(u32, 4) = .{};
    try testing.expect(q.pop() == null);
    try testing.expect(q.push(1));
    try testing.expect(q.push(2));
    try testing.expectEqual(@as(usize, 2), q.len());
    try testing.expectEqual(@as(u32, 1), q.peek().?);
    try testing.expectEqual(@as(u32, 1), q.pop().?);
    try testing.expectEqual(@as(u32, 2), q.pop().?);
    try testing.expect(q.pop() == null);

    // Fills up and refuses rather than overwriting.
    for (0..4) |i| try testing.expect(q.push(@intCast(i)));
    try testing.expect(!q.push(99));
    try testing.expectEqual(@as(u32, 0), q.pop().?);
    try testing.expect(q.push(99));
}

test "engine plays a queue through the null sink and reports position" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    const a_path = try std.fmt.allocPrint(gpa, "{s}/a.wav", .{dir});
    defer gpa.free(a_path);
    const b_path = try std.fmt.allocPrint(gpa, "{s}/b.wav", .{dir});
    defer gpa.free(b_path);
    gpa.free(try writeTestWav(gpa, io, a_path, 0.4, 440, 44_100));
    gpa.free(try writeTestWav(gpa, io, b_path, 0.4, 880, 44_100));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 200,
        .latency_ms = 10,
        .analyzer_bands = 16,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(a_path);
        _ = try pl.append(b_path);
    }

    try engine.start();
    engine.play();

    // Wait for playback to get going.
    var waited: u32 = 0;
    while (engine.status().track_index == null and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const started = engine.status();
    try testing.expectEqual(State.playing, started.state);
    try testing.expectEqual(@as(?usize, 0), started.track_index);
    try testing.expectEqual(@as(u32, 44_100), started.src_sample_rate);
    try testing.expect(started.duration_s != null);
    try testing.expectApproxEqAbs(@as(f64, 0.4), started.duration_s.?, 0.01);

    // Position should advance.
    const p1 = engine.status().position_s;
    try io.sleep(.fromMilliseconds(120), .awake);
    const p2 = engine.status().position_s;
    try testing.expect(p2 > p1);

    // And it should roll into the second track and then finish.
    waited = 0;
    while (!engine.finished() and waited < 400) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(engine.finished());
    try testing.expectEqual(@as(u64, 0), engine.status().decode_errors);
}

test "pause stops the clock and resume continues" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/long.wav", .{dir});
    defer gpa.free(path);
    gpa.free(try writeTestWav(gpa, io, path, 5.0, 440, 44_100));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 150,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(path);
    }
    try engine.start();
    engine.play();

    var waited: u32 = 0;
    while (engine.status().position_s < 0.05 and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(engine.status().position_s > 0.0);

    engine.pause();
    try io.sleep(.fromMilliseconds(60), .awake);
    try testing.expectEqual(State.paused, engine.status().state);
    const held = engine.status().position_s;
    try io.sleep(.fromMilliseconds(150), .awake);
    // Allow for the few milliseconds consumed by the fade-out ramp.
    try testing.expectApproxEqAbs(held, engine.status().position_s, 0.05);

    engine.play();
    try io.sleep(.fromMilliseconds(150), .awake);
    try testing.expectEqual(State.playing, engine.status().state);
    try testing.expect(engine.status().position_s > held);
}

test "seeking moves the reported position" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/long.wav", .{dir});
    defer gpa.free(path);
    gpa.free(try writeTestWav(gpa, io, path, 10.0, 440, 44_100));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 150,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(path);
    }
    try engine.start();
    engine.play();

    var waited: u32 = 0;
    while (engine.status().track_index == null and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }

    engine.seekTo(6.0);
    waited = 0;
    while (engine.status().position_s < 5.5 and waited < 300) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const after = engine.status().position_s;
    try testing.expect(after >= 5.9);
    try testing.expect(after < 8.0);

    // Seeking backwards works too.
    engine.seekTo(1.0);
    waited = 0;
    while (engine.status().position_s > 3.0 and waited < 300) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(engine.status().position_s < 3.0);
}

test "a broken file is skipped rather than stopping the queue" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);

    const bad_path = try std.fmt.allocPrint(gpa, "{s}/bad.wav", .{dir});
    defer gpa.free(bad_path);
    const bad = try Io.Dir.cwd().createFile(io, bad_path, .{ .truncate = true });
    try bad.writeStreamingAll(io, "this is definitely not audio data");
    bad.close(io);

    const good_path = try std.fmt.allocPrint(gpa, "{s}/good.wav", .{dir});
    defer gpa.free(good_path);
    gpa.free(try writeTestWav(gpa, io, good_path, 0.3, 440, 44_100));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 150,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(bad_path);
        _ = try pl.append(good_path);
    }
    try engine.start();
    engine.play();

    // It should land on the good file, with the failure recorded.
    var waited: u32 = 0;
    while (engine.status().track_index != 1 and waited < 300) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const st = engine.status();
    try testing.expectEqual(@as(?usize, 1), st.track_index);
    try testing.expect(st.decode_errors >= 1);
    try testing.expectEqual(TrackError.unsupported_format, st.last_error);
}

test "volume and EQ commands reach the audio thread" {
    const gpa = testing.allocator;
    const io = testing.io;

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 100,
        .latency_ms = 10,
        .analyzer_bands = 0,
        .initial_volume = 0.5,
    });
    defer engine.deinit();
    try engine.start();

    engine.setVolume(0.25);
    engine.setEqEnabled(true);
    engine.setEqPreset(.rock);
    engine.setEqBand(3, 6.0);
    engine.toggleMute();

    // The audio thread drains commands once per callback.
    var waited: u32 = 0;
    while (waited < 100) : (waited += 1) {
        const st = engine.status();
        if (st.muted and st.eq_enabled and @abs(st.volume - 0.25) < 0.01) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const st = engine.status();
    try testing.expectApproxEqAbs(@as(f32, 0.25), st.volume, 0.01);
    try testing.expect(st.eq_enabled);
    try testing.expect(st.muted);
    try testing.expectApproxEqAbs(@as(f32, 6.0), st.eq_gains[3], 0.01);
}

test "a resampled track reports that it is being converted" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/r22.wav", .{dir});
    defer gpa.free(path);
    // 22.05 kHz source against a 48 kHz output.
    gpa.free(try writeTestWav(gpa, io, path, 0.5, 440, 22_050));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 200,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(path);
    }
    try engine.start();
    engine.play();

    var waited: u32 = 0;
    while (engine.status().src_sample_rate == 0 and waited < 300) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const st = engine.status();
    try testing.expectEqual(@as(u32, 22_050), st.src_sample_rate);
    try testing.expectEqual(@as(u32, 48_000), st.out_sample_rate);
    try testing.expect(st.resampling);

    // And it still reaches the end.
    waited = 0;
    while (!engine.finished() and waited < 400) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(engine.finished());
}

test "stop resets to a clean state" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/x.wav", .{dir});
    defer gpa.free(path);
    gpa.free(try writeTestWav(gpa, io, path, 3.0, 440, 44_100));

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 150,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append(path);
    }
    try engine.start();
    engine.play();

    var waited: u32 = 0;
    while (engine.status().position_s < 0.05 and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }

    engine.stop();
    waited = 0;
    while (engine.status().state != .stopped and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(State.stopped, engine.status().state);
}

test "an engine with an empty queue starts and stops without incident" {
    const gpa = testing.allocator;
    const io = testing.io;

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .buffer_ms = 100,
        .latency_ms = 10,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    try engine.start();
    engine.play();
    engine.nextTrack();
    engine.previousTrack();
    engine.seekTo(10);
    try io.sleep(.fromMilliseconds(60), .awake);
    const st = engine.status();
    try testing.expect(st.track_index == null);
    try testing.expectEqual(@as(u64, 0), st.underruns);
}

test "starting twice is refused" {
    const gpa = testing.allocator;
    const engine = try Engine.init(gpa, testing.io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    try engine.start();
    try testing.expectError(error.AlreadyStarted, engine.start());
}
