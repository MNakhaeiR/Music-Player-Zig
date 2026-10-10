//! Colours for the interface.
//!
//! Two palettes are provided so the player stays readable on both dark and
//! light terminals, plus a monochrome one for terminals without truecolor.

const std = @import("std");
const screen = @import("screen.zig");
const Rgb = screen.Rgb;
const Style = screen.Style;

pub const Kind = enum {
    dark,
    light,
    mono,

    pub fn fromName(name: []const u8) ?Kind {
        if (std.ascii.eqlIgnoreCase(name, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(name, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(name, "mono")) return .mono;
        return null;
    }

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .dark => "dark",
            .light => "light",
            .mono => "mono",
        };
    }
};

pub const Theme = struct {
    kind: Kind,

    /// Panel borders and separators.
    border: Rgb,
    border_focus: Rgb,
    /// Ordinary text.
    text: Rgb,
    /// Secondary text: artist lines, hints, units.
    muted: Rgb,
    /// Headings and the current track.
    accent: Rgb,
    /// Second accent, for the progress bar fill.
    accent_alt: Rgb,
    /// Row highlight for the queue cursor.
    selection_bg: Rgb,
    /// Spectrum gradient, low to high energy.
    spectrum_low: Rgb,
    spectrum_mid: Rgb,
    spectrum_high: Rgb,
    /// Level meters.
    meter_ok: Rgb,
    meter_warn: Rgb,
    meter_peak: Rgb,
    /// Errors and warnings.
    danger: Rgb,
    /// Inactive track text.
    dim: Rgb,

    pub fn get(kind: Kind) Theme {
        return switch (kind) {
            .dark => .{
                .kind = .dark,
                .border = .{ .r = 68, .g = 76, .b = 94 },
                .border_focus = .{ .r = 122, .g = 162, .b = 247 },
                .text = .{ .r = 205, .g = 214, .b = 244 },
                .muted = .{ .r = 127, .g = 136, .b = 162 },
                .accent = .{ .r = 137, .g = 220, .b = 235 },
                .accent_alt = .{ .r = 166, .g = 227, .b = 161 },
                .selection_bg = .{ .r = 49, .g = 50, .b = 68 },
                .spectrum_low = .{ .r = 116, .g = 199, .b = 236 },
                .spectrum_mid = .{ .r = 166, .g = 227, .b = 161 },
                .spectrum_high = .{ .r = 243, .g = 139, .b = 168 },
                .meter_ok = .{ .r = 166, .g = 227, .b = 161 },
                .meter_warn = .{ .r = 249, .g = 226, .b = 175 },
                .meter_peak = .{ .r = 243, .g = 139, .b = 168 },
                .danger = .{ .r = 243, .g = 139, .b = 168 },
                .dim = .{ .r = 88, .g = 96, .b = 120 },
            },
            .light => .{
                .kind = .light,
                .border = .{ .r = 172, .g = 176, .b = 190 },
                .border_focus = .{ .r = 30, .g = 102, .b = 245 },
                .text = .{ .r = 76, .g = 79, .b = 105 },
                .muted = .{ .r = 124, .g = 127, .b = 147 },
                .accent = .{ .r = 4, .g = 140, .b = 175 },
                .accent_alt = .{ .r = 64, .g = 160, .b = 43 },
                .selection_bg = .{ .r = 220, .g = 224, .b = 232 },
                .spectrum_low = .{ .r = 32, .g = 159, .b = 181 },
                .spectrum_mid = .{ .r = 64, .g = 160, .b = 43 },
                .spectrum_high = .{ .r = 210, .g = 15, .b = 57 },
                .meter_ok = .{ .r = 64, .g = 160, .b = 43 },
                .meter_warn = .{ .r = 223, .g = 142, .b = 29 },
                .meter_peak = .{ .r = 210, .g = 15, .b = 57 },
                .danger = .{ .r = 210, .g = 15, .b = 57 },
                .dim = .{ .r = 156, .g = 160, .b = 176 },
            },
            .mono => blk: {
                const white: Rgb = .{ .r = 229, .g = 229, .b = 229 };
                const grey: Rgb = .{ .r = 140, .g = 140, .b = 140 };
                const dark: Rgb = .{ .r = 80, .g = 80, .b = 80 };
                break :blk .{
                    .kind = .mono,
                    .border = grey,
                    .border_focus = white,
                    .text = white,
                    .muted = grey,
                    .accent = white,
                    .accent_alt = white,
                    .selection_bg = dark,
                    .spectrum_low = grey,
                    .spectrum_mid = white,
                    .spectrum_high = white,
                    .meter_ok = grey,
                    .meter_warn = white,
                    .meter_peak = white,
                    .danger = white,
                    .dim = dark,
                };
            },
        };
    }

    // --- convenience styles ---------------------------------------------

    pub fn textStyle(t: Theme) Style {
        return .{ .fg = .{ .rgb = t.text } };
    }
    pub fn mutedStyle(t: Theme) Style {
        return .{ .fg = .{ .rgb = t.muted } };
    }
    pub fn dimStyle(t: Theme) Style {
        return .{ .fg = .{ .rgb = t.dim } };
    }
    pub fn accentStyle(t: Theme) Style {
        return .{ .fg = .{ .rgb = t.accent }, .bold = true };
    }
    pub fn borderStyle(t: Theme, focused: bool) Style {
        return .{ .fg = .{ .rgb = if (focused) t.border_focus else t.border } };
    }
    pub fn dangerStyle(t: Theme) Style {
        return .{ .fg = .{ .rgb = t.danger }, .bold = true };
    }
    pub fn selectedStyle(t: Theme) Style {
        return .{
            .fg = .{ .rgb = t.text },
            .bg = .{ .rgb = t.selection_bg },
            .bold = true,
        };
    }

    /// Colour for a spectrum bar or meter at `level` in 0..1.
    pub fn energyColor(t: Theme, level: f32) Rgb {
        const l = std.math.clamp(level, 0, 1);
        if (l < 0.5) return t.spectrum_low.lerp(t.spectrum_mid, l * 2.0);
        return t.spectrum_mid.lerp(t.spectrum_high, (l - 0.5) * 2.0);
    }

    /// Colour for a level meter segment, going amber then red near full scale.
    pub fn meterColor(t: Theme, level: f32) Rgb {
        const l = std.math.clamp(level, 0, 1);
        if (l < 0.75) return t.meter_ok;
        if (l < 0.92) return t.meter_warn;
        return t.meter_peak;
    }
};

const testing = std.testing;

test "every theme is fully populated" {
    for ([_]Kind{ .dark, .light, .mono }) |k| {
        const t = Theme.get(k);
        try testing.expectEqual(k, t.kind);
        // A zeroed colour would mean a field was forgotten; the palettes
        // deliberately contain no pure black.
        const fields = [_]Rgb{
            t.border, t.border_focus, t.text,          t.muted,
            t.accent, t.accent_alt,   t.spectrum_low,  t.spectrum_mid,
            t.danger, t.dim,          t.spectrum_high, t.meter_ok,
        };
        for (fields) |c| {
            try testing.expect(c.r != 0 or c.g != 0 or c.b != 0);
        }
    }
}

test "theme names round trip" {
    for ([_]Kind{ .dark, .light, .mono }) |k| {
        try testing.expectEqual(k, Kind.fromName(k.label()).?);
    }
    try testing.expect(Kind.fromName("solarized") == null);
}

test "energy gradient runs low to high" {
    const t = Theme.get(.dark);
    const low = t.energyColor(0);
    const high = t.energyColor(1);
    try testing.expectEqual(t.spectrum_low, low);
    try testing.expectEqual(t.spectrum_high, high);
    // Midpoint is the middle colour.
    try testing.expectEqual(t.spectrum_mid, t.energyColor(0.5));
    // Out of range clamps rather than wrapping.
    try testing.expectEqual(low, t.energyColor(-5));
    try testing.expectEqual(high, t.energyColor(5));
}

test "meter colour escalates near full scale" {
    const t = Theme.get(.dark);
    try testing.expectEqual(t.meter_ok, t.meterColor(0.3));
    try testing.expectEqual(t.meter_warn, t.meterColor(0.8));
    try testing.expectEqual(t.meter_peak, t.meterColor(1.0));
}
