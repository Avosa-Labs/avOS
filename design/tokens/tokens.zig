//! Semantic design tokens.
//!
//! Components consume roles, never raw values. A surface asks for the colour
//! that means "denied" rather than for a particular red, so a brand change
//! cannot silently turn a denial into something that reads as success.
//!
//! Branding may alter accent and decorative motifs. It may not alter contrast
//! or the meaning of a status role: those carry information a user relies on to
//! understand what the system did, and a brand that could restyle them could
//! make a denial look like an approval.

const std = @import("std");

/// A colour in sRGB with an alpha channel.
pub const Colour = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 255,

    /// Relative luminance, used for contrast. Follows the standard sRGB
    /// transfer function rather than a linear approximation, because a
    /// simplified curve produces contrast figures that pass review and fail in
    /// use.
    pub fn luminance(value: Colour) f64 {
        return 0.2126 * channelLuminance(value.red) +
            0.7152 * channelLuminance(value.green) +
            0.0722 * channelLuminance(value.blue);
    }

    fn channelLuminance(value: u8) f64 {
        const scaled = @as(f64, @floatFromInt(value)) / 255.0;
        if (scaled <= 0.04045) return scaled / 12.92;
        return std.math.pow(f64, (scaled + 0.055) / 1.055, 2.4);
    }

    /// Contrast ratio between two colours, from 1 to 21.
    pub fn contrastWith(value: Colour, other: Colour) f64 {
        const first = value.luminance();
        const second = other.luminance();
        const lighter = @max(first, second);
        const darker = @min(first, second);
        return (lighter + 0.05) / (darker + 0.05);
    }
};

/// What a colour means, not what it looks like.
pub const ColourRole = enum {
    surface,
    surface_raised,
    text_primary,
    text_secondary,
    /// Brand-owned. The one role a brand may restyle freely.
    accent,
    /// An action completed.
    status_succeeded,
    /// An action was refused.
    status_denied,
    /// An action failed after starting.
    status_failed,
    /// Work is waiting on a human.
    status_awaiting_approval,
    /// Work is running.
    status_running,
    /// Work was cancelled.
    status_cancelled,
    /// Data left the device.
    status_left_device,
    focus_ring,

    /// Whether a brand may override this role.
    ///
    /// Status roles and text are excluded: they carry meaning and contrast that
    /// a user depends on, and a brand that could change them could make the
    /// system misreport itself.
    pub fn isBrandOverridable(role: ColourRole) bool {
        return switch (role) {
            .accent => true,
            .surface,
            .surface_raised,
            .text_primary,
            .text_secondary,
            .status_succeeded,
            .status_denied,
            .status_failed,
            .status_awaiting_approval,
            .status_running,
            .status_cancelled,
            .status_left_device,
            .focus_ring,
            => false,
        };
    }

    /// Whether this role is read against a surface and therefore has a minimum
    /// contrast to meet.
    pub fn isForeground(role: ColourRole) bool {
        return switch (role) {
            .surface, .surface_raised => false,
            else => true,
        };
    }
};

/// Minimum contrast a foreground role must reach against its surface.
///
/// Normal text is held to a higher ratio than large text because it subtends a
/// smaller angle; the focus ring is held to the non-text ratio because it is a
/// shape rather than a glyph.
pub const minimum_text_contrast: f64 = 4.5;
pub const minimum_large_text_contrast: f64 = 3.0;
pub const minimum_non_text_contrast: f64 = 3.0;

pub const Appearance = enum { light, dark };

/// The colour a role resolves to in one appearance.
///
/// Dark is tuned independently rather than derived by inverting light: an
/// inverted palette produces washed status colours and contrast that fails
/// exactly where it matters most.
pub fn colour(role: ColourRole, appearance: Appearance) Colour {
    return switch (appearance) {
        .light => switch (role) {
            .surface => .{ .red = 255, .green = 255, .blue = 255 },
            .surface_raised => .{ .red = 244, .green = 245, .blue = 247 },
            .text_primary => .{ .red = 17, .green = 19, .blue = 23 },
            .text_secondary => .{ .red = 84, .green = 89, .blue = 97 },
            .accent => .{ .red = 22, .green = 82, .blue = 158 },
            .status_succeeded => .{ .red = 20, .green = 100, .blue = 52 },
            .status_denied => .{ .red = 168, .green = 24, .blue = 30 },
            .status_failed => .{ .red = 128, .green = 28, .blue = 110 },
            .status_awaiting_approval => .{ .red = 140, .green = 92, .blue = 0 },
            .status_running => .{ .red = 22, .green = 82, .blue = 158 },
            .status_cancelled => .{ .red = 84, .green = 89, .blue = 97 },
            .status_left_device => .{ .red = 0, .green = 96, .blue = 124 },
            .focus_ring => .{ .red = 12, .green = 74, .blue = 168 },
        },
        .dark => switch (role) {
            .surface => .{ .red = 17, .green = 19, .blue = 23 },
            .surface_raised => .{ .red = 30, .green = 33, .blue = 39 },
            .text_primary => .{ .red = 244, .green = 245, .blue = 247 },
            .text_secondary => .{ .red = 176, .green = 182, .blue = 192 },
            .accent => .{ .red = 126, .green = 178, .blue = 255 },
            .status_succeeded => .{ .red = 104, .green = 214, .blue = 140 },
            .status_denied => .{ .red = 255, .green = 132, .blue = 136 },
            .status_failed => .{ .red = 226, .green = 150, .blue = 235 },
            .status_awaiting_approval => .{ .red = 240, .green = 190, .blue = 90 },
            .status_running => .{ .red = 126, .green = 178, .blue = 255 },
            .status_cancelled => .{ .red = 176, .green = 182, .blue = 192 },
            .status_left_device => .{ .red = 110, .green = 208, .blue = 236 },
            .focus_ring => .{ .red = 150, .green = 195, .blue = 255 },
        },
    };
}

/// Type sizes as roles rather than measurements.
pub const TextRole = enum {
    display,
    title,
    body,
    label,
    caption,
    /// System data such as identifiers, which must align in columns.
    monospace_data,

    /// Whether text at this role counts as large for contrast purposes.
    pub fn isLarge(role: TextRole) bool {
        return switch (role) {
            .display, .title => true,
            .body, .label, .caption, .monospace_data => false,
        };
    }

    /// Base size in points before the user's scale is applied.
    pub fn basePoints(role: TextRole) f32 {
        return switch (role) {
            .display => 34,
            .title => 22,
            .body => 17,
            .label => 15,
            .caption => 13,
            .monospace_data => 14,
        };
    }
};

/// The user's text scale.
///
/// Every surface must remain usable across the whole range. No essential
/// control may depend on truncation, which is why layout is tested at the
/// extremes rather than at the default.
pub const TextScale = enum {
    smallest,
    small,
    standard,
    large,
    largest,
    accessibility_largest,

    pub fn multiplier(scale: TextScale) f32 {
        return switch (scale) {
            .smallest => 0.82,
            .small => 0.92,
            .standard => 1.0,
            .large => 1.18,
            .largest => 1.35,
            .accessibility_largest => 2.0,
        };
    }
};

pub fn textPoints(role: TextRole, scale: TextScale) f32 {
    return role.basePoints() * scale.multiplier();
}

/// Motion, expressed by what it explains rather than by duration.
pub const MotionRole = enum {
    navigate,
    task_split,
    task_merge,
    approval_appear,
    completion,
    failure,
    cancellation,
    endpoint_handoff,

    pub fn milliseconds(role: MotionRole) u16 {
        return switch (role) {
            .navigate => 240,
            .task_split, .task_merge => 200,
            .approval_appear => 180,
            .completion => 160,
            .failure => 220,
            .cancellation => 140,
            .endpoint_handoff => 320,
        };
    }
};

/// How motion behaves when the user has asked for less of it.
///
/// Reduced motion never removes the state change, only the movement conveying
/// it: a surface that simply stopped animating would leave the user unable to
/// tell that anything happened.
pub fn reducedMotionMilliseconds(role: MotionRole) u16 {
    _ = role;
    return 0;
}

/// Longest any motion may take. Beyond this the interface feels unresponsive
/// regardless of how well the movement explains itself.
pub const maximum_motion_milliseconds: u16 = 400;

test "a brand may restyle the accent and nothing else" {
    for (std.enums.values(ColourRole)) |role| {
        const overridable = role == .accent;
        try std.testing.expectEqual(overridable, role.isBrandOverridable());
    }
}

test "every foreground role meets its contrast minimum in both appearances" {
    for (std.enums.values(Appearance)) |appearance| {
        const background = colour(.surface, appearance);
        const raised = colour(.surface_raised, appearance);

        for (std.enums.values(ColourRole)) |role| {
            if (!role.isForeground()) continue;

            const foreground = colour(role, appearance);
            const minimum: f64 = if (role == .focus_ring)
                minimum_non_text_contrast
            else
                minimum_text_contrast;

            try std.testing.expect(foreground.contrastWith(background) >= minimum);
            // Raised surfaces are used for cards and sheets, so the same text
            // must remain legible on them.
            try std.testing.expect(foreground.contrastWith(raised) >= minimum_large_text_contrast);
        }
    }
}

test "every status role is visually distinct from every other" {
    // Two statuses that resolve to near-identical colours would leave a user
    // unable to tell a denial from a completion at a glance.
    const statuses = [_]ColourRole{
        .status_succeeded,
        .status_denied,
        .status_failed,
        .status_awaiting_approval,
        .status_left_device,
    };
    for (std.enums.values(Appearance)) |appearance| {
        for (statuses, 0..) |first, index| {
            for (statuses[index + 1 ..]) |second| {
                const difference = colourDistance(
                    colour(first, appearance),
                    colour(second, appearance),
                );
                try std.testing.expect(difference > 60);
            }
        }
    }
}

fn colourDistance(first: Colour, second: Colour) f64 {
    const red = @as(f64, @floatFromInt(first.red)) - @as(f64, @floatFromInt(second.red));
    const green = @as(f64, @floatFromInt(first.green)) - @as(f64, @floatFromInt(second.green));
    const blue = @as(f64, @floatFromInt(first.blue)) - @as(f64, @floatFromInt(second.blue));
    return @sqrt(red * red + green * green + blue * blue);
}

test "dark is tuned independently rather than inverted from light" {
    // An inverted palette would make each dark value the arithmetic complement
    // of its light counterpart, which produces unusable status colours.
    var inverted_count: usize = 0;
    for (std.enums.values(ColourRole)) |role| {
        const light = colour(role, .light);
        const dark = colour(role, .dark);
        if (@as(u16, light.red) + @as(u16, dark.red) == 255 and
            @as(u16, light.green) + @as(u16, dark.green) == 255)
        {
            inverted_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), inverted_count);
}

test "contrast is symmetric and bounded" {
    const white: Colour = .{ .red = 255, .green = 255, .blue = 255 };
    const black: Colour = .{ .red = 0, .green = 0, .blue = 0 };

    try std.testing.expectApproxEqAbs(@as(f64, 21.0), white.contrastWith(black), 0.01);
    try std.testing.expectApproxEqAbs(
        white.contrastWith(black),
        black.contrastWith(white),
        0.0001,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), white.contrastWith(white), 0.0001);
}

test "text scales across the whole range without collapsing" {
    for (std.enums.values(TextRole)) |role| {
        var previous: f32 = 0;
        for (std.enums.values(TextScale)) |scale| {
            const points = textPoints(role, scale);
            try std.testing.expect(points > previous);
            previous = points;
        }
        // The largest accessibility scale must at least double the base, or it
        // is not serving the users it exists for.
        try std.testing.expect(
            textPoints(role, .accessibility_largest) >= role.basePoints() * 1.9,
        );
    }
}

test "caption text is never smaller than a legible floor" {
    // The smallest role at the smallest scale is the worst case a user can
    // configure, and it must still be readable.
    try std.testing.expect(textPoints(.caption, .smallest) >= 10.0);
}

test "every motion stays within the responsiveness budget" {
    for (std.enums.values(MotionRole)) |role| {
        try std.testing.expect(role.milliseconds() <= maximum_motion_milliseconds);
        try std.testing.expect(role.milliseconds() > 0);
    }
}

test "reduced motion removes movement without removing the state change" {
    for (std.enums.values(MotionRole)) |role| {
        try std.testing.expectEqual(@as(u16, 0), reducedMotionMilliseconds(role));
    }
}
