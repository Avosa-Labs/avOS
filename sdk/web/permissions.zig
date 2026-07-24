//! Deciding whether a web app's runtime permission request is within what it declared, so a web app
//! can only ever ask for what its manifest promised.
//!
//! A web app built with the SDK declares in its manifest the permissions it will use, and at runtime
//! it requests them from the person. The manifest is the promise; the runtime request must keep it.
//! A request for a permission the app never declared is refused before the person is even asked,
//! because a manifest that listed three permissions and an app that then asks for a fourth has
//! broken the contract the person could have inspected before installing — the manifest is meant to
//! be the complete, honest statement of what the app can request. A request within the declared set
//! proceeds to the person for their decision as normal. So the SDK gates runtime requests against
//! the declared manifest, which keeps the manifest a reliable summary a person and a reviewer can
//! trust rather than a lower bound the app exceeds at will.
//!
//! This module prompts no one. It decides whether a runtime permission request is within the app's
//! declared set, as a pure function.

const std = @import("std");

/// Whether a requested permission was declared in the app's manifest.
fn declared(manifest: []const []const u8, permission: []const u8) bool {
    for (manifest) |name| {
        if (std.mem.eql(u8, name, permission)) return true;
    }
    return false;
}

/// Whether a runtime permission request may proceed to the person.
///
/// The request is allowed to proceed only if the permission was declared in the manifest; a request
/// for an undeclared permission is refused outright, so the app can never ask for more than its
/// manifest promised. An allowed request still faces the person's decision — this only enforces the
/// manifest as the ceiling of what may be asked.
pub fn mayRequest(manifest: []const []const u8, permission: []const u8) bool {
    return declared(manifest, permission);
}

const sample_manifest = [_][]const u8{ "geolocation", "notifications", "camera" };

test "a declared permission may be requested" {
    try std.testing.expect(mayRequest(&sample_manifest, "camera"));
    try std.testing.expect(mayRequest(&sample_manifest, "geolocation"));
}

test "an undeclared permission cannot be requested" {
    try std.testing.expect(!mayRequest(&sample_manifest, "microphone"));
    try std.testing.expect(!mayRequest(&sample_manifest, ""));
}

test "an empty manifest permits no request" {
    try std.testing.expect(!mayRequest(&.{}, "camera"));
}

test "a request is allowed exactly when declared, swept" {
    // The manifest-ceiling property: a request may proceed only for a permission in the manifest.
    const candidates = [_][]const u8{ "camera", "geolocation", "notifications", "microphone", "usb" };
    for (candidates) |permission| {
        try std.testing.expectEqual(declared(&sample_manifest, permission), mayRequest(&sample_manifest, permission));
    }
}
