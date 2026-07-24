//! Validating a project template before it scaffolds a new app, so a developer starts from a
//! template that will actually build rather than one missing its essentials.
//!
//! A template is the starting point the SDK hands a developer for a new app, and its whole value is
//! that the generated project builds and runs on the first try. That only holds if the template
//! itself is complete. It must name a target — phone, tablet, watch — because a project with no
//! target has nothing to build for. It must pin an SDK version that the toolchain actually has, or
//! the first build fails resolving a version that does not exist. And it must declare an entry
//! point, the file the app starts from, or there is nothing to run. A template missing any of these
//! is broken, and scaffolding from it wastes the developer's time on errors that have nothing to do
//! with their code. So the template is validated before it is used, turning a broken starting point
//! into a caught error rather than a confusing first-build failure.
//!
//! This module scaffolds nothing. It validates a template manifest, as a pure function.

const std = @import("std");

/// A project template's manifest.
pub const Template = struct {
    /// The build target, e.g. "phone". Non-empty.
    target: []const u8,
    /// The SDK version the template pins.
    sdk_version: u32,
    /// The entry-point path. Non-empty.
    entry_point: []const u8,
};

/// The SDK versions the toolchain has available. A template pinning a version not in this set
/// cannot resolve.
pub const available_sdk_versions = [_]u32{ 1, 2, 3 };

/// Why a template was rejected.
pub const Invalid = error{
    /// The template names no build target.
    MissingTarget,
    /// The pinned SDK version is not available in the toolchain.
    UnavailableSdkVersion,
    /// The template declares no entry point.
    MissingEntryPoint,
};

fn sdkAvailable(version: u32) bool {
    for (available_sdk_versions) |v| {
        if (v == version) return true;
    }
    return false;
}

/// Validates a template manifest.
///
/// The template must name a target, pin an available SDK version, and declare an entry point. Any
/// missing essential rejects the template, so a developer never scaffolds from a starting point that
/// cannot build.
pub fn validate(template: Template) Invalid!void {
    if (template.target.len == 0) return Invalid.MissingTarget;
    if (!sdkAvailable(template.sdk_version)) return Invalid.UnavailableSdkVersion;
    if (template.entry_point.len == 0) return Invalid.MissingEntryPoint;
}

/// Whether a template is valid.
pub fn isValid(template: Template) bool {
    validate(template) catch return false;
    return true;
}

test "a complete template validates" {
    try validate(.{ .target = "phone", .sdk_version = 2, .entry_point = "src/main.zig" });
}

test "a template with no target is rejected" {
    try std.testing.expectError(Invalid.MissingTarget, validate(.{ .target = "", .sdk_version = 2, .entry_point = "m" }));
}

test "a template pinning an unavailable SDK is rejected" {
    try std.testing.expectError(Invalid.UnavailableSdkVersion, validate(.{ .target = "phone", .sdk_version = 99, .entry_point = "m" }));
}

test "a template with no entry point is rejected" {
    try std.testing.expectError(Invalid.MissingEntryPoint, validate(.{ .target = "phone", .sdk_version = 2, .entry_point = "" }));
}

test "a valid template always has a target, available SDK, and entry point, swept" {
    const targets = [_][]const u8{ "", "phone" };
    const versions = [_]u32{ 2, 99 };
    const entries = [_][]const u8{ "", "main" };
    for (targets) |target| {
        for (versions) |version| {
            for (entries) |entry| {
                const template: Template = .{ .target = target, .sdk_version = version, .entry_point = entry };
                if (isValid(template)) {
                    try std.testing.expect(target.len > 0 and sdkAvailable(version) and entry.len > 0);
                }
            }
        }
    }
}
