//! Deciding whether what a person typed may be learned from or predicted into, so
//! the keyboard that gets smarter about their writing never remembers a password or
//! suggests a card number into the open.
//!
//! A good keyboard learns: it adapts to the words a person uses, corrects their
//! typos, and predicts what comes next. That learning is a store of what a person
//! has typed, which is safe for ordinary prose and dangerous for the fields that
//! exist to hold secrets. A password typed into the learning model can resurface as
//! a suggestion in another app; a card number remembered becomes a card number
//! leaked. The dividing line is the field: an ordinary text field feeds learning and
//! prediction, while a field marked as holding a secret — a password, a one-time
//! code, a payment number — is excluded from both, so nothing typed there is stored,
//! corrected against the shared dictionary, or offered as a prediction anywhere else.
//! The keyboard stays helpful where help is wanted and forgets, deliberately, where
//! memory would be a leak.
//!
//! This module types nothing and stores nothing. It decides whether input from a
//! field may be learned from and whether predictions may be shown into it, as pure
//! functions over the field's kind.

const std = @import("std");

/// The kind of field receiving input, which decides whether it is safe to learn
/// from.
pub const FieldKind = enum {
    /// Ordinary text: a message, a note, a search. Safe to learn from and predict
    /// into.
    ordinary,
    /// A password field. Never learned from, never predicted into.
    password,
    /// A one-time code or verification field. A short-lived secret; never retained.
    one_time_code,
    /// A payment field: card number, security code. Never retained.
    payment,

    /// Whether a field of this kind holds a secret that must never be retained.
    fn isSecret(kind: FieldKind) bool {
        return kind != .ordinary;
    }
};

/// Whether input typed into a field may be learned from — added to the personal
/// dictionary, used to adapt correction and prediction.
///
/// Only ordinary fields feed learning. Every secret-bearing field is excluded, so
/// nothing typed into a password, code, or payment field is ever stored where it
/// could resurface elsewhere.
pub fn mayLearnFrom(kind: FieldKind) bool {
    return !kind.isSecret();
}

/// Whether predictions and autocorrect suggestions may be shown into a field.
///
/// Suppressed in secret fields for two reasons: a suggestion drawn from prior input
/// could surface another secret, and predicting into a password field encourages the
/// wrong text. Ordinary fields get the full assistance.
pub fn mayPredictInto(kind: FieldKind) bool {
    return !kind.isSecret();
}

test "ordinary fields feed learning and prediction" {
    try std.testing.expect(mayLearnFrom(.ordinary));
    try std.testing.expect(mayPredictInto(.ordinary));
}

test "a password field is never learned from or predicted into" {
    try std.testing.expect(!mayLearnFrom(.password));
    try std.testing.expect(!mayPredictInto(.password));
}

test "one-time codes and payment fields are never retained" {
    try std.testing.expect(!mayLearnFrom(.one_time_code));
    try std.testing.expect(!mayLearnFrom(.payment));
    try std.testing.expect(!mayPredictInto(.one_time_code));
    try std.testing.expect(!mayPredictInto(.payment));
}

test "only ordinary fields are ever learned from, swept" {
    // The no-secret-retention property: whenever learning is permitted, the field is
    // ordinary.
    for (std.enums.values(FieldKind)) |kind| {
        if (mayLearnFrom(kind)) try std.testing.expectEqual(FieldKind.ordinary, kind);
    }
}

test "learning and prediction are gated together, swept" {
    // A field learned from is exactly a field predicted into: the two never diverge,
    // so a secret field is closed to both at once.
    for (std.enums.values(FieldKind)) |kind| {
        try std.testing.expectEqual(mayLearnFrom(kind), mayPredictInto(kind));
    }
}
