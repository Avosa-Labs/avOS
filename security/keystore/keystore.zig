//! Who may use which key.
//!
//! The secure element decides whether a key may be used at all — the right
//! purpose, an unlocked device, a use limit not yet reached. The keystore
//! decides who is asking. Both checks are necessary and neither substitutes for
//! the other: an element that trusts the caller's word about identity protects
//! nothing from a compromised caller, and a keystore over an element that hands
//! out key material protects nothing from anyone.
//!
//! A key belongs to exactly one principal. Sharing is delegation of the
//! operation, never of the key, so a principal that may sign with a key still
//! cannot pass it on in a form that outlives the delegation.
//!
//! Nothing here can produce key material either. It is a lookup and an
//! authorization check in front of an interface that has no export operation,
//! and adding one at this layer would mean adding one below it first.

const std = @import("std");
const core = @import("core");
const secure_element = @import("hardware").secure_element;
const attestation = @import("../attestation/attestation.zig");
const manifest = core.trust.manifest;

pub const Error = error{
    /// No key by that name for this principal. Also what a principal asking for
    /// another principal's key gets: saying "not yours" would confirm it
    /// exists.
    UnknownKey,
    /// The keystore holds as many keys as it can.
    Full,
} || secure_element.Error;

/// A key as the keystore knows it.
pub const Record = struct {
    owner: core.identity.PrincipalId,
    /// Names the key within its owner. Two principals may use the same name for
    /// different keys, because a name is not identity.
    name: []const u8,
    handle: secure_element.KeyHandle,
    purpose: secure_element.Purpose,
};

/// How many keys the keystore tracks.
pub const capacity: usize = secure_element.capacity;

/// Keys, and who owns them.
pub const Keystore = struct {
    element: secure_element.Element,
    records: [capacity]?Record = @splat(null),

    pub fn init(element: secure_element.Element) Keystore {
        return .{ .element = element };
    }

    /// Whether the keys this holds are protected by hardware.
    ///
    /// Passed through rather than answered here. The keystore knows who may ask
    /// for a signature; only the element knows what a signature is worth.
    pub fn backing(keystore: *const Keystore) secure_element.Backing {
        return keystore.element.backing();
    }

    /// Creates a key owned by a principal.
    pub fn create(
        keystore: *Keystore,
        owner: core.identity.PrincipalId,
        name: []const u8,
        purpose: secure_element.Purpose,
        condition: secure_element.Condition,
    ) Error!void {
        // Refuse before creating: a key made in the element that the keystore
        // then failed to record would be unreachable and undestroyable.
        const slot = keystore.freeSlot() orelse return error.Full;
        if (keystore.find(owner, name) != null) return error.Full;

        const handle = try keystore.element.create(purpose, condition);
        keystore.records[slot] = .{
            .owner = owner,
            .name = name,
            .handle = handle,
            .purpose = purpose,
        };
    }

    /// Signs with a key its owner is asking for.
    pub fn sign(
        keystore: *Keystore,
        asking: core.identity.PrincipalId,
        name: []const u8,
        digest: [secure_element.digest_bytes]u8,
    ) Error![secure_element.signature_bytes]u8 {
        const record = keystore.find(asking, name) orelse return error.UnknownKey;
        return keystore.element.sign(record.handle, record.purpose, digest);
    }

    /// The public half of a key, for whoever needs to check its signatures.
    ///
    /// Available to the owner only. A public key identifies the principal that
    /// holds it, so handing it to anyone who asks would let one principal
    /// enumerate another's keys.
    pub fn publicKey(
        keystore: *Keystore,
        asking: core.identity.PrincipalId,
        name: []const u8,
    ) Error![secure_element.public_key_bytes]u8 {
        const record = keystore.find(asking, name) orelse return error.UnknownKey;
        return keystore.element.publicKey(record.handle);
    }

    /// Destroys a key and forgets it.
    pub fn destroy(
        keystore: *Keystore,
        asking: core.identity.PrincipalId,
        name: []const u8,
    ) Error!void {
        const index = keystore.indexOf(asking, name) orelse return error.UnknownKey;
        const record = keystore.records[index].?;
        try keystore.element.destroy(record.handle);
        keystore.records[index] = null;
    }

    /// Destroys every key a principal owns.
    ///
    /// What a principal ends up owning outlives the principal unless someone
    /// removes it, and a key that outlives its owner is a key nobody is
    /// accountable for.
    pub fn destroyAllOwnedBy(
        keystore: *Keystore,
        owner: core.identity.PrincipalId,
    ) Error!void {
        for (&keystore.records) |*entry| {
            const record = entry.* orelse continue;
            if (!record.owner.eql(owner)) continue;
            try keystore.element.destroy(record.handle);
            entry.* = null;
        }
    }

    /// How many keys a principal owns.
    pub fn countOwnedBy(keystore: *const Keystore, owner: core.identity.PrincipalId) usize {
        var total: usize = 0;
        for (keystore.records) |entry| {
            const record = entry orelse continue;
            if (record.owner.eql(owner)) total += 1;
        }
        return total;
    }

    fn find(
        keystore: *const Keystore,
        owner: core.identity.PrincipalId,
        name: []const u8,
    ) ?Record {
        const index = keystore.indexOf(owner, name) orelse return null;
        return keystore.records[index];
    }

    fn indexOf(
        keystore: *const Keystore,
        owner: core.identity.PrincipalId,
        name: []const u8,
    ) ?usize {
        for (keystore.records, 0..) |entry, index| {
            const record = entry orelse continue;
            if (record.owner.eql(owner) and std.mem.eql(u8, record.name, name)) return index;
        }
        return null;
    }

    fn freeSlot(keystore: *const Keystore) ?usize {
        for (keystore.records, 0..) |entry, index| {
            if (entry == null) return index;
        }
        return null;
    }
};

/// Lets one named key answer attestation challenges.
///
/// The delegate holds the owner and the name, never the key, so what is passed
/// around is permission to ask for a signature under one key for one purpose.
/// It cannot be widened by whoever holds it: the name it will use is fixed when
/// it is made.
pub const AttestationDelegate = struct {
    keystore: *Keystore,
    owner: core.identity.PrincipalId,
    name: []const u8,

    pub fn signer(delegate: *AttestationDelegate) attestation.Signer {
        return .{ .context_pointer = delegate, .signFn = signFor };
    }

    fn signFor(
        context_pointer: *anyopaque,
        digest: [attestation.digest_bytes]u8,
    ) ?[attestation.signature_bytes]u8 {
        const delegate: *AttestationDelegate = @ptrCast(@alignCast(context_pointer));
        // A refusal here becomes an absent quote rather than an unsigned one,
        // which is what the attestation layer does with a null.
        return delegate.keystore.sign(delegate.owner, delegate.name, digest) catch null;
    }
};

/// Lets one named key endorse an agent's manifest on the account's behalf.
///
/// Endorsing a manifest means the account's key signs the manifest's content
/// hash. This is the seam the provisioning path holds so it can ask for that
/// signature without ever seeing the key: the delegate keeps the account and the
/// key name, never the key, and the name is fixed when it is made, so whoever
/// holds the delegate can sign one manifest under one key and cannot widen it to
/// another. It is the manifest-layer counterpart of `AttestationDelegate` — the
/// digest and signature sizes are the element's Ed25519 over Sha256, the same the
/// manifest layer expects.
pub const EndorsementDelegate = struct {
    keystore: *Keystore,
    owner: core.identity.PrincipalId,
    name: []const u8,

    pub fn signer(delegate: *EndorsementDelegate) manifest.Signer {
        return .{ .context = delegate, .signFn = signFor };
    }

    fn signFor(
        context: *anyopaque,
        digest: [manifest.digest_bytes]u8,
    ) ?[manifest.signature_bytes]u8 {
        const delegate: *EndorsementDelegate = @ptrCast(@alignCast(context));
        // A refusal here becomes a failed endorsement rather than an unsigned
        // manifest: `endorseWith` turns a null into `EndorsementInvalid`, so an
        // agent is issued no grant rather than one nobody endorsed.
        return delegate.keystore.sign(delegate.owner, delegate.name, digest) catch null;
    }
};

const sample_digest: [secure_element.digest_bytes]u8 = @splat(5);

fn principal(value: u128) core.identity.PrincipalId {
    return .{ .value = value };
}

test "a principal can use the key it owns" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    try keystore.create(owner, "session", .session_binding, .{});
    const signature = try keystore.sign(owner, "session", sample_digest);
    const public = try keystore.publicKey(owner, "session");

    const key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(public);
    try (std.crypto.sign.Ed25519.Signature.fromBytes(signature)).verify(&sample_digest, key);
}

test "one principal cannot use another's key" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());

    try keystore.create(principal(1), "session", .session_binding, .{});

    // Refused as unknown rather than as forbidden: saying "not yours" would
    // confirm the key exists.
    try std.testing.expectError(
        error.UnknownKey,
        keystore.sign(principal(2), "session", sample_digest),
    );
    try std.testing.expectError(
        error.UnknownKey,
        keystore.publicKey(principal(2), "session"),
    );
    try std.testing.expectError(error.UnknownKey, keystore.destroy(principal(2), "session"));
}

test "two principals may use the same name for different keys" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());

    try keystore.create(principal(1), "storage", .storage_protection, .{});
    try keystore.create(principal(2), "storage", .storage_protection, .{});

    // A name is not identity, so the same name must not collide across owners.
    const first = try keystore.publicKey(principal(1), "storage");
    const second = try keystore.publicKey(principal(2), "storage");
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "a key is created for one purpose and used only for it" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    try keystore.create(owner, "attestation", .device_attestation, .{});
    // The purpose comes from the record rather than the caller, so a caller
    // cannot ask for a signature under a purpose the key was not made for.
    _ = try keystore.sign(owner, "attestation", sample_digest);
}

test "the element's conditions still apply" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    try keystore.create(owner, "unlock", .user_authentication, .{ .requires_unlocked = true });

    // Owning the key is not the same as being allowed to use it now. Both
    // checks apply, and neither substitutes for the other.
    try std.testing.expectError(
        error.ConditionUnmet,
        keystore.sign(owner, "unlock", sample_digest),
    );

    software.device.unlocked = true;
    _ = try keystore.sign(owner, "unlock", sample_digest);
}

test "a destroyed key is unusable and its name is free again" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    try keystore.create(owner, "storage", .storage_protection, .{});
    const before = try keystore.publicKey(owner, "storage");
    try keystore.destroy(owner, "storage");

    try std.testing.expectError(
        error.UnknownKey,
        keystore.sign(owner, "storage", sample_digest),
    );

    // A name reused after destruction gets a new key, not the old one back.
    try keystore.create(owner, "storage", .storage_protection, .{});
    const after = try keystore.publicKey(owner, "storage");
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "a name cannot be taken twice by the same principal" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    try keystore.create(owner, "session", .session_binding, .{});
    // Replacing it silently would destroy whatever the first key protected.
    try std.testing.expectError(
        error.Full,
        keystore.create(owner, "session", .session_binding, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), keystore.countOwnedBy(owner));
}

test "removing a principal removes its keys" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const leaving = principal(1);
    const staying = principal(2);

    try keystore.create(leaving, "session", .session_binding, .{});
    try keystore.create(leaving, "storage", .storage_protection, .{});
    try keystore.create(staying, "storage", .storage_protection, .{});

    try keystore.destroyAllOwnedBy(leaving);

    try std.testing.expectEqual(@as(usize, 0), keystore.countOwnedBy(leaving));
    try std.testing.expectEqual(@as(usize, 1), keystore.countOwnedBy(staying));
    _ = try keystore.sign(staying, "storage", sample_digest);
}

test "a full keystore refuses without creating a key it cannot reach" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);

    var buffer: [capacity][2]u8 = undefined;
    for (0..capacity) |index| {
        buffer[index] = .{ 'k', @intCast('a' + index) };
        try keystore.create(owner, &buffer[index], .storage_protection, .{});
    }

    try std.testing.expectError(
        error.Full,
        keystore.create(owner, "one more", .storage_protection, .{}),
    );

    // The element must not hold a key the keystore never recorded: such a key
    // could never be used and never be destroyed.
    var occupied: usize = 0;
    for (software.slots) |slot| {
        if (slot.occupied) occupied += 1;
    }
    try std.testing.expectEqual(capacity, occupied);
}

test "an unavailable element is reported rather than worked around" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "session", .session_binding, .{});

    software.unavailable = true;
    try std.testing.expectError(
        error.Unavailable,
        keystore.sign(owner, "session", sample_digest),
    );
    try std.testing.expectError(
        error.Unavailable,
        keystore.create(owner, "another", .session_binding, .{}),
    );
}

test "what a signature is worth comes from the element, not from here" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    try std.testing.expectEqual(secure_element.Backing.software, keystore.backing());
}

test "nothing here returns key material" {
    // The keystore is a lookup and an authorization check in front of an
    // interface with no export operation. Adding one here would mean adding one
    // below it first, which the element's own test forbids.
    const forbidden = [_][]const u8{ "export", "extract", "unwrap", "privateKey", "backup" };
    inline for (@typeInfo(Keystore).@"struct".decls) |declaration| {
        for (forbidden) |name| {
            try std.testing.expect(!std.mem.eql(u8, declaration.name, name));
        }
    }
}

test "an attestation key answers a challenge through the keystore" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "attestation", .device_attestation, .{});

    var delegate: AttestationDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "attestation",
    };
    const digest: [attestation.digest_bytes]u8 = @splat(3);
    const signature = delegate.signer().signFn(&delegate, digest).?;

    const public = try keystore.publicKey(owner, "attestation");
    const key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(public);
    try (std.crypto.sign.Ed25519.Signature.fromBytes(signature)).verify(&digest, key);
}

test "a delegate whose key is gone produces no signature" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "attestation", .device_attestation, .{});

    var delegate: AttestationDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "attestation",
    };
    try keystore.destroy(owner, "attestation");

    // No signature at all rather than a weaker one: the attestation layer turns
    // this into an absent quote.
    const digest: [attestation.digest_bytes]u8 = @splat(3);
    try std.testing.expectEqual(
        @as(?[attestation.signature_bytes]u8, null),
        delegate.signer().signFn(&delegate, digest),
    );
}

test "a delegate cannot be pointed at another key" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "attestation", .device_attestation, .{});
    try keystore.create(owner, "storage", .storage_protection, .{});

    var delegate: AttestationDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "attestation",
    };
    const digest: [attestation.digest_bytes]u8 = @splat(3);
    const signature = delegate.signer().signFn(&delegate, digest).?;

    // The signature is the attestation key's, not the other key's, whatever the
    // holder of the delegate would prefer.
    const other = try keystore.publicKey(owner, "storage");
    const other_key = try std.crypto.sign.Ed25519.PublicKey.fromBytes(other);
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        (std.crypto.sign.Ed25519.Signature.fromBytes(signature)).verify(&digest, other_key),
    );
}

fn sampleManifest(issuer: core.identity.PrincipalId, agent_key: [manifest.public_key_bytes]u8) manifest.Manifest {
    return .{
        .subject = .{ .value = 0xA },
        .issuer = issuer,
        .kind = .agent,
        .public_key = agent_key,
        .expires_at = .fromSeconds(10_000),
        .capabilities = &.{.{ .name = "calendar.read", .action_class = .silent }},
        .namespaces_requested = &.{},
        .namespaces_offered = &.{},
        .delegation = .{},
        .budgets = .{},
        .data_class = .never_leaves_device,
    };
}

test "an endorsement key signs an agent manifest through the keystore" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "endorsement", .user_authentication, .{});

    var delegate: EndorsementDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "endorsement",
    };
    const agent_key = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(9))).public_key.toBytes();
    const document = sampleManifest(owner, agent_key);

    // The account endorses without the provisioning path ever touching its key,
    // and the endorsement verifies against the key's public half.
    const endorsement = try manifest.endorseWith(delegate.signer(), owner, document);
    const public = try keystore.publicKey(owner, "endorsement");
    try manifest.verify(document, public, endorsement);
}

test "an endorsement delegate whose key is gone endorses nothing" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "endorsement", .user_authentication, .{});

    var delegate: EndorsementDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "endorsement",
    };
    try keystore.destroy(owner, "endorsement");

    // No signature at all rather than a weaker one: `endorseWith` fails closed, so
    // a manifest whose key is gone is issued no endorsement.
    const agent_key = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(9))).public_key.toBytes();
    const document = sampleManifest(owner, agent_key);
    try std.testing.expectError(
        manifest.Error.EndorsementInvalid,
        manifest.endorseWith(delegate.signer(), owner, document),
    );
}

test "an endorsement delegate cannot be pointed at another key" {
    var software: secure_element.SoftwareElement = .{};
    var keystore: Keystore = .init(software.element());
    const owner = principal(1);
    try keystore.create(owner, "endorsement", .user_authentication, .{});
    try keystore.create(owner, "storage", .storage_protection, .{});

    var delegate: EndorsementDelegate = .{
        .keystore = &keystore,
        .owner = owner,
        .name = "endorsement",
    };
    const agent_key = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(9))).public_key.toBytes();
    const document = sampleManifest(owner, agent_key);
    const endorsement = try manifest.endorseWith(delegate.signer(), owner, document);

    // The endorsement is the endorsement key's, not the storage key's, whatever
    // the holder of the delegate would prefer.
    const other = try keystore.publicKey(owner, "storage");
    try std.testing.expectError(
        manifest.Error.EndorsementInvalid,
        manifest.verify(document, other, endorsement),
    );
}
