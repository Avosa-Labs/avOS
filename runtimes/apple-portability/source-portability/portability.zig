//! Classifying an Apple-platform API as portable, host-mappable, or unsupported, so
//! source brought to this platform is told plainly what will and will not carry over.
//!
//! Bringing an app's source from an Apple platform to this one is worth doing only if it
//! is honest about what transfers. An API a developer uses falls into one of three
//! kinds, and pretending otherwise is how a "ported" app ships broken. Some APIs are
//! portable as-is: standard-library and language constructs that mean the same thing
//! everywhere. Some have a host equivalent this platform provides under a different name,
//! so a call is mechanically rewritten to the host's version — a real mapping, not a
//! guess. And some depend on Apple-specific frameworks or hardware with no counterpart
//! here, and those are reported as unsupported rather than stubbed to a no-op, because a
//! silently stubbed API is a feature that compiles and then does nothing, which is worse
//! than a clear compile-time refusal. Classification up front lets a developer see the
//! real cost of the move before making it.
//!
//! This module rewrites no code. It classifies an API by name against a closed table
//! into portable, host-mapped, or unsupported, as a pure function.

const std = @import("std");

/// How an Apple-platform API carries over to this platform.
pub const Portability = union(enum) {
    /// Portable as-is: no change needed.
    portable,
    /// Has a host equivalent under this name, to which calls are rewritten.
    host_mapped: []const u8,
    /// No counterpart on this platform; reported rather than stubbed.
    unsupported,

    pub fn carries(portability: Portability) bool {
        return portability != .unsupported;
    }
};

const Entry = struct {
    api: []const u8,
    portability: Portability,
};

/// The closed classification table. An API absent from it is unsupported, so the set of
/// what carries over is exactly what has been considered rather than assumed.
const table = [_]Entry{
    // Language and standard-library constructs are portable unchanged.
    .{ .api = "String", .portability = .portable },
    .{ .api = "Array", .portability = .portable },
    .{ .api = "Codable", .portability = .portable },
    // Framework APIs with a host equivalent are rewritten to the host name.
    .{ .api = "URLSession", .portability = .{ .host_mapped = "host.net.HttpClient" } },
    .{ .api = "FileManager", .portability = .{ .host_mapped = "host.storage.Files" } },
    .{ .api = "UserDefaults", .portability = .{ .host_mapped = "host.storage.Preferences" } },
    // Apple-specific frameworks with no counterpart are unsupported.
    .{ .api = "StoreKit", .portability = .unsupported },
    .{ .api = "HealthKit", .portability = .unsupported },
};

/// Classifies an API by name.
///
/// A name in the table returns its recorded classification: portable as-is, host-mapped
/// to a named equivalent, or unsupported. A name not in the table is unsupported —
/// never assumed portable — so an unconsidered API surfaces as a clear refusal rather
/// than a silent failure at run time.
pub fn classify(api: []const u8) Portability {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.api, api)) return entry.portability;
    }
    return .unsupported;
}

test "a standard-library type is portable" {
    try std.testing.expectEqual(Portability.portable, classify("String"));
}

test "a framework with a host equivalent is host-mapped" {
    switch (classify("URLSession")) {
        .host_mapped => |name| try std.testing.expectEqualStrings("host.net.HttpClient", name),
        else => return error.TestUnexpectedResult,
    }
}

test "an Apple-specific framework is unsupported" {
    try std.testing.expectEqual(Portability.unsupported, classify("StoreKit"));
}

test "an unknown API is unsupported, not assumed portable" {
    try std.testing.expectEqual(Portability.unsupported, classify("SomePrivateFramework"));
}

test "a host-mapped API carries; an unsupported one does not" {
    try std.testing.expect(classify("FileManager").carries());
    try std.testing.expect(!classify("HealthKit").carries());
}

test "only classified APIs ever carry over, swept" {
    // The honesty property: any API reported as carrying is in the table with a
    // portable or host-mapped classification.
    const names = [_][]const u8{ "String", "URLSession", "StoreKit", "Unknown" };
    for (names) |name| {
        if (classify(name).carries()) {
            var found = false;
            for (table) |entry| {
                if (std.mem.eql(u8, entry.api, name)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}
