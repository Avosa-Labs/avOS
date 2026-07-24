//! Decides whether a rollback to an earlier version is permitted, and reports why.
//!
//! A rollback is a controlled downgrade: when a new build misbehaves, the device returns to a version
//! that worked. This is in tension with anti-rollback, which exists to stop a downgrade from
//! reintroducing a vulnerability a security update closed — and resolving that tension correctly is the
//! whole point of this tool. A rollback is permitted only when three things hold. The target must be a
//! version this device actually retained and confirmed good, because rolling back to a build that was
//! never known-good on this device is not a recovery, it is a guess. The target must be verified —
//! signed by a currently-trusted key with a matching digest — because a rollback is still a boot, held
//! to the same integrity floor as any other. And, decisively, the target's security generation must
//! not be below the device's security floor: rolling back across a security-generation boundary would
//! undo a fix and re-expose a closed hole, so it is refused even though the target is retained and
//! verified. A rollback that clears all three returns the device to safe, known-good ground; anything
//! else is refused with the reason.
//!
//! Exit codes: 0 the rollback is permitted, 1 it is refused, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A rollback target: the version the device would return to.
pub const Target = struct {
    /// Whether this version is a retained, previously-confirmed-good slot on this device.
    retained_known_good: bool,
    /// Whether the target image is verified — signed by a trusted key, digest matching.
    verified: bool,
    /// The target's security generation.
    security_generation: u32,
};

/// Why a rollback was refused.
pub const Refusal = enum {
    /// The target is not a retained, known-good version on this device.
    not_retained,
    /// The target image is not verified.
    unverified,
    /// The target's security generation is below the device's floor — rolling back would undo a fix.
    crosses_security_floor,
};

/// The rollback decision.
pub const Decision = union(enum) {
    permit,
    refuse: Refusal,

    pub fn permitted(decision: Decision) bool {
        return decision == .permit;
    }
};

/// Decides whether a rollback to a target is permitted, given the device's security floor.
///
/// The checks run from most fundamental to most subtle. A target that was never retained and
/// known-good is refused first — there is nothing safe to return to. A retained target that is not
/// verified is refused next — a rollback is still a boot. Finally, a retained, verified target whose
/// security generation is below the floor is refused, because permitting it would reintroduce a closed
/// vulnerability; this is the check that keeps rollback from becoming an anti-rollback bypass. A target
/// clearing all three is permitted.
pub fn decide(target: Target, security_floor: u32) Decision {
    if (!target.retained_known_good) return .{ .refuse = .not_retained };
    if (!target.verified) return .{ .refuse = .unverified };
    if (target.security_generation < security_floor) return .{ .refuse = .crosses_security_floor };
    return .permit;
}

const Options = struct {
    retained: bool = true,
    verified: bool = true,
    security_generation: u32 = 0,
    security_floor: u32 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [8 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const options = parseArguments(args, out, err) catch |parse_error| switch (parse_error) {
        error.HelpRequested => {
            try out.flush();
            return 0;
        },
        error.InvalidArguments => {
            try err.flush();
            return 2;
        },
        else => return parse_error,
    };

    const target: Target = .{
        .retained_known_good = options.retained,
        .verified = options.verified,
        .security_generation = options.security_generation,
    };

    switch (decide(target, options.security_floor)) {
        .permit => {
            try out.print("rollback: permitted to security generation {d} (floor {d})\n", .{
                options.security_generation, options.security_floor,
            });
            try out.flush();
            return 0;
        },
        .refuse => |reason| {
            try out.print("rollback: refused ({s})\n", .{describe(reason)});
            try out.flush();
            return 1;
        },
    }
}

fn describe(reason: Refusal) []const u8 {
    return switch (reason) {
        .not_retained => "target is not a retained, known-good version on this device",
        .unverified => "target image is not verified",
        .crosses_security_floor => "target security generation is below the floor; rollback would undo a fix",
    };
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: rollback [--no-retained] [--no-verified]
                \\                [--security-generation N] [--security-floor N]
                \\
                \\Decides whether a rollback to a target version is permitted. A rollback is
                \\permitted only when the target is retained and known-good, verified, and its
                \\security generation is at or above the device's floor.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--no-retained")) {
            options.retained = false;
        } else if (std.mem.eql(u8, arg, "--no-verified")) {
            options.verified = false;
        } else if (std.mem.eql(u8, arg, "--security-generation")) {
            index += 1;
            options.security_generation = try parseUnsigned(args, index, err, "--security-generation");
        } else if (std.mem.eql(u8, arg, "--security-floor")) {
            index += 1;
            options.security_floor = try parseUnsigned(args, index, err, "--security-floor");
        } else {
            try err.print("rollback: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn parseUnsigned(args: []const []const u8, index: usize, err: *std.Io.Writer, flag: []const u8) !u32 {
    if (index >= args.len) {
        try err.print("rollback: {s} needs a number\n", .{flag});
        return error.InvalidArguments;
    }
    return std.fmt.parseUnsigned(u32, args[index], 10) catch {
        try err.print("rollback: {s} needs a number, got '{s}'\n", .{ flag, args[index] });
        return error.InvalidArguments;
    };
}

fn makeTarget(retained: bool, verified: bool, generation: u32) Target {
    return .{ .retained_known_good = retained, .verified = verified, .security_generation = generation };
}

test "a retained, verified target at or above the floor is permitted" {
    try std.testing.expect(decide(makeTarget(true, true, 5), 5).permitted());
    try std.testing.expect(decide(makeTarget(true, true, 6), 5).permitted());
}

test "a non-retained target is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .not_retained }, decide(makeTarget(false, true, 5), 5));
}

test "an unverified target is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .unverified }, decide(makeTarget(true, false, 5), 5));
}

test "a target below the security floor is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .crosses_security_floor }, decide(makeTarget(true, true, 4), 5));
}

test "no permitted rollback ever crosses the security floor, swept" {
    // The anti-rollback property: a permitted rollback's security generation is always at least the
    // floor, so a fix can never be undone by a rollback.
    const floor: u32 = 5;
    var generation: u32 = 0;
    while (generation <= 8) : (generation += 1) {
        for ([_]bool{ false, true }) |retained| {
            for ([_]bool{ false, true }) |verified| {
                if (decide(makeTarget(retained, verified, generation), floor).permitted()) {
                    try std.testing.expect(retained and verified);
                    try std.testing.expect(generation >= floor);
                }
            }
        }
    }
}
