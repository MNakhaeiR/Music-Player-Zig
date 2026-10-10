//! The interactive terminal interface.
//!
//! One loop: drain the key queue, ask the engine for a status snapshot, redraw
//! into the cell buffer, flush the difference, sleep until the next frame. The
//! engine is only ever touched through its command methods and `status()`, so
//! nothing here can stall the audio thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const term_mod = @import("term.zig");
const screen_mod = @import("screen.zig");
const theme_mod = @import("theme.zig");

const Terminal = term_mod.Terminal;
const Key = term_mod.Key;
const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Rgb = screen_mod.Rgb;
const Theme = theme_mod.Theme;

const engine_mod = @import("../player/engine.zig");
const Engine = engine_mod.Engine;
const playlist_mod = @import("../player/playlist.zig");
const library = @import("../player/library.zig");
const equalizer = @import("../dsp/equalizer.zig");
const analyzer_mod = @import("../dsp/analyzer.zig");
const time_util = @import("../util/time.zig");

pub const Error = error{ OutOfMemory, NoTerminal };

const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    fn inner(r: Rect) Rect {
        if (r.w < 2 or r.h < 2) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
        return .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 };
    }
};

const View = enum { player, help, equalizer };

/// `'+'` or `'-'`, for displaying a signed decibel value.
fn signChar(value: f32) u8 {
    return if (value < 0) '-' else '+';
}

/// Transient message shown in the footer.
const Toast = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    frames_left: u16 = 0,

    fn set(t: *Toast, comptime fmt: []const u8, args: anytype, frames: u16) void {
        const out = std.fmt.bufPrint(&t.buf, fmt, args) catch {
            t.len = 0;
            return;
        };
        t.len = out.len;
        t.frames_left = frames;
    }

    fn text(t: *const Toast) ?[]const u8 {
        if (t.frames_left == 0 or t.len == 0) return null;
        return t.buf[0..t.len];
    }

    fn tick(t: *Toast) void {
        if (t.frames_left > 0) t.frames_left -= 1;
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    engine: *Engine,
    /// Null when the app was built headless for a drawing test.
    terminal: ?*Terminal,
    screen: Screen,
    theme: Theme,

    view: View = .player,
    /// Index into the playlist that the queue cursor is on.
    cursor: usize = 0,
    /// First visible queue row.
    scroll: usize = 0,
    /// Band the EQ editor is editing.
    eq_band: usize = 0,
    toast: Toast = .{},
    quit_requested: bool = false,
    /// Follow the playing track with the cursor until the user moves it.
    follow_playback: bool = true,

    /// Redraws per second while playing. Idle drops to a third of this.
    target_fps: u32 = 30,

    /// Characters used for the border.
    border: screen_mod.BorderSet = .rounded,

    pub fn init(
        gpa: Allocator,
        io: Io,
        engine: *Engine,
        terminal: *Terminal,
        theme_kind: theme_mod.Kind,
    ) Error!App {
        const size = terminal.size;
        const scr = Screen.init(gpa, size.width, size.height) catch return error.OutOfMemory;
        return .{
            .gpa = gpa,
            .io = io,
            .engine = engine,
            .terminal = terminal,
            .screen = scr,
            .theme = Theme.get(theme_kind),
        };
    }

    /// Build an interface with no terminal behind it, so the drawing code can
    /// be exercised against a fixed-size buffer in tests.
    pub fn initHeadless(
        gpa: Allocator,
        io: Io,
        engine: *Engine,
        width: u16,
        height: u16,
        theme_kind: theme_mod.Kind,
    ) Error!App {
        const scr = Screen.init(gpa, width, height) catch return error.OutOfMemory;
        return .{
            .gpa = gpa,
            .io = io,
            .engine = engine,
            .terminal = null,
            .screen = scr,
            .theme = Theme.get(theme_kind),
        };
    }

    pub fn deinit(self: *App) void {
        self.screen.deinit();
        self.* = undefined;
    }

    /// Render one frame into the cell buffer. Exposed for tests; `run` calls
    /// it once per frame.
    pub fn drawFrame(self: *App) void {
        self.draw(self.engine.status());
    }

    pub fn run(self: *App) !void {
        if (self.terminal == null) return error.NoTerminal;
        self.terminal.?.enterAltScreen();
        self.terminal.?.hideCursor();
        self.terminal.?.clearScreen();
        self.terminal.?.startInput();
        defer {
            self.terminal.?.showCursor();
            self.terminal.?.leaveAltScreen();
            self.terminal.?.flush() catch {};
        }

        self.toast.set("Press ? for help", .{}, 90);

        while (!self.quit_requested) {
            // Input first, so a keypress is reflected in this frame.
            while (self.terminal.?.pollKey()) |key| self.handleKey(key);

            if (self.terminal.?.refreshSize()) {
                const size = self.terminal.?.size;
                self.screen.resize(size.width, size.height) catch {};
            }

            if (self.engine.analyzerPtr()) |an| _ = an.update();

            const st = self.engine.status();
            self.syncCursorToPlayback(st);
            self.draw(st);

            try self.screen.flush(self.terminal.?.writer_ptr());
            self.terminal.?.flush() catch {};
            self.toast.tick();

            const fps = if (st.state == .playing) self.target_fps else @max(self.target_fps / 3, 5);
            const frame_ms: i64 = @intCast(1000 / @max(fps, 1));
            self.io.sleep(.fromMilliseconds(frame_ms), .awake) catch break;
        }
    }

    fn syncCursorToPlayback(self: *App, st: engine_mod.Status) void {
        if (!self.follow_playback) return;
        if (st.track_index) |i| self.cursor = i;
    }

    // -----------------------------------------------------------------------
    // Input
    // -----------------------------------------------------------------------

    fn handleKey(self: *App, key: Key) void {
        // Overlays take the keys they care about first.
        switch (self.view) {
            .help => {
                switch (key) {
                    .escape, .enter => self.view = .player,
                    .char => |c| switch (c) {
                        '?', 'q' => self.view = .player,
                        else => {},
                    },
                    .f => |n| if (n == 1) {
                        self.view = .player;
                    },
                    else => {},
                }
                return;
            },
            .equalizer => {
                if (self.handleEqKey(key)) return;
            },
            .player => {},
        }

        switch (key) {
            .resize => self.screen.invalidate(),
            .char => |c| self.handleCharKey(c),
            .ctrl => |c| switch (c) {
                'c' => self.quit_requested = true,
                'l' => self.screen.invalidate(),
                else => {},
            },
            .left => self.engine.seekBy(-5),
            .right => self.engine.seekBy(5),
            .up => self.moveCursor(-1),
            .down => self.moveCursor(1),
            .page_up => self.moveCursor(-10),
            .page_down => self.moveCursor(10),
            .home => self.setCursor(0),
            .end => {
                const n = self.queueLen();
                if (n > 0) self.setCursor(n - 1);
            },
            .enter => self.playCursor(),
            .delete => self.removeCursor(),
            .escape => {
                if (self.view != .player) {
                    self.view = .player;
                } else {
                    self.follow_playback = true;
                }
            },
            .f => |n| switch (n) {
                1 => self.view = .help,
                2 => self.view = .equalizer,
                else => {},
            },
            else => {},
        }
    }

    fn handleCharKey(self: *App, c: u21) void {
        switch (c) {
            'q' => self.quit_requested = true,
            ' ' => {
                self.engine.togglePause();
                const st = self.engine.status();
                self.toast.set("{s}", .{st.state.label()}, 30);
            },
            'n' => {
                self.engine.nextTrack();
                self.follow_playback = true;
            },
            'p' => {
                self.engine.previousTrack();
                self.follow_playback = true;
            },
            's' => {
                const pl = self.engine.lockPlaylist();
                pl.toggleShuffle();
                const on = pl.shuffle;
                self.engine.unlockPlaylist();
                self.toast.set("shuffle {s}", .{if (on) "on" else "off"}, 45);
            },
            'r' => {
                const pl = self.engine.lockPlaylist();
                pl.cycleRepeat();
                const mode = pl.repeat;
                self.engine.unlockPlaylist();
                self.toast.set("repeat {s}", .{mode.label()}, 45);
            },
            'm' => {
                self.engine.toggleMute();
                self.toast.set("mute toggled", .{}, 30);
            },
            '+', '=' => {
                self.engine.nudgeVolume(0.05);
                self.showVolume();
            },
            '-', '_' => {
                self.engine.nudgeVolume(-0.05);
                self.showVolume();
            },
            '[' => self.engine.seekBy(-30),
            ']' => self.engine.seekBy(30),
            '{' => self.engine.seekBy(-60),
            '}' => self.engine.seekBy(60),
            'e' => {
                const st = self.engine.status();
                self.engine.setEqEnabled(!st.eq_enabled);
                self.toast.set("equalizer {s}", .{if (st.eq_enabled) "off" else "on"}, 45);
            },
            'E' => self.view = .equalizer,
            'l' => {
                const st = self.engine.status();
                self.engine.setLimiterEnabled(!st.limiter_enabled);
                self.toast.set("limiter {s}", .{if (st.limiter_enabled) "off" else "on"}, 45);
            },
            'd' => self.removeCursor(),
            'g' => self.setCursor(0),
            'G' => {
                const n = self.queueLen();
                if (n > 0) self.setCursor(n - 1);
            },
            'j' => self.moveCursor(1),
            'k' => self.moveCursor(-1),
            '0' => self.engine.seekTo(0),
            '?' => self.view = .help,
            't' => self.cycleTheme(),
            else => {},
        }
    }

    /// Returns true when the EQ view consumed the key.
    fn handleEqKey(self: *App, key: Key) bool {
        switch (key) {
            .left => {
                self.eq_band = if (self.eq_band == 0) equalizer.band_count - 1 else self.eq_band - 1;
                return true;
            },
            .right => {
                self.eq_band = (self.eq_band + 1) % equalizer.band_count;
                return true;
            },
            .up => {
                self.engine.nudgeEqBand(@intCast(self.eq_band), 1.0);
                return true;
            },
            .down => {
                self.engine.nudgeEqBand(@intCast(self.eq_band), -1.0);
                return true;
            },
            .char => |c| switch (c) {
                '1'...'9' => {
                    const presets = comptime std.enums.values(equalizer.Preset);
                    const idx: usize = @intCast(c - '1');
                    if (idx < presets.len) {
                        self.engine.setEqPreset(presets[idx]);
                        self.toast.set("preset: {s}", .{presets[idx].label()}, 45);
                    }
                    return true;
                },
                '0' => {
                    self.engine.setEqPreset(.flat);
                    self.toast.set("preset: Flat", .{}, 45);
                    return true;
                },
                'E', 'e' => {
                    self.view = .player;
                    return true;
                },
                else => return false,
            },
            .escape => {
                self.view = .player;
                return true;
            },
            else => return false,
        }
    }

    fn showVolume(self: *App) void {
        const st = self.engine.status();
        self.toast.set("volume {d:.0}%", .{st.volume * 100}, 30);
    }

    fn cycleTheme(self: *App) void {
        self.theme = Theme.get(switch (self.theme.kind) {
            .dark => .light,
            .light => .mono,
            .mono => .dark,
        });
        self.screen.invalidate();
        self.toast.set("theme: {s}", .{self.theme.kind.label()}, 45);
    }

    fn queueLen(self: *App) usize {
        const pl = self.engine.lockPlaylist();
        defer self.engine.unlockPlaylist();
        return pl.count();
    }

    fn moveCursor(self: *App, delta: i32) void {
        const n = self.queueLen();
        if (n == 0) return;
        self.follow_playback = false;
        const current: i64 = @intCast(self.cursor);
        const target = std.math.clamp(current + delta, 0, @as(i64, @intCast(n - 1)));
        self.cursor = @intCast(target);
    }

    fn setCursor(self: *App, index: usize) void {
        const n = self.queueLen();
        if (n == 0) return;
        self.follow_playback = false;
        self.cursor = @min(index, n - 1);
    }

    fn playCursor(self: *App) void {
        if (self.queueLen() == 0) return;
        self.engine.playIndex(self.cursor);
        self.follow_playback = true;
    }

    fn removeCursor(self: *App) void {
        const pl = self.engine.lockPlaylist();
        const n = pl.count();
        if (n == 0) {
            self.engine.unlockPlaylist();
            return;
        }
        const playing = pl.currentIndex();
        pl.remove(self.cursor);
        const left = pl.count();
        self.engine.unlockPlaylist();

        if (left == 0) {
            self.engine.stop();
        } else if (playing != null and playing.? == self.cursor) {
            // The track that was removed is the one playing; move on.
            self.engine.playIndex(@min(self.cursor, left - 1));
        }
        self.engine.playlistChanged();
        if (self.cursor >= left and left > 0) self.cursor = left - 1;
        self.toast.set("removed; {d} left", .{left}, 30);
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    fn draw(self: *App, st: engine_mod.Status) void {
        const t = self.theme;
        self.screen.clear(.{ .fg = .{ .rgb = t.text } });

        const w = self.screen.width;
        const h = self.screen.height;
        if (w < 40 or h < 12) {
            self.drawTooSmall();
            return;
        }

        // Layout: header on top, footer on the bottom, and the middle split
        // between the spectrum and the queue.
        const header_h: u16 = 8;
        const footer_h: u16 = 2;
        const middle_h = h - header_h - footer_h;

        const header: Rect = .{ .x = 0, .y = 0, .w = w, .h = header_h };
        // Give the queue the larger share, but never less than 32 columns to
        // the spectrum unless the terminal is narrow.
        const queue_w: u16 = if (w >= 100) @max(w / 2, 40) else if (w >= 70) w / 2 else w;
        const spectrum_w: u16 = w - queue_w;

        self.drawHeader(header, st);

        if (spectrum_w >= 20) {
            self.drawSpectrum(.{ .x = 0, .y = header_h, .w = spectrum_w, .h = middle_h });
            self.drawQueue(.{ .x = spectrum_w, .y = header_h, .w = queue_w, .h = middle_h }, st);
        } else {
            self.drawQueue(.{ .x = 0, .y = header_h, .w = w, .h = middle_h }, st);
        }

        self.drawFooter(.{ .x = 0, .y = h - footer_h, .w = w, .h = footer_h }, st);

        switch (self.view) {
            .player => {},
            .help => self.drawHelpOverlay(),
            .equalizer => self.drawEqOverlay(st),
        }
    }

    fn drawTooSmall(self: *App) void {
        const t = self.theme;
        const msg = "terminal too small";
        self.screen.textCenter(0, self.screen.height / 2, msg, self.screen.width, t.dangerStyle());
    }

    fn drawHeader(self: *App, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const s = &self.screen;

        var title_buf: [96]u8 = undefined;
        const header_title = std.fmt.bufPrint(&title_buf, "zmp", .{}) catch "zmp";
        s.box(r.x, r.y, r.w, r.h, self.border, t.borderStyle(false), header_title);

        // Backend description, inset into the top border. The spaces either
        // side are what separate it from the border run; without them it
        // reads as part of the line.
        const backend = self.engine.backendDescription();
        if (r.w > 34 and backend.len > 0) {
            const max = @min(@as(u16, @intCast(backend.len)), r.w - 18);
            const x = r.x + r.w - 3 - max;
            _ = s.text(x, r.y, " ", 1, t.borderStyle(false));
            const used = s.textEllipsis(x + 1, r.y, backend, max, t.mutedStyle());
            _ = s.text(x + 1 + used, r.y, " ", 1, t.borderStyle(false));
        }

        const in = r.inner();
        if (in.w == 0) return;
        const pad: u16 = 2;
        const cx = in.x + pad;
        const cw = if (in.w > pad * 2) in.w - pad * 2 else in.w;

        // --- track identity ---
        const pl = self.engine.lockPlaylist();
        var title: []const u8 = "nothing queued";
        var artist: []const u8 = "";
        var album: []const u8 = "";
        // Prefer the playing track; when stopped, show whichever track is
        // selected so the header still says something useful.
        const show_index: ?usize = st.track_index orelse
            pl.currentIndex() orelse
            (if (pl.count() > 0) @min(self.cursor, pl.count() - 1) else null);
        if (show_index) |i| {
            if (pl.at(i)) |track| {
                title = track.displayTitle();
                artist = track.displayArtist();
                album = track.album orelse "";
            }
        }
        const queue_count = pl.count();
        const shuffle_on = pl.shuffle;
        const repeat_mode = pl.repeat;
        // Deliberately not `pl.currentIndex()`: during a gapless hand-off
        // the decoder has already advanced the playlist to the next track
        // while the previous one is still playing out of the buffer.
        // `st.track_index` is what the listener is actually hearing.
        const queue_pos: ?usize = st.track_index orelse pl.currentIndex();
        self.engine.unlockPlaylist();

        const marker: []const u8 = switch (st.state) {
            .playing => "\u{25B6}", // ▶
            .paused => "\u{2016}", // ‖
            .stopped => "\u{25A0}", // ■
        };
        _ = s.text(cx, in.y + 1, marker, 2, t.accentStyle());
        _ = s.textEllipsis(cx + 3, in.y + 1, title, cw - 3, .{
            .fg = .{ .rgb = t.accent },
            .bold = true,
        });

        // Artist and album on the next line.
        var sub_buf: [256]u8 = undefined;
        const sub = if (artist.len > 0 and album.len > 0)
            std.fmt.bufPrint(&sub_buf, "{s} \u{2014} {s}", .{ artist, album }) catch artist
        else if (artist.len > 0)
            artist
        else
            album;
        if (sub.len > 0) {
            _ = s.textEllipsis(cx + 3, in.y + 2, sub, cw - 3, t.mutedStyle());
        }

        // Format summary, right-aligned on the same row.
        if (st.codec) |codec| {
            var fmt_buf: [96]u8 = undefined;
            const rate_khz = @as(f64, @floatFromInt(st.src_sample_rate)) / 1000.0;
            const fmt_text = std.fmt.bufPrint(&fmt_buf, "{s} {d:.1} kHz / {d}-bit / {d}ch{s}", .{
                codec.label(),
                rate_khz,
                st.src_bits,
                st.src_channels,
                if (st.resampling) " \u{2192} resampled" else "",
            }) catch "";
            if (fmt_text.len < cw) {
                s.textRight(cx, in.y + 2, fmt_text, cw, t.dimStyle());
            }
        }

        // --- progress ---
        const row = in.y + 4;
        var elapsed_buf: [16]u8 = undefined;
        var total_buf: [16]u8 = undefined;
        const elapsed = time_util.formatClock(&elapsed_buf, st.position_s);
        const total = if (st.duration_s) |d|
            time_util.formatClock(&total_buf, d)
        else
            "--:--";

        _ = s.text(cx, row, elapsed, 8, t.textStyle());
        const time_w: u16 = 8;
        if (cw > time_w * 2 + 4) {
            const bar_x = cx + time_w;
            const bar_w = cw - time_w * 2;
            const fraction: f32 = blk: {
                const d = st.duration_s orelse break :blk 0;
                if (d <= 0) break :blk 0;
                break :blk @floatCast(std.math.clamp(st.position_s / d, 0, 1));
            };
            self.drawProgressBar(bar_x, row, bar_w, fraction);
            s.textRight(bar_x + bar_w, row, total, time_w, t.textStyle());
        }

        // --- status line ---
        // The last usable inner row. The header box is `header_h` tall, so
        // its inner area runs from `in.y` to `in.y + in.h - 1`; writing past
        // that would draw over the bottom border.
        const status_row = in.y + in.h - 1;
        var buf: [256]u8 = undefined;
        const pos_text = if (queue_pos) |qp|
            std.fmt.bufPrint(&buf, "{d}/{d}", .{ qp + 1, queue_count }) catch ""
        else
            std.fmt.bufPrint(&buf, "-/{d}", .{queue_count}) catch "";

        var x = cx;
        x += self.drawChip(x, status_row, st.state.label(), switch (st.state) {
            .playing => t.accent_alt,
            .paused => t.meter_warn,
            .stopped => t.muted,
        });
        x += self.drawChip(x, status_row, pos_text, t.muted);

        var vol_buf: [32]u8 = undefined;
        const vol_text = if (st.muted)
            "muted"
        else
            std.fmt.bufPrint(&vol_buf, "vol {d:.0}%", .{st.volume * 100}) catch "vol";
        x += self.drawChip(x, status_row, vol_text, if (st.muted) t.danger else t.text);

        if (shuffle_on) x += self.drawChip(x, status_row, "shuffle", t.accent);
        if (repeat_mode != .off) {
            var rbuf: [24]u8 = undefined;
            const rt = std.fmt.bufPrint(&rbuf, "repeat {s}", .{repeat_mode.label()}) catch "repeat";
            x += self.drawChip(x, status_row, rt, t.accent);
        }
        if (st.eq_enabled) x += self.drawChip(x, status_row, "eq", t.accent);
        if (st.replaygain_db != 0) {
            var gbuf: [24]u8 = undefined;
            const gt = std.fmt.bufPrint(&gbuf, "rg {d:.1}dB", .{st.replaygain_db}) catch "rg";
            x += self.drawChip(x, status_row, gt, t.muted);
        }

        // Buffer health, right-aligned.
        if (cw > 24) {
            var bbuf: [32]u8 = undefined;
            const btext = std.fmt.bufPrint(&bbuf, "buf {d:.0}%", .{st.buffer_fill * 100}) catch "";
            const color = if (st.buffer_fill < 0.1) t.danger else t.muted;
            s.textRight(cx, status_row, btext, cw, .{ .fg = .{ .rgb = color } });
        }
    }

    /// A small labelled pill. Returns the columns consumed.
    fn drawChip(self: *App, x: u16, y: u16, label: []const u8, color: Rgb) u16 {
        if (label.len == 0) return 0;
        const w = screen_mod.displayWidth(label);
        if (x + w + 2 >= self.screen.width) return 0;
        _ = self.screen.text(x, y, label, w, .{ .fg = .{ .rgb = color } });
        return w + 2;
    }

    fn drawProgressBar(self: *App, x: u16, y: u16, w: u16, fraction: f32) void {
        if (w == 0) return;
        const t = self.theme;
        const filled_f = fraction * @as(f32, @floatFromInt(w));
        const filled: u16 = @intFromFloat(@floor(filled_f));

        var i: u16 = 0;
        while (i < w) : (i += 1) {
            if (i < filled) {
                self.screen.set(x + i, y, '\u{2501}', .{ .fg = .{ .rgb = t.accent_alt } }); // ━
            } else if (i == filled and filled < w) {
                // The playhead.
                self.screen.set(x + i, y, '\u{25CF}', .{
                    .fg = .{ .rgb = t.accent },
                    .bold = true,
                }); // ●
            } else {
                self.screen.set(x + i, y, '\u{2500}', .{ .fg = .{ .rgb = t.dim } }); // ─
            }
        }
    }

    fn drawSpectrum(self: *App, r: Rect) void {
        const t = self.theme;
        const s = &self.screen;
        s.box(r.x, r.y, r.w, r.h, self.border, t.borderStyle(false), "Spectrum");

        const in = r.inner();
        if (in.w < 4 or in.h < 3) return;

        const an = self.engine.analyzerPtr() orelse {
            s.textCenter(in.x, in.y + in.h / 2, "analyzer disabled", in.w, t.mutedStyle());
            return;
        };

        const bands = an.bandCount();
        if (bands == 0) return;

        // One column per band, widened to fill the panel when there is room.
        const label_rows: u16 = 1;
        const plot_h = if (in.h > label_rows) in.h - label_rows else in.h;
        const col_w: u16 = @max(1, in.w / @as(u16, @intCast(bands)));
        const used_w: u16 = @min(in.w, col_w * @as(u16, @intCast(bands)));
        const x0 = in.x + (in.w - used_w) / 2;

        var b: usize = 0;
        while (b < bands) : (b += 1) {
            const level = an.bandLevel(b);
            const peak = an.bandPeak(b);
            // Each row holds eight sub-steps, so a bar can grow smoothly.
            const total_steps = @as(f32, @floatFromInt(plot_h)) * 8.0;
            const steps = level * total_steps;

            var col: u16 = 0;
            while (col < col_w) : (col += 1) {
                const x = x0 + @as(u16, @intCast(b)) * col_w + col;
                if (x >= in.x + in.w) break;

                var row: u16 = 0;
                while (row < plot_h) : (row += 1) {
                    // Row 0 is the bottom of the plot.
                    const y = in.y + plot_h - 1 - row;
                    const row_base = @as(f32, @floatFromInt(row)) * 8.0;
                    const in_row = steps - row_base;

                    const height_fraction = @as(f32, @floatFromInt(row + 1)) /
                        @as(f32, @floatFromInt(plot_h));
                    const color = t.energyColor(height_fraction);

                    if (in_row >= 8.0) {
                        s.set(x, y, '\u{2588}', .{ .fg = .{ .rgb = color } }); // █
                    } else if (in_row > 0.3) {
                        s.set(x, y, screen_mod.blockFor(in_row / 8.0), .{
                            .fg = .{ .rgb = color },
                        });
                    } else {
                        // Peak marker floats above the bar.
                        const peak_row: f32 = peak * @as(f32, @floatFromInt(plot_h));
                        const this_row: f32 = @floatFromInt(row);
                        if (peak > 0.02 and peak_row >= this_row and peak_row < this_row + 1.0) {
                            s.set(x, y, '\u{2581}', .{ .fg = .{ .rgb = t.dim } }); // ▁
                        }
                    }
                }
            }
        }

        // Frequency labels along the bottom.
        if (in.h > 2) {
            const y = in.y + in.h - 1;
            const marks = [_]struct { hz: f32, label: []const u8 }{
                .{ .hz = 31, .label = "31" },
                .{ .hz = 125, .label = "125" },
                .{ .hz = 500, .label = "500" },
                .{ .hz = 2000, .label = "2k" },
                .{ .hz = 8000, .label = "8k" },
                .{ .hz = 16000, .label = "16k" },
            };
            for (marks) |m| {
                // Find the band containing this frequency.
                var band: ?usize = null;
                for (0..bands) |i| {
                    const range = analyzer_mod.bandRange(i, bands);
                    if (m.hz >= range.lo and m.hz < range.hi) band = i;
                }
                const bi = band orelse continue;
                const bx = x0 + @as(u16, @intCast(bi)) * col_w;
                const lw = screen_mod.displayWidth(m.label);
                if (bx + lw <= in.x + in.w) {
                    _ = s.text(bx, y, m.label, lw, t.dimStyle());
                }
            }
        }
    }

    fn drawQueue(self: *App, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const s = &self.screen;

        const pl = self.engine.lockPlaylist();
        defer self.engine.unlockPlaylist();

        const n = pl.count();
        var title_buf: [48]u8 = undefined;
        const title = if (st.track_index) |i|
            std.fmt.bufPrint(&title_buf, "Queue {d}/{d}", .{ i + 1, n }) catch "Queue"
        else
            std.fmt.bufPrint(&title_buf, "Queue {d}", .{n}) catch "Queue";

        s.box(r.x, r.y, r.w, r.h, self.border, t.borderStyle(self.view == .player), title);

        const in = r.inner();
        if (in.w < 8 or in.h < 1) return;

        if (n == 0) {
            s.textCenter(in.x, in.y + in.h / 2, "queue is empty", in.w, t.mutedStyle());
            return;
        }

        // Keep the cursor on screen.
        const rows: usize = in.h;
        if (self.cursor < self.scroll) {
            self.scroll = self.cursor;
        } else if (self.cursor >= self.scroll + rows) {
            self.scroll = self.cursor - rows + 1;
        }
        if (self.scroll + rows > n) {
            self.scroll = n -| rows;
        }

        // Same reasoning as in the header: mark the track being heard, not
        // the one the decoder has moved on to.
        const playing = st.track_index orelse pl.currentIndex();

        var row: usize = 0;
        while (row < rows and self.scroll + row < n) : (row += 1) {
            const index = self.scroll + row;
            const track = pl.at(index) orelse continue;
            const y = in.y + @as(u16, @intCast(row));

            const is_playing = playing != null and playing.? == index;
            const is_cursor = index == self.cursor;

            const style: Style = if (is_cursor)
                t.selectedStyle()
            else if (is_playing)
                .{ .fg = .{ .rgb = t.accent }, .bold = true }
            else
                t.textStyle();

            // Paint the whole row so the selection reads as a band.
            if (is_cursor) {
                s.fill(in.x, y, in.w, 1, ' ', style);
            }

            var x = in.x;
            // Playing marker.
            const mark: []const u8 = if (is_playing) "\u{25B8}" else " ";
            _ = s.text(x, y, mark, 1, if (is_playing) .{
                .fg = .{ .rgb = t.accent },
                .bg = style.bg,
                .bold = true,
            } else style);
            x += 2;

            // Index.
            var idx_buf: [12]u8 = undefined;
            const idx_text = std.fmt.bufPrint(&idx_buf, "{d:>3}", .{index + 1}) catch "";
            var idx_style = style;
            if (!is_cursor and !is_playing) idx_style = t.dimStyle();
            _ = s.text(x, y, idx_text, 3, idx_style);
            x += 4;

            // Duration on the right.
            var dur_buf: [16]u8 = undefined;
            const dur_text = if (track.duration_s) |d|
                time_util.formatClock(&dur_buf, d)
            else
                "--:--";
            const dur_w: u16 = 6;

            const text_w = if (in.x + in.w > x + dur_w + 1)
                in.x + in.w - x - dur_w - 1
            else
                0;

            if (text_w > 0) {
                // "Artist — Title" when the artist is known and there is room.
                const artist = track.displayArtist();
                if (artist.len > 0 and text_w > 24) {
                    var line_buf: [512]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "{s} \u{2014} {s}", .{
                        artist,
                        track.displayTitle(),
                    }) catch track.displayTitle();
                    _ = s.textEllipsis(x, y, line, text_w, style);
                } else {
                    _ = s.textEllipsis(x, y, track.displayTitle(), text_w, style);
                }
            }

            var dur_style = style;
            if (!is_cursor and !is_playing) dur_style = t.dimStyle();
            s.textRight(in.x + in.w - dur_w - 1, y, dur_text, dur_w, dur_style);
        }

        // Scroll indicator.
        if (n > rows and in.h >= 3) {
            const bar_x = r.x + r.w - 1;
            const track_h = in.h;
            const thumb_h: u16 = @max(1, @as(u16, @intCast((rows * track_h) / n)));
            const max_scroll = n - rows;
            const offset: u16 = if (max_scroll == 0)
                0
            else
                @intCast((self.scroll * (track_h - thumb_h)) / max_scroll);
            var i: u16 = 0;
            while (i < thumb_h) : (i += 1) {
                s.set(bar_x, in.y + offset + i, '\u{2503}', .{ .fg = .{ .rgb = t.border_focus } });
            }
        }
    }

    fn drawFooter(self: *App, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const s = &self.screen;
        const y = r.y;

        // Level meters on the left.
        var x: u16 = 1;
        if (self.engine.analyzerPtr()) |an| {
            const channels = @min(an.channelCount(), 2);
            const labels = [_][]const u8{ "L", "R" };
            const meter_w: u16 = if (r.w > 60) 12 else 8;
            for (0..channels) |ch| {
                if (x + meter_w + 3 >= r.w) break;
                _ = s.text(x, y, labels[ch], 1, t.mutedStyle());
                x += 2;
                self.drawMeter(x, y, meter_w, an.meterLevel(ch), an.meterPeak(ch));
                x += meter_w + 2;
            }
        }

        // A toast, or the key hints.
        const hint = "space play  n/p track  \u{2190}\u{2192} seek  \u{2191}\u{2193} queue  e eq  ? help  q quit";
        if (self.toast.text()) |msg| {
            if (x + screen_mod.displayWidth(msg) < r.w) {
                _ = s.text(x + 1, y, msg, r.w - x - 1, t.accentStyle());
            }
        } else if (x + screen_mod.displayWidth(hint) < r.w) {
            s.textRight(x, y, hint, r.w - x - 1, t.dimStyle());
        }

        // Error line, if anything went wrong.
        if (st.last_error != .none and r.h > 1) {
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "last error: {s} ({d})", .{
                st.last_error.label(),
                st.decode_errors,
            }) catch "";
            _ = s.textEllipsis(1, y + 1, text, r.w - 2, t.dangerStyle());
        } else if (st.underruns > 0 and r.h > 1) {
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "buffer underruns: {d}", .{st.underruns}) catch "";
            _ = s.textEllipsis(1, y + 1, text, r.w - 2, t.mutedStyle());
        }
    }

    fn drawMeter(self: *App, x: u16, y: u16, w: u16, level: f32, peak: f32) void {
        const t = self.theme;
        const filled: u16 = @intFromFloat(@round(std.math.clamp(level, 0, 1) *
            @as(f32, @floatFromInt(w))));
        const peak_col: u16 = @intFromFloat(@round(std.math.clamp(peak, 0, 1) *
            @as(f32, @floatFromInt(w))));

        var i: u16 = 0;
        while (i < w) : (i += 1) {
            const pos = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(w));
            if (i < filled) {
                self.screen.set(x + i, y, '\u{2588}', .{ .fg = .{ .rgb = t.meterColor(pos) } });
            } else if (peak_col > 0 and i == peak_col - 1) {
                self.screen.set(x + i, y, '\u{2502}', .{ .fg = .{ .rgb = t.meterColor(pos) } });
            } else {
                self.screen.set(x + i, y, '\u{2591}', .{ .fg = .{ .rgb = t.dim } });
            }
        }
    }

    fn drawHelpOverlay(self: *App) void {
        const t = self.theme;
        const s = &self.screen;

        const lines = [_][]const u8{
            "",
            "  Playback",
            "    space        play / pause",
            "    n / p        next / previous track",
            "    enter        play the selected track",
            "    0            restart the current track",
            "    left/right   seek 5 seconds",
            "    [ / ]        seek 30 seconds",
            "    { / }        seek 60 seconds",
            "",
            "  Queue",
            "    up/down, j/k move the cursor",
            "    pgup/pgdn    move ten rows",
            "    g / G        first / last track",
            "    d, delete    remove the selected track",
            "    escape       follow the playing track again",
            "",
            "  Sound",
            "    + / -        volume",
            "    m            mute",
            "    e            equalizer on / off",
            "    E, F2        equalizer editor",
            "    l            output limiter on / off",
            "",
            "  Other",
            "    s            shuffle",
            "    r            repeat: off / all / one",
            "    t            cycle theme",
            "    ctrl+l       force a full redraw",
            "    ? , F1       this help",
            "    q, ctrl+c    quit",
            "",
        };

        const box_h: u16 = @intCast(@min(lines.len + 2, self.screen.height));
        const box_w: u16 = @min(60, self.screen.width);
        const x = (self.screen.width - box_w) / 2;
        const y = (self.screen.height - box_h) / 2;

        s.fill(x, y, box_w, box_h, ' ', .{ .bg = .{ .rgb = t.selection_bg } });
        s.box(x, y, box_w, box_h, .double, t.borderStyle(true), "Keys");

        const base: Style = .{
            .fg = .{ .rgb = t.text },
            .bg = .{ .rgb = t.selection_bg },
        };
        const heading: Style = .{
            .fg = .{ .rgb = t.accent },
            .bg = .{ .rgb = t.selection_bg },
            .bold = true,
        };

        var row: u16 = 0;
        while (row < box_h - 2 and row < lines.len) : (row += 1) {
            const line = lines[row];
            const is_heading = line.len > 2 and line[2] != ' ';
            _ = s.textEllipsis(x + 1, y + 1 + row, line, box_w - 2, if (is_heading) heading else base);
        }
    }

    fn drawEqOverlay(self: *App, st: engine_mod.Status) void {
        const t = self.theme;
        const s = &self.screen;

        const box_w: u16 = @min(66, self.screen.width);
        const box_h: u16 = @min(20, self.screen.height);
        const x = (self.screen.width - box_w) / 2;
        const y = (self.screen.height - box_h) / 2;

        s.fill(x, y, box_w, box_h, ' ', .{ .bg = .{ .rgb = t.selection_bg } });
        s.box(x, y, box_w, box_h, .double, t.borderStyle(true), "Equalizer");

        const base: Style = .{
            .fg = .{ .rgb = t.text },
            .bg = .{ .rgb = t.selection_bg },
        };
        const muted: Style = .{
            .fg = .{ .rgb = t.muted },
            .bg = .{ .rgb = t.selection_bg },
        };

        const in: Rect = .{ .x = x + 2, .y = y + 1, .w = box_w - 4, .h = box_h - 2 };

        var header_buf: [96]u8 = undefined;
        // std.fmt has no "always show the sign" flag, so the sign is written
        // separately and the magnitude formatted on its own.
        const header = std.fmt.bufPrint(&header_buf, "{s}   preamp {c}{d:.1} dB", .{
            if (st.eq_enabled) "enabled" else "disabled (press e)",
            signChar(st.eq_preamp_db),
            @abs(st.eq_preamp_db),
        }) catch "";
        _ = s.textEllipsis(in.x, in.y, header, in.w, if (st.eq_enabled) .{
            .fg = .{ .rgb = t.accent_alt },
            .bg = .{ .rgb = t.selection_bg },
            .bold = true,
        } else muted);

        // Vertical sliders, one per band.
        const slider_h: u16 = @max(5, in.h - 6);
        const band_cols: u16 = @max(4, in.w / equalizer.band_count);
        const plot_y = in.y + 2;

        for (0..equalizer.band_count) |b| {
            const bx = in.x + @as(u16, @intCast(b)) * band_cols + band_cols / 2;
            if (bx >= in.x + in.w) break;

            const gain = st.eq_gains[b];
            const span = equalizer.max_gain_db - equalizer.min_gain_db;
            // 0 dB sits in the middle of the slider.
            const norm = (gain - equalizer.min_gain_db) / span;
            const handle_row: u16 = @intFromFloat(@round(
                (1.0 - std.math.clamp(norm, 0, 1)) * @as(f32, @floatFromInt(slider_h - 1)),
            ));
            const zero_row: u16 = (slider_h - 1) / 2;

            const is_selected = b == self.eq_band;

            var row: u16 = 0;
            while (row < slider_h) : (row += 1) {
                const cy = plot_y + row;
                var ch: u21 = '\u{2502}'; // │
                var style = muted;
                if (row == handle_row) {
                    ch = '\u{25AC}'; // ▬
                    style = .{
                        .fg = .{ .rgb = if (is_selected) t.accent else t.accent_alt },
                        .bg = .{ .rgb = t.selection_bg },
                        .bold = true,
                    };
                } else if (row == zero_row) {
                    ch = '\u{00B7}'; // ·
                }
                s.set(bx, cy, ch, style);
            }

            // Centre frequency label.
            var label_buf: [12]u8 = undefined;
            const hz = equalizer.centers[b];
            const label = if (hz >= 1000)
                std.fmt.bufPrint(&label_buf, "{d:.0}k", .{hz / 1000}) catch ""
            else
                std.fmt.bufPrint(&label_buf, "{d:.0}", .{hz}) catch "";
            const lw = screen_mod.displayWidth(label);
            const lx = if (bx >= lw / 2) bx - lw / 2 else bx;
            _ = s.text(lx, plot_y + slider_h, label, lw, if (is_selected) .{
                .fg = .{ .rgb = t.accent },
                .bg = .{ .rgb = t.selection_bg },
                .bold = true,
            } else muted);

            // Gain readout for the selected band only, to avoid clutter.
            if (is_selected) {
                var gain_buf: [16]u8 = undefined;
                const gt = std.fmt.bufPrint(&gain_buf, "{c}{d:.0}", .{
                    signChar(gain),
                    @abs(gain),
                }) catch "";
                const gw = screen_mod.displayWidth(gt);
                const gx = if (bx >= gw / 2) bx - gw / 2 else bx;
                _ = s.text(gx, plot_y + slider_h + 1, gt, gw, .{
                    .fg = .{ .rgb = t.accent },
                    .bg = .{ .rgb = t.selection_bg },
                    .bold = true,
                });
            }
        }

        const hint = "left/right band   up/down gain   1-9 presets   0 flat   E close";
        _ = s.textEllipsis(in.x, in.y + in.h - 1, hint, in.w, base);
    }
};

const testing = std.testing;

test "rect inner shrinks by the border" {
    const r: Rect = .{ .x = 2, .y = 3, .w = 10, .h = 6 };
    const in = r.inner();
    try testing.expectEqual(@as(u16, 3), in.x);
    try testing.expectEqual(@as(u16, 4), in.y);
    try testing.expectEqual(@as(u16, 8), in.w);
    try testing.expectEqual(@as(u16, 4), in.h);

    // Degenerate rects collapse rather than underflowing.
    const tiny: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    try testing.expectEqual(@as(u16, 0), tiny.inner().w);
}

test "toast expires" {
    var t: Toast = .{};
    try testing.expect(t.text() == null);
    t.set("hello {d}", .{42}, 2);
    try testing.expectEqualStrings("hello 42", t.text().?);
    t.tick();
    try testing.expect(t.text() != null);
    t.tick();
    try testing.expect(t.text() == null);
}

test "toast truncates rather than overflowing" {
    var t: Toast = .{};
    const long: [400]u8 = @splat('x');
    t.set("{s}", .{long}, 10);
    // The format failed, so nothing is shown instead of a buffer overrun.
    try testing.expect(t.text() == null);
}

test "signed decibel display" {
    try testing.expectEqual(@as(u8, '+'), signChar(0));
    try testing.expectEqual(@as(u8, '+'), signChar(3.5));
    try testing.expectEqual(@as(u8, '-'), signChar(-3.5));
}

/// Flatten a drawn screen into one string, so a test can look for text.
fn screenText(gpa: Allocator, s: *const Screen) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var y: u16 = 0;
    while (y < s.height) : (y += 1) {
        var x: u16 = 0;
        while (x < s.width) : (x += 1) {
            const cell = s.get(x, y).?;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch 0;
            try list.appendSlice(gpa, buf[0..n]);
        }
        try list.append(gpa, '\n');
    }
    return list.toOwnedSlice(gpa);
}

test "an empty player draws its frame and says the queue is empty" {
    const gpa = testing.allocator;
    const io = testing.io;

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 12,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 100, 30, .dark);
    defer app.deinit();

    app.drawFrame();
    const text = try screenText(gpa, &app.screen);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "zmp") != null);
    try testing.expect(std.mem.indexOf(u8, text, "nothing queued") != null);
    try testing.expect(std.mem.indexOf(u8, text, "queue is empty") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Spectrum") != null);
    try testing.expect(std.mem.indexOf(u8, text, "stopped") != null);
    // The progress bar shows a zero-length time on both sides.
    try testing.expect(std.mem.indexOf(u8, text, "0:00") != null);
}

test "a queued track appears in the header and the list" {
    const gpa = testing.allocator;
    const io = testing.io;

    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.appendTrack(.{
            .path = "a/Milestones.flac",
            .title = "Milestones",
            .artist = "Miles Davis",
            .album = "Milestones",
            .duration_s = 348,
        });
        _ = try pl.appendTrack(.{
            .path = "a/Sid.flac",
            .title = "Sid's Ahead",
            .artist = "Miles Davis",
            .duration_s = 790,
        });
    }

    var app = try App.initHeadless(gpa, io, engine, 110, 28, .dark);
    defer app.deinit();
    app.drawFrame();

    const text = try screenText(gpa, &app.screen);
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Milestones") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Miles Davis") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Sid's Ahead") != null);
    // Durations are rendered as clock times.
    try testing.expect(std.mem.indexOf(u8, text, "5:48") != null);
    try testing.expect(std.mem.indexOf(u8, text, "13:10") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Queue 2") != null);
}

test "the header status line stays inside its box" {
    // Regression: the status row was computed as a fixed offset and landed on
    // the bottom border, so the frame read as "╰──stopped──vol 70%──╯".
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.appendTrack(.{ .path = "x.flac", .title = "X", .duration_s = 100 });
    }

    const width: u16 = 100;
    var app = try App.initHeadless(gpa, io, engine, width, 30, .dark);
    defer app.deinit();
    app.drawFrame();

    // The header occupies rows 0..7, so row 7 is its bottom border and must
    // contain nothing but box-drawing characters.
    const border_row: u16 = 7;
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        const ch = app.screen.get(x, border_row).?.ch;
        const is_border = ch == '\u{2500}' or ch == '\u{2570}' or ch == '\u{256F}';
        if (!is_border) {
            std.debug.print(
                "row {d} column {d} holds U+{X:0>4}, not a border character\n",
                .{ border_row, x, ch },
            );
            return error.TestUnexpectedResult;
        }
    }

    // And the status text really is on the row above it. The engine here was
    // never started, so the state chip reads "stopped".
    const needle = "stopped";
    var found = false;
    var cx: u16 = 0;
    while (cx + needle.len < width) : (cx += 1) {
        var match = true;
        for (needle, 0..) |want, k| {
            if (app.screen.get(cx + @as(u16, @intCast(k)), border_row - 1).?.ch != want) {
                match = false;
                break;
            }
        }
        if (match) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "a tiny terminal says so rather than drawing a broken frame" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 20, 6, .dark);
    defer app.deinit();
    app.drawFrame();

    const text = try screenText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "too small") != null);
}

test "the help overlay lists its keys" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 100, 40, .dark);
    defer app.deinit();
    app.handleKey(.{ .char = '?' });
    try testing.expectEqual(View.help, app.view);
    app.drawFrame();

    const text = try screenText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Keys") != null);
    try testing.expect(std.mem.indexOf(u8, text, "play / pause") != null);
    try testing.expect(std.mem.indexOf(u8, text, "shuffle") != null);

    // Escape closes it.
    app.handleKey(.escape);
    try testing.expectEqual(View.player, app.view);
}

test "the equalizer overlay draws its sliders and labels" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 100, 34, .dark);
    defer app.deinit();
    app.handleKey(.{ .char = 'E' });
    try testing.expectEqual(View.equalizer, app.view);
    app.drawFrame();

    const text = try screenText(gpa, &app.screen);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Equalizer") != null);
    // Band centre labels.
    try testing.expect(std.mem.indexOf(u8, text, "16k") != null);
    try testing.expect(std.mem.indexOf(u8, text, "presets") != null);
}

test "equalizer keys move between bands and wrap" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 100, 34, .dark);
    defer app.deinit();
    app.view = .equalizer;

    try testing.expectEqual(@as(usize, 0), app.eq_band);
    app.handleKey(.right);
    try testing.expectEqual(@as(usize, 1), app.eq_band);
    app.handleKey(.left);
    app.handleKey(.left); // wraps to the top band
    try testing.expectEqual(equalizer.band_count - 1, app.eq_band);
}

test "queue navigation keys move the cursor and stop at the ends" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        for (0..5) |i| {
            var buf: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "t{d}.flac", .{i});
            _ = try pl.append(path);
        }
    }

    var app = try App.initHeadless(gpa, io, engine, 100, 30, .dark);
    defer app.deinit();

    app.handleKey(.down);
    try testing.expectEqual(@as(usize, 1), app.cursor);
    // Moving the cursor stops it following playback.
    try testing.expect(!app.follow_playback);

    app.handleKey(.{ .char = 'j' });
    try testing.expectEqual(@as(usize, 2), app.cursor);
    app.handleKey(.{ .char = 'k' });
    try testing.expectEqual(@as(usize, 1), app.cursor);

    app.handleKey(.{ .char = 'G' });
    try testing.expectEqual(@as(usize, 4), app.cursor);
    app.handleKey(.down); // already at the end
    try testing.expectEqual(@as(usize, 4), app.cursor);

    app.handleKey(.{ .char = 'g' });
    try testing.expectEqual(@as(usize, 0), app.cursor);
    app.handleKey(.up); // already at the start
    try testing.expectEqual(@as(usize, 0), app.cursor);

    // Escape resumes following.
    app.handleKey(.escape);
    try testing.expect(app.follow_playback);
}

test "quit keys set the flag" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 80, 24, .dark);
    defer app.deinit();
    try testing.expect(!app.quit_requested);
    app.handleKey(.{ .char = 'q' });
    try testing.expect(app.quit_requested);

    var app2 = try App.initHeadless(gpa, io, engine, 80, 24, .dark);
    defer app2.deinit();
    app2.handleKey(.{ .ctrl = 'c' });
    try testing.expect(app2.quit_requested);
}

test "removing the selected track shrinks the queue" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.append("one.flac");
        _ = try pl.append("two.flac");
        _ = try pl.append("three.flac");
    }

    var app = try App.initHeadless(gpa, io, engine, 90, 26, .dark);
    defer app.deinit();
    app.handleKey(.down); // select "two"
    app.handleKey(.{ .char = 'd' });

    const pl = engine.lockPlaylist();
    defer engine.unlockPlaylist();
    try testing.expectEqual(@as(usize, 2), pl.count());
    try testing.expectEqualStrings("one.flac", pl.at(0).?.path);
    try testing.expectEqualStrings("three.flac", pl.at(1).?.path);
}

test "the theme key cycles through all three palettes" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 80, 24, .dark);
    defer app.deinit();
    try testing.expectEqual(theme_mod.Kind.dark, app.theme.kind);
    app.handleKey(.{ .char = 't' });
    try testing.expectEqual(theme_mod.Kind.light, app.theme.kind);
    app.handleKey(.{ .char = 't' });
    try testing.expectEqual(theme_mod.Kind.mono, app.theme.kind);
    app.handleKey(.{ .char = 't' });
    try testing.expectEqual(theme_mod.Kind.dark, app.theme.kind);
}

test "run refuses to start without a terminal" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 0,
    });
    defer engine.deinit();

    var app = try App.initHeadless(gpa, io, engine, 80, 24, .dark);
    defer app.deinit();
    try testing.expectError(error.NoTerminal, app.run());
}

test "every theme renders a frame without tripping over itself" {
    const gpa = testing.allocator;
    const io = testing.io;
    const engine = try Engine.init(gpa, io, .{
        .backend_kind = .null_sink,
        .analyzer_bands = 16,
    });
    defer engine.deinit();
    {
        const pl = engine.lockPlaylist();
        defer engine.unlockPlaylist();
        _ = try pl.appendTrack(.{ .path = "x.flac", .title = "X", .duration_s = 100 });
    }

    // Also sweep a range of sizes, which is where layout maths tends to break.
    for ([_]theme_mod.Kind{ .dark, .light, .mono }) |kind| {
        for ([_]u16{ 40, 60, 80, 100, 160 }) |w| {
            for ([_]u16{ 12, 20, 30, 50 }) |h| {
                var app = try App.initHeadless(gpa, io, engine, w, h, kind);
                defer app.deinit();
                app.drawFrame();
                app.view = .help;
                app.drawFrame();
                app.view = .equalizer;
                app.drawFrame();
            }
        }
    }
}
