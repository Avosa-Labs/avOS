//! Deciding whether a Swift module may be loaded, so a Swift app runs on the runtime only when it is
//! built with the required Swift 6 toolchain in data-race-safe mode, is ABI-stable, and its interface
//! still matches.
//!
//! Swift is a first-class language for writing apps for the platform, and the platform pins it to Swift 6 — the
//! latest major — for one reason above the rest: Swift 6's language mode makes data races a
//! compile-time error rather than a runtime crash, and on a device where an app's concurrency bug can
//! corrupt a person's data, compile-time data-race safety is not a nicety, it is a requirement. So a
//! Swift module is admitted only when it clears three gates. It must be built with a Swift 6 or later
//! toolchain in the data-race-safe language mode, because a module built in a legacy mode carries
//! exactly the concurrency hazards Swift 6 exists to eliminate. It must be ABI-stable
//! (library-evolution), so it survives across compiler and runtime versions rather than being tied to
//! the exact compiler that made it. And its module interface must be one the runtime still provides.
//! A module clearing all three loads; any failure is refused with the reason, turning a class of
//! subtle Swift loading and concurrency failures into a clear, explained refusal at load time.
//!
//! This module loads nothing. It decides whether a Swift module is loadable, from its Swift version,
//! language mode, ABI stability, and interface version, as a pure function.

const std = @import("std");

/// The minimum Swift major version the platform accepts. Swift 6 is required for its data-race-safe
/// language mode; older toolchains carry concurrency hazards the platform does not allow.
pub const required_swift_version: u16 = 6;

/// A Swift module presented for loading.
pub const Module = struct {
    /// The Swift major version of the toolchain the module was built with.
    swift_version: u16,
    /// Whether the module was built in Swift 6's data-race-safe language mode (strict concurrency).
    data_race_safe: bool,
    /// Whether the module was compiled ABI-stable (library-evolution mode).
    abi_stable: bool,
    /// The module interface version the module was built against.
    interface_version: u32,
    /// The oldest interface version the runtime still supports.
    runtime_min_interface: u32,
    /// The current interface version the runtime provides.
    runtime_interface: u32,
};

/// Why a Swift module was refused.
pub const Refusal = enum {
    /// The module was built with a Swift toolchain older than the required version.
    swift_too_old,
    /// The module was not built in the data-race-safe language mode.
    not_data_race_safe,
    /// The module was not built ABI-stable.
    not_abi_stable,
    /// The module's interface is older than the runtime still supports.
    interface_retired,
    /// The module's interface is newer than the runtime provides.
    interface_too_new,
};

/// The load decision.
pub const Decision = union(enum) {
    load,
    refuse: Refusal,

    pub fn loads(decision: Decision) bool {
        return decision == .load;
    }
};

/// Decides whether a Swift module may be loaded.
///
/// The Swift version gate comes first: a module below the required version is refused outright,
/// because everything the platform requires of Swift begins at that version. Then the module must be
/// data-race-safe — the reason the version is pinned — and ABI-stable, and its interface must fall
/// within the range the runtime supports. A module clearing all five conditions loads; any failure is
/// refused with the reason.
pub fn decide(module: Module) Decision {
    if (module.swift_version < required_swift_version) return .{ .refuse = .swift_too_old };
    if (!module.data_race_safe) return .{ .refuse = .not_data_race_safe };
    if (!module.abi_stable) return .{ .refuse = .not_abi_stable };
    if (module.interface_version < module.runtime_min_interface) return .{ .refuse = .interface_retired };
    if (module.interface_version > module.runtime_interface) return .{ .refuse = .interface_too_new };
    return .load;
}

fn makeModule(version: u16, race_safe: bool, abi_stable: bool, iface: u32, min: u32, current: u32) Module {
    return .{
        .swift_version = version,
        .data_race_safe = race_safe,
        .abi_stable = abi_stable,
        .interface_version = iface,
        .runtime_min_interface = min,
        .runtime_interface = current,
    };
}

test "a Swift 6, data-race-safe, ABI-stable, compatible module loads" {
    try std.testing.expect(decide(makeModule(6, true, true, 3, 1, 5)).loads());
    // A later Swift version is fine too.
    try std.testing.expect(decide(makeModule(7, true, true, 3, 1, 5)).loads());
}

test "a module older than Swift 6 is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .swift_too_old }, decide(makeModule(5, true, true, 3, 1, 5)));
}

test "a module not built data-race-safe is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .not_data_race_safe }, decide(makeModule(6, false, true, 3, 1, 5)));
}

test "a non-ABI-stable module is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .not_abi_stable }, decide(makeModule(6, true, false, 3, 1, 5)));
}

test "a retired or too-new interface is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .interface_retired }, decide(makeModule(6, true, true, 1, 2, 5)));
    try std.testing.expectEqual(Decision{ .refuse = .interface_too_new }, decide(makeModule(6, true, true, 6, 1, 5)));
}

test "the Swift version gate precedes the others" {
    // An old Swift version that is also not data-race-safe reports the version, the root cause.
    try std.testing.expectEqual(Decision{ .refuse = .swift_too_old }, decide(makeModule(5, false, false, 3, 1, 5)));
}

test "no module below Swift 6 ever loads, swept" {
    // The Swift-6-required property: whenever a module loads, its Swift version is at least the
    // required one.
    var version: u16 = 4;
    while (version <= 8) : (version += 1) {
        if (decide(makeModule(version, true, true, 3, 1, 5)).loads()) {
            try std.testing.expect(version >= required_swift_version);
        }
    }
}

test "no module that is not data-race-safe ever loads, swept" {
    // The data-race-safety property: a loaded module was always built in the safe language mode.
    for ([_]bool{ false, true }) |safe| {
        if (decide(makeModule(6, safe, true, 3, 1, 5)).loads()) {
            try std.testing.expect(safe);
        }
    }
}
