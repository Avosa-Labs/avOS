//! Checks performance measurements against their budgets, so a surface that misses a budget is caught
//! before it ships slow.
//!
//! Performance is a promise the platform makes and can break silently: a surface that was within
//! budget grows a little slower each release, no single change is obviously at fault, and one day it is
//! sluggish with no one having decided to make it so. A budget turns that slow drift into a hard line.
//! Each metric — a frame time, a launch time, an input latency — has a budget, and a measurement is
//! within budget only when it does not exceed it. A measurement over budget is a regression, reported
//! with how far over it went so the size of the miss is visible, not just its existence. The budgets are
//! the same ones the on-device performance gate enforces, so a developer measuring locally gets the same
//! verdict a shipping build would. Holding measurements to explicit budgets is what keeps performance a
//! property the platform maintains rather than one it loses a millisecond at a time.
//!
//! Exit codes: 0 every measurement is within budget, 1 a measurement exceeds its budget or a manifest
//! cannot be read, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A metric's measured value against its budget, both in the same unit (for example microseconds).
pub const Measurement = struct {
    name: []const u8,
    measured: u64,
    budget: u64,

    /// Whether the measurement is within budget: it does not exceed the budget. The budget is
    /// inclusive — a measurement exactly at budget passes, because the budget is the allowed maximum.
    pub fn withinBudget(measurement: Measurement) bool {
        return measurement.measured <= measurement.budget;
    }

    /// How far over budget the measurement is, or zero if within budget.
    pub fn overBy(measurement: Measurement) u64 {
        return if (measurement.measured > measurement.budget) measurement.measured - measurement.budget else 0;
    }
};

/// Parses one manifest line: "name measured budget".
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Measurement {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = fields.next() orelse return error.Malformed;
    const measured = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    const budget = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    if (fields.next() != null) return error.Malformed;
    return .{ .name = try arena.dupe(u8, name), .measured = measured, .budget = budget };
}

const Options = struct {
    manifest: []const u8 = "measurements.txt",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
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

    const contents = io_adapters.cwd().readFileAlloc(io, options.manifest, gpa, .limited(1 << 20)) catch {
        try err.print("performance: cannot read measurements '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var over: usize = 0;
    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const measurement = parseLine(arena, line) catch {
            try err.print("performance: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        checked += 1;
        if (measurement.withinBudget()) {
            try out.print("  ok    {s}  {d}/{d}\n", .{ measurement.name, measurement.measured, measurement.budget });
        } else {
            over += 1;
            try out.print("  OVER  {s}  {d}/{d}  (+{d})\n", .{
                measurement.name, measurement.measured, measurement.budget, measurement.overBy(),
            });
        }
    }

    if (over == 0) {
        try out.print("performance: {d} metric(s) checked, all within budget\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("performance: {d} of {d} metric(s) over budget\n", .{ over, checked });
    try out.flush();
    return 1;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: performance [--manifest FILE]
                \\
                \\Checks each measurement against its budget: a measurement within its budget passes,
                \\one over it is a regression. Manifest lines are "name measured budget" in a common
                \\unit; the budget is the inclusive maximum.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("performance: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("performance: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn make(measured: u64, budget: u64) Measurement {
    return .{ .name = "metric", .measured = measured, .budget = budget };
}

test "a measurement within budget passes" {
    try std.testing.expect(make(90, 100).withinBudget());
}

test "a measurement exactly at budget passes" {
    try std.testing.expect(make(100, 100).withinBudget());
    try std.testing.expectEqual(@as(u64, 0), make(100, 100).overBy());
}

test "a measurement over budget fails and reports the overage" {
    try std.testing.expect(!make(130, 100).withinBudget());
    try std.testing.expectEqual(@as(u64, 30), make(130, 100).overBy());
}

test "overBy is zero exactly when within budget, swept" {
    // The consistency property: a measurement is within budget iff its overage is zero.
    var measured: u64 = 90;
    while (measured <= 110) : (measured += 5) {
        const measurement = make(measured, 100);
        try std.testing.expectEqual(measurement.withinBudget(), measurement.overBy() == 0);
    }
}
