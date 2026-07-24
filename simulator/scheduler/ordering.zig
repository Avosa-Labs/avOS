//! Deciding which ready task the simulator runs next, so scheduling is a total, deterministic order
//! that does not depend on how tasks happened to be inserted.
//!
//! On a real device the order in which ready tasks run can depend on timing, core count, and a dozen
//! nondeterministic factors, and that is fine because the platform's correctness does not rest on a
//! particular order. In the simulator it is not fine: if the next ready task were chosen by insertion
//! accident or host timing, the same scenario would explore different interleavings on different runs,
//! and a bug that appears in one ordering would vanish in another, unreproducibly. So the simulator
//! imposes a total order on ready tasks and always runs the smallest under it — here, the lowest task
//! id among those ready. The choice of key is almost arbitrary; what matters is that it is total and
//! stable, so a given set of ready tasks always yields the same next task, and a scenario replayed
//! observes the identical interleaving. Deterministic selection is what lets the simulator's runs be
//! compared, replayed, and trusted as evidence.
//!
//! This module runs no task. It decides which ready task is next under the total order, from the set of
//! ready task ids, as a pure function.

const std = @import("std");

/// Selects the next ready task: the one with the lowest id, the simulator's total order.
///
/// Among the ready tasks, the smallest id is chosen. The result does not depend on the order the ids
/// were provided in — the same set always yields the same next task — which is what makes scheduling
/// reproducible. An empty ready set has no next task and returns null.
pub fn next(ready: []const u64) ?u64 {
    if (ready.len == 0) return null;
    var lowest = ready[0];
    for (ready[1..]) |id| {
        if (id < lowest) lowest = id;
    }
    return lowest;
}

test "the lowest ready id runs next" {
    try std.testing.expectEqual(@as(?u64, 2), next(&.{ 5, 2, 9 }));
}

test "an empty ready set has no next task" {
    try std.testing.expectEqual(@as(?u64, null), next(&.{}));
}

test "selection is independent of insertion order" {
    // The same set in two orders yields the same next task.
    try std.testing.expectEqual(next(&.{ 9, 2, 5 }), next(&.{ 2, 5, 9 }));
    try std.testing.expectEqual(next(&.{ 5, 9, 2 }), next(&.{ 2, 9, 5 }));
}

test "the selected task is the minimum of the ready set, swept" {
    // The total-order property: whatever the arrangement, the next task is no greater than any ready
    // task.
    const arrangements = [_][]const u64{
        &.{ 3, 1, 4, 1, 5 },
        &.{ 5, 4, 3, 1, 1 },
        &.{ 1, 1, 3, 4, 5 },
    };
    for (arrangements) |ready| {
        const chosen = next(ready).?;
        for (ready) |id| {
            try std.testing.expect(chosen <= id);
        }
    }
}
