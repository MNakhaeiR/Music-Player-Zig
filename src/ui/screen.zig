//! A double-buffered character grid.
//!
//! Drawing goes into a back buffer of cells; `flush` compares it with what the
//! terminal already shows and emits only the differences. That is what keeps a
//! 30 fps spectrum display from flickering and from flooding the terminal with
//! redundant escape sequences — a full 120x40 redraw is ~10 KB, while a typical
//! frame of this UI changes a few hundred cells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn lerp(a: Rgb, b: Rgb, t: f32) Rgb {
        const u = std.math.clamp(t, 0, 1);
        return .{
            .r = @intFromFloat(@round(@as(f32, @floatFromInt(a.r)) * (1 - u) +
                @as(f32, @floatFromInt(b.r)) * u)),
            .g = @intFromFloat(@round(@as(f32, @floatFromInt(a.g)) * (1 - u) +
                @as(f32, @floatFromInt(b.g)) * u)),
            .b = @intFromFloat(@round(@as(f32, @floatFromInt(a.b)) * (1 - u) +
                @as(f32, @floatFromInt(b.b)) * u)),
        };
    }

    /// Scale brightness, for dimming inactive elements.
    pub fn scale(c: Rgb, f: f32) Rgb {
        return .{
            .r = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c.r)) * f, 0, 255)),
            .g = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c.g)) * f, 0, 255)),
            .b = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(c.b)) * f, 0, 255)),
        };
    }
};

pub const Color = union(enum) {
    /// The terminal's own foreground or background.
    default,
    rgb: Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .rgb => |ac| switch (b) {
                .default => false,
                .rgb => |bc| ac.r == bc.r and ac.g == bc.g and ac.b == bc.b,
            },
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,
    underline: bool = false,

    pub const plain: Style = .{};

    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.bold == b.bold and a.dim == b.dim and
            a.reverse == b.reverse and a.underline == b.underline;
    }

    pub fn withFg(s: Style, c: Rgb) Style {
        var out = s;
        out.fg = .{ .rgb = c };
        return out;
    }

    pub fn withBg(s: Style, c: Rgb) Style {
        var out = s;
        out.bg = .{ .rgb = c };
        return out;
    }
};

pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.style.eql(b.style);
    }
};

/// Box-drawing pieces, as a set so the UI can pick a style.
pub const BorderSet = struct {
    tl: u21,
    tr: u21,
    bl: u21,
    br: u21,
    h: u21,
    v: u21,

    pub const rounded: BorderSet = .{
        .tl = '╭',
        .tr = '╮',
        .bl = '╰',
        .br = '╯',
        .h = '─',
        .v = '│',
    };
    pub const sharp: BorderSet = .{
        .tl = '┌',
        .tr = '┐',
        .bl = '└',
        .br = '┘',
        .h = '─',
        .v = '│',
    };
    pub const double: BorderSet = .{
        .tl = '╔',
        .tr = '╗',
        .bl = '╚',
        .br = '╝',
        .h = '═',
        .v = '║',
    };
    /// For terminals that cannot render box drawing.
    pub const ascii: BorderSet = .{
        .tl = '+',
        .tr = '+',
        .bl = '+',
        .br = '+',
        .h = '-',
        .v = '|',
    };
};

pub const Screen = struct {
    gpa: Allocator,
    width: u16,
    height: u16,
    /// What we want the terminal to show.
    cells: []Cell,
    /// What it currently shows.
    prev: []Cell,
    /// Set when the next flush must repaint everything.
    dirty_all: bool = true,

    pub fn init(gpa: Allocator, width: u16, height: u16) Allocator.Error!Screen {
        const n = @as(usize, width) * height;
        const cells = try gpa.alloc(Cell, n);
        errdefer gpa.free(cells);
        const prev = try gpa.alloc(Cell, n);
        @memset(cells, .{});
        // Fill `prev` with something that cannot match, so the first flush
        // paints every cell.
        @memset(prev, .{ .ch = 0 });
        return .{
            .gpa = gpa,
            .width = width,
            .height = height,
            .cells = cells,
            .prev = prev,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.cells);
        self.gpa.free(self.prev);
        self.* = undefined;
    }

    pub fn resize(self: *Screen, width: u16, height: u16) Allocator.Error!void {
        if (width == self.width and height == self.height) return;
        const n = @as(usize, width) * height;
        const cells = try self.gpa.alloc(Cell, n);
        const prev = try self.gpa.alloc(Cell, n);
        self.gpa.free(self.cells);
        self.gpa.free(self.prev);
        self.cells = cells;
        self.prev = prev;
        self.width = width;
        self.height = height;
        @memset(self.cells, .{});
        @memset(self.prev, .{ .ch = 0 });
        self.dirty_all = true;
    }

    pub fn clear(self: *Screen, style: Style) void {
        @memset(self.cells, .{ .ch = ' ', .style = style });
    }

    /// Force the next flush to repaint everything, e.g. after the terminal
    /// has been scrolled by something else.
    pub fn invalidate(self: *Screen) void {
        self.dirty_all = true;
    }

    inline fn index(self: *const Screen, x: u16, y: u16) ?usize {
        if (x >= self.width or y >= self.height) return null;
        return @as(usize, y) * self.width + x;
    }

    pub fn set(self: *Screen, x: u16, y: u16, ch: u21, style: Style) void {
        const i = self.index(x, y) orelse return;
        self.cells[i] = .{ .ch = ch, .style = style };
    }

    pub fn get(self: *const Screen, x: u16, y: u16) ?Cell {
        const i = self.index(x, y) orelse return null;
        return self.cells[i];
    }

    /// Draw UTF-8 text, clipped to `max_width` columns and to the screen edge.
    /// Returns the number of columns written.
    pub fn text(self: *Screen, x: u16, y: u16, s: []const u8, max_width: u16, style: Style) u16 {
        if (y >= self.height or x >= self.width) return 0;
        const limit = @min(max_width, self.width - x);
        var col: u16 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
        while (col < limit) {
            const cp = it.nextCodepoint() orelse break;
            // Control characters would move the cursor unpredictably.
            if (cp < 0x20 or cp == 0x7F) continue;
            self.set(x + col, y, cp, style);
            col += 1;
        }
        return col;
    }

    /// Draw text, replacing the tail with an ellipsis if it does not fit.
    pub fn textEllipsis(
        self: *Screen,
        x: u16,
        y: u16,
        s: []const u8,
        max_width: u16,
        style: Style,
    ) u16 {
        if (max_width == 0) return 0;
        const needed = displayWidth(s);
        if (needed <= max_width) return self.text(x, y, s, max_width, style);
        if (max_width == 1) return self.text(x, y, "…", 1, style);
        const written = self.text(x, y, s, max_width - 1, style);
        _ = self.text(x + written, y, "…", 1, style);
        return written + 1;
    }

    /// Draw text right-aligned within `[x, x+width)`.
    pub fn textRight(
        self: *Screen,
        x: u16,
        y: u16,
        s: []const u8,
        width: u16,
        style: Style,
    ) void {
        const w = displayWidth(s);
        if (w >= width) {
            _ = self.textEllipsis(x, y, s, width, style);
            return;
        }
        _ = self.text(x + (width - w), y, s, w, style);
    }

    /// Draw text centred within `[x, x+width)`.
    pub fn textCenter(
        self: *Screen,
        x: u16,
        y: u16,
        s: []const u8,
        width: u16,
        style: Style,
    ) void {
        const w = displayWidth(s);
        if (w >= width) {
            _ = self.textEllipsis(x, y, s, width, style);
            return;
        }
        _ = self.text(x + (width - w) / 2, y, s, w, style);
    }

    pub fn fill(self: *Screen, x: u16, y: u16, w: u16, h: u16, ch: u21, style: Style) void {
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            var col: u16 = 0;
            while (col < w) : (col += 1) {
                self.set(x + col, y + row, ch, style);
            }
        }
    }

    pub fn hline(self: *Screen, x: u16, y: u16, w: u16, ch: u21, style: Style) void {
        var i: u16 = 0;
        while (i < w) : (i += 1) self.set(x + i, y, ch, style);
    }

    pub fn vline(self: *Screen, x: u16, y: u16, h: u16, ch: u21, style: Style) void {
        var i: u16 = 0;
        while (i < h) : (i += 1) self.set(x, y + i, ch, style);
    }

    /// Draw a box, optionally with a title inset into the top edge.
    pub fn box(
        self: *Screen,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
        border: BorderSet,
        style: Style,
        title: ?[]const u8,
    ) void {
        if (w < 2 or h < 2) return;
        self.set(x, y, border.tl, style);
        self.set(x + w - 1, y, border.tr, style);
        self.set(x, y + h - 1, border.bl, style);
        self.set(x + w - 1, y + h - 1, border.br, style);
        self.hline(x + 1, y, w - 2, border.h, style);
        self.hline(x + 1, y + h - 1, w - 2, border.h, style);
        self.vline(x, y + 1, h - 2, border.v, style);
        self.vline(x + w - 1, y + 1, h - 2, border.v, style);

        if (title) |t| {
            if (w >= 6) {
                const avail = w - 4;
                _ = self.text(x + 2, y, " ", 1, style);
                const used = self.textEllipsis(x + 3, y, t, avail - 1, style);
                _ = self.text(x + 3 + used, y, " ", 1, style);
            }
        }
    }

    /// Emit the difference between `cells` and `prev` to `w`, then swap.
    pub fn flush(self: *Screen, w: *Io.Writer) Io.Writer.Error!void {
        var current_style: ?Style = null;
        var cursor_x: u16 = std.math.maxInt(u16);
        var cursor_y: u16 = std.math.maxInt(u16);

        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.width) {
                const i = @as(usize, y) * self.width + x;
                if (!self.dirty_all and self.cells[i].eql(self.prev[i])) {
                    x += 1;
                    continue;
                }

                // Reposition only when the run does not continue from where
                // the cursor already is.
                if (cursor_y != y or cursor_x != x) {
                    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    cursor_x = x;
                    cursor_y = y;
                }

                // Emit a run of cells sharing one style.
                const run_style = self.cells[i].style;
                if (current_style == null or !current_style.?.eql(run_style)) {
                    try writeStyle(w, run_style);
                    current_style = run_style;
                }

                while (x < self.width) {
                    const j = @as(usize, y) * self.width + x;
                    const cell = self.cells[j];
                    if (!cell.style.eql(run_style)) break;
                    if (!self.dirty_all and cell.eql(self.prev[j])) break;
                    try writeCodepoint(w, cell.ch);
                    self.prev[j] = cell;
                    x += 1;
                    cursor_x += 1;
                }
            }
        }

        if (current_style != null) try w.writeAll("\x1b[0m");
        self.dirty_all = false;
    }

    fn writeCodepoint(w: *Io.Writer, cp: u21) Io.Writer.Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            try w.writeByte(' ');
            return;
        };
        try w.writeAll(buf[0..n]);
    }

    fn writeStyle(w: *Io.Writer, s: Style) Io.Writer.Error!void {
        // Always reset first: computing the minimal transition between two
        // arbitrary styles is not worth the complexity, and a reset plus the
        // attributes is a handful of bytes.
        try w.writeAll("\x1b[0m");
        if (s.bold) try w.writeAll("\x1b[1m");
        if (s.dim) try w.writeAll("\x1b[2m");
        if (s.underline) try w.writeAll("\x1b[4m");
        if (s.reverse) try w.writeAll("\x1b[7m");
        switch (s.fg) {
            .default => {},
            .rgb => |c| try w.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        }
        switch (s.bg) {
            .default => {},
            .rgb => |c| try w.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        }
    }
};

/// Column count for a UTF-8 string, counting one column per code point.
///
/// This is correct for Latin, Greek, Cyrillic and the box-drawing and block
/// characters the UI uses. East Asian wide characters occupy two columns and
/// will under-count; the layout clips rather than wraps, so the failure mode
/// is a truncated title rather than a broken frame.
pub fn displayWidth(s: []const u8) u16 {
    var count: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7F) continue;
        count += 1;
    }
    return count;
}

/// The eighth-block characters, for sub-cell bar resolution.
pub const blocks = [_]u21{ ' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' };

/// Pick a block character for a fractional fill in 0..1.
pub fn blockFor(fraction: f32) u21 {
    const f = std.math.clamp(fraction, 0, 1);
    const i: usize = @intFromFloat(@round(f * 8.0));
    return blocks[@min(i, blocks.len - 1)];
}

const testing = std.testing;

/// Render a screen to a string, for assertions.
fn renderToString(gpa: Allocator, screen: *Screen) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        var x: u16 = 0;
        while (x < screen.width) : (x += 1) {
            const cell = screen.get(x, y).?;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch 0;
            try list.appendSlice(gpa, buf[0..n]);
        }
        if (y + 1 < screen.height) try list.append(gpa, '\n');
    }
    return list.toOwnedSlice(gpa);
}

test "text drawing and clipping" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 3);
    defer s.deinit();
    s.clear(.plain);

    try testing.expectEqual(@as(u16, 5), s.text(0, 0, "hello", 10, .plain));
    // Clipped by max_width.
    try testing.expectEqual(@as(u16, 3), s.text(0, 1, "abcdefgh", 3, .plain));
    // Clipped by the screen edge.
    try testing.expectEqual(@as(u16, 2), s.text(8, 2, "xyz", 10, .plain));

    const out = try renderToString(gpa, &s);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "hello     \n" ++
            "abc       \n" ++
            "        xy",
        out,
    );
}

test "ellipsis, right and centre alignment" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 3);
    defer s.deinit();
    s.clear(.plain);

    _ = s.textEllipsis(0, 0, "abcdefghijkl", 6, .plain);
    s.textRight(0, 1, "end", 10, .plain);
    s.textCenter(0, 2, "mid", 9, .plain);

    const out = try renderToString(gpa, &s);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "abcde…    \n" ++
            "       end\n" ++
            "   mid    ",
        out,
    );
}

test "text that exactly fits is not shortened" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 1);
    defer s.deinit();
    s.clear(.plain);
    _ = s.textEllipsis(0, 0, "abcde", 5, .plain);
    const out = try renderToString(gpa, &s);
    defer gpa.free(out);
    try testing.expectEqualStrings("abcde     ", out);
}

test "boxes draw corners, edges and a title" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 4);
    defer s.deinit();
    s.clear(.plain);
    s.box(0, 0, 10, 4, .sharp, .plain, "Hi");

    const out = try renderToString(gpa, &s);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "┌─ Hi ───┐\n" ++
            "│        │\n" ++
            "│        │\n" ++
            "└────────┘",
        out,
    );
}

test "fill, hline and vline" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 6, 4);
    defer s.deinit();
    s.clear(.plain);
    s.fill(1, 1, 2, 2, '#', .plain);
    s.hline(0, 0, 6, '-', .plain);
    s.vline(5, 1, 3, '|', .plain);

    const out = try renderToString(gpa, &s);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        "------\n" ++
            " ##  |\n" ++
            " ##  |\n" ++
            "     |",
        out,
    );
}

test "out of bounds drawing is ignored" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 4, 2);
    defer s.deinit();
    s.clear(.plain);
    s.set(100, 100, 'x', .plain);
    s.set(4, 0, 'x', .plain);
    _ = s.text(10, 10, "nope", 4, .plain);
    s.box(0, 0, 1, 1, .sharp, .plain, null); // too small
    try testing.expect(s.get(100, 100) == null);
}

test "flush emits only what changed" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 20, 2);
    defer s.deinit();

    var buf: [8192]u8 = undefined;
    var w = Io.Writer.fixed(&buf);

    s.clear(.plain);
    _ = s.text(0, 0, "first frame", 20, .plain);
    try s.flush(&w);
    const first_len = w.end;
    try testing.expect(first_len > 20); // a full paint

    // Nothing changed: the second flush should emit nothing at all.
    w = Io.Writer.fixed(&buf);
    try s.flush(&w);
    try testing.expectEqual(@as(usize, 0), w.end);

    // Change one character: the update should be tiny.
    w = Io.Writer.fixed(&buf);
    s.set(3, 0, 'X', .plain);
    try s.flush(&w);
    try testing.expect(w.end > 0);
    try testing.expect(w.end < 32);
    // And it should contain a cursor move to row 1, column 4.
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "\x1b[1;4H") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "X") != null);
}

test "invalidate forces a full repaint" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 2);
    defer s.deinit();

    var buf: [8192]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    s.clear(.plain);
    try s.flush(&w);

    w = Io.Writer.fixed(&buf);
    try s.flush(&w);
    try testing.expectEqual(@as(usize, 0), w.end);

    s.invalidate();
    w = Io.Writer.fixed(&buf);
    try s.flush(&w);
    try testing.expect(w.end > 20);
}

test "styles produce truecolor escapes" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 5, 1);
    defer s.deinit();
    s.clear(.plain);
    _ = s.text(0, 0, "hi", 5, .{
        .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
        .bold = true,
    });

    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try s.flush(&w);
    const out = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;128;0m") != null);
}

test "resize reallocates and forces a repaint" {
    const gpa = testing.allocator;
    var s = try Screen.init(gpa, 10, 2);
    defer s.deinit();
    try s.resize(20, 5);
    try testing.expectEqual(@as(u16, 20), s.width);
    try testing.expectEqual(@as(u16, 5), s.height);
    try testing.expectEqual(@as(usize, 100), s.cells.len);
    try testing.expect(s.dirty_all);
    // Resizing to the same size is a no-op.
    s.dirty_all = false;
    try s.resize(20, 5);
    try testing.expect(!s.dirty_all);
}

test "display width counts code points, not bytes" {
    try testing.expectEqual(@as(u16, 5), displayWidth("hello"));
    try testing.expectEqual(@as(u16, 4), displayWidth("caf\u{00E9}"));
    try testing.expectEqual(@as(u16, 1), displayWidth("\u{2588}"));
    try testing.expectEqual(@as(u16, 0), displayWidth(""));
    // Control characters do not occupy a column.
    try testing.expectEqual(@as(u16, 2), displayWidth("a\x01b"));
}

test "block characters span the fill range" {
    try testing.expectEqual(@as(u21, ' '), blockFor(0));
    try testing.expectEqual(@as(u21, '█'), blockFor(1));
    try testing.expectEqual(@as(u21, '█'), blockFor(5)); // clamped
    try testing.expectEqual(@as(u21, '▄'), blockFor(0.5));
    try testing.expectEqual(@as(u21, ' '), blockFor(-1)); // clamped
}

test "colour blending" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const mid = black.lerp(white, 0.5);
    try testing.expectEqual(@as(u8, 128), mid.r);
    try testing.expectEqual(white, black.lerp(white, 1.0));
    try testing.expectEqual(black, black.lerp(white, 0.0));

    const dim = white.scale(0.5);
    try testing.expectEqual(@as(u8, 127), dim.r);
}

test "style and colour equality" {
    const default_color: Color = .default;
    try testing.expect(default_color.eql(.default));
    try testing.expect(!default_color.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    const a: Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    try testing.expect(a.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try testing.expect(!a.eql(.{ .rgb = .{ .r = 9, .g = 2, .b = 3 } }));

    try testing.expect(Style.plain.eql(.{}));
    try testing.expect(!Style.plain.eql(.{ .bold = true }));
}
