//! Checks power-draw measurements against their budgets, so a build that drains the battery is caught
//! before it ships.
//!
//! Battery life is a promise a device makes and a build can quietly break: a background task that wakes
//! too often, a sensor left on, a screen brighter than it needs to be, and the device that lasted a day
//! now lasts an afternoon — with no crash and no obvious culprit. A power budget makes that drift
//! visible. Each draw a build is responsible for — idle draw, a background task's average, a wake's
//! energy — has a budget in milliwatts or millijoules, and a measurement is within budget only when it
//! does not exceed it. A measurement over budget is a regression, reported with how far over, so the
//! size of the miss is visible. The budgets are the same ones a device's power gate enforces, so a
//! developer measuring locally learns what a shipping build would. Holding draw to explicit budgets is
//! what keeps battery life a property the platform maintains rather than one it loses a wake at a time.
//!
//! Exit codes: 0 every draw is within budget, 1 a draw exceeds its budget or a manifest cannot be read,
//! 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A power draw measured against its budget, both in the same unit (for example milliwatts).
pub const Draw = struct {
    name: []const u8,
    measured: u64,
    budget: u64,

    /// Whether the draw is within budget — it does not exceed it. The budget is the inclusive maximum,
    /// so a draw exactly at budget passes.
    pub fn withinBudget(draw: Draw) bool {
        return draw.measured <= draw.budget;
    }

    /// How far over budget the draw is, or zero if within budget.
    pub fn overBy(draw: Draw) u64 {
        return if (draw.measured > draw.budget) draw.measured - draw.budget else 0;
    }
};

/// Parses one manifest line: "name measured budget".
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Draw {
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
    manifest: []const u8 = "power.txt",
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
        try err.print("power: cannot read measurements '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var over: usize = 0;
    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const draw = parseLine(arena, line) catch {
            try err.print("power: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        checked += 1;
        if (draw.withinBudget()) {
            try out.print("  ok    {s}  {d}/{d}\n", .{ draw.name, draw.measured, draw.budget });
        } else {
            over += 1;
            try out.print("  OVER  {s}  {d}/{d}  (+{d})\n", .{ draw.name, draw.measured, draw.budget, draw.overBy() });
        }
    }

    if (over == 0) {
        try out.print("power: {d} draw(s) checked, all within budget\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("power: {d} of {d} draw(s) over budget\n", .{ over, checked });
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
                \\usage: power [--manifest FILE]
                \\
                \\Checks each power draw against its budget: a draw within its budget passes, one over
                \\it is a regression. Manifest lines are "name measured budget" in a common unit; the
                \\budget is the inclusive maximum.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("power: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("power: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn make(measured: u64, budget: u64) Draw {
    return .{ .name = "draw", .measured = measured, .budget = budget };
}

test "a draw within budget passes" {
    try std.testing.expect(make(80, 100).withinBudget());
}

test "a draw exactly at budget passes with zero overage" {
    try std.testing.expect(make(100, 100).withinBudget());
    try std.testing.expectEqual(@as(u64, 0), make(100, 100).overBy());
}

test "a draw over budget fails and reports the overage" {
    try std.testing.expect(!make(150, 100).withinBudget());
    try std.testing.expectEqual(@as(u64, 50), make(150, 100).overBy());
}

test "withinBudget holds exactly when overage is zero, swept" {
    var measured: u64 = 80;
    while (measured <= 120) : (measured += 5) {
        const draw = make(measured, 100);
        try std.testing.expectEqual(draw.withinBudget(), draw.overBy() == 0);
    }
}
