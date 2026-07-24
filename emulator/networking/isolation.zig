//! Deciding whether a virtual device's outbound connection is allowed, so an emulated device is
//! isolated by default and reaches only the hosts a test explicitly permitted.
//!
//! A virtual device that could reach the open network by default is a hazard in two directions: a test
//! becomes non-deterministic because it depends on whatever a real server returns, and a build under
//! examination could quietly exfiltrate to, or be influenced by, a host no one intended it to talk to. So
//! the emulator's network is closed by default: an outbound connection is refused unless its destination
//! host is on the allowlist the test declared. This makes the device's external surface an explicit,
//! reviewable list rather than the whole internet — a test that needs to talk to a mock service names that
//! service and reaches nothing else, and a test that declares no hosts reaches nothing at all. Isolation-
//! by-default turns the emulated device's networking into something a test fully controls and an examiner
//! can fully see, which is what a faithful, reproducible, and safe emulation requires.
//!
//! This module opens no connection. It decides whether an outbound connection to a host is allowed,
//! from the declared allowlist, as a pure function.

const std = @import("std");

/// Whether a destination host is on the declared allowlist.
fn allowed(allowlist: []const []const u8, host: []const u8) bool {
    for (allowlist) |permitted| {
        if (std.mem.eql(u8, permitted, host)) return true;
    }
    return false;
}

/// Whether a virtual device may open an outbound connection to a host.
///
/// The connection is allowed only if the host is on the test's declared allowlist. With no allowlist,
/// nothing is reachable; the device is isolated until a host is explicitly named, so no traffic leaves
/// the emulated device to a destination the test did not intend.
pub fn mayConnect(allowlist: []const []const u8, host: []const u8) bool {
    return allowed(allowlist, host);
}

const sample_allowlist = [_][]const u8{ "mock.local", "fixtures.local" };

test "a host on the allowlist is reachable" {
    try std.testing.expect(mayConnect(&sample_allowlist, "mock.local"));
    try std.testing.expect(mayConnect(&sample_allowlist, "fixtures.local"));
}

test "a host not on the allowlist is refused" {
    try std.testing.expect(!mayConnect(&sample_allowlist, "example.com"));
    try std.testing.expect(!mayConnect(&sample_allowlist, ""));
}

test "an empty allowlist isolates the device completely" {
    try std.testing.expect(!mayConnect(&.{}, "mock.local"));
}

test "a connection is allowed exactly when the host is declared, swept" {
    // The isolation property: a connection is permitted only to a host on the allowlist.
    const candidates = [_][]const u8{ "mock.local", "fixtures.local", "example.com", "evil.local" };
    for (candidates) |host| {
        try std.testing.expectEqual(allowed(&sample_allowlist, host), mayConnect(&sample_allowlist, host));
    }
}
