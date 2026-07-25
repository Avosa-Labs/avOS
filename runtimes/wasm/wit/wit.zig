//! The typed world a WebAssembly component may import from the host, and the check
//! that a component's declared imports match it, so a component binds only functions
//! the host actually offers, with the types the host expects.
//!
//! A component declares what it imports — functions it expects the host to supply.
//! The host does not honour those declarations blindly: a component that imports a
//! function the host does not offer, or offers with a different signature, must fail
//! to bind rather than link against a mismatched or absent host function and trap or
//! misbehave once running. The WIT world is the contract that makes this decidable —
//! the set of host functions on offer, each with its parameter and result types — and
//! this module models it and checks a component's imports against it. An import the
//! world does not name is refused; an import whose signature disagrees is refused;
//! only an import the world offers, with a matching signature, resolves. This is the
//! shape check that runs before the capability bridge decides whether the component
//! may actually call the function it bound.
//!
//! This module resolves no call and offers no function; it defines the world and
//! decides whether a component's imports fit it, as pure data.

const std = @import("std");

/// The value types a host function's parameters and results may take. The core
/// WebAssembly numeric types, which every host function signature is built from.
pub const ValueType = enum { i32, i64, f32, f64 };

/// A host function's signature: the types it takes and the type it returns.
pub const Signature = struct {
    params: []const ValueType,
    /// The single result type, or null for a function that returns nothing.
    result: ?ValueType,

    pub fn matches(signature: Signature, other: Signature) bool {
        if (signature.params.len != other.params.len) return false;
        for (signature.params, other.params) |a, b| {
            if (a != b) return false;
        }
        return signature.result == other.result;
    }
};

/// One host function the world offers: its name and its signature.
pub const HostFunction = struct {
    name: []const u8,
    signature: Signature,
};

/// A function a component declares it imports.
pub const Import = struct {
    name: []const u8,
    signature: Signature,
};

/// The set of host functions on offer to a component.
pub const World = struct {
    functions: []const HostFunction,

    fn find(world: World, name: []const u8) ?HostFunction {
        for (world.functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }
};

/// Why an import did not resolve against the world.
pub const Mismatch = enum {
    /// The world offers no function by that name.
    not_offered,
    /// The world offers the name but with a different signature.
    signature_mismatch,
};

/// The result of binding one import against the world.
pub const Binding = union(enum) {
    /// The import resolves to this host function.
    bound: HostFunction,
    /// The import does not fit the world.
    unbound: Mismatch,

    pub fn isBound(binding: Binding) bool {
        return binding == .bound;
    }
};

/// Binds one import against the world: it must name a function the world offers,
/// and its signature must match. Anything else is a mismatch the caller refuses.
pub fn bind(world: World, import: Import) Binding {
    const offered = world.find(import.name) orelse return .{ .unbound = .not_offered };
    if (!offered.signature.matches(import.signature)) return .{ .unbound = .signature_mismatch };
    return .{ .bound = offered };
}

/// Why a component's whole import set was rejected.
pub const LinkError = error{
    /// An import names no function the world offers.
    ImportNotOffered,
    /// An import's signature disagrees with the world's.
    ImportSignatureMismatch,
};

/// Checks that every import a component declares fits the world. A component links
/// only if all of its imports resolve; a single mismatch fails the whole link,
/// because a component that binds some of what it needs and traps on the rest is not
/// a component the host should run.
pub fn link(world: World, imports: []const Import) LinkError!void {
    for (imports) |import| {
        switch (bind(world, import)) {
            .bound => {},
            .unbound => |mismatch| return switch (mismatch) {
                .not_offered => error.ImportNotOffered,
                .signature_mismatch => error.ImportSignatureMismatch,
            },
        }
    }
}

// --- Tests ---

const testing = std.testing;

const read_sig: Signature = .{ .params = &.{ .i32, .i32 }, .result = .i64 };
const write_sig: Signature = .{ .params = &.{.i32}, .result = null };

const sample_world: World = .{ .functions = &.{
    .{ .name = "host.read", .signature = read_sig },
    .{ .name = "host.write", .signature = write_sig },
} };

test "an import the world offers with a matching signature binds" {
    const binding = bind(sample_world, .{ .name = "host.read", .signature = read_sig });
    try testing.expect(binding.isBound());
}

test "an import the world does not offer is unbound" {
    const binding = bind(sample_world, .{ .name = "host.delete", .signature = write_sig });
    try testing.expectEqual(Mismatch.not_offered, binding.unbound);
}

test "an import whose signature disagrees is unbound" {
    // Right name, wrong signature: read returns i64, not i32.
    const wrong: Signature = .{ .params = &.{ .i32, .i32 }, .result = .i32 };
    const binding = bind(sample_world, .{ .name = "host.read", .signature = wrong });
    try testing.expectEqual(Mismatch.signature_mismatch, binding.unbound);
}

test "a component links only if every import fits the world" {
    try link(sample_world, &.{
        .{ .name = "host.read", .signature = read_sig },
        .{ .name = "host.write", .signature = write_sig },
    });

    // Adding one unoffered import fails the whole link.
    try testing.expectError(error.ImportNotOffered, link(sample_world, &.{
        .{ .name = "host.read", .signature = read_sig },
        .{ .name = "host.spawn", .signature = write_sig },
    }));
}

test "a component that imports nothing links against any world" {
    try link(sample_world, &.{});
}

test "a signature match is exact in arity, order, and result" {
    const a: Signature = .{ .params = &.{ .i32, .f64 }, .result = .i32 };
    const reordered: Signature = .{ .params = &.{ .f64, .i32 }, .result = .i32 };
    const shorter: Signature = .{ .params = &.{.i32}, .result = .i32 };
    try testing.expect(a.matches(a));
    try testing.expect(!a.matches(reordered));
    try testing.expect(!a.matches(shorter));
}
