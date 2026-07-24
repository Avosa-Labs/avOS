//! Resolving a call from Android app code to a host bridge method, from a closed registry, so an
//! Android app can reach only the host functions the SDK deliberately exposed.
//!
//! An Android app running on the platform reaches host capabilities through a bridge — a fixed set
//! of methods the SDK exposes to the app's Java or Kotlin code. That set is the entire surface
//! between an unreviewed app and the host, so it is closed: an app may call only a registered bridge
//! method, and a call to a name that was not registered is refused rather than dispatched. This
//! matters because an app cannot be allowed to reach a host function by guessing at a name or
//! exploiting a naming convention; if it is not in the registry, it does not exist to the app. Each
//! registered method also carries whether it is consequential, so a bridge call that would send,
//! pay, or grant is surfaced for approval rather than run on the app's say-so, the same rule the
//! other runtime bridges follow. A small closed registry with per-method effect is what keeps the
//! Android bridge a deliberate, auditable surface rather than an open door.
//!
//! This module dispatches nothing. It decides whether a bridge call resolves and whether it needs
//! approval, as a pure function over the registry.

const std = @import("std");

/// A host bridge method exposed to Android app code.
pub const Method = struct {
    name: []const u8,
    /// Whether invoking it is consequential enough to need the host's approval.
    consequential: bool,
};

/// The outcome of a bridge call.
pub const Resolution = union(enum) {
    /// The call resolves and may run directly.
    invoke,
    /// The call resolves but is consequential and must be held for approval.
    require_approval,
    /// No method by that name is registered; the call is refused.
    not_registered,

    pub fn resolves(resolution: Resolution) bool {
        return resolution == .invoke or resolution == .require_approval;
    }
};

/// The closed bridge registry.
pub const Registry = struct {
    methods: []const Method,

    fn find(registry: Registry, name: []const u8) ?Method {
        for (registry.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return method;
        }
        return null;
    }

    /// Resolves a bridge call by name.
    ///
    /// The name must be a registered method, or the call is refused rather than dispatched — an app
    /// cannot reach a host function it was not given. A registered consequential method is returned
    /// as requiring approval, so a send or a payment never runs on the app's say-so; anything else
    /// invokes directly.
    pub fn call(registry: Registry, name: []const u8) Resolution {
        const method = registry.find(name) orelse return .not_registered;
        if (method.consequential) return .require_approval;
        return .invoke;
    }
};

const sample = [_]Method{
    .{ .name = "getDeviceInfo", .consequential = false },
    .{ .name = "readGrantedFile", .consequential = false },
    .{ .name = "sendPayment", .consequential = true },
};

const sample_registry: Registry = .{ .methods = &sample };

test "a registered non-consequential method invokes" {
    try std.testing.expectEqual(Resolution.invoke, sample_registry.call("getDeviceInfo"));
}

test "a registered consequential method requires approval" {
    try std.testing.expectEqual(Resolution.require_approval, sample_registry.call("sendPayment"));
}

test "an unregistered name is refused" {
    try std.testing.expectEqual(Resolution.not_registered, sample_registry.call("deleteEverything"));
    try std.testing.expectEqual(Resolution.not_registered, sample_registry.call(""));
}

test "an empty registry resolves nothing" {
    const empty: Registry = .{ .methods = &.{} };
    try std.testing.expectEqual(Resolution.not_registered, empty.call("getDeviceInfo"));
}

test "no consequential call ever invokes without approval, swept" {
    for (sample) |method| {
        const resolution = sample_registry.call(method.name);
        if (method.consequential) {
            try std.testing.expectEqual(Resolution.require_approval, resolution);
        } else {
            try std.testing.expectEqual(Resolution.invoke, resolution);
        }
    }
}
