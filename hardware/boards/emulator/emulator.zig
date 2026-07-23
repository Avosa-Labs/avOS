//! The emulator board.
//!
//! A board with every capability present and ready. It exists so the platform
//! can be exercised end to end without physical hardware, and it declares the
//! full capability set precisely so that a subsystem which works here has been
//! run against every interface it will meet on a real board.
//!
//! It is described the same way every board is — through the abstraction's
//! descriptor and query protocol — so nothing above it can tell it apart from a
//! shipped device except by reading `board_class`. It drives no silicon; a
//! provider it hands back is a token, and what carries it out is the emulator
//! tree under `emulator/`, not this description of it.

const std = @import("std");
const abstraction = @import("../../abstraction/abstraction.zig");

/// The emulator's declaration: everything, present and ready.
pub fn descriptor() abstraction.Descriptor {
    var provided = std.EnumSet(abstraction.Capability).initEmpty();
    for (std.enums.values(abstraction.Capability)) |capability| provided.insert(capability);
    return .{ .board_class = "emulator", .provided = provided };
}

/// Builds an emulator board backed by a table.
pub fn build() abstraction.TableBoard {
    return .{ .descriptor = descriptor() };
}

test "the emulator provides every capability" {
    var board_state = build();
    const board = board_state.board();
    for (std.enums.values(abstraction.Capability)) |capability| {
        try std.testing.expect(board.query(capability).isAvailable());
    }
}

test "the emulator declares itself honestly" {
    var board_state = build();
    try std.testing.expect(board_state.board().declarationIsHonest());
}

test "the emulator can uphold the security guarantees" {
    var board_state = build();
    // It has a secure element, so the platform may trust it with a key even
    // though its element is the software one behind that capability.
    try std.testing.expect(board_state.board().describe().canSecure());
}

test "the emulator names itself so nothing mistakes it for a shipped device" {
    var board_state = build();
    try std.testing.expectEqualStrings("emulator", board_state.board().describe().board_class);
}
