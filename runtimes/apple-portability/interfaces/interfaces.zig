//! Deciding whether a system interface a ported app depends on is available here, so a
//! dependency the host cannot honour is refused at build time rather than crashing at
//! run time.
//!
//! A ported app does not only call APIs; it depends on system *interfaces* — the
//! services an app assumes are present, like a notification centre, a location provider,
//! a keychain. Whether such a dependency can be honoured is a yes-or-no fact about this
//! host, and getting it wrong is expensive in a specific way: an interface assumed
//! present but absent does not fail politely, it crashes the app the first time it is
//! reached, in the field, in front of a person. So an app declares the interfaces it
//! requires, and the port is admitted only if every required interface has a host
//! provider. An optional interface the host lacks is fine — the app is expected to
//! degrade — but a required one that is missing fails the port up front, where a
//! developer can see it, rather than being discovered by a user's crash report.
//!
//! This module provides no interface. It decides whether an app's required interfaces
//! are all available on the host, as a pure function over the requirements and what the
//! host provides.

const std = @import("std");

/// How much an app depends on an interface.
pub const Requirement = enum {
    /// The app cannot function without it. A missing required interface fails the port.
    required,
    /// The app uses it if present and degrades if not. A missing optional interface is
    /// fine.
    optional,
};

/// An interface an app depends on.
pub const Dependency = struct {
    interface: []const u8,
    requirement: Requirement,
};

/// Why a port was refused.
pub const Refusal = struct {
    /// The name of the first required interface the host does not provide.
    missing: []const u8,
};

/// The admission decision for a port.
pub const Decision = union(enum) {
    /// Every required interface is available; the port is admitted.
    admit,
    /// A required interface is missing.
    refuse: Refusal,

    pub fn admitted(decision: Decision) bool {
        return decision == .admit;
    }
};

/// The interfaces this host provides.
pub const Host = struct {
    provided: []const []const u8,

    fn provides(host: Host, interface: []const u8) bool {
        for (host.provided) |name| {
            if (std.mem.eql(u8, name, interface)) return true;
        }
        return false;
    }

    /// Decides whether an app's dependencies can all be honoured.
    ///
    /// Every required dependency must have a host provider; the first required one that
    /// is missing refuses the port, naming it, so a developer sees the gap at build time
    /// rather than a user seeing a crash. An optional dependency the host lacks does not
    /// block the port — the app is expected to degrade.
    pub fn admit(host: Host, dependencies: []const Dependency) Decision {
        for (dependencies) |dependency| {
            if (dependency.requirement == .required and !host.provides(dependency.interface)) {
                return .{ .refuse = .{ .missing = dependency.interface } };
            }
        }
        return .admit;
    }
};

const sample_host: Host = .{ .provided = &.{ "notifications", "location", "storage" } };

test "a port whose required interfaces are all present is admitted" {
    const deps = [_]Dependency{
        .{ .interface = "notifications", .requirement = .required },
        .{ .interface = "location", .requirement = .required },
    };
    try std.testing.expect(sample_host.admit(&deps).admitted());
}

test "a missing required interface refuses the port and names it" {
    const deps = [_]Dependency{
        .{ .interface = "notifications", .requirement = .required },
        .{ .interface = "biometrics", .requirement = .required }, // not provided
    };
    switch (sample_host.admit(&deps)) {
        .refuse => |refusal| try std.testing.expectEqualStrings("biometrics", refusal.missing),
        .admit => return error.TestUnexpectedResult,
    }
}

test "a missing optional interface does not block the port" {
    const deps = [_]Dependency{
        .{ .interface = "location", .requirement = .required },
        .{ .interface = "haptics", .requirement = .optional }, // not provided, but optional
    };
    try std.testing.expect(sample_host.admit(&deps).admitted());
}

test "an app with no dependencies is admitted" {
    try std.testing.expect(sample_host.admit(&.{}).admitted());
}

test "the first missing required interface is the one named" {
    const deps = [_]Dependency{
        .{ .interface = "camera", .requirement = .required }, // first missing
        .{ .interface = "biometrics", .requirement = .required },
    };
    switch (sample_host.admit(&deps)) {
        .refuse => |refusal| try std.testing.expectEqualStrings("camera", refusal.missing),
        .admit => return error.TestUnexpectedResult,
    }
}

test "a port is admitted only when every required interface is provided, swept" {
    // The no-runtime-surprise property: whenever a port is admitted, the host provides
    // every required interface it declared.
    const dep_sets = [_][]const Dependency{
        &.{.{ .interface = "notifications", .requirement = .required }},
        &.{.{ .interface = "biometrics", .requirement = .required }},
        &.{.{ .interface = "haptics", .requirement = .optional }},
    };
    for (dep_sets) |deps| {
        if (sample_host.admit(deps).admitted()) {
            for (deps) |dependency| {
                if (dependency.requirement == .required) {
                    try std.testing.expect(sample_host.provides(dependency.interface));
                }
            }
        }
    }
}
