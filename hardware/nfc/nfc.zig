//! Deciding what a near-field tap is allowed to do without a person meaning it.
//!
//! Near-field communication happens by proximity: bring the phone close to a
//! reader and a transaction begins. That is the convenience and the danger at
//! once, because proximity is not intent. A phone in a pocket brushed against a
//! reader, or held near a hostile tag, should not authorize a payment or pair
//! with a device on the strength of nearness alone. So a tap's authority depends
//! on what it is trying to do and whether the device is in a state where the
//! person plausibly meant it, and this module makes that call.
//!
//! It drives no radio field. It answers whether a given near-field interaction
//! is permitted in the device's current state, as a pure function, so the rule
//! that a payment needs a present, unlocked, deliberate person is verified
//! rather than assumed.

const std = @import("std");

/// What a near-field tap is trying to do.
///
/// Ordered by how much a mistaken tap would cost, because the bar rises with the
/// cost: reading a public tag is harmless, moving money is not.
pub const Interaction = enum {
    /// Read a passive tag: a poster, a label, a transit sign. No lasting effect.
    read_tag,
    /// Emulate a card to unlock a door or ride transit. A real-world action, but
    /// a reversible and low-value one.
    access_credential,
    /// Pair with another device by tapping. Sets up a lasting connection.
    pair_device,
    /// Authorize a payment. The interaction a mistaken tap must never complete.
    payment,

    /// Whether this interaction moves value or grants lasting access, and so
    /// needs deliberate intent rather than mere proximity.
    pub fn needsDeliberateIntent(interaction: Interaction) bool {
        return switch (interaction) {
            .read_tag => false,
            .access_credential, .pair_device, .payment => true,
        };
    }

    /// Whether this interaction needs the person to have just authenticated.
    ///
    /// Only payment does: unlocking a door with the phone is meant to be quick,
    /// but moving money is worth a fingerprint even to a person in a hurry.
    pub fn needsRecentAuthentication(interaction: Interaction) bool {
        return interaction == .payment;
    }
};

/// What the device knows when a tap happens.
pub const Situation = struct {
    /// Whether the screen is on and unlocked. A pocketed, locked phone did not
    /// mean to tap anything beyond reading a public tag.
    unlocked: bool,
    /// Whether the person authenticated within the recent window. Required for
    /// payment.
    recently_authenticated: bool,
    /// Whether the near-field radio is enabled at all. A person who turned it
    /// off did so to stop exactly these interactions.
    radio_enabled: bool,
};

/// Why a tap was refused.
pub const Refusal = enum {
    /// The near-field radio is off.
    radio_disabled,
    /// The interaction needs a deliberate, unlocked person and the device is
    /// locked.
    intent_required,
    /// The interaction needs a recent authentication and there is none.
    authentication_required,
};

/// The outcome of a tap.
pub const Decision = union(enum) {
    allow,
    deny: Refusal,

    pub fn isAllowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// Decides whether a tap may proceed.
///
/// The radio being off refuses everything, including a tag read, because a
/// person who disabled the radio wanted nothing to happen. Beyond that, the bar
/// rises with the interaction: a tag read needs only the radio, a credential or
/// a pairing needs an unlocked device so the tap was plausibly meant, and a
/// payment needs a recent authentication on top, because proximity plus an
/// unlock is still not proof a person meant to spend.
pub fn decide(interaction: Interaction, situation: Situation) Decision {
    // A disabled radio means the person chose for nothing to happen. Even a
    // harmless read is refused, because the choice was about the radio, not the
    // risk.
    if (!situation.radio_enabled) return .{ .deny = .radio_disabled };

    if (interaction.needsDeliberateIntent() and !situation.unlocked) {
        return .{ .deny = .intent_required };
    }

    if (interaction.needsRecentAuthentication() and !situation.recently_authenticated) {
        return .{ .deny = .authentication_required };
    }

    return .allow;
}

const ready: Situation = .{
    .unlocked = true,
    .recently_authenticated = true,
    .radio_enabled = true,
};

test "reading a public tag needs only the radio" {
    const situation: Situation = .{
        .unlocked = false,
        .recently_authenticated = false,
        .radio_enabled = true,
    };
    // A locked phone may still read a poster; nothing lasting happens.
    try std.testing.expect(decide(.read_tag, situation).isAllowed());
}

test "a disabled radio refuses everything, even a tag read" {
    var situation = ready;
    situation.radio_enabled = false;
    for (std.enums.values(Interaction)) |interaction| {
        try std.testing.expectEqual(
            Decision{ .deny = .radio_disabled },
            decide(interaction, situation),
        );
    }
}

test "a payment needs an unlocked, recently authenticated person" {
    try std.testing.expect(decide(.payment, ready).isAllowed());

    // Locked: refused for intent before authentication is even considered.
    var locked = ready;
    locked.unlocked = false;
    try std.testing.expectEqual(Decision{ .deny = .intent_required }, decide(.payment, locked));

    // Unlocked but not recently authenticated: proximity and an unlock are still
    // not proof a person meant to spend.
    var stale = ready;
    stale.recently_authenticated = false;
    try std.testing.expectEqual(
        Decision{ .deny = .authentication_required },
        decide(.payment, stale),
    );
}

test "a credential tap needs an unlocked device but not a fresh authentication" {
    // Unlocking a door is meant to be quick.
    var unlocked_stale = ready;
    unlocked_stale.recently_authenticated = false;
    try std.testing.expect(decide(.access_credential, unlocked_stale).isAllowed());

    var locked = ready;
    locked.unlocked = false;
    try std.testing.expectEqual(
        Decision{ .deny = .intent_required },
        decide(.access_credential, locked),
    );
}

test "pairing needs deliberate intent" {
    var locked = ready;
    locked.unlocked = false;
    try std.testing.expectEqual(Decision{ .deny = .intent_required }, decide(.pair_device, locked));
    try std.testing.expect(decide(.pair_device, ready).isAllowed());
}

test "proximity alone never completes a payment" {
    // Swept: for every situation short of unlocked-and-authenticated, a payment
    // is refused.
    for ([_]bool{ true, false }) |unlocked| {
        for ([_]bool{ true, false }) |authenticated| {
            const situation: Situation = .{
                .unlocked = unlocked,
                .recently_authenticated = authenticated,
                .radio_enabled = true,
            };
            const allowed = decide(.payment, situation).isAllowed();
            try std.testing.expectEqual(unlocked and authenticated, allowed);
        }
    }
}

test "the interactions that move value all need deliberate intent" {
    try std.testing.expect(!Interaction.read_tag.needsDeliberateIntent());
    try std.testing.expect(Interaction.access_credential.needsDeliberateIntent());
    try std.testing.expect(Interaction.pair_device.needsDeliberateIntent());
    try std.testing.expect(Interaction.payment.needsDeliberateIntent());
}

test "only payment demands a fresh authentication" {
    for (std.enums.values(Interaction)) |interaction| {
        const needs = interaction.needsRecentAuthentication();
        try std.testing.expectEqual(interaction == .payment, needs);
    }
}
