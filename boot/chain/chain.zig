//! The boot chain.
//!
//! Each stage verifies the next before handing control to it, and measures it
//! before it does. A stage that cannot verify what comes next stops rather than
//! continuing: a boot that proceeds past a failed verification has verified
//! nothing, because the check was advisory.
//!
//! Measurement happens before control is handed over, so the log describes what
//! ran even when what ran then fails. A log written afterwards would be written
//! by the stage it is supposed to describe.
//!
//! The root of trust is not established here. It is whatever the hardware
//! provides, and this module takes it as given: a chain that could establish its
//! own root would be a chain an attacker could re-root.

const std = @import("std");
const core = @import("core");
const measurements = @import("../measurements/measurements.zig");
const recovery = @import("../recovery/recovery.zig");
const verified = @import("../verified/verified.zig");

pub const Error = error{
    /// The stage was reached out of order.
    OutOfOrder,
} || verified.Error || measurements.Error;

/// The stages, in the order they run.
///
/// The order is fixed, so a stage cannot be skipped by arranging for it to be
/// reached out of turn.
pub const Stage = enum(u8) {
    /// Immutable, provided by hardware. Verifies the bootloader.
    root_of_trust = 0,
    /// Verifies the kernel.
    bootloader = 1,
    /// Verifies the trusted control plane. The first stage from which a
    /// recovery image can be located and loaded.
    kernel = 2,
    /// The first stage that can refuse to run for policy reasons.
    control_plane = 3,

    pub const count = std.enums.values(Stage).len;

    pub fn next(stage: Stage) ?Stage {
        return switch (stage) {
            .root_of_trust => .bootloader,
            .bootloader => .kernel,
            .kernel => .control_plane,
            .control_plane => null,
        };
    }

    /// Whether this stage is fixed in hardware, and therefore neither verified
    /// by anything above it nor replaceable by anything the device does to
    /// itself.
    pub fn isImmutable(stage: Stage) bool {
        return stage == .root_of_trust;
    }

    /// Whether a recovery image can be located and loaded from here.
    fn recoveryDepth(stage: Stage) recovery.Depth {
        return switch (stage) {
            .root_of_trust, .bootloader => .before_recovery_is_loadable,
            .kernel, .control_plane => .after_recovery_is_loadable,
        };
    }
};

/// A stage as presented to the one before it.
pub const StageImage = struct {
    stage: Stage,
    image: verified.Image,
};

/// The anti-rollback floors the device carries between boots.
pub const Floors = verified.Floors(Stage.count);

/// Verifies and measures each stage as the device starts.
pub const Chain = struct {
    clock: core.time.Clock,
    /// The key each stage is verified against. On a real device these differ per
    /// stage and the earliest is fused; here they are supplied.
    stage_keys: [Stage.count][verified.public_key_bytes]u8,
    /// Persisted across boots. A floor the running system could lower would not
    /// be a floor.
    floors: Floors,
    log: measurements.Log = .{},
    /// The last stage that completed verification.
    reached: Stage = .root_of_trust,
    /// Set when the chain stopped rather than completing.
    halted_by: ?Error = null,

    pub fn init(
        clock: core.time.Clock,
        stage_keys: [Stage.count][verified.public_key_bytes]u8,
        floors: Floors,
    ) Chain {
        return .{ .clock = clock, .stage_keys = stage_keys, .floors = floors };
    }

    /// Verifies the next stage, measures it, and hands control to it.
    ///
    /// Returns an error rather than a verdict the caller could ignore.
    pub fn advance(chain: *Chain, staged: StageImage) Error!void {
        chain.attempt(staged) catch |failure| {
            chain.halted_by = failure;
            return failure;
        };
    }

    fn attempt(chain: *Chain, staged: StageImage) Error!void {
        const expected = chain.reached.next() orelse return error.OutOfOrder;
        if (staged.stage != expected) return error.OutOfOrder;

        const index = @intFromEnum(staged.stage);
        const digest = try verified.verify(
            staged.image,
            chain.stage_keys[index],
            chain.floors.forStage(index),
        );

        // Measured before control is handed over, so the log describes what ran
        // even if it then fails.
        try chain.log.record(.{
            .stage = @intFromEnum(staged.stage),
            .digest = digest,
            .version = staged.image.version,
            .measured_at = chain.clock.wall(),
        });

        chain.floors.raise(index, staged.image.version);
        chain.reached = staged.stage;
    }

    /// Whether the chain completed.
    pub fn isComplete(chain: Chain) bool {
        return chain.reached == .control_plane and chain.halted_by == null;
    }

    pub fn hasHalted(chain: Chain) bool {
        return chain.halted_by != null;
    }

    /// The measurements taken this boot, in order.
    pub fn taken(chain: *const Chain) []const measurements.Measurement {
        return chain.log.taken();
    }

    /// A single value summarizing everything measured, suitable for quoting in
    /// an attestation.
    pub fn summary(chain: *const Chain) [measurements.digest_bytes]u8 {
        return chain.log.summary();
    }

    /// What to do, when the chain stopped.
    ///
    /// Returns null when it did not: a device that booted has nothing to
    /// recover from, and asking must not produce an answer that looks like one.
    pub fn recoveryOutcome(chain: Chain, available: recovery.Available) ?recovery.Outcome {
        const failure = chain.halted_by orelse return null;
        return recovery.choose(
            switch (failure) {
                error.SignatureRejected => .signature_rejected,
                error.RollbackRefused => .rollback_refused,
                error.OutOfOrder => .out_of_order,
                error.LogFull => .unmeasurable,
            },
            // The stage that failed is the one after the last one reached.
            (chain.reached.next() orelse chain.reached).recoveryDepth(),
            available,
        );
    }
};

const Fixture = struct {
    const Ed25519 = std.crypto.sign.Ed25519;

    manual: core.time.ManualClock,
    keys: [Stage.count]Ed25519.KeyPair,
    chain: Chain,

    fn init(fixture: *Fixture) !void {
        fixture.* = .{
            .manual = .init(.fromSeconds(1_000)),
            .keys = undefined,
            .chain = undefined,
        };
        for (&fixture.keys, 0..) |*pair, index| {
            const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(@intCast(40 + index));
            pair.* = try .generateDeterministic(seed);
        }

        var public: [Stage.count][verified.public_key_bytes]u8 = undefined;
        for (&public, fixture.keys) |*slot, pair| slot.* = pair.public_key.toBytes();

        fixture.chain = .init(fixture.manual.clock(), public, .{});
    }

    fn staged(
        fixture: *Fixture,
        stage: Stage,
        contents: []const u8,
        version: u32,
    ) !StageImage {
        const digest = measurements.digestOf(contents);
        const signature = try fixture.keys[@intFromEnum(stage)].sign(&digest, null);
        return .{
            .stage = stage,
            .image = .{
                .contents = contents,
                .version = version,
                .signature = signature.toBytes(),
            },
        };
    }

    fn boot(fixture: *Fixture) !void {
        try fixture.chain.advance(try fixture.staged(.bootloader, "the bootloader", 1));
        try fixture.chain.advance(try fixture.staged(.kernel, "the kernel", 1));
        try fixture.chain.advance(try fixture.staged(.control_plane, "the control plane", 1));
    }
};

const everything: recovery.Available = .{
    .recovery_image_verified = true,
    .previous_slot_bootable = true,
};

test "a chain of verified stages completes" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.boot();

    try std.testing.expect(fixture.chain.isComplete());
    try std.testing.expect(!fixture.chain.hasHalted());
    try std.testing.expectEqual(@as(usize, 3), fixture.chain.taken().len);
}

test "a stage that fails verification stops the boot and is not measured" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    var tampered = try fixture.staged(.bootloader, "the bootloader", 1);
    tampered.image.signature[0] ^= 0xff;

    try std.testing.expectError(error.SignatureRejected, fixture.chain.advance(tampered));
    try std.testing.expect(fixture.chain.hasHalted());
    try std.testing.expect(!fixture.chain.isComplete());
    try std.testing.expectEqual(@as(usize, 0), fixture.chain.taken().len);
}

test "the chain does not advance past a stage it refused" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    var tampered = try fixture.staged(.bootloader, "the bootloader", 1);
    tampered.image.signature[0] ^= 0xff;
    _ = fixture.chain.advance(tampered) catch {};

    // Offering the next stage after a refusal must not let the refused one be
    // skipped over.
    try std.testing.expectError(
        error.OutOfOrder,
        fixture.chain.advance(try fixture.staged(.kernel, "the kernel", 1)),
    );
}

test "stages cannot be skipped or reordered" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);

    // Jumping to the kernel would skip the bootloader's verification of it.
    try std.testing.expectError(
        error.OutOfOrder,
        fixture.chain.advance(try fixture.staged(.kernel, "the kernel", 1)),
    );
    try std.testing.expect(fixture.chain.hasHalted());
}

test "the chain cannot advance past its final stage" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.boot();

    try std.testing.expectError(
        error.OutOfOrder,
        fixture.chain.advance(try fixture.staged(.control_plane, "again", 1)),
    );
}

test "the root of trust is taken as given rather than established" {
    try std.testing.expect(Stage.root_of_trust.isImmutable());
    for (std.enums.values(Stage)) |stage| {
        if (stage == .root_of_trust) continue;
        try std.testing.expect(!stage.isImmutable());
    }

    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try std.testing.expectError(
        error.OutOfOrder,
        fixture.chain.advance(try fixture.staged(.root_of_trust, "hardware", 1)),
    );
}

test "what ran is measured, not what was claimed" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.boot();

    const taken = fixture.chain.taken();
    try std.testing.expectEqual(@intFromEnum(Stage.bootloader), taken[0].stage);
    try std.testing.expectEqual(@intFromEnum(Stage.kernel), taken[1].stage);
    try std.testing.expectEqual(@intFromEnum(Stage.control_plane), taken[2].stage);
    try std.testing.expectEqualSlices(
        u8,
        &measurements.digestOf("the kernel"),
        &taken[1].digest,
    );
}

test "the summary distinguishes what ran from what was merely acceptable" {
    var first: Fixture = undefined;
    try Fixture.init(&first);
    try first.boot();

    var second: Fixture = undefined;
    try Fixture.init(&second);
    try second.chain.advance(try second.staged(.bootloader, "the bootloader", 1));
    try second.chain.advance(try second.staged(.kernel, "a different kernel", 1));
    try second.chain.advance(try second.staged(.control_plane, "the control plane", 1));

    // Both booted three correctly signed stages. Only the summary says which
    // kernel actually ran.
    try std.testing.expect(first.chain.isComplete());
    try std.testing.expect(second.chain.isComplete());
    try std.testing.expect(!std.mem.eql(u8, &first.chain.summary(), &second.chain.summary()));
}

test "a downgraded stage is refused once the floor has risen" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.chain.advance(try fixture.staged(.bootloader, "the bootloader", 5));

    var later: Fixture = undefined;
    try Fixture.init(&later);
    later.chain.floors = fixture.chain.floors;

    try std.testing.expectError(
        error.RollbackRefused,
        later.chain.advance(try later.staged(.bootloader, "an older bootloader", 3)),
    );
}

test "the floors carried between boots never fall" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.chain.advance(try fixture.staged(.bootloader, "the bootloader", 7));
    try fixture.chain.advance(try fixture.staged(.kernel, "the kernel", 2));

    var later: Fixture = undefined;
    try Fixture.init(&later);
    later.chain.floors = fixture.chain.floors;
    try later.chain.advance(try later.staged(.bootloader, "the same version", 7));

    try std.testing.expectEqual(
        @as(u32, 7),
        later.chain.floors.forStage(@intFromEnum(Stage.bootloader)),
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        later.chain.floors.forStage(@intFromEnum(Stage.kernel)),
    );
}

test "a boot that completed has nothing to recover from" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.boot();

    try std.testing.expectEqual(
        @as(?recovery.Outcome, null),
        fixture.chain.recoveryOutcome(everything),
    );
}

test "a failure early in the chain has fewer options than one late in it" {
    var early: Fixture = undefined;
    try Fixture.init(&early);
    var tampered = try early.staged(.bootloader, "the bootloader", 1);
    tampered.image.signature[0] ^= 0xff;
    _ = early.chain.advance(tampered) catch {};

    // Nothing this early is trusted to locate a recovery image, even though one
    // is offered.
    try std.testing.expectEqual(
        recovery.Outcome.previous_slot,
        early.chain.recoveryOutcome(everything).?,
    );

    var late: Fixture = undefined;
    try Fixture.init(&late);
    try late.chain.advance(try late.staged(.bootloader, "the bootloader", 1));
    try late.chain.advance(try late.staged(.kernel, "the kernel", 1));
    var bad = try late.staged(.control_plane, "the control plane", 1);
    bad.image.signature[0] ^= 0xff;
    _ = late.chain.advance(bad) catch {};

    try std.testing.expectEqual(
        recovery.Outcome.boot_recovery_image,
        late.chain.recoveryOutcome(everything).?,
    );
}

test "with no alternative the device stops rather than booting something unverified" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    var tampered = try fixture.staged(.bootloader, "the bootloader", 1);
    tampered.image.signature[0] ^= 0xff;
    _ = fixture.chain.advance(tampered) catch {};

    const outcome = fixture.chain.recoveryOutcome(.{
        .recovery_image_verified = false,
        .previous_slot_bootable = false,
    }).?;
    try std.testing.expectEqual(recovery.Outcome.halt, outcome);
    try std.testing.expect(!outcome.leavesDeviceUsable());
}

test "an unmeasurable boot stops" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    fixture.chain.log.recorded = measurements.capacity;

    try std.testing.expectError(
        error.LogFull,
        fixture.chain.advance(try fixture.staged(.bootloader, "the bootloader", 1)),
    );
    // A stage that could not be measured must not run, however verifiable it is.
    try std.testing.expectEqual(
        recovery.Outcome.halt,
        fixture.chain.recoveryOutcome(everything).?,
    );
}

test "a halted chain never reports as complete" {
    var fixture: Fixture = undefined;
    try Fixture.init(&fixture);
    try fixture.chain.advance(try fixture.staged(.bootloader, "the bootloader", 1));
    try fixture.chain.advance(try fixture.staged(.kernel, "the kernel", 1));

    var bad = try fixture.staged(.control_plane, "the control plane", 1);
    bad.image.contents = "something else";
    _ = fixture.chain.advance(bad) catch {};

    // Reaching the last stage is not the same as completing the chain.
    try std.testing.expect(!fixture.chain.isComplete());
    try std.testing.expect(fixture.chain.hasHalted());
}

test "every stage has a defined recovery depth" {
    for (std.enums.values(Stage)) |stage| {
        _ = stage.recoveryDepth();
    }
}
