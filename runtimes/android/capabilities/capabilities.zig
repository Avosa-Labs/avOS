//! The operations an Android application offers the host, and the registry that
//! holds them, so an agent can invoke a typed application operation without
//! navigating its screens — and only the operations the application actually offers.
//!
//! An Android application is not only a thing a person taps through; it can expose
//! typed operations an agent invokes directly — "add this to the cart", "start a
//! ride to this address" — so the agent reaches the capability without driving the
//! UI. What an application offers is a declaration, and a declaration is not
//! permission: the application says "this operation exists and acts on this resource
//! under this authority", and whether any given caller may invoke it is decided
//! separately, against the capability the caller holds. This module holds the offers
//! — the surface an application publishes — and answers what an application offers and
//! under what authority, so the invocation path has one place to look up an operation
//! and the resource-and-operation it maps to.
//!
//! It registers and resolves offers; it invokes nothing and authorizes nothing. The
//! authority check is the host capability bridge's; this module only says which
//! operation a name refers to and what it acts on.

const std = @import("std");
const core = @import("core");

const capability = core.capability;

/// A typed operation an application offers to the host.
pub const Offer = struct {
    /// The wire name an invoker uses, e.g. "cart.add".
    name: []const u8,
    /// The host resource kind the operation acts on, matched by the capability
    /// bridge against what the caller's capability covers.
    resource_kind: []const u8,
    /// The capability operation invoking it requires.
    operation: capability.Operation,
};

/// An application's published surface: its package and the operations it offers.
pub const Surface = struct {
    package: []const u8,
    offers: []const Offer,

    /// The offer for a name, or null if the application offers no such operation.
    pub fn find(surface: Surface, name: []const u8) ?Offer {
        for (surface.offers) |offer| {
            if (std.mem.eql(u8, offer.name, name)) return offer;
        }
        return null;
    }

    /// Whether every offered name is distinct, so a lookup is unambiguous. A caller
    /// validates a surface once before publishing it.
    pub fn namesAreDistinct(surface: Surface) bool {
        for (surface.offers, 0..) |offer, index| {
            for (surface.offers[index + 1 ..]) |other| {
                if (std.mem.eql(u8, offer.name, other.name)) return false;
            }
        }
        return true;
    }
};

/// The registry of published application surfaces.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    surfaces: std.ArrayListUnmanaged(Surface) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(registry: *Registry) void {
        registry.surfaces.deinit(registry.gpa);
        registry.* = undefined;
    }

    pub const Error = error{
        /// The surface offers two operations under one name.
        DuplicateOffer,
    };

    /// Publishes an application's surface. A surface with a duplicate offered name is
    /// refused, so a later lookup is never ambiguous.
    pub fn publish(registry: *Registry, surface: Surface) !void {
        if (!surface.namesAreDistinct()) return Error.DuplicateOffer;
        try registry.surfaces.append(registry.gpa, surface);
    }

    /// Resolves an operation offered by a package to the offer that describes it, or
    /// null if the package is unknown or offers no such operation.
    pub fn resolve(registry: *Registry, package: []const u8, name: []const u8) ?Offer {
        for (registry.surfaces.items) |surface| {
            if (!std.mem.eql(u8, surface.package, package)) continue;
            return surface.find(name);
        }
        return null;
    }
};

// --- Tests ---

const testing = std.testing;

const cart_offers = [_]Offer{
    .{ .name = "cart.add", .resource_kind = "cart", .operation = .write },
    .{ .name = "cart.view", .resource_kind = "cart", .operation = .read },
};

test "a published surface resolves its offers by name" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    try registry.publish(.{ .package = "com.shop.app", .offers = &cart_offers });
    const offer = registry.resolve("com.shop.app", "cart.add").?;
    try testing.expectEqualStrings("cart", offer.resource_kind);
    try testing.expectEqual(capability.Operation.write, offer.operation);
}

test "an operation the application does not offer resolves to nothing" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    try registry.publish(.{ .package = "com.shop.app", .offers = &cart_offers });
    try testing.expect(registry.resolve("com.shop.app", "cart.delete") == null);
    try testing.expect(registry.resolve("com.other.app", "cart.add") == null);
}

test "a surface with a duplicate offered name is refused" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const clashing = [_]Offer{
        .{ .name = "cart.add", .resource_kind = "cart", .operation = .write },
        .{ .name = "cart.add", .resource_kind = "cart", .operation = .read },
    };
    try testing.expectError(Registry.Error.DuplicateOffer, registry.publish(.{ .package = "com.shop.app", .offers = &clashing }));
}
