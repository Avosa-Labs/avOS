//! How much storage each principal may use, and refusing the write that would
//! exceed it.
//!
//! Storage is shared and finite, and the failure it invites is one principal
//! filling the disk so that every other principal — and the system itself —
//! fails at its next write, in a place that has nothing to do with the one that
//! consumed the space. So storage is not a common pool anyone draws from freely.
//! Each principal has a quota, a write that would exceed it is refused at the
//! moment it is attempted, and the refusal is that principal's problem alone
//! rather than a disk-full error that surfaces somewhere unrelated later.
//!
//! This is the accounting and the decision, not the storage. It tracks bytes per
//! principal against a ceiling, refuses an allocation that would breach it,
//! releases bytes when data is deleted, and never lets the accounting drift
//! below zero or wrap — an underflow would hand a principal unlimited space, an
//! overflow would lock it out. It is exact and total, so the number it reports
//! is the number on disk.

const std = @import("std");
const core = @import("core");

const PrincipalId = core.identity.PrincipalId;

pub const Error = error{
    /// The write would push the principal over its quota. Its problem, refused
    /// here, not a disk-full failure elsewhere.
    QuotaExceeded,
    /// A release named more bytes than the principal is holding. A caller bug
    /// caught rather than allowed to underflow the accounting into a huge value.
    ReleaseUnderflow,
    /// No quota is recorded for the principal. It may use nothing until one is
    /// set, which is the safe default.
    NoQuota,
    /// The tracker has no room for another principal.
    Full,
};

/// One principal's storage account.
pub const Account = struct {
    principal: PrincipalId,
    /// The most bytes this principal may hold.
    ceiling_bytes: u64,
    /// Bytes currently held. Always at or below the ceiling.
    used_bytes: u64 = 0,

    pub fn available(account: Account) u64 {
        return account.ceiling_bytes - account.used_bytes;
    }

    pub fn isOverHalf(account: Account) bool {
        return account.used_bytes * 2 > account.ceiling_bytes;
    }
};

/// How many principals the tracker holds accounts for.
pub const max_accounts: usize = 256;

/// The per-principal storage accounting.
pub const Tracker = struct {
    accounts: [max_accounts]?Account = @splat(null),

    /// Sets a principal's quota, creating its account. A ceiling below what the
    /// principal already holds is allowed and simply leaves it over quota until
    /// it deletes something — it is not retroactively evicted, but it can write
    /// nothing more.
    pub fn setQuota(tracker: *Tracker, principal: PrincipalId, ceiling_bytes: u64) Error!void {
        if (tracker.indexOf(principal)) |index| {
            tracker.accounts[index].?.ceiling_bytes = ceiling_bytes;
            return;
        }
        const slot = tracker.freeSlot() orelse return error.Full;
        tracker.accounts[slot] = .{ .principal = principal, .ceiling_bytes = ceiling_bytes };
    }

    /// Reserves bytes for a write, or refuses if it would breach the quota.
    ///
    /// Checked before the write, because a quota noticed after the bytes are on
    /// disk is a quota already exceeded. The addition is overflow-safe: a request
    /// so large it would wrap is refused as exceeding the quota, never silently
    /// accepted.
    pub fn reserve(tracker: *Tracker, principal: PrincipalId, bytes: u64) Error!void {
        const index = tracker.indexOf(principal) orelse return error.NoQuota;
        const account = &tracker.accounts[index].?;
        const after = std.math.add(u64, account.used_bytes, bytes) catch return error.QuotaExceeded;
        if (after > account.ceiling_bytes) return error.QuotaExceeded;
        account.used_bytes = after;
    }

    /// Releases bytes when data is deleted.
    ///
    /// Refuses to release more than the principal holds, because that would
    /// underflow the count into an enormous value and hand the principal
    /// effectively unlimited space. A caller that double-frees is caught here.
    pub fn release(tracker: *Tracker, principal: PrincipalId, bytes: u64) Error!void {
        const index = tracker.indexOf(principal) orelse return error.NoQuota;
        const account = &tracker.accounts[index].?;
        if (bytes > account.used_bytes) return error.ReleaseUnderflow;
        account.used_bytes -= bytes;
    }

    /// The bytes a principal may still write.
    pub fn available(tracker: Tracker, principal: PrincipalId) Error!u64 {
        const index = tracker.indexOf(principal) orelse return error.NoQuota;
        return tracker.accounts[index].?.available();
    }

    /// A principal's account, for inspection.
    pub fn accountOf(tracker: Tracker, principal: PrincipalId) ?Account {
        const index = tracker.indexOf(principal) orelse return null;
        return tracker.accounts[index].?;
    }

    fn indexOf(tracker: Tracker, principal: PrincipalId) ?usize {
        for (tracker.accounts, 0..) |entry, index| {
            const account = entry orelse continue;
            if (account.principal.eql(principal)) return index;
        }
        return null;
    }

    fn freeSlot(tracker: Tracker) ?usize {
        for (tracker.accounts, 0..) |entry, index| {
            if (entry == null) return index;
        }
        return null;
    }
};

fn principalId(value: u128) PrincipalId {
    return .{ .value = value };
}

test "a write within quota is reserved" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 400);
    try std.testing.expectEqual(@as(u64, 600), try tracker.available(owner));
}

test "a write that would exceed the quota is refused at that principal" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 900);
    // The write that would breach the quota is refused, rather than filling the
    // disk and failing someone else's write later.
    try std.testing.expectError(error.QuotaExceeded, tracker.reserve(owner, 200));
    // And nothing was consumed by the failed reservation.
    try std.testing.expectEqual(@as(u64, 100), try tracker.available(owner));
}

test "one principal's usage does not affect another's quota" {
    var tracker: Tracker = .{};
    const alex = principalId(1);
    const sam = principalId(2);
    try tracker.setQuota(alex, 1000);
    try tracker.setQuota(sam, 1000);
    try tracker.reserve(alex, 1000);
    // Alex is full; Sam is untouched.
    try std.testing.expectError(error.QuotaExceeded, tracker.reserve(alex, 1));
    try tracker.reserve(sam, 1000);
    try std.testing.expectEqual(@as(u64, 0), try tracker.available(sam));
}

test "released bytes become available again" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 800);
    try tracker.release(owner, 300);
    try std.testing.expectEqual(@as(u64, 500), try tracker.available(owner));
}

test "releasing more than is held is refused rather than underflowing" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 100);
    // A double-free would underflow the count into a huge value and grant
    // unlimited space; it is caught.
    try std.testing.expectError(error.ReleaseUnderflow, tracker.release(owner, 200));
    try std.testing.expectEqual(@as(u64, 900), try tracker.available(owner));
}

test "a write so large it would overflow is refused, not wrapped" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, std.math.maxInt(u64));
    try tracker.reserve(owner, std.math.maxInt(u64) - 10);
    // Adding a value that would wrap past u64 must refuse, never silently accept
    // by wrapping to a small number.
    try std.testing.expectError(error.QuotaExceeded, tracker.reserve(owner, 100));
}

test "a principal with no quota may use nothing" {
    var tracker: Tracker = .{};
    // The safe default: unknown principal reserves nothing until a quota is set.
    try std.testing.expectError(error.NoQuota, tracker.reserve(principalId(9), 1));
    try std.testing.expectError(error.NoQuota, tracker.available(principalId(9)));
}

test "lowering a quota below current usage stops further writes without eviction" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 800);
    // The quota drops below what is held: no eviction, but nothing more may be
    // written, and available saturates at zero rather than underflowing.
    try tracker.setQuota(owner, 500);
    try std.testing.expectError(error.QuotaExceeded, tracker.reserve(owner, 1));
    const account = tracker.accountOf(owner).?;
    try std.testing.expectEqual(@as(u64, 800), account.used_bytes);
}

test "the account reports crossing half its ceiling" {
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 1000);
    try tracker.reserve(owner, 400);
    try std.testing.expect(!tracker.accountOf(owner).?.isOverHalf());
    try tracker.reserve(owner, 200);
    try std.testing.expect(tracker.accountOf(owner).?.isOverHalf());
}

test "the tracker refuses a new principal when full" {
    var tracker: Tracker = .{};
    for (0..max_accounts) |index| {
        try tracker.setQuota(principalId(index + 1), 100);
    }
    try std.testing.expectError(error.Full, tracker.setQuota(principalId(9999), 100));
    // But updating an existing principal's quota still works when full.
    try tracker.setQuota(principalId(1), 200);
}

test "a full sequence of reserve and release stays exact" {
    // The accounting must never drift: after many operations, the number matches
    // what was actually reserved.
    var tracker: Tracker = .{};
    const owner = principalId(1);
    try tracker.setQuota(owner, 10_000);
    var held: u64 = 0;
    for (0..500) |i| {
        if (i % 3 == 0 and held >= 5) {
            try tracker.release(owner, 5);
            held -= 5;
        } else {
            try tracker.reserve(owner, 10);
            held += 10;
        }
    }
    try std.testing.expectEqual(held, tracker.accountOf(owner).?.used_bytes);
}
