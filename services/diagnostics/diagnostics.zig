//! Deciding whether a diagnostic report may leave the device and stripping what
//! must never leave it, so a crash report helps fix a bug without carrying a
//! person's data off with it.
//!
//! A diagnostic report is genuinely useful — a crash trace, the state that led to a
//! fault — and it is also a stream of data leaving the device, which makes it a
//! privacy decision before it is a debugging one. Two rules keep it honest. Nothing
//! leaves without the person's consent, and the consent is graded: a person who
//! agreed to send crash reports did not thereby agree to send the contents of their
//! documents. And some things never leave at all, whatever the consent — a key, a
//! token, a password caught in a stack frame — because there is no debugging value
//! that justifies exfiltrating a secret. So the report is filtered before it is
//! sent: secrets are always removed, personal detail is removed unless the person
//! allowed it, and if consent does not cover the report it is withheld entirely.
//!
//! This module sends nothing. It decides whether a report may be sent at the
//! current consent level and which of its fields must be stripped first, as pure
//! functions over the field sensitivities and the consent.

const std = @import("std");

/// How sensitive a field in a diagnostic report is.
pub const Sensitivity = enum {
    /// Technical detail with no personal content: a fault code, a version, a stack
    /// address. Safe to send with any consent to send at all.
    ordinary,
    /// Personal detail: a file path, a message fragment, a contact. Sent only with
    /// full consent.
    personal,
    /// A secret: a key, a token, a credential. Never sent, at any consent level.
    secret,
};

/// What the person has agreed to send.
pub const Consent = enum {
    /// Nothing leaves the device.
    none,
    /// Technical crash data only.
    crashes_only,
    /// Technical and personal detail, for a person who opted into fuller reporting.
    full,
};

/// One field of a report.
pub const Field = struct {
    name: []const u8,
    sensitivity: Sensitivity,
};

/// Whether a field may be included in a report sent at a given consent level.
///
/// A secret is never included. Ordinary technical detail is included whenever any
/// report may be sent. Personal detail is included only under full consent. The
/// rule is monotone in consent: raising consent never removes a field, and secrets
/// are excluded at every level.
pub fn fieldPermitted(field: Field, consent: Consent) bool {
    return switch (field.sensitivity) {
        .secret => false,
        .ordinary => consent != .none,
        .personal => consent == .full,
    };
}

/// The decision about sending a report.
pub const SendDecision = union(enum) {
    /// The report may be sent once the excluded fields are stripped. `stripped` is
    /// how many fields must be removed first.
    send: struct { stripped: usize },
    /// No field may be sent at this consent level; the whole report is withheld.
    withhold,

    pub fn sends(decision: SendDecision) bool {
        return decision == .send;
    }
};

/// Decides whether a report may be sent and how much must be stripped.
///
/// With no consent, nothing leaves — the report is withheld outright. Otherwise the
/// report may be sent, but only after every field not permitted at this consent
/// level is stripped: always the secrets, and the personal detail too unless
/// consent is full. If nothing survives the stripping the report is withheld rather
/// than sent empty. The count of stripped fields is returned so the caller removes
/// exactly them.
pub fn decideSend(fields: []const Field, consent: Consent) SendDecision {
    if (consent == .none) return .withhold;

    var kept: usize = 0;
    var stripped: usize = 0;
    for (fields) |field| {
        if (fieldPermitted(field, consent)) kept += 1 else stripped += 1;
    }
    if (kept == 0) return .withhold;
    return .{ .send = .{ .stripped = stripped } };
}

const report = [_]Field{
    .{ .name = "fault_code", .sensitivity = .ordinary },
    .{ .name = "os_version", .sensitivity = .ordinary },
    .{ .name = "open_document_path", .sensitivity = .personal },
    .{ .name = "session_token", .sensitivity = .secret },
};

test "a secret is never sent, at any consent" {
    for ([_]Consent{ .none, .crashes_only, .full }) |consent| {
        try std.testing.expect(!fieldPermitted(.{ .name = "k", .sensitivity = .secret }, consent));
    }
}

test "ordinary detail sends with crashes-only consent" {
    try std.testing.expect(fieldPermitted(.{ .name = "c", .sensitivity = .ordinary }, .crashes_only));
    try std.testing.expect(!fieldPermitted(.{ .name = "c", .sensitivity = .ordinary }, .none));
}

test "personal detail sends only with full consent" {
    const personal: Field = .{ .name = "p", .sensitivity = .personal };
    try std.testing.expect(!fieldPermitted(personal, .crashes_only));
    try std.testing.expect(fieldPermitted(personal, .full));
}

test "no consent withholds the whole report" {
    try std.testing.expectEqual(SendDecision.withhold, decideSend(&report, .none));
}

test "crashes-only consent strips the personal field and the secret" {
    // Two ordinary fields survive; the path and the token are stripped.
    switch (decideSend(&report, .crashes_only)) {
        .send => |s| try std.testing.expectEqual(@as(usize, 2), s.stripped),
        .withhold => return error.TestUnexpectedResult,
    }
}

test "full consent keeps personal detail but still strips the secret" {
    switch (decideSend(&report, .full)) {
        .send => |s| try std.testing.expectEqual(@as(usize, 1), s.stripped), // only the token
        .withhold => return error.TestUnexpectedResult,
    }
}

test "a report of only secrets is withheld even at full consent" {
    const secrets = [_]Field{
        .{ .name = "key", .sensitivity = .secret },
        .{ .name = "token", .sensitivity = .secret },
    };
    try std.testing.expectEqual(SendDecision.withhold, decideSend(&secrets, .full));
}

test "no secret is ever kept and nothing leaves without consent, swept" {
    // The two invariants: a sent report never includes a secret field, and no field
    // is permitted under no consent.
    for ([_]Consent{ .none, .crashes_only, .full }) |consent| {
        for (report) |field| {
            const permitted = fieldPermitted(field, consent);
            if (field.sensitivity == .secret) try std.testing.expect(!permitted);
            if (consent == .none) try std.testing.expect(!permitted);
        }
    }
}
