//! Deciding which service a message is delivered to, from a closed table, so a
//! method is never misrouted and an unknown one is never guessed at.
//!
//! A message names a method — "calendar.read", "wallet.pay" — and something must
//! turn that name into the service that handles it. That step is a boundary, not a
//! lookup convenience: if the mapping is open, a caller can name a method that was
//! never registered and have it delivered somewhere by a best-effort guess, and if
//! the mapping is ambiguous, the same method can reach two services and the one
//! that answers is a race. Both are how a request ends up handled by code that was
//! never meant to see it. So routing resolves against a closed table with exactly
//! one destination per method: a name that is not in the table is refused, and a
//! name cannot be registered to two services.
//!
//! This module delivers nothing. It answers which service a method resolves to, or
//! that it resolves to none, and it rejects a table that would make a method
//! ambiguous — as pure functions over the table, testable without a running
//! service.

const std = @import("std");

/// A stable identifier for a service that receives messages. Zero is reserved for
/// "no service", so a real destination is always non-zero.
pub const ServiceId = u32;

/// The largest method name the router will resolve. Bounded because the name is
/// read before anything is dispatched and must not itself become a resource; kept
/// in step with the envelope's method bound.
pub const max_method_bytes: usize = 64;

/// One entry in the routing table: a method delivered to a service.
pub const Route = struct {
    method: []const u8,
    service: ServiceId,
};

/// Why a method could not be resolved.
pub const Refusal = enum {
    /// No route for that method. Refused rather than delivered somewhere by guess.
    unknown_method,
    /// The method name is longer than the router will read.
    method_too_long,
};

/// The outcome of resolving a method.
pub const Resolution = union(enum) {
    /// Deliver to this service.
    deliver: ServiceId,
    /// The method does not resolve.
    refuse: Refusal,

    pub fn delivered(resolution: Resolution) bool {
        return resolution == .deliver;
    }
};

/// Why a table was rejected as invalid.
pub const TableError = error{
    /// The same method appears twice, which would make delivery ambiguous.
    DuplicateMethod,
    /// A route's service id is zero, the reserved "no service" value.
    ReservedService,
    /// A route's method name exceeds the bound.
    MethodTooLong,
};

/// A closed set of routes.
pub const Table = struct {
    routes: []const Route,

    /// Checks that a table is well formed before it is used: no method appears
    /// twice, no route points at the reserved zero service, and no method name is
    /// over the bound. A table that fails this is a configuration error, caught
    /// here rather than surfacing as a misroute later.
    pub fn validate(table: Table) TableError!void {
        for (table.routes, 0..) |route, index| {
            if (route.service == 0) return TableError.ReservedService;
            if (route.method.len > max_method_bytes) return TableError.MethodTooLong;
            for (table.routes[index + 1 ..]) |other| {
                if (std.mem.eql(u8, route.method, other.method)) return TableError.DuplicateMethod;
            }
        }
    }

    /// Resolves a method to its service.
    ///
    /// An over-long name is refused before it is compared, so the name cannot be
    /// used to make the router do unbounded work. Otherwise the method must match
    /// a route exactly; a name that matches none is refused rather than delivered
    /// to a nearest guess. Because a valid table has at most one route per method,
    /// the first match is the only match.
    pub fn resolve(table: Table, method: []const u8) Resolution {
        if (method.len > max_method_bytes) return .{ .refuse = .method_too_long };
        for (table.routes) |route| {
            if (std.mem.eql(u8, route.method, method)) return .{ .deliver = route.service };
        }
        return .{ .refuse = .unknown_method };
    }

    /// Whether a method resolves at all.
    pub fn handles(table: Table, method: []const u8) bool {
        return table.resolve(method).delivered();
    }
};

const sample_routes = [_]Route{
    .{ .method = "calendar.read", .service = 10 },
    .{ .method = "calendar.write", .service = 10 },
    .{ .method = "wallet.pay", .service = 20 },
    .{ .method = "messages.send", .service = 30 },
};

const sample_table: Table = .{ .routes = &sample_routes };

test "a registered method resolves to its service" {
    try sample_table.validate();
    try std.testing.expectEqual(Resolution{ .deliver = 10 }, sample_table.resolve("calendar.read"));
    try std.testing.expectEqual(Resolution{ .deliver = 20 }, sample_table.resolve("wallet.pay"));
}

test "two methods may share a service" {
    // A service handles several methods; that is not ambiguity.
    try std.testing.expectEqual(Resolution{ .deliver = 10 }, sample_table.resolve("calendar.read"));
    try std.testing.expectEqual(Resolution{ .deliver = 10 }, sample_table.resolve("calendar.write"));
}

test "an unregistered method is refused, not delivered by guess" {
    try std.testing.expectEqual(
        Resolution{ .refuse = .unknown_method },
        sample_table.resolve("calendar.delete"),
    );
    // A near miss is still unknown; matching is exact.
    try std.testing.expectEqual(
        Resolution{ .refuse = .unknown_method },
        sample_table.resolve("calendar.rea"),
    );
    try std.testing.expectEqual(Resolution{ .refuse = .unknown_method }, sample_table.resolve(""));
}

test "an over-long method name is refused before it is compared" {
    const long: [max_method_bytes + 1]u8 = @splat('a');
    try std.testing.expectEqual(Resolution{ .refuse = .method_too_long }, sample_table.resolve(&long));
}

test "a duplicate method makes the table invalid" {
    const routes = [_]Route{
        .{ .method = "calendar.read", .service = 10 },
        .{ .method = "calendar.read", .service = 11 }, // same method, another service
    };
    try std.testing.expectError(TableError.DuplicateMethod, (Table{ .routes = &routes }).validate());
}

test "a route to the reserved zero service makes the table invalid" {
    const routes = [_]Route{.{ .method = "calendar.read", .service = 0 }};
    try std.testing.expectError(TableError.ReservedService, (Table{ .routes = &routes }).validate());
}

test "an over-long route method makes the table invalid" {
    const long: [max_method_bytes + 1]u8 = @splat('m');
    const routes = [_]Route{.{ .method = &long, .service = 10 }};
    try std.testing.expectError(TableError.MethodTooLong, (Table{ .routes = &routes }).validate());
}

test "an empty table resolves nothing" {
    const empty: Table = .{ .routes = &.{} };
    try empty.validate();
    try std.testing.expectEqual(Resolution{ .refuse = .unknown_method }, empty.resolve("anything"));
    try std.testing.expect(!empty.handles("anything"));
}

test "every registered method resolves and nothing else does, swept" {
    // The closed-table property: membership is exact and total. Every route's
    // method delivers to that route's service, and a manufactured non-member does
    // not deliver.
    try sample_table.validate();
    for (sample_routes) |route| {
        try std.testing.expectEqual(Resolution{ .deliver = route.service }, sample_table.resolve(route.method));
        try std.testing.expect(sample_table.handles(route.method));
    }
    try std.testing.expect(!sample_table.handles("not.a.real.method"));
}
