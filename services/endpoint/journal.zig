//! A write-ahead record of in-progress state transitions, so a service that is
//! restarted partway through one recovers to a clean state rather than a
//! half-applied one.
//!
//! A trusted service mutates state a caller depends on: a capability is issued, a
//! task advances, a secret is sealed. If the service process is killed — by a
//! fault, by the supervisor, by the host — in the middle of applying one of these,
//! the effect is in doubt: it may have been applied, or not, or applied but not yet
//! acknowledged. A service that came back and simply resumed taking requests would
//! carry that ambiguity into everything after it.
//!
//! The journal removes the ambiguity by making every mutation a transition with two
//! recorded phases. Before the effect is applied, the intent is written as
//! `prepared`. After it is durably applied, it is written as `committed`. A restart
//! then has only three cases to consider, and each is decidable: a transition with
//! no record never started and there is nothing to do; a `committed` transition
//! finished and is left alone; a `prepared` transition with no commit is in doubt,
//! and because every mutating method is keyed by an idempotency key and required to
//! be idempotent, recovery re-drives it to completion — applying it a second time
//! reaches the same state as applying it once. No transition is ever left partial:
//! after recovery each is either committed or has been re-driven and committed.
//!
//! This module records and classifies transitions; it applies none. Persisting the
//! log across a real process death is the storage layer's job — here the log is the
//! in-memory source of truth whose recovery logic the tests pin.

const std = @import("std");

/// The bound on a method name a transition may carry, kept in step with the IPC
/// method bound so a journal entry cannot name a method the wire refuses.
pub const max_method_bytes: usize = 64;

/// Distinguishes one transition from another within a service. Matches the
/// envelope correlation the request carried.
pub const Correlation = u64;

/// How far a transition has got. The two phases are the whole state machine: a
/// transition is either intended or done, and the gap between them is exactly the
/// window a restart must recover.
pub const Phase = enum {
    /// The intent is recorded but the effect is not yet known to be applied. A
    /// transition seen in this phase after a restart is in doubt.
    prepared,
    /// The effect is durably applied. A transition in this phase is finished and a
    /// restart leaves it untouched.
    committed,
};

/// One transition the journal tracks: which request, keyed for idempotent replay,
/// and how far it got.
pub const Transition = struct {
    correlation: Correlation,
    /// The idempotency key the mutating method is keyed by. Recovery relies on the
    /// method being idempotent under this key, so re-driving an in-doubt transition
    /// reaches the same state rather than doubling its effect.
    idempotency_key: u128,
    method: []const u8,
    phase: Phase,
};

pub const Error = error{
    /// The method name is longer than the journal will record.
    MethodTooLong,
    /// A transition was prepared for a correlation already in flight, which would
    /// make the log ambiguous about which intent is current.
    AlreadyInFlight,
    /// The journal is full. A service cannot hold more transitions in doubt than
    /// this at once without risking recovery it cannot bound.
    Full,
};

/// A bounded log of transitions, holding the latest phase for each correlation.
///
/// Ownership: the journal owns its entries and the method strings it copies. It
/// keeps at most one live entry per correlation — commit replaces the prepared
/// entry rather than appending — so the log is bounded by the number of distinct
/// in-flight transitions, not by traffic.
pub const Journal = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Transition) = .empty,
    /// Ceiling on transitions tracked at once. Without one a flood of prepares that
    /// never commit would grow the log without bound and turn recovery into work no
    /// restart could finish.
    capacity: usize = 1024,

    pub fn init(gpa: std.mem.Allocator) Journal {
        return .{ .gpa = gpa };
    }

    pub fn deinit(journal: *Journal) void {
        for (journal.entries.items) |entry| journal.gpa.free(entry.method);
        journal.entries.deinit(journal.gpa);
        journal.* = undefined;
    }

    fn find(journal: *Journal, correlation: Correlation) ?*Transition {
        for (journal.entries.items) |*entry| {
            if (entry.correlation == correlation) return entry;
        }
        return null;
    }

    /// Records the intent to apply a transition, before its effect is applied.
    ///
    /// Written first so a restart between here and the commit finds the transition
    /// in doubt and re-drives it, rather than losing it. Preparing a correlation
    /// already in flight is refused: the log must name one current intent per
    /// correlation, not two.
    pub fn prepare(
        journal: *Journal,
        correlation: Correlation,
        idempotency_key: u128,
        method: []const u8,
    ) Error!void {
        if (method.len > max_method_bytes) return error.MethodTooLong;
        if (journal.find(correlation) != null) return error.AlreadyInFlight;
        if (journal.entries.items.len >= journal.capacity) return error.Full;

        const owned = journal.gpa.dupe(u8, method) catch return error.Full;
        errdefer journal.gpa.free(owned);
        journal.entries.append(journal.gpa, .{
            .correlation = correlation,
            .idempotency_key = idempotency_key,
            .method = owned,
            .phase = .prepared,
        }) catch return error.Full;
    }

    /// Marks a prepared transition durably applied.
    ///
    /// After this the transition is finished and a restart ignores it. A commit for
    /// a correlation with no prepared entry is a no-op: a commit can only follow a
    /// prepare, and a duplicate must be harmless rather than an error.
    pub fn commit(journal: *Journal, correlation: Correlation) void {
        if (journal.find(correlation)) |entry| entry.phase = .committed;
    }

    /// Drops a prepared transition whose effect is known not to have been applied.
    ///
    /// This is the clean-failure counterpart to recovery: when a handler returns a
    /// fault synchronously, the effect definitely did not happen, so the intent is
    /// removed rather than left in doubt. The distinction matters — an in-doubt
    /// transition is one whose outcome is *unknown* after a crash and must be
    /// re-driven; an aborted one is *known* not to have applied and must not be.
    /// Aborting a committed transition is refused implicitly: only prepared entries
    /// are dropped, so a durable effect is never silently undone.
    pub fn abort(journal: *Journal, correlation: Correlation) void {
        for (journal.entries.items, 0..) |entry, index| {
            if (entry.correlation == correlation and entry.phase == .prepared) {
                journal.gpa.free(entry.method);
                _ = journal.entries.swapRemove(index);
                return;
            }
        }
    }

    /// Forgets a finished transition, freeing its slot.
    ///
    /// Called once a committed transition's effect has been acknowledged to the
    /// caller, so the bounded log does not fill with transitions that are long done.
    /// Forgetting a prepared transition is refused implicitly: only committed
    /// entries are eligible, so an in-doubt transition cannot be dropped before it
    /// is recovered.
    pub fn forget(journal: *Journal, correlation: Correlation) void {
        for (journal.entries.items, 0..) |entry, index| {
            if (entry.correlation == correlation and entry.phase == .committed) {
                journal.gpa.free(entry.method);
                _ = journal.entries.swapRemove(index);
                return;
            }
        }
    }

    /// The phase a correlation is in, or null if the journal holds no such
    /// transition.
    pub fn phaseOf(journal: *Journal, correlation: Correlation) ?Phase {
        const entry = journal.find(correlation) orelse return null;
        return entry.phase;
    }

    /// Whether any transition is in doubt: prepared but not committed. A service
    /// with none may resume immediately; one with any must recover first.
    pub fn hasInDoubt(journal: Journal) bool {
        for (journal.entries.items) |entry| {
            if (entry.phase == .prepared) return true;
        }
        return false;
    }

    /// Re-drives every in-doubt transition to completion and commits it.
    ///
    /// This is the recovery a restart runs before serving new requests. For each
    /// prepared-but-uncommitted transition, the driver re-applies the effect —
    /// safe because the method is idempotent under its key — and the transition is
    /// then committed. A driver that cannot re-apply one leaves it prepared and
    /// recovery reports the count still in doubt, so a transition is never silently
    /// dropped. After a run that returns zero, no transition is partial.
    pub fn recover(journal: *Journal, driver: Driver) usize {
        var still_in_doubt: usize = 0;
        for (journal.entries.items) |*entry| {
            if (entry.phase != .prepared) continue;
            if (driver.redrive(driver.context, entry.*)) {
                entry.phase = .committed;
            } else {
                still_in_doubt += 1;
            }
        }
        return still_in_doubt;
    }
};

/// Re-applies an in-doubt transition during recovery. The service supplies one
/// bound to its own state; `redrive` returns whether the effect was re-applied, so
/// a transition it cannot yet complete stays in doubt rather than being lost.
pub const Driver = struct {
    context: *anyopaque,
    redrive: *const fn (context: *anyopaque, transition: Transition) bool,
};

// --- Tests ---

test "a prepared transition is in doubt until it commits" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xAB, "capability.issue");
    try std.testing.expectEqual(Phase.prepared, journal.phaseOf(1).?);
    try std.testing.expect(journal.hasInDoubt());

    journal.commit(1);
    try std.testing.expectEqual(Phase.committed, journal.phaseOf(1).?);
    try std.testing.expect(!journal.hasInDoubt());
}

test "recovery re-drives an in-doubt transition and commits it" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    // Two transitions prepared; only the first committed before the "restart".
    try journal.prepare(1, 0xA1, "task.advance");
    journal.commit(1);
    try journal.prepare(2, 0xA2, "task.advance");
    // Correlation 2 is in doubt: prepared, never committed.

    const Redriver = struct {
        applied: std.ArrayListUnmanaged(Correlation) = .empty,
        fn redrive(context: *anyopaque, transition: Transition) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.applied.append(std.testing.allocator, transition.correlation) catch return false;
            return true;
        }
    };
    var redriver: Redriver = .{};
    defer redriver.applied.deinit(gpa);

    const remaining = journal.recover(.{ .context = &redriver, .redrive = Redriver.redrive });

    // Nothing left in doubt, only the uncommitted transition was re-driven, and it
    // is now committed like the one that finished before the restart.
    try std.testing.expectEqual(@as(usize, 0), remaining);
    try std.testing.expectEqual(@as(usize, 1), redriver.applied.items.len);
    try std.testing.expectEqual(@as(Correlation, 2), redriver.applied.items[0]);
    try std.testing.expectEqual(Phase.committed, journal.phaseOf(2).?);
    try std.testing.expect(!journal.hasInDoubt());
}

test "a committed transition is never re-driven by recovery" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "secret.seal");
    journal.commit(1);

    const Fail = struct {
        fn redrive(_: *anyopaque, _: Transition) bool {
            // Recovery must not call this for a committed transition.
            unreachable;
        }
    };
    var nothing: u8 = 0;
    const remaining = journal.recover(.{ .context = &nothing, .redrive = Fail.redrive });
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

test "a transition recovery cannot yet re-apply stays in doubt" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "policy.approve");

    const Refuse = struct {
        fn redrive(_: *anyopaque, _: Transition) bool {
            return false; // cannot re-apply right now
        }
    };
    var nothing: u8 = 0;
    const remaining = journal.recover(.{ .context = &nothing, .redrive = Refuse.redrive });

    // The transition is reported still in doubt and left prepared, not dropped.
    try std.testing.expectEqual(@as(usize, 1), remaining);
    try std.testing.expectEqual(Phase.prepared, journal.phaseOf(1).?);
}

test "preparing a correlation already in flight is refused" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "task.advance");
    try std.testing.expectError(error.AlreadyInFlight, journal.prepare(1, 0xA2, "task.advance"));
}

test "an over-long method name is refused before it is recorded" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    const long: [max_method_bytes + 1]u8 = @splat('m');
    try std.testing.expectError(error.MethodTooLong, journal.prepare(1, 0xA1, &long));
    try std.testing.expect(journal.phaseOf(1) == null);
}

test "the journal refuses to grow past its capacity" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    journal.capacity = 2;
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "m");
    try journal.prepare(2, 0xA2, "m");
    try std.testing.expectError(error.Full, journal.prepare(3, 0xA3, "m"));
}

test "forgetting a committed transition frees its slot but a prepared one stays" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    journal.capacity = 2;
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "m");
    journal.commit(1);
    try journal.prepare(2, 0xA2, "m");

    // The committed transition can be forgotten, freeing room again.
    journal.forget(1);
    try std.testing.expect(journal.phaseOf(1) == null);
    try journal.prepare(3, 0xA3, "m");

    // A prepared (in-doubt) transition cannot be forgotten: recovery must still see it.
    journal.forget(2);
    try std.testing.expectEqual(Phase.prepared, journal.phaseOf(2).?);
}

test "a handler that fails cleanly aborts its transition rather than leaving it in doubt" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "capability.issue");
    // The handler returned a fault: the effect never applied, so the intent is
    // dropped and there is nothing for recovery to re-drive.
    journal.abort(1);
    try std.testing.expect(journal.phaseOf(1) == null);
    try std.testing.expect(!journal.hasInDoubt());
}

test "abort will not drop a committed transition" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();

    try journal.prepare(1, 0xA1, "task.advance");
    journal.commit(1);
    journal.abort(1); // must not undo a durable effect
    try std.testing.expectEqual(Phase.committed, journal.phaseOf(1).?);
}

test "committing an unknown correlation is a harmless no-op" {
    const gpa = std.testing.allocator;
    var journal = Journal.init(gpa);
    defer journal.deinit();
    journal.commit(999); // no prepared entry; must not crash
    try std.testing.expect(journal.phaseOf(999) == null);
}
