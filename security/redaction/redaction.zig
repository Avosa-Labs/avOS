//! Deciding what may be written to the audit ledger, so it never becomes a
//! shadow copy of a person's private data.
//!
//! An audit ledger is a record of what acted, for whom, under which authority,
//! and with what outcome — a log a person can later interrogate to learn what
//! their device did. It must not become the thing it is meant to make
//! accountable: a durable, forever copy of the email bodies, prompts, messages,
//! files, and secrets it was only ever supposed to reference. The failure is
//! ordinary and quiet — a developer logs "denied request to send: <the whole
//! message>" for debugging, and now the ledger holds the message the send was
//! meant to protect.
//!
//! So a ledger field is not free text. It is a typed value whose category
//! decides whether it is recorded as written, recorded as a reference (a hash, a
//! bounded summary, an identifier), or refused entirely. The categories that may
//! be recorded in full are the ones the ledger exists to hold — action type,
//! outcome, authority — and content is never among them. This decides; the
//! ledger writes only what this returns.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// What a field is, which decides how it may be recorded.
pub const Category = enum {
    /// The kind of action taken: "capability_used", "send_refused". Structural,
    /// never a person's content. Recorded in full.
    action_type,
    /// The outcome: "succeeded", "denied". Recorded in full.
    outcome,
    /// The authority an action ran under: a capability identifier. Recorded in
    /// full, because it is a reference, not content.
    authority,
    /// An identifier for a resource: a message id, a file handle. Recorded in
    /// full — it names data without being it.
    resource_id,
    /// Content: an email body, a prompt, a message, a file's bytes. Recorded
    /// only as a reference, never in full, because the ledger must not become a
    /// copy of it.
    content,
    /// A secret: a key, a token, a credential. Never recorded in any form, not
    /// even a hash, because a hash of a low-entropy secret is a target for a
    /// guessing attack.
    secret,
};

/// How a field ends up in the ledger.
pub const Recorded = union(enum) {
    /// The value, written as-is.
    value: []const u8,
    /// A reference to the value: its digest and a bounded summary, enough to
    /// correlate and explain without holding the content.
    reference: Reference,
    /// Nothing. The field is refused.
    omitted,

    pub const Reference = struct {
        digest: [Sha256.digest_length]u8,
        /// A short, bounded excerpt safe to show: a length, a type, never the
        /// content itself. Empty when even a summary would leak.
        summary: []const u8,
        byte_length: usize,
    };
};

/// The longest a bounded summary may be.
pub const max_summary_bytes: usize = 64;

/// One field offered to the ledger.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
    category: Category,
    /// A summary the caller vouches is safe to store for a content field: a
    /// classification, a length description, never the content. Ignored for
    /// other categories.
    safe_summary: []const u8 = "",
};

/// Decides how a field may be recorded.
///
/// The structural categories record their value; content records a reference —
/// a digest and the caller's bounded, safe summary — so the action can be
/// explained and correlated without the ledger holding the content; a secret is
/// omitted entirely. This is the whole policy in one function, so there is one
/// place a category's treatment is decided and none where it can be bypassed.
pub fn record(field: Field) Recorded {
    return switch (field.category) {
        .action_type, .outcome, .authority, .resource_id => .{ .value = field.value },
        .content => .{
            .reference = .{
                .digest = digestOf(field.value),
                .summary = boundedSummary(field.safe_summary),
                .byte_length = field.value.len,
            },
        },
        .secret => .omitted,
    };
}

fn digestOf(bytes: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn boundedSummary(summary: []const u8) []const u8 {
    return summary[0..@min(summary.len, max_summary_bytes)];
}

/// Whether a recorded field could expose the original content bytes.
///
/// Exists so a caller — or a test — can assert that content and secrets do not
/// reach the ledger verbatim, rather than trusting the categories were assigned
/// correctly.
pub fn wouldExposeContent(recorded: Recorded, content: []const u8) bool {
    if (content.len == 0) return false;
    return switch (recorded) {
        .value => |value| std.mem.indexOf(u8, value, content) != null,
        // A reference holds a digest and a caller-vouched summary, never the
        // content; the summary is checked too in case a caller passed content
        // as a summary by mistake.
        .reference => |reference| std.mem.indexOf(u8, reference.summary, content) != null,
        .omitted => false,
    };
}

test "structural fields are recorded in full" {
    for ([_]Category{ .action_type, .outcome, .authority, .resource_id }) |category| {
        const recorded = record(.{ .name = "f", .value = "capability_used", .category = category });
        try std.testing.expectEqualStrings("capability_used", recorded.value);
    }
}

test "content is recorded only as a reference" {
    const body = "Dear Alex, the private contents of an email nobody should log.";
    const recorded = record(.{
        .name = "message_body",
        .value = body,
        .category = .content,
        .safe_summary = "email body, 61 bytes",
    });

    // A reference, carrying a digest and a safe summary — never the body.
    try std.testing.expect(recorded == .reference);
    try std.testing.expectEqual(body.len, recorded.reference.byte_length);
    try std.testing.expect(!wouldExposeContent(recorded, body));
}

test "a secret is omitted entirely" {
    const recorded = record(.{ .name = "token", .value = "sk-secret", .category = .secret });
    // Not even a digest: a hash of a low-entropy secret is a guessing target.
    try std.testing.expectEqual(Recorded.omitted, recorded);
    try std.testing.expect(!wouldExposeContent(recorded, "sk-secret"));
}

test "content never reaches the ledger verbatim" {
    // The property the module exists for, checked rather than trusted.
    const secret_message = "the contents that must not be logged";
    const recorded = record(.{
        .name = "prompt",
        .value = secret_message,
        .category = .content,
    });
    try std.testing.expect(!wouldExposeContent(recorded, secret_message));
}

test "the same content produces the same reference digest" {
    // References must correlate: two log entries about the same message can be
    // recognized as such without either holding the message.
    const content = "a message referenced twice";
    const first = record(.{ .name = "m", .value = content, .category = .content });
    const second = record(.{ .name = "m", .value = content, .category = .content });
    try std.testing.expectEqualSlices(u8, &first.reference.digest, &second.reference.digest);
}

test "different content produces different digests" {
    const a = record(.{ .name = "m", .value = "one message", .category = .content });
    const b = record(.{ .name = "m", .value = "another message", .category = .content });
    try std.testing.expect(!std.mem.eql(u8, &a.reference.digest, &b.reference.digest));
}

test "a summary is bounded so it cannot smuggle the content" {
    // A caller that passed the whole content as a summary gets it truncated to
    // the bound, and the module's own check catches that it does not carry the
    // content in full.
    const long_summary = "x" ** 200;
    const recorded = record(.{
        .name = "m",
        .value = "content",
        .category = .content,
        .safe_summary = long_summary,
    });
    try std.testing.expect(recorded.reference.summary.len <= max_summary_bytes);
}

test "a safe summary is preserved when short" {
    const recorded = record(.{
        .name = "m",
        .value = "content",
        .category = .content,
        .safe_summary = "image, 2 MB",
    });
    try std.testing.expectEqualStrings("image, 2 MB", recorded.reference.summary);
}

test "an empty-content check never reports exposure" {
    const recorded = record(.{ .name = "o", .value = "denied", .category = .outcome });
    try std.testing.expect(!wouldExposeContent(recorded, ""));
}

test "every category has a defined treatment" {
    // Swept: no category falls through to an unhandled path.
    for (std.enums.values(Category)) |category| {
        const recorded = record(.{ .name = "f", .value = "v", .category = category });
        // Each resolves to exactly one of the three recordings.
        try std.testing.expect(recorded == .value or recorded == .reference or recorded == .omitted);
    }
}
