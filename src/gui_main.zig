//! zmp-gui — entry point for the desktop interface.
//!
//! Shares the whole engine with the terminal player; only the presentation
//! layer differs. `--screenshot` renders one frame to a BMP without opening a
//! window, which is how the layout is reviewed and regression-checked.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zmp = @import("zmp");

const win32 = @import("gui/win32.zig");
const canvas_mod = @import("gui/canvas.zig");
const gui_app = @import("gui/app.zig");

const Engine = zmp.player.engine.Engine;
const library = zmp.player.library;

const usage_text =
    \\zmp-gui — a desktop music player
    \\
    \\usage: zmp-gui [options] [FILE|DIRECTORY|PLAYLIST ...]
    \\
    \\Files can also be dropped onto the window.
    \\
    \\  --shuffle                 start with shuffle on
    \\  --repeat off|all|one      repeat mode
    \\  -V, --volume PCT          initial volume, 0-100
    \\  --eq PRESET               equalizer preset
    \\  -o, --backend NAME        wasapi, winmm or null
    \\  --device ID               output device
    \\  --latency MS              device buffer target
    \\  --theme dark|light|mono   colour scheme
    \\  --screenshot FILE.bmp     render one frame and exit
    \\  --size WxH                size for --screenshot (default 1100x700)
    \\  -h, --help                this message
    \\
;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) {
        // The window and drawing layers are Win32; the terminal player runs
        // everywhere.
        return;
    }

    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    const args = if (argv.len > 0) argv[1..] else argv;

    const cfg = zmp.cli.parse(gpa, args) catch {
        showMessage("zmp-gui", "Could not understand the command line.");
        return;
    };
    defer gpa.free(cfg.inputs);

    if (cfg.action == .help) {
        showMessage("zmp-gui", usage_text);
        return;
    }

    const engine = Engine.init(gpa, io, .{
        .buffer_ms = cfg.buffer_ms,
        .latency_ms = cfg.latency_ms,
        .backend_kind = cfg.backend_kind,
        .device_id = cfg.device_id,
        .resample_quality = cfg.resample_quality,
        .use_replaygain = cfg.replaygain,
        .replaygain_album_mode = cfg.replaygain_album,
        // The spectrum display wants more bars than the terminal version,
        // since it has pixels rather than cells to work with.
        .analyzer_bands = 64,
        .analyzer_fft_size = 4096,
        .initial_volume = cfg.volume,
    }) catch {
        showMessage("zmp-gui", "Could not start the audio engine.");
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

    if (cfg.eq_preset) |preset| engine.setEqPreset(preset);
    if (cfg.eq_bands) |bands| {
        for (bands, 0..) |g, i| engine.setEqBand(@intCast(i), g);
    }
    engine.setEqEnabled(cfg.eq_enabled);
    engine.setLimiterEnabled(cfg.limiter);
    engine.setLimiterCeilingDb(cfg.ceiling_db);

    if (cfg.screenshot_path) |path| {
        try screenshot(gpa, io, engine, cfg, path);
        return;
    }

    engine.start() catch {
        showMessage(
            "zmp-gui",
            "No audio output could be opened. Playback will be silent.",
        );
    };

    var app = gui_app.App.init(gpa, io, engine, cfg.theme) catch {
        showMessage("zmp-gui", "Out of memory.");
        return;
    };
    defer app.deinit();
    // Asking for an equalizer setting on the command line implies wanting to
    // see the equalizer.
    app.show_eq = cfg.eq_enabled;

    const has_tracks = blk: {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        break :blk pl.count() > 0;
    };
    if (has_tracks) engine.play();

    app.run() catch |e| switch (e) {
        // The only failure `run` reports is that the window could not be
        // created, which the user needs told since there is nothing to see.
        error.WindowFailed => showMessage(
            "zmp-gui",
            "The player window could not be created.",
        ),
        error.OutOfMemory => showMessage("zmp-gui", "Out of memory."),
    };
}

/// Render one frame offscreen and write it as a BMP.
fn screenshot(
    gpa: std.mem.Allocator,
    io: Io,
    engine: *Engine,
    cfg: zmp.cli.Config,
    path: []const u8,
) !void {
    var app = gui_app.App.init(gpa, io, engine, cfg.theme) catch return;
    defer app.deinit();
    app.show_eq = cfg.eq_enabled;

    // Run briefly against the real output so the frame shows a live position,
    // spectrum and meters rather than an idle shell.
    engine.start() catch {};
    engine.play();
    var settle: u32 = 0;
    while (settle < 60) : (settle += 1) {
        if (engine.analyzerPtr()) |an| _ = an.update();
        io.sleep(.fromMilliseconds(25), .awake) catch break;
        if (engine.status().position_s > 0.8) break;
    }

    try app.renderOffscreen(cfg.dump_width, cfg.dump_height, path);
}

fn showMessage(title: []const u8, body: []const u8) void {
    if (builtin.os.tag != .windows) return;
    var title_buf: [128]u16 = undefined;
    var body_buf: [4096]u16 = undefined;
    const t = win32.toWide(&title_buf, title) orelse return;
    const b = win32.toWide(&body_buf, body) orelse return;
    _ = win32.MessageBoxW(null, b.ptr, t.ptr, 0);
}

test "the GUI entry module compiles against the engine" {
    try std.testing.expect(usage_text.len > 0);
}

test {
    // Pull the interface's own tests into this module's test binary; Zig only
    // analyzes a file when something references it.
    _ = win32;
    _ = canvas_mod;
    _ = gui_app;
    _ = @import("gui/theme.zig");
}
