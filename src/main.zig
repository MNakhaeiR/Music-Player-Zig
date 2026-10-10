//! zmp — entry point.
//!
//! Parses the command line, builds a queue, and either runs the interactive
//! interface or plays headless. The diagnostic modes (`--probe`, `--raw`,
//! `--verify-seek`) go straight to the decoders without touching a device.

const std = @import("std");
const Io = std.Io;
const zmp = @import("zmp");

const cli = zmp.cli;
const decoder_mod = zmp.decode.decoder;
const tags_mod = zmp.meta.tags;
const library = zmp.player.library;
const Engine = zmp.player.engine.Engine;
const Playlist = zmp.player.playlist.Playlist;
const backend_mod = zmp.audio.backend;
const Terminal = zmp.ui.term.Terminal;
const App = zmp.ui.app.App;
const time_util = zmp.util.time;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    const args = if (argv.len > 0) argv[1..] else argv;

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err = &stderr_file.interface;

    const cfg = cli.parse(gpa, args) catch |e| {
        switch (e) {
            error.UnknownOption => try err.print("zmp: unrecognized option\n", .{}),
            error.MissingValue => try err.print("zmp: option is missing its value\n", .{}),
            error.BadValue => try err.print("zmp: invalid value for an option\n", .{}),
            error.OutOfMemory => try err.print("zmp: out of memory\n", .{}),
        }
        try err.print("try 'zmp --help'\n", .{});
        try err.flush();
        std.process.exit(2);
    };
    defer gpa.free(cfg.inputs);

    switch (cfg.action) {
        .help => {
            try out.writeAll(cli.usage_text);
            try out.flush();
        },
        .show_version => {
            try out.print("zmp {s}\n", .{cli.version});
            try out.print("zig {s}\n", .{@import("builtin").zig_version_string});
            try out.print("formats: WAV, FLAC{s}\n", .{
                if (zmp.decode.mp3.enabled) ", MP3/MP2" else "",
            });
            try out.flush();
        },
        .list_devices => try listDevices(gpa, out, err),
        .dump_ui => try dumpUi(gpa, io, cfg, out, err),
        .probe => try probeInputs(gpa, io, cfg, out, err),
        .raw => try rawInputs(gpa, io, cfg, out, err),
        .verify_seek => try verifySeek(gpa, io, cfg, out, err),
        .play => try runPlayer(gpa, io, cfg, out, err),
    }

    try out.flush();
    try err.flush();
}

// ---------------------------------------------------------------------------
// Diagnostic modes
// ---------------------------------------------------------------------------

fn listDevices(gpa: std.mem.Allocator, out: *Io.Writer, err: *Io.Writer) !void {
    var list = backend_mod.listDevices(gpa) catch {
        try err.print("zmp: could not enumerate audio devices\n", .{});
        return;
    };
    defer list.deinit();

    try out.print("output devices:\n\n", .{});
    for (list.items) |d| {
        try out.print("  {s:<7} {s} {s}\n", .{
            d.kind.label(),
            if (d.is_default) "*" else " ",
            d.name,
        });
        if (d.sample_rate != 0) {
            try out.print("          {d} Hz, {d} channels\n", .{ d.sample_rate, d.channels });
        }
        try out.print("          --device {s}\n\n", .{d.id});
    }
    try out.print("* is the system default. Pass --backend to force one API.\n", .{});
}

fn probeInputs(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    if (cfg.inputs.len == 0) {
        try err.print("zmp: --probe needs at least one file\n", .{});
        return;
    }

    var list = Playlist.init(gpa, 0);
    defer list.deinit();
    for (cfg.inputs) |input| {
        _ = library.add(gpa, io, &list, input, .{}) catch |e| {
            try err.print("zmp: {s}: {t}\n", .{ input, e });
            continue;
        };
    }

    for (list.tracks.items, 0..) |track, i| {
        if (i > 0) try out.print("\n", .{});
        try out.print("{s}\n", .{track.path});

        var dec = decoder_mod.Decoder.openFile(gpa, io, track.path) catch |e| {
            try out.print("  cannot decode: {t}\n", .{e});
            continue;
        };
        defer dec.deinit();

        const info = dec.info();
        try out.print("  codec       {s}\n", .{info.codec.label()});
        try out.print("  sample rate {d} Hz\n", .{info.sample_rate});
        try out.print("  channels    {d}\n", .{info.channels});
        try out.print("  bit depth   {d}\n", .{info.bits_per_sample});
        if (info.total_frames) |frames| {
            var clock: [32]u8 = undefined;
            try out.print("  frames      {d}\n", .{frames});
            try out.print("  duration    {s} ({d:.3} s)\n", .{
                time_util.formatClock(&clock, info.durationSeconds().?),
                info.durationSeconds().?,
            });
        } else {
            try out.print("  duration    unknown\n", .{});
        }
        if (info.bitrate) |b| {
            try out.print("  bitrate     {d} kbps\n", .{b / 1000});
        }
        try out.print("  seekable    {}\n", .{info.seekable});
        try out.print("  mapped      {}\n", .{dec.source.isMapped()});

        if (dec.tagBlock()) |block| {
            var tags = tags_mod.parse(gpa, toMetaBlock(block));
            defer tags.deinit();
            if (tags.title) |v| try out.print("  title       {s}\n", .{v});
            if (tags.artist) |v| try out.print("  artist      {s}\n", .{v});
            if (tags.album_artist) |v| try out.print("  albumartist {s}\n", .{v});
            if (tags.album) |v| try out.print("  album       {s}\n", .{v});
            if (tags.genre) |v| try out.print("  genre       {s}\n", .{v});
            if (tags.date) |v| try out.print("  date        {s}\n", .{v});
            if (tags.track) |v| try out.print("  track       {d}\n", .{v});
            if (tags.disc) |v| try out.print("  disc        {d}\n", .{v});
            if (tags.comment) |v| try out.print("  comment     {s}\n", .{v});
            if (tags.gain_track_db) |v| try out.print("  rg track    {d:.2} dB\n", .{v});
            if (tags.gain_album_db) |v| try out.print("  rg album    {d:.2} dB\n", .{v});
        }
    }
}

fn rawInputs(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    if (cfg.inputs.len == 0) {
        try err.print("zmp: --raw needs at least one file\n", .{});
        return;
    }
    for (cfg.inputs) |path| {
        var dec = decoder_mod.Decoder.openFile(gpa, io, path) catch |e| {
            try err.print("zmp: {s}: {t}\n", .{ path, e });
            continue;
        };
        defer dec.deinit();

        const channels: usize = dec.info().channels;
        const buf = try gpa.alloc(f32, 8192 * channels);
        defer gpa.free(buf);

        while (true) {
            const n = dec.readFrames(buf) catch |e| {
                try err.print("zmp: {s}: {t}\n", .{ path, e });
                break;
            };
            if (n == 0) break;
            try out.writeAll(std.mem.sliceAsBytes(buf[0 .. n * channels]));
        }
    }
}

fn verifySeek(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    if (cfg.inputs.len == 0) {
        try err.print("zmp: --verify-seek needs at least one file\n", .{});
        return;
    }

    var failures: usize = 0;
    for (cfg.inputs) |path| {
        try out.print("{s}\n", .{path});
        var dec = decoder_mod.Decoder.openFile(gpa, io, path) catch |e| {
            try out.print("  cannot decode: {t}\n", .{e});
            failures += 1;
            continue;
        };
        defer dec.deinit();

        const info = dec.info();
        const total: usize = @intCast(info.total_frames orelse {
            try out.print("  stream length unknown; skipping\n", .{});
            continue;
        });
        const ch: usize = info.channels;

        // Decode the whole stream once as a reference.
        const all = try gpa.alloc(f32, total * ch);
        defer gpa.free(all);
        var got: usize = 0;
        while (got < total) {
            const n = dec.readFrames(all[got * ch ..]) catch break;
            if (n == 0) break;
            got += n;
        }
        try out.print("  decoded {d}/{d} frames\n", .{ got, total });

        // Then seek all over it and compare.
        const window = 64;
        const probe = try gpa.alloc(f32, window * ch);
        defer gpa.free(probe);

        const points = [_]u64{ 0, 1, 1023, 4096, 44_100, 100_000, 500_000 };
        for (points) |p| {
            if (p + window >= got) continue;
            dec.seekToFrame(p) catch |e| {
                try out.print("  seek {d}: failed ({t})\n", .{ p, e });
                failures += 1;
                continue;
            };
            const reported = dec.positionFrames();
            const n = dec.readFrames(probe) catch 0;
            var worst: f32 = 0;
            for (0..n * ch) |i| {
                worst = @max(worst, @abs(probe[i] - all[@as(usize, @intCast(p)) * ch + i]));
            }
            const exact = worst == 0 and reported == p;
            if (!exact) failures += 1;
            try out.print("  seek {d:>7}: {d:>3} frames, delta {d:.9}  {s}\n", .{
                p, n, worst, if (exact) "exact" else "MISMATCH",
            });
        }
    }
    try out.print("\n{s}\n", .{
        if (failures == 0) "seek verification passed" else "seek verification FAILED",
    });
}

/// Clear any colour the dumped frame left set, then end the line.
const ansi_reset = "\x1b[0m\n";

/// Render one frame of the interface to stdout. Lets the layout be inspected
/// (and diffed) without an interactive terminal, which is also how the UI is
/// checked when stdout is a pipe.
fn dumpUi(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    const engine = Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = cfg.analyzer_bands,
        .initial_volume = cfg.volume,
    }) catch |e| {
        try err.print("zmp: {t}\n", .{e});
        return;
    };
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        for (cfg.inputs) |input| {
            _ = library.add(gpa, io, pl, input, .{}) catch continue;
        }
        pl.setShuffle(cfg.shuffle);
        pl.setRepeat(cfg.repeat);
    }
    if (cfg.load_metadata) {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        library.loadMetadata(gpa, io, pl, null);
    }

    var app = App.initHeadless(
        gpa,
        io,
        engine,
        cfg.dump_width,
        cfg.dump_height,
        cfg.theme,
    ) catch |e| {
        try err.print("zmp: {t}\n", .{e});
        return;
    };
    defer app.deinit();

    // Run briefly against the null sink so the frame shows a real position,
    // spectrum and level meters rather than an idle shell.
    engine.play();
    engine.start() catch {};
    var settle: u32 = 0;
    while (settle < 40) : (settle += 1) {
        if (engine.analyzerPtr()) |an| _ = an.update();
        io.sleep(.fromMilliseconds(25), .awake) catch break;
        if (engine.status().position_s > 0.6) break;
    }

    app.drawFrame();
    try app.screen.flush(out);
    try out.writeAll(ansi_reset);
}

fn toMetaBlock(block: decoder_mod.TagBlock) tags_mod.Block {
    return switch (block) {
        .id3 => |b| .{ .id3 = b },
        .vorbis_comment => |b| .{ .vorbis_comment = b },
        .riff_info => |b| .{ .riff_info = b },
    };
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

fn runPlayer(
    gpa: std.mem.Allocator,
    io: Io,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    if (!cfg.hasWork()) {
        try out.writeAll(cli.usage_text);
        try out.flush();
        return;
    }

    // Decide the output format before the engine opens a device: for an
    // offline render, matching the source rate avoids a resampling pass that
    // would otherwise be baked into the file.
    var first_rate: ?u32 = null;
    var first_channels: ?u8 = null;

    const engine = Engine.init(gpa, io, .{
        .buffer_ms = cfg.buffer_ms,
        .latency_ms = cfg.latency_ms,
        .backend_kind = cfg.backend_kind,
        .device_id = cfg.device_id,
        .output_path = cfg.render_path,
        .resample_quality = cfg.resample_quality,
        .use_replaygain = cfg.replaygain,
        .replaygain_album_mode = cfg.replaygain_album,
        .analyzer_bands = if (cfg.use_ui) cfg.analyzer_bands else 0,
        .initial_volume = cfg.volume,
        .initial_offset_s = cfg.start_at,
        .tone_spec = if (cfg.tone_shape) |shape| .{
            .shape = shape,
            // Overwritten with the output's own rate when the track starts.
            .frames = 0,
        } else null,
    }) catch |e| {
        try err.print("zmp: cannot start the engine: {t}\n", .{e});
        return;
    };
    defer engine.deinit();

    // --- build the queue ---
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();

        var added: usize = 0;
        for (cfg.inputs) |input| {
            const result = library.add(gpa, io, pl, input, .{}) catch |e| {
                try err.print("zmp: {s}: {t}\n", .{ input, e });
                continue;
            };
            added += result.added;
        }
        if (cfg.tone_shape) |shape| {
            // A synthesized source has no file, so it is queued as a
            // pseudo-path the engine recognizes.
            var name_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&name_buf, "test signal: {s}", .{
                shape.label(),
            }) catch "test signal";
            _ = pl.appendTrack(.{
                .path = zmp.player.engine.tone_scheme ++ "generated",
                .title = label,
                .duration_s = cfg.tone_seconds,
            }) catch {};
            added += 1;
        }
        if (added == 0) {
            try err.print("zmp: nothing playable was found\n", .{});
            return;
        }

        pl.setShuffle(cfg.shuffle);
        pl.setRepeat(cfg.repeat);
    }

    // --- metadata pre-pass ---
    if (cfg.load_metadata) {
        const pl = engine.lockPlaylist();
        const count = pl.count();
        engine.unlockPlaylist();

        if (count > 1 and !cfg.use_ui) {
            try out.print("reading tags for {d} tracks...\n", .{count});
            try out.flush();
        }
        const pl2 = engine.lockPlaylist();
        library.loadMetadata(gpa, io, pl2, null);
        if (pl2.count() > 0) {
            if (pl2.at(0)) |t| {
                first_rate = if (t.sample_rate != 0) t.sample_rate else null;
                first_channels = if (t.channels != 0) t.channels else null;
            }
        }
        engine.unlockPlaylist();
    }

    // Writing a playlist is a terminal action.
    if (cfg.save_playlist) |path| {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        library.saveM3u(io, pl, path) catch |e| {
            try err.print("zmp: cannot write {s}: {t}\n", .{ path, e });
            return;
        };
        try out.print("wrote {d} tracks to {s}\n", .{ pl.count(), path });
        return;
    }

    // For a render, follow the source format and give the file an exact
    // length rather than trailing silence.
    if (cfg.render_path != null) {
        engine.options.output_sample_rate = first_rate;
        engine.options.output_channels = first_channels;
        const pl = engine.lockPlaylist();
        const seconds = pl.totalDurationSeconds();
        engine.unlockPlaylist();
        if (seconds > 0) {
            const rate = first_rate orelse 48_000;
            // Add the DSP chain's latency so the tail is not clipped.
            engine.options.render_frames =
                @as(u64, @intFromFloat(seconds * @as(f64, @floatFromInt(rate)))) + 4096;
        }
    }

    engine.start() catch |e| {
        try err.print("zmp: cannot open an audio output: {t}\n", .{e});
        return;
    };

    // --- apply sound settings ---
    if (cfg.eq_preset) |preset| engine.setEqPreset(preset);
    if (cfg.eq_bands) |bands| {
        for (bands, 0..) |g, i| engine.setEqBand(@intCast(i), g);
    }
    engine.setEqEnabled(cfg.eq_enabled);
    engine.setLimiterEnabled(cfg.limiter);
    engine.setLimiterCeilingDb(cfg.ceiling_db);

    if (cfg.start_at > 0) engine.seekTo(cfg.start_at);
    engine.play();

    if (cfg.use_ui) {
        try runInteractive(gpa, io, engine, cfg, out, err);
    } else {
        try runHeadless(io, engine, cfg, out);
    }
}

fn runInteractive(
    gpa: std.mem.Allocator,
    io: Io,
    engine: *Engine,
    cfg: cli.Config,
    out: *Io.Writer,
    err: *Io.Writer,
) !void {
    const terminal = Terminal.init(gpa, io) catch |e| {
        // Not a terminal (piped output, for instance): fall back rather than
        // failing, so `zmp song.flac | tee log` still plays.
        switch (e) {
            error.NotATerminal => {
                try err.print("zmp: not a terminal; playing without the interface\n", .{});
                try err.flush();
                return runHeadless(io, engine, cfg, out);
            },
            else => {
                try err.print("zmp: cannot set up the terminal: {t}\n", .{e});
                try err.flush();
                return runHeadless(io, engine, cfg, out);
            },
        }
    };
    defer terminal.deinit();

    var app = App.init(gpa, io, engine, terminal, cfg.theme) catch |e| {
        try err.print("zmp: {t}\n", .{e});
        return;
    };
    defer app.deinit();

    // The interface exits when the user asks; if the queue finishes first and
    // the user did not ask to keep going, exit too.
    if (cfg.exit_at_end) {
        app.target_fps = 30;
    }

    try app.run();
}

fn runHeadless(io: Io, engine: *Engine, cfg: cli.Config, out: *Io.Writer) !void {
    var last_line_len: usize = 0;
    var ticks: u64 = 0;

    while (true) {
        if (engine.finished() and cfg.exit_at_end) break;

        const st = engine.status();

        // A one-line status, refreshed in place. Keep it quiet when rendering
        // to a file, where stdout may be the useful output.
        if (cfg.render_path == null and ticks % 4 == 0) {
            var line_buf: [240]u8 = undefined;
            var elapsed_buf: [16]u8 = undefined;
            var total_buf: [16]u8 = undefined;

            const pl = engine.lockPlaylist();
            var title: []const u8 = "";
            if (st.track_index) |i| {
                if (pl.at(i)) |t| title = t.displayTitle();
            }
            const count = pl.count();
            engine.unlockPlaylist();

            const line = std.fmt.bufPrint(&line_buf, "\r[{s}] {s} / {s}  {d}/{d}  {s}", .{
                st.state.label(),
                time_util.formatClock(&elapsed_buf, st.position_s),
                if (st.duration_s) |d| time_util.formatClock(&total_buf, d) else "--:--",
                (st.track_index orelse 0) + 1,
                count,
                title,
            }) catch "";

            try out.writeAll(line);
            // Erase whatever the previous, longer line left behind.
            if (last_line_len > line.len) {
                var pad: usize = last_line_len - line.len;
                while (pad > 0) : (pad -= 1) try out.writeByte(' ');
            }
            last_line_len = line.len;
            try out.flush();
        }

        ticks += 1;
        io.sleep(.fromMilliseconds(125), .awake) catch break;
    }

    const final = engine.status();
    if (cfg.render_path) |path| {
        try out.print("rendered {s}\n", .{path});
        try out.print("  {d} frames written, {d} decoded\n", .{
            engine.outputFramesWritten(),
            engine.renderedFrames(),
        });
    } else {
        try out.print("\n", .{});
    }
    if (final.decode_errors > 0) {
        try out.print("  {d} decode error(s); last was {s}\n", .{
            final.decode_errors,
            final.last_error.label(),
        });
    }
    if (final.underruns > 0) {
        try out.print("  {d} buffer underrun(s) — try a larger --buffer\n", .{final.underruns});
    }
    try out.flush();
}

test "the entry point module compiles with the library" {
    // The real coverage lives in the library's own tests; this just keeps the
    // executable's module in the test graph.
    try std.testing.expect(cli.usage_text.len > 0);
}
