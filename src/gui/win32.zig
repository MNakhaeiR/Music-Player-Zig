//! Win32 and GDI bindings for the desktop interface.
//!
//! Declared by hand, in the same style as the WASAPI and console bindings:
//! Zig has no Win32 import, and pulling in a generated binding set for the
//! three dozen calls a window needs would be more weight than it is worth.
//!
//! The drawing model is a DIB section used as a back buffer. We render into
//! its pixel array directly — which gives full control over gradients,
//! alpha blending and anti-aliasing — and then let GDI draw text onto the
//! same surface so labels get real system fonts with proper hinting. One
//! `BitBlt` puts the finished frame on screen.

const std = @import("std");

pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HBITMAP = *opaque {};
pub const HBRUSH = *opaque {};
pub const HFONT = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HMENU = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = HINSTANCE;
pub const HRGN = *opaque {};
pub const HDROP = *opaque {};
pub const HGDIOBJ = *anyopaque;

pub const BOOL = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const COLORREF = u32;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

/// GDI takes colours as 0x00BBGGRR.
pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub const POINT = extern struct { x: i32, y: i32 };
pub const SIZE = extern struct { cx: i32, cy: i32 };

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(r: RECT) i32 {
        return r.right - r.left;
    }
    pub fn height(r: RECT) i32 {
        return r.bottom - r.top;
    }
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: u32,
    biSizeImage: u32,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: u32,
    biClrImportant: u32,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32,
};

pub const BITMAPFILEHEADER = extern struct {
    bfType: u16 align(1),
    bfSize: u32 align(1),
    bfReserved1: u16 align(1),
    bfReserved2: u16 align(1),
    bfOffBits: u32 align(1),
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: ?HWND,
    dwHoverTime: u32,
};

pub const LOGFONTW = extern struct {
    lfHeight: i32,
    lfWidth: i32,
    lfEscapement: i32,
    lfOrientation: i32,
    lfWeight: i32,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]u16,
};

// --- window styles ---------------------------------------------------------

pub const WS_OVERLAPPED: u32 = 0x00000000;
pub const WS_CAPTION: u32 = 0x00C00000;
pub const WS_SYSMENU: u32 = 0x00080000;
pub const WS_THICKFRAME: u32 = 0x00040000;
pub const WS_MINIMIZEBOX: u32 = 0x00020000;
pub const WS_MAXIMIZEBOX: u32 = 0x00010000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const WS_OVERLAPPEDWINDOW: u32 = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
    WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_EX_ACCEPTFILES: u32 = 0x00000010;
pub const WS_EX_APPWINDOW: u32 = 0x00040000;

pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_OWNDC: u32 = 0x0020;
pub const CS_DBLCLKS: u32 = 0x0008;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_SHOW: i32 = 5;
pub const SW_SHOWNORMAL: i32 = 1;

// --- messages --------------------------------------------------------------

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_SETCURSOR: u32 = 0x0020;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_LBUTTONDBLCLK: u32 = 0x0203;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_MOUSELEAVE: u32 = 0x02A3;
pub const WM_DROPFILES: u32 = 0x0233;
pub const WM_DPICHANGED: u32 = 0x02E0;

pub const TME_LEAVE: u32 = 0x00000002;

// --- virtual keys ----------------------------------------------------------

pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_RETURN: u32 = 0x0D;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_PRIOR: u32 = 0x21;
pub const VK_NEXT: u32 = 0x22;
pub const VK_END: u32 = 0x23;
pub const VK_HOME: u32 = 0x24;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_DELETE: u32 = 0x2E;
pub const VK_OEM_PLUS: u32 = 0xBB;
pub const VK_OEM_MINUS: u32 = 0xBD;
pub const VK_F1: u32 = 0x70;

// --- GDI -------------------------------------------------------------------

pub const BI_RGB: u32 = 0;
pub const DIB_RGB_COLORS: u32 = 0;
pub const SRCCOPY: u32 = 0x00CC0020;

pub const TRANSPARENT: i32 = 1;
pub const OPAQUE: i32 = 2;

pub const DT_LEFT: u32 = 0x00000000;
pub const DT_CENTER: u32 = 0x00000001;
pub const DT_RIGHT: u32 = 0x00000002;
pub const DT_TOP: u32 = 0x00000000;
pub const DT_VCENTER: u32 = 0x00000004;
pub const DT_SINGLELINE: u32 = 0x00000020;
pub const DT_NOPREFIX: u32 = 0x00000800;
pub const DT_END_ELLIPSIS: u32 = 0x00008000;
pub const DT_CALCRECT: u32 = 0x00000400;

pub const FW_NORMAL: i32 = 400;
pub const FW_MEDIUM: i32 = 500;
pub const FW_SEMIBOLD: i32 = 600;
pub const FW_BOLD: i32 = 700;

pub const ANSI_CHARSET: u8 = 0;
pub const DEFAULT_CHARSET: u8 = 1;
pub const OUT_TT_PRECIS: u8 = 4;
pub const CLIP_DEFAULT_PRECIS: u8 = 0;
pub const CLEARTYPE_QUALITY: u8 = 5;
pub const ANTIALIASED_QUALITY: u8 = 4;
pub const DEFAULT_PITCH: u8 = 0;
pub const FF_DONTCARE: u8 = 0;

pub const IDC_ARROW: usize = 32512;
pub const IDC_HAND: usize = 32649;
pub const IDC_SIZEWE: usize = 32644;

pub const IDI_APPLICATION: usize = 32512;

// --- imports ---------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(.winapi) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
pub extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;

pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: u32,
    ppvBits: *?[*]u8,
    hSection: ?HANDLE,
    offset: u32,
) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(HDC, i32, i32, i32, i32, HDC, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: [*:0]const u16,
) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkMode(HDC, i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetBkColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn GetDeviceCaps(HDC, i32) callconv(.winapi) i32;

pub extern "user32" fn DrawTextW(HDC, [*]const u16, i32, *RECT, u32) callconv(.winapi) i32;
pub extern "gdi32" fn GetTextExtentPoint32W(HDC, [*]const u16, i32, *SIZE) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub extern "shell32" fn DragQueryFileW(HDROP, u32, ?[*]u16, u32) callconv(.winapi) u32;
pub extern "shell32" fn DragFinish(HDROP) callconv(.winapi) void;
pub extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(.winapi) void;

pub const GWLP_USERDATA: i32 = -21;
pub const LOGPIXELSY: i32 = 90;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;
/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
pub const dpi_per_monitor_v2: isize = -4;

/// Convert a UTF-8 string to a null-terminated UTF-16 buffer, truncating at a
/// character boundary if it does not fit.
///
/// Deliberately not `std.unicode.utf8ToUtf16Le`: that function *panics* when
/// the destination is too small rather than returning an error, so a long
/// track title or file path would take the whole interface down. Truncating is
/// also the better behaviour here — a clipped title beats no title.
pub fn toWide(buf: []u16, text: []const u8) ?[:0]const u16 {
    if (buf.len < 2) return null;
    const capacity = buf.len - 1;
    var out: usize = 0;

    if (std.unicode.Utf8View.init(text)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // Anything outside the basic plane needs a surrogate pair.
            const need: usize = if (cp >= 0x10000) 2 else 1;
            if (out + need > capacity) break;
            if (need == 2) {
                const v = cp - 0x10000;
                buf[out] = @intCast(0xD800 + (v >> 10));
                buf[out + 1] = @intCast(0xDC00 + (v & 0x3FF));
                out += 2;
            } else {
                buf[out] = @intCast(cp);
                out += 1;
            }
        }
    } else |_| {
        // Not valid UTF-8 (a path with an odd byte sequence, say). Copy what
        // is unambiguous rather than refusing to display anything.
        for (text) |b| {
            if (out >= capacity) break;
            buf[out] = if (b < 0x80) b else 0xFFFD;
            out += 1;
        }
    }

    buf[out] = 0;
    return buf[0..out :0];
}

/// Mouse coordinates packed into an LPARAM. The values are signed 16-bit, so
/// dragging above or left of the window gives negatives.
pub fn mouseX(lparam: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
}

pub fn mouseY(lparam: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
}

/// Signed wheel delta from a WM_MOUSEWHEEL wParam, in notches.
pub fn wheelDelta(wparam: WPARAM) i32 {
    const hi: u16 = @truncate(wparam >> 16);
    const signed: i16 = @bitCast(hi);
    return @divTrunc(@as(i32, signed), 120);
}

pub fn isKeyDown(vk: u32) bool {
    return (GetKeyState(@intCast(vk)) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
}

const testing = std.testing;

test "struct layouts match the Win32 ABI" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(RECT));
    try testing.expectEqual(@as(usize, 8), @sizeOf(POINT));
    try testing.expectEqual(@as(usize, 40), @sizeOf(BITMAPINFOHEADER));
    try testing.expectEqual(@as(usize, 44), @sizeOf(BITMAPINFO));
    // Byte-packed, so the pixel data offset lands at 54 for a 40-byte header.
    try testing.expectEqual(@as(usize, 14), @sizeOf(BITMAPFILEHEADER));
    try testing.expectEqual(@as(usize, 40), @sizeOf(MINMAXINFO));
    try testing.expectEqual(@as(usize, 92), @sizeOf(LOGFONTW));
    // WNDCLASSEXW: 4 + 4 + 8 + 4 + 4 + 8*5 + 8 + 8 with padding.
    try testing.expectEqual(@as(usize, 80), @sizeOf(WNDCLASSEXW));
}

test "colour packing is BGR" {
    // GDI stores colours as 0x00BBGGRR.
    try testing.expectEqual(@as(COLORREF, 0x0000FF), rgb(255, 0, 0));
    try testing.expectEqual(@as(COLORREF, 0x00FF00), rgb(0, 255, 0));
    try testing.expectEqual(@as(COLORREF, 0xFF0000), rgb(0, 0, 255));
    try testing.expectEqual(@as(COLORREF, 0xFFFFFF), rgb(255, 255, 255));
}

test "rect helpers" {
    const r: RECT = .{ .left = 10, .top = 20, .right = 110, .bottom = 70 };
    try testing.expectEqual(@as(i32, 100), r.width());
    try testing.expectEqual(@as(i32, 50), r.height());
}

test "mouse coordinates unpack as signed" {
    // x = 100, y = 200
    const packed_pos: LPARAM = @bitCast(@as(usize, (200 << 16) | 100));
    try testing.expectEqual(@as(i32, 100), mouseX(packed_pos));
    try testing.expectEqual(@as(i32, 200), mouseY(packed_pos));

    // Negative coordinates arrive as two's complement 16-bit values, which is
    // what happens when a drag leaves the window to the left or above.
    const neg: LPARAM = @bitCast(@as(usize, (0xFFF6 << 16) | 0xFFFB));
    try testing.expectEqual(@as(i32, -5), mouseX(neg));
    try testing.expectEqual(@as(i32, -10), mouseY(neg));
}

test "wheel delta is signed notches" {
    try testing.expectEqual(@as(i32, 1), wheelDelta(120 << 16));
    try testing.expectEqual(@as(i32, 3), wheelDelta(360 << 16));
    const down: WPARAM = @as(WPARAM, @as(u16, @bitCast(@as(i16, -120)))) << 16;
    try testing.expectEqual(@as(i32, -1), wheelDelta(down));
}

test "UTF-8 to UTF-16 conversion" {
    var buf: [64]u16 = undefined;
    const w = toWide(&buf, "hello").?;
    try testing.expectEqual(@as(usize, 5), w.len);
    try testing.expectEqual(@as(u16, 'h'), w[0]);
    try testing.expectEqual(@as(u16, 0), buf[5]);

    // Non-ASCII survives.
    const accented = toWide(&buf, "caf\u{00E9}").?;
    try testing.expectEqual(@as(usize, 4), accented.len);
    try testing.expectEqual(@as(u16, 0xE9), accented[3]);

    // Text that does not fit is truncated at a character boundary rather
    // than overrunning. `std.unicode.utf8ToUtf16Le` panics in this case,
    // which is why this function does the conversion itself.
    var tiny: [4]u16 = undefined;
    const truncated = toWide(&tiny, "much too long").?;
    try testing.expectEqual(@as(usize, 3), truncated.len);
    try testing.expectEqual(@as(u16, 'm'), truncated[0]);
    try testing.expectEqual(@as(u16, 0), tiny[3]);

    // A surrogate pair is never split across the truncation point.
    var pair_buf: [2]u16 = undefined;
    const clef = toWide(&pair_buf, "\u{1D11E}").?; // needs two UTF-16 units
    try testing.expectEqual(@as(usize, 0), clef.len);

    var pair_ok: [3]u16 = undefined;
    const full = toWide(&pair_ok, "\u{1D11E}").?;
    try testing.expectEqual(@as(usize, 2), full.len);
    try testing.expectEqual(@as(u16, 0xD834), full[0]);
    try testing.expectEqual(@as(u16, 0xDD1E), full[1]);

    // Invalid UTF-8 degrades to replacement characters instead of failing.
    const lossy = toWide(&buf, &[_]u8{ 'a', 0xFF, 'b' }).?;
    try testing.expectEqual(@as(usize, 3), lossy.len);
    try testing.expectEqual(@as(u16, 0xFFFD), lossy[1]);

    // A buffer with no room for even a terminator is refused.
    var empty: [1]u16 = undefined;
    try testing.expect(toWide(&empty, "x") == null);
}
