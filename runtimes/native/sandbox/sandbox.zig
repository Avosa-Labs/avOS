//! The resource boundary a component runs inside.
//!
//! A component reaches nothing it did not declare and was not granted. The
//! declaration is in its package manifest; the grant is a policy decision made
//! at install or launch. Declaring a resource is a request, never an
//! entitlement, so a manifest asking for the filesystem gets nothing until
//! something authorizes it.
//!
//! The default is empty. A component with no grants has no filesystem, no
//! network, no clock, no randomness, and no environment — every capability a
//! runtime would otherwise supply ambiently is absent until it is named.

const std = @import("std");

/// A class of host resource a component may be granted.
pub const ResourceClass = enum {
    filesystem_read,
    filesystem_write,
    network_outbound,
    clock,
    random,
    environment,
    /// Sending a message to another component or service.
    message_send,
};

pub const Denial = enum {
    /// The class was never granted.
    class_not_granted,
    /// The class is granted but not for this path or destination.
    target_not_granted,
    /// The component is not running.
    not_running,
};

pub const Error = error{
    /// The component reached for something it was not granted.
    ResourceDenied,
    /// A declared limit was reached.
    LimitExceeded,
};

/// Longest path or destination accepted. Bounded because it arrives from the
/// component and is compared before anything else happens.
pub const max_target_bytes: usize = 1024;

/// What a component was granted.
///
/// Ownership: the grant borrows every path and destination it was given. They
/// must outlive it, which in practice means they are owned by the package
/// record the grant was derived from.
pub const Grant = struct {
    classes: std.EnumSet(ResourceClass) = .initEmpty(),
    /// Path prefixes readable when `filesystem_read` is granted.
    readable_paths: []const []const u8 = &.{},
    /// Path prefixes writable when `filesystem_write` is granted.
    writable_paths: []const []const u8 = &.{},
    /// Destinations reachable when `network_outbound` is granted.
    destinations: []const []const u8 = &.{},

    /// A component granted nothing. This is the starting point, not a fallback.
    pub const empty: Grant = .{};

    pub fn permits(grant: Grant, class: ResourceClass) bool {
        return grant.classes.contains(class);
    }
};

/// Why an access was refused, alongside the failure returned to the caller.
pub const Refusal = struct {
    class: ResourceClass,
    reason: Denial,
};

/// Mediates every host resource a component reaches for.
///
/// A component never touches a host interface directly: it asks the sandbox,
/// and the sandbox decides. That is what keeps the decision in one reviewable
/// place instead of spread across each host function.
pub const Sandbox = struct {
    grant: Grant,
    /// Set when an access is refused, for the caller to record.
    last_refusal: ?Refusal = null,
    /// Accesses refused so far. A component generating refusals is either
    /// misconfigured or probing; either way the count is worth surfacing.
    refusals: u64 = 0,
    /// Accesses permitted so far.
    grants_used: u64 = 0,

    pub fn init(grant: Grant) Sandbox {
        return .{ .grant = grant };
    }

    fn refuse(sandbox: *Sandbox, class: ResourceClass, reason: Denial) Error {
        sandbox.last_refusal = .{ .class = class, .reason = reason };
        sandbox.refusals += 1;
        return error.ResourceDenied;
    }

    fn permit(sandbox: *Sandbox) void {
        sandbox.grants_used += 1;
    }

    pub fn openForRead(sandbox: *Sandbox, path: []const u8) Error!void {
        if (path.len > max_target_bytes) return error.LimitExceeded;
        if (!sandbox.grant.permits(.filesystem_read)) {
            return sandbox.refuse(.filesystem_read, .class_not_granted);
        }
        if (!coveredByPrefix(sandbox.grant.readable_paths, path)) {
            return sandbox.refuse(.filesystem_read, .target_not_granted);
        }
        sandbox.permit();
    }

    pub fn openForWrite(sandbox: *Sandbox, path: []const u8) Error!void {
        if (path.len > max_target_bytes) return error.LimitExceeded;
        if (!sandbox.grant.permits(.filesystem_write)) {
            return sandbox.refuse(.filesystem_write, .class_not_granted);
        }
        if (!coveredByPrefix(sandbox.grant.writable_paths, path)) {
            return sandbox.refuse(.filesystem_write, .target_not_granted);
        }
        sandbox.permit();
    }

    pub fn connect(sandbox: *Sandbox, destination: []const u8) Error!void {
        if (destination.len > max_target_bytes) return error.LimitExceeded;
        if (!sandbox.grant.permits(.network_outbound)) {
            return sandbox.refuse(.network_outbound, .class_not_granted);
        }
        if (!containsText(sandbox.grant.destinations, destination)) {
            return sandbox.refuse(.network_outbound, .target_not_granted);
        }
        sandbox.permit();
    }

    /// Ambient capabilities a runtime would otherwise supply without being
    /// asked. Each is refused unless granted, so a component cannot read the
    /// clock or draw randomness to fingerprint the host by default.
    pub fn readClock(sandbox: *Sandbox) Error!void {
        if (!sandbox.grant.permits(.clock)) return sandbox.refuse(.clock, .class_not_granted);
        sandbox.permit();
    }

    pub fn drawRandom(sandbox: *Sandbox) Error!void {
        if (!sandbox.grant.permits(.random)) return sandbox.refuse(.random, .class_not_granted);
        sandbox.permit();
    }

    pub fn readEnvironment(sandbox: *Sandbox) Error!void {
        if (!sandbox.grant.permits(.environment)) {
            return sandbox.refuse(.environment, .class_not_granted);
        }
        sandbox.permit();
    }

    pub fn sendMessage(sandbox: *Sandbox) Error!void {
        if (!sandbox.grant.permits(.message_send)) {
            return sandbox.refuse(.message_send, .class_not_granted);
        }
        sandbox.permit();
    }
};

/// Whether `path` sits under one of the granted prefixes.
///
/// A prefix must match at a separator boundary. Without that check a grant over
/// `/documents` would also cover `/documents-private`, which is a different
/// place with a similar name.
fn coveredByPrefix(prefixes: []const []const u8, path: []const u8) bool {
    for (prefixes) |prefix| {
        if (prefix.len == 0) continue;
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        if (path.len == prefix.len) return true;
        const boundary = path[prefix.len];
        const prefix_ends_with_separator = prefix[prefix.len - 1] == '/';
        if (boundary == '/' or prefix_ends_with_separator) return true;
    }
    return false;
}

fn containsText(list: []const []const u8, value: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

test "a component granted nothing reaches nothing" {
    var sandbox: Sandbox = .init(.empty);

    try std.testing.expectError(error.ResourceDenied, sandbox.openForRead("/documents/agenda"));
    try std.testing.expectError(error.ResourceDenied, sandbox.openForWrite("/documents/agenda"));
    try std.testing.expectError(error.ResourceDenied, sandbox.connect("routing.invalid"));
    try std.testing.expectError(error.ResourceDenied, sandbox.readClock());
    try std.testing.expectError(error.ResourceDenied, sandbox.drawRandom());
    try std.testing.expectError(error.ResourceDenied, sandbox.readEnvironment());
    try std.testing.expectError(error.ResourceDenied, sandbox.sendMessage());

    try std.testing.expectEqual(@as(u64, 7), sandbox.refusals);
    try std.testing.expectEqual(@as(u64, 0), sandbox.grants_used);
}

test "a granted class still restricts which target may be reached" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);

    var sandbox: Sandbox = .init(.{
        .classes = classes,
        .readable_paths = &.{"/documents"},
    });

    try sandbox.openForRead("/documents/agenda");
    try std.testing.expectError(error.ResourceDenied, sandbox.openForRead("/secrets/keys"));
    try std.testing.expectEqual(Denial.target_not_granted, sandbox.last_refusal.?.reason);
}

test "a path prefix does not cover a similarly named sibling" {
    // A grant over one directory must not extend to another whose name merely
    // starts the same way.
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);

    var sandbox: Sandbox = .init(.{
        .classes = classes,
        .readable_paths = &.{"/documents"},
    });

    try sandbox.openForRead("/documents");
    try sandbox.openForRead("/documents/agenda");
    try std.testing.expectError(error.ResourceDenied, sandbox.openForRead("/documents-private/keys"));
    try std.testing.expectError(error.ResourceDenied, sandbox.openForRead("/documentsother"));
}

test "read access does not imply write access" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);

    var sandbox: Sandbox = .init(.{
        .classes = classes,
        .readable_paths = &.{"/documents"},
        .writable_paths = &.{"/documents"},
    });

    try sandbox.openForRead("/documents/agenda");
    // The write path is listed but the class was never granted.
    try std.testing.expectError(error.ResourceDenied, sandbox.openForWrite("/documents/agenda"));
    try std.testing.expectEqual(Denial.class_not_granted, sandbox.last_refusal.?.reason);
}

test "network access is limited to named destinations" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.network_outbound);

    var sandbox: Sandbox = .init(.{
        .classes = classes,
        .destinations = &.{"routing.invalid"},
    });

    try sandbox.connect("routing.invalid");
    try std.testing.expectError(error.ResourceDenied, sandbox.connect("elsewhere.invalid"));
    try std.testing.expectEqual(Denial.target_not_granted, sandbox.last_refusal.?.reason);
}

test "an oversized target is refused before it is compared" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);
    var sandbox: Sandbox = .init(.{ .classes = classes, .readable_paths = &.{"/"} });

    const long: [max_target_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.LimitExceeded, sandbox.openForRead(&long));
}

test "an empty prefix grants nothing" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.filesystem_read);
    var sandbox: Sandbox = .init(.{ .classes = classes, .readable_paths = &.{""} });

    try std.testing.expectError(error.ResourceDenied, sandbox.openForRead("/anything"));
}

test "a prefix ending in a separator covers what is beneath it" {
    try std.testing.expect(coveredByPrefix(&.{"/documents/"}, "/documents/agenda"));
    try std.testing.expect(coveredByPrefix(&.{"/documents/"}, "/documents/"));
    try std.testing.expect(!coveredByPrefix(&.{"/documents/"}, "/documents-private/x"));
}

test "permitted and refused accesses are both counted" {
    var classes: std.EnumSet(ResourceClass) = .initEmpty();
    classes.insert(.clock);
    var sandbox: Sandbox = .init(.{ .classes = classes });

    try sandbox.readClock();
    try sandbox.readClock();
    try std.testing.expectError(error.ResourceDenied, sandbox.drawRandom());

    try std.testing.expectEqual(@as(u64, 2), sandbox.grants_used);
    try std.testing.expectEqual(@as(u64, 1), sandbox.refusals);
}
