//! The connector seam: how an app's domain reaches the world through a typed, provider-
//! neutral interface, honest about whether a real provider is wired behind it.
//!
//! An agent does real work only if the domain it acts on is real, and a domain reaches
//! the world through a connector. The connector is platform-owned and neutral; the
//! provider behind it is an adapter, and the provider's name is metadata, never part of
//! the domain. What this module fixes is honesty about maturity. A connector is in one of
//! three states, and the UI and the ledger always reflect which: live, a real provider is
//! wired and the work is fully real; local-real, the domain is genuinely local and needs no
//! provider, so nothing is ever simulated; or connector-pending, no provider is wired yet
//! and a labeled simulator answers, with every surrounding authority, approval, and ledger
//! step still real. The simulation is confined to the far side of this one interface, never
//! the agent or the authority. And the decisive property: binding a real account flips a
//! pending connector to live, and the same capabilities then operate on real data with no
//! change to what is permitted — proof the architecture was real all along. A live provider
//! going offline degrades to a typed unavailable, never a hang.
//!
//! This module moves no bytes and calls no provider. It decides a connector's honest state,
//! what a read through it yields, and the privacy the data carries, as pure functions.

const std = @import("std");

/// A connector's maturity — whether a real provider is wired behind the seam. Always
/// surfaced honestly.
pub const Maturity = enum {
    /// A real external provider is wired. Fully real work.
    live,
    /// The domain is genuinely local; no external provider is needed and none is ever
    /// simulated.
    local_real,
    /// No real provider is wired yet; a labeled simulator answers, everything around it
    /// real.
    connector_pending,
};

/// The privacy classification of the data a connector handles — whether it may leave the
/// device. The model router honors this: data classified on-device never routes to a
/// remote model.
pub const DataClass = enum {
    /// This data class never leaves the device.
    on_device_only,
    /// This data class may leave the device with the appropriate authority.
    shareable,
};

/// Where the data a read returned actually came from — always honest, so the UI and
/// ledger can label it.
pub const Source = enum { real, local, simulated };

/// A connector: its maturity and the privacy class of the data it carries. The provider
/// behind it never appears here.
pub const Connector = struct {
    maturity: Maturity,
    data_class: DataClass,
};

/// What a read through a connector yields.
pub const Reach = union(enum) {
    /// Data came back, from this source. A live provider returns real; a local domain
    /// returns local; a pending connector returns simulated, labeled.
    served: Source,
    /// A live provider is offline. A typed unavailable the caller must handle — never a
    /// hang, never a silent stale answer.
    unavailable,

    pub fn ok(reach: Reach) bool {
        return reach == .served;
    }
};

/// The honest label a connector's maturity shows, so a person always knows whether what
/// they see is real or simulated.
pub fn label(maturity: Maturity) []const u8 {
    return switch (maturity) {
        .live => "Live",
        .local_real => "On device",
        .connector_pending => "Simulated \u{00B7} not yet wired",
    };
}

/// Whether a connector's data may leave the device — what the model router consults.
pub fn mayEgress(data_class: DataClass) bool {
    return data_class == .shareable;
}

/// Reads through a connector, given whether a live provider is currently reachable. A
/// local-real connector always serves locally; a pending one serves from the labeled
/// simulator; a live one serves real data when reachable and reports unavailable when not.
/// The source is always honest.
pub fn read(connector: Connector, provider_reachable: bool) Reach {
    return switch (connector.maturity) {
        .local_real => .{ .served = .local },
        .connector_pending => .{ .served = .simulated },
        .live => if (provider_reachable) .{ .served = .real } else .unavailable,
    };
}

/// Binds a real provider to a connector-pending connector, flipping it to live. The data
/// class is unchanged, and — the property that matters — the operations the connector
/// permits do not change, so the same capabilities that operated on the simulator now
/// operate on real data with no code change. A connector already live or local-real is
/// returned unchanged.
pub fn bindProvider(connector: Connector) Connector {
    if (connector.maturity != .connector_pending) return connector;
    return .{ .maturity = .live, .data_class = connector.data_class };
}

// --- Tests ---

const testing = std.testing;

test "a connector's maturity is labeled honestly" {
    try testing.expectEqualStrings("Live", label(.live));
    try testing.expectEqualStrings("On device", label(.local_real));
    // The pending state never pretends to be real.
    try testing.expect(std.mem.indexOf(u8, label(.connector_pending), "Simulated") != null);
}

test "a read is honest about where its data came from" {
    try testing.expectEqual(Reach{ .served = .local }, read(.{ .maturity = .local_real, .data_class = .on_device_only }, false));
    try testing.expectEqual(Reach{ .served = .simulated }, read(.{ .maturity = .connector_pending, .data_class = .shareable }, false));
    try testing.expectEqual(Reach{ .served = .real }, read(.{ .maturity = .live, .data_class = .shareable }, true));
}

test "a live provider offline degrades to a typed unavailable, never a stale answer" {
    const offline = read(.{ .maturity = .live, .data_class = .shareable }, false);
    try testing.expectEqual(Reach.unavailable, offline);
    try testing.expect(!offline.ok());
}

test "on-device data never egresses; shareable may" {
    try testing.expect(!mayEgress(.on_device_only));
    try testing.expect(mayEgress(.shareable));
}

test "binding a real account flips pending to live, preserving the data class" {
    const pending = Connector{ .maturity = .connector_pending, .data_class = .on_device_only };
    const bound = bindProvider(pending);
    try testing.expectEqual(Maturity.live, bound.maturity);
    // The privacy class does not change on the flip — the same guarantee, now on real data.
    try testing.expectEqual(pending.data_class, bound.data_class);
    // The same read now returns real data where it returned simulated before.
    try testing.expectEqual(Reach{ .served = .real }, read(bound, true));
    try testing.expectEqual(Reach{ .served = .simulated }, read(pending, true));
    // Binding an already-live or local connector changes nothing.
    const live = Connector{ .maturity = .live, .data_class = .shareable };
    try testing.expectEqual(live, bindProvider(live));
}

test "local-real is never simulated and never unavailable, swept over reachability" {
    // A local domain answers from itself regardless of any provider's reachability.
    for ([_]bool{ false, true }) |reachable| {
        const reach = read(.{ .maturity = .local_real, .data_class = .on_device_only }, reachable);
        try testing.expectEqual(Reach{ .served = .local }, reach);
    }
}
