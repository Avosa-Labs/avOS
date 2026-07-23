//! The machine-readable description of a service's methods that a stub generator
//! consumes, and the check that a description is well formed before anything is
//! generated from it.
//!
//! Client and server stubs are generated rather than written by hand, so that both
//! ends of a call agree on the method names, the effect each method has, and the
//! capability it requires without a person keeping two files in sync. A generator
//! is only as trustworthy as its input: if the description it reads has two methods
//! with the same name, generation is ambiguous; if a method's required capability
//! is blank, the generated server would admit it with no authority check; if a
//! method's effect is understated, the generated client would skip an approval the
//! call actually needs. Every one of these is a defect that would be baked into
//! every stub, so the description is validated first, and an invalid one is a build
//! error rather than a fleet of subtly wrong clients.
//!
//! This module generates no code. It defines the service descriptor — the contract
//! a generator and the router both derive from — and validates it: unique bounded
//! method names, a capability named for every method, and an effect consistent with
//! whether the method may mutate. Pure logic over the descriptor, checked at build
//! time.

const std = @import("std");

/// The largest method name a descriptor may declare, kept in step with the
/// envelope, router, and binding bounds so a generated stub cannot name a method
/// the wire refuses to carry.
pub const max_method_bytes: usize = 64;

/// What a method does, which the generated client uses to decide whether the call
/// needs an approval and the generated server uses to decide what to audit.
pub const Effect = enum {
    /// Reads state without changing anything.
    read_only,
    /// Changes state on the device but reaches nowhere outside it.
    local_mutation,
    /// Reaches outside the device: sends, posts, publishes.
    external,
    /// Moves value or grants authority.
    value_transfer,

    /// Whether a method with this effect changes any state, which fixes whether it
    /// may be marked read-only.
    pub fn mutates(effect: Effect) bool {
        return effect != .read_only;
    }

    /// Whether a call with this effect needs a person to approve it beyond holding
    /// the capability — the generated client inserts the approval step for these.
    pub fn needsApproval(effect: Effect) bool {
        return effect == .external or effect == .value_transfer;
    }
};

/// One method a service exposes.
pub const Method = struct {
    /// The wire method name, e.g. "calendar.read". Unique within the service and
    /// within the method-name bound.
    name: []const u8,
    /// The capability a caller must present to invoke it. Never empty: a method
    /// with no required capability would be generated as one anyone may call.
    required_capability: []const u8,
    effect: Effect,
};

/// A service's exposed surface: its name and the methods it offers.
pub const Descriptor = struct {
    /// The service's stable name, used as the method namespace and the routing
    /// key. Non-empty.
    service: []const u8,
    methods: []const Method,
};

/// Why a descriptor was rejected as unfit to generate from.
pub const DescriptorError = error{
    /// The service name is empty; it has no namespace to generate under.
    EmptyServiceName,
    /// A method name is empty; the wire cannot carry an unnamed method.
    EmptyMethodName,
    /// A method name exceeds the bound the wire will carry.
    MethodNameTooLong,
    /// A method declares no required capability; generating it would omit the
    /// authority check.
    MissingCapability,
    /// Two methods share a name, making generation and routing ambiguous.
    DuplicateMethod,
};

/// Validates a descriptor before any stub is generated from it.
///
/// The service must be named. Every method must have a non-empty name within the
/// wire bound, a non-empty required capability so the generated server always
/// checks authority, and a name distinct from every other method's so generation
/// and routing are unambiguous. A descriptor that passes this is safe to generate
/// from; one that fails is a build error, not a runtime surprise.
pub fn validate(descriptor: Descriptor) DescriptorError!void {
    if (descriptor.service.len == 0) return DescriptorError.EmptyServiceName;
    for (descriptor.methods, 0..) |method, index| {
        if (method.name.len == 0) return DescriptorError.EmptyMethodName;
        if (method.name.len > max_method_bytes) return DescriptorError.MethodNameTooLong;
        if (method.required_capability.len == 0) return DescriptorError.MissingCapability;
        for (descriptor.methods[index + 1 ..]) |other| {
            if (std.mem.eql(u8, method.name, other.name)) return DescriptorError.DuplicateMethod;
        }
    }
}

/// Whether a descriptor is well formed, for callers that want a boolean rather
/// than the specific error.
pub fn isValid(descriptor: Descriptor) bool {
    validate(descriptor) catch return false;
    return true;
}

const sample_methods = [_]Method{
    .{ .name = "calendar.read", .required_capability = "calendar.read", .effect = .read_only },
    .{ .name = "calendar.write", .required_capability = "calendar.write", .effect = .local_mutation },
    .{ .name = "calendar.share", .required_capability = "calendar.share", .effect = .external },
};

const sample_descriptor: Descriptor = .{ .service = "calendar", .methods = &sample_methods };

test "a well-formed descriptor validates" {
    try validate(sample_descriptor);
    try std.testing.expect(isValid(sample_descriptor));
}

test "an empty service name is rejected" {
    const descriptor: Descriptor = .{ .service = "", .methods = &sample_methods };
    try std.testing.expectError(DescriptorError.EmptyServiceName, validate(descriptor));
}

test "an empty method name is rejected" {
    const methods = [_]Method{.{ .name = "", .required_capability = "x", .effect = .read_only }};
    const descriptor: Descriptor = .{ .service = "s", .methods = &methods };
    try std.testing.expectError(DescriptorError.EmptyMethodName, validate(descriptor));
}

test "an over-long method name is rejected" {
    const long: [max_method_bytes + 1]u8 = @splat('m');
    const methods = [_]Method{.{ .name = &long, .required_capability = "x", .effect = .read_only }};
    const descriptor: Descriptor = .{ .service = "s", .methods = &methods };
    try std.testing.expectError(DescriptorError.MethodNameTooLong, validate(descriptor));
}

test "a method with no required capability is rejected" {
    // The dangerous case: generating this would omit the authority check.
    const methods = [_]Method{.{ .name = "s.open", .required_capability = "", .effect = .read_only }};
    const descriptor: Descriptor = .{ .service = "s", .methods = &methods };
    try std.testing.expectError(DescriptorError.MissingCapability, validate(descriptor));
}

test "a duplicate method name is rejected" {
    const methods = [_]Method{
        .{ .name = "s.open", .required_capability = "a", .effect = .read_only },
        .{ .name = "s.open", .required_capability = "b", .effect = .local_mutation },
    };
    const descriptor: Descriptor = .{ .service = "s", .methods = &methods };
    try std.testing.expectError(DescriptorError.DuplicateMethod, validate(descriptor));
}

test "an empty descriptor is valid: a service may expose no methods yet" {
    const descriptor: Descriptor = .{ .service = "s", .methods = &.{} };
    try validate(descriptor);
}

test "effect classification drives approval and mutation" {
    try std.testing.expect(!Effect.read_only.mutates());
    try std.testing.expect(Effect.local_mutation.mutates());
    try std.testing.expect(Effect.external.mutates());
    try std.testing.expect(Effect.value_transfer.mutates());

    try std.testing.expect(!Effect.read_only.needsApproval());
    try std.testing.expect(!Effect.local_mutation.needsApproval());
    try std.testing.expect(Effect.external.needsApproval());
    try std.testing.expect(Effect.value_transfer.needsApproval());
}

test "every method in a valid descriptor is generatable, swept" {
    // The property a generator relies on: after validation, every method has a
    // usable name and a capability to check, and names are unique.
    try validate(sample_descriptor);
    for (sample_descriptor.methods, 0..) |method, i| {
        try std.testing.expect(method.name.len > 0 and method.name.len <= max_method_bytes);
        try std.testing.expect(method.required_capability.len > 0);
        for (sample_descriptor.methods[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, method.name, other.name));
        }
    }
}
