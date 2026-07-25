//! Deciding whether this device can satisfy what an Android application depends on,
//! and naming exactly what it cannot, so an unsupported application is refused with a
//! reason rather than installed and left broken.
//!
//! An Android application declares the platform services it needs — a maps provider,
//! a push-messaging service, a vendor framework. A device that lacks one cannot run
//! the application usefully, and the wrong response is to install it anyway and let it
//! fail at runtime in a way the person cannot diagnose. The right response is to
//! decide compatibility before install and, when the answer is no, to say precisely
//! which dependencies are unsatisfiable — because "this app needs a service this
//! device does not provide" is an answer a person can act on, and a silent failure is
//! not. This module holds the set of dependencies the device can satisfy and checks
//! an application's declared dependencies against it, reporting every gap, not just
//! the first.
//!
//! It decides compatibility; it installs nothing. What the device supports is the
//! host's to declare; this module reasons over that declaration.

const std = @import("std");

/// The dependencies this device can satisfy for Android applications.
pub const Support = struct {
    /// The names of platform services the device provides, e.g. "location",
    /// "push-messaging". An application's dependencies are matched against these.
    provided: []const []const u8,

    fn provides(support: Support, dependency: []const u8) bool {
        for (support.provided) |name| {
            if (std.mem.eql(u8, name, dependency)) return true;
        }
        return false;
    }
};

/// The outcome of a compatibility check: whether the application is supported and,
/// if not, which of its dependencies the device cannot satisfy.
pub const Report = struct {
    /// The dependencies the application declared that the device does not provide.
    /// Empty means fully supported. Borrows the application's dependency slice.
    unsatisfiable: []const []const u8,

    pub fn supported(report: Report) bool {
        return report.unsatisfiable.len == 0;
    }
};

/// Checks an application's declared dependencies against the device's support,
/// collecting every unsatisfiable one into `buffer` and returning a report over it.
///
/// Every gap is reported, not just the first, because a person deciding whether to
/// install wants the whole picture — an application missing three services is a
/// different decision from one missing one. The buffer bounds the report; a device
/// that declares fewer than the application's dependency count is a programming
/// error the caller sizes against, so the buffer is sized to the dependency count.
pub fn check(
    support: Support,
    dependencies: []const []const u8,
    buffer: [][]const u8,
) Report {
    var count: usize = 0;
    for (dependencies) |dependency| {
        if (support.provides(dependency)) continue;
        if (count >= buffer.len) break; // bounded; caller sizes buffer to dependencies.len
        buffer[count] = dependency;
        count += 1;
    }
    return .{ .unsatisfiable = buffer[0..count] };
}

// --- Tests ---

const testing = std.testing;

const device_support: Support = .{ .provided = &.{ "location", "push-messaging", "camera" } };

test "an application needing only provided services is supported" {
    var buffer: [4][]const u8 = undefined;
    const report = check(device_support, &.{ "location", "camera" }, &buffer);
    try testing.expect(report.supported());
}

test "every unsatisfiable dependency is reported, not just the first" {
    var buffer: [4][]const u8 = undefined;
    const report = check(device_support, &.{ "location", "maps", "vendor-drm" }, &buffer);
    try testing.expect(!report.supported());
    try testing.expectEqual(@as(usize, 2), report.unsatisfiable.len);
    try testing.expectEqualStrings("maps", report.unsatisfiable[0]);
    try testing.expectEqualStrings("vendor-drm", report.unsatisfiable[1]);
}

test "an application with no dependencies is trivially supported" {
    var buffer: [1][]const u8 = undefined;
    const report = check(device_support, &.{}, &buffer);
    try testing.expect(report.supported());
}
