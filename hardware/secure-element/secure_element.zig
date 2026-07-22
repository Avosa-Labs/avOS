//! The part of the device that holds keys the rest of the device cannot read.
//!
//! Everything here is expressed as an interface, because what makes a key
//! hardware-backed is where it lives and not what the calling code believes. An
//! implementation is a real element on a real board, or it is software standing
//! in for one, and the difference must be something a caller can ask about
//! rather than something it assumes.
//!
//! There is no operation that returns key material. Not a restricted one, not a
//! privileged one, not one for backup: an interface with an export function is
//! an interface that can be talked into exporting. Keys are created inside the
//! element and used inside it, and what crosses the boundary is a handle and a
//! signature.
//!
//! Conditions on a key are enforced inside the element too. A condition the
//! caller checks is a condition an attacker who controls the caller does not
//! have.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;
pub const signature_bytes = Ed25519.Signature.encoded_length;
pub const public_key_bytes = Ed25519.PublicKey.encoded_length;

pub const Error = error{
    /// No key by that handle. Also what a handle to a deleted key gets, because
    /// distinguishing the two would say whether a key once existed.
    UnknownKey,
    /// The key exists but its conditions are not met right now.
    ConditionUnmet,
    /// The key exists but was not created for this.
    WrongPurpose,
    /// The element has no room for another key.
    Full,
    /// The element is not responding.
    Unavailable,
};

/// What a key may be used for.
///
/// Declared when the key is created and enforced on every use, so a key issued
/// for one job cannot quietly do another. A single key that signs both
/// attestations and user data lets anyone who can ask for one obtain the other.
pub const Purpose = enum {
    /// Signs statements about what this device booted.
    device_attestation,
    /// Signs on behalf of the person using the device.
    user_authentication,
    /// Protects data at rest.
    storage_protection,
    /// Authenticates this endpoint to another one.
    session_binding,
};

/// When a key may be used.
///
/// Checked inside the element against state the element observes, not against
/// state the caller reports.
pub const Condition = struct {
    /// The device must be unlocked.
    requires_unlocked: bool = false,
    /// The person must have authenticated recently.
    requires_recent_authentication: bool = false,
    /// The key stops working after this many uses. Zero means no limit.
    ///
    /// A limit is the difference between a stolen handle signing once and
    /// signing forever.
    use_limit: u32 = 0,
};

/// What the element currently observes about the device.
pub const DeviceState = struct {
    unlocked: bool = false,
    authenticated_recently: bool = false,
};

/// An opaque reference to a key inside the element.
///
/// It is a name, not a secret: holding one does not authorize using the key,
/// because the conditions are checked at use.
pub const KeyHandle = struct {
    value: u64,

    pub fn eql(handle: KeyHandle, other: KeyHandle) bool {
        return handle.value == other.value;
    }
};

/// Where a key actually lives.
///
/// Reported rather than assumed. A remote verifier deciding how much a signature
/// is worth needs to know, and a device that could not tell the difference would
/// have to be trusted to be honest about something it did not know.
pub const Backing = enum {
    /// A discrete element the main processor cannot read.
    hardware,
    /// Software standing in for one. Offers no protection against code running
    /// on the same machine.
    software,
};

/// The element.
pub const Element = struct {
    context_pointer: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        backing: *const fn (context_pointer: *anyopaque) Backing,
        create: *const fn (
            context_pointer: *anyopaque,
            purpose: Purpose,
            condition: Condition,
        ) Error!KeyHandle,
        publicKey: *const fn (
            context_pointer: *anyopaque,
            handle: KeyHandle,
        ) Error![public_key_bytes]u8,
        sign: *const fn (
            context_pointer: *anyopaque,
            handle: KeyHandle,
            purpose: Purpose,
            digest: [digest_bytes]u8,
        ) Error![signature_bytes]u8,
        destroy: *const fn (context_pointer: *anyopaque, handle: KeyHandle) Error!void,
    };

    /// Where keys held by this element actually live.
    pub fn backing(element: Element) Backing {
        return element.vtable.backing(element.context_pointer);
    }

    /// Creates a key inside the element. The material never leaves.
    pub fn create(element: Element, purpose: Purpose, condition: Condition) Error!KeyHandle {
        return element.vtable.create(element.context_pointer, purpose, condition);
    }

    /// The public half, which is the only half anything outside ever sees.
    pub fn publicKey(element: Element, handle: KeyHandle) Error![public_key_bytes]u8 {
        return element.vtable.publicKey(element.context_pointer, handle);
    }

    /// Signs, if the key exists, was created for this purpose, and its
    /// conditions are met.
    ///
    /// The purpose is passed at use as well as at creation so a caller states
    /// what it thinks it is doing and the element can disagree.
    pub fn sign(
        element: Element,
        handle: KeyHandle,
        purpose: Purpose,
        digest: [digest_bytes]u8,
    ) Error![signature_bytes]u8 {
        return element.vtable.sign(element.context_pointer, handle, purpose, digest);
    }

    /// Destroys a key. What it protected becomes unreadable, which is the point.
    pub fn destroy(element: Element, handle: KeyHandle) Error!void {
        return element.vtable.destroy(element.context_pointer, handle);
    }
};

/// How many keys an element holds.
pub const capacity: usize = 32;

/// An element implemented in software.
///
/// For the emulator, the simulator, and tests. It reports `.software` backing
/// and always will: a stand-in that claimed to be hardware would let every layer
/// above it be tested against a guarantee it was not getting.
pub const SoftwareElement = struct {
    const Slot = struct {
        occupied: bool = false,
        /// Which key this slot holds. Compared against the handle, so a handle
        /// to a destroyed key does not reach the key that replaced it.
        generation: u32 = 0,
        pair: Ed25519.KeyPair = undefined,
        purpose: Purpose = .device_attestation,
        condition: Condition = .{},
        uses: u32 = 0,
    };

    slots: [capacity]Slot = @splat(.{}),
    /// Distinguishes a fresh key in a reused slot from the key it replaced.
    generation: u32 = 0,
    /// What the element observes. In a real element this comes from the
    /// hardware; here it is set by whoever is exercising it.
    device: DeviceState = .{},
    /// Set to make every operation fail, so the unavailable path is reachable.
    unavailable: bool = false,
    /// Seeds deterministic key generation, so a scenario replays exactly.
    next_seed: u8 = 1,

    pub fn element(software: *SoftwareElement) Element {
        return .{ .context_pointer = software, .vtable = &vtable };
    }

    const vtable: Element.VTable = .{
        .backing = backingOf,
        .create = createIn,
        .publicKey = publicKeyOf,
        .sign = signIn,
        .destroy = destroyIn,
    };

    fn from(context_pointer: *anyopaque) *SoftwareElement {
        return @ptrCast(@alignCast(context_pointer));
    }

    fn backingOf(context_pointer: *anyopaque) Backing {
        _ = context_pointer;
        return .software;
    }

    /// Packs the slot and the generation into the handle, so a handle to a
    /// destroyed key does not come back to life when the slot is reused.
    fn handleFor(index: usize, generation: u32) KeyHandle {
        return .{ .value = (@as(u64, generation) << 32) | index };
    }

    fn slotFor(software: *SoftwareElement, handle: KeyHandle) Error!*Slot {
        const index: usize = @intCast(handle.value & 0xffff_ffff);
        if (index >= capacity) return error.UnknownKey;
        const slot = &software.slots[index];
        if (!slot.occupied) return error.UnknownKey;
        if (slot.generation != @as(u32, @intCast(handle.value >> 32))) return error.UnknownKey;
        return slot;
    }

    fn createIn(
        context_pointer: *anyopaque,
        purpose: Purpose,
        condition: Condition,
    ) Error!KeyHandle {
        const software = from(context_pointer);
        if (software.unavailable) return error.Unavailable;

        for (&software.slots, 0..) |*slot, index| {
            if (slot.occupied) continue;
            const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(software.next_seed);
            software.next_seed +%= 1;
            software.generation += 1;
            slot.* = .{
                .occupied = true,
                .generation = software.generation,
                .pair = Ed25519.KeyPair.generateDeterministic(seed) catch
                    return error.Unavailable,
                .purpose = purpose,
                .condition = condition,
            };
            return handleFor(index, software.generation);
        }
        return error.Full;
    }

    fn publicKeyOf(context_pointer: *anyopaque, handle: KeyHandle) Error![public_key_bytes]u8 {
        const software = from(context_pointer);
        if (software.unavailable) return error.Unavailable;
        const slot = try software.slotFor(handle);
        return slot.pair.public_key.toBytes();
    }

    fn signIn(
        context_pointer: *anyopaque,
        handle: KeyHandle,
        purpose: Purpose,
        digest: [digest_bytes]u8,
    ) Error![signature_bytes]u8 {
        const software = from(context_pointer);
        if (software.unavailable) return error.Unavailable;
        const slot = try software.slotFor(handle);

        if (slot.purpose != purpose) return error.WrongPurpose;
        if (slot.condition.requires_unlocked and !software.device.unlocked) {
            return error.ConditionUnmet;
        }
        if (slot.condition.requires_recent_authentication and
            !software.device.authenticated_recently)
        {
            return error.ConditionUnmet;
        }
        if (slot.condition.use_limit != 0 and slot.uses >= slot.condition.use_limit) {
            return error.ConditionUnmet;
        }

        // Counted before signing. A count kept afterwards is a count a failure
        // between the two can skip.
        slot.uses += 1;
        const signature = slot.pair.sign(&digest, null) catch return error.Unavailable;
        return signature.toBytes();
    }

    fn destroyIn(context_pointer: *anyopaque, handle: KeyHandle) Error!void {
        const software = from(context_pointer);
        if (software.unavailable) return error.Unavailable;
        const slot = try software.slotFor(handle);
        slot.* = .{};
    }
};

const sample_digest: [digest_bytes]u8 = @splat(9);

test "a key is created inside the element and used by handle" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.device_attestation, .{});
    const public = try element.publicKey(handle);
    const signature = try element.sign(handle, .device_attestation, sample_digest);

    const key = try Ed25519.PublicKey.fromBytes(public);
    try (Ed25519.Signature.fromBytes(signature)).verify(&sample_digest, key);
}

test "nothing in the interface returns key material" {
    // Checked structurally rather than by convention: an export function added
    // later fails this test rather than passing review.
    inline for (@typeInfo(Element.VTable).@"struct".fields) |field| {
        const forbidden = [_][]const u8{ "export", "extract", "unwrap", "privateKey", "backup" };
        for (forbidden) |name| {
            try std.testing.expect(!std.mem.eql(u8, field.name, name));
        }
    }
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(Element.VTable).@"struct".fields.len);
}

test "a key created for one purpose refuses another" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.storage_protection, .{});
    try std.testing.expectError(
        error.WrongPurpose,
        element.sign(handle, .device_attestation, sample_digest),
    );
    _ = try element.sign(handle, .storage_protection, sample_digest);
}

test "a key that requires an unlocked device refuses a locked one" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.user_authentication, .{ .requires_unlocked = true });
    try std.testing.expectError(
        error.ConditionUnmet,
        element.sign(handle, .user_authentication, sample_digest),
    );

    // The condition is checked against what the element observes, so satisfying
    // it means changing the device rather than telling the element otherwise.
    software.device.unlocked = true;
    _ = try element.sign(handle, .user_authentication, sample_digest);
}

test "a key that requires recent authentication refuses without it" {
    var software: SoftwareElement = .{};
    const element = software.element();
    software.device.unlocked = true;

    const handle = try element.create(
        .user_authentication,
        .{ .requires_recent_authentication = true },
    );
    try std.testing.expectError(
        error.ConditionUnmet,
        element.sign(handle, .user_authentication, sample_digest),
    );

    software.device.authenticated_recently = true;
    _ = try element.sign(handle, .user_authentication, sample_digest);
}

test "a use limit is enforced" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.session_binding, .{ .use_limit = 2 });
    _ = try element.sign(handle, .session_binding, sample_digest);
    _ = try element.sign(handle, .session_binding, sample_digest);

    // A stolen handle signs at most as many times as the limit allows, rather
    // than forever.
    try std.testing.expectError(
        error.ConditionUnmet,
        element.sign(handle, .session_binding, sample_digest),
    );
}

test "a refused use still counts against nothing" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(
        .session_binding,
        .{ .use_limit = 1, .requires_unlocked = true },
    );
    // Refused before the count, so a locked device cannot exhaust a key by
    // asking for it.
    _ = element.sign(handle, .session_binding, sample_digest) catch {};
    _ = element.sign(handle, .session_binding, sample_digest) catch {};

    software.device.unlocked = true;
    _ = try element.sign(handle, .session_binding, sample_digest);
}

test "a destroyed key is gone and its handle does not come back" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.storage_protection, .{});
    try element.destroy(handle);

    try std.testing.expectError(
        error.UnknownKey,
        element.sign(handle, .storage_protection, sample_digest),
    );
    try std.testing.expectError(error.UnknownKey, element.publicKey(handle));

    // The slot is reused, and the old handle must not reach the key that took
    // its place.
    const replacement = try element.create(.storage_protection, .{});
    try std.testing.expect(!replacement.eql(handle));
    _ = try element.publicKey(replacement);
    try std.testing.expectError(error.UnknownKey, element.publicKey(handle));
    try std.testing.expectError(
        error.UnknownKey,
        element.sign(handle, .storage_protection, sample_digest),
    );
}

test "an unknown handle and a destroyed one are indistinguishable" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const handle = try element.create(.storage_protection, .{});
    try element.destroy(handle);

    const never_existed: KeyHandle = .{ .value = 31 };
    try std.testing.expectEqual(
        element.publicKey(handle),
        element.publicKey(never_existed),
    );
}

test "keys are distinct from each other" {
    var software: SoftwareElement = .{};
    const element = software.element();

    const first = try element.create(.storage_protection, .{});
    const second = try element.create(.storage_protection, .{});
    try std.testing.expect(!first.eql(second));

    const first_key = try element.publicKey(first);
    const second_key = try element.publicKey(second);
    try std.testing.expect(!std.mem.eql(u8, &first_key, &second_key));
}

test "a full element refuses rather than evicting" {
    var software: SoftwareElement = .{};
    const element = software.element();

    for (0..capacity) |_| _ = try element.create(.storage_protection, .{});
    // Evicting would destroy whatever the displaced key protected, silently.
    try std.testing.expectError(error.Full, element.create(.storage_protection, .{}));
}

test "an unavailable element refuses every operation" {
    var software: SoftwareElement = .{};
    const element = software.element();
    const handle = try element.create(.storage_protection, .{});

    software.unavailable = true;
    try std.testing.expectError(error.Unavailable, element.create(.storage_protection, .{}));
    try std.testing.expectError(error.Unavailable, element.publicKey(handle));
    try std.testing.expectError(
        error.Unavailable,
        element.sign(handle, .storage_protection, sample_digest),
    );
    try std.testing.expectError(error.Unavailable, element.destroy(handle));
}

test "a software element says it is software" {
    var software: SoftwareElement = .{};
    // It must never claim otherwise: every layer above would then be tested
    // against a guarantee it was not getting.
    try std.testing.expectEqual(Backing.software, software.element().backing());
}

test "an unknown handle is refused rather than defaulting to a key" {
    var software: SoftwareElement = .{};
    const element = software.element();
    _ = try element.create(.storage_protection, .{});

    const out_of_range: KeyHandle = .{ .value = capacity + 5 };
    try std.testing.expectError(error.UnknownKey, element.publicKey(out_of_range));
    try std.testing.expectError(
        error.UnknownKey,
        element.sign(out_of_range, .storage_protection, sample_digest),
    );
}
