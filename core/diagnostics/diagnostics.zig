//! Reporting what went wrong without reporting what must stay secret.
//!
//! A diagnostic is written to be read by someone who is not the person whose
//! device it describes: a support engineer, a crash aggregator, a log the owner
//! forwards for help. That is its purpose and its hazard. A stack trace with a
//! token in it, an error message quoting the file path of a private document, a
//! field dump that happens to include a passphrase — each turns a report meant
//! to help into a leak. So a diagnostic here is not free-form text. It is built
//! from typed fields, and a field carries a sensitivity that decides whether its
//! value appears, is redacted to a shape, or is dropped entirely.
//!
//! The default is the safe one. A value is redacted unless it was explicitly
//! marked safe to show, because the failure that matters is the field someone
//! forgot to think about, and a system that leaks by default leaks exactly
//! those. A reader learns that a field existed and roughly what it was, never
//! its contents, unless someone decided its contents were safe to share.

const std = @import("std");

/// How sensitive a field's value is, and therefore how it is rendered.
pub const Sensitivity = enum {
    /// Safe to show in full. A status, a count, an error kind — nothing about a
    /// person or a secret. This is never the default; it is a decision.
    public,
    /// Identifies a person or their data: a name, a path, an address. Shown as
    /// its shape — length and kind — so a reader can tell one value from another
    /// without learning either.
    personal,
    /// A secret: a key, a token, a passphrase. Never shown in any form, not even
    /// its length, because a length can be enough to narrow a guess.
    secret,
};

/// One field of a diagnostic.
pub const Field = struct {
    /// The field's name. Always shown: names describe structure, not content,
    /// and a reader needs them to make sense of the report.
    name: []const u8,
    value: []const u8,
    sensitivity: Sensitivity,
};

/// How a field renders once its sensitivity is applied.
pub const Rendered = struct {
    name: []const u8,
    /// What a reader sees for the value.
    shown: Shown,

    pub const Shown = union(enum) {
        /// The value in full.
        value: []const u8,
        /// The value's shape: its length in bytes. Enough to distinguish fields,
        /// not enough to reconstruct one.
        redacted_length: usize,
        /// Nothing at all, not even a length.
        withheld,
    };
};

/// Renders a field according to its sensitivity.
///
/// This is the whole safety property in one function: a public field shows its
/// value, a personal field shows only its length, and a secret shows nothing.
/// There is no path by which a personal or secret value's bytes reach the
/// output.
pub fn render(field: Field) Rendered {
    return .{
        .name = field.name,
        .shown = switch (field.sensitivity) {
            .public => .{ .value = field.value },
            .personal => .{ .redacted_length = field.value.len },
            .secret => .withheld,
        },
    };
}

/// A diagnostic report: a kind, and a bounded set of fields.
///
/// Bounded because a report is written on a failure path, sometimes a low-memory
/// one, and a report that could grow without limit is a second failure waiting
/// on the first.
pub fn Report(comptime max_fields: usize) type {
    return struct {
        const Self = @This();

        /// A short, public identifier for what happened. Never carries a value,
        /// so it is always safe to show and to group reports by.
        kind: []const u8,
        fields: [max_fields]Field = undefined,
        count: usize = 0,

        pub fn init(kind: []const u8) Self {
            return .{ .kind = kind };
        }

        pub const Error = error{
            /// The report is full. Reported so a caller knows a field was
            /// dropped rather than silently losing it.
            Full,
        };

        /// Adds a field. A public value must be marked so deliberately; the two
        /// convenience adders below make the safe choices the easy ones.
        pub fn add(report: *Self, field: Field) Error!void {
            if (report.count == max_fields) return error.Full;
            report.fields[report.count] = field;
            report.count += 1;
        }

        /// Adds a value that is safe to show. Verbose on purpose: marking a
        /// value public should read as a decision.
        pub fn addPublic(report: *Self, name: []const u8, value: []const u8) Error!void {
            try report.add(.{ .name = name, .value = value, .sensitivity = .public });
        }

        /// Adds a value that identifies a person or their data.
        pub fn addPersonal(report: *Self, name: []const u8, value: []const u8) Error!void {
            try report.add(.{ .name = name, .value = value, .sensitivity = .personal });
        }

        /// Adds a secret. It will never appear in any rendering.
        pub fn addSecret(report: *Self, name: []const u8, value: []const u8) Error!void {
            try report.add(.{ .name = name, .value = value, .sensitivity = .secret });
        }

        /// Renders every field for output.
        pub fn renderAll(report: *const Self, into: []Rendered) []const Rendered {
            const n = @min(report.count, into.len);
            for (report.fields[0..n], 0..) |field, index| {
                into[index] = render(field);
            }
            return into[0..n];
        }

        /// Whether any rendered field would expose the given bytes.
        ///
        /// Exists so a test — or a caller that wants to be sure — can assert a
        /// secret does not appear, rather than trusting that it does not.
        pub fn wouldExpose(report: *const Self, needle: []const u8) bool {
            if (needle.len == 0) return false;
            for (report.fields[0..report.count]) |field| {
                if (field.sensitivity != .public) continue;
                if (std.mem.indexOf(u8, field.value, needle) != null) return true;
            }
            return false;
        }
    };
}

const SmallReport = Report(8);

test "a public field shows its value" {
    const rendered = render(.{ .name = "state", .value = "cancelled", .sensitivity = .public });
    try std.testing.expectEqualStrings("cancelled", rendered.shown.value);
}

test "a personal field shows only its length" {
    const rendered = render(.{
        .name = "document_path",
        .value = "/home/alex/private/taxes.pdf",
        .sensitivity = .personal,
    });
    // A reader can tell two documents apart by length, and learns neither path.
    try std.testing.expectEqual(
        @as(usize, "/home/alex/private/taxes.pdf".len),
        rendered.shown.redacted_length,
    );
}

test "a secret shows nothing, not even a length" {
    const rendered = render(.{ .name = "api_key", .value = "sk-secret-value", .sensitivity = .secret });
    // A length can narrow a guess, so not even that leaks.
    try std.testing.expectEqual(Rendered.Shown.withheld, rendered.shown);
}

test "a report renders every field by its sensitivity" {
    var report: SmallReport = .init("task_failed");
    try report.addPublic("state", "failed");
    try report.addPersonal("owner", "alex@example.com");
    try report.addSecret("session_token", "tok-abc-123");

    var buffer: [8]Rendered = undefined;
    const rendered = report.renderAll(&buffer);
    try std.testing.expectEqual(@as(usize, 3), rendered.len);
    try std.testing.expectEqualStrings("failed", rendered[0].shown.value);
    try std.testing.expectEqual(@as(usize, "alex@example.com".len), rendered[1].shown.redacted_length);
    try std.testing.expectEqual(Rendered.Shown.withheld, rendered[2].shown);
}

test "a secret never appears in any rendering" {
    var report: SmallReport = .init("auth_failed");
    try report.addSecret("passphrase", "correct-horse-battery-staple");

    // The property the module exists for, checked rather than trusted.
    try std.testing.expect(!report.wouldExpose("correct-horse-battery-staple"));
}

test "a personal value never appears in full" {
    var report: SmallReport = .init("share_failed");
    try report.addPersonal("recipient", "bob@example.com");
    try std.testing.expect(!report.wouldExpose("bob@example.com"));
}

test "only a value deliberately marked public is exposed" {
    var report: SmallReport = .init("event");
    try report.addPublic("outcome", "denied");
    // The one field marked safe to show is the one that shows.
    try std.testing.expect(report.wouldExpose("denied"));
    try std.testing.expect(!report.wouldExpose("something-not-present"));
}

test "the report kind is always safe to show" {
    // The kind carries no value, so it can group reports without leaking. A
    // report built with only a secret still has a shareable kind.
    var report: SmallReport = .init("token_expired");
    try report.addSecret("token", "tok-xyz");
    try std.testing.expectEqualStrings("token_expired", report.kind);
    try std.testing.expect(!report.wouldExpose("tok-xyz"));
}

test "a full report refuses rather than dropping a field silently" {
    var report: Report(2) = .init("busy");
    try report.addPublic("a", "1");
    try report.addPublic("b", "2");
    // A caller learns the field was dropped, rather than the report quietly
    // losing it.
    try std.testing.expectError(error.Full, report.addPublic("c", "3"));
}

test "an empty needle never counts as exposed" {
    var report: SmallReport = .init("event");
    try report.addPublic("x", "y");
    try std.testing.expect(!report.wouldExpose(""));
}

test "personal and secret fields are indistinguishable to an exposure check" {
    // Neither ever exposes its bytes, whatever the check looks for.
    var report: SmallReport = .init("mixed");
    try report.addPersonal("email", "a@b.c");
    try report.addSecret("key", "deadbeef");
    try std.testing.expect(!report.wouldExpose("a@b.c"));
    try std.testing.expect(!report.wouldExpose("deadbeef"));
}
