//! The endorsement chain: verifying an agent's identity back to a trust root the verifier accepts.
//!
//! A single endorsement (an account signing an agent's manifest) says "I vouch for this agent". A chain
//! composes those: an account endorses an agent, a device co-endorses an embodied one, and a verifier
//! accepts the agent only if the endorsements link, unbroken, back to a root it already trusts. Each link
//! carries the endorser's key and its signature over the subject's identity and accepted-manifest hash,
//! so the chain binds identity to manifest at every hop. A link is trusted only when its endorser is
//! itself the subject of the next link up — continuity of both principal and key — and the top of the
//! chain is a root the verifier anchors. A broken signature, a discontinuity, an unknown root, or a
//! chain that runs longer than allowed all fail the whole chain: identity is verified, never asserted.

const std = @import("std");
const identity = @import("../identity/identity.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;
pub const digest_bytes = Sha256.digest_length;

/// The longest endorsement chain accepted, so a malformed or adversarial chain cannot force unbounded
/// work: account → intermediate → agent is short, and depth beyond this is refused.
pub const max_chain = 8;

pub const Error = error{
    SignatureInvalid,
    SubjectMismatch,
    Discontinuous,
    RootNotAnchored,
    ChainEmpty,
    ChainTooLong,
};

/// One endorsement: an issuer vouching for a subject's identity and the manifest the subject accepted.
/// The signature is the issuer's over the link's content, so none of it can be altered after signing.
pub const Link = struct {
    issuer: identity.PrincipalId,
    issuer_key: [public_key_bytes]u8,
    subject: identity.PrincipalId,
    subject_key: [public_key_bytes]u8,
    /// Binds the endorsement to the exact manifest the subject accepted, so re-pointing an endorsement
    /// at a different manifest breaks it.
    manifest_hash: [digest_bytes]u8,
    signature: [signature_bytes]u8,

    fn digest(issuer: identity.PrincipalId, issuer_key: [public_key_bytes]u8, subject: identity.PrincipalId, subject_key: [public_key_bytes]u8, manifest_hash: [digest_bytes]u8) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("trust.endorsement.link.v1");
        hashInt(&hasher, u128, issuer.value);
        hasher.update(&issuer_key);
        hashInt(&hasher, u128, subject.value);
        hasher.update(&subject_key);
        hasher.update(&manifest_hash);
        var out: [digest_bytes]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// Whether this link's signature is the issuer's over its own content.
    fn signatureValid(link: Link) bool {
        const key = Ed25519.PublicKey.fromBytes(link.issuer_key) catch return false;
        const parsed: Ed25519.Signature = .fromBytes(link.signature);
        parsed.verify(&Link.digest(link.issuer, link.issuer_key, link.subject, link.subject_key, link.manifest_hash), key) catch return false;
        return true;
    }
};

/// A root the verifier already trusts: a principal and the key it is known by. A chain is accepted only
/// when its top endorser is one of these.
pub const Root = struct {
    principal: identity.PrincipalId,
    key: [public_key_bytes]u8,
};

/// Produces a signed link: `issuer_key` vouches for `subject` holding `subject_key` under `manifest_hash`.
pub fn sign(
    issuer_key: Ed25519.KeyPair,
    issuer: identity.PrincipalId,
    subject: identity.PrincipalId,
    subject_key: [public_key_bytes]u8,
    manifest_hash: [digest_bytes]u8,
) Error!Link {
    const d = Link.digest(issuer, issuer_key.public_key.toBytes(), subject, subject_key, manifest_hash);
    const signature = issuer_key.sign(&d, null) catch return Error.SignatureInvalid;
    return .{
        .issuer = issuer,
        .issuer_key = issuer_key.public_key.toBytes(),
        .subject = subject,
        .subject_key = subject_key,
        .manifest_hash = manifest_hash,
        .signature = signature.toBytes(),
    };
}

/// Verifies a chain endorsing `agent`, ordered from the agent upward: `links[0]` endorses the agent, each
/// subsequent link endorses the previous link's endorser, and the top endorser is a trusted root. Fails
/// closed on any broken signature, discontinuity, unanchored root, empty or over-long chain.
pub fn verifyChain(links: []const Link, agent: identity.PrincipalId, agent_key: [public_key_bytes]u8, anchors: []const Root) Error!void {
    if (links.len == 0) return Error.ChainEmpty;
    if (links.len > max_chain) return Error.ChainTooLong;

    // The bottom link must endorse the agent, with the agent's own key.
    if (!links[0].subject.eql(agent) or !keysEqual(links[0].subject_key, agent_key)) return Error.SubjectMismatch;

    for (links, 0..) |link, i| {
        if (!link.signatureValid()) return Error.SignatureInvalid;
        if (i + 1 < links.len) {
            // Continuity: this link's endorser is the next link's subject, same principal and same key.
            const above = links[i + 1];
            if (!link.issuer.eql(above.subject) or !keysEqual(link.issuer_key, above.subject_key)) return Error.Discontinuous;
        }
    }

    // The top endorser must be a root the verifier anchors, known by the same key it signed with.
    const top = links[links.len - 1];
    for (anchors) |root| {
        if (root.principal.eql(top.issuer) and keysEqual(root.key, top.issuer_key)) return;
    }
    return Error.RootNotAnchored;
}

fn keysEqual(a: [public_key_bytes]u8, b: [public_key_bytes]u8) bool {
    return std.crypto.timing_safe.eql([public_key_bytes]u8, a, b);
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

// --- Tests ---

const testing = std.testing;

const Fixture = struct {
    root: Ed25519.KeyPair,
    device: Ed25519.KeyPair,
    agent_key: Ed25519.KeyPair,
    root_id: identity.PrincipalId = .{ .value = 0x100 },
    device_id: identity.PrincipalId = .{ .value = 0x200 },
    agent_id: identity.PrincipalId = .{ .value = 0x300 },
    manifest_hash: [digest_bytes]u8 = @splat(0xAB),

    fn init() !Fixture {
        return .{
            .root = try Ed25519.KeyPair.generateDeterministic(@splat(1)),
            .device = try Ed25519.KeyPair.generateDeterministic(@splat(2)),
            .agent_key = try Ed25519.KeyPair.generateDeterministic(@splat(3)),
        };
    }

    fn anchors(self: Fixture) [1]Root {
        return .{.{ .principal = self.root_id, .key = self.root.public_key.toBytes() }};
    }
};

test "a two-hop chain (root endorses device, device endorses agent) verifies to the anchored root" {
    const f = try Fixture.init();
    const lower = try sign(f.device, f.device_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const upper = try sign(f.root, f.root_id, f.device_id, f.device.public_key.toBytes(), f.manifest_hash);
    const chain = [_]Link{ lower, upper };
    const anchors = f.anchors();
    try verifyChain(&chain, f.agent_id, f.agent_key.public_key.toBytes(), &anchors);
}

test "a direct account endorsement verifies" {
    const f = try Fixture.init();
    const link = try sign(f.root, f.root_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const chain = [_]Link{link};
    const anchors = f.anchors();
    try verifyChain(&chain, f.agent_id, f.agent_key.public_key.toBytes(), &anchors);
}

test "a broken signature anywhere fails the whole chain" {
    const f = try Fixture.init();
    var lower = try sign(f.device, f.device_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const upper = try sign(f.root, f.root_id, f.device_id, f.device.public_key.toBytes(), f.manifest_hash);
    lower.signature[0] ^= 0xFF; // tamper the lower endorsement
    const chain = [_]Link{ lower, upper };
    const anchors = f.anchors();
    try testing.expectError(Error.SignatureInvalid, verifyChain(&chain, f.agent_id, f.agent_key.public_key.toBytes(), &anchors));
}

test "a chain whose top is not an anchored root is refused" {
    const f = try Fixture.init();
    const impostor = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    // The top link is signed by an impostor claiming to be the root principal — its key is not anchored.
    const link = try sign(impostor, f.root_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const chain = [_]Link{link};
    const anchors = f.anchors();
    try testing.expectError(Error.RootNotAnchored, verifyChain(&chain, f.agent_id, f.agent_key.public_key.toBytes(), &anchors));
}

test "a discontinuous chain (a link's endorser is not the next link's subject) fails" {
    const f = try Fixture.init();
    const stranger = try Ed25519.KeyPair.generateDeterministic(@splat(8));
    const stranger_id: identity.PrincipalId = .{ .value = 0x999 };
    // lower is endorsed by the device, but the upper link endorses a stranger, not the device.
    const lower = try sign(f.device, f.device_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const upper = try sign(f.root, f.root_id, stranger_id, stranger.public_key.toBytes(), f.manifest_hash);
    const chain = [_]Link{ lower, upper };
    const anchors = f.anchors();
    try testing.expectError(Error.Discontinuous, verifyChain(&chain, f.agent_id, f.agent_key.public_key.toBytes(), &anchors));
}

test "a chain endorsing a different agent (or key) than presented is refused" {
    const f = try Fixture.init();
    const other_key = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const link = try sign(f.root, f.root_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    const chain = [_]Link{link};
    const anchors = f.anchors();
    // Presenting the right agent id but a different key than was endorsed.
    try testing.expectError(Error.SubjectMismatch, verifyChain(&chain, f.agent_id, other_key.public_key.toBytes(), &anchors));
}

test "an empty or over-long chain is refused" {
    const f = try Fixture.init();
    const anchors = f.anchors();
    try testing.expectError(Error.ChainEmpty, verifyChain(&.{}, f.agent_id, f.agent_key.public_key.toBytes(), &anchors));

    var many: [max_chain + 1]Link = undefined;
    for (&many) |*link| link.* = try sign(f.root, f.root_id, f.agent_id, f.agent_key.public_key.toBytes(), f.manifest_hash);
    try testing.expectError(Error.ChainTooLong, verifyChain(&many, f.agent_id, f.agent_key.public_key.toBytes(), &anchors));
}
