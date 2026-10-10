//! Terminal setup, teardown and keyboard input.
//!
//! Output is plain ANSI on every platform (Windows gets virtual-terminal
//! processing switched on first). Input is read on a dedicated thread, because
//! both platforms only offer a blocking read and the UI needs to keep
//! redrawing the spectrum while nobody is pressing anything. Decoded keys go
//! into a small lock-free queue the UI drains each frame.
//!
//! Windows uses `ReadConsoleInputW` rather than VT input sequences: it reports
//! arrow and function keys as virtual key codes directly, which avoids having
//! to disambiguate an escape sequence from someone actually pressing Escape.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Atomic = std.atomic.Value;

const is_windows = builtin.os.tag == .windows;

pub const Error = error{
    NotATerminal,
    SetupFailed,
    OutOfMemory,
};

pub const Key = union(enum) {
    /// A printable character.
    char: u21,
    /// Control + an ASCII letter, stored lowercase.
    ctrl: u8,
    enter,
    escape,
    backspace,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    f: u8,
    /// The window changed size.
    resize,

    pub fn isChar(k: Key, c: u8) bool {
        return k == .char and k.char == c;
    }
};

pub const Size = struct { width: u16, height: u16 };

/// Keys buffered between UI frames.
const key_queue_capacity = 64;

const KeyQueue = struct {
    items: [key_queue_capacity]Key = undefined,
    head: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    tail: Atomic(usize) align(std.atomic.cache_line) = .init(0),

    fn push(q: *KeyQueue, k: Key) void {
        const h = q.head.load(.monotonic);
        const t = q.tail.load(.acquire);
        // Drop the key rather than block if the UI has stalled; a lost
        // keystroke beats a wedged input thread.
        if (h - t >= key_queue_capacity) return;
        q.items[h % key_queue_capacity] = k;
        q.head.store(h + 1, .release);
    }

    fn pop(q: *KeyQueue) ?Key {
        const t = q.tail.load(.monotonic);
        const h = q.head.load(.acquire);
        if (t == h) return null;
        const k = q.items[t % key_queue_capacity];
        q.tail.store(t + 1, .release);
        return k;
    }
};

// ---------------------------------------------------------------------------
// Windows console
// ---------------------------------------------------------------------------

const win = struct {
    const HANDLE = *anyopaque;
    const BOOL = i32;
    const INVALID_HANDLE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6; // -10
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // -11

    const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_ECHO_INPUT: u32 = 0x0004;
    const ENABLE_WINDOW_INPUT: u32 = 0x0008;
    const ENABLE_MOUSE_INPUT: u32 = 0x0010;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;

    const ENABLE_PROCESSED_OUTPUT: u32 = 0x0001;
    const ENABLE_WRAP_AT_EOL_OUTPUT: u32 = 0x0002;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const DISABLE_NEWLINE_AUTO_RETURN: u32 = 0x0008;

    const KEY_EVENT: u16 = 0x0001;
    const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

    const LEFT_CTRL_PRESSED: u32 = 0x0008;
    const RIGHT_CTRL_PRESSED: u32 = 0x0004;
    const SHIFT_PRESSED: u32 = 0x0010;

    const COORD = extern struct { X: i16, Y: i16 };
    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };

    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    const KEY_EVENT_RECORD = extern struct {
        bKeyDown: BOOL,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        UnicodeChar: u16,
        dwControlKeyState: u32,
    };

    const INPUT_RECORD = extern struct {
        EventType: u16,
        /// The union is 16 bytes wide and 4-byte aligned, which puts it at
        /// offset 4 after the event type's padding.
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
            pad: [16]u8,
        },
    };

    // Virtual key codes.
    const VK_BACK: u16 = 0x08;
    const VK_TAB: u16 = 0x09;
    const VK_RETURN: u16 = 0x0D;
    const VK_ESCAPE: u16 = 0x1B;
    const VK_PRIOR: u16 = 0x21;
    const VK_NEXT: u16 = 0x22;
    const VK_END: u16 = 0x23;
    const VK_HOME: u16 = 0x24;
    const VK_LEFT: u16 = 0x25;
    const VK_UP: u16 = 0x26;
    const VK_RIGHT: u16 = 0x27;
    const VK_DOWN: u16 = 0x28;
    const VK_INSERT: u16 = 0x2D;
    const VK_DELETE: u16 = 0x2E;
    const VK_F1: u16 = 0x70;
    const VK_F12: u16 = 0x7B;

    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: HANDLE,
        lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadConsoleInputW(
        hConsoleInput: HANDLE,
        lpBuffer: [*]INPUT_RECORD,
        nLength: u32,
        lpNumberOfEventsRead: *u32,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNumberOfConsoleInputEvents(
        hConsoleInput: HANDLE,
        lpcNumberOfEvents: *u32,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;

    /// Translate one console key event, or null if it carries no key.
    fn translate(rec: KEY_EVENT_RECORD) ?Key {
        if (rec.bKeyDown == 0) return null;

        const ctrl = (rec.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;

        switch (rec.wVirtualKeyCode) {
            VK_LEFT => return .left,
            VK_RIGHT => return .right,
            VK_UP => return .up,
            VK_DOWN => return .down,
            VK_HOME => return .home,
            VK_END => return .end,
            VK_PRIOR => return .page_up,
            VK_NEXT => return .page_down,
            VK_INSERT => return .insert,
            VK_DELETE => return .delete,
            VK_RETURN => return .enter,
            VK_ESCAPE => return .escape,
            VK_BACK => return .backspace,
            VK_TAB => return .tab,
            else => {},
        }
        if (rec.wVirtualKeyCode >= VK_F1 and rec.wVirtualKeyCode <= VK_F12) {
            return .{ .f = @intCast(rec.wVirtualKeyCode - VK_F1 + 1) };
        }

        const ch = rec.UnicodeChar;
        if (ch == 0) return null;

        // Control combinations arrive as 0x01..0x1A.
        if (ctrl and ch >= 1 and ch <= 26) {
            return .{ .ctrl = @intCast('a' + ch - 1) };
        }
        if (ch < 0x20) return null; // other control codes
        return .{ .char = ch };
    }
};

// ---------------------------------------------------------------------------
// POSIX terminal
// ---------------------------------------------------------------------------

const posix_term = struct {
    /// Parse one key from a buffer of raw bytes, returning the key and how
    /// many bytes it consumed. Returns null when more input is needed.
    fn parse(buf: []const u8) ?struct { key: Key, len: usize } {
        if (buf.len == 0) return null;
        const b = buf[0];

        if (b == 0x1B) {
            if (buf.len == 1) return .{ .key = .escape, .len = 1 };
            if (buf[1] == '[') {
                if (buf.len < 3) return null;
                switch (buf[2]) {
                    'A' => return .{ .key = .up, .len = 3 },
                    'B' => return .{ .key = .down, .len = 3 },
                    'C' => return .{ .key = .right, .len = 3 },
                    'D' => return .{ .key = .left, .len = 3 },
                    'H' => return .{ .key = .home, .len = 3 },
                    'F' => return .{ .key = .end, .len = 3 },
                    '1'...'6' => {
                        // "ESC [ n ~" forms.
                        if (buf.len < 4) return null;
                        if (buf[3] != '~') return .{ .key = .escape, .len = 1 };
                        return switch (buf[2]) {
                            '1' => .{ .key = .home, .len = 4 },
                            '2' => .{ .key = .insert, .len = 4 },
                            '3' => .{ .key = .delete, .len = 4 },
                            '4' => .{ .key = .end, .len = 4 },
                            '5' => .{ .key = .page_up, .len = 4 },
                            '6' => .{ .key = .page_down, .len = 4 },
                            else => .{ .key = .escape, .len = 1 },
                        };
                    },
                    else => return .{ .key = .escape, .len = 1 },
                }
            }
            if (buf[1] == 'O') {
                if (buf.len < 3) return null;
                return switch (buf[2]) {
                    'P'...'S' => .{ .key = .{ .f = @intCast(buf[2] - 'P' + 1) }, .len = 3 },
                    'H' => .{ .key = .home, .len = 3 },
                    'F' => .{ .key = .end, .len = 3 },
                    else => .{ .key = .escape, .len = 1 },
                };
            }
            return .{ .key = .escape, .len = 1 };
        }

        if (b == '\r' or b == '\n') return .{ .key = .enter, .len = 1 };
        if (b == 0x7F or b == 0x08) return .{ .key = .backspace, .len = 1 };
        if (b == '\t') return .{ .key = .tab, .len = 1 };
        if (b >= 1 and b <= 26) return .{ .key = .{ .ctrl = @intCast('a' + b - 1) }, .len = 1 };
        if (b < 0x20) return null;

        // UTF-8 multi-byte sequence.
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (buf.len < seq_len) return null;
        const cp = std.unicode.utf8Decode(buf[0..seq_len]) catch
            return .{ .key = .{ .char = b }, .len = 1 };
        return .{ .key = .{ .char = cp }, .len = seq_len };
    }
};

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

pub const Terminal = struct {
    gpa: Allocator,
    io: Io,

    out_file: Io.File,
    writer: Io.File.Writer,
    write_buf: []u8,

    size: Size = .{ .width = 80, .height = 24 },

    keys: KeyQueue = .{},
    input_thread: ?std.Thread = null,
    input_running: Atomic(bool) = .init(false),

    /// Console state to put back on exit.
    saved_out_mode: u32 = 0,
    saved_in_mode: u32 = 0,
    saved_out_cp: u32 = 0,
    modes_saved: bool = false,
    alt_screen: bool = false,

    posix_saved: if (is_windows) void else std.posix.termios = if (is_windows) {} else undefined,
    posix_saved_valid: bool = false,

    pub fn init(gpa: Allocator, io: Io) Error!*Terminal {
        const self = gpa.create(Terminal) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);

        const write_buf = gpa.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
        errdefer gpa.free(write_buf);

        const out_file: Io.File = .stdout();
        self.* = .{
            .gpa = gpa,
            .io = io,
            .out_file = out_file,
            .writer = out_file.writer(io, write_buf),
            .write_buf = write_buf,
        };

        // Bail out before touching console modes if this is a pipe or a file.
        // The `errdefer`s above release both allocations; freeing them here as
        // well would be a double free.
        const tty = out_file.isTty(io) catch false;
        if (!tty) return error.NotATerminal;

        try self.enableRawMode();
        self.size = self.querySize();
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.stopInput();
        if (self.alt_screen) self.leaveAltScreen();
        self.showCursor();
        self.flush() catch {};
        self.restoreMode();
        const gpa = self.gpa;
        gpa.free(self.write_buf);
        gpa.destroy(self);
    }

    fn enableRawMode(self: *Terminal) Error!void {
        if (is_windows) {
            const hout = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
            const hin = win.GetStdHandle(win.STD_INPUT_HANDLE);
            if (hout == win.INVALID_HANDLE or hin == win.INVALID_HANDLE) {
                return error.SetupFailed;
            }

            var out_mode: u32 = 0;
            var in_mode: u32 = 0;
            if (win.GetConsoleMode(hout, &out_mode) == 0) return error.SetupFailed;
            if (win.GetConsoleMode(hin, &in_mode) == 0) return error.SetupFailed;
            self.saved_out_mode = out_mode;
            self.saved_in_mode = in_mode;
            self.saved_out_cp = win.GetConsoleOutputCP();
            self.modes_saved = true;

            // ANSI escapes, and no automatic newline at the right edge (which
            // would scroll the screen when drawing the bottom-right cell).
            const want_out = out_mode | win.ENABLE_PROCESSED_OUTPUT |
                win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.DISABLE_NEWLINE_AUTO_RETURN;
            if (win.SetConsoleMode(hout, want_out) == 0) return error.SetupFailed;

            // Raw input: no line buffering, no echo, and no Ctrl-C handling,
            // since the UI treats it as a key.
            var want_in = in_mode;
            want_in &= ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT |
                win.ENABLE_PROCESSED_INPUT | win.ENABLE_VIRTUAL_TERMINAL_INPUT |
                win.ENABLE_MOUSE_INPUT);
            want_in |= win.ENABLE_WINDOW_INPUT;
            if (win.SetConsoleMode(hin, want_in) == 0) return error.SetupFailed;

            // Box-drawing characters and the degree sign need UTF-8.
            _ = win.SetConsoleOutputCP(65001);
        } else {
            const fd = std.posix.STDIN_FILENO;
            const saved = std.posix.tcgetattr(fd) catch return error.SetupFailed;
            self.posix_saved = saved;
            self.posix_saved_valid = true;

            var raw = saved;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.iflag.BRKINT = false;
            raw.iflag.INPCK = false;
            raw.iflag.ISTRIP = false;
            raw.oflag.OPOST = false;
            std.posix.tcsetattr(fd, .FLUSH, raw) catch return error.SetupFailed;
        }
    }

    fn restoreMode(self: *Terminal) void {
        if (is_windows) {
            if (!self.modes_saved) return;
            const hout = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
            const hin = win.GetStdHandle(win.STD_INPUT_HANDLE);
            _ = win.SetConsoleMode(hout, self.saved_out_mode);
            _ = win.SetConsoleMode(hin, self.saved_in_mode);
            if (self.saved_out_cp != 0) _ = win.SetConsoleOutputCP(self.saved_out_cp);
        } else {
            if (!self.posix_saved_valid) return;
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.posix_saved) catch {};
        }
    }

    pub fn querySize(self: *Terminal) Size {
        if (is_windows) {
            const hout = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
            var info: win.CONSOLE_SCREEN_BUFFER_INFO = std.mem.zeroes(win.CONSOLE_SCREEN_BUFFER_INFO);
            if (win.GetConsoleScreenBufferInfo(hout, &info) != 0) {
                // The visible window, not the scrollback buffer.
                const w = info.srWindow.Right - info.srWindow.Left + 1;
                const h = info.srWindow.Bottom - info.srWindow.Top + 1;
                if (w > 0 and h > 0) {
                    return .{ .width = @intCast(w), .height = @intCast(h) };
                }
            }
            return self.size;
        } else {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(
                std.posix.STDOUT_FILENO,
                std.posix.T.IOCGWINSZ,
                @intFromPtr(&ws),
            );
            if (rc == 0 and ws.col > 0 and ws.row > 0) {
                return .{ .width = ws.col, .height = ws.row };
            }
            return self.size;
        }
    }

    /// Re-read the size; returns true if it changed.
    pub fn refreshSize(self: *Terminal) bool {
        const now = self.querySize();
        if (now.width == self.size.width and now.height == self.size.height) return false;
        self.size = now;
        return true;
    }

    // --- output ---------------------------------------------------------

    pub fn writer_ptr(self: *Terminal) *Io.Writer {
        return &self.writer.interface;
    }

    pub fn write(self: *Terminal, bytes: []const u8) void {
        self.writer.interface.writeAll(bytes) catch {};
    }

    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        self.writer.interface.print(fmt, args) catch {};
    }

    pub fn flush(self: *Terminal) !void {
        try self.writer.interface.flush();
    }

    pub fn enterAltScreen(self: *Terminal) void {
        self.write("\x1b[?1049h");
        self.alt_screen = true;
    }

    pub fn leaveAltScreen(self: *Terminal) void {
        self.write("\x1b[?1049l");
        self.alt_screen = false;
    }

    pub fn hideCursor(self: *Terminal) void {
        self.write("\x1b[?25l");
    }

    pub fn showCursor(self: *Terminal) void {
        self.write("\x1b[?25h");
    }

    pub fn clearScreen(self: *Terminal) void {
        self.write("\x1b[2J\x1b[H");
    }

    pub fn moveTo(self: *Terminal, x: u16, y: u16) void {
        // ANSI is 1-based.
        self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn resetStyle(self: *Terminal) void {
        self.write("\x1b[0m");
    }

    // --- input ----------------------------------------------------------

    pub fn startInput(self: *Terminal) void {
        if (self.input_thread != null) return;
        self.input_running.store(true, .release);
        self.input_thread = std.Thread.spawn(.{}, inputLoop, .{self}) catch {
            self.input_running.store(false, .release);
            return;
        };
    }

    pub fn stopInput(self: *Terminal) void {
        if (self.input_thread == null) return;
        self.input_running.store(false, .release);
        // The reader is blocked in a syscall and cannot be interrupted
        // portably, so let it exit on its own once the user presses something
        // or the process ends.
        if (self.input_thread) |t| {
            t.detach();
            self.input_thread = null;
        }
    }

    /// Next buffered key, or null.
    pub fn pollKey(self: *Terminal) ?Key {
        return self.keys.pop();
    }

    fn inputLoop(self: *Terminal) void {
        if (is_windows) {
            const hin = win.GetStdHandle(win.STD_INPUT_HANDLE);
            var records: [32]win.INPUT_RECORD = undefined;
            while (self.input_running.load(.acquire)) {
                // Wait with a timeout so the thread notices shutdown even
                // when nobody is typing.
                if (win.WaitForSingleObject(hin, 100) != 0) continue;

                var count: u32 = 0;
                if (win.ReadConsoleInputW(hin, &records, records.len, &count) == 0) break;
                for (records[0..count]) |rec| {
                    switch (rec.EventType) {
                        win.KEY_EVENT => {
                            if (win.translate(rec.Event.KeyEvent)) |k| self.keys.push(k);
                        },
                        win.WINDOW_BUFFER_SIZE_EVENT => self.keys.push(.resize),
                        else => {},
                    }
                }
            }
        } else {
            var buf: [256]u8 = undefined;
            var len: usize = 0;
            while (self.input_running.load(.acquire)) {
                const n = std.posix.read(std.posix.STDIN_FILENO, buf[len..]) catch break;
                if (n == 0) break;
                len += n;

                var consumed: usize = 0;
                while (consumed < len) {
                    const parsed = posix_term.parse(buf[consumed..len]) orelse break;
                    self.keys.push(parsed.key);
                    consumed += parsed.len;
                }
                // Keep any partial sequence for the next read.
                if (consumed > 0 and consumed < len) {
                    std.mem.copyForwards(u8, buf[0 .. len - consumed], buf[consumed..len]);
                }
                len -= consumed;
                if (len == buf.len) len = 0; // give up on a wedged sequence
            }
        }
    }
};

const testing = std.testing;

test "key helpers" {
    const k: Key = .{ .char = 'q' };
    try testing.expect(k.isChar('q'));
    try testing.expect(!k.isChar('p'));
    const up: Key = .up;
    try testing.expect(!up.isChar('q'));
}

test "console input record layout matches the Win32 ABI" {
    if (!is_windows) return error.SkipZigTest;
    // Getting these wrong means reading garbage key codes.
    try testing.expectEqual(@as(usize, 16), @sizeOf(win.KEY_EVENT_RECORD));
    try testing.expectEqual(@as(usize, 20), @sizeOf(win.INPUT_RECORD));
    try testing.expectEqual(@as(usize, 4), @offsetOf(win.INPUT_RECORD, "Event"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(win.KEY_EVENT_RECORD, "bKeyDown"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(win.KEY_EVENT_RECORD, "wRepeatCount"));
    try testing.expectEqual(@as(usize, 6), @offsetOf(win.KEY_EVENT_RECORD, "wVirtualKeyCode"));
    try testing.expectEqual(@as(usize, 10), @offsetOf(win.KEY_EVENT_RECORD, "UnicodeChar"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(win.KEY_EVENT_RECORD, "dwControlKeyState"));
    try testing.expectEqual(@as(usize, 22), @sizeOf(win.CONSOLE_SCREEN_BUFFER_INFO));
}

test "windows key translation" {
    if (!is_windows) return error.SkipZigTest;

    const mk = struct {
        fn rec(vk: u16, ch: u16, ctrl: u32, down: i32) win.KEY_EVENT_RECORD {
            return .{
                .bKeyDown = down,
                .wRepeatCount = 1,
                .wVirtualKeyCode = vk,
                .wVirtualScanCode = 0,
                .UnicodeChar = ch,
                .dwControlKeyState = ctrl,
            };
        }
    };

    // Key-up events are ignored, otherwise every press would register twice.
    try testing.expect(win.translate(mk.rec('A', 'a', 0, 0)) == null);

    try testing.expectEqual(Key{ .char = 'a' }, win.translate(mk.rec('A', 'a', 0, 1)).?);
    try testing.expectEqual(Key.up, win.translate(mk.rec(win.VK_UP, 0, 0, 1)).?);
    try testing.expectEqual(Key.page_down, win.translate(mk.rec(win.VK_NEXT, 0, 0, 1)).?);
    try testing.expectEqual(Key.enter, win.translate(mk.rec(win.VK_RETURN, 13, 0, 1)).?);
    try testing.expectEqual(Key.escape, win.translate(mk.rec(win.VK_ESCAPE, 27, 0, 1)).?);
    try testing.expectEqual(Key{ .f = 1 }, win.translate(mk.rec(win.VK_F1, 0, 0, 1)).?);
    try testing.expectEqual(Key{ .f = 12 }, win.translate(mk.rec(win.VK_F12, 0, 0, 1)).?);
    // Ctrl+C arrives as code point 3.
    try testing.expectEqual(
        Key{ .ctrl = 'c' },
        win.translate(mk.rec('C', 3, win.LEFT_CTRL_PRESSED, 1)).?,
    );
    // A modifier on its own produces nothing.
    try testing.expect(win.translate(mk.rec(0x10, 0, win.SHIFT_PRESSED, 1)) == null);
}

test "ANSI escape parsing" {
    const cases = [_]struct { in: []const u8, key: Key, len: usize }{
        .{ .in = "q", .key = .{ .char = 'q' }, .len = 1 },
        .{ .in = "\x1b[A", .key = .up, .len = 3 },
        .{ .in = "\x1b[B", .key = .down, .len = 3 },
        .{ .in = "\x1b[C", .key = .right, .len = 3 },
        .{ .in = "\x1b[D", .key = .left, .len = 3 },
        .{ .in = "\x1b[H", .key = .home, .len = 3 },
        .{ .in = "\x1b[5~", .key = .page_up, .len = 4 },
        .{ .in = "\x1b[6~", .key = .page_down, .len = 4 },
        .{ .in = "\x1b[3~", .key = .delete, .len = 4 },
        .{ .in = "\x1bOP", .key = .{ .f = 1 }, .len = 3 },
        .{ .in = "\r", .key = .enter, .len = 1 },
        .{ .in = "\x7f", .key = .backspace, .len = 1 },
        .{ .in = "\t", .key = .tab, .len = 1 },
        .{ .in = "\x03", .key = .{ .ctrl = 'c' }, .len = 1 },
        .{ .in = "\x1b", .key = .escape, .len = 1 },
    };
    for (cases) |c| {
        const got = posix_term.parse(c.in) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(c.key, got.key);
        try testing.expectEqual(c.len, got.len);
    }

    // A partial escape sequence asks for more bytes rather than guessing.
    try testing.expect(posix_term.parse("\x1b[") == null);
    try testing.expect(posix_term.parse("\x1b[5") == null);
    try testing.expect(posix_term.parse("") == null);

    // Multi-byte UTF-8.
    const utf8 = posix_term.parse("\u{00E9}").?;
    try testing.expectEqual(@as(u21, 0xE9), utf8.key.char);
    try testing.expectEqual(@as(usize, 2), utf8.len);
}

test "key queue drops rather than blocking when full" {
    var q: KeyQueue = .{};
    try testing.expect(q.pop() == null);
    for (0..key_queue_capacity) |_| q.push(.up);
    q.push(.down); // dropped
    var count: usize = 0;
    while (q.pop()) |k| {
        try testing.expectEqual(Key.up, k);
        count += 1;
    }
    try testing.expectEqual(key_queue_capacity, count);
}

test "key queue preserves order" {
    var q: KeyQueue = .{};
    q.push(.{ .char = 'a' });
    q.push(.{ .char = 'b' });
    q.push(.left);
    try testing.expectEqual(@as(u21, 'a'), q.pop().?.char);
    try testing.expectEqual(@as(u21, 'b'), q.pop().?.char);
    try testing.expectEqual(Key.left, q.pop().?);
    try testing.expect(q.pop() == null);
}
