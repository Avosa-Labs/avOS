//! Deciding what the wearable form factor may do, so a watch on a wrist can glance and approve without
//! becoming a place to install or manage applications.
//!
//! A wearable is intimate but tiny: always on the person, private enough to trust with a glance at
//! sensitive content, but far too small for the deliberate, detail-heavy work of choosing and
//! installing software. So its capability set is deliberately narrowed from the phone's. It presents,
//! it accepts the light input a small surface allows, and — because it is genuinely on the owner's
//! wrist — it may approve a consequential action, which is exactly the quick, high-value confirmation a
//! wearable is good for. What it does not do is install: application installation is a considered act
//! that belongs on a surface with room to read entitlements and reviews, and a watch is not that
//! surface. This follows the platform rule that capabilities are the device's, not the identity's — the
//! same person who may install from their phone cannot install from their watch, because the watch is
//! not an installation surface. Letting the wearable approve but not install is what makes it a genuine
//! endpoint rather than a shrunk-down phone.
//!
//! This module renders nothing. It decides which interactions the wearable permits, as a pure function.

const std = @import("std");

/// An interaction an endpoint might permit.
pub const Interaction = enum { present, act, approve, install };

/// Whether the wearable form factor permits an interaction.
///
/// It presents, acts, and approves — the quick confirmations a wrist surface is suited to — but does
/// not install, because installation is a considered choice that needs a larger, detail-capable
/// surface. The approve-without-install shape is the wearable's defining reduction from the phone.
pub fn permits(interaction: Interaction) bool {
    return switch (interaction) {
        .present, .act, .approve => true,
        .install => false,
    };
}

/// Whether the wearable may present sensitive content unmasked. It may — it is on the owner's body.
pub fn showsSensitive() bool {
    return true;
}

test "the wearable may present, act, and approve" {
    try std.testing.expect(permits(.present));
    try std.testing.expect(permits(.act));
    try std.testing.expect(permits(.approve));
}

test "the wearable may not install" {
    try std.testing.expect(!permits(.install));
}

test "the wearable never permits installation, swept" {
    // The no-install property: installation is refused whatever else the wearable permits.
    for (std.enums.values(Interaction)) |interaction| {
        if (permits(interaction)) {
            try std.testing.expect(interaction != .install);
        }
    }
}
