//! Planning a store's move from one format version to another one step at a time,
//! so an upgrade never skips a transformation and never runs backwards.
//!
//! A persistent store's on-disk layout changes as the system evolves, and each
//! change ships with a migration that rewrites the old layout into the new one. The
//! danger is in how those migrations are chained. A device that has been off for a
//! year may boot several versions behind, and its store must be brought forward
//! through every intervening migration in order — skip one and a later migration
//! runs against a layout it was never written for, corrupting the store it meant to
//! upgrade. Running a migration backwards is worse still: a downgrade rewrites new
//! data into an old shape that cannot hold it, losing whatever the new version
//! added. So a migration plan is a contiguous ascending chain from where the store
//! is to where it needs to be, with no gap and no reversal, and if such a chain
//! does not exist the store is left untouched rather than half-migrated.
//!
//! This module migrates nothing. It validates a set of migration steps and plans
//! the ordered path from a current version to a target, refusing a downgrade or a
//! missing step, as pure functions over the step set.

const std = @import("std");

/// A store format version. Monotonic: a higher number is a later layout.
pub const Version = u16;

/// One migration step: it rewrites a store from version `from` to `from + 1`. Each
/// step advances exactly one version, so the chain has no ambiguity about order.
pub const Step = struct {
    from: Version,
    to: Version,

    fn advancesOne(step: Step) bool {
        return step.to == step.from + 1;
    }
};

/// Why a chain of steps was rejected as invalid.
pub const ChainError = error{
    /// A step does not advance exactly one version. Steps must be single-version so
    /// the plan is unambiguous.
    StepNotSingleVersion,
    /// Two steps start from the same version, so which one applies is ambiguous.
    DuplicateStep,
};

/// Why a plan could not be formed.
pub const PlanError = error{
    /// The target is below the current version: a downgrade, which would lose data
    /// the newer layout holds.
    Downgrade,
    /// No step rewrites some version between current and target: the chain has a
    /// gap, and skipping it would corrupt the store.
    MissingStep,
    /// The plan needs more steps than the output buffer holds.
    PlanTooLong,
};

/// The registered set of migration steps.
pub const Chain = struct {
    steps: []const Step,

    /// Checks that the chain is well formed: every step advances exactly one
    /// version and no two steps start from the same version. A chain that fails
    /// this is a build error, caught before any migration runs.
    pub fn validate(chain: Chain) ChainError!void {
        for (chain.steps, 0..) |step, index| {
            if (!step.advancesOne()) return ChainError.StepNotSingleVersion;
            for (chain.steps[index + 1 ..]) |other| {
                if (other.from == step.from) return ChainError.DuplicateStep;
            }
        }
    }

    fn stepFrom(chain: Chain, version: Version) ?Step {
        for (chain.steps) |step| {
            if (step.from == version) return step;
        }
        return null;
    }

    /// Plans the ordered steps to move a store from `current` to `target`.
    ///
    /// A target below the current version is a downgrade and is refused outright. A
    /// target equal to the current version needs no steps. Otherwise the plan walks
    /// one version at a time from current to target, requiring a step out of every
    /// version along the way; a missing step is a gap that would corrupt the store,
    /// so the whole plan is refused rather than partially applied. The steps are
    /// written into `out` in the order they must run.
    pub fn plan(chain: Chain, current: Version, target: Version, out: []Step) PlanError![]const Step {
        if (target < current) return PlanError.Downgrade;
        var version = current;
        var count: usize = 0;
        while (version < target) : (version += 1) {
            const step = chain.stepFrom(version) orelse return PlanError.MissingStep;
            if (count >= out.len) return PlanError.PlanTooLong;
            out[count] = step;
            count += 1;
        }
        return out[0..count];
    }

    /// Whether a store at `current` can be migrated to `target` at all.
    pub fn canMigrate(chain: Chain, current: Version, target: Version) bool {
        var scratch: [256]Step = undefined;
        _ = chain.plan(current, target, &scratch) catch return false;
        return true;
    }
};

const sample_chain: Chain = .{ .steps = &.{
    .{ .from = 1, .to = 2 },
    .{ .from = 2, .to = 3 },
    .{ .from = 3, .to = 4 },
} };

test "a valid chain validates" {
    try sample_chain.validate();
}

test "a plan across several versions lists every step in order" {
    var out: [8]Step = undefined;
    const steps = try sample_chain.plan(1, 4, &out);
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqual(@as(Version, 1), steps[0].from);
    try std.testing.expectEqual(@as(Version, 2), steps[1].from);
    try std.testing.expectEqual(@as(Version, 3), steps[2].from);
}

test "a store already at the target needs no steps" {
    var out: [8]Step = undefined;
    const steps = try sample_chain.plan(4, 4, &out);
    try std.testing.expectEqual(@as(usize, 0), steps.len);
}

test "a downgrade is refused" {
    var out: [8]Step = undefined;
    try std.testing.expectError(PlanError.Downgrade, sample_chain.plan(4, 2, &out));
}

test "a gap in the chain refuses the whole plan" {
    // A chain missing the 2->3 step cannot carry a store from 1 to 4.
    const gapped: Chain = .{ .steps = &.{
        .{ .from = 1, .to = 2 },
        .{ .from = 3, .to = 4 },
    } };
    var out: [8]Step = undefined;
    try std.testing.expectError(PlanError.MissingStep, gapped.plan(1, 4, &out));
}

test "a step that advances more than one version is rejected" {
    const bad: Chain = .{ .steps = &.{.{ .from = 1, .to = 3 }} };
    try std.testing.expectError(ChainError.StepNotSingleVersion, bad.validate());
}

test "duplicate steps from the same version are rejected" {
    const ambiguous: Chain = .{ .steps = &.{
        .{ .from = 1, .to = 2 },
        .{ .from = 1, .to = 2 },
    } };
    try std.testing.expectError(ChainError.DuplicateStep, ambiguous.validate());
}

test "a plan longer than the buffer is refused rather than truncated" {
    var out: [1]Step = undefined;
    try std.testing.expectError(PlanError.PlanTooLong, sample_chain.plan(1, 4, &out));
}

test "canMigrate reports reachability" {
    try std.testing.expect(sample_chain.canMigrate(1, 4));
    try std.testing.expect(sample_chain.canMigrate(2, 2));
    try std.testing.expect(!sample_chain.canMigrate(4, 1)); // downgrade
    const gapped: Chain = .{ .steps = &.{.{ .from = 1, .to = 2 }} };
    try std.testing.expect(!gapped.canMigrate(1, 4)); // gap
}

test "a plan is always a contiguous ascending chain, swept" {
    // The correctness property: for every reachable target, the planned steps run
    // from current upward with no gap and no repeat.
    var target: Version = 1;
    while (target <= 4) : (target += 1) {
        var out: [8]Step = undefined;
        const steps = try sample_chain.plan(1, target, &out);
        var expected: Version = 1;
        for (steps) |step| {
            try std.testing.expectEqual(expected, step.from);
            try std.testing.expectEqual(expected + 1, step.to);
            expected += 1;
        }
        try std.testing.expectEqual(target, expected);
    }
}
