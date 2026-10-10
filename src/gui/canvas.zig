//! A software renderer over a 32-bit BGRA pixel buffer.
//!
//! Everything is drawn by hand into the pixel array rather than through GDI
//! primitives: GDI has no alpha blending, no anti-aliasing and no gradients,
//! all of which this interface leans on heavily. Text is the exception — it
//! goes through GDI onto the same surface, because reimplementing font
//! rasterization and hinting to the standard a desktop user expects is not a
//! reasonable trade.
//!
//! Anti-aliasing for rounded rectangles and circles comes from analytic
//! coverage: for each pixel, the signed distance to the shape's edge is
//! converted into an alpha value. That is cheap, exact enough at these sizes,
//! and avoids any supersampling pass.

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Parse `#rrggbb` or `#rrggbbaa`.
    ///
    /// The digits are decoded by hand rather than with `parseInt`, because
    /// `parseInt(...) catch @compileError(...)` does not do what it looks
    /// like: `@compileError` fires whenever the branch is analyzed, not only
    /// when the parse actually fails, so every call site would be an error.
    /// Inside a comptime loop a `switch` prong is only analyzed if it is
    /// taken, which gives a genuine compile-time check.
    pub fn hex(comptime text: []const u8) Color {
        return comptime blk: {
            const s = if (text.len > 0 and text[0] == '#') text[1..] else text;
            if (s.len != 6 and s.len != 8) {
                @compileError("colour must be #rrggbb or #rrggbbaa, got " ++ text);
            }
            var v: u32 = 0;
            for (s) |ch| {
                const digit: u32 = switch (ch) {
                    '0'...'9' => ch - '0',
                    'a'...'f' => ch - 'a' + 10,
                    'A'...'F' => ch - 'A' + 10,
                    else => @compileError("invalid hex digit in colour " ++ text),
                };
                v = v * 16 + digit;
            }
            if (s.len == 8) break :blk Color{
                .r = @truncate(v >> 24),
                .g = @truncate(v >> 16),
                .b = @truncate(v >> 8),
                .a = @truncate(v),
            };
            break :blk Color{
                .r = @truncate(v >> 16),
                .g = @truncate(v >> 8),
                .b = @truncate(v),
            };
        };
    }

    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// Scale alpha by a 0..1 factor.
    pub fn fade(c: Color, f: f32) Color {
        const a = std.math.clamp(f, 0, 1) * @as(f32, @floatFromInt(c.a));
        return c.withAlpha(@intFromFloat(@round(a)));
    }

    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const u = std.math.clamp(t, 0, 1);
        return .{
            .r = mixByte(a.r, b.r, u),
            .g = mixByte(a.g, b.g, u),
            .b = mixByte(a.b, b.b, u),
            .a = mixByte(a.a, b.a, u),
        };
    }

    /// Multiply the channels, for dimming or highlighting.
    pub fn scale(c: Color, f: f32) Color {
        return .{
            .r = clampByte(@as(f32, @floatFromInt(c.r)) * f),
            .g = clampByte(@as(f32, @floatFromInt(c.g)) * f),
            .b = clampByte(@as(f32, @floatFromInt(c.b)) * f),
            .a = c.a,
        };
    }

    pub fn toColorRef(c: Color) win32.COLORREF {
        return win32.rgb(c.r, c.g, c.b);
    }

    /// Relative luminance, for picking readable text over a background.
    pub fn luminance(c: Color) f32 {
        return (0.2126 * @as(f32, @floatFromInt(c.r)) +
            0.7152 * @as(f32, @floatFromInt(c.g)) +
            0.0722 * @as(f32, @floatFromInt(c.b))) / 255.0;
    }
};

fn mixByte(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af * (1 - t) + bf * t));
}

fn clampByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }
    pub fn centerX(r: Rect) f32 {
        return r.x + r.w * 0.5;
    }
    pub fn centerY(r: Rect) f32 {
        return r.y + r.h * 0.5;
    }

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.right() and py >= r.y and py < r.bottom();
    }

    pub fn inset(r: Rect, amount: f32) Rect {
        return .{
            .x = r.x + amount,
            .y = r.y + amount,
            .w = @max(0, r.w - amount * 2),
            .h = @max(0, r.h - amount * 2),
        };
    }

    pub fn insetXY(r: Rect, dx: f32, dy: f32) Rect {
        return .{
            .x = r.x + dx,
            .y = r.y + dy,
            .w = @max(0, r.w - dx * 2),
            .h = @max(0, r.h - dy * 2),
        };
    }

    pub fn translate(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }

    /// Split `amount` off the top, returning the strip and the remainder.
    pub fn splitTop(r: Rect, amount: f32) struct { top: Rect, rest: Rect } {
        const a = @min(amount, r.h);
        return .{
            .top = .{ .x = r.x, .y = r.y, .w = r.w, .h = a },
            .rest = .{ .x = r.x, .y = r.y + a, .w = r.w, .h = r.h - a },
        };
    }

    pub fn splitBottom(r: Rect, amount: f32) struct { bottom: Rect, rest: Rect } {
        const a = @min(amount, r.h);
        return .{
            .bottom = .{ .x = r.x, .y = r.bottom() - a, .w = r.w, .h = a },
            .rest = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - a },
        };
    }

    pub fn splitLeft(r: Rect, amount: f32) struct { left: Rect, rest: Rect } {
        const a = @min(amount, r.w);
        return .{
            .left = .{ .x = r.x, .y = r.y, .w = a, .h = r.h },
            .rest = .{ .x = r.x + a, .y = r.y, .w = r.w - a, .h = r.h },
        };
    }

    pub fn splitRight(r: Rect, amount: f32) struct { right: Rect, rest: Rect } {
        const a = @min(amount, r.w);
        return .{
            .right = .{ .x = r.right() - a, .y = r.y, .w = a, .h = r.h },
            .rest = .{ .x = r.x, .y = r.y, .w = r.w - a, .h = r.h },
        };
    }
};

pub const TextAlign = enum { left, center, right };

pub const FontWeight = enum {
    regular,
    medium,
    semibold,
    bold,

    fn toGdi(w: FontWeight) i32 {
        return switch (w) {
            .regular => win32.FW_NORMAL,
            .medium => win32.FW_MEDIUM,
            .semibold => win32.FW_SEMIBOLD,
            .bold => win32.FW_BOLD,
        };
    }
};

/// A GDI font, created once and reused.
pub const Font = struct {
    handle: win32.HFONT,
    height_px: i32,

    pub fn create(face: []const u8, px: i32, weight: FontWeight) ?Font {
        var name_buf: [64]u16 = undefined;
        const name = win32.toWide(&name_buf, face) orelse return null;
        // A negative height asks for a character height in pixels rather than
        // a cell height, which is what a layout in pixels wants.
        const h = win32.CreateFontW(
            -px,
            0,
            0,
            0,
            weight.toGdi(),
            0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_TT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH | win32.FF_DONTCARE,
            name.ptr,
        ) orelse return null;
        return .{ .handle = h, .height_px = px };
    }

    pub fn destroy(f: Font) void {
        _ = win32.DeleteObject(@ptrCast(f.handle));
    }
};

/// A 32-bit BGRA drawing surface backed by a GDI DIB section.
pub const Canvas = struct {
    width: i32,
    height: i32,
    /// BGRA, bottom-up rows are avoided by using a negative biHeight, so row 0
    /// is the top of the image.
    pixels: []u32,
    stride: usize,

    bitmap: win32.HBITMAP,
    /// Memory DC with `bitmap` selected into it, for GDI text.
    dc: win32.HDC,
    old_bitmap: ?win32.HGDIOBJ,

    /// Clip rectangle applied to every drawing call.
    clip: Rect,

    pub fn create(width: i32, height: i32) ?Canvas {
        if (width <= 0 or height <= 0) return null;

        const info: win32.BITMAPINFO = .{
            .bmiHeader = .{
                .biSize = @sizeOf(win32.BITMAPINFOHEADER),
                .biWidth = width,
                // Negative height gives a top-down DIB, so row 0 is the top.
                .biHeight = -height,
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = win32.BI_RGB,
                .biSizeImage = 0,
                .biXPelsPerMeter = 0,
                .biYPelsPerMeter = 0,
                .biClrUsed = 0,
                .biClrImportant = 0,
            },
            .bmiColors = .{0},
        };

        const dc = win32.CreateCompatibleDC(null) orelse return null;
        var bits: ?[*]u8 = null;
        const bitmap = win32.CreateDIBSection(
            dc,
            &info,
            win32.DIB_RGB_COLORS,
            &bits,
            null,
            0,
        ) orelse {
            _ = win32.DeleteDC(dc);
            return null;
        };
        const raw = bits orelse {
            _ = win32.DeleteObject(@ptrCast(bitmap));
            _ = win32.DeleteDC(dc);
            return null;
        };

        const old = win32.SelectObject(dc, @ptrCast(bitmap));
        _ = win32.SetBkMode(dc, win32.TRANSPARENT);

        const count: usize = @intCast(width * height);
        const pixels: []u32 = @as([*]u32, @ptrCast(@alignCast(raw)))[0..count];

        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .stride = @intCast(width),
            .bitmap = bitmap,
            .dc = dc,
            .old_bitmap = old,
            .clip = .init(0, 0, @floatFromInt(width), @floatFromInt(height)),
        };
    }

    pub fn destroy(c: *Canvas) void {
        if (c.old_bitmap) |old| _ = win32.SelectObject(c.dc, old);
        _ = win32.DeleteObject(@ptrCast(c.bitmap));
        _ = win32.DeleteDC(c.dc);
        c.* = undefined;
    }

    pub fn bounds(c: *const Canvas) Rect {
        return .init(0, 0, @floatFromInt(c.width), @floatFromInt(c.height));
    }

    pub fn resetClip(c: *Canvas) void {
        c.clip = c.bounds();
    }

    /// Intersect the clip rectangle, returning the previous one so the caller
    /// can restore it.
    pub fn pushClip(c: *Canvas, r: Rect) Rect {
        const old = c.clip;
        const x0 = @max(old.x, r.x);
        const y0 = @max(old.y, r.y);
        const x1 = @min(old.right(), r.right());
        const y1 = @min(old.bottom(), r.bottom());
        c.clip = .{
            .x = x0,
            .y = y0,
            .w = @max(0, x1 - x0),
            .h = @max(0, y1 - y0),
        };
        return old;
    }

    pub fn popClip(c: *Canvas, saved: Rect) void {
        c.clip = saved;
    }

    pub fn clear(c: *Canvas, color: Color) void {
        const v = pack(color);
        @memset(c.pixels, v);
    }

    inline fn pack(color: Color) u32 {
        // The DIB is BGRA in memory, i.e. 0xAARRGGBB as a little-endian u32.
        return (@as(u32, color.a) << 24) |
            (@as(u32, color.r) << 16) |
            (@as(u32, color.g) << 8) |
            @as(u32, color.b);
    }

    /// Blend one pixel. `alpha` is 0..1 coverage, multiplied with the colour's
    /// own alpha.
    inline fn blend(c: *Canvas, x: i32, y: i32, color: Color, alpha: f32) void {
        if (alpha <= 0) return;
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        if (fx < c.clip.x or fx >= c.clip.right()) return;
        if (fy < c.clip.y or fy >= c.clip.bottom()) return;

        const a = std.math.clamp(alpha, 0, 1) * (@as(f32, @floatFromInt(color.a)) / 255.0);
        if (a <= 0.0001) return;

        const idx: usize = @intCast(y * c.width + x);
        if (a >= 0.9999) {
            c.pixels[idx] = pack(color);
            return;
        }

        const dst = c.pixels[idx];
        const dr: f32 = @floatFromInt((dst >> 16) & 0xFF);
        const dg: f32 = @floatFromInt((dst >> 8) & 0xFF);
        const db: f32 = @floatFromInt(dst & 0xFF);

        const sr: f32 = @floatFromInt(color.r);
        const sg: f32 = @floatFromInt(color.g);
        const sb: f32 = @floatFromInt(color.b);

        const nr = clampByte(dr + (sr - dr) * a);
        const ng = clampByte(dg + (sg - dg) * a);
        const nb = clampByte(db + (sb - db) * a);
        c.pixels[idx] = (@as(u32, 255) << 24) |
            (@as(u32, nr) << 16) |
            (@as(u32, ng) << 8) |
            @as(u32, nb);
    }

    pub fn fillRect(c: *Canvas, r: Rect, color: Color) void {
        const x0: i32 = @intFromFloat(@floor(@max(r.x, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(r.y, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(r.right(), c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(r.bottom(), c.clip.bottom())));
        if (x1 <= x0 or y1 <= y0) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) c.blend(x, y, color, 1.0);
        }
    }

    /// Fill with a vertical gradient from `top` to `bottom`.
    pub fn fillRectGradient(c: *Canvas, r: Rect, top: Color, bottom: Color) void {
        const y0: i32 = @intFromFloat(@floor(@max(r.y, c.clip.y)));
        const y1: i32 = @intFromFloat(@ceil(@min(r.bottom(), c.clip.bottom())));
        if (y1 <= y0 or r.h <= 0) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            const t = (@as(f32, @floatFromInt(y)) - r.y) / r.h;
            const color = top.lerp(bottom, t);
            c.fillRect(.{ .x = r.x, .y = @floatFromInt(y), .w = r.w, .h = 1 }, color);
        }
    }

    /// Fill with a horizontal gradient from `left` to `right`.
    pub fn fillRectGradientH(c: *Canvas, r: Rect, left: Color, right: Color) void {
        const x0: i32 = @intFromFloat(@floor(@max(r.x, c.clip.x)));
        const x1: i32 = @intFromFloat(@ceil(@min(r.right(), c.clip.right())));
        if (x1 <= x0 or r.w <= 0) return;

        var x = x0;
        while (x < x1) : (x += 1) {
            const t = (@as(f32, @floatFromInt(x)) - r.x) / r.w;
            const color = left.lerp(right, t);
            c.fillRect(.{ .x = @floatFromInt(x), .y = r.y, .w = 1, .h = r.h }, color);
        }
    }

    /// Signed distance from a point to a rounded rectangle; negative inside.
    fn roundedDistance(r: Rect, radius: f32, px: f32, py: f32) f32 {
        const half_w = r.w * 0.5;
        const half_h = r.h * 0.5;
        const rad = @min(radius, @min(half_w, half_h));
        const cx = r.x + half_w;
        const cy = r.y + half_h;
        // Distance in the "box with corners pulled in" space.
        const qx = @abs(px - cx) - (half_w - rad);
        const qy = @abs(py - cy) - (half_h - rad);
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
    }

    pub fn fillRoundedRect(c: *Canvas, r: Rect, radius: f32, color: Color) void {
        if (radius <= 0.5) {
            c.fillRect(r, color);
            return;
        }
        const x0: i32 = @intFromFloat(@floor(@max(r.x, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(r.y, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(r.right(), c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(r.bottom(), c.clip.bottom())));

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const d = roundedDistance(r, radius, px, py);
                // Convert the distance into coverage over one pixel.
                const coverage = std.math.clamp(0.5 - d, 0, 1);
                c.blend(x, y, color, coverage);
            }
        }
    }

    pub fn fillRoundedRectGradient(
        c: *Canvas,
        r: Rect,
        radius: f32,
        top: Color,
        bottom: Color,
    ) void {
        const x0: i32 = @intFromFloat(@floor(@max(r.x, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(r.y, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(r.right(), c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(r.bottom(), c.clip.bottom())));
        if (r.h <= 0) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            const t = (@as(f32, @floatFromInt(y)) + 0.5 - r.y) / r.h;
            const color = top.lerp(bottom, t);
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const d = roundedDistance(r, radius, px, py);
                const coverage = std.math.clamp(0.5 - d, 0, 1);
                c.blend(x, y, color, coverage);
            }
        }
    }

    pub fn strokeRoundedRect(
        c: *Canvas,
        r: Rect,
        radius: f32,
        thickness: f32,
        color: Color,
    ) void {
        const x0: i32 = @intFromFloat(@floor(@max(r.x - 1, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(r.y - 1, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(r.right() + 1, c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(r.bottom() + 1, c.clip.bottom())));
        const half = thickness * 0.5;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const d = roundedDistance(r, radius, px, py);
                // Coverage of a band of width `thickness` centred on the edge.
                const coverage = std.math.clamp(0.5 - (@abs(d) - half), 0, 1);
                c.blend(x, y, color, coverage);
            }
        }
    }

    pub fn fillCircle(c: *Canvas, cx: f32, cy: f32, radius: f32, color: Color) void {
        const x0: i32 = @intFromFloat(@floor(@max(cx - radius - 1, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(cy - radius - 1, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(cx + radius + 1, c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(cy + radius + 1, c.clip.bottom())));

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(px * px + py * py) - radius;
                const coverage = std.math.clamp(0.5 - d, 0, 1);
                c.blend(x, y, color, coverage);
            }
        }
    }

    pub fn strokeCircle(
        c: *Canvas,
        cx: f32,
        cy: f32,
        radius: f32,
        thickness: f32,
        color: Color,
    ) void {
        const outer = radius + thickness;
        const x0: i32 = @intFromFloat(@floor(@max(cx - outer - 1, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(cy - outer - 1, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(cx + outer + 1, c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(cy + outer + 1, c.clip.bottom())));
        const half = thickness * 0.5;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const py = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(px * px + py * py) - radius;
                const coverage = std.math.clamp(0.5 - (@abs(d) - half), 0, 1);
                c.blend(x, y, color, coverage);
            }
        }
    }

    /// Anti-aliased line, drawn as a distance field around the segment.
    pub fn drawLine(
        c: *Canvas,
        ax: f32,
        ay: f32,
        bx: f32,
        by: f32,
        thickness: f32,
        color: Color,
    ) void {
        const minx = @min(ax, bx) - thickness - 1;
        const maxx = @max(ax, bx) + thickness + 1;
        const miny = @min(ay, by) - thickness - 1;
        const maxy = @max(ay, by) + thickness + 1;

        const x0: i32 = @intFromFloat(@floor(@max(minx, c.clip.x)));
        const y0: i32 = @intFromFloat(@floor(@max(miny, c.clip.y)));
        const x1: i32 = @intFromFloat(@ceil(@min(maxx, c.clip.right())));
        const y1: i32 = @intFromFloat(@ceil(@min(maxy, c.clip.bottom())));

        const dx = bx - ax;
        const dy = by - ay;
        const len_sq = dx * dx + dy * dy;
        const half = thickness * 0.5;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - ax;
                const py = @as(f32, @floatFromInt(y)) + 0.5 - ay;
                // Project onto the segment and clamp to its ends.
                const t = if (len_sq <= 0.0001)
                    0.0
                else
                    std.math.clamp((px * dx + py * dy) / len_sq, 0, 1);
                const qx = px - dx * t;
                const qy = py - dy * t;
                const d = @sqrt(qx * qx + qy * qy) - half;
                c.blend(x, y, color, std.math.clamp(0.5 - d, 0, 1));
            }
        }
    }

    /// A soft shadow under a rounded rectangle, for lifting panels off the
    /// background. Approximated by stacking translucent outlines rather than a
    /// true blur, which is indistinguishable at these radii and far cheaper.
    pub fn dropShadow(c: *Canvas, r: Rect, radius: f32, spread: f32, color: Color) void {
        var i: f32 = spread;
        while (i >= 1) : (i -= 1) {
            const t = i / spread;
            const alpha = (1.0 - t) * 0.5;
            c.strokeRoundedRect(
                r.inset(-i).translate(0, i * 0.35),
                radius + i,
                1.6,
                color.fade(alpha),
            );
        }
    }

    // --- text ---------------------------------------------------------------

    /// Draw text with GDI onto this surface. Returns the width used.
    pub fn text(
        c: *Canvas,
        font: Font,
        r: Rect,
        s: []const u8,
        color: Color,
        alignment: TextAlign,
        ellipsis: bool,
    ) i32 {
        if (s.len == 0) return 0;
        var buf: [1024]u16 = undefined;
        const wide = win32.toWide(&buf, s) orelse return 0;

        const old_font = win32.SelectObject(c.dc, @ptrCast(font.handle));
        defer {
            if (old_font) |f| _ = win32.SelectObject(c.dc, f);
        }
        _ = win32.SetTextColor(c.dc, color.toColorRef());
        _ = win32.SetBkMode(c.dc, win32.TRANSPARENT);

        // GDI clips to the rectangle it is given, so intersect with our clip
        // to keep text inside panels.
        const cx0 = @max(r.x, c.clip.x);
        const cy0 = @max(r.y, c.clip.y);
        const cx1 = @min(r.right(), c.clip.right());
        const cy1 = @min(r.bottom(), c.clip.bottom());
        if (cx1 <= cx0 or cy1 <= cy0) return 0;

        var rect: win32.RECT = .{
            .left = @intFromFloat(@floor(cx0)),
            .top = @intFromFloat(@floor(cy0)),
            .right = @intFromFloat(@ceil(cx1)),
            .bottom = @intFromFloat(@ceil(cy1)),
        };

        var flags: u32 = win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_NOPREFIX;
        flags |= switch (alignment) {
            .left => win32.DT_LEFT,
            .center => win32.DT_CENTER,
            .right => win32.DT_RIGHT,
        };
        if (ellipsis) flags |= win32.DT_END_ELLIPSIS;

        _ = win32.DrawTextW(c.dc, wide.ptr, @intCast(wide.len), &rect, flags);
        return c.measure(font, s);
    }

    /// Width of `s` in pixels for `font`.
    pub fn measure(c: *Canvas, font: Font, s: []const u8) i32 {
        if (s.len == 0) return 0;
        var buf: [1024]u16 = undefined;
        const wide = win32.toWide(&buf, s) orelse return 0;

        const old_font = win32.SelectObject(c.dc, @ptrCast(font.handle));
        defer {
            if (old_font) |f| _ = win32.SelectObject(c.dc, f);
        }

        var size: win32.SIZE = .{ .cx = 0, .cy = 0 };
        if (win32.GetTextExtentPoint32W(c.dc, wide.ptr, @intCast(wide.len), &size) == 0) {
            return 0;
        }
        return size.cx;
    }

    /// Blit the finished frame to a window DC.
    pub fn present(c: *Canvas, target: win32.HDC) void {
        _ = win32.BitBlt(target, 0, 0, c.width, c.height, c.dc, 0, 0, win32.SRCCOPY);
    }

    /// Write the surface as a 32-bit BMP. Used by `--screenshot`, which is how
    /// the layout gets reviewed without a display.
    pub fn writeBmp(c: *const Canvas, writer: *std.Io.Writer) !void {
        const pixel_bytes: u32 = @intCast(c.pixels.len * 4);
        const header_size: u32 = 14 + 40;

        const file_header: win32.BITMAPFILEHEADER = .{
            .bfType = 0x4D42, // "BM"
            .bfSize = header_size + pixel_bytes,
            .bfReserved1 = 0,
            .bfReserved2 = 0,
            .bfOffBits = header_size,
        };
        try writer.writeAll(std.mem.asBytes(&file_header));

        const info: win32.BITMAPINFOHEADER = .{
            .biSize = 40,
            .biWidth = c.width,
            // Negative for top-down, matching our row order.
            .biHeight = -c.height,
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = win32.BI_RGB,
            .biSizeImage = pixel_bytes,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        };
        try writer.writeAll(std.mem.asBytes(&info));

        // The DIB is already BGRA, which is what a 32-bit BMP stores. Force
        // alpha opaque so viewers that honour it do not show the frame as
        // transparent where nothing set it.
        var row_buf: [8192]u32 = undefined;
        var y: usize = 0;
        while (y < @as(usize, @intCast(c.height))) : (y += 1) {
            const row = c.pixels[y * c.stride ..][0..@intCast(c.width)];
            const n = @min(row.len, row_buf.len);
            for (row[0..n], row_buf[0..n]) |src, *dst| dst.* = src | 0xFF00_0000;
            try writer.writeAll(std.mem.sliceAsBytes(row_buf[0..n]));
        }
    }
};

const testing = std.testing;

test "colour helpers" {
    const red = Color.rgb(255, 0, 0);
    try testing.expectEqual(@as(u8, 255), red.r);
    try testing.expectEqual(@as(u8, 255), red.a);

    const h = Color.hex("#3366cc");
    try testing.expectEqual(@as(u8, 0x33), h.r);
    try testing.expectEqual(@as(u8, 0x66), h.g);
    try testing.expectEqual(@as(u8, 0xCC), h.b);
    try testing.expectEqual(@as(u8, 255), h.a);

    const ha = Color.hex("#11223344");
    try testing.expectEqual(@as(u8, 0x11), ha.r);
    try testing.expectEqual(@as(u8, 0x44), ha.a);

    const black = Color.rgb(0, 0, 0);
    const white = Color.rgb(255, 255, 255);
    try testing.expectEqual(@as(u8, 128), black.lerp(white, 0.5).r);
    try testing.expectEqual(white, black.lerp(white, 1.0));
    try testing.expectEqual(@as(u8, 128), white.fade(0.5).a);
    // 255 * 0.5 rounds to 128, not 127.
    try testing.expectEqual(@as(u8, 128), white.scale(0.5).r);
    try testing.expectEqual(@as(u8, 255), white.scale(4.0).r); // clamped

    // Luminance distinguishes light from dark backgrounds.
    try testing.expect(white.luminance() > 0.9);
    try testing.expect(black.luminance() < 0.1);
}

test "rect geometry" {
    const r: Rect = .init(10, 20, 100, 50);
    try testing.expectEqual(@as(f32, 110), r.right());
    try testing.expectEqual(@as(f32, 70), r.bottom());
    try testing.expectEqual(@as(f32, 60), r.centerX());
    try testing.expectEqual(@as(f32, 45), r.centerY());

    try testing.expect(r.contains(10, 20));
    try testing.expect(r.contains(109, 69));
    try testing.expect(!r.contains(110, 70));
    try testing.expect(!r.contains(9, 20));

    const i = r.inset(5);
    try testing.expectEqual(@as(f32, 15), i.x);
    try testing.expectEqual(@as(f32, 90), i.w);

    // Over-insetting collapses rather than going negative.
    const collapsed = r.inset(100);
    try testing.expectEqual(@as(f32, 0), collapsed.w);
}

test "rect splitting" {
    const r: Rect = .init(0, 0, 100, 80);

    const t = r.splitTop(20);
    try testing.expectEqual(@as(f32, 20), t.top.h);
    try testing.expectEqual(@as(f32, 20), t.rest.y);
    try testing.expectEqual(@as(f32, 60), t.rest.h);

    const b = r.splitBottom(30);
    try testing.expectEqual(@as(f32, 50), b.bottom.y);
    try testing.expectEqual(@as(f32, 50), b.rest.h);

    const l = r.splitLeft(25);
    try testing.expectEqual(@as(f32, 25), l.left.w);
    try testing.expectEqual(@as(f32, 25), l.rest.x);

    const rr = r.splitRight(40);
    try testing.expectEqual(@as(f32, 60), rr.right.x);
    try testing.expectEqual(@as(f32, 60), rr.rest.w);

    // Splitting off more than exists clamps.
    const over = r.splitTop(500);
    try testing.expectEqual(@as(f32, 80), over.top.h);
    try testing.expectEqual(@as(f32, 0), over.rest.h);
}

test "signed distance to a rounded rect" {
    const r: Rect = .init(0, 0, 100, 100);
    // Centre is deep inside.
    try testing.expect(Canvas.roundedDistance(r, 10, 50, 50) < -40);
    // Just inside an edge.
    try testing.expect(Canvas.roundedDistance(r, 10, 1, 50) < 0);
    // Outside.
    try testing.expect(Canvas.roundedDistance(r, 10, -5, 50) > 0);
    // The corner is cut away by the radius, so a point at (1,1) with a
    // radius of 20 sits outside the shape.
    try testing.expect(Canvas.roundedDistance(r, 20, 1, 1) > 0);
    // And the same point is inside when the corners are square.
    try testing.expect(Canvas.roundedDistance(r, 0, 1, 1) < 0);
}

test "pixel packing is BGRA in memory" {
    // 0xAARRGGBB as a little-endian u32 puts B at the lowest byte, which is
    // what a 32-bit DIB expects.
    const v = Canvas.pack(.{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0xFF });
    try testing.expectEqual(@as(u32, 0xFF123456), v);
    const bytes = std.mem.asBytes(&v);
    try testing.expectEqual(@as(u8, 0x56), bytes[0]); // blue
    try testing.expectEqual(@as(u8, 0x34), bytes[1]); // green
    try testing.expectEqual(@as(u8, 0x12), bytes[2]); // red
    try testing.expectEqual(@as(u8, 0xFF), bytes[3]); // alpha
}
