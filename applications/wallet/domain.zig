//! The Wallet domain: the person's real cards and passes and a stored-value balance, and the one act
//! that moves money — a payment — which is held for the person and, above all, applied exactly once.
//!
//! This is the "one domain" both doors reach. It holds the cards a person keeps and their stored-value
//! balance. Listing the cards and reading the balance are silent; adding a card is an ordinary local
//! change. A payment is the strongest act the frame knows — it transfers value — so it is held for the
//! person, and its idempotency is not a nicety but the whole point: an agent's payment, approved
//! perhaps after a restart or a double tap, must debit once and only once. The domain records the key
//! of every applied payment and a re-drive returns the first result rather than paying again. An agent
//! paying and a person paying run the identical code over the same balance.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// A card or pass the person keeps: a name and the last four digits shown on the face. The full number
/// never lives here — the wallet holds only what identifies a card to its owner.
const Card = struct { name: []const u8, last4: []const u8 };
const Applied = struct { key: u128, result: []const u8 };

/// The Wallet store: the cards, the stored-value balance in whole cents, and the record of applied
/// keyed payments.
pub const Store = struct {
    gpa: std.mem.Allocator,
    cards: std.ArrayListUnmanaged(Card) = .empty,
    /// The stored-value balance in whole cents. A payment debits it; it never goes negative because a
    /// payment beyond the balance is refused before anything is recorded.
    balance_cents: i64 = 0,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    reply: [24]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(store: *Store) void {
        store.cards.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn cardCount(store: Store) usize {
        return store.cards.items.len;
    }

    pub fn balance(store: Store) i64 {
        return store.balance_cents;
    }

    /// Loads the stored-value balance — how the wallet is funded, outside the payment path.
    pub fn fund(store: *Store, cents: i64) void {
        store.balance_cents += cents;
    }

    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |entry| {
            if (entry.key == key) return entry.result;
        }
        return null;
    }

    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach. For an add `args` is "name@last4"; for a payment it is
    /// "cents@merchant".
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        if (std.mem.eql(u8, op, "wallet.list")) return .{ .ok = "listed" };
        if (std.mem.eql(u8, op, "wallet.balance")) {
            const text = std.fmt.bufPrint(&store.reply, "{d}", .{store.balance_cents}) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key — for a payment this is the load-bearing invariant.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };
        if (std.mem.eql(u8, op, "wallet.add_card")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            store.cards.append(store.gpa, .{ .name = input.args[0..at], .last4 = input.args[at + 1 ..] }) catch return .failed;
            return store.commit(key, "added");
        }
        if (std.mem.eql(u8, op, "wallet.pay")) {
            const at = std.mem.indexOfScalar(u8, input.args, '@') orelse return .failed;
            const cents = std.fmt.parseInt(i64, input.args[0..at], 10) catch return .failed;
            // A payment is positive and within the balance; either failing refuses it before any debit,
            // so the balance is never wrong and no key is recorded for a payment that did not happen.
            if (cents <= 0 or cents > store.balance_cents) return .failed;
            store.balance_cents -= cents;
            return store.commit(key, "paid");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

test "adding cards and reading the balance are ordinary, and a card holds only its last four" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "wallet.add_card", .args = "Everyday@4242" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "wallet.add_card", .args = "Travel@0005" }, agent(), 2);
    try testing.expectEqual(@as(usize, 2), store.cardCount());
    store.fund(5000); // 50.00
    try testing.expectEqualStrings("5000", Store.execute(&store, .{ .operation = "wallet.balance", .args = "" }, agent(), 0).ok);
}

test "a payment debits the balance exactly once by key — a re-drive never double-charges" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    store.fund(5000);
    const first = Store.execute(&store, .{ .operation = "wallet.pay", .args = "1500@Cafe" }, agent(), 9);
    try testing.expectEqualStrings("paid", first.ok);
    try testing.expectEqual(@as(i64, 3500), store.balance());
    // The same payment re-driven under the same key returns the first result and does not debit again.
    const again = Store.execute(&store, .{ .operation = "wallet.pay", .args = "1500@Cafe" }, agent(), 9);
    try testing.expectEqualStrings("paid", again.ok);
    try testing.expectEqual(@as(i64, 3500), store.balance()); // still 35.00, charged once
}

test "a payment beyond the balance or a non-positive amount is refused before any debit" {
    const gpa = testing.allocator;
    var store = Store.init(gpa);
    defer store.deinit();
    store.fund(1000);
    // Over balance: refused, balance untouched, no key recorded.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "wallet.pay", .args = "1500@Shop" }, agent(), 1));
    try testing.expectEqual(@as(i64, 1000), store.balance());
    // Non-positive: refused.
    try testing.expectEqual(DomainResult.failed, Store.execute(&store, .{ .operation = "wallet.pay", .args = "0@Shop" }, agent(), 2));
    // A later valid payment under a fresh key still works — the refused keys did not record anything.
    _ = Store.execute(&store, .{ .operation = "wallet.pay", .args = "400@Shop" }, agent(), 3);
    try testing.expectEqual(@as(i64, 600), store.balance());
}
