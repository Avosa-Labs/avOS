//! A/B slot management for atomic, rollback-capable updates.
//!
//! An update must never leave the device unable to boot. This tracks two boot
//! slots and walks an update through a fixed lifecycle on the inactive one —
//! stage, verify, commit, then mark good after it boots — so the running slot is
//! untouched until the new one has proven it can boot. If the committed slot
//! fails, the device falls back to the slot that was known good, and nothing was
//! overwritten in place.
//!
//! Every transition is idempotent: staging a version already staged, committing a
//! commit already made, or marking good a slot already good all succeed without
//! changing anything, so an update interrupted by a reset and retried lands in
//! the same place rather than a corrupt one.

const std = @import("std");

pub const Slot = enum {
    a,
    b,

    /// The other slot. An update always targets the one the device is not
    /// running from, so a failure can never brick the slot in use.
    pub fn other(slot: Slot) Slot {
        return switch (slot) {
            .a => .b,
            .b => .a,
        };
    }
};

/// Where a slot is in the update lifecycle.
pub const State = enum {
    /// Nothing installed, or wiped.
    empty,
    /// New contents written, not yet verified.
    staged,
    /// Verified by the boot chain; eligible to be committed.
    verified,
    /// Selected as the next slot to boot, but not yet proven to boot.
    committed,
    /// Booted successfully at least once. The safe fallback.
    good,
};

pub const Error = error{
    /// A transition was asked for from a state that does not allow it.
    OutOfOrder,
    /// There is no good slot to fall back to.
    NoGoodSlot,
};

pub const SlotInfo = struct {
    state: State = .empty,
    version: u32 = 0,
};

/// The two slots and which one the device is running.
pub const Slots = struct {
    active: Slot,
    info: [2]SlotInfo,

    fn at(slots: *Slots, slot: Slot) *SlotInfo {
        return &slots.info[@intFromEnum(slot)];
    }

    fn get(slots: Slots, slot: Slot) SlotInfo {
        return slots.info[@intFromEnum(slot)];
    }

    /// A device with slot `active` already booted and marked good.
    pub fn init(active: Slot, active_version: u32) Slots {
        var slots: Slots = .{ .active = active, .info = .{ .{}, .{} } };
        slots.at(active).* = .{ .state = .good, .version = active_version };
        return slots;
    }

    /// The slot an update targets: never the active one.
    pub fn target(slots: Slots) Slot {
        return slots.active.other();
    }

    /// Writes a new version into the target slot. Restaging the same version onto
    /// an already-staged target is a no-op, so a retried write does not reset
    /// progress.
    pub fn stage(slots: *Slots, version: u32) void {
        const info = slots.at(slots.target());
        if (info.state == .staged and info.version == version) return;
        info.* = .{ .state = .staged, .version = version };
    }

    /// Records that the boot chain verified the staged target. The caller runs
    /// the verification; this only advances the state once it passed.
    pub fn markVerified(slots: *Slots) Error!void {
        const info = slots.at(slots.target());
        if (info.state == .verified) return; // idempotent
        if (info.state != .staged) return error.OutOfOrder;
        info.state = .verified;
    }

    /// Selects the verified target as the next slot to boot. The active slot is
    /// left good, so a failure to boot the committed slot can fall back to it.
    pub fn commit(slots: *Slots) Error!void {
        const info = slots.at(slots.target());
        if (info.state == .committed) return; // idempotent
        if (info.state != .verified) return error.OutOfOrder;
        info.state = .committed;
    }

    /// The slot the device should boot next: the committed one if there is a
    /// commit in flight, otherwise the active good slot.
    pub fn nextBoot(slots: Slots) Slot {
        const t = slots.target();
        if (slots.get(t).state == .committed) return t;
        return slots.active;
    }

    /// Confirms the committed slot booted. It becomes the new active good slot,
    /// and the old one is left good as a fallback until the next update overwrites
    /// it. Marking good a slot already good succeeds unchanged.
    pub fn markGood(slots: *Slots, slot: Slot) Error!void {
        const info = slots.at(slot);
        if (info.state == .good) {
            slots.active = slot;
            return;
        }
        if (info.state != .committed) return error.OutOfOrder;
        info.state = .good;
        slots.active = slot;
    }

    /// Abandons a committed update that failed to boot and returns the slot to
    /// fall back to — the other slot, which must still be good. The failed slot
    /// is left committed-but-not-good so it is never chosen again without a fresh
    /// commit.
    pub fn rollback(slots: *Slots) Error!Slot {
        const committed = slots.target();
        const fallback = committed.other();
        if (slots.get(fallback).state != .good) return error.NoGoodSlot;
        // Drop the failed commit so nextBoot stops selecting it.
        slots.at(committed).state = .verified;
        slots.active = fallback;
        return fallback;
    }
};

const testing = std.testing;

test "an update walks stage, verify, commit, then good on the inactive slot" {
    var slots: Slots = .init(.a, 5);
    try testing.expectEqual(Slot.b, slots.target());

    slots.stage(6);
    try slots.markVerified();
    try slots.commit();

    // The next boot is the committed slot; the active one is untouched.
    try testing.expectEqual(Slot.b, slots.nextBoot());
    try testing.expectEqual(State.good, slots.get(.a).state);

    // It boots and is marked good, becoming active; the old slot stays a fallback.
    try slots.markGood(.b);
    try testing.expectEqual(Slot.b, slots.active);
    try testing.expectEqual(State.good, slots.get(.a).state);
}

test "each transition is idempotent under a retried, interrupted update" {
    var slots: Slots = .init(.a, 5);
    slots.stage(6);
    slots.stage(6); // restaging the same version changes nothing
    try slots.markVerified();
    try slots.markVerified(); // replay
    try slots.commit();
    try slots.commit(); // replay
    try testing.expectEqual(State.committed, slots.get(.b).state);
}

test "a transition out of order is refused" {
    var slots: Slots = .init(.a, 5);
    // Committing before verifying is not allowed.
    try testing.expectError(error.OutOfOrder, slots.commit());
    slots.stage(6);
    try testing.expectError(error.OutOfOrder, slots.commit());
}

test "a committed slot that fails to boot rolls back to the good one" {
    var slots: Slots = .init(.a, 5);
    slots.stage(6);
    try slots.markVerified();
    try slots.commit();
    try testing.expectEqual(Slot.b, slots.nextBoot());

    // Slot b failed to boot; fall back to a, which is still good.
    const fallback = try slots.rollback();
    try testing.expectEqual(Slot.a, fallback);
    try testing.expectEqual(Slot.a, slots.active);
    try testing.expectEqual(Slot.a, slots.nextBoot());
}

test "rollback with no good fallback is refused" {
    var slots: Slots = .{ .active = .a, .info = .{
        .{ .state = .committed, .version = 6 },
        .{ .state = .empty },
    } };
    slots.active = .b;
    // target() is a, which is committed-not-good; fallback b is empty.
    try testing.expectError(error.NoGoodSlot, slots.rollback());
}
