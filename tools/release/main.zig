//! Drives a release through the rollout rings, one promotion at a time.
//!
//! A release advances through rings of widening exposure — internal, canary, staged, general — and
//! this tool decides, for a release sitting in one ring, what happens next: advance to the next ring,
//! hold where it is, or roll back. The promotion decision itself belongs to the rollout policy
//! (`packaging/policies/rollout`): advance only behind a sufficient soak with no regression, roll back
//! on any regression, hold otherwise. This tool wraps that decision in the ring sequence, so an advance
//! from one ring names the ring it advances to, and an advance from the last ring means the release has
//! reached everyone. Keeping the promotion logic in the policy and only the ring sequence here means the
//! tool and the on-device gate make the same decision from the same evidence — the tool is how a release
//! engineer asks that gate "what now" without guessing.
//!
//! Exit codes: 0 the release advances or has reached general availability, 1 it holds or rolls back,
//! 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const packaging = @import("packaging");

const rollout = packaging.rollout;

/// The rollout rings, in order of widening exposure.
pub const Ring = enum(u2) {
    internal = 0,
    canary = 1,
    staged = 2,
    general = 3,

    /// The next wider ring, or null if this is already the widest.
    pub fn next(ring: Ring) ?Ring {
        return switch (ring) {
            .internal => .canary,
            .canary => .staged,
            .staged => .general,
            .general => null,
        };
    }

    fn parse(text: []const u8) ?Ring {
        inline for (@typeInfo(Ring).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, text)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// What the release does next.
pub const Action = union(enum) {
    /// Advance to the next ring.
    advance_to: Ring,
    /// The release has cleared the last ring — it is at general availability.
    reached_general,
    /// Hold in the current ring — not enough soak yet.
    hold,
    /// Roll the release back — a regression was observed.
    rollback,
};

/// Decides what a release in a given ring does next, from the ring's rollout result.
///
/// The rollout policy decides advance, hold, or rollback from the soak and health. An advance is then
/// mapped onto the ring sequence: from a middle ring it advances to the next, and from the last ring it
/// is general availability. Hold and rollback carry through unchanged.
pub fn decide(current: Ring, result: rollout.RingResult, required_soak_hours: u32) Action {
    return switch (rollout.decide(result, required_soak_hours)) {
        .advance => if (current.next()) |ring| .{ .advance_to = ring } else .reached_general,
        .hold => .hold,
        .rollback => .rollback,
    };
}

const Options = struct {
    ring: Ring = .internal,
    soak_hours: u32 = 0,
    healthy: bool = true,
    required_soak_hours: u32 = 24,
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

    const result: rollout.RingResult = .{
        .soak_hours = options.soak_hours,
        .health = if (options.healthy) .healthy else .regressed,
    };

    switch (decide(options.ring, result, options.required_soak_hours)) {
        .advance_to => |ring| {
            try out.print("release: advance from {s} to {s}\n", .{ @tagName(options.ring), @tagName(ring) });
            try out.flush();
            return 0;
        },
        .reached_general => {
            try out.print("release: {s} cleared; the release has reached general availability\n", .{@tagName(options.ring)});
            try out.flush();
            return 0;
        },
        .hold => {
            try out.print("release: hold in {s}; soak {d}h of {d}h required\n", .{
                @tagName(options.ring), options.soak_hours, options.required_soak_hours,
            });
            try out.flush();
            return 1;
        },
        .rollback => {
            try out.print("release: roll back from {s}; a regression was observed\n", .{@tagName(options.ring)});
            try out.flush();
            return 1;
        },
    }
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: release [--ring internal|canary|staged|general]
                \\               [--soak-hours N] [--required-soak N] [--regressed]
                \\
                \\Decides what a release in a ring does next: advance to the next ring, hold, or
                \\roll back. Advancement requires the required soak with no regression.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--ring")) {
            index += 1;
            if (index >= args.len) {
                try err.print("release: --ring needs a ring name\n", .{});
                return error.InvalidArguments;
            }
            options.ring = Ring.parse(args[index]) orelse {
                try err.print("release: unknown ring '{s}'\n", .{args[index]});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--soak-hours")) {
            index += 1;
            options.soak_hours = try parseUnsigned(args, index, err, "--soak-hours");
        } else if (std.mem.eql(u8, arg, "--required-soak")) {
            index += 1;
            options.required_soak_hours = try parseUnsigned(args, index, err, "--required-soak");
        } else if (std.mem.eql(u8, arg, "--regressed")) {
            options.healthy = false;
        } else {
            try err.print("release: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn parseUnsigned(args: []const []const u8, index: usize, err: *std.Io.Writer, flag: []const u8) !u32 {
    if (index >= args.len) {
        try err.print("release: {s} needs a number\n", .{flag});
        return error.InvalidArguments;
    }
    return std.fmt.parseUnsigned(u32, args[index], 10) catch {
        try err.print("release: {s} needs a number, got '{s}'\n", .{ flag, args[index] });
        return error.InvalidArguments;
    };
}

fn healthy(soak: u32) rollout.RingResult {
    return .{ .soak_hours = soak, .health = .healthy };
}

test "a healthy, soaked release advances to the next ring" {
    try std.testing.expectEqual(Action{ .advance_to = .canary }, decide(.internal, healthy(24), 24));
    try std.testing.expectEqual(Action{ .advance_to = .general }, decide(.staged, healthy(24), 24));
}

test "advancing from the last ring reaches general availability" {
    try std.testing.expectEqual(Action.reached_general, decide(.general, healthy(24), 24));
}

test "an under-soaked release holds" {
    try std.testing.expectEqual(Action.hold, decide(.canary, healthy(10), 24));
}

test "a regressed release rolls back from any ring" {
    const regressed: rollout.RingResult = .{ .soak_hours = 100, .health = .regressed };
    try std.testing.expectEqual(Action.rollback, decide(.staged, regressed, 24));
    try std.testing.expectEqual(Action.rollback, decide(.internal, regressed, 24));
}

test "the ring sequence advances by exactly one and stops at general" {
    try std.testing.expectEqual(@as(?Ring, .canary), Ring.internal.next());
    try std.testing.expectEqual(@as(?Ring, .staged), Ring.canary.next());
    try std.testing.expectEqual(@as(?Ring, .general), Ring.staged.next());
    try std.testing.expectEqual(@as(?Ring, null), Ring.general.next());
}

test "an advance never skips a ring, swept" {
    // The one-ring-at-a-time property: an advance always lands on the immediate next ring.
    for ([_]Ring{ .internal, .canary, .staged, .general }) |ring| {
        switch (decide(ring, healthy(24), 24)) {
            .advance_to => |next_ring| try std.testing.expectEqual(ring.next().?, next_ring),
            .reached_general => try std.testing.expectEqual(@as(?Ring, null), ring.next()),
            else => {},
        }
    }
}
