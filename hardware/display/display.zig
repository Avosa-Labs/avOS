//! Deciding a display's brightness and refresh rate from what is being shown and
//! what the device can afford.
//!
//! A display is the largest single draw on a phone's battery, and the two knobs
//! that matter — how bright it is and how often it refreshes — trade directly
//! against how long the device lasts and how it feels. Full brightness in a dark
//! room wastes charge and dazzles; a high refresh rate on a static page spends
//! power to redraw pixels nobody changed. So brightness and refresh are not set
//! to the maximum the panel supports; they are chosen from ambient light, the
//! content, and the device's power state, and this module makes that choice.
//!
//! It drives no panel. It takes those inputs — facts the sensors and the power
//! policy supply — and returns the brightness and refresh the panel should be
//! set to. The choice is logic, testable across lighting and power conditions a
//! bench would have to physically reproduce.

const std = @import("std");
const battery = @import("../battery/battery.zig");

/// Brightness as a fraction of the panel's maximum, in hundredths of a percent.
pub const BrightnessBasisPoints = u16;

pub const full_brightness: BrightnessBasisPoints = 10_000;

/// A refresh rate the panel can run at, in hertz.
///
/// A small set rather than a continuous value, because a panel switches between
/// discrete modes and asking for one it does not have is a request it cannot
/// honour.
pub const RefreshRate = enum(u16) {
    /// The floor: enough for legible static content, cheapest to drive.
    hz_30 = 30,
    /// Standard motion.
    hz_60 = 60,
    /// Smooth scrolling and animation, most expensive.
    hz_120 = 120,

    pub fn hertz(rate: RefreshRate) u16 {
        return @intFromEnum(rate);
    }
};

/// What is being shown, as far as the refresh choice is concerned.
pub const Content = enum {
    /// Nothing is moving. The lowest refresh is enough and the rest is waste.
    static,
    /// Text is scrolling or a small animation is playing.
    scrolling,
    /// Video or continuous motion, where a low refresh is visibly worse.
    motion,
};

/// Ambient light in lux, as the light sensor reports it.
pub const Lux = u32;

/// The inputs a display decision is made from.
pub const Conditions = struct {
    ambient_lux: Lux,
    content: Content,
    power_state: battery.PowerState,
    /// Whether the person has set a manual brightness, overriding automatic
    /// choice. A person's explicit choice is not second-guessed.
    manual_brightness: ?BrightnessBasisPoints = null,
};

/// What the panel should be set to.
pub const Settings = struct {
    brightness: BrightnessBasisPoints,
    refresh: RefreshRate,
};

/// The brightness curve's reference points: how bright to be at a given ambient
/// light level. Between them brightness scales linearly.
const dim_lux: Lux = 10;
const bright_lux: Lux = 10_000;
const min_auto_brightness: BrightnessBasisPoints = 1_000;

/// Decides the display settings.
///
/// A manual brightness is honoured as set — a person's explicit choice is not
/// overridden by the ambient curve — but even a manual setting is dimmed when the
/// device is critically low, because staying alive outranks staying bright.
/// Refresh follows the content, capped by the power state, because a high refresh
/// on a draining device spends the charge that keeps it running on smoothness
/// nobody asked to pay for.
pub fn decide(conditions: Conditions) Settings {
    const brightness = brightnessFor(conditions);
    const refresh = refreshFor(conditions.content, conditions.power_state);
    return .{ .brightness = brightness, .refresh = refresh };
}

fn brightnessFor(conditions: Conditions) BrightnessBasisPoints {
    const base = conditions.manual_brightness orelse autoBrightness(conditions.ambient_lux);

    // Whatever the source, a critically low device dims to save charge. A person
    // would rather a readable-but-dim screen that survives than a bright one
    // that dies.
    return switch (conditions.power_state) {
        .critical, .save_and_stop => @min(base, min_auto_brightness * 2),
        else => base,
    };
}

/// Brightness from ambient light: dim indoors, bright in sunlight, scaling
/// linearly between the two reference points.
fn autoBrightness(lux: Lux) BrightnessBasisPoints {
    if (lux <= dim_lux) return min_auto_brightness;
    if (lux >= bright_lux) return full_brightness;

    const span = bright_lux - dim_lux;
    const above = lux - dim_lux;
    const range = full_brightness - min_auto_brightness;
    const scaled = @as(u64, range) * above / span;
    return min_auto_brightness + @as(BrightnessBasisPoints, @intCast(scaled));
}

/// Refresh from content, lowered when power is short.
fn refreshFor(content: Content, power_state: battery.PowerState) RefreshRate {
    // A draining device does not spend charge redrawing pixels for smoothness.
    // Below low, the panel is held to the cheapest rate whatever the content.
    if (!power_state.permitsBackgroundWork()) return .hz_30;

    return switch (content) {
        .static => .hz_30,
        .scrolling => .hz_60,
        .motion => .hz_120,
    };
}

test "a dark room gives a dim but legible screen" {
    const settings = decide(.{
        .ambient_lux = 5,
        .content = .static,
        .power_state = .ample,
    });
    try std.testing.expectEqual(min_auto_brightness, settings.brightness);
}

test "direct sunlight gives full brightness" {
    const settings = decide(.{
        .ambient_lux = 50_000,
        .content = .static,
        .power_state = .ample,
    });
    try std.testing.expectEqual(full_brightness, settings.brightness);
}

test "brightness rises with ambient light" {
    // Monotonic across the range: more light never gives a dimmer screen.
    var previous: BrightnessBasisPoints = 0;
    var lux: Lux = 0;
    while (lux <= 20_000) : (lux += 100) {
        const brightness = autoBrightness(lux);
        try std.testing.expect(brightness >= previous);
        previous = brightness;
    }
}

test "a manual brightness is honoured, not second-guessed" {
    const settings = decide(.{
        .ambient_lux = 50_000, // bright room, auto would go high
        .content = .static,
        .power_state = .ample,
        .manual_brightness = 2_000, // person chose dim
    });
    try std.testing.expectEqual(@as(BrightnessBasisPoints, 2_000), settings.brightness);
}

test "even a manual brightness is dimmed when critically low" {
    const settings = decide(.{
        .ambient_lux = 50_000,
        .content = .static,
        .power_state = .critical,
        .manual_brightness = full_brightness,
    });
    // Staying alive outranks staying bright.
    try std.testing.expect(settings.brightness < full_brightness);
}

test "static content uses the cheapest refresh" {
    const settings = decide(.{
        .ambient_lux = 500,
        .content = .static,
        .power_state = .ample,
    });
    try std.testing.expectEqual(RefreshRate.hz_30, settings.refresh);
}

test "motion content uses the highest refresh when power allows" {
    const settings = decide(.{
        .ambient_lux = 500,
        .content = .motion,
        .power_state = .ample,
    });
    try std.testing.expectEqual(RefreshRate.hz_120, settings.refresh);
}

test "a low battery holds the refresh down whatever the content" {
    // Motion content, but the device is low: it does not spend charge on
    // smoothness nobody asked to pay for.
    const settings = decide(.{
        .ambient_lux = 500,
        .content = .motion,
        .power_state = .low,
    });
    try std.testing.expectEqual(RefreshRate.hz_30, settings.refresh);
}

test "refresh never exceeds what the power state permits" {
    // Swept: for every content and power state, a low device is capped.
    for (std.enums.values(Content)) |content| {
        for (std.enums.values(battery.PowerState)) |state| {
            const settings = decide(.{
                .ambient_lux = 500,
                .content = content,
                .power_state = state,
            });
            if (!state.permitsBackgroundWork()) {
                try std.testing.expectEqual(RefreshRate.hz_30, settings.refresh);
            }
        }
    }
}

test "the refresh rate reports its own hertz" {
    try std.testing.expectEqual(@as(u16, 30), RefreshRate.hz_30.hertz());
    try std.testing.expectEqual(@as(u16, 120), RefreshRate.hz_120.hertz());
}
