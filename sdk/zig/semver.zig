//! Deciding whether an SDK version is compatible with what an app was built against, so an app
//! keeps running across compatible SDK updates and fails clearly on a breaking one.
//!
//! An app is built against a version of the SDK, and the platform ships new SDK versions over
//! time. Whether an app built against one version runs on another is a compatibility question with
//! a well-known answer: semantic versioning. A change to the major version signals a break —
//! something the app relied on was removed or changed shape — so a runtime SDK with a different
//! major version than the app was built against is incompatible, and running the app against it
//! would fail in confusing ways. A higher minor version is compatible, because minor versions only
//! add; the app uses what it always did and ignores what is new. A lower minor version is not
//! compatible, because the app may use something that version does not yet have. Deciding this by
//! the version numbers, once and predictably, lets an app run across the many compatible SDK
//! updates it will see and fail with a clear reason on the rare breaking one, rather than crashing
//! mysteriously.
//!
//! This module links nothing. It decides whether a runtime SDK version can run an app built
//! against a required version, as a pure function over the version numbers.

const std = @import("std");

/// A semantic version.
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

/// Whether a `runtime` SDK version is compatible with the `required` version an app was built
/// against.
///
/// The major versions must match — a different major is a breaking change the app cannot survive.
/// Given the same major, the runtime's minor version must be at least the required one, because
/// minor versions only add features and the app may use something a lower minor lacks. Patch does
/// not affect compatibility. So an app runs on the version it needs and any compatible later one.
pub fn compatible(runtime: Version, required: Version) bool {
    if (runtime.major != required.major) return false;
    return runtime.minor >= required.minor;
}

fn v(major: u16, minor: u16, patch: u16) Version {
    return .{ .major = major, .minor = minor, .patch = patch };
}

test "the same version is compatible" {
    try std.testing.expect(compatible(v(2, 3, 1), v(2, 3, 1)));
}

test "a higher minor is compatible" {
    try std.testing.expect(compatible(v(2, 5, 0), v(2, 3, 0)));
}

test "a lower minor is not compatible" {
    try std.testing.expect(!compatible(v(2, 2, 0), v(2, 3, 0)));
}

test "a different major is never compatible" {
    try std.testing.expect(!compatible(v(3, 0, 0), v(2, 3, 0)));
    try std.testing.expect(!compatible(v(1, 9, 0), v(2, 0, 0)));
}

test "patch does not affect compatibility" {
    try std.testing.expect(compatible(v(2, 3, 0), v(2, 3, 9)));
    try std.testing.expect(compatible(v(2, 3, 9), v(2, 3, 0)));
}

test "compatibility requires a matching major and a sufficient minor, swept" {
    // The semver property: whenever compatible, the majors match and the runtime minor is at
    // least the required minor.
    const required = v(2, 3, 0);
    var major: u16 = 1;
    while (major <= 3) : (major += 1) {
        var minor: u16 = 0;
        while (minor <= 5) : (minor += 1) {
            const runtime = v(major, minor, 0);
            if (compatible(runtime, required)) {
                try std.testing.expectEqual(required.major, runtime.major);
                try std.testing.expect(runtime.minor >= required.minor);
            }
        }
    }
}
