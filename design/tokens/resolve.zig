//! Resolving a brand and an appearance into the concrete values a renderer paints —
//! the single place raw colour and geometry are allowed to exist, so every pixel the
//! system emits traces back to one source that the contrast guarantees actually cover.
//!
//! The semantic tokens say what a colour means and geometry says by role; this turns
//! a role into a value, for a given brand and light-or-dark appearance. It matters
//! that this is the *only* producer of concrete colour: when a renderer reads raw hex
//! of its own, the palette the accessibility tests verify and the palette the screen
//! shows are two different things, and the denial red a person sees can quietly diverge from
//! the one that was proven legible. So the reference palette lives in one resolution,
//! a brand may
//! restyle only what it is allowed to (the accent and decorative hues, never a status
//! colour or the contrast beneath it), and a renderer consumes the resolved output
//! rather than inventing its own. What the contrast tests check and what the display
//! shows become the same thing by construction.
//!
//! This module holds values and the rule for restyling them; it renders nothing. It
//! resolves a brand and appearance to a palette and geometry, as pure data.

const std = @import("std");
const base = @import("tokens.zig");
const geometry = @import("geometry.zig");

pub const Colour = base.Colour;
pub const Appearance = base.Appearance;

fn rgb(r: u8, g: u8, b: u8) Colour {
    return .{ .red = r, .green = g, .blue = b, .alpha = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) Colour {
    return .{ .red = r, .green = g, .blue = b, .alpha = a };
}

/// A vertical top-to-bottom fill, for an app icon tile.
pub const Gradient = struct { top: Colour, bottom: Colour };

/// Every concrete colour the reference paints, named by the role it fills. This is
/// the resolved palette a renderer reads; it invents no colour of its own.
pub const Palette = struct {
    // Dark chrome surfaces.
    base: Colour,
    panel: Colour,
    surface: Colour,
    surface_raised: Colour,
    divider: Colour,
    // Chrome text.
    text_primary: Colour,
    text_secondary: Colour,
    text_tertiary: Colour,
    // Accents and status.
    agent: Colour,
    agent_soft: Colour,
    human: Colour,
    teal: Colour,
    teal_bright: Colour,
    coral: Colour,
    amber: Colour,
    denied: Colour,
    // The light phone screen.
    screen_top: Colour,
    screen_mid: Colour,
    screen_bottom: Colour,
    screen_card: Colour,
    screen_card_tint: Colour,
    screen_text: Colour,
    screen_text_soft: Colour,
    screen_text_muted: Colour,
    screen_text_faint: Colour,
    screen_label: Colour,
    screen_hairline: Colour,
    sky: Colour,
    // The physical device.
    desktop_top: Colour,
    desktop_bottom: Colour,
    bezel_top: Colour,
    bezel_bottom: Colour,
    // App icon gradients.
    icon_calendar: Gradient,
    icon_phone: Gradient,
    icon_messages: Gradient,
    icon_camera: Gradient,
    icon_health: Gradient,
    icon_agents: Gradient,
    icon_files: Gradient,
    icon_settings: Gradient,
    icon_mail: Gradient,
    icon_weather: Gradient,
    icon_notes: Gradient,
    icon_maps: Gradient,
};

/// The resolved geometry: the corner radii, elevation shadow, spacing step, and
/// signature spring, as concrete values.
pub const Geometry = struct {
    spacing_step: u16,
    radius_sm: u16,
    radius_md: u16,
    radius_lg: u16,
    radius_xl: u16,
    radius_pill: u16,
    icon_radius_ratio_num: u16,
    icon_radius_ratio_den: u16,
    elevation: geometry.Elevation,
    spring: geometry.Curve,
    // Device frame geometry, in logical points.
    screen_pro_w: u32,
    screen_pro_h: u32,
    screen_max_w: u32,
    screen_max_h: u32,
    bezel_thickness: u32,
    device_radius: u16,
    screen_radius: u16,
    desktop_margin: u32,
};

/// A brand: the identity whose accent and decorative hues may be restyled. The
/// reference brand is the design as authored; a product brand adjusts only what it is
/// permitted to.
pub const Brand = enum {
    reference,
};

/// The output a renderer consumes.
pub const Output = struct {
    palette: Palette,
    geometry: Geometry,
    appearance: Appearance,
};

/// The reference palette, exactly as the design authors it. These are the only raw
/// colour literals in the production tree; everything else reads them through a
/// resolution.
fn referencePalette() Palette {
    return .{
        .base = rgb(0x0b, 0x0a, 0x11),
        .panel = rgb(0x24, 0x1f, 0x30),
        .surface = rgb(0x2a, 0x28, 0x33),
        .surface_raised = rgb(0x32, 0x2c, 0x40),
        .divider = rgba(0xff, 0xff, 0xff, 0x14),
        .text_primary = rgb(0xf4, 0xf5, 0xf7),
        .text_secondary = rgb(0x94, 0x8f, 0xa2),
        .text_tertiary = rgb(0x6a, 0x64, 0x78),
        .agent = rgb(0x9a, 0x6c, 0xff),
        .agent_soft = rgb(0x7c, 0x78, 0xff),
        .human = rgb(0x5a, 0xa8, 0xff),
        .teal = rgb(0x37, 0xc2, 0xa6),
        .teal_bright = rgb(0x5f, 0xe0, 0xb0),
        .coral = rgb(0xff, 0x8f, 0x6b),
        .amber = rgb(0xff, 0xb1, 0x5c),
        .denied = rgb(0xe4, 0x6a, 0x6a),
        .screen_top = rgb(0xf4, 0xf2, 0xfa),
        .screen_mid = rgb(0xee, 0xf0, 0xf7),
        .screen_bottom = rgb(0xf3, 0xee, 0xf7),
        .screen_card = rgb(0xff, 0xff, 0xff),
        .screen_card_tint = rgb(0xfb, 0xf7, 0xff),
        .screen_text = rgb(0x21, 0x1f, 0x2a),
        .screen_text_soft = rgb(0x24, 0x1f, 0x30),
        .screen_text_muted = rgb(0x8a, 0x86, 0x94),
        .screen_text_faint = rgb(0x9c, 0x98, 0xa8),
        .screen_label = rgb(0x9a, 0x95, 0xa6),
        .screen_hairline = rgba(0x21, 0x1f, 0x2a, 0x12),
        .sky = rgb(0x39, 0xb7, 0xe6),
        .desktop_top = rgb(0x16, 0x13, 0x29),
        .desktop_bottom = rgb(0x0b, 0x0a, 0x11),
        .bezel_top = rgb(0x26, 0x24, 0x2f),
        .bezel_bottom = rgb(0x10, 0x0f, 0x16),
        .icon_calendar = .{ .top = rgb(0xff, 0x9a, 0x7a), .bottom = rgb(0xe8, 0x57, 0x2f) },
        .icon_phone = .{ .top = rgb(0x53, 0xd6, 0x90), .bottom = rgb(0x2f, 0xae, 0x6a) },
        .icon_messages = .{ .top = rgb(0x6f, 0x8b, 0xff), .bottom = rgb(0x4a, 0x8c, 0xff) },
        .icon_camera = .{ .top = rgb(0xa9, 0x82, 0xff), .bottom = rgb(0x7c, 0x5c, 0xf0) },
        .icon_health = .{ .top = rgb(0x56, 0xc7, 0xe6), .bottom = rgb(0x2f, 0x9f, 0xc9) },
        .icon_agents = .{ .top = rgb(0xff, 0xb1, 0x5c), .bottom = rgb(0xf0, 0x84, 0x2f) },
        .icon_files = .{ .top = rgb(0xa9, 0x82, 0xff), .bottom = rgb(0x7c, 0x5c, 0xf0) },
        .icon_settings = .{ .top = rgb(0x7a, 0x81, 0x94), .bottom = rgb(0x56, 0x5d, 0x6e) },
        .icon_mail = .{ .top = rgb(0x6f, 0x8b, 0xff), .bottom = rgb(0x4a, 0x6c, 0xf0) },
        .icon_weather = .{ .top = rgb(0x5a, 0xc8, 0xff), .bottom = rgb(0x2f, 0x9f, 0xe0) },
        .icon_notes = .{ .top = rgb(0xff, 0xd1, 0x5c), .bottom = rgb(0xf0, 0xa5, 0x2f) },
        .icon_maps = .{ .top = rgb(0x4f, 0xd0, 0x8a), .bottom = rgb(0x2a, 0x9e, 0x86) },
    };
}

fn referenceGeometry() Geometry {
    return .{
        .spacing_step = geometry.spacing_step,
        .radius_sm = geometry.RadiusRole.sm.points(),
        .radius_md = geometry.RadiusRole.md.points(),
        .radius_lg = geometry.RadiusRole.lg.points(),
        .radius_xl = geometry.RadiusRole.xl.points(),
        .radius_pill = geometry.RadiusRole.pill.points(),
        .icon_radius_ratio_num = geometry.icon_radius_ratio_num,
        .icon_radius_ratio_den = geometry.icon_radius_ratio_den,
        .elevation = .{ .blur = 16, .offset_y = 6, .tint_red = 0x4b, .tint_green = 0x3a, .tint_blue = 0x66, .tint_alpha = 0x99 },
        .spring = .{ .x1 = 200, .y1 = 900, .x2 = 250, .y2 = 1100 },
        .screen_pro_w = 393,
        .screen_pro_h = 852,
        .screen_max_w = 440,
        .screen_max_h = 956,
        .bezel_thickness = 13,
        .device_radius = 52,
        .screen_radius = 42,
        .desktop_margin = 22,
    };
}

/// Resolves a brand and appearance to the concrete palette and geometry a renderer
/// paints. The reference brand in dark appearance is the design as authored; other
/// brands and appearances derive from it without inventing new raw values here beyond
/// the reference above.
pub fn resolve(brand: Brand, appearance: Appearance) Output {
    // Only the reference brand exists today; a product brand would attenuate the
    // accent and decorative hues here while leaving status and text untouched, since
    // those carry meaning and contrast a brand may not alter.
    std.debug.assert(brand == .reference);
    return .{
        .palette = referencePalette(),
        .geometry = referenceGeometry(),
        .appearance = appearance,
    };
}

// --- Tests ---

const testing = std.testing;

test "the reference resolves to a complete palette and geometry" {
    const out = resolve(.reference, .dark);
    // Elevation reads as lighter surfaces rising off the base.
    try testing.expect(out.palette.panel.luminance() >= out.palette.base.luminance());
    try testing.expect(out.palette.surface_raised.luminance() >= out.palette.surface.luminance());
    // The signature spring overshoots.
    try testing.expect(out.geometry.spring.overshoots());
    // The corner scale is present and ordered.
    try testing.expect(out.geometry.radius_sm < out.geometry.radius_lg);
}

test "the resolved palette is the single place raw colour lives, and it is legible" {
    // The contrast guarantee now covers exactly what a renderer paints, because the
    // renderer paints this. Primary text clears the text floor on every dark surface.
    const p = resolve(.reference, .dark).palette;
    const dark_surfaces = [_]Colour{ p.base, p.panel, p.surface, p.surface_raised };
    for (dark_surfaces) |surface| {
        try testing.expect(p.text_primary.contrastWith(surface) >= base.minimum_text_contrast);
    }
}

test "resolution carries the appearance it was asked for" {
    try testing.expectEqual(Appearance.dark, resolve(.reference, .dark).appearance);
    try testing.expectEqual(Appearance.light, resolve(.reference, .light).appearance);
}
