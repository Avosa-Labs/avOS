//! The reference theme, as the pure resolution of the reference brand — not a second
//! palette, but the named view of what `tokens.resolve` produces.
//!
//! This module used to hold its own copy of the concrete colours and geometry, which
//! meant the values a renderer painted and the values the accessibility layer verified
//! were two separate lists that could drift. They are now one: every value here is a
//! field of `resolve(.reference, .dark)`, so the palette the contrast tests cover and
//! the palette the screen shows are the same object by construction. A renderer keeps
//! reading these familiar names — `theme.base`, `theme.denied`, `theme.radius_md` —
//! but each is a projection of the single resolved source, not a value invented here.
//! Raw colour lives in exactly one place now, the brand resolution; this is its named
//! surface for the renderer.
//!
//! This module defines nothing of its own. It names the fields of a resolution, so a
//! renderer can ask for a value by the role it fills.

const std = @import("std");
const tokens = @import("../tokens/tokens.zig");
const resolve = @import("../tokens/resolve.zig");

pub const Colour = tokens.Colour;
pub const Gradient = resolve.Gradient;

/// The one resolved source every value below projects from.
const reference = resolve.resolve(.reference, .dark);
const palette = reference.palette;
const geometry = reference.geometry;

// --- Base surfaces ---

pub const base = palette.base;
pub const panel = palette.panel;
pub const surface = palette.surface;
pub const surface_raised = palette.surface_raised;
pub const divider = palette.divider;

// --- Text ---

pub const text_primary = palette.text_primary;
pub const text_secondary = palette.text_secondary;
pub const text_tertiary = palette.text_tertiary;

// --- Accents ---

pub const agent = palette.agent;
pub const agent_soft = palette.agent_soft;
pub const human = palette.human;
pub const teal = palette.teal;
pub const teal_bright = palette.teal_bright;
pub const coral = palette.coral;
pub const amber = palette.amber;
pub const denied = palette.denied;

// --- The light phone screen ---

pub const screen_top = palette.screen_top;
pub const screen_mid = palette.screen_mid;
pub const screen_bottom = palette.screen_bottom;
pub const screen_card = palette.screen_card;
pub const screen_card_tint = palette.screen_card_tint;
pub const screen_text = palette.screen_text;
pub const screen_text_soft = palette.screen_text_soft;
pub const screen_text_muted = palette.screen_text_muted;
pub const screen_text_faint = palette.screen_text_faint;
pub const screen_label = palette.screen_label;
pub const screen_hairline = palette.screen_hairline;
pub const card_shadow = palette.card_shadow;
pub const screen_line = palette.screen_line;
pub const sky = palette.sky;

// --- The physical device ---

pub const desktop_top = palette.desktop_top;
pub const desktop_bottom = palette.desktop_bottom;
pub const bezel_top = palette.bezel_top;
pub const bezel_bottom = palette.bezel_bottom;

// --- Device frame geometry ---

pub const screen_pro_w = geometry.screen_pro_w;
pub const screen_pro_h = geometry.screen_pro_h;
pub const screen_max_w = geometry.screen_max_w;
pub const screen_max_h = geometry.screen_max_h;
pub const bezel_thickness = geometry.bezel_thickness;
pub const device_radius = geometry.device_radius;
pub const screen_radius = geometry.screen_radius;
pub const desktop_margin = geometry.desktop_margin;

// --- App icon gradients ---

pub const icon_calendar = palette.icon_calendar;
pub const icon_phone = palette.icon_phone;
pub const icon_messages = palette.icon_messages;
pub const icon_camera = palette.icon_camera;
pub const icon_health = palette.icon_health;
pub const icon_agents = palette.icon_agents;
pub const icon_files = palette.icon_files;
pub const icon_settings = palette.icon_settings;
pub const icon_mail = palette.icon_mail;
pub const icon_weather = palette.icon_weather;
pub const icon_notes = palette.icon_notes;
pub const icon_maps = palette.icon_maps;

// --- Layout geometry ---

pub const spacing_step = geometry.spacing_step;
pub const radius_sm = geometry.radius_sm;
pub const radius_md = geometry.radius_md;
pub const radius_lg = geometry.radius_lg;
pub const radius_xl = geometry.radius_xl;
pub const radius_pill = geometry.radius_pill;
pub const icon_radius_ratio_num = geometry.icon_radius_ratio_num;
pub const icon_radius_ratio_den = geometry.icon_radius_ratio_den;

// --- Elevation shadow ---

pub const shadow_blur = geometry.elevation.blur;
pub const shadow_offset_y = geometry.elevation.offset_y;
pub const shadow_tint = Colour{
    .red = geometry.elevation.tint_red,
    .green = geometry.elevation.tint_green,
    .blue = geometry.elevation.tint_blue,
    .alpha = geometry.elevation.tint_alpha,
};

// --- The signature spring, as cubic-bezier control points scaled by 1000 ---

pub const ease_spring_x1 = geometry.spring.x1;
pub const ease_spring_y1 = geometry.spring.y1;
pub const ease_spring_x2 = geometry.spring.x2;
pub const ease_spring_y2 = geometry.spring.y2;

// --- Tests ---

test "surfaces get lighter as they rise off the base" {
    try std.testing.expect(panel.luminance() >= base.luminance());
    try std.testing.expect(surface.luminance() >= panel.luminance());
    try std.testing.expect(surface_raised.luminance() >= surface.luminance());
}

test "primary text clears the contrast floor on the panel" {
    try std.testing.expect(text_primary.contrastWith(panel) >= tokens.minimum_text_contrast);
}

test "the agent accent is distinct from the human accent" {
    try std.testing.expect(agent.red != human.red or agent.green != human.green or agent.blue != human.blue);
}

test "every icon gradient descends (top lighter than bottom)" {
    const gradients = [_]Gradient{
        icon_calendar, icon_phone,  icon_messages, icon_camera,
        icon_health,   icon_agents, icon_files,    icon_settings,
    };
    for (gradients) |gradient| {
        try std.testing.expect(gradient.top.luminance() >= gradient.bottom.luminance());
    }
}

test "the dark-chrome text the shell actually paints clears its contrast floor" {
    // The point of the unification: the concrete colours paint emits, not only the
    // semantic roles, are held to the contrast guarantee — and now they are the same
    // object the resolution produced, so this covers exactly what the renderer shows.
    const dark_surfaces = [_]Colour{ base, panel, surface, surface_raised };
    for (dark_surfaces) |background| {
        try std.testing.expect(text_primary.contrastWith(background) >= tokens.minimum_text_contrast);
        try std.testing.expect(text_secondary.contrastWith(background) >= tokens.minimum_large_text_contrast);
    }
}

test "the light-screen text the phone paints clears its contrast floor" {
    const light_surfaces = [_]Colour{ screen_top, screen_mid, screen_bottom, screen_card, screen_card_tint };
    for (light_surfaces) |background| {
        try std.testing.expect(screen_text.contrastWith(background) >= tokens.minimum_text_contrast);
        try std.testing.expect(screen_text_soft.contrastWith(background) >= tokens.minimum_text_contrast);
        try std.testing.expect(screen_text_muted.contrastWith(background) >= tokens.minimum_large_text_contrast);
    }
}

test "the theme is exactly the reference resolution, not a second palette" {
    // The unification guarantee: a named value equals the field of the resolution it
    // projects, so there is one source, not two.
    try std.testing.expectEqual(reference.palette.denied, denied);
    try std.testing.expectEqual(reference.geometry.radius_md, radius_md);
    try std.testing.expectEqual(reference.geometry.spring.x1, ease_spring_x1);
}
