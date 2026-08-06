//! Provenance for authority actions: a tamper-evident record of who did what, under which capability,
//! endorsed by which root, to which namespace — answerable from records, not inferred.
//!
//! The hard half of trust is after the fact. For any change to a shared or owned namespace, this chain
//! records the acting principal, the capability it acted under, the root that endorsed it, the namespace,
//! what changed, and whether it is reversible. Each entry commits to the one before it by hash, so the
//! trail is append-only and tamper-evident: altering any past entry breaks the chain from that point on,
//! and a verifier can prove the history was not quietly rewritten. Cross-owner actions record the
//! endorsement root, not just the actor, so "who did this to our shared workspace" has a cryptographic
//! answer rather than a guess.

const std = @import("std");
const identity = @import("../identity/identity.zig");
const time = @import("../time/time.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
pub const digest_bytes = Sha256.digest_length;

/// What an actor did to a namespace. Read is recorded too, so provenance answers who has seen a shared
/// namespace, not only who changed it.
pub const Action = enum(u8) { created, read, wrote, deleted, delegated, revoked };

/// One provenance entry. `entry_hash` binds this entry's content to the previous entry's hash, forming
/// the tamper-evident chain.
pub const Record = struct {
    sequence: u64,
    /// The principal that acted.
    actor: identity.PrincipalId,
    /// The capability or grant it acted under.
    capability: identity.CapabilityId,
    /// The root that endorsed the actor — the head of its endorsement chain. For an owner's own agent,
    /// the account; for a cross-owner action, the counterparty's trust root.
    endorser: identity.PrincipalId,
    namespace: []const u8,
    action: Action,
    /// Whether the change can be undone from records — the question a person asks first.
    reversible: bool,
    at: time.Timestamp,
    entry_hash: [digest_bytes]u8,

    fn contentHash(previous: [digest_bytes]u8, sequence: u64, actor: identity.PrincipalId, capability: identity.CapabilityId, endorser: identity.PrincipalId, namespace: []const u8, action: Action, reversible: bool, at: time.Timestamp) [digest_bytes]u8 {
        var hasher = Sha256.init(.{});
        hasher.update("trust.provenance.v1");
        hasher.update(&previous);
        hashInt(&hasher, u64, sequence);
        hashInt(&hasher, u128, actor.value);
        hashInt(&hasher, u128, capability.value);
        hashInt(&hasher, u128, endorser.value);
        hashField(&hasher, namespace);
        hashInt(&hasher, u8, @intFromEnum(action));
        hashInt(&hasher, u8, @intFromBool(reversible));
        hashInt(&hasher, i64, at.nanoseconds);
        var digest: [digest_bytes]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }
};

/// The genesis hash the first entry chains from — a fixed, well-known value so an empty chain has a
/// definite head rather than an arbitrary one.
pub const genesis: [digest_bytes]u8 = @splat(0);

/// An append-only, hash-chained provenance ledger. Namespace strings are borrowed and must outlive the
/// chain (they name durable resources, so the caller owns their storage).
pub const Chain = struct {
    records: std.ArrayListUnmanaged(Record) = .empty,

    pub fn deinit(self: *Chain, gpa: std.mem.Allocator) void {
        self.records.deinit(gpa);
    }

    /// The hash the next entry will chain from: the last entry's hash, or the genesis hash when empty.
    pub fn head(self: Chain) [digest_bytes]u8 {
        if (self.records.items.len == 0) return genesis;
        return self.records.items[self.records.items.len - 1].entry_hash;
    }

    /// Appends an action to the chain, computing its hash from the current head. Returns the new entry.
    pub fn record(
        self: *Chain,
        gpa: std.mem.Allocator,
        actor: identity.PrincipalId,
        capability: identity.CapabilityId,
        endorser: identity.PrincipalId,
        namespace: []const u8,
        action: Action,
        reversible: bool,
        at: time.Timestamp,
    ) !Record {
        const sequence = self.records.items.len;
        const entry_hash = Record.contentHash(self.head(), sequence, actor, capability, endorser, namespace, action, reversible, at);
        const entry: Record = .{
            .sequence = sequence,
            .actor = actor,
            .capability = capability,
            .endorser = endorser,
            .namespace = namespace,
            .action = action,
            .reversible = reversible,
            .at = at,
            .entry_hash = entry_hash,
        };
        try self.records.append(gpa, entry);
        return entry;
    }

    /// Re-derives every entry's hash from the genesis forward and confirms it matches what was stored and
    /// that the sequence is unbroken. Any altered past entry — content or order — makes this false, so the
    /// audit trail cannot be quietly rewritten.
    pub fn verify(self: Chain) bool {
        var previous = genesis;
        for (self.records.items, 0..) |entry, index| {
            if (entry.sequence != index) return false;
            const expected = Record.contentHash(previous, entry.sequence, entry.actor, entry.capability, entry.endorser, entry.namespace, entry.action, entry.reversible, entry.at);
            if (!std.mem.eql(u8, &expected, &entry.entry_hash)) return false;
            previous = entry.entry_hash;
        }
        return true;
    }

    /// Every entry touching a namespace, newest last — the readable history of who did what to a shared
    /// or owned namespace, written into `out` and returned as a slice.
    pub fn touching(self: Chain, namespace: []const u8, out: []Record) []const Record {
        var count: usize = 0;
        for (self.records.items) |entry| {
            if (count >= out.len) break;
            if (std.mem.eql(u8, entry.namespace, namespace)) {
                out[count] = entry;
                count += 1;
            }
        }
        return out[0..count];
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

test "a chain of actions verifies, and answers who touched a namespace" {
    var chain: Chain = .{};
    defer chain.deinit(testing.allocator);

    _ = try chain.record(testing.allocator, .{ .value = 0xA }, .{ .value = 0x1 }, .{ .value = 0xACC }, "workspace/shared", .created, true, .fromSeconds(1));
    _ = try chain.record(testing.allocator, .{ .value = 0xB }, .{ .value = 0x2 }, .{ .value = 0xBCC }, "workspace/shared", .wrote, true, .fromSeconds(2));
    _ = try chain.record(testing.allocator, .{ .value = 0xB }, .{ .value = 0x2 }, .{ .value = 0xBCC }, "notes/private", .read, false, .fromSeconds(3));

    try testing.expect(chain.verify());

    var buffer: [8]Record = undefined;
    const shared = chain.touching("workspace/shared", &buffer);
    try testing.expectEqual(@as(usize, 2), shared.len);
    // The endorsement root is recorded, so a cross-owner action names who vouched for the actor.
    try testing.expect(shared[1].endorser.eql(.{ .value = 0xBCC }));
    try testing.expect(shared[1].action == .wrote);
}

test "tampering with a past entry breaks the chain from that point" {
    var chain: Chain = .{};
    defer chain.deinit(testing.allocator);
    _ = try chain.record(testing.allocator, .{ .value = 0xA }, .{ .value = 0x1 }, .{ .value = 0xACC }, "workspace/shared", .created, true, .fromSeconds(1));
    _ = try chain.record(testing.allocator, .{ .value = 0xB }, .{ .value = 0x2 }, .{ .value = 0xBCC }, "workspace/shared", .wrote, true, .fromSeconds(2));
    try testing.expect(chain.verify());

    // Quietly rewrite history: change a recorded action. The stored hash no longer matches.
    chain.records.items[0].action = .deleted;
    try testing.expect(!chain.verify());

    // Reordering is caught too: the sequence no longer matches the position.
    chain.records.items[0].action = .created; // undo the content change
    std.mem.swap(Record, &chain.records.items[0], &chain.records.items[1]);
    try testing.expect(!chain.verify());
}

test "reversibility is carried, so provenance says whether a change can be undone" {
    var chain: Chain = .{};
    defer chain.deinit(testing.allocator);
    const reversible_entry = try chain.record(testing.allocator, .{ .value = 0xA }, .{ .value = 0x1 }, .{ .value = 0xACC }, "files/tree", .wrote, true, .fromSeconds(1));
    const irreversible_entry = try chain.record(testing.allocator, .{ .value = 0xA }, .{ .value = 0x1 }, .{ .value = 0xACC }, "files/tree", .deleted, false, .fromSeconds(2));
    try testing.expect(reversible_entry.reversible);
    try testing.expect(!irreversible_entry.reversible);
    try testing.expect(chain.verify());
}
