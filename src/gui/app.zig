//! The desktop interface.
//!
//! Immediate-mode: every frame walks the layout, draws it, and tests the
//! current mouse position against each control's rectangle. There is no widget
//! tree to keep in sync with the engine, which for an interface that is mostly
//! a live view of audio state is simpler and less error-prone than retained
//! widgets.
//!
//! Interaction state is just a handful of fields — where the pointer is, which
//! control is being dragged — so a click is "the pointer went down inside this
//! rectangle this frame".

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const win32 = @import("win32.zig");
const canvas_mod = @import("canvas.zig");
const theme_mod = @import("theme.zig");

const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;
const Rect = canvas_mod.Rect;
const Font = canvas_mod.Font;
const Theme = theme_mod.Theme;

const zmp = @import("zmp");
const Engine = zmp.player.engine.Engine;
const engine_mod = zmp.player.engine;
const equalizer = zmp.dsp.equalizer;
const analyzer_mod = zmp.dsp.analyzer;
const library = zmp.player.library;
const time_util = zmp.util.time;

pub const Error = error{ OutOfMemory, WindowFailed };

const window_class = std.unicode.utf8ToUtf16LeStringLiteral("ZmpMainWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("zmp");

const min_width: i32 = 760;
const min_height: i32 = 480;

/// Which draggable control has the pointer captured.
const Drag = union(enum) {
    none,
    seek,
    volume,
    eq_band: usize,
    playlist_scroll,
};

/// What the pointer did this frame.
const Pointer = struct {
    x: f32 = -1,
    y: f32 = -1,
    inside: bool = false,
    /// Set for exactly one frame when the button went down.
    pressed: bool = false,
    /// Set for exactly one frame when it was released.
    released: bool = false,
    down: bool = false,
    double_clicked: bool = false,
    wheel: i32 = 0,

    fn over(p: Pointer, r: Rect) bool {
        return p.inside and r.contains(p.x, p.y);
    }

    /// True when a click completed inside `r` this frame.
    fn clicked(p: Pointer, r: Rect) bool {
        return p.released and p.over(r);
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    engine: *Engine,
    theme: Theme,

    hwnd: ?win32.HWND = null,
    canvas: ?Canvas = null,

    font_title: ?Font = null,
    font_body: ?Font = null,
    font_small: ?Font = null,
    font_mono: ?Font = null,
    font_icon: ?Font = null,

    pointer: Pointer = .{},
    drag: Drag = .none,
    /// Where the pointer was when the drag started, for relative drags.
    drag_origin: f32 = 0,

    /// First visible playlist row.
    scroll: f32 = 0,
    /// Row the pointer is over, or null.
    hover_row: ?usize = null,
    selected: usize = 0,

    show_eq: bool = false,
    quit: bool = false,
    /// Set while the user drags the seek bar, so the display follows the
    /// pointer instead of the engine until they let go.
    seek_preview: ?f64 = null,

    /// Remembered so a resize can rebuild the canvas.
    width: i32 = 0,
    height: i32 = 0,

    /// Pending files from a drag-and-drop, applied on the next frame.
    dropped: std.ArrayList([]u8) = .empty,

    status_message: [192]u8 = undefined,
    status_len: usize = 0,
    status_frames: u32 = 0,

    /// Rows that fit in the playlist panel, remembered between frames so
    /// keyboard scrolling can keep the selection visible without needing to
    /// know the layout.
    playlist_rows: f32 = 10,

    const row_height: f32 = 30;
    const timer_id: usize = 1;

    pub fn init(gpa: Allocator, io: Io, engine: *Engine, kind: theme_mod.Kind) Error!App {
        return .{
            .gpa = gpa,
            .io = io,
            .engine = engine,
            .theme = Theme.get(kind),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.dropped.items) |p| self.gpa.free(p);
        self.dropped.deinit(self.gpa);
        self.releaseFonts();
        if (self.canvas) |*c| c.destroy();
        self.* = undefined;
    }

    fn releaseFonts(self: *App) void {
        if (self.font_title) |f| f.destroy();
        if (self.font_body) |f| f.destroy();
        if (self.font_small) |f| f.destroy();
        if (self.font_mono) |f| f.destroy();
        if (self.font_icon) |f| f.destroy();
        self.font_title = null;
        self.font_body = null;
        self.font_small = null;
        self.font_mono = null;
        self.font_icon = null;
    }

    /// Build fonts at a size suited to the window's DPI.
    fn buildFonts(self: *App, dpi: u32) void {
        self.releaseFonts();
        const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        const px = struct {
            fn at(base: f32, s: f32) i32 {
                return @intFromFloat(@round(base * s));
            }
        };
        self.font_title = Font.create("Segoe UI Semibold", px.at(21, scale), .semibold) orelse
            Font.create("Segoe UI", px.at(21, scale), .bold);
        self.font_body = Font.create("Segoe UI", px.at(14, scale), .regular);
        self.font_small = Font.create("Segoe UI", px.at(12, scale), .regular);
        self.font_mono = Font.create("Consolas", px.at(13, scale), .regular) orelse
            Font.create("Courier New", px.at(13, scale), .regular);
        // Segoe UI Symbol carries the transport glyphs.
        self.font_icon = Font.create("Segoe UI Symbol", px.at(16, scale), .regular) orelse
            Font.create("Segoe UI", px.at(16, scale), .regular);
    }

    // -----------------------------------------------------------------------
    // Window lifetime
    // -----------------------------------------------------------------------

    pub fn run(self: *App) Error!void {
        // Ask for per-monitor DPI awareness so the window is not bitmap
        // scaled into blurriness on a high-density display.
        _ = win32.SetProcessDpiAwarenessContext(win32.dpi_per_monitor_v2);

        const instance = win32.GetModuleHandleW(null);

        const class: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC | win32.CS_DBLCLKS,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = win32.LoadIconW(null, win32.IDI_APPLICATION),
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_class,
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&class) == 0) return error.WindowFailed;

        // Open at a comfortable size, centred, but never larger than the
        // screen.
        const screen_w = win32.GetSystemMetrics(win32.SM_CXSCREEN);
        const screen_h = win32.GetSystemMetrics(win32.SM_CYSCREEN);
        const want_w = @min(1180, @max(min_width, screen_w - 160));
        const want_h = @min(760, @max(min_height, screen_h - 160));

        const hwnd = win32.CreateWindowExW(
            win32.WS_EX_ACCEPTFILES | win32.WS_EX_APPWINDOW,
            window_class,
            window_title,
            win32.WS_OVERLAPPEDWINDOW,
            @divTrunc(screen_w - want_w, 2),
            @divTrunc(screen_h - want_h, 2),
            want_w,
            want_h,
            null,
            null,
            instance,
            self,
        ) orelse return error.WindowFailed;
        self.hwnd = hwnd;

        // The window procedure needs to reach back into this struct.
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        win32.DragAcceptFiles(hwnd, win32.TRUE);

        self.buildFonts(win32.GetDpiForWindow(hwnd));
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(hwnd);

        // ~60 Hz repaint, which the spectrum needs to look smooth.
        _ = win32.SetTimer(hwnd, timer_id, 16, null);

        self.setStatus("Drop files here, or press ? for keys", 180);

        var msg: win32.MSG = undefined;
        while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
            if (self.quit) break;
        }

        _ = win32.KillTimer(hwnd, timer_id);
        if (self.hwnd) |h| _ = win32.DestroyWindow(h);
        self.hwnd = null;
    }

    /// Render one frame into an offscreen canvas and write it as a BMP.
    pub fn renderOffscreen(self: *App, width: u16, height: u16, path: []const u8) !void {
        self.buildFonts(96);
        var canvas = Canvas.create(@intCast(width), @intCast(height)) orelse
            return error.WindowFailed;
        defer canvas.destroy();

        self.width = canvas.width;
        self.height = canvas.height;
        // Put the pointer somewhere harmless so no hover state shows.
        self.pointer = .{};
        if (self.engine.analyzerPtr()) |an| _ = an.update();
        self.drawFrame(&canvas);

        const file = try Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(self.io, &buf);
        try canvas.writeBmp(&writer.interface);
        try writer.interface.flush();
    }

    fn ensureCanvas(self: *App, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        if (self.canvas) |*c| {
            if (c.width == width and c.height == height) return;
            c.destroy();
            self.canvas = null;
        }
        self.canvas = Canvas.create(width, height);
        self.width = width;
        self.height = height;
    }

    fn setStatus(self: *App, comptime fmt: []const u8, frames: u32) void {
        self.setStatusArgs(fmt, .{}, frames);
    }

    fn setStatusArgs(self: *App, comptime fmt: []const u8, args: anytype, frames: u32) void {
        const out = std.fmt.bufPrint(&self.status_message, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = out.len;
        self.status_frames = frames;
    }

    fn statusText(self: *const App) ?[]const u8 {
        if (self.status_frames == 0 or self.status_len == 0) return null;
        return self.status_message[0..self.status_len];
    }

    // -----------------------------------------------------------------------
    // Message handling
    // -----------------------------------------------------------------------

    fn windowProc(
        hwnd: win32.HWND,
        msg: u32,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        const raw = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        const self: ?*App = if (raw == 0) null else @ptrFromInt(@as(usize, @bitCast(raw)));

        switch (msg) {
            win32.WM_DESTROY, win32.WM_CLOSE => {
                if (self) |s| s.quit = true;
                win32.PostQuitMessage(0);
                return 0;
            },
            // We paint every pixel ourselves, so letting the system erase
            // first would only cause a flash.
            win32.WM_ERASEBKGND => return 1,
            win32.WM_GETMINMAXINFO => {
                const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                info.ptMinTrackSize = .{ .x = min_width, .y = min_height };
                return 0;
            },
            win32.WM_SIZE => {
                if (self) |s| {
                    var rect: win32.RECT = undefined;
                    if (win32.GetClientRect(hwnd, &rect) != 0) {
                        s.ensureCanvas(rect.width(), rect.height());
                    }
                }
                return 0;
            },
            win32.WM_DPICHANGED => {
                if (self) |s| s.buildFonts(@truncate(wparam & 0xFFFF));
                return 0;
            },
            win32.WM_TIMER, win32.WM_PAINT => {
                if (self) |s| {
                    s.paint(hwnd, msg == win32.WM_PAINT);
                    return 0;
                }
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            win32.WM_MOUSEMOVE => {
                if (self) |s| {
                    s.pointer.x = @floatFromInt(win32.mouseX(lparam));
                    s.pointer.y = @floatFromInt(win32.mouseY(lparam));
                    s.pointer.inside = true;
                    var track: win32.TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                        .dwFlags = win32.TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = win32.TrackMouseEvent(&track);
                }
                return 0;
            },
            win32.WM_MOUSELEAVE => {
                if (self) |s| {
                    s.pointer.inside = false;
                    s.hover_row = null;
                }
                return 0;
            },
            win32.WM_LBUTTONDOWN => {
                if (self) |s| {
                    s.pointer.x = @floatFromInt(win32.mouseX(lparam));
                    s.pointer.y = @floatFromInt(win32.mouseY(lparam));
                    s.pointer.inside = true;
                    s.pointer.pressed = true;
                    s.pointer.down = true;
                    _ = win32.SetCapture(hwnd);
                }
                return 0;
            },
            win32.WM_LBUTTONUP => {
                if (self) |s| {
                    s.pointer.x = @floatFromInt(win32.mouseX(lparam));
                    s.pointer.y = @floatFromInt(win32.mouseY(lparam));
                    s.pointer.released = true;
                    s.pointer.down = false;
                    _ = win32.ReleaseCapture();
                }
                return 0;
            },
            win32.WM_LBUTTONDBLCLK => {
                if (self) |s| {
                    s.pointer.x = @floatFromInt(win32.mouseX(lparam));
                    s.pointer.y = @floatFromInt(win32.mouseY(lparam));
                    s.pointer.inside = true;
                    s.pointer.double_clicked = true;
                }
                return 0;
            },
            win32.WM_MOUSEWHEEL => {
                if (self) |s| s.pointer.wheel += win32.wheelDelta(wparam);
                return 0;
            },
            win32.WM_KEYDOWN => {
                if (self) |s| s.handleVirtualKey(@intCast(wparam));
                return 0;
            },
            win32.WM_CHAR => {
                if (self) |s| s.handleChar(@intCast(wparam & 0xFFFF));
                return 0;
            },
            win32.WM_DROPFILES => {
                if (self) |s| s.handleDrop(@ptrFromInt(wparam));
                return 0;
            },
            else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn paint(self: *App, hwnd: win32.HWND, from_paint_message: bool) void {
        var rect: win32.RECT = undefined;
        if (win32.GetClientRect(hwnd, &rect) == 0) return;
        self.ensureCanvas(rect.width(), rect.height());
        const canvas = if (self.canvas) |*c| c else return;

        if (self.engine.analyzerPtr()) |an| _ = an.update();
        self.applyDroppedFiles();
        self.drawFrame(canvas);

        if (from_paint_message) {
            var ps: win32.PAINTSTRUCT = undefined;
            if (win32.BeginPaint(hwnd, &ps)) |hdc| {
                canvas.present(hdc);
                _ = win32.EndPaint(hwnd, &ps);
            }
        } else {
            // On the timer, blit directly rather than invalidating; going
            // through WM_PAINT would double the work for no benefit.
            var ps: win32.PAINTSTRUCT = undefined;
            if (win32.BeginPaint(hwnd, &ps)) |hdc| {
                canvas.present(hdc);
                _ = win32.EndPaint(hwnd, &ps);
            }
            _ = win32.InvalidateRect(hwnd, null, win32.FALSE);
        }

        // One-shot pointer events have now been seen by the layout.
        self.pointer.pressed = false;
        self.pointer.released = false;
        self.pointer.double_clicked = false;
        self.pointer.wheel = 0;
        if (self.status_frames > 0) self.status_frames -= 1;
    }

    fn handleDrop(self: *App, drop: win32.HDROP) void {
        defer win32.DragFinish(drop);
        const count = win32.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var wide: [1024]u16 = undefined;
            const n = win32.DragQueryFileW(drop, i, &wide, wide.len);
            if (n == 0 or n >= wide.len) continue;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(self.gpa, wide[0..n]) catch continue;
            self.dropped.append(self.gpa, utf8) catch {
                self.gpa.free(utf8);
                continue;
            };
        }
    }

    /// Scanning a directory touches the file system, so it happens on the
    /// frame after the drop rather than inside the window procedure.
    fn applyDroppedFiles(self: *App) void {
        if (self.dropped.items.len == 0) return;

        var added: usize = 0;
        {
            const pl = self.engine.lockPlaylist();
            defer self.engine.unlockPlaylist();
            const was_empty = pl.count() == 0;
            for (self.dropped.items) |path| {
                const result = library.add(self.gpa, self.io, pl, path, .{}) catch continue;
                added += result.added;
            }
            if (was_empty and pl.count() > 0) _ = pl.start();
        }
        for (self.dropped.items) |p| self.gpa.free(p);
        self.dropped.clearRetainingCapacity();

        if (added > 0) {
            self.engine.playlistChanged();
            if (self.engine.status().state != .playing) self.engine.play();
            self.setStatusArgs("added {d} track(s)", .{added}, 120);
        } else {
            self.setStatus("nothing playable in that drop", 120);
        }
    }

    // -----------------------------------------------------------------------
    // Keyboard
    // -----------------------------------------------------------------------

    fn handleVirtualKey(self: *App, vk: u32) void {
        const ctrl = win32.isKeyDown(win32.VK_CONTROL);
        switch (vk) {
            win32.VK_SPACE => {
                self.engine.togglePause();
                self.setStatusArgs("{s}", .{self.engine.status().state.label()}, 60);
            },
            win32.VK_LEFT => self.engine.seekBy(if (ctrl) -30 else -5),
            win32.VK_RIGHT => self.engine.seekBy(if (ctrl) 30 else 5),
            win32.VK_UP => self.moveSelection(-1),
            win32.VK_DOWN => self.moveSelection(1),
            win32.VK_PRIOR => self.moveSelection(-10),
            win32.VK_NEXT => self.moveSelection(10),
            win32.VK_HOME => self.setSelection(0),
            win32.VK_END => {
                const n = self.trackCount();
                if (n > 0) self.setSelection(n - 1);
            },
            win32.VK_RETURN => self.playSelection(),
            win32.VK_DELETE => self.removeSelection(),
            win32.VK_ESCAPE => {
                if (self.show_eq) self.show_eq = false;
            },
            win32.VK_F1 => self.setStatus(
                "space play  <- -> seek  up/down select  enter play  del remove  e eq  t theme",
                300,
            ),
            else => {},
        }
    }

    fn handleChar(self: *App, c: u16) void {
        switch (c) {
            'n', 'N' => self.engine.nextTrack(),
            'p', 'P' => self.engine.previousTrack(),
            '+', '=' => {
                self.engine.nudgeVolume(0.05);
                self.showVolume();
            },
            '-', '_' => {
                self.engine.nudgeVolume(-0.05);
                self.showVolume();
            },
            'm', 'M' => {
                self.engine.toggleMute();
                self.setStatus("mute toggled", 60);
            },
            's', 'S' => {
                const pl = self.engine.lockPlaylist();
                pl.toggleShuffle();
                const on = pl.shuffle;
                self.engine.unlockPlaylist();
                self.setStatusArgs("shuffle {s}", .{if (on) "on" else "off"}, 90);
            },
            'r', 'R' => {
                const pl = self.engine.lockPlaylist();
                pl.cycleRepeat();
                const mode = pl.repeat;
                self.engine.unlockPlaylist();
                self.setStatusArgs("repeat {s}", .{mode.label()}, 90);
            },
            'e', 'E' => self.show_eq = !self.show_eq,
            'l', 'L' => {
                const st = self.engine.status();
                self.engine.setLimiterEnabled(!st.limiter_enabled);
                self.setStatusArgs(
                    "limiter {s}",
                    .{if (st.limiter_enabled) "off" else "on"},
                    90,
                );
            },
            't', 'T' => {
                self.theme = self.theme.next();
                self.setStatusArgs("theme: {s}", .{self.theme.kind.label()}, 90);
            },
            '?' => self.setStatus(
                "space play  <- -> seek  up/down select  enter play  del remove  e eq  t theme",
                300,
            ),
            'q', 'Q' => self.quit = true,
            else => {},
        }
    }

    fn showVolume(self: *App) void {
        self.setStatusArgs("volume {d:.0}%", .{self.engine.status().volume * 100}, 60);
    }

    fn trackCount(self: *App) usize {
        const pl = self.engine.lockPlaylist();
        defer self.engine.unlockPlaylist();
        return pl.count();
    }

    fn moveSelection(self: *App, delta: i32) void {
        const n = self.trackCount();
        if (n == 0) return;
        const cur: i64 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(n - 1))));
        self.scrollToSelection();
    }

    fn setSelection(self: *App, index: usize) void {
        const n = self.trackCount();
        if (n == 0) return;
        self.selected = @min(index, n - 1);
        self.scrollToSelection();
    }

    fn scrollToSelection(self: *App) void {
        // The visible row count is known only during layout, so approximate
        // using the last known playlist viewport height.
        const rows = @max(1.0, self.playlist_rows);
        const sel: f32 = @floatFromInt(self.selected);
        if (sel < self.scroll) self.scroll = sel;
        if (sel >= self.scroll + rows) self.scroll = sel - rows + 1;
        if (self.scroll < 0) self.scroll = 0;
    }

    fn playSelection(self: *App) void {
        if (self.trackCount() == 0) return;
        self.engine.playIndex(self.selected);
    }

    fn removeSelection(self: *App) void {
        const pl = self.engine.lockPlaylist();
        const n = pl.count();
        if (n == 0) {
            self.engine.unlockPlaylist();
            return;
        }
        const playing = pl.currentIndex();
        pl.remove(self.selected);
        const left = pl.count();
        self.engine.unlockPlaylist();

        if (left == 0) {
            self.engine.stop();
        } else if (playing != null and playing.? == self.selected) {
            self.engine.playIndex(@min(self.selected, left - 1));
        }
        self.engine.playlistChanged();
        if (self.selected >= left and left > 0) self.selected = left - 1;
        self.setStatusArgs("removed; {d} left", .{left}, 90);
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    fn drawFrame(self: *App, c: *Canvas) void {
        const t = self.theme;
        c.resetClip();
        // A very slight vertical gradient stops a large flat window from
        // looking like a dead rectangle.
        c.fillRectGradient(
            c.bounds(),
            t.background.scale(1.08),
            t.background.scale(0.94),
        );

        const st = self.engine.status();
        const pad: f32 = 14;
        var area = c.bounds().inset(pad);

        // Now playing across the top.
        const top = area.splitTop(132);
        self.drawNowPlaying(c, top.top, st);
        area = top.rest;

        const gap: f32 = 12;
        area.y += gap;
        area.h -= gap;

        // Transport strip at the bottom.
        const bottom = area.splitBottom(74);
        self.drawTransport(c, bottom.bottom, st);
        var middle = bottom.rest;
        middle.h -= gap;

        if (self.show_eq) {
            const eq = middle.splitBottom(186);
            self.drawEqualizer(c, eq.bottom, st);
            middle = eq.rest;
            middle.h -= gap;
        }

        // Spectrum on the left, playlist on the right.
        const split: f32 = if (middle.w > 900) middle.w * 0.46 else middle.w * 0.40;
        const left = middle.splitLeft(split);
        self.drawSpectrum(c, left.left, st);
        var right = left.rest;
        right.x += gap;
        right.w -= gap;
        self.drawPlaylist(c, right, st);
    }

    fn panel(self: *App, c: *Canvas, r: Rect, title: ?[]const u8) Rect {
        const t = self.theme;
        c.dropShadow(r, 10, 5, t.shadow);
        c.fillRoundedRect(r, 10, t.surface);
        c.strokeRoundedRect(r, 10, 1, t.outline);

        var inner = r.inset(14);
        if (title) |text| {
            if (self.font_small) |f| {
                const head = inner.splitTop(20);
                _ = c.text(f, head.top, text, t.text_faint, .left, true);
                inner = head.rest;
                inner.y += 6;
                inner.h -= 6;
            }
        }
        return inner;
    }

    fn drawNowPlaying(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const panel_inner = self.panel(c, r, null);

        // Reserve the seek bar's row before anything else, so the artwork and
        // text lay out inside what is left rather than over the top of it.
        const split = panel_inner.splitBottom(28);
        const seek_row = split.bottom;
        var inner = split.rest;
        inner.h -= 4;

        // Album-art placeholder: a rounded tile with a note glyph. Real art
        // would mean decoding embedded images, which the tag reader skips.
        const art_size = @min(inner.h, 84);
        const art = Rect.init(inner.x, inner.y + (inner.h - art_size) / 2, art_size, art_size);
        // Tint the panel surface toward the accent rather than using the
        // accent directly, so the tile stays muted in every theme.
        const tile_top = t.surface_raised.lerp(t.accent, 0.42);
        const tile_bottom = t.surface_raised.lerp(t.accent, 0.18);
        c.fillRoundedRectGradient(art, 8, tile_top, tile_bottom);
        if (self.font_title) |f| {
            // Pick whichever foreground actually contrasts with the tile; in a
            // light theme the normal text colour sits close to the tile's own
            // luminance and would disappear.
            const glyph_color = if (@abs(tile_top.luminance() - t.text.luminance()) > 0.3)
                t.text
            else
                t.text_on_accent;
            _ = c.text(f, art, "\u{266B}", glyph_color.fade(0.85), .center, false);
        }

        var text_area = Rect.init(
            art.right() + 16,
            inner.y,
            inner.w - art_size - 16,
            inner.h,
        );

        // Title, artist, album.
        const pl = self.engine.lockPlaylist();
        var title: []const u8 = "Nothing queued";
        var artist: []const u8 = "";
        var album: []const u8 = "";
        const show: ?usize = st.track_index orelse pl.currentIndex() orelse
            (if (pl.count() > 0) @min(self.selected, pl.count() - 1) else null);
        if (show) |i| {
            if (pl.at(i)) |track| {
                title = track.displayTitle();
                artist = track.displayArtist();
                album = track.album orelse "";
            }
        }
        const count = pl.count();
        const shuffle_on = pl.shuffle;
        const repeat_mode = pl.repeat;
        self.engine.unlockPlaylist();

        const title_row = text_area.splitTop(30);
        if (self.font_title) |f| {
            _ = c.text(f, title_row.top, title, t.text, .left, true);
        }
        text_area = title_row.rest;

        const sub_row = text_area.splitTop(22);
        if (self.font_body) |f| {
            var buf: [512]u8 = undefined;
            const sub = if (artist.len > 0 and album.len > 0)
                std.fmt.bufPrint(&buf, "{s}  \u{2014}  {s}", .{ artist, album }) catch artist
            else if (artist.len > 0)
                artist
            else
                album;
            if (sub.len > 0) _ = c.text(f, sub_row.top, sub, t.text_muted, .left, true);
        }
        text_area = sub_row.rest;

        // Format and flags on one line.
        if (self.font_small) |f| {
            const info_row = text_area.splitTop(20);
            var buf: [256]u8 = undefined;
            if (st.codec) |codec| {
                const text = std.fmt.bufPrint(
                    &buf,
                    "{s}  \u{00B7}  {d:.1} kHz  \u{00B7}  {d}-bit  \u{00B7}  {d}ch{s}",
                    .{
                        codec.label(),
                        @as(f64, @floatFromInt(st.src_sample_rate)) / 1000.0,
                        st.src_bits,
                        st.src_channels,
                        if (st.resampling) "  \u{00B7}  resampled" else "",
                    },
                ) catch "";
                _ = c.text(f, info_row.top, text, t.text_faint, .left, true);
            } else if (count > 0) {
                const text = std.fmt.bufPrint(&buf, "{d} tracks queued", .{count}) catch "";
                _ = c.text(f, info_row.top, text, t.text_faint, .left, true);
            } else {
                _ = c.text(
                    f,
                    info_row.top,
                    "Drop audio files or a folder onto this window",
                    t.text_faint,
                    .left,
                    true,
                );
            }

            // Mode pills, right-aligned.
            var pill_x = info_row.top.right();
            if (st.eq_enabled) pill_x = self.drawPill(c, pill_x, info_row.top.y, "EQ", t.accent);
            if (repeat_mode != .off) {
                const label = switch (repeat_mode) {
                    .all => "REPEAT",
                    .one => "REPEAT 1",
                    .off => "",
                };
                pill_x = self.drawPill(c, pill_x, info_row.top.y, label, t.accent);
            }
            if (shuffle_on) pill_x = self.drawPill(c, pill_x, info_row.top.y, "SHUFFLE", t.accent);
        }

        self.drawSeekBar(c, seek_row, st);
    }

    /// A small rounded label. Returns the x to use for the next pill to its
    /// left, so callers can lay them out right to left.
    fn drawPill(self: *App, c: *Canvas, right_x: f32, y: f32, label: []const u8, color: Color) f32 {
        const f = self.font_small orelse return right_x;
        const w: f32 = @floatFromInt(c.measure(f, label));
        const box = Rect.init(right_x - w - 16, y + 1, w + 16, 17);
        if (box.x < 0) return right_x;
        c.fillRoundedRect(box, 8, color.fade(0.18));
        c.strokeRoundedRect(box, 8, 1, color.fade(0.5));
        _ = c.text(f, box, label, color, .center, false);
        return box.x - 6;
    }

    fn drawSeekBar(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const duration = st.duration_s orelse 0;

        // Clock readouts flank the groove.
        const time_w: f32 = 54;
        var elapsed_buf: [24]u8 = undefined;
        var total_buf: [24]u8 = undefined;
        const shown_pos = self.seek_preview orelse st.position_s;
        const elapsed = time_util.formatClock(&elapsed_buf, shown_pos);
        const total = if (duration > 0)
            time_util.formatClock(&total_buf, duration)
        else
            "--:--";

        if (self.font_mono) |f| {
            _ = c.text(f, Rect.init(r.x, r.y, time_w, r.h), elapsed, t.text_muted, .left, false);
            _ = c.text(
                f,
                Rect.init(r.right() - time_w, r.y, time_w, r.h),
                total,
                t.text_muted,
                .right,
                false,
            );
        }

        const groove = Rect.init(
            r.x + time_w + 6,
            r.centerY() - 3,
            @max(10, r.w - time_w * 2 - 12),
            6,
        );
        // A generous hit area: a 6 px groove is far too thin to click.
        const hit = Rect.init(groove.x, r.y, groove.w, r.h);

        const fraction: f32 = blk: {
            if (duration <= 0) break :blk 0;
            break :blk @floatCast(std.math.clamp(shown_pos / duration, 0, 1));
        };

        c.fillRoundedRect(groove, 3, t.surface_raised);
        if (fraction > 0) {
            c.fillRoundedRectGradient(
                Rect.init(groove.x, groove.y, groove.w * fraction, groove.h),
                3,
                t.accent_hover,
                t.accent,
            );
        }

        const hovering = self.pointer.over(hit);
        const active = self.drag == .seek;
        if (duration > 0 and (hovering or active)) {
            const knob_x = groove.x + groove.w * fraction;
            c.fillCircle(knob_x, groove.centerY(), 7, t.accent);
            c.fillCircle(knob_x, groove.centerY(), 3.5, t.text_on_accent);
        }

        // Dragging: follow the pointer, and only commit the seek on release so
        // the engine is not asked to seek on every mouse move.
        if (duration > 0) {
            if (self.pointer.pressed and hovering) {
                self.drag = .seek;
            }
            if (active) {
                const rel = std.math.clamp(
                    (self.pointer.x - groove.x) / @max(groove.w, 1),
                    0,
                    1,
                );
                self.seek_preview = @as(f64, rel) * duration;
                if (!self.pointer.down or self.pointer.released) {
                    self.engine.seekTo(self.seek_preview.?);
                    self.seek_preview = null;
                    self.drag = .none;
                }
            }
        }
    }

    fn drawTransport(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const inner = self.panel(c, r, null);

        // Transport buttons, centred as a group on the left.
        const btn: f32 = 38;
        const spacing: f32 = 10;
        var x = inner.x;
        const cy = inner.centerY();

        if (self.iconButton(c, Rect.init(x, cy - btn / 2, btn, btn), "\u{23EE}", false)) {
            self.engine.previousTrack();
        }
        x += btn + spacing;

        const playing = st.state == .playing;
        const play_size = btn + 8;
        if (self.iconButton(
            c,
            Rect.init(x, cy - play_size / 2, play_size, play_size),
            if (playing) "\u{23F8}" else "\u{25B6}",
            true,
        )) {
            self.engine.togglePause();
        }
        x += play_size + spacing;

        if (self.iconButton(c, Rect.init(x, cy - btn / 2, btn, btn), "\u{23ED}", false)) {
            self.engine.nextTrack();
        }
        x += btn + spacing * 2;

        // Toggles.
        if (self.toggleButton(c, Rect.init(x, cy - 14, 44, 28), "EQ", st.eq_enabled)) {
            self.engine.setEqEnabled(!st.eq_enabled);
            self.show_eq = true;
        }
        x += 50;

        const pl = self.engine.lockPlaylist();
        const shuffle_on = pl.shuffle;
        const repeat_mode = pl.repeat;
        self.engine.unlockPlaylist();

        if (self.toggleButton(c, Rect.init(x, cy - 14, 42, 28), "SHUF", shuffle_on)) {
            const p = self.engine.lockPlaylist();
            p.toggleShuffle();
            self.engine.unlockPlaylist();
        }
        x += 48;

        const repeat_label: []const u8 = if (repeat_mode == .one) "RPT 1" else "RPT";
        if (self.toggleButton(c, Rect.init(x, cy - 14, 46, 28), repeat_label, repeat_mode != .off)) {
            const p = self.engine.lockPlaylist();
            p.cycleRepeat();
            self.engine.unlockPlaylist();
        }
        x += 54;

        // Level meters, then the volume slider on the right.
        const vol_w: f32 = 128;
        const vol = Rect.init(inner.right() - vol_w, cy - 12, vol_w, 24);
        self.drawVolume(c, vol, st);

        const meter_right = vol.x - 16;
        if (meter_right > x + 80) {
            const meter_w = @min(200, meter_right - x - 12);
            self.drawMeters(c, Rect.init(x, cy - 12, meter_w, 24));
        }

        // Status message, or the buffer state, under the buttons.
        if (self.font_small) |f| {
            const line = Rect.init(inner.x, inner.bottom() - 2, inner.w, 14);
            if (self.statusText()) |msg| {
                _ = c.text(f, line, msg, t.accent, .left, true);
            } else if (st.last_error != .none) {
                var buf: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "last error: {s} ({d})", .{
                    st.last_error.label(),
                    st.decode_errors,
                }) catch "";
                _ = c.text(f, line, text, t.danger, .left, true);
            } else if (st.underruns > 0) {
                var buf: [96]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buf,
                    "{d} buffer underruns",
                    .{st.underruns},
                ) catch "";
                _ = c.text(f, line, text, t.text_faint, .left, true);
            }
        }
    }

    /// A circular transport button. Returns true when clicked.
    fn iconButton(self: *App, c: *Canvas, r: Rect, glyph: []const u8, filled: bool) bool {
        const t = self.theme;
        const hovering = self.pointer.over(r);
        const pressing = hovering and self.pointer.down;

        const radius = r.w * 0.5;
        if (filled) {
            const base = if (pressing)
                t.accent_pressed
            else if (hovering)
                t.accent_hover
            else
                t.accent;
            c.fillCircle(r.centerX(), r.centerY(), radius, base);
            if (self.font_icon) |f| {
                _ = c.text(f, r, glyph, t.text_on_accent, .center, false);
            }
        } else {
            const base = if (pressing)
                t.surface_selected
            else if (hovering)
                t.surface_hover
            else
                t.surface_raised;
            c.fillCircle(r.centerX(), r.centerY(), radius, base);
            c.strokeCircle(r.centerX(), r.centerY(), radius - 0.5, 1, t.outline);
            if (self.font_icon) |f| {
                _ = c.text(f, r, glyph, if (hovering) t.text else t.text_muted, .center, false);
            }
        }
        return self.pointer.clicked(r);
    }

    fn toggleButton(self: *App, c: *Canvas, r: Rect, label: []const u8, on: bool) bool {
        const t = self.theme;
        const hovering = self.pointer.over(r);
        const base = if (on)
            (if (hovering) t.accent_hover else t.accent)
        else if (hovering)
            t.surface_hover
        else
            t.surface_raised;
        c.fillRoundedRect(r, 7, base);
        if (!on) c.strokeRoundedRect(r, 7, 1, t.outline);
        if (self.font_small) |f| {
            const fg = if (on) t.text_on_accent else if (hovering) t.text else t.text_muted;
            _ = c.text(f, r, label, fg, .center, false);
        }
        return self.pointer.clicked(r);
    }

    fn drawVolume(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;

        // A speaker glyph that doubles as the mute button.
        const icon = Rect.init(r.x, r.y, 32, r.h);
        if (self.font_small) |f| {
            const glyph: []const u8 = if (st.muted) "MUTE" else "VOL";
            const hovering = self.pointer.over(icon);
            const fg = if (st.muted) t.danger else if (hovering) t.text else t.text_muted;
            _ = c.text(f, icon, glyph, fg, .center, false);
        }
        if (self.pointer.clicked(icon)) self.engine.toggleMute();

        const groove = Rect.init(r.x + 38, r.centerY() - 3, @max(10, r.w - 38), 6);
        const hit = Rect.init(groove.x, r.y, groove.w, r.h);
        const level = if (st.muted) 0 else st.volume;

        c.fillRoundedRect(groove, 3, t.surface_raised);
        if (level > 0) {
            c.fillRoundedRect(
                Rect.init(groove.x, groove.y, groove.w * level, groove.h),
                3,
                if (st.muted) t.text_faint else t.accent,
            );
        }

        const hovering = self.pointer.over(hit);
        if (hovering or self.drag == .volume) {
            const knob_x = groove.x + groove.w * level;
            c.fillCircle(knob_x, groove.centerY(), 7, t.accent);
            c.fillCircle(knob_x, groove.centerY(), 3.5, t.text_on_accent);
        }

        if (self.pointer.pressed and hovering) self.drag = .volume;
        if (self.drag == .volume) {
            const rel = std.math.clamp((self.pointer.x - groove.x) / @max(groove.w, 1), 0, 1);
            self.engine.setVolume(rel);
            if (!self.pointer.down) self.drag = .none;
        }
        // The wheel over the slider adjusts volume, which is the gesture
        // people expect there.
        if (hovering and self.pointer.wheel != 0) {
            self.engine.nudgeVolume(@as(f32, @floatFromInt(self.pointer.wheel)) * 0.04);
        }
    }

    fn drawMeters(self: *App, c: *Canvas, r: Rect) void {
        const t = self.theme;
        const an = self.engine.analyzerPtr() orelse return;
        const channels = @min(an.channelCount(), 2);
        if (channels == 0) return;

        const bar_h: f32 = 6;
        const gap: f32 = 4;
        const total_h = @as(f32, @floatFromInt(channels)) * bar_h +
            @as(f32, @floatFromInt(channels - 1)) * gap;
        var y = r.centerY() - total_h / 2;

        for (0..channels) |ch| {
            const track = Rect.init(r.x, y, r.w, bar_h);
            c.fillRoundedRect(track, 3, t.surface_raised);

            const level = an.meterLevel(ch);
            if (level > 0.001) {
                const w = r.w * level;
                // Gradient along the bar so the loud end reads as hotter.
                c.fillRoundedRectGradient(
                    Rect.init(r.x, y, w, bar_h),
                    3,
                    t.meterColor(level),
                    t.meterColor(level * 0.6),
                );
            }

            // Peak hold tick.
            const peak = an.meterPeak(ch);
            if (peak > 0.01) {
                const px = r.x + r.w * peak;
                c.fillRect(Rect.init(px - 1, y - 1, 2, bar_h + 2), t.meterColor(peak));
            }
            y += bar_h + gap;
        }
    }

    fn drawSpectrum(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        _ = st;
        const t = self.theme;
        const inner = self.panel(c, r, "SPECTRUM");
        if (inner.w < 20 or inner.h < 20) return;

        const an = self.engine.analyzerPtr() orelse {
            if (self.font_small) |f| {
                _ = c.text(f, inner, "analyzer disabled", t.text_faint, .center, false);
            }
            return;
        };
        const bands = an.bandCount();
        if (bands == 0) return;

        // Leave room for the frequency scale.
        const label_h: f32 = 16;
        const plot = Rect.init(inner.x, inner.y, inner.w, @max(10, inner.h - label_h));

        // Faint horizontal guides at -12, -24, -36 dB equivalents.
        var guide: usize = 1;
        while (guide < 4) : (guide += 1) {
            const gy = plot.y + plot.h * (@as(f32, @floatFromInt(guide)) / 4.0);
            c.fillRect(Rect.init(plot.x, gy, plot.w, 1), t.outline.fade(0.5));
        }

        const bandsf: f32 = @floatFromInt(bands);
        const slot = plot.w / bandsf;
        const bar_w = @max(1.5, slot - @max(1.0, slot * 0.22));

        for (0..bands) |i| {
            const level = an.bandLevel(i);
            const peak = an.bandPeak(i);
            const x = plot.x + @as(f32, @floatFromInt(i)) * slot + (slot - bar_w) / 2;

            if (level > 0.004) {
                const h = @max(1.5, plot.h * level);
                const bar = Rect.init(x, plot.bottom() - h, bar_w, h);
                // Colour by the bar's own height, so a tall bar is hot
                // regardless of which band it is.
                c.fillRoundedRectGradient(
                    bar,
                    @min(2.5, bar_w * 0.4),
                    t.energyColor(level),
                    t.energyColor(level).scale(0.55),
                );
            }

            if (peak > 0.01) {
                const py = plot.bottom() - plot.h * peak;
                c.fillRect(Rect.init(x, py, bar_w, 2), t.text.fade(0.35));
            }
        }

        // Frequency labels under the plot.
        if (self.font_small) |f| {
            const marks = [_]struct { hz: f32, label: []const u8 }{
                .{ .hz = 60, .label = "60" },
                .{ .hz = 250, .label = "250" },
                .{ .hz = 1000, .label = "1k" },
                .{ .hz = 4000, .label = "4k" },
                .{ .hz = 12000, .label = "12k" },
            };
            for (marks) |m| {
                var band: ?usize = null;
                for (0..bands) |i| {
                    const range = analyzer_mod.bandRange(i, bands);
                    if (m.hz >= range.lo and m.hz < range.hi) band = i;
                }
                const bi = band orelse continue;
                const cx = plot.x + (@as(f32, @floatFromInt(bi)) + 0.5) * slot;
                const box = Rect.init(cx - 20, plot.bottom() + 1, 40, label_h);
                _ = c.text(f, box, m.label, t.text_faint, .center, false);
            }
        }
    }

    fn drawPlaylist(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;

        var title_buf: [64]u8 = undefined;
        const pl = self.engine.lockPlaylist();
        const count = pl.count();
        const playing_index = st.track_index orelse pl.currentIndex();
        const header = if (playing_index) |i|
            std.fmt.bufPrint(&title_buf, "QUEUE  {d} / {d}", .{ i + 1, count }) catch "QUEUE"
        else
            std.fmt.bufPrint(&title_buf, "QUEUE  {d}", .{count}) catch "QUEUE";

        const inner = self.panel(c, r, header);

        if (count == 0) {
            self.engine.unlockPlaylist();
            if (self.font_body) |f| {
                _ = c.text(f, inner, "Drop files here", t.text_faint, .center, false);
            }
            return;
        }

        const rows_visible = @max(1.0, @floor(inner.h / row_height));
        self.playlist_rows = rows_visible;

        // Wheel scrolling, and clamping after a removal.
        if (self.pointer.over(inner) and self.pointer.wheel != 0) {
            self.scroll -= @as(f32, @floatFromInt(self.pointer.wheel)) * 3;
        }
        const max_scroll = @max(0, @as(f32, @floatFromInt(count)) - rows_visible);
        self.scroll = std.math.clamp(self.scroll, 0, max_scroll);

        const first: usize = @intFromFloat(@floor(self.scroll));
        const saved_clip = c.pushClip(inner);
        defer c.popClip(saved_clip);

        var hovered: ?usize = null;
        var clicked_row: ?usize = null;
        var double_clicked_row: ?usize = null;

        var slot: usize = 0;
        while (slot < @as(usize, @intFromFloat(rows_visible)) + 1) : (slot += 1) {
            const index = first + slot;
            if (index >= count) break;
            const track = pl.at(index) orelse continue;

            const y = inner.y + (@as(f32, @floatFromInt(index)) - self.scroll) * row_height;
            const row = Rect.init(inner.x, y, inner.w, row_height);
            if (row.bottom() < inner.y or row.y > inner.bottom()) continue;

            const is_playing = playing_index != null and playing_index.? == index;
            const is_selected = index == self.selected;
            const is_hover = self.pointer.over(row);
            if (is_hover) hovered = index;
            if (is_hover and self.pointer.released) clicked_row = index;
            if (is_hover and self.pointer.double_clicked) double_clicked_row = index;

            if (is_selected) {
                c.fillRoundedRect(row.insetXY(0, 1), 6, t.surface_selected);
            } else if (is_hover) {
                c.fillRoundedRect(row.insetXY(0, 1), 6, t.surface_hover);
            }

            // Playing indicator.
            if (is_playing) {
                c.fillRoundedRect(Rect.init(row.x + 2, row.y + 7, 3, row.h - 14), 1.5, t.accent);
            }

            const num_w: f32 = 32;
            const dur_w: f32 = 52;
            if (self.font_small) |f| {
                var buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch "";
                _ = c.text(
                    f,
                    Rect.init(row.x + 8, row.y, num_w, row.h),
                    num,
                    t.text_faint,
                    .right,
                    false,
                );
            }

            if (self.font_body) |f| {
                const text_x = row.x + num_w + 16;
                const text_w = @max(10, row.w - num_w - dur_w - 28);
                var buf: [512]u8 = undefined;
                const artist = track.displayArtist();
                const line = if (artist.len > 0)
                    std.fmt.bufPrint(&buf, "{s}  \u{2014}  {s}", .{
                        artist,
                        track.displayTitle(),
                    }) catch track.displayTitle()
                else
                    track.displayTitle();
                const fg = if (is_playing) t.accent else if (is_selected) t.text else t.text_muted;
                _ = c.text(f, Rect.init(text_x, row.y, text_w, row.h), line, fg, .left, true);
            }

            if (self.font_mono) |f| {
                var buf: [24]u8 = undefined;
                const dur = if (track.duration_s) |d|
                    time_util.formatClock(&buf, d)
                else
                    "--:--";
                _ = c.text(
                    f,
                    Rect.init(row.right() - dur_w - 8, row.y, dur_w, row.h),
                    dur,
                    t.text_faint,
                    .right,
                    false,
                );
            }
        }
        self.engine.unlockPlaylist();
        self.hover_row = hovered;

        // Apply the interactions after the lock is released, since playing a
        // track takes it again.
        if (double_clicked_row) |i| {
            self.selected = i;
            self.engine.playIndex(i);
        } else if (clicked_row) |i| {
            self.selected = i;
        }

        // Scrollbar.
        if (max_scroll > 0) {
            const track_x = inner.right() - 4;
            const bar = Rect.init(track_x, inner.y, 4, inner.h);
            c.fillRoundedRect(bar, 2, t.surface_raised.fade(0.6));
            const thumb_h = @max(24, inner.h * (rows_visible / @as(f32, @floatFromInt(count))));
            const thumb_y = inner.y + (inner.h - thumb_h) * (self.scroll / max_scroll);
            c.fillRoundedRect(Rect.init(track_x, thumb_y, 4, thumb_h), 2, t.accent.fade(0.7));
        }
    }

    fn drawEqualizer(self: *App, c: *Canvas, r: Rect, st: engine_mod.Status) void {
        const t = self.theme;
        const inner = self.panel(c, r, "EQUALIZER");
        if (inner.w < 100 or inner.h < 60) return;

        // Preset buttons along the top.
        const head = inner.splitTop(28);
        var x = head.top.x;
        const presets = [_]equalizer.Preset{
            .flat,     .rock,       .pop,          .jazz,
            .dance,    .acoustic,   .electronic,   .bass_boost,
            .vocal,    .loudness,
        };
        for (presets) |p| {
            const label = p.label();
            const f = self.font_small orelse break;
            const w: f32 = @as(f32, @floatFromInt(c.measure(f, label))) + 18;
            if (x + w > head.top.right()) break;
            const box = Rect.init(x, head.top.y, w, 24);
            const hovering = self.pointer.over(box);
            c.fillRoundedRect(box, 6, if (hovering) t.surface_hover else t.surface_raised);
            if (!hovering) c.strokeRoundedRect(box, 6, 1, t.outline);
            _ = c.text(f, box, label, if (hovering) t.text else t.text_muted, .center, false);
            if (self.pointer.clicked(box)) {
                self.engine.setEqPreset(p);
                self.engine.setEqEnabled(true);
                self.setStatusArgs("preset: {s}", .{label}, 90);
            }
            x += w + 6;
        }

        // Ten vertical sliders.
        var body = head.rest;
        body.y += 8;
        body.h -= 8;
        const slot = body.w / @as(f32, equalizer.band_count);
        const label_h: f32 = 16;
        const track_h = @max(20, body.h - label_h);
        const span = equalizer.max_gain_db - equalizer.min_gain_db;

        for (0..equalizer.band_count) |i| {
            const cx = body.x + (@as(f32, @floatFromInt(i)) + 0.5) * slot;
            const track = Rect.init(cx - 3, body.y, 6, track_h);
            // Clicking anywhere in the column grabs the slider.
            const hit = Rect.init(body.x + @as(f32, @floatFromInt(i)) * slot, body.y, slot, track_h);

            // The track needs to read against the panel behind it, so it is
            // drawn darker than the surface rather than lighter.
            c.fillRoundedRect(track, 3, t.background.scale(0.85));
            c.strokeRoundedRect(track, 3, 1, t.outline);

            // The 0 dB reference, spanning the whole column so the row of
            // them reads as a single line across the band set.
            const zero_y = track.y + track_h * 0.5;
            c.fillRect(
                Rect.init(cx - slot * 0.42, zero_y, slot * 0.84, 1),
                t.text_faint.fade(0.45),
            );

            const gain = st.eq_gains[i];
            const norm = (gain - equalizer.min_gain_db) / span;
            const knob_y = track.y + track_h * (1.0 - std.math.clamp(norm, 0, 1));

            // Fill from the zero line to the knob, so a cut reads downward.
            const top_y = @min(zero_y, knob_y);
            const fill_h = @abs(knob_y - zero_y);
            if (fill_h > 0.5) {
                c.fillRoundedRect(
                    Rect.init(track.x, top_y, track.w, fill_h),
                    3,
                    if (gain >= 0) t.accent else t.meter_warn,
                );
            }

            const dragging = switch (self.drag) {
                .eq_band => |b| b == i,
                else => false,
            };
            const hovering = self.pointer.over(hit);
            c.fillCircle(cx, knob_y, if (hovering or dragging) 8 else 6.5, t.accent);
            c.fillCircle(cx, knob_y, 3, t.text_on_accent);

            if (self.pointer.pressed and hovering) self.drag = .{ .eq_band = i };
            if (dragging) {
                const rel = 1.0 - std.math.clamp(
                    (self.pointer.y - track.y) / @max(track_h, 1),
                    0,
                    1,
                );
                const new_gain = equalizer.min_gain_db + rel * span;
                self.engine.setEqBand(@intCast(i), new_gain);
                self.engine.setEqEnabled(true);
                if (!self.pointer.down) self.drag = .none;
            }
            // Double-clicking a band resets it, which is the standard gesture.
            if (self.pointer.double_clicked and hovering) {
                self.engine.setEqBand(@intCast(i), 0);
            }

            if (self.font_small) |f| {
                var buf: [16]u8 = undefined;
                const hz = equalizer.centers[i];
                const label = if (hz >= 1000)
                    std.fmt.bufPrint(&buf, "{d:.0}k", .{hz / 1000}) catch ""
                else
                    std.fmt.bufPrint(&buf, "{d:.0}", .{hz}) catch "";
                _ = c.text(
                    f,
                    Rect.init(cx - slot / 2, track.bottom(), slot, label_h),
                    label,
                    if (hovering) t.text else t.text_faint,
                    .center,
                    false,
                );
            }
        }
    }
};

const testing = std.testing;

test "pointer hit testing" {
    const r: Rect = .init(10, 10, 100, 40);
    var p: Pointer = .{ .x = 50, .y = 20, .inside = true };
    try testing.expect(p.over(r));
    try testing.expect(!p.clicked(r));
    p.released = true;
    try testing.expect(p.clicked(r));

    // Outside the window entirely.
    p.inside = false;
    try testing.expect(!p.over(r));
    try testing.expect(!p.clicked(r));

    // Inside the window but outside the rect.
    p = .{ .x = 5, .y = 5, .inside = true, .released = true };
    try testing.expect(!p.clicked(r));
}

test "drag state discriminates equalizer bands" {
    var d: Drag = .none;
    try testing.expect(d == .none);
    d = .{ .eq_band = 3 };
    switch (d) {
        .eq_band => |b| try testing.expectEqual(@as(usize, 3), b),
        else => return error.TestUnexpectedResult,
    }
}
