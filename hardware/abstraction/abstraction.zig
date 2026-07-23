//! What every board must provide, and how the platform asks for it.
//!
//! A board is a physical device the platform runs on: the emulator, a reference
//! handset, eventually a shipped phone. Each has different silicon, but the
//! platform above must not know which — it asks for a capability by name and
//! gets back either the interface that provides it or an honest statement that
//! this board does not have it.
//!
//! That honesty is the whole design. The failure this prevents is a platform
//! that assumes a board has a sensor it lacks, discovers the absence at the
//! moment it tries to use it, and has no graceful answer. Here a board declares
//! exactly what it has up front, a request for something absent is refused with
//! a reason rather than a crash, and a request for something present returns a
//! handle the caller can use. A board can be interrogated before it is trusted
//! to run anything.
//!
//! There is no hardware in this module and there never will be. It is the
//! description of a board and the protocol for querying one. A board's actual
//! silicon lives in `hardware/boards/<name>/`, behind this same description, so
//! the platform is written once against the description and every board fits it.

const std = @import("std");

/// A hardware capability a board may or may not provide.
///
/// Named by what it does for a person or the system, not by the part number
/// that implements it. Two boards with different display controllers both
/// provide `.display`, because the platform's question is "can this device draw"
/// and not "which controller does it use".
pub const Capability = enum {
    display,
    touch_input,
    audio_output,
    audio_input,
    haptics,
    battery,
    charging,
    /// Motion, orientation, ambient light: the passive sensors.
    motion_sensors,
    camera,
    /// Cellular, wireless, and near-field radios as a class.
    radio,
    /// Fingerprint, face, or other biometric capture.
    biometric,
    /// Satellite positioning.
    positioning,
    /// A discrete element that holds keys the main processor cannot read.
    secure_element,
    /// A monotonic counter and temperature the thermal policy reads.
    thermal_sensors,

    pub const count = std.enums.values(Capability).len;

    /// Whether a board that lacks this capability can still be a usable device.
    ///
    /// A device with no display is not a phone but may be a sensor node; a
    /// device with no secure element cannot make the security guarantees the
    /// platform rests on. The distinction lets a board be validated against
    /// what it claims to be rather than against one fixed shape.
    pub fn isFoundational(capability: Capability) bool {
        return capability == .secure_element;
    }
};

/// Why a capability request was refused.
pub const Refusal = enum {
    /// The board does not have this capability at all.
    not_present,
    /// The board has it, but it is not initialized yet.
    not_ready,
    /// The board has it, but it has failed and is not usable.
    faulted,

    pub fn describe(refusal: Refusal) []const u8 {
        return switch (refusal) {
            .not_present => "this board does not provide this capability",
            .not_ready => "this capability is present but not yet initialized",
            .faulted => "this capability has failed and is not usable",
        };
    }
};

/// An opaque reference to a capability's provider.
///
/// The platform gets one of these for a capability that is present and ready,
/// and passes it to the subsystem that drives that hardware. It is not the
/// hardware; it is a token that says "this board's provider for this capability,
/// as of this query".
pub const Provider = struct {
    capability: Capability,
    /// Identifies the concrete provider within the board. Opaque to the
    /// platform, meaningful only to the board that issued it.
    handle: u32,
};

/// The result of asking a board for a capability.
pub const Query = union(enum) {
    available: Provider,
    unavailable: Refusal,

    pub fn isAvailable(query: Query) bool {
        return query == .available;
    }
};

/// What a board declares about itself.
///
/// Filled in by the board and read by the platform before anything else runs.
/// A board that misdeclares — claims a capability it lacks — fails validation
/// here rather than at the moment the missing hardware is reached, which is the
/// entire point of declaring up front.
pub const Descriptor = struct {
    /// Which board this is. Stable, technical, never a marketing name.
    board_class: []const u8,
    /// The capabilities this board provides. Everything not in this set is
    /// absent, and a request for it is refused as `not_present`.
    provided: std.EnumSet(Capability),

    pub fn provides(descriptor: Descriptor, capability: Capability) bool {
        return descriptor.provided.contains(capability);
    }

    /// Whether this board can uphold the platform's security guarantees.
    ///
    /// A board without a secure element cannot, and the platform must know that
    /// before it decides what to allow, not after it has already trusted the
    /// board with a key.
    pub fn canSecure(descriptor: Descriptor) bool {
        var foundational = std.EnumSet(Capability).initEmpty();
        for (std.enums.values(Capability)) |capability| {
            if (capability.isFoundational()) foundational.insert(capability);
        }
        return descriptor.provided.supersetOf(foundational);
    }
};

/// A board the platform can query.
///
/// An interface, because the platform is written once against it and every
/// board — emulator, reference, shipped — fits behind the same shape. The board
/// answers what it declares and what state each provider is in; it never runs
/// platform logic.
pub const Board = struct {
    context_pointer: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        describe: *const fn (context_pointer: *anyopaque) Descriptor,
        query: *const fn (context_pointer: *anyopaque, capability: Capability) Query,
    };

    /// What this board declares it has.
    pub fn describe(board: Board) Descriptor {
        return board.vtable.describe(board.context_pointer);
    }

    /// Ask for a capability. Returns a provider if present and ready, or a
    /// refusal that says why not.
    pub fn query(board: Board, capability: Capability) Query {
        return board.vtable.query(board.context_pointer, capability);
    }

    /// A capability's provider, or an error if it cannot be had.
    ///
    /// The form most callers want: a provider they can use, or a refusal they
    /// must handle. A caller that ignored the refusal and used a stale provider
    /// would be reaching for hardware that is not there.
    pub fn require(board: Board, capability: Capability) error{Unavailable}!Provider {
        return switch (board.query(capability)) {
            .available => |provider| provider,
            .unavailable => error.Unavailable,
        };
    }

    /// Whether every capability the board declares can actually be queried.
    ///
    /// Validation: a board that declares a capability its query refuses as
    /// `not_present` is lying about itself, and catching that here is why the
    /// declaration exists.
    pub fn declarationIsHonest(board: Board) bool {
        const descriptor = board.describe();
        for (std.enums.values(Capability)) |capability| {
            const declared = descriptor.provides(capability);
            const queried = board.query(capability);
            switch (queried) {
                .available => if (!declared) return false,
                .unavailable => |refusal| {
                    // A declared capability may be not_ready or faulted, but a
                    // declared one must never answer not_present.
                    if (declared and refusal == .not_present) return false;
                    // An undeclared one must answer not_present, never anything
                    // that implies it exists.
                    if (!declared and refusal != .not_present) return false;
                },
            }
        }
        return true;
    }
};

/// A board described entirely by a static table, for the emulator and for tests.
///
/// It provides whatever its descriptor says and refuses everything else. It is
/// not a stand-in for hardware in the dangerous sense — it drives no silicon and
/// claims none. It answers the description protocol truthfully for a board whose
/// providers are all ready, which is exactly what the emulator is.
pub const TableBoard = struct {
    descriptor: Descriptor,
    /// Capabilities that are present but reporting not-ready, so a test can
    /// exercise the initialization path.
    not_ready: std.EnumSet(Capability) = .initEmpty(),
    /// Capabilities that are present but faulted.
    faulted: std.EnumSet(Capability) = .initEmpty(),

    pub fn board(table: *TableBoard) Board {
        return .{ .context_pointer = table, .vtable = &vtable };
    }

    const vtable: Board.VTable = .{
        .describe = describe,
        .query = query,
    };

    fn describe(context_pointer: *anyopaque) Descriptor {
        const table: *TableBoard = @ptrCast(@alignCast(context_pointer));
        return table.descriptor;
    }

    fn query(context_pointer: *anyopaque, capability: Capability) Query {
        const table: *TableBoard = @ptrCast(@alignCast(context_pointer));
        if (!table.descriptor.provides(capability)) {
            return .{ .unavailable = .not_present };
        }
        if (table.faulted.contains(capability)) return .{ .unavailable = .faulted };
        if (table.not_ready.contains(capability)) return .{ .unavailable = .not_ready };
        return .{ .available = .{ .capability = capability, .handle = @intFromEnum(capability) } };
    }
};

fn setOf(capabilities: []const Capability) std.EnumSet(Capability) {
    var set = std.EnumSet(Capability).initEmpty();
    for (capabilities) |capability| set.insert(capability);
    return set;
}

test "a board provides what it declares and refuses the rest" {
    var table: TableBoard = .{ .descriptor = .{
        .board_class = "reference",
        .provided = setOf(&.{ .display, .secure_element }),
    } };
    const board = table.board();

    try std.testing.expect(board.query(.display).isAvailable());
    try std.testing.expect(!board.query(.camera).isAvailable());

    // An absent capability is refused as not_present, with a reason.
    try std.testing.expectEqual(
        Query{ .unavailable = .not_present },
        board.query(.camera),
    );
}

test "requiring an absent capability is an error, not a crash" {
    var table: TableBoard = .{ .descriptor = .{
        .board_class = "sensor-node",
        .provided = setOf(&.{ .motion_sensors, .secure_element }),
    } };
    const board = table.board();

    _ = try board.require(.motion_sensors);
    try std.testing.expectError(error.Unavailable, board.require(.display));
}

test "a present but not-ready capability is refused distinctly from an absent one" {
    var table: TableBoard = .{
        .descriptor = .{
            .board_class = "reference",
            .provided = setOf(&.{ .display, .secure_element }),
        },
        .not_ready = setOf(&.{.display}),
    };
    const board = table.board();

    // not_ready and not_present are different answers: one means wait, the
    // other means never.
    try std.testing.expectEqual(Query{ .unavailable = .not_ready }, board.query(.display));
    try std.testing.expectEqual(Query{ .unavailable = .not_present }, board.query(.camera));
}

test "a faulted capability is refused as faulted" {
    var table: TableBoard = .{
        .descriptor = .{
            .board_class = "reference",
            .provided = setOf(&.{ .camera, .secure_element }),
        },
        .faulted = setOf(&.{.camera}),
    };
    try std.testing.expectEqual(
        Query{ .unavailable = .faulted },
        table.board().query(.camera),
    );
}

/// A board whose declaration disagrees with its answers, for the validator to
/// catch. It claims a camera and then refuses it as not_present, which is
/// exactly the lie declaring up front exists to expose.
const DishonestBoard = struct {
    fn board(self: *DishonestBoard) Board {
        return .{ .context_pointer = self, .vtable = &vtable };
    }

    const vtable: Board.VTable = .{ .describe = describe, .query = query };

    fn describe(_: *anyopaque) Descriptor {
        return .{
            .board_class = "liar",
            .provided = setOf(&.{ .display, .camera, .secure_element }),
        };
    }

    fn query(_: *anyopaque, capability: Capability) Query {
        // Answers for the camera as though it were absent, contradicting the
        // declaration that claims it.
        if (capability == .camera) return .{ .unavailable = .not_present };
        if (capability == .display or capability == .secure_element) {
            return .{ .available = .{ .capability = capability, .handle = 0 } };
        }
        return .{ .unavailable = .not_present };
    }
};

test "a board that declares a capability it cannot provide fails validation" {
    // The honest table board passes.
    var honest: TableBoard = .{ .descriptor = .{
        .board_class = "reference",
        .provided = setOf(&.{ .display, .secure_element }),
    } };
    try std.testing.expect(honest.board().declarationIsHonest());

    // A board that claims a camera and then refuses it as not_present is caught.
    // The whole point of declaring up front is to expose exactly this before the
    // missing hardware is reached.
    var liar: DishonestBoard = .{};
    try std.testing.expect(!liar.board().declarationIsHonest());
}

test "a board with a secure element can uphold the security guarantees" {
    var secured: TableBoard = .{ .descriptor = .{
        .board_class = "reference",
        .provided = setOf(&.{ .display, .secure_element }),
    } };
    try std.testing.expect(secured.board().describe().canSecure());

    var insecure: TableBoard = .{ .descriptor = .{
        .board_class = "toy",
        .provided = setOf(&.{.display}),
    } };
    // The platform must know a board cannot secure before it trusts it with a
    // key, not after.
    try std.testing.expect(!insecure.board().describe().canSecure());
}

test "the foundational capability is exactly the secure element" {
    var foundational: usize = 0;
    for (std.enums.values(Capability)) |capability| {
        if (capability.isFoundational()) {
            try std.testing.expectEqual(Capability.secure_element, capability);
            foundational += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), foundational);
}

test "every refusal explains itself" {
    for (std.enums.values(Refusal)) |refusal| {
        try std.testing.expect(refusal.describe().len > 0);
    }
}

test "a fully-equipped board is honest across every capability" {
    var everything: TableBoard = .{ .descriptor = .{
        .board_class = "reference",
        .provided = setOf(std.enums.values(Capability)),
    } };
    const board = everything.board();
    try std.testing.expect(board.declarationIsHonest());
    for (std.enums.values(Capability)) |capability| {
        try std.testing.expect(board.query(capability).isAvailable());
    }
}

test "a minimal board is honest too" {
    // Only the foundational capability. Everything else absent, and the board
    // says so consistently.
    var minimal: TableBoard = .{ .descriptor = .{
        .board_class = "headless",
        .provided = setOf(&.{.secure_element}),
    } };
    try std.testing.expect(minimal.board().declarationIsHonest());
}
