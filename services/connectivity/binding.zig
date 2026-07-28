//! Linking a real provider to an app, flipping its connector from pending to live — the moment the
//! architecture stops being a promise and starts operating on real data.
//!
//! An app that reaches an external service starts connector-pending: a labeled simulator answers,
//! with every surrounding authority, approval, and ledger step already real. Linking a real account
//! in Settings is what closes that gap. This module holds the record of which apps have a real
//! provider linked and, given an app's declared pending connector, hands back the connector that is
//! actually live — flipping pending to live through the connector's own bind, with the data-privacy
//! class unchanged, so the same capabilities that operated on the simulator now operate on real data
//! with no code change. That flip is the proof the seam was real all along: nothing about what the
//! app or its agents may do changes, only where the bytes come from. Linking is exactly-once by app —
//! re-linking the same app is idempotent — and an app with no provider linked keeps answering from
//! its pending connector, honestly labeled, rather than pretending to be live.
//!
//! This module reaches no provider and speaks no protocol — the authenticated connector adapters do
//! that. It records the links and resolves an app's live-or-pending connector, over the connector
//! seam, so "prefer a real provider" is enforced in one place.

const std = @import("std");
const connector = @import("connector.zig");

/// A real provider linked to an app: the app it serves and the provider's opaque handle. The
/// provider's identity is metadata here and never enters an app's domain.
const Link = struct { app: []const u8, provider: []const u8 };

/// The record of which apps have a real provider linked. Owned by the connectivity service.
pub const BindingRegistry = struct {
    gpa: std.mem.Allocator,
    links: std.ArrayListUnmanaged(Link) = .empty,

    pub fn init(gpa: std.mem.Allocator) BindingRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(registry: *BindingRegistry) void {
        registry.links.deinit(registry.gpa);
        registry.* = undefined;
    }

    /// Whether a real provider is linked for an app.
    pub fn isLinked(registry: BindingRegistry, app: []const u8) bool {
        for (registry.links.items) |link| {
            if (std.mem.eql(u8, link.app, app)) return true;
        }
        return false;
    }

    /// Links a real provider to an app, exactly-once by app. Re-linking the same app is idempotent —
    /// the person linked it, and linking again does not double it. Returns whether a new link was
    /// recorded (false if the app was already linked).
    pub fn link(registry: *BindingRegistry, app: []const u8, provider: []const u8) !bool {
        if (registry.isLinked(app)) return false;
        try registry.links.append(registry.gpa, .{ .app = app, .provider = provider });
        return true;
    }

    /// Resolves the connector an app actually operates over, given the pending connector it declares.
    /// With a real provider linked, the pending connector is flipped to live (data class unchanged);
    /// with none linked, the app keeps its pending connector, honestly labeled. A connector that is
    /// already live or local-real is returned unchanged whether or not a link exists.
    pub fn resolve(registry: BindingRegistry, app: []const u8, declared: connector.Connector) connector.Connector {
        if (declared.maturity != .connector_pending) return declared;
        if (registry.isLinked(app)) return connector.bindProvider(declared);
        return declared;
    }
};

// --- Tests ---

const testing = std.testing;

const pending_weather = connector.Connector{ .maturity = .connector_pending, .data_class = .shareable };

test "an app with no provider linked keeps answering from its pending connector" {
    var registry = BindingRegistry.init(testing.allocator);
    defer registry.deinit();
    try testing.expect(!registry.isLinked("Weather"));
    const app_connector = registry.resolve("Weather", pending_weather);
    try testing.expectEqual(connector.Maturity.connector_pending, app_connector.maturity);
    // Honestly labeled, not pretending to be live.
    try testing.expectEqual(connector.Reach{ .served = .simulated }, connector.read(app_connector, true));
}

test "linking a real provider flips the app's connector to live, data class unchanged" {
    var registry = BindingRegistry.init(testing.allocator);
    defer registry.deinit();
    try testing.expect(try registry.link("Weather", "some-provider"));
    const app_connector = registry.resolve("Weather", pending_weather);
    try testing.expectEqual(connector.Maturity.live, app_connector.maturity);
    // The privacy class is preserved on the flip — the same guarantee, now on real data.
    try testing.expectEqual(pending_weather.data_class, app_connector.data_class);
    // The same read now returns real data where it returned simulated before.
    try testing.expectEqual(connector.Reach{ .served = .real }, connector.read(app_connector, true));
}

test "linking an app is exactly-once; re-linking is idempotent" {
    var registry = BindingRegistry.init(testing.allocator);
    defer registry.deinit();
    try testing.expect(try registry.link("Calendar", "provider-a"));
    try testing.expect(!try registry.link("Calendar", "provider-b")); // already linked, not doubled
    try testing.expect(registry.isLinked("Calendar"));
    try testing.expectEqual(@as(usize, 1), registry.links.items.len);
}

test "a local-real connector is unaffected by binding" {
    var registry = BindingRegistry.init(testing.allocator);
    defer registry.deinit();
    const local = connector.Connector{ .maturity = .local_real, .data_class = .on_device };
    // Even with a stray link recorded, a local-real app is never flipped or simulated.
    _ = try registry.link("Files", "irrelevant");
    try testing.expectEqual(local, registry.resolve("Files", local));
}
