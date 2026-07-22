//! An update that goes wrong, and a device that comes back.
//!
//! The point of running this rather than reading the update tests is that a
//! rollback is something an owner lives through, not only a state transition an
//! assertion checks. The scenario installs an image, boots it, and — when the
//! new image is the kind that hangs — watches the device try it, fail, and
//! return to the version that worked, without ever being unable to boot.
//!
//! Nothing here is a mock of the updater. It is the updater, driven through the
//! same calls a real install path makes, so the slot the device ends on is the
//! slot the code chose.

const std = @import("std");
const core = @import("core");

const update = core.update;
const Ed25519 = std.crypto.sign.Ed25519;

/// What the new image does once it is selected.
pub const Outcome = enum {
    /// It boots and reaches a working state. The update commits.
    boots_cleanly,
    /// It boots but never starts correctly, the way a hang looks to a
    /// watchdog. The device returns to the slot that worked.
    hangs_on_start,
    /// It is a genuine but older image, refused before it is ever written.
    is_a_downgrade,
    /// Its contents were damaged in storage after signing, caught before the
    /// device commits to it.
    is_corrupt,
};

/// One moment in the update, as it happened.
pub const Step = struct {
    /// Always a string with static storage, so the report can be returned by
    /// value and rendered afterwards without a label pointing at a stack frame
    /// that no longer exists.
    label: []const u8,
    /// Which slot the device would boot if the power were cut right here.
    boot_slot: update.Slot,
    /// Whether the device can boot at all at this moment. Must never be false.
    bootable: bool,
};

pub const Report = struct {
    outcome: Outcome,
    steps: [8]Step,
    taken: usize,
    /// The version the device is running once the dust settles.
    running_major: u32,
    running_minor: u32,
    /// Whether the update was kept. False is a correct result for three of the
    /// four outcomes.
    committed: bool,
    /// Whether some slot was bootable at every step. The invariant the whole
    /// two-slot design exists to hold.
    never_unbootable: bool,
    /// Set when the install refused before writing anything.
    refused: ?[]const u8,
};

const device_class = "reference-handset";

const running: update.Version = .{
    .major = 2,
    .minor = 0,
    .patch = 0,
    .security_generation = 1,
};

/// Runs the update and reports what the device did.
pub fn run(outcome: Outcome) !Report {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(51));

    var manual: core.time.ManualClock = .init(.fromSeconds(1_000));
    var shipped_digest: [update.digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the shipped image", &shipped_digest, .{});

    var updater: update.Updater = .init(
        manual.clock(),
        key_pair.public_key.toBytes(),
        device_class,
        running,
        shipped_digest,
    );

    var report: Report = .{
        .outcome = outcome,
        .steps = undefined,
        .taken = 0,
        .running_major = running.major,
        .running_minor = running.minor,
        .committed = false,
        .never_unbootable = true,
        .refused = null,
    };

    record(&report, &updater, "before the update");

    // A downgrade offers an older version; every other case offers a newer one.
    const offered_version: update.Version = if (outcome == .is_a_downgrade)
        .{ .major = 1, .minor = 9, .patch = 0, .security_generation = 1 }
    else
        .{ .major = 2, .minor = 1, .patch = 0, .security_generation = 1 };

    const contents = "the next system image";
    const image = imageOf(key_pair, contents, offered_version);

    // Staging verifies before it writes, so a downgrade never reaches a slot.
    _ = updater.stage(image, contents) catch |failure| {
        report.refused = @errorName(failure);
        record(&report, &updater, "install refused");
        finish(&report, &updater);
        return report;
    };
    record(&report, &updater, "staging into the spare slot");

    // Corruption in storage between staging and the pre-commit check: the
    // contents no longer match what was signed.
    const finish_contents = if (outcome == .is_corrupt) "the next system imagX" else contents;
    updater.finishStaging(image, finish_contents) catch |failure| {
        report.refused = @errorName(failure);
        record(&report, &updater, "damaged image refused before commit");
        finish(&report, &updater);
        return report;
    };
    record(&report, &updater, "spare slot written and verified");

    try updater.selectForNextBoot();
    record(&report, &updater, "spare slot selected for next boot");

    switch (outcome) {
        .boots_cleanly => {
            try updater.confirmBoot();
            record(&report, &updater, "new image booted and started");
        },
        .hangs_on_start => {
            // The watchdog reports failure until the update is abandoned. The
            // labels are static rather than formatted per attempt: a label
            // pointing into a loop-local buffer would dangle by the time the
            // report is rendered.
            const attempt_labels = [_][]const u8{
                "boot attempt 1 failed",
                "boot attempt 2 failed",
                "boot attempt 3 failed",
                "boot attempt failed",
            };
            for (0..update.max_boot_attempts) |attempt| {
                updater.reportBootFailure() catch break;
                const label = attempt_labels[@min(attempt, attempt_labels.len - 1)];
                record(&report, &updater, label);
            }
            record(&report, &updater, "returned to the working slot");
        },
        // Handled before selection; unreachable once staging succeeded.
        .is_a_downgrade, .is_corrupt => unreachable,
    }

    finish(&report, &updater);
    return report;
}

fn record(report: *Report, updater: *const update.Updater, label: []const u8) void {
    if (report.taken >= report.steps.len) return;
    const bootable = updater.hasBootableSlot();
    if (!bootable) report.never_unbootable = false;
    report.steps[report.taken] = .{
        .label = label,
        .boot_slot = updater.nextBootSlot(),
        .bootable = bootable,
    };
    report.taken += 1;
}

fn finish(report: *Report, updater: *const update.Updater) void {
    report.committed = updater.currentStage() == .committed;
    if (updater.runningVersion()) |version| {
        report.running_major = version.major;
        report.running_minor = version.minor;
    }
}

fn imageOf(key_pair: Ed25519.KeyPair, contents: []const u8, version: update.Version) update.Image {
    var digest: [update.digest_bytes]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const signature = key_pair.sign(&digest, null) catch unreachable;
    return update.Image.ofContents(contents, version, device_class, signature.toBytes());
}

test "a clean update commits and runs the new version" {
    const report = try run(.boots_cleanly);
    try std.testing.expect(report.committed);
    try std.testing.expectEqual(@as(u32, 2), report.running_major);
    try std.testing.expectEqual(@as(u32, 1), report.running_minor);
    try std.testing.expect(report.never_unbootable);
    try std.testing.expectEqual(@as(?[]const u8, null), report.refused);
}

test "an image that hangs is abandoned and the working version returns" {
    const report = try run(.hangs_on_start);
    try std.testing.expect(!report.committed);

    // Back on the version that shipped, not stranded on the one that hangs.
    try std.testing.expectEqual(@as(u32, 2), report.running_major);
    try std.testing.expectEqual(@as(u32, 0), report.running_minor);
    try std.testing.expect(report.never_unbootable);
}

test "a downgrade is refused before anything is written" {
    const report = try run(.is_a_downgrade);
    try std.testing.expect(!report.committed);
    try std.testing.expect(report.refused != null);

    // Still on the shipped version, because the older image never reached a
    // slot.
    try std.testing.expectEqual(@as(u32, 2), report.running_major);
    try std.testing.expectEqual(@as(u32, 0), report.running_minor);
    try std.testing.expect(report.never_unbootable);
}

test "a corrupt image is refused before the device commits to it" {
    const report = try run(.is_corrupt);
    try std.testing.expect(!report.committed);
    try std.testing.expect(report.refused != null);
    try std.testing.expectEqual(@as(u32, 2), report.running_major);
    try std.testing.expect(report.never_unbootable);
}

test "the device can boot at every moment of every outcome" {
    // The invariant the two-slot design exists to hold: whatever goes wrong,
    // and whenever the power is cut, some slot boots.
    for (std.enums.values(Outcome)) |outcome| {
        const report = try run(outcome);
        try std.testing.expect(report.never_unbootable);
        for (report.steps[0..report.taken]) |step| {
            try std.testing.expect(step.bootable);
        }
    }
}

test "only a clean boot commits the update" {
    // Three of the four outcomes must leave the update uncommitted. A design
    // that committed on anything less than a confirmed boot would strand a
    // device on an image that does not work.
    try std.testing.expect((try run(.boots_cleanly)).committed);
    try std.testing.expect(!(try run(.hangs_on_start)).committed);
    try std.testing.expect(!(try run(.is_a_downgrade)).committed);
    try std.testing.expect(!(try run(.is_corrupt)).committed);
}

test "there is a static label for every boot attempt" {
    // If max_boot_attempts grew past the static list, a run would fall back to
    // the generic label rather than reading past the array, but the specific
    // labels should keep pace. This catches the list going stale.
    try std.testing.expect(update.max_boot_attempts <= 3);
}

test "the spare slot is what boots while an update is pending" {
    // Between selection and confirmation the device boots the new slot. A
    // clean run passes through that state on its way to committing.
    const report = try run(.boots_cleanly);
    var saw_spare_selected = false;
    for (report.steps[0..report.taken]) |step| {
        if (std.mem.eql(u8, step.label, "spare slot selected for next boot")) {
            try std.testing.expectEqual(update.Slot.secondary, step.boot_slot);
            saw_spare_selected = true;
        }
    }
    try std.testing.expect(saw_spare_selected);
}
