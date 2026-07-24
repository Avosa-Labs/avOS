//! The concrete dark reference theme, the exact colours and geometry the shell renders with.
//!
//! Where the semantic tokens say what a colour *means* (a surface, a denial, the accent), this module
//! gives the *values* the reference build actually paints: the near-black base a screen rests on, the
//! raised panel it stacks surfaces on, the agent-forward accent that marks anything an agent did, and
//! the per-role status hues. It also fixes the geometry — the corner radii, the soft elevation shadow,
//! the spacing step, and the spring easing — so every surface shares one coherent look rather than each
//! inventing its own. A brand may restyle the accent and decorative hues; it may not touch the
//! status colours or the contrast the semantic layer guarantees. Keeping the concrete values in one
//! place is what lets a rendered frame be checked against the design pixel for pixel.
//!
//! Colours here reuse the design token `Colour` type, so a theme value and a semantic role are the same
//! kind of thing and can be compared directly.

const tokens = @import("../tokens/tokens.zig");

pub const Colour = tokens.Colour;

fn rgb(r: u8, g: u8, b: u8) Colour {
    return .{ .red = r, .green = g, .blue = b, .alpha = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) Colour {
    return .{ .red = r, .green = g, .blue = b, .alpha = a };
}

// --- Base surfaces ---

/// The deepest background — a screen at rest, and what the boot and rest scenes fade to.
pub const base = rgb(0x0b, 0x0a, 0x11);
/// A panel raised off the base: the shell's primary surface.
pub const panel = rgb(0x24, 0x1f, 0x30);
/// A surface raised above a panel: cards, list rows.
pub const surface = rgb(0x2a, 0x28, 0x33);
/// A surface raised further: the active or focused card.
pub const surface_raised = rgb(0x32, 0x2c, 0x40);
/// A hairline divider between surfaces.
pub const divider = rgba(0xff, 0xff, 0xff, 0x14);

// --- Text ---

pub const text_primary = rgb(0xf4, 0xf5, 0xf7);
pub const text_secondary = rgb(0x94, 0x8f, 0xa2);
pub const text_tertiary = rgb(0x6a, 0x64, 0x78);

// --- Accents ---

/// The agent accent: anything an agent did, is doing, or may do is marked with this. The signature
/// colour of the platform.
pub const agent = rgb(0x9a, 0x6c, 0xff);
/// A lighter agent tint for fills and glows.
pub const agent_soft = rgb(0x7c, 0x78, 0xff);
/// The human/interaction accent — a person's own actions.
pub const human = rgb(0x5a, 0xa8, 0xff);
/// The calm/confirmation hue.
pub const teal = rgb(0x37, 0xc2, 0xa6);
pub const teal_bright = rgb(0x5f, 0xe0, 0xb0);
/// The warm/attention hue.
pub const coral = rgb(0xff, 0x8f, 0x6b);
/// The caution/awaiting hue.
pub const amber = rgb(0xff, 0xb1, 0x5c);
/// The denial hue.
pub const denied = rgb(0xe4, 0x6a, 0x6a);

// --- A per-app icon gradient: a vertical top→bottom fill. ---

pub const Gradient = struct { top: Colour, bottom: Colour };

pub const icon_calendar: Gradient = .{ .top = rgb(0xff, 0x9a, 0x7a), .bottom = rgb(0xe8, 0x57, 0x2f) };
pub const icon_phone: Gradient = .{ .top = rgb(0x53, 0xd6, 0x90), .bottom = rgb(0x2f, 0xae, 0x6a) };
pub const icon_messages: Gradient = .{ .top = rgb(0x6f, 0x8b, 0xff), .bottom = rgb(0x4a, 0x8c, 0xff) };
pub const icon_camera: Gradient = .{ .top = rgb(0xa9, 0x82, 0xff), .bottom = rgb(0x7c, 0x5c, 0xf0) };
pub const icon_health: Gradient = .{ .top = rgb(0x56, 0xc7, 0xe6), .bottom = rgb(0x2f, 0x9f, 0xc9) };
pub const icon_agents: Gradient = .{ .top = rgb(0xff, 0xb1, 0x5c), .bottom = rgb(0xf0, 0x84, 0x2f) };
pub const icon_files: Gradient = .{ .top = rgb(0xa9, 0x82, 0xff), .bottom = rgb(0x7c, 0x5c, 0xf0) };
pub const icon_settings: Gradient = .{ .top = rgb(0x7a, 0x81, 0x94), .bottom = rgb(0x56, 0x5d, 0x6e) };

// --- Geometry ---

/// The base spacing step in logical points; the layout grid is multiples of this.
pub const spacing_step: u16 = 8;

/// The corner radii scale, in logical points.
pub const radius_sm: u16 = 8;
pub const radius_md: u16 = 12;
pub const radius_lg: u16 = 16;
pub const radius_xl: u16 = 20;
pub const radius_pill: u16 = 22;

/// The fraction of an icon tile's side used as its superellipse corner radius (the squircle look).
pub const icon_radius_ratio_num: u16 = 23;
pub const icon_radius_ratio_den: u16 = 100;

/// The soft elevation shadow, expressed as its blur radius and offset in points and its tint.
pub const shadow_blur: u16 = 16;
pub const shadow_offset_y: i16 = 6;
pub const shadow_tint = rgba(0x4b, 0x3a, 0x66, 0x99);

/// The signature spring easing, as cubic-bezier control points scaled by 1000. The shell's motion
/// overshoots slightly (y2 > 1000) so surfaces settle rather than snap.
pub const ease_spring_x1: i16 = 200;
pub const ease_spring_y1: i16 = 900;
pub const ease_spring_x2: i16 = 250;
pub const ease_spring_y2: i16 = 1100;

const std = @import("std");

test "surfaces get lighter as they rise off the base" {
    // Elevation reads as a lighter surface on a dark theme; each step is no darker than the one below.
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
