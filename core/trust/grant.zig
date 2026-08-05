//! Cross-owner namespace grants and revocation: deliberate, verified sharing across a trust boundary.
//!
//! By default a principal under a different owner is untrusted content. This adds the machinery for
//! sharing on purpose: an owner signs a scoped grant that lets a named counterparty reach one namespace,
//! bounded in reach (read/write/delete), in time, and in count, and traceable through a delegation
//! chain. The counterparty holds an opaque handle — the grant's id — and every use is validated against
//! the owner's signature and the bounds before anything happens. Sharing never transfers ownership: the
//! owner can revoke a single grant, or cut off a whole principal in one act, and the revocation takes
//! effect for every later use immediately. Only identity and granted reach are ever trusted; the
//! counterparty's claims and content are not.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

pub const Error = error{
    SignatureInvalid,
    HolderMismatch,
    Expired,
    Exhausted,
    ReachExceeded,
    Revoked,
    DelegationTooDeep,
};

/// The reach a grant confers within its namespace. Delete is separate because it is the reach that most
/// needs consent.
pub const Reach = struct {
    read: bool = false,
    write: bool = false,
    delete: bool = false,

    /// Whether `self` stays within `allowed` — every reach it asks for is one the grant confers.
    pub fn withinReach(self: Reach, allowed: Reach) bool {
        return (!self.read or allowed.read) and (!self.write or allowed.write) and (!self.delete or allowed.delete);
    }
};

/// A scoped, signed, revocable grant from one owner to a counterparty principal. The signature covers
/// every field, so none can be altered on a validly-signed grant.
pub const Grant = struct {
    id: identity.CapabilityId,
    /// The owner extending the reach — the root that signs.
    granter: identity.PrincipalId,
    /// The counterparty the reach is extended to. Only this principal may use the grant.
    holder: identity.PrincipalId,
    namespace: []const u8,
    reach: Reach,
    /// The grant is unusable after this instant.
    expires_at: time.Timestamp,
    /// How many uses remain, or null for unbounded within the time bound.
    uses_remaining: ?u32,
    /// How much further this grant may be delegated. A delegated grant must sit strictly below its
    /// parent, so a chain can never exceed the depth the owner allowed.
    delegation_depth: u8,

    /// The digest the granter signs — a canonical serialization so the signature commits to every field.
    pub fn signingDigest(grant: Grant) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("cross_owner.grant.v1");
        hashInt(&hasher, u128, grant.id.value);
        hashInt(&hasher, u128, grant.granter.value);
        hashInt(&hasher, u128, grant.holder.value);
        hashField(&hasher, grant.namespace);
        hashInt(&hasher, u8, @intFromBool(grant.reach.read));
        hashInt(&hasher, u8, @intFromBool(grant.reach.write));
        hashInt(&hasher, u8, @intFromBool(grant.reach.delete));
        hashInt(&hasher, i64, grant.expires_at.nanoseconds);
        hashInt(&hasher, u8, @intFromBool(grant.uses_remaining != null));
        hashInt(&hasher, u32, grant.uses_remaining orelse 0);
        hashInt(&hasher, u8, grant.delegation_depth);
        var digest: [digest_bytes]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }
};

/// A grant bound to its owner's signature. The handle a counterparty presents is opaque — it carries no
/// authority on its own; authority is re-derived by verifying this at the owner's boundary on every use.
pub const SignedGrant = struct {
    grant: Grant,
    signature: [signature_bytes]u8,
};

/// Signs a grant with the granter's key.
pub fn sign(granter_key: Ed25519.KeyPair, grant: Grant) Error!SignedGrant {
    const digest = grant.signingDigest();
    const signature = granter_key.sign(&digest, null) catch return Error.SignatureInvalid;
    return .{ .grant = grant, .signature = signature.toBytes() };
}

/// What a counterparty is trying to do with a grant: who is presenting it, the reach they want, and
/// when. Everything here is checked against the signed grant and the revocation set before it proceeds.
pub const Use = struct {
    holder: identity.PrincipalId,
    reach: Reach,
    now: time.Timestamp,
};

/// Validates a use against the signed grant and the owner's revocation set — the full check at the
/// owner's boundary. Fails closed on any of: a broken or non-owner signature, a holder that is not the
/// grantee, expiry, exhausted uses, reach beyond the grant, or a revoked grant or principal. Returns the
/// uses remaining after this one (null when unbounded) so the caller can persist the decrement.
pub fn validate(
    signed: SignedGrant,
    granter_public_key: [public_key_bytes]u8,
    revocations: *const Revocations,
    use: Use,
) Error!?u32 {
    const grant = signed.grant;
    // Revocation is checked first and fails closed instantly: a revoked grant or a cut-off principal is
    // denied regardless of the signature being otherwise valid.
    if (revocations.isRevoked(grant.id, grant.holder)) return Error.Revoked;

    const key = Ed25519.PublicKey.fromBytes(granter_public_key) catch return Error.SignatureInvalid;
    const parsed: Ed25519.Signature = .fromBytes(signed.signature);
    parsed.verify(&grant.signingDigest(), key) catch return Error.SignatureInvalid;

    if (!use.holder.eql(grant.holder)) return Error.HolderMismatch;
    if (use.now.isAfter(grant.expires_at)) return Error.Expired;
    if (grant.uses_remaining) |remaining| {
        if (remaining == 0) return Error.Exhausted;
    }
    if (!use.reach.withinReach(grant.reach)) return Error.ReachExceeded;

    if (grant.uses_remaining) |remaining| return remaining - 1;
    return null;
}

/// Delegates a grant one hop down the chain to a further holder, narrowing only. The child sits strictly
/// below its parent's delegation depth, so no chain can exceed the depth the original owner allowed, and
/// the child can never confer more reach than its parent held.
pub fn delegate(
    parent: Grant,
    child_id: identity.CapabilityId,
    to: identity.PrincipalId,
    reach: Reach,
    expires_at: time.Timestamp,
    uses_remaining: ?u32,
) Error!Grant {
    if (parent.delegation_depth == 0) return Error.DelegationTooDeep;
    if (!reach.withinReach(parent.reach)) return Error.ReachExceeded;
    if (expires_at.isAfter(parent.expires_at)) return Error.Expired; // a child cannot outlive its parent
    return .{
        .id = child_id,
        .granter = parent.holder, // the parent's holder is the child's granter
        .holder = to,
        .namespace = parent.namespace,
        .reach = reach,
        .expires_at = expires_at,
        .uses_remaining = uses_remaining,
        .delegation_depth = parent.delegation_depth - 1,
    };
}

/// The set of what an owner has cut off: individual grants, and whole principals. A principal in the set
/// invalidates every grant it holds at once — the trust kill switch — so a compromised counterparty is
/// contained in one act, not grant by grant.
pub const Revocations = struct {
    grants: std.AutoHashMapUnmanaged(u128, void) = .empty,
    principals: std.AutoHashMapUnmanaged(u128, void) = .empty,

    pub fn deinit(self: *Revocations, gpa: std.mem.Allocator) void {
        self.grants.deinit(gpa);
        self.principals.deinit(gpa);
    }

    /// Revokes a single grant. Idempotent.
    pub fn revokeGrant(self: *Revocations, gpa: std.mem.Allocator, id: identity.CapabilityId) !void {
        try self.grants.put(gpa, id.value, {});
    }

    /// Cuts off a principal across every grant it holds, at once — the kill path for trust.
    pub fn revokePrincipal(self: *Revocations, gpa: std.mem.Allocator, id: identity.PrincipalId) !void {
        try self.principals.put(gpa, id.value, {});
    }

    /// Whether a grant is revoked — the grant itself, or the principal that holds it. An O(1) lookup, so
    /// the check on every use is cheap.
    pub fn isRevoked(self: Revocations, id: identity.CapabilityId, holder: identity.PrincipalId) bool {
        return self.grants.contains(id.value) or self.principals.contains(holder.value);
    }
};

fn hashField(hasher: *Sha256, field: []const u8) void {
    hashInt(hasher, u32, @intCast(field.len));
    hasher.update(field);
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

// --- Tests ---

const testing = std.testing;

fn sampleGrant() Grant {
    return .{
        .id = .{ .value = 0x6 },
        .granter = .{ .value = 0xA },
        .holder = .{ .value = 0xB },
        .namespace = "workspace/shared",
        .reach = .{ .read = true, .write = true },
        .expires_at = .fromSeconds(10_000),
        .uses_remaining = 3,
        .delegation_depth = 1,
    };
}

test "a use within a signed grant validates and decrements the count" {
    const granter = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    const signed = try sign(granter, sampleGrant());
    var rev: Revocations = .{};
    defer rev.deinit(testing.allocator);
    const remaining = try validate(signed, granter.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xB },
        .reach = .{ .read = true },
        .now = .fromSeconds(1_000),
    });
    try testing.expectEqual(@as(?u32, 2), remaining);
}

test "a forged signature is refused" {
    const granter = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    const impostor = try Ed25519.KeyPair.generateDeterministic(@splat(5));
    const signed = try sign(granter, sampleGrant());
    var rev: Revocations = .{};
    defer rev.deinit(testing.allocator);
    try testing.expectError(Error.SignatureInvalid, validate(signed, impostor.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xB },
        .reach = .{ .read = true },
        .now = .fromSeconds(1_000),
    }));
}

test "least authority across the boundary: reach beyond the grant is denied, and the wrong holder too" {
    const granter = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    const signed = try sign(granter, sampleGrant());
    var rev: Revocations = .{};
    defer rev.deinit(testing.allocator);
    // delete was never granted.
    try testing.expectError(Error.ReachExceeded, validate(signed, granter.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xB },
        .reach = .{ .read = true, .delete = true },
        .now = .fromSeconds(1_000),
    }));
    // a principal that is not the grantee cannot use the grant.
    try testing.expectError(Error.HolderMismatch, validate(signed, granter.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xC },
        .reach = .{ .read = true },
        .now = .fromSeconds(1_000),
    }));
}

test "an expired or exhausted grant is denied" {
    const granter = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    var rev: Revocations = .{};
    defer rev.deinit(testing.allocator);

    const signed = try sign(granter, sampleGrant());
    try testing.expectError(Error.Expired, validate(signed, granter.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xB },
        .reach = .{ .read = true },
        .now = .fromSeconds(10_001),
    }));

    var spent = sampleGrant();
    spent.uses_remaining = 0;
    const signed_spent = try sign(granter, spent);
    try testing.expectError(Error.Exhausted, validate(signed_spent, granter.public_key.toBytes(), &rev, .{
        .holder = .{ .value = 0xB },
        .reach = .{ .read = true },
        .now = .fromSeconds(1_000),
    }));
}

test "revoking a grant, and cutting off a principal, both fail closed instantly" {
    const granter = try Ed25519.KeyPair.generateDeterministic(@splat(4));
    const signed = try sign(granter, sampleGrant());
    const ok: Use = .{ .holder = .{ .value = 0xB }, .reach = .{ .read = true }, .now = .fromSeconds(1_000) };

    var rev: Revocations = .{};
    defer rev.deinit(testing.allocator);
    _ = try validate(signed, granter.public_key.toBytes(), &rev, ok); // valid before revocation

    try rev.revokeGrant(testing.allocator, signed.grant.id);
    try testing.expectError(Error.Revoked, validate(signed, granter.public_key.toBytes(), &rev, ok));

    // The kill path: cutting off the holder principal revokes every grant it holds, including a second.
    var rev2: Revocations = .{};
    defer rev2.deinit(testing.allocator);
    var other = sampleGrant();
    other.id = .{ .value = 0x7 };
    const signed_other = try sign(granter, other);
    try rev2.revokePrincipal(testing.allocator, .{ .value = 0xB });
    try testing.expectError(Error.Revoked, validate(signed, granter.public_key.toBytes(), &rev2, ok));
    try testing.expectError(Error.Revoked, validate(signed_other, granter.public_key.toBytes(), &rev2, ok));
}

test "delegation narrows and cannot exceed the parent's depth or reach" {
    const parent = sampleGrant(); // depth 1, read+write
    const child = try delegate(parent, .{ .value = 0x8 }, .{ .value = 0xC }, .{ .read = true }, .fromSeconds(5_000), 1);
    try testing.expectEqual(@as(u8, 0), child.delegation_depth);
    try testing.expect(child.granter.eql(.{ .value = 0xB })); // the parent's holder granted the child
    try testing.expect(child.holder.eql(.{ .value = 0xC }));

    // A child cannot be delegated further once depth reaches zero.
    try testing.expectError(Error.DelegationTooDeep, delegate(child, .{ .value = 0x9 }, .{ .value = 0xD }, .{ .read = true }, .fromSeconds(4_000), null));

    // A child cannot claim reach the parent never held, nor outlive it.
    try testing.expectError(Error.ReachExceeded, delegate(parent, .{ .value = 0x9 }, .{ .value = 0xC }, .{ .read = true, .delete = true }, .fromSeconds(5_000), null));
    try testing.expectError(Error.Expired, delegate(parent, .{ .value = 0x9 }, .{ .value = 0xC }, .{ .read = true }, .fromSeconds(20_000), null));
}
