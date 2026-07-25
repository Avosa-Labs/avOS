//! The receive pipeline: authenticate, decode, capability-bind, then route.
//!
//! The other modules each decide one thing correctly; this composes them into the
//! single path every inbound message takes, in the order that makes each stage
//! safe. A message is delivered only if it verifies against a trusted key, is not
//! a replay, presents a capability that authorizes exactly the method it invokes,
//! and names a method some service serves. A failure at any stage becomes a typed
//! fault the peer can act on — never a silent drop, and never a delivery on
//! authority the sender did not prove.
//!
//! The pipeline invents no authority. It asks a resolver to turn the capability
//! identifier the envelope carries into the grant state the binding check needs;
//! a capability the resolver does not know grants nothing.

const std = @import("std");
const envelope_schema = @import("../schema/envelope.zig");
const authenticator = @import("../authentication/authenticator.zig");
const capability_binding = @import("../capability-binding/capability_binding.zig");
const routing = @import("../routing/routing.zig");

pub const FaultCode = envelope_schema.FaultCode;

/// Resolves a capability identifier the envelope presents to the current grant
/// state behind it. Returning null means the capability is unknown, which the
/// pipeline treats as unauthorized rather than trusting the identifier alone.
pub const Resolver = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, capability: u128) ?capability_binding.Grant,

    fn resolve(resolver: Resolver, capability: u128) ?capability_binding.Grant {
        return resolver.lookup(resolver.context, capability);
    }
};

/// What the pipeline decided for a message.
pub const Outcome = union(enum) {
    /// Deliver the decoded envelope to a service.
    deliver: struct { service: routing.ServiceId, envelope: envelope_schema.Envelope },
    /// Refuse with a typed fault the peer receives.
    fault: FaultCode,

    pub fn delivered(outcome: Outcome) bool {
        return outcome == .deliver;
    }
};

/// Runs one signed message through the whole receive path.
pub fn receive(
    verifier: *authenticator.Verifier,
    message: authenticator.SignedMessage,
    resolver: Resolver,
    table: routing.Table,
    now_ns: u64,
) Outcome {
    // Authenticate and decode. A bad signature, an unknown sender, a malformed
    // body, or a replay stops here as a fault, before any authority is consulted.
    const decoded = verifier.accept(message) catch |err| return .{ .fault = faultForAccept(err) };

    // Turn the presented capability into its current grant state. The resolver is
    // the only source of authority; an unknown capability authorizes nothing.
    const grant = resolver.resolve(decoded.capability) orelse return .{ .fault = .unauthorized };

    // Bind: the capability must be this principal's, unrevoked, unexpired, within
    // its task and use limits, and cover exactly this method. The generation the
    // wire trusts is the one the resolver reports, so the wire-side check turns on
    // the grant's own revoked/expired/scope state.
    switch (capability_binding.check(grant, .{
        .principal = decoded.principal,
        .method = decoded.method,
        .generation = grant.generation,
        .task = decoded.task,
        .now_ns = now_ns,
    })) {
        .authorize => {},
        .refuse => |refusal| return .{ .fault = faultForRefusal(refusal) },
    }

    // Route: only now, with authority proven, is the method resolved to a service.
    switch (table.resolve(decoded.method)) {
        .deliver => |service| return .{ .deliver = .{ .service = service, .envelope = decoded } },
        .refuse => return .{ .fault = .unavailable },
    }
}

fn faultForAccept(err: anytype) FaultCode {
    return switch (err) {
        error.UnknownSender, error.IntegrityFailure => .integrity_failure,
        error.ReplayDetected => .conflict,
        error.OutsideFreshnessWindow => .deadline_exceeded,
        error.Malformed => .invalid_input,
        error.OutOfMemory => .internal_fault,
        else => .invalid_input,
    };
}

fn faultForRefusal(refusal: capability_binding.Refusal) FaultCode {
    return switch (refusal) {
        .principal_mismatch, .out_of_scope, .method_too_long => .unauthorized,
        .stale_generation, .revoked => .capability_revoked,
        .expired => .capability_expired,
        .task_binding_violated => .constraint_violation,
        .invocations_exhausted => .budget_exhausted,
    };
}

// --- Tests ---

const Ed25519 = std.crypto.sign.Ed25519;
const testing = std.testing;

const holder: u128 = 0xAA;
const capability_id: u128 = 0x55;

const GrantBox = struct {
    grant: ?capability_binding.Grant,

    fn lookup(context: *anyopaque, capability: u128) ?capability_binding.Grant {
        const box: *GrantBox = @ptrCast(@alignCast(context));
        if (capability != capability_id) return null;
        return box.grant;
    }

    fn resolver(box: *GrantBox) Resolver {
        return .{ .context = box, .lookup = lookup };
    }
};

const routes = [_]routing.Route{
    .{ .method = "calendar.read", .service = 7 },
};

fn signerFor(seed: u8) authenticator.SigningIdentity {
    const kp = Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch unreachable;
    return .{ .service = holder, .key_pair = kp };
}

fn buildVerifier(gpa: std.mem.Allocator, signer: authenticator.SigningIdentity) authenticator.Verifier {
    var verifier: authenticator.Verifier = .init(gpa);
    verifier.trust(holder, signer.key_pair.public_key.toBytes()) catch unreachable;
    return verifier;
}

fn envelopeBytes(gpa: std.mem.Allocator) ![]u8 {
    const message: envelope_schema.Envelope = .{
        .version = .{ .major = 1, .minor = 0 },
        .kind = .request,
        .correlation = 1,
        .idempotency_key = 99,
        .principal = holder,
        .task = 0,
        .capability = capability_id,
        .deadline_nanoseconds = 0,
        .method = "calendar.read",
        .fault = null,
        .payload = "",
    };
    const buffer = try gpa.alloc(u8, message.encodedSize());
    errdefer gpa.free(buffer);
    _ = try envelope_schema.encode(message, buffer);
    return buffer;
}

test "a signed, authorized, routable message is delivered" {
    const gpa = testing.allocator;
    const signer = signerFor(1);
    var verifier = buildVerifier(gpa, signer);
    defer verifier.deinit();

    const body = try envelopeBytes(gpa);
    defer gpa.free(body);
    const signed = try authenticator.sign(signer, body);

    var box: GrantBox = .{ .grant = .{
        .bound_principal = holder,
        .scopes = &.{.{ .pattern = "calendar.", .prefix = true }},
    } };

    const outcome = receive(&verifier, signed, box.resolver(), .{ .routes = &routes }, 0);
    try testing.expect(outcome.delivered());
    try testing.expectEqual(@as(routing.ServiceId, 7), outcome.deliver.service);
}

test "a message presenting an unknown capability is unauthorized" {
    const gpa = testing.allocator;
    const signer = signerFor(1);
    var verifier = buildVerifier(gpa, signer);
    defer verifier.deinit();

    const body = try envelopeBytes(gpa);
    defer gpa.free(body);
    const signed = try authenticator.sign(signer, body);

    var box: GrantBox = .{ .grant = null }; // resolver knows no capability
    const outcome = receive(&verifier, signed, box.resolver(), .{ .routes = &routes }, 0);
    try testing.expectEqual(FaultCode.unauthorized, outcome.fault);
}

test "a capability that does not cover the method is refused before routing" {
    const gpa = testing.allocator;
    const signer = signerFor(1);
    var verifier = buildVerifier(gpa, signer);
    defer verifier.deinit();

    const body = try envelopeBytes(gpa);
    defer gpa.free(body);
    const signed = try authenticator.sign(signer, body);

    var box: GrantBox = .{ .grant = .{
        .bound_principal = holder,
        .scopes = &.{.{ .pattern = "contacts.", .prefix = true }},
    } };
    const outcome = receive(&verifier, signed, box.resolver(), .{ .routes = &routes }, 0);
    try testing.expectEqual(FaultCode.unauthorized, outcome.fault);
}

test "a message signed by an untrusted key is an integrity fault" {
    const gpa = testing.allocator;
    const trusted = signerFor(1);
    var verifier = buildVerifier(gpa, trusted);
    defer verifier.deinit();

    const body = try envelopeBytes(gpa);
    defer gpa.free(body);
    // Sign with a different key than the verifier trusts.
    const signed = try authenticator.sign(signerFor(2), body);

    var box: GrantBox = .{ .grant = .{ .bound_principal = holder, .scopes = &.{} } };
    const outcome = receive(&verifier, signed, box.resolver(), .{ .routes = &routes }, 0);
    try testing.expectEqual(FaultCode.integrity_failure, outcome.fault);
}
