//! A store where an object's name is its content, so two copies are one and a
//! corrupted one is caught.
//!
//! Most storage names a thing by where it is: a path, an offset, a handle. A
//! content-addressed store names it by what it is — the digest of its bytes — and
//! that one change buys three properties the platform leans on. Identical content
//! stored twice is stored once, because it has one name, which is how a backup or
//! a set of similar images does not cost their combined size. An object cannot be
//! altered without its name changing, so fetching by name and checking the digest
//! catches any corruption or tampering for free. And a reference to an object is a
//! reference to exactly those bytes forever, because the name cannot come to mean
//! anything else.
//!
//! This is the addressing and integrity layer, over whatever block storage sits
//! beneath. It computes an object's address, refuses to return bytes whose digest
//! does not match the address asked for, and counts references so an object is not
//! discarded while something still points at it. It allocates the index; the bulk
//! bytes live below.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const address_bytes = Sha256.digest_length;

/// An object's address: the digest of its content.
///
/// Two objects with the same address have the same bytes; that is the whole
/// premise, and it is why the address is computed from content rather than
/// assigned.
pub const Address = struct {
    digest: [address_bytes]u8,

    pub fn eql(a: Address, b: Address) bool {
        return std.mem.eql(u8, &a.digest, &b.digest);
    }

    /// The address of some content.
    pub fn of(content: []const u8) Address {
        var digest: [address_bytes]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        return .{ .digest = digest };
    }
};

pub const Error = error{
    /// The requested address is not in the store.
    NotFound,
    /// The stored bytes do not hash to the address they are filed under —
    /// corruption or tampering, caught because the name is the content.
    IntegrityFailure,
    /// The store is full.
    Full,
    /// A release was called on an object with no outstanding references. A
    /// double-free caught rather than allowed to discard an object something
    /// still uses.
    NotReferenced,
};

/// How many distinct objects the store indexes.
pub const capacity: usize = 1024;

/// A content-addressed object store.
///
/// The index maps an address to its content and a reference count; the content
/// is borrowed from a caller-owned backing buffer, because the bulk bytes are the
/// block layer's to own, not this index's.
pub const Store = struct {
    const Entry = struct {
        address: Address,
        content: []const u8,
        references: u32,
    };

    entries: [capacity]?Entry = @splat(null),

    /// Stores content, returning its address. Storing content already present
    /// adds a reference rather than a second copy, which is the deduplication
    /// that makes identical data free to store again.
    pub fn put(store: *Store, content: []const u8) Error!Address {
        const address = Address.of(content);
        if (store.indexOf(address)) |index| {
            store.entries[index].?.references += 1;
            return address;
        }
        const slot = store.freeSlot() orelse return error.Full;
        store.entries[slot] = .{ .address = address, .content = content, .references = 1 };
        return address;
    }

    /// Fetches content by address, verifying it still hashes to that address.
    ///
    /// The integrity check is not optional: the point of a content address is
    /// that the bytes returned are exactly the bytes named, so a mismatch is
    /// reported rather than the wrong bytes handed back.
    pub fn get(store: Store, address: Address) Error![]const u8 {
        const index = store.indexOf(address) orelse return error.NotFound;
        const content = store.entries[index].?.content;
        if (!Address.of(content).eql(address)) return error.IntegrityFailure;
        return content;
    }

    /// Adds a reference to an existing object, for a second holder.
    pub fn retain(store: *Store, address: Address) Error!void {
        const index = store.indexOf(address) orelse return error.NotFound;
        store.entries[index].?.references += 1;
    }

    /// Drops a reference. The object is discarded only when the last reference
    /// goes, so an object is never removed while something still points at it.
    pub fn release(store: *Store, address: Address) Error!void {
        const index = store.indexOf(address) orelse return error.NotFound;
        const entry = &store.entries[index].?;
        if (entry.references == 0) return error.NotReferenced;
        entry.references -= 1;
        if (entry.references == 0) store.entries[index] = null;
    }

    /// How many references an object has, or zero if it is not present.
    pub fn referenceCount(store: Store, address: Address) u32 {
        const index = store.indexOf(address) orelse return 0;
        return store.entries[index].?.references;
    }

    pub fn contains(store: Store, address: Address) bool {
        return store.indexOf(address) != null;
    }

    fn indexOf(store: Store, address: Address) ?usize {
        for (store.entries, 0..) |entry, index| {
            const present = entry orelse continue;
            if (present.address.eql(address)) return index;
        }
        return null;
    }

    fn freeSlot(store: Store) ?usize {
        for (store.entries, 0..) |entry, index| {
            if (entry == null) return index;
        }
        return null;
    }
};

test "an object's address is the digest of its content" {
    const a = Address.of("hello");
    const b = Address.of("hello");
    const c = Address.of("world");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "storing and fetching round-trips" {
    var store: Store = .{};
    const address = try store.put("the object contents");
    try std.testing.expectEqualStrings("the object contents", try store.get(address));
}

test "identical content is stored once and reference-counted" {
    var store: Store = .{};
    const first = try store.put("same bytes");
    const second = try store.put("same bytes");
    // One name, so one object, with two references — not two copies.
    try std.testing.expect(first.eql(second));
    try std.testing.expectEqual(@as(u32, 2), store.referenceCount(first));
}

test "an object survives until its last reference is released" {
    var store: Store = .{};
    const address = try store.put("shared");
    try store.retain(address); // two references now
    try store.release(address);
    // Still present: one reference remains.
    try std.testing.expect(store.contains(address));
    try store.release(address);
    // Now gone.
    try std.testing.expect(!store.contains(address));
}

test "fetching a corrupted object is caught" {
    var store: Store = .{};
    // Store content, then corrupt the backing bytes behind the store's back, as
    // disk corruption would.
    var backing = [_]u8{ 'g', 'o', 'o', 'd' };
    const address = try store.put(&backing);
    backing[0] = 'b';
    // The bytes no longer hash to the address they are filed under.
    try std.testing.expectError(error.IntegrityFailure, store.get(address));
}

test "a missing address is not found" {
    const store: Store = .{};
    try std.testing.expectError(error.NotFound, store.get(Address.of("absent")));
}

test "releasing an object with no references is refused" {
    var store: Store = .{};
    const address = try store.put("once");
    try store.release(address); // drops to zero, removed
    // A second release is a double-free: the object is gone.
    try std.testing.expectError(error.NotFound, store.release(address));
}

test "different content produces different addresses and separate objects" {
    var store: Store = .{};
    const a = try store.put("alpha");
    const b = try store.put("beta");
    try std.testing.expect(!a.eql(b));
    try std.testing.expectEqualStrings("alpha", try store.get(a));
    try std.testing.expectEqualStrings("beta", try store.get(b));
}

test "a full store refuses a new object but still retains an existing one" {
    var store: Store = .{};
    var buffers: [capacity][8]u8 = undefined;
    for (0..capacity) |index| {
        buffers[index] = .{ 'o', 'b', 'j', @intCast(index & 0xff), @intCast(index >> 8), 0, 0, 0 };
        _ = try store.put(&buffers[index]);
    }
    try std.testing.expectError(error.Full, store.put("one too many"));
    // Storing content already present still works when full, because it adds a
    // reference rather than an object.
    const existing = try store.put(&buffers[0]);
    try std.testing.expectEqual(@as(u32, 2), store.referenceCount(existing));
}

test "a reference count reaching zero frees the slot for reuse" {
    var store: Store = .{};
    const a = try store.put("first");
    try store.release(a);
    // The slot is free again; a new object can take it.
    const b = try store.put("second");
    try std.testing.expect(store.contains(b));
    try std.testing.expect(!store.contains(a));
}

test "the empty content has a stable address" {
    var store: Store = .{};
    const address = try store.put("");
    try std.testing.expectEqualStrings("", try store.get(address));
    try std.testing.expect(address.eql(Address.of("")));
}
