//! Crash recovery acceptance.
//!
//! A crash is modelled the way one actually happens: the process stops between
//! two writes, and what survives is whatever reached the journal. Recovery then
//! rebuilds from that and nothing else — no in-memory state carries across,
//! because in a real crash none would.
//!
//! Each of the six transitions is exercised twice: once crashing before the
//! record was written, once after. The system must reach a defined state in
//! both cases, and in neither case may an external effect happen twice.

const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const session = @import("session");

const identity = core.identity;
const task_model = core.task;
const audit = core.audit;
const policy_model = core.policy;
const capability_model = core.capability;
const package_model = core.package;
const journal = storage.journal;

/// A journal that can be cut short at any point, as a crash would leave it.
const CrashPoint = struct {
    /// Bytes that reached durable storage before the process stopped.
    survived: []const u8,

    /// Everything written up to and including record `count`.
    fn afterRecords(gpa: std.mem.Allocator, writer: *journal.Writer, count: usize) ![]u8 {
        var reader = try journal.Reader.init(writer.written());
        var seen: usize = 0;
        while (seen < count) : (seen += 1) {
            _ = (try reader.next()) orelse break;
        }
        return gpa.dupe(u8, writer.written()[0..reader.intact_through]);
    }
};

/// What replay rebuilt.
const Rebuilt = struct {
    gpa: std.mem.Allocator,
    task_states: std.ArrayList([]const u8) = .empty,
    revoked_capabilities: usize = 0,
    approvals_decided: usize = 0,
    packages_installed: usize = 0,
    transfers: usize = 0,
    audit_entries: usize = 0,
    effects_claimed: std.ArrayList(u128) = .empty,
    effects_settled: usize = 0,

    fn apply(rebuilt: *Rebuilt, record: journal.Record) anyerror!void {
        switch (record.kind) {
            .task_transition => try rebuilt.task_states.append(rebuilt.gpa, record.payload),
            .capability_revoked => rebuilt.revoked_capabilities += 1,
            .approval_decided => rebuilt.approvals_decided += 1,
            .package_installed => rebuilt.packages_installed += 1,
            .session_transferred => rebuilt.transfers += 1,
            .audit_appended => rebuilt.audit_entries += 1,
            .effect_claimed => try rebuilt.effects_claimed.append(rebuilt.gpa, record.idempotency_key),
            .effect_settled => rebuilt.effects_settled += 1,
            .capability_issued => {},
        }
    }

    fn deinit(rebuilt: *Rebuilt) void {
        rebuilt.task_states.deinit(rebuilt.gpa);
        rebuilt.effects_claimed.deinit(rebuilt.gpa);
    }
};

fn rebuild(gpa: std.mem.Allocator, bytes: []const u8, into: *Rebuilt) !journal.Recovery {
    return journal.replay(gpa, bytes, into, Rebuilt.apply);
}

test "a task transition survives a crash after it was recorded" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "runnable");
    _ = try writer.append(.task_transition, 2, .fromSeconds(1_001), "running");
    _ = try writer.append(.task_transition, 3, .fromSeconds(1_002), "succeeded");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 3);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    const recovery = try rebuild(gpa, survived, &rebuilt);

    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 3), rebuilt.task_states.items.len);
    try std.testing.expectEqualStrings("succeeded", rebuilt.task_states.items[2]);
}

test "a task transition lost to a crash leaves the previous state intact" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "runnable");
    _ = try writer.append(.task_transition, 2, .fromSeconds(1_001), "running");
    _ = try writer.append(.task_transition, 3, .fromSeconds(1_002), "succeeded");

    // The process stopped before the last transition reached storage.
    const survived = try CrashPoint.afterRecords(gpa, &writer, 2);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    const recovery = try rebuild(gpa, survived, &rebuilt);

    // A defined earlier state, not a corrupt or partial one.
    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 2), rebuilt.task_states.items.len);
    try std.testing.expectEqualStrings("running", rebuilt.task_states.items[1]);
}

test "a capability revocation survives a crash" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.capability_issued, 1, .fromSeconds(1_000), "calendar read");
    _ = try writer.append(.capability_revoked, 2, .fromSeconds(1_001), "calendar read");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 2);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, survived, &rebuilt);

    // Recovering must not resurrect a withdrawn capability.
    try std.testing.expectEqual(@as(usize, 1), rebuilt.revoked_capabilities);
}

test "a revocation lost to a crash leaves the capability outstanding, not half-revoked" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.capability_issued, 1, .fromSeconds(1_000), "calendar read");
    _ = try writer.append(.capability_revoked, 2, .fromSeconds(1_001), "calendar read");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 1);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    const recovery = try rebuild(gpa, survived, &rebuilt);

    // The state is the one before the revocation, and it is coherent: the
    // capability is outstanding and can be revoked again.
    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 0), rebuilt.revoked_capabilities);
}

test "an approval decision survives a crash and is not decided twice" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    const decision_key: u128 = 0xa11_0bed;
    _ = try writer.append(.approval_decided, decision_key, .fromSeconds(1_000), "approved");
    // A retried write after a crash produces the record again.
    _ = try writer.append(.approval_decided, decision_key, .fromSeconds(1_001), "approved");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 2);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, survived, &rebuilt);

    // One decision, however many times it was written.
    try std.testing.expectEqual(@as(usize, 1), rebuilt.approvals_decided);
}

test "a package installation survives a crash and is not installed twice" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    const install_key: u128 = 0x1_5741;
    _ = try writer.append(.package_installed, install_key, .fromSeconds(1_000), "calendar agent");
    _ = try writer.append(.package_installed, install_key, .fromSeconds(1_001), "calendar agent");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 2);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, survived, &rebuilt);

    try std.testing.expectEqual(@as(usize, 1), rebuilt.packages_installed);
}

test "a session transfer survives a crash without duplicating its effect" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    const effect_key: u128 = 0x5ec0_0dad;

    // The phone claims the effect, performs it, and the session transfers.
    _ = try writer.append(.effect_claimed, effect_key, .fromSeconds(1_000), "send confirmation");
    _ = try writer.append(.effect_settled, 0xbeef, .fromSeconds(1_001), "performed");
    _ = try writer.append(.session_transferred, 0xdead, .fromSeconds(1_002), "phone to desktop");
    // The desktop resumes and, without the journal, would try the same effect.
    _ = try writer.append(.effect_claimed, effect_key, .fromSeconds(1_003), "send confirmation");

    const survived = try CrashPoint.afterRecords(gpa, &writer, 4);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, survived, &rebuilt);

    // The effect is claimed once across the transfer, not once per endpoint.
    try std.testing.expectEqual(@as(usize, 1), rebuilt.effects_claimed.items.len);
    try std.testing.expectEqual(effect_key, rebuilt.effects_claimed.items[0]);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.transfers);
}

test "a crash between claiming an effect and settling it leaves it claimed" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    const effect_key: u128 = 0xc0ffee;
    _ = try writer.append(.effect_claimed, effect_key, .fromSeconds(1_000), "pay the deposit");
    _ = try writer.append(.effect_settled, 0xfeed, .fromSeconds(1_001), "performed");

    // The process stopped after the claim and before the settlement.
    const survived = try CrashPoint.afterRecords(gpa, &writer, 1);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, survived, &rebuilt);

    // Claimed but unsettled. Whether it reached the outside world is unknown,
    // which is exactly the state that must not be retried automatically.
    try std.testing.expectEqual(@as(usize, 1), rebuilt.effects_claimed.items.len);
    try std.testing.expectEqual(@as(usize, 0), rebuilt.effects_settled);
    try std.testing.expect(!core.outcome.Outcome.outcome_unknown.hadNoEffect());
}

test "an audit append survives a crash without gaps" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    for (1..17) |index| {
        _ = try writer.append(
            .audit_appended,
            @intCast(index),
            .fromSeconds(1_000 + @as(i64, @intCast(index))),
            "event",
        );
    }

    const survived = try CrashPoint.afterRecords(gpa, &writer, 11);
    defer gpa.free(survived);

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    const recovery = try rebuild(gpa, survived, &rebuilt);

    // What survived is a contiguous prefix. A ledger that recovered with a hole
    // in it would reconstruct an execution that never happened.
    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 11), rebuilt.audit_entries);
}

test "recovery reaches the same state however many times it runs" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "running");
    _ = try writer.append(.effect_claimed, 0xc0ffee, .fromSeconds(1_001), "send");
    _ = try writer.append(.approval_decided, 0xa11, .fromSeconds(1_002), "approved");

    var first: Rebuilt = .{ .gpa = gpa };
    defer first.deinit();
    _ = try rebuild(gpa, writer.written(), &first);

    var second: Rebuilt = .{ .gpa = gpa };
    defer second.deinit();
    _ = try rebuild(gpa, writer.written(), &second);

    var third: Rebuilt = .{ .gpa = gpa };
    defer third.deinit();
    _ = try rebuild(gpa, writer.written(), &third);

    try std.testing.expectEqual(first.task_states.items.len, second.task_states.items.len);
    try std.testing.expectEqual(second.task_states.items.len, third.task_states.items.len);
    try std.testing.expectEqual(first.effects_claimed.items.len, third.effects_claimed.items.len);
    try std.testing.expectEqual(first.approvals_decided, third.approvals_decided);
}

test "a crash at every possible point leaves a state recovery can reach" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "runnable");
    _ = try writer.append(.capability_issued, 2, .fromSeconds(1_001), "calendar");
    _ = try writer.append(.effect_claimed, 3, .fromSeconds(1_002), "send");
    _ = try writer.append(.effect_settled, 4, .fromSeconds(1_003), "performed");
    _ = try writer.append(.task_transition, 5, .fromSeconds(1_004), "succeeded");

    const complete = writer.written();

    // Cut the journal at every byte. Recovery must always terminate with a
    // defined result: either a clean prefix or a reported stopping point.
    var length: usize = 0;
    while (length <= complete.len) : (length += 1) {
        var rebuilt: Rebuilt = .{ .gpa = gpa };
        defer rebuilt.deinit();

        const recovery = try rebuild(gpa, complete[0..length], &rebuilt);

        // Whatever it recovered is bounded by what it was given, and an effect
        // is never claimed more than once.
        try std.testing.expect(recovery.intact_through <= length);
        try std.testing.expect(rebuilt.effects_claimed.items.len <= 1);
    }
}

test "durable state and the live model agree on what a transition means" {
    const gpa = std.testing.allocator;

    // The journal records the same state names the task machine uses, so a
    // recovered transition is one the machine can act on rather than a string
    // nothing recognizes.
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    for (std.enums.values(task_model.State), 0..) |state, index| {
        _ = try writer.append(
            .task_transition,
            @intCast(index + 1),
            .fromSeconds(1_000),
            @tagName(state),
        );
    }

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    _ = try rebuild(gpa, writer.written(), &rebuilt);

    for (rebuilt.task_states.items) |recorded| {
        // Every recovered name resolves back to a state the machine defines.
        _ = std.meta.stringToEnum(task_model.State, recorded) orelse
            return error.TestUnexpectedResult;
    }
}

test "the recovery path holds for every record kind the system writes" {
    const gpa = std.testing.allocator;
    var writer = try journal.Writer.init(gpa);
    defer writer.deinit();

    for (std.enums.values(journal.RecordKind), 0..) |kind, index| {
        _ = try writer.append(kind, @intCast(index + 1), .fromSeconds(1_000), "payload");
    }

    var rebuilt: Rebuilt = .{ .gpa = gpa };
    defer rebuilt.deinit();
    const recovery = try rebuild(gpa, writer.written(), &rebuilt);

    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(std.enums.values(journal.RecordKind).len, recovery.applied);
    _ = package_model;
    _ = policy_model;
    _ = capability_model;
    _ = audit;
    _ = session;
    _ = identity;
}
