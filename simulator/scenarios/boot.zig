//! A boot, with a fault of the operator's choosing.
//!
//! The point of running this rather than reading the tests is that a boot
//! failure is something a person sees, not only something a test asserts. The
//! scenario walks the real chain, injects one fault, and reports both what the
//! device concluded and what it would have shown on its screen.
//!
//! Nothing here is a mock of the boot path. It is the boot path, given images
//! this scenario signed, so what the screen says is what the code decides.

const std = @import("std");
const boot = @import("boot");
const core = @import("core");

const Ed25519 = std.crypto.sign.Ed25519;

/// What goes wrong, if anything.
pub const Fault = enum {
    /// Nothing. The device boots.
    none,
    /// The bootloader was modified after it was signed. Caught early, where
    /// little of the device can be trusted to recover.
    tampered_bootloader,
    /// The control plane was modified. Caught late, where a recovery image can
    /// be loaded.
    tampered_control_plane,
    /// A genuine but older kernel is offered to a device that has already run a
    /// newer one.
    downgraded_kernel,
};

/// What the device has available when it has to choose.
pub const Available = struct {
    recovery_image_verified: bool = true,
    previous_slot_bootable: bool = true,
};

/// One stage, as it happened.
pub const Step = struct {
    stage: boot.chain.Stage,
    version: u32,
    /// Null when the stage was refused.
    digest: ?[boot.measurements.digest_bytes]u8,
    refusal: ?[]const u8,
};

pub const Report = struct {
    fault: Fault,
    steps: [3]Step,
    taken: usize,
    completed: bool,
    /// The value an attestation would quote.
    summary: [boot.measurements.digest_bytes]u8,
    recovery: ?boot.recovery.Outcome,
    /// What a person would read out to support. Empty when the device booted.
    ///
    /// Held as storage and a length rather than a slice: the report is returned
    /// by value, and a slice into its own storage would point at the copy that
    /// was left behind.
    code_storage: [16]u8 = undefined,
    code_length: usize = 0,
    /// What the device would show. Empty when it booted, because a device that
    /// booted shows its shell.
    screen: boot.early_ui.Surface,

    pub fn code(report: *const Report) []const u8 {
        return report.code_storage[0..report.code_length];
    }
};

const stage_contents = [_][]const u8{
    "the root of trust",
    "the bootloader",
    "the kernel",
    "the control plane",
};

/// Runs the boot.
pub fn run(fault: Fault, available: Available) !Report {
    var keys: [boot.chain.Stage.count]Ed25519.KeyPair = undefined;
    for (&keys, 0..) |*pair, index| {
        const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(@intCast(40 + index));
        pair.* = try .generateDeterministic(seed);
    }
    var public: [boot.chain.Stage.count][boot.verified.public_key_bytes]u8 = undefined;
    for (&public, keys) |*slot, pair| slot.* = pair.public_key.toBytes();

    var manual: core.time.ManualClock = .init(.fromSeconds(1_000));

    // A device that has already run a newer kernel, so the downgrade has
    // something to be refused against.
    var floors: boot.chain.Floors = .{};
    if (fault == .downgraded_kernel) floors.raise(@intFromEnum(boot.chain.Stage.kernel), 5);

    var chain: boot.chain.Chain = .init(manual.clock(), public, floors);

    var report: Report = .{
        .fault = fault,
        .steps = undefined,
        .taken = 0,
        .completed = false,
        .summary = undefined,
        .recovery = null,
        .screen = .{},
    };

    const order = [_]boot.chain.Stage{ .bootloader, .kernel, .control_plane };
    for (order) |stage| {
        const index = @intFromEnum(stage);
        const version: u32 = if (stage == .kernel and fault == .downgraded_kernel) 2 else 7;
        const contents = stage_contents[index];

        const digest = boot.measurements.digestOf(contents);
        const signature = try keys[index].sign(&digest, null);
        var staged: boot.chain.StageImage = .{
            .stage = stage,
            .image = .{
                .contents = contents,
                .version = version,
                .signature = signature.toBytes(),
            },
        };

        // Modification after signing: the contents change, the signature does
        // not, which is exactly what tampering looks like.
        const tampered = switch (fault) {
            .tampered_bootloader => stage == .bootloader,
            .tampered_control_plane => stage == .control_plane,
            else => false,
        };
        if (tampered) staged.image.contents = "a modified stage";

        if (chain.advance(staged)) {
            report.steps[report.taken] = .{
                .stage = stage,
                .version = version,
                .digest = boot.measurements.digestOf(staged.image.contents),
                .refusal = null,
            };
            report.taken += 1;
        } else |refusal| {
            report.steps[report.taken] = .{
                .stage = stage,
                .version = version,
                .digest = null,
                .refusal = @errorName(refusal),
            };
            report.taken += 1;
            break;
        }
    }

    report.completed = chain.isComplete();
    report.summary = chain.summary();
    report.recovery = chain.recoveryOutcome(.{
        .recovery_image_verified = available.recovery_image_verified,
        .previous_slot_bootable = available.previous_slot_bootable,
    });

    if (report.recovery) |outcome| {
        // The code identifies this failure without saying anything a person
        // holding the device could not already read off it.
        const written = std.fmt.bufPrint(
            &report.code_storage,
            "{x}",
            .{report.summary[0..4]},
        ) catch unreachable;
        report.code_length = written.len;
        report.screen = boot.early_ui.render(.{ .halted = .{
            .failure = failureFor(report.steps[report.taken - 1].refusal.?),
            .outcome = outcome,
            .code = written,
        } });
    }

    return report;
}

/// Maps the chain's refusal back to what the screen needs to say.
fn failureFor(name: []const u8) boot.recovery.Failure {
    if (std.mem.eql(u8, name, "RollbackRefused")) return .rollback_refused;
    if (std.mem.eql(u8, name, "OutOfOrder")) return .out_of_order;
    if (std.mem.eql(u8, name, "LogFull")) return .unmeasurable;
    return .signature_rejected;
}

test "a device with no fault boots and shows no failure screen" {
    const report = try run(.none, .{});
    try std.testing.expect(report.completed);
    try std.testing.expectEqual(@as(usize, 3), report.taken);
    try std.testing.expectEqual(@as(?boot.recovery.Outcome, null), report.recovery);
    try std.testing.expectEqual(@as(usize, 0), report.screen.lines().len);
}

test "a tampered bootloader stops early and falls back to the previous slot" {
    const report = try run(.tampered_bootloader, .{});
    try std.testing.expect(!report.completed);
    try std.testing.expectEqual(@as(usize, 1), report.taken);
    try std.testing.expectEqual(boot.recovery.Outcome.previous_slot, report.recovery.?);
    try std.testing.expect(report.screen.contains("previous version"));
}

test "a tampered control plane reaches recovery" {
    const report = try run(.tampered_control_plane, .{});
    try std.testing.expect(!report.completed);
    try std.testing.expectEqual(@as(usize, 3), report.taken);
    try std.testing.expectEqual(boot.recovery.Outcome.boot_recovery_image, report.recovery.?);
}

test "a downgraded kernel is refused" {
    const report = try run(.downgraded_kernel, .{});
    try std.testing.expect(!report.completed);
    try std.testing.expectEqualStrings("RollbackRefused", report.steps[1].refusal.?);
    try std.testing.expect(report.screen.contains("older"));
}

test "a device with nothing to fall back on halts and shows a code" {
    const report = try run(.tampered_bootloader, .{
        .recovery_image_verified = false,
        .previous_slot_bootable = false,
    });
    try std.testing.expectEqual(boot.recovery.Outcome.halt, report.recovery.?);
    try std.testing.expect(report.screen.contains("servicing"));
    try std.testing.expect(report.code().len > 0);
    try std.testing.expect(report.screen.contains(report.code()));
}

test "a device that booted has no code to quote" {
    const report = try run(.none, .{});
    try std.testing.expectEqual(@as(usize, 0), report.code().len);
}

test "only the stages that were accepted are measured" {
    const report = try run(.tampered_control_plane, .{});
    // The refused stage is reported as a step, because a person needs to see
    // where it stopped, but it carries no digest: it was never measured.
    try std.testing.expect(report.steps[0].digest != null);
    try std.testing.expect(report.steps[1].digest != null);
    try std.testing.expect(report.steps[2].digest == null);
}

test "a failed boot never summarizes to the same value as a successful one" {
    const booted = try run(.none, .{});
    const stopped = try run(.tampered_control_plane, .{});
    try std.testing.expect(!std.mem.eql(u8, &booted.summary, &stopped.summary));
}

test "every fault produces a report" {
    for (std.enums.values(Fault)) |fault| {
        const report = try run(fault, .{});
        try std.testing.expect(report.taken > 0);
        // A device either booted or has something to show. Never neither.
        try std.testing.expect(report.completed or report.screen.lines().len > 0);
    }
}

test "the code survives the report being copied" {
    // The report is returned by value and passed on by value again. A code that
    // pointed into the report it was built in would read whatever the copy left
    // behind.
    const original = try run(.tampered_bootloader, .{
        .recovery_image_verified = false,
        .previous_slot_bootable = false,
    });
    const copied = original;
    try std.testing.expectEqualStrings(original.code(), copied.code());
    try std.testing.expect(copied.screen.contains(copied.code()));
}
