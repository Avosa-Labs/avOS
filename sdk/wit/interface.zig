//! Deciding whether a current interface version is backward-compatible, so an interface can grow
//! without breaking the code already built against it.
//!
//! A component interface — the functions a module exposes to others — is a contract, and once
//! published, other code depends on every function in it. Evolving that interface safely means one
//! rule: it may only grow. Adding a function is safe, because existing callers do not use what they
//! do not know about. Removing a function, or changing the shape of one, is a break, because a
//! caller that used it now finds it gone or different and fails. So a current interface version is
//! backward-compatible with an previous one exactly when it contains every function the previous one did —
//! append-only evolution. Checking this at build time turns a whole class of runtime breakages into
//! a compile-time refusal a developer sees before shipping, which is what lets an interface be a
//! stable foundation rather than a moving target.
//!
//! This module generates no bindings. It decides whether a current set of interface functions is
//! backward-compatible with an previous set, as a pure function.

const std = @import("std");

/// Whether an previous set of function names is a subset of a current set — every previous function still present.
fn preserves(previous: []const []const u8, current: []const []const u8) bool {
    for (previous) |name| {
        var found = false;
        for (current) |candidate| {
            if (std.mem.eql(u8, candidate, name)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// Whether a current interface is backward-compatible with an previous one.
///
/// It is compatible exactly when every function the previous interface exposed is still present in the
/// current one. Adding functions preserves compatibility; removing or renaming any breaks it, because a
/// caller depending on the removed function would fail. This is the append-only rule that lets an
/// interface evolve without breaking its consumers.
pub fn backwardCompatible(previous: []const []const u8, current: []const []const u8) bool {
    return preserves(previous, current);
}

test "adding a function preserves compatibility" {
    const previous = [_][]const u8{ "read", "write" };
    const current = [_][]const u8{ "read", "write", "flush" };
    try std.testing.expect(backwardCompatible(&previous, &current));
}

test "an identical interface is compatible" {
    const iface = [_][]const u8{ "read", "write" };
    try std.testing.expect(backwardCompatible(&iface, &iface));
}

test "removing a function breaks compatibility" {
    const previous = [_][]const u8{ "read", "write" };
    const current = [_][]const u8{"read"};
    try std.testing.expect(!backwardCompatible(&previous, &current));
}

test "renaming a function breaks compatibility" {
    const previous = [_][]const u8{"read"};
    const current = [_][]const u8{"read_bytes"};
    try std.testing.expect(!backwardCompatible(&previous, &current));
}

test "an empty previous interface is always preserved" {
    const current = [_][]const u8{"anything"};
    try std.testing.expect(backwardCompatible(&.{}, &current));
}

test "compatibility holds exactly when every previous function survives, swept" {
    const previous = [_][]const u8{ "a", "b", "c" };
    const news = [_][]const []const u8{
        &.{ "a", "b", "c" },
        &.{ "a", "b", "c", "d" },
        &.{ "a", "b" },
        &.{ "a", "b", "x" },
    };
    for (news) |current| {
        try std.testing.expectEqual(preserves(&previous, current), backwardCompatible(&previous, current));
    }
}
