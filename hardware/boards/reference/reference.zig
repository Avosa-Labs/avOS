//! The reference handset board.
//!
//! A realistic phone: display, touch, audio in and out, haptics, battery and
//! charging, motion sensors, a camera, radios, a fingerprint reader, satellite
//! positioning, a secure element, and thermal sensors. It is what the platform
//! is validated against as a device a person would carry, distinct from the
//! emulator only in that it stands for real silicon rather than all of it.
//!
//! It deliberately does not claim capabilities a reference handset would not
//! have; the abstraction refuses those with a reason, and a subsystem that needs
//! one absent here learns so up front rather than at the moment it reaches for
//! missing hardware.

const std = @import("std");
const abstraction = @import("../../abstraction/abstraction.zig");

/// The reference handset's declaration.
pub fn descriptor() abstraction.Descriptor {
    var provided = std.EnumSet(abstraction.Capability).initEmpty();
    for ([_]abstraction.Capability{
        .display,
        .touch_input,
        .audio_output,
        .audio_input,
        .haptics,
        .battery,
        .charging,
        .motion_sensors,
        .camera,
        .radio,
        .biometric,
        .positioning,
        .secure_element,
        .thermal_sensors,
    }) |capability| provided.insert(capability);
    return .{ .board_class = "reference-handset", .provided = provided };
}

/// Builds a reference board backed by a table.
pub fn build() abstraction.TableBoard {
    return .{ .descriptor = descriptor() };
}

test "the reference handset provides what a phone has" {
    var board_state = build();
    const board = board_state.board();
    for ([_]abstraction.Capability{ .display, .touch_input, .camera, .radio, .biometric }) |capability| {
        try std.testing.expect(board.query(capability).isAvailable());
    }
}

test "the reference handset declares itself honestly" {
    var board_state = build();
    try std.testing.expect(board_state.board().declarationIsHonest());
}

test "the reference handset can uphold the security guarantees" {
    var board_state = build();
    try std.testing.expect(board_state.board().describe().canSecure());
}

test "the platform is written once and both boards fit behind it" {
    // The point of the abstraction: identical code queries either board.
    const emulator = @import("../emulator/emulator.zig");
    var emulator_state = emulator.build();
    var reference_state = build();

    for ([_]abstraction.Board{ emulator_state.board(), reference_state.board() }) |board| {
        // Every board can be interrogated for the foundational capability
        // before it is trusted with anything.
        try std.testing.expect(board.describe().canSecure());
        try std.testing.expect(board.declarationIsHonest());
    }
}
