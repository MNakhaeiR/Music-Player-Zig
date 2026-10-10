//! Command-line parsing.
//!
//! Kept separate from `main` so the whole option surface is testable without
//! spawning a process or touching a device.

const std = @import("std");
const Allocator = std.mem.Allocator;

const backend = @import("audio/backend.zig");
const equalizer = @import("dsp/equalizer.zig");
const resample = @import("dsp/resample.zig");
const playlist_mod = @import("player/playlist.zig");
const theme_mod = @import("ui/theme.zig");
const tone = @import("decode/tone.zig");

pub const version = @import("build_options").version;

pub const Error = error{
    /// An option was not recognized.
    UnknownOption,
    /// An option that takes a value did not get one.
    MissingValue,
    /// A value could not be parsed, or was out of range.
    BadValue,
    OutOfMemory,
};

/// What the program should actually do.
pub const Action = enum {
    /// Normal interactive playback.
    play,
    /// Print stream information for each input.
    probe,
    /// Write decoded f32 PCM to stdout.
    raw,
    /// Decode, then verify that seeking returns identical samples.
    verify_seek,
    /// List audio output devices.
    list_devices,
    /// Render one frame of the interface to stdout, for inspecting the layout
    /// without an interactive terminal.
    dump_ui,
    /// Print usage.
    help,
    /// Print the version.
    show_version,
};

pub const Config = struct {
    action: Action = .play,

    /// Files, directories and playlists named on the command line. Borrowed
    /// from the argument array, which lives for the whole process.
    inputs: []const []const u8 = &.{},

    // playback
    shuffle: bool = false,
    repeat: playlist_mod.RepeatMode = .off,
    volume: f32 = 0.7,
    start_at: f64 = 0,
    /// Exit when the queue finishes instead of idling.
    exit_at_end: bool = true,

    // output
    backend_kind: ?backend.Kind = null,
    device_id: ?[]const u8 = null,
    latency_ms: u32 = 40,
    buffer_ms: u32 = 1500,
    resample_quality: resample.Quality = .medium,
    render_path: ?[]const u8 = null,

    // processing
    eq_preset: ?equalizer.Preset = null,
    eq_bands: ?equalizer.Gains = null,
    eq_enabled: bool = false,
    limiter: bool = true,
    ceiling_db: f32 = -0.2,
    replaygain: bool = true,
    replaygain_album: bool = false,

    // synthesized input
    tone_shape: ?tone.Shape = null,
    tone_seconds: f64 = 10,

    // interface
    use_ui: bool = true,
    theme: theme_mod.Kind = .dark,
    load_metadata: bool = true,
    analyzer_bands: usize = 28,
    save_playlist: ?[]const u8 = null,
    /// Size used by `--dump-ui`, and by the desktop interface's
    /// `--screenshot`. The defaults suit a terminal; the GUI overrides them.
    dump_width: u16 = 110,
    dump_height: u16 = 30,
    /// Desktop interface only: render one frame to this BMP and exit.
    screenshot_path: ?[]const u8 = null,
    /// True once `--size` has been given, so a later default cannot override it.
    explicit_size: bool = false,

    pub fn hasWork(self: Config) bool {
        return self.inputs.len > 0 or self.tone_shape != null;
    }
};

const Parser = struct {
    args: []const []const u8,
    i: usize = 0,
    /// Set when a bad value is reported, for a better message.
    bad_option: []const u8 = "",
    bad_value: []const u8 = "",

    fn next(p: *Parser) ?[]const u8 {
        if (p.i >= p.args.len) return null;
        const a = p.args[p.i];
        p.i += 1;
        return a;
    }

    /// Value for the option just consumed, supporting both `--opt value` and
    /// `--opt=value`.
    fn value(p: *Parser, opt: []const u8, inline_value: ?[]const u8) Error![]const u8 {
        if (inline_value) |v| return v;
        const v = p.next() orelse {
            p.bad_option = opt;
            return error.MissingValue;
        };
        return v;
    }

    fn fail(p: *Parser, opt: []const u8, v: []const u8) Error {
        p.bad_option = opt;
        p.bad_value = v;
        return error.BadValue;
    }
};

/// Parse `args` (without the program name). `inputs` is allocated with `gpa`.
pub fn parse(gpa: Allocator, args: []const []const u8) Error!Config {
    var cfg: Config = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(gpa);

    var p: Parser = .{ .args = args };
    var saw_terminator = false;

    while (p.next()) |arg| {
        if (saw_terminator or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            inputs.append(gpa, arg) catch return error.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            saw_terminator = true;
            continue;
        }

        // Split "--name=value".
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            inline_value = arg[eq + 1 ..];
        }

        if (eqls(name, "-h", "--help")) {
            cfg.action = .help;
        } else if (eqls(name, "-v", "--version")) {
            cfg.action = .show_version;
        } else if (std.mem.eql(u8, name, "--probe")) {
            cfg.action = .probe;
        } else if (std.mem.eql(u8, name, "--raw")) {
            cfg.action = .raw;
        } else if (std.mem.eql(u8, name, "--verify-seek")) {
            cfg.action = .verify_seek;
        } else if (std.mem.eql(u8, name, "--list-devices")) {
            cfg.action = .list_devices;
        } else if (std.mem.eql(u8, name, "--dump-ui")) {
            cfg.action = .dump_ui;
        } else if (std.mem.eql(u8, name, "--screenshot")) {
            // Handled by the desktop interface; the terminal player ignores it.
            cfg.screenshot_path = try p.value(name, inline_value);
            if (!cfg.explicit_size) {
                cfg.dump_width = 1100;
                cfg.dump_height = 700;
            }
        } else if (std.mem.eql(u8, name, "--size")) {
            const v = try p.value(name, inline_value);
            const x = std.mem.indexOfScalar(u8, v, 'x') orelse return p.fail(name, v);
            cfg.dump_width = std.fmt.parseInt(u16, v[0..x], 10) catch return p.fail(name, v);
            cfg.dump_height = std.fmt.parseInt(u16, v[x + 1 ..], 10) catch return p.fail(name, v);
            if (cfg.dump_width < 10 or cfg.dump_height < 4) return p.fail(name, v);
            cfg.explicit_size = true;

            // --- playback ---
        } else if (std.mem.eql(u8, name, "--shuffle")) {
            cfg.shuffle = true;
        } else if (std.mem.eql(u8, name, "--repeat")) {
            const v = try p.value(name, inline_value);
            cfg.repeat = if (std.ascii.eqlIgnoreCase(v, "off"))
                .off
            else if (std.ascii.eqlIgnoreCase(v, "all"))
                .all
            else if (std.ascii.eqlIgnoreCase(v, "one"))
                .one
            else
                return p.fail(name, v);
        } else if (eqls(name, "-V", "--volume")) {
            const v = try p.value(name, inline_value);
            const pct = std.fmt.parseFloat(f32, v) catch return p.fail(name, v);
            if (pct < 0 or pct > 100) return p.fail(name, v);
            cfg.volume = pct / 100.0;
        } else if (std.mem.eql(u8, name, "--start-at")) {
            const v = try p.value(name, inline_value);
            cfg.start_at = parseDuration(v) orelse return p.fail(name, v);
        } else if (std.mem.eql(u8, name, "--loop-forever")) {
            cfg.exit_at_end = false;
            cfg.repeat = .all;

            // --- output ---
        } else if (eqls(name, "-o", "--backend")) {
            const v = try p.value(name, inline_value);
            cfg.backend_kind = backend.Kind.fromName(v) orelse return p.fail(name, v);
        } else if (std.mem.eql(u8, name, "--device")) {
            cfg.device_id = try p.value(name, inline_value);
        } else if (std.mem.eql(u8, name, "--latency")) {
            const v = try p.value(name, inline_value);
            const ms = std.fmt.parseInt(u32, v, 10) catch return p.fail(name, v);
            if (ms < 2 or ms > 2000) return p.fail(name, v);
            cfg.latency_ms = ms;
        } else if (std.mem.eql(u8, name, "--buffer")) {
            const v = try p.value(name, inline_value);
            const ms = std.fmt.parseInt(u32, v, 10) catch return p.fail(name, v);
            if (ms < 50 or ms > 30_000) return p.fail(name, v);
            cfg.buffer_ms = ms;
        } else if (std.mem.eql(u8, name, "--resample")) {
            const v = try p.value(name, inline_value);
            cfg.resample_quality = if (std.ascii.eqlIgnoreCase(v, "low"))
                .low
            else if (std.ascii.eqlIgnoreCase(v, "medium"))
                .medium
            else if (std.ascii.eqlIgnoreCase(v, "high"))
                .high
            else
                return p.fail(name, v);
        } else if (std.mem.eql(u8, name, "--render")) {
            cfg.render_path = try p.value(name, inline_value);
            cfg.backend_kind = .wav_file;
            cfg.use_ui = false;

            // --- processing ---
        } else if (std.mem.eql(u8, name, "--eq")) {
            const v = try p.value(name, inline_value);
            cfg.eq_preset = equalizer.Preset.fromName(v) orelse return p.fail(name, v);
            cfg.eq_enabled = true;
        } else if (std.mem.eql(u8, name, "--eq-bands")) {
            const v = try p.value(name, inline_value);
            cfg.eq_bands = parseBands(v) orelse return p.fail(name, v);
            cfg.eq_enabled = true;
        } else if (std.mem.eql(u8, name, "--no-limiter")) {
            cfg.limiter = false;
        } else if (std.mem.eql(u8, name, "--ceiling")) {
            const v = try p.value(name, inline_value);
            const db = std.fmt.parseFloat(f32, v) catch return p.fail(name, v);
            if (db > 0 or db < -24) return p.fail(name, v);
            cfg.ceiling_db = db;
        } else if (std.mem.eql(u8, name, "--no-replaygain")) {
            cfg.replaygain = false;
        } else if (std.mem.eql(u8, name, "--replaygain-album")) {
            cfg.replaygain_album = true;

            // --- synthesized input ---
        } else if (std.mem.eql(u8, name, "--tone")) {
            const v = try p.value(name, inline_value);
            cfg.tone_shape = tone.parseShape(v) orelse return p.fail(name, v);
        } else if (std.mem.eql(u8, name, "--duration")) {
            const v = try p.value(name, inline_value);
            cfg.tone_seconds = parseDuration(v) orelse return p.fail(name, v);
            if (cfg.tone_seconds <= 0) return p.fail(name, v);

            // --- interface ---
        } else if (std.mem.eql(u8, name, "--no-ui")) {
            cfg.use_ui = false;
        } else if (std.mem.eql(u8, name, "--theme")) {
            const v = try p.value(name, inline_value);
            cfg.theme = theme_mod.Kind.fromName(v) orelse return p.fail(name, v);
        } else if (std.mem.eql(u8, name, "--no-metadata")) {
            cfg.load_metadata = false;
        } else if (std.mem.eql(u8, name, "--no-analyzer")) {
            cfg.analyzer_bands = 0;
        } else if (std.mem.eql(u8, name, "--bands")) {
            const v = try p.value(name, inline_value);
            const n = std.fmt.parseInt(usize, v, 10) catch return p.fail(name, v);
            if (n > 128) return p.fail(name, v);
            cfg.analyzer_bands = n;
        } else if (std.mem.eql(u8, name, "--save-playlist")) {
            cfg.save_playlist = try p.value(name, inline_value);
        } else {
            p.bad_option = name;
            return error.UnknownOption;
        }
    }

    cfg.inputs = inputs.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return cfg;
}

fn eqls(name: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, name, short) or std.mem.eql(u8, name, long);
}

/// Accept "90", "1:30" or "1:02:03" as a number of seconds.
pub fn parseDuration(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;

    var total: f64 = 0;
    var parts = std.mem.splitScalar(u8, trimmed, ':');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count >= 3) return null;
        const v = std.fmt.parseFloat(f64, part) catch return null;
        if (v < 0) return null;
        total = total * 60.0 + v;
        count += 1;
    }
    return total;
}

/// Parse ten comma-separated dB values for `--eq-bands`.
fn parseBands(text: []const u8) ?equalizer.Gains {
    var gains: equalizer.Gains = @splat(0);
    var it = std.mem.splitScalar(u8, text, ',');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= equalizer.band_count) return null;
        const trimmed = std.mem.trim(u8, part, " ");
        const v = std.fmt.parseFloat(f32, trimmed) catch return null;
        gains[i] = std.math.clamp(v, equalizer.min_gain_db, equalizer.max_gain_db);
        i += 1;
    }
    if (i != equalizer.band_count) return null;
    return gains;
}

pub const usage_text =
    \\zmp — a terminal music player
    \\
    \\usage: zmp [options] [FILE|DIRECTORY|PLAYLIST ...]
    \\
    \\Inputs may be audio files, directories (scanned recursively) or .m3u/.m3u8
    \\playlists. Formats: WAV, FLAC and MP3/MP2.
    \\
    \\Playback
    \\  --shuffle                 start with shuffle on
    \\  --repeat off|all|one      repeat mode (default off)
    \\  -V, --volume PCT          initial volume, 0-100 (default 70)
    \\  --start-at TIME           start the first track at TIME (90, 1:30, 1:02:03)
    \\  --loop-forever            keep playing the queue instead of exiting
    \\
    \\Output
    \\  -o, --backend NAME        wasapi, winmm, null or wav (default: best available)
    \\  --device ID               output device from --list-devices
    \\  --latency MS              device buffer target (default 40)
    \\  --buffer MS               decode-ahead buffer (default 1500)
    \\  --resample low|medium|high  conversion quality (default medium)
    \\  --render FILE.wav         render to a file instead of playing
    \\  --list-devices            list output devices and exit
    \\
    \\Sound
    \\  --eq PRESET               flat, rock, pop, jazz, classical, dance, acoustic,
    \\                            electronic, bass_boost, treble_boost, vocal, loudness
    \\  --eq-bands a,b,...        ten dB values, -12 to +12
    \\  --no-limiter              disable the output limiter
    \\  --ceiling DB              limiter ceiling, -24 to 0 (default -0.2)
    \\  --no-replaygain           ignore ReplayGain tags
    \\  --replaygain-album        prefer album gain over track gain
    \\
    \\Test signals
    \\  --tone SPEC               sine:440, square:100, saw:50, sweep:20-20000,
    \\                            pink, white, silence
    \\  --duration SECONDS        length of the generated signal (default 10)
    \\
    \\Interface
    \\  --no-ui                   play without the interactive interface
    \\  --theme dark|light|mono   colour scheme (default dark)
    \\  --bands N                 spectrum analyzer bands (default 28)
    \\  --no-analyzer             disable the spectrum analyzer
    \\  --no-metadata             skip reading tags before playback starts
    \\  --save-playlist FILE      write the queue as an m3u8 and exit
    \\
    \\Information
    \\  --probe                   print stream details for each input
    \\  --raw                     decode to stdout as 32-bit float PCM
    \\  --verify-seek             check that seeking is sample accurate
    \\  -h, --help                this message
    \\  -v, --version             version information
    \\
    \\Keys (interactive mode)
    \\  space play/pause   n/p track   left/right seek   up/down queue
    \\  enter play selected   + / - volume   m mute   e eq   E eq editor
    \\  s shuffle   r repeat   t theme   ? help   q quit
    \\
;

const testing = std.testing;

test "no arguments yields defaults" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{});
    defer gpa.free(cfg.inputs);

    try testing.expectEqual(Action.play, cfg.action);
    try testing.expectEqual(@as(usize, 0), cfg.inputs.len);
    try testing.expect(!cfg.hasWork());
    try testing.expectApproxEqAbs(@as(f32, 0.7), cfg.volume, 1e-6);
    try testing.expect(cfg.use_ui);
    try testing.expect(cfg.limiter);
    try testing.expectEqual(playlist_mod.RepeatMode.off, cfg.repeat);
}

test "files collect as inputs" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "a.flac", "b.mp3", "dir" });
    defer gpa.free(cfg.inputs);
    try testing.expectEqual(@as(usize, 3), cfg.inputs.len);
    try testing.expectEqualStrings("a.flac", cfg.inputs[0]);
    try testing.expectEqualStrings("dir", cfg.inputs[2]);
    try testing.expect(cfg.hasWork());
}

test "actions" {
    const gpa = testing.allocator;
    const cases = [_]struct { arg: []const u8, action: Action }{
        .{ .arg = "--help", .action = .help },
        .{ .arg = "-h", .action = .help },
        .{ .arg = "--version", .action = .show_version },
        .{ .arg = "-v", .action = .show_version },
        .{ .arg = "--probe", .action = .probe },
        .{ .arg = "--raw", .action = .raw },
        .{ .arg = "--verify-seek", .action = .verify_seek },
        .{ .arg = "--list-devices", .action = .list_devices },
    };
    for (cases) |c| {
        const cfg = try parse(gpa, &.{c.arg});
        defer gpa.free(cfg.inputs);
        try testing.expectEqual(c.action, cfg.action);
    }
}

test "both value syntaxes work" {
    const gpa = testing.allocator;
    const a = try parse(gpa, &.{ "--volume", "50" });
    defer gpa.free(a.inputs);
    try testing.expectApproxEqAbs(@as(f32, 0.5), a.volume, 1e-6);

    const b = try parse(gpa, &.{"--volume=25"});
    defer gpa.free(b.inputs);
    try testing.expectApproxEqAbs(@as(f32, 0.25), b.volume, 1e-6);
}

test "repeat and shuffle" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "--shuffle", "--repeat", "all" });
    defer gpa.free(cfg.inputs);
    try testing.expect(cfg.shuffle);
    try testing.expectEqual(playlist_mod.RepeatMode.all, cfg.repeat);

    const one = try parse(gpa, &.{"--repeat=one"});
    defer gpa.free(one.inputs);
    try testing.expectEqual(playlist_mod.RepeatMode.one, one.repeat);
}

test "backend selection" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "-o", "null" });
    defer gpa.free(cfg.inputs);
    try testing.expectEqual(backend.Kind.null_sink, cfg.backend_kind.?);

    const w = try parse(gpa, &.{"--backend=wasapi"});
    defer gpa.free(w.inputs);
    try testing.expectEqual(backend.Kind.wasapi, w.backend_kind.?);
}

test "render implies a file backend and no interface" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "--render", "out.wav", "in.flac" });
    defer gpa.free(cfg.inputs);
    try testing.expectEqualStrings("out.wav", cfg.render_path.?);
    try testing.expectEqual(backend.Kind.wav_file, cfg.backend_kind.?);
    try testing.expect(!cfg.use_ui);
    try testing.expectEqual(@as(usize, 1), cfg.inputs.len);
}

test "equalizer options" {
    const gpa = testing.allocator;
    const preset = try parse(gpa, &.{ "--eq", "rock" });
    defer gpa.free(preset.inputs);
    try testing.expectEqual(equalizer.Preset.rock, preset.eq_preset.?);
    try testing.expect(preset.eq_enabled);

    const bands = try parse(gpa, &.{"--eq-bands=6,5,4,3,2,1,0,-1,-2,-3"});
    defer gpa.free(bands.inputs);
    const g = bands.eq_bands.?;
    try testing.expectApproxEqAbs(@as(f32, 6), g[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -3), g[9], 1e-6);
    try testing.expect(bands.eq_enabled);
}

test "eq band lists must have exactly ten values" {
    try testing.expect(parseBands("1,2,3") == null);
    try testing.expect(parseBands("1,2,3,4,5,6,7,8,9,10,11") == null);
    try testing.expect(parseBands("a,b,c,d,e,f,g,h,i,j") == null);
    const ok = parseBands("0,0,0,0,0,0,0,0,0,0").?;
    for (ok) |v| try testing.expectEqual(@as(f32, 0), v);
    // Out of range values clamp rather than failing.
    const clamped = parseBands("99,-99,0,0,0,0,0,0,0,0").?;
    try testing.expectEqual(equalizer.max_gain_db, clamped[0]);
    try testing.expectEqual(equalizer.min_gain_db, clamped[1]);
}

test "durations in several formats" {
    try testing.expectApproxEqAbs(@as(f64, 90), parseDuration("90").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90), parseDuration("1:30").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3723), parseDuration("1:02:03").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), parseDuration("1.5").?, 1e-9);
    try testing.expect(parseDuration("") == null);
    try testing.expect(parseDuration("abc") == null);
    try testing.expect(parseDuration("1:2:3:4") == null);
    try testing.expect(parseDuration("-5") == null);
}

test "tone specs" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "--tone", "sine:1000", "--duration", "2.5" });
    defer gpa.free(cfg.inputs);
    try testing.expectEqual(@as(f32, 1000), cfg.tone_shape.?.sine.freq);
    try testing.expectApproxEqAbs(@as(f64, 2.5), cfg.tone_seconds, 1e-9);
    try testing.expect(cfg.hasWork());
}

test "interface options" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "--no-ui", "--theme", "light", "--no-analyzer", "--no-metadata" });
    defer gpa.free(cfg.inputs);
    try testing.expect(!cfg.use_ui);
    try testing.expectEqual(theme_mod.Kind.light, cfg.theme);
    try testing.expectEqual(@as(usize, 0), cfg.analyzer_bands);
    try testing.expect(!cfg.load_metadata);
}

test "unknown options are rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownOption, parse(gpa, &.{"--nope"}));
    try testing.expectError(error.UnknownOption, parse(gpa, &.{"-z"}));
}

test "missing values are reported" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingValue, parse(gpa, &.{"--volume"}));
    try testing.expectError(error.MissingValue, parse(gpa, &.{"--eq"}));
    try testing.expectError(error.MissingValue, parse(gpa, &.{"--render"}));
}

test "out of range and malformed values are rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadValue, parse(gpa, &.{"--volume=200"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--volume=abc"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--repeat=sometimes"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--backend=coreaudio"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--eq=disco"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--latency=0"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--latency=99999"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--buffer=1"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--ceiling=5"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--resample=perfect"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--theme=solarized"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--tone=trombone"}));
    try testing.expectError(error.BadValue, parse(gpa, &.{"--bands=500"}));
}

test "a double dash stops option parsing" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "--shuffle", "--", "--weird-file-name.flac" });
    defer gpa.free(cfg.inputs);
    try testing.expect(cfg.shuffle);
    try testing.expectEqual(@as(usize, 1), cfg.inputs.len);
    try testing.expectEqualStrings("--weird-file-name.flac", cfg.inputs[0]);
}

test "a lone dash is treated as an input" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{"-"});
    defer gpa.free(cfg.inputs);
    try testing.expectEqual(@as(usize, 1), cfg.inputs.len);
    try testing.expectEqualStrings("-", cfg.inputs[0]);
}

test "loop forever implies repeat all" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{"--loop-forever"});
    defer gpa.free(cfg.inputs);
    try testing.expect(!cfg.exit_at_end);
    try testing.expectEqual(playlist_mod.RepeatMode.all, cfg.repeat);
}

test "options and inputs can interleave" {
    const gpa = testing.allocator;
    const cfg = try parse(gpa, &.{ "one.flac", "--shuffle", "two.flac", "--volume=30", "three.flac" });
    defer gpa.free(cfg.inputs);
    try testing.expectEqual(@as(usize, 3), cfg.inputs.len);
    try testing.expect(cfg.shuffle);
    try testing.expectApproxEqAbs(@as(f32, 0.3), cfg.volume, 1e-6);
}

test "usage text mentions every documented group" {
    for ([_][]const u8{
        "usage: zmp", "Playback", "Output",   "Sound",
        "Test signals",  "Interface", "Information", "Keys",
        "--shuffle",  "--eq",      "--render",    "--tone",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, usage_text, needle) != null);
    }
}
