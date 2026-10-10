//! Colours for the desktop interface.
//!
//! A separate palette from the terminal's: a GUI has real pixels and alpha, so
//! it can use layered surfaces and soft shadows, where the TUI only has
//! foreground and background per cell.

const std = @import("std");
const Color = @import("canvas.zig").Color;

/// Reached through the `zmp` module rather than by relative path: the
/// terminal interface's files belong to that module, and a Zig source file
/// can only be part of one module.
pub const Kind = @import("zmp").ui.theme.Kind;

pub const Theme = struct {
    kind: Kind,

    /// Window background, behind everything.
    background: Color,
    /// Raised panel surfaces.
    surface: Color,
    /// A surface one level higher, for rows and controls.
    surface_raised: Color,
    /// Hover state for an interactive surface.
    surface_hover: Color,
    /// The selected row.
    surface_selected: Color,
    /// Hairline separators and control outlines.
    outline: Color,

    text: Color,
    text_muted: Color,
    text_faint: Color,
    /// Text on top of an accent fill.
    text_on_accent: Color,

    accent: Color,
    accent_hover: Color,
    accent_pressed: Color,

    /// Spectrum gradient, bottom to top.
    spectrum_low: Color,
    spectrum_mid: Color,
    spectrum_high: Color,

    meter_ok: Color,
    meter_warn: Color,
    meter_peak: Color,

    danger: Color,
    shadow: Color,

    pub fn get(kind: Kind) Theme {
        return switch (kind) {
            .dark => .{
                .kind = .dark,
                .background = Color.hex("#12141c"),
                .surface = Color.hex("#1a1d28"),
                .surface_raised = Color.hex("#222634"),
                .surface_hover = Color.hex("#2b3042"),
                .surface_selected = Color.hex("#313a55"),
                .outline = Color.hex("#2f3747"),
                .text = Color.hex("#e4e7f2"),
                .text_muted = Color.hex("#9aa2bd"),
                .text_faint = Color.hex("#646c88"),
                .text_on_accent = Color.hex("#0d1017"),
                .accent = Color.hex("#6ea8fe"),
                .accent_hover = Color.hex("#8cbcff"),
                .accent_pressed = Color.hex("#5590e8"),
                .spectrum_low = Color.hex("#4d9bf0"),
                .spectrum_mid = Color.hex("#63d7a4"),
                .spectrum_high = Color.hex("#f2748c"),
                .meter_ok = Color.hex("#63d7a4"),
                .meter_warn = Color.hex("#f0cf72"),
                .meter_peak = Color.hex("#f2748c"),
                .danger = Color.hex("#f2748c"),
                .shadow = Color.rgba(0, 0, 0, 160),
            },
            .light => .{
                .kind = .light,
                .background = Color.hex("#eef0f6"),
                .surface = Color.hex("#ffffff"),
                .surface_raised = Color.hex("#f5f6fa"),
                .surface_hover = Color.hex("#e6e9f2"),
                .surface_selected = Color.hex("#d7e2fb"),
                .outline = Color.hex("#d2d6e2"),
                .text = Color.hex("#1f2330"),
                .text_muted = Color.hex("#5c6480"),
                .text_faint = Color.hex("#8d94ab"),
                .text_on_accent = Color.hex("#ffffff"),
                .accent = Color.hex("#2f6fe0"),
                .accent_hover = Color.hex("#4a85ef"),
                .accent_pressed = Color.hex("#2259be"),
                .spectrum_low = Color.hex("#2f8ee0"),
                .spectrum_mid = Color.hex("#2aa96f"),
                .spectrum_high = Color.hex("#d8445f"),
                .meter_ok = Color.hex("#2aa96f"),
                .meter_warn = Color.hex("#d79a1f"),
                .meter_peak = Color.hex("#d8445f"),
                .danger = Color.hex("#d8445f"),
                .shadow = Color.rgba(30, 40, 70, 60),
            },
            .mono => .{
                .kind = .mono,
                .background = Color.hex("#101010"),
                .surface = Color.hex("#1a1a1a"),
                .surface_raised = Color.hex("#242424"),
                .surface_hover = Color.hex("#303030"),
                .surface_selected = Color.hex("#3c3c3c"),
                .outline = Color.hex("#454545"),
                .text = Color.hex("#e8e8e8"),
                .text_muted = Color.hex("#a0a0a0"),
                .text_faint = Color.hex("#6a6a6a"),
                .text_on_accent = Color.hex("#101010"),
                .accent = Color.hex("#d8d8d8"),
                .accent_hover = Color.hex("#f0f0f0"),
                .accent_pressed = Color.hex("#b8b8b8"),
                .spectrum_low = Color.hex("#808080"),
                .spectrum_mid = Color.hex("#b4b4b4"),
                .spectrum_high = Color.hex("#f0f0f0"),
                .meter_ok = Color.hex("#a0a0a0"),
                .meter_warn = Color.hex("#d0d0d0"),
                .meter_peak = Color.hex("#f4f4f4"),
                .danger = Color.hex("#f4f4f4"),
                .shadow = Color.rgba(0, 0, 0, 180),
            },
        };
    }

    /// Spectrum colour for a bar at `height` in 0..1.
    pub fn energyColor(t: Theme, height: f32) Color {
        const h = std.math.clamp(height, 0, 1);
        if (h < 0.55) return t.spectrum_low.lerp(t.spectrum_mid, h / 0.55);
        return t.spectrum_mid.lerp(t.spectrum_high, (h - 0.55) / 0.45);
    }

    pub fn meterColor(t: Theme, level: f32) Color {
        const l = std.math.clamp(level, 0, 1);
        if (l < 0.75) return t.meter_ok;
        if (l < 0.92) return t.meter_warn;
        return t.meter_peak;
    }

    pub fn next(t: Theme) Theme {
        return get(switch (t.kind) {
            .dark => .light,
            .light => .mono,
            .mono => .dark,
        });
    }
};

const testing = std.testing;

test "every palette is populated and distinct" {
    for ([_]Kind{ .dark, .light, .mono }) |k| {
        const t = Theme.get(k);
        try testing.expectEqual(k, t.kind);
        // Text must contrast with the background, or the interface is unusable.
        const delta = @abs(t.text.luminance() - t.background.luminance());
        try testing.expect(delta > 0.4);
        // Opaque surfaces.
        try testing.expectEqual(@as(u8, 255), t.surface.a);
        try testing.expectEqual(@as(u8, 255), t.text.a);
    }
}

test "dark and light are actually inverted" {
    const dark = Theme.get(.dark);
    const light = Theme.get(.light);
    try testing.expect(dark.background.luminance() < 0.2);
    try testing.expect(light.background.luminance() > 0.8);
}

test "energy gradient spans low to high" {
    const t = Theme.get(.dark);
    try testing.expectEqual(t.spectrum_low, t.energyColor(0));
    try testing.expectEqual(t.spectrum_high, t.energyColor(1));
    try testing.expectEqual(t.spectrum_mid, t.energyColor(0.55));
}

test "theme cycling returns to the start" {
    var t = Theme.get(.dark);
    t = t.next();
    try testing.expectEqual(Kind.light, t.kind);
    t = t.next();
    try testing.expectEqual(Kind.mono, t.kind);
    t = t.next();
    try testing.expectEqual(Kind.dark, t.kind);
}
