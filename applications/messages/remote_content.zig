//! Deciding whether a message's remote content is fetched automatically, so opening a message from
//! a stranger does not silently tell them you read it or leak where you are.
//!
//! A message can reference content hosted elsewhere — an image, a preview, a tracking beacon —
//! and the moment the device fetches it, the sender's server learns the message was opened, when,
//! and from what network address. For a message from someone the person already knows and messages
//! with, that round trip is expected and harmless. For a message from an unknown sender it is a
//! disclosure the person never agreed to: a read receipt and a coarse location handed to whoever
//! sent an unsolicited message, which is exactly how spam confirms a live target. So remote content
//! is auto-fetched only for a known sender; from an unknown sender it is held until the person
//! chooses to load it, turning a silent leak into a deliberate act. The message text itself always
//! shows — withholding only the remote round trip keeps the message readable without paying for it
//! with the person's privacy.
//!
//! This module fetches nothing. It decides whether a message's remote content is loaded
//! automatically, from the sender's standing and the person's choice, as a pure function.

const std = @import("std");

/// Where a message's sender stands with the person.
pub const Sender = enum {
    /// Someone in the person's contacts or an ongoing conversation. Remote content auto-loads.
    known,
    /// A sender the person has no relationship with. Remote content held until the person loads it.
    unknown,
};

/// Whether a message's remote content is fetched automatically.
///
/// A known sender's remote content loads on open. An unknown sender's loads only when the person
/// explicitly asks for it, so no read receipt or network round trip reaches a stranger's server
/// before the person decided to engage.
pub fn autoLoad(sender: Sender, person_requested: bool) bool {
    return switch (sender) {
        .known => true,
        .unknown => person_requested,
    };
}

test "a known sender's remote content loads automatically" {
    try std.testing.expect(autoLoad(.known, false));
}

test "an unknown sender's remote content is held by default" {
    try std.testing.expect(!autoLoad(.unknown, false));
}

test "the person may choose to load an unknown sender's content" {
    try std.testing.expect(autoLoad(.unknown, true));
}

test "no unknown sender is ever auto-loaded without the person, swept" {
    // The no-silent-leak property: an unknown sender's content loads only on the person's request.
    for ([_]bool{ false, true }) |requested| {
        if (autoLoad(.unknown, requested)) {
            try std.testing.expect(requested);
        }
    }
}
