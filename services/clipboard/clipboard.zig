//! Deciding whether a clipboard read may proceed, expiring sensitive content and
//! flagging every access, so a copied password does not linger and a silent paste-
//! grab cannot read what a person copied for somewhere else.
//!
//! The clipboard is a small shared channel every app can read, and that sharing is
//! exactly what makes it dangerous. A person copies a one-time code or a password
//! meaning to paste it once, into one place; if it sits on the clipboard
//! indefinitely, any app opened later can read it, and a background app can poll it
//! without the person ever knowing. So a clipboard is not a passive buffer. Content
//! a person marked or the system recognised as sensitive expires after a short
//! window, so it is gone before an opportunistic reader arrives, and every read is
//! surfaced rather than silent, so a person can see that an app took what was on
//! the clipboard. The convenience of copy-paste is kept; the ambient leak it would
//! otherwise be is not.
//!
//! This module holds no clipboard bytes. It decides whether a read of the current
//! entry may proceed given the entry's sensitivity and age, and reports that the
//! read must be surfaced to the person, as pure functions over the entry and the
//! current time.

const std = @import("std");

/// How sensitive the clipboard's current content is, which sets whether and when
/// it expires.
pub const Sensitivity = enum {
    /// Ordinary text a person copied. Persists until replaced.
    ordinary,
    /// A password, one-time code, or similar secret. Expires after a short window
    /// so it does not linger for a later reader.
    sensitive,
};

/// How long sensitive content stays on the clipboard before it expires, in
/// milliseconds. Short, because its whole purpose is one immediate paste.
pub const sensitive_lifetime_ms: i64 = 60 * 1000;

/// The current clipboard entry.
pub const Entry = struct {
    sensitivity: Sensitivity,
    /// When the content was placed on the clipboard, in milliseconds since the
    /// epoch.
    copied_at_ms: i64,

    /// Whether the entry has expired at `now_ms`. Only sensitive content expires;
    /// ordinary content persists until replaced.
    pub fn expired(entry: Entry, now_ms: i64) bool {
        if (entry.sensitivity != .sensitive) return false;
        return now_ms - entry.copied_at_ms >= sensitive_lifetime_ms;
    }
};

/// Why a clipboard read was refused.
pub const Refusal = enum {
    /// The sensitive content has expired and is no longer available, so a late
    /// reader gets nothing.
    expired,
    /// The clipboard is empty.
    empty,
};

/// The outcome of a read.
pub const ReadDecision = struct {
    outcome: Outcome,
    /// Whether the person must be shown that the clipboard was read. A grant is
    /// always surfaced, so no app can take clipboard content silently; a refusal is
    /// not, because nothing was disclosed.
    must_surface: bool,

    pub const Outcome = union(enum) {
        /// The read may proceed; the content is provided.
        provide,
        /// The read is refused.
        refuse: Refusal,
    };

    pub fn provided(decision: ReadDecision) bool {
        return decision.outcome == .provide;
    }
};

/// Decides whether a read of the current clipboard entry may proceed.
///
/// An empty clipboard provides nothing. Sensitive content past its lifetime is
/// treated as gone — refused, not handed over late, because the window is the whole
/// protection. Otherwise the content is provided, and the read is marked to be
/// surfaced to the person, so an app reading the clipboard is always visible and
/// never a silent grab.
pub fn read(entry: ?Entry, now_ms: i64) ReadDecision {
    const current = entry orelse return .{ .outcome = .{ .refuse = .empty }, .must_surface = false };
    if (current.expired(now_ms)) {
        return .{ .outcome = .{ .refuse = .expired }, .must_surface = false };
    }
    return .{ .outcome = .provide, .must_surface = true };
}

const t0: i64 = 1_000_000;

test "ordinary content is provided and the read is surfaced" {
    const entry: Entry = .{ .sensitivity = .ordinary, .copied_at_ms = t0 };
    const decision = read(entry, t0 + 5 * 60 * 1000);
    try std.testing.expect(decision.provided());
    try std.testing.expect(decision.must_surface);
}

test "ordinary content never expires" {
    const entry: Entry = .{ .sensitivity = .ordinary, .copied_at_ms = t0 };
    try std.testing.expect(!entry.expired(t0 + 1_000_000_000));
    try std.testing.expect(read(entry, t0 + 1_000_000_000).provided());
}

test "sensitive content is provided within its window" {
    const entry: Entry = .{ .sensitivity = .sensitive, .copied_at_ms = t0 };
    const decision = read(entry, t0 + sensitive_lifetime_ms - 1);
    try std.testing.expect(decision.provided());
    try std.testing.expect(decision.must_surface);
}

test "sensitive content expires at its lifetime and is refused" {
    const entry: Entry = .{ .sensitivity = .sensitive, .copied_at_ms = t0 };
    try std.testing.expect(entry.expired(t0 + sensitive_lifetime_ms));
    const decision = read(entry, t0 + sensitive_lifetime_ms);
    try std.testing.expectEqual(ReadDecision.Outcome{ .refuse = .expired }, decision.outcome);
    // A refusal discloses nothing, so it is not surfaced as an access.
    try std.testing.expect(!decision.must_surface);
}

test "an empty clipboard provides nothing" {
    const decision = read(null, t0);
    try std.testing.expectEqual(ReadDecision.Outcome{ .refuse = .empty }, decision.outcome);
    try std.testing.expect(!decision.must_surface);
}

test "every successful read is surfaced, swept" {
    // The no-silent-grab property: whenever a read provides content, it is marked
    // to be shown to the person.
    const sensitivities = [_]Sensitivity{ .ordinary, .sensitive };
    for (sensitivities) |sensitivity| {
        const entry: Entry = .{ .sensitivity = sensitivity, .copied_at_ms = t0 };
        var age: i64 = 0;
        while (age <= sensitive_lifetime_ms * 2) : (age += sensitive_lifetime_ms / 4) {
            const decision = read(entry, t0 + age);
            if (decision.provided()) try std.testing.expect(decision.must_surface);
        }
    }
}

test "sensitive content is never provided after its window, swept" {
    // The linger-protection property: past the lifetime, a sensitive entry is never
    // handed over, whatever the exact time.
    const entry: Entry = .{ .sensitivity = .sensitive, .copied_at_ms = t0 };
    var age: i64 = sensitive_lifetime_ms;
    while (age <= sensitive_lifetime_ms * 5) : (age += 1000) {
        try std.testing.expect(!read(entry, t0 + age).provided());
    }
}
