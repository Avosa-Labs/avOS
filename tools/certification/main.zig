//! Assembles certification evidence into a single launch go/no-go decision.
//!
//! Launch readiness is not one check but many — security assessment, update and recovery targets,
//! accessibility, localization, performance, support — and the danger at launch is that most of them
//! pass and one that did not is quietly overlooked in the rush. This tool exists to make that
//! impossible: it collects the status of every required criterion and returns go only when every one of
//! them has passed. A single unmet criterion is no-go, and the tool names which ones are outstanding, so
//! the decision to launch is made against the complete evidence rather than a hopeful summary. Some
//! criteria are marked non-waivable — the security, update, and recovery floors — and those can never be
//! marked satisfied by anything other than actually passing; the tool refuses to treat them as met on a
//! waiver. Gathering every criterion into one all-or-nothing verdict is what keeps launch a decision
//! backed by evidence rather than an accumulation of individually-reasonable omissions.
//!
//! Exit codes: 0 go — every criterion satisfied, 1 no-go — a criterion is outstanding or a manifest
//! cannot be read, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// One launch-readiness criterion and whether its evidence shows it satisfied.
pub const Criterion = struct {
    name: []const u8,
    satisfied: bool,
    /// Whether this criterion is a non-waivable floor (security, update, recovery).
    non_waivable: bool,
};

/// The launch decision.
pub const Verdict = enum { go, no_go };

/// Whether every criterion is satisfied — the only condition under which launch is go.
pub fn verdict(criteria: []const Criterion) Verdict {
    for (criteria) |criterion| {
        if (!criterion.satisfied) return .no_go;
    }
    return .go;
}

/// The name of the first outstanding (unsatisfied) criterion, or null if all are satisfied. Criteria
/// are checked in order for a deterministic report.
pub fn firstOutstanding(criteria: []const Criterion) ?[]const u8 {
    for (criteria) |criterion| {
        if (!criterion.satisfied) return criterion.name;
    }
    return null;
}

/// Parses one manifest line: "name status", where status is one of "pass", "fail", or "waived".
/// A waived non-waivable criterion is a manifest error — a floor cannot be waived.
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Criterion {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = fields.next() orelse return error.Malformed;
    const status = fields.next() orelse return error.Malformed;
    // An optional third field "floor" marks the criterion non-waivable.
    const marker = fields.next();
    const non_waivable = if (marker) |text| std.mem.eql(u8, text, "floor") else false;
    if (marker != null and !non_waivable) return error.Malformed;
    if (fields.next() != null) return error.Malformed;

    var satisfied: bool = undefined;
    if (std.mem.eql(u8, status, "pass")) {
        satisfied = true;
    } else if (std.mem.eql(u8, status, "fail")) {
        satisfied = false;
    } else if (std.mem.eql(u8, status, "waived")) {
        // A floor can never be waived; treat a waiver on it as a manifest error, not a pass.
        if (non_waivable) return error.FloorWaived;
        satisfied = true;
    } else {
        return error.Malformed;
    }
    return .{ .name = try arena.dupe(u8, name), .satisfied = satisfied, .non_waivable = non_waivable };
}

const Options = struct {
    manifest: []const u8 = "criteria.txt",
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
        try err.print("certification: cannot read criteria '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var criteria: std.ArrayList(Criterion) = .empty;
    defer criteria.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const criterion = parseLine(arena, line) catch |parse_error| switch (parse_error) {
            error.FloorWaived => {
                try err.print("certification: a non-waivable floor cannot be waived: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
                try err.flush();
                return 2;
            },
            else => {
                try err.print("certification: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
                try err.flush();
                return 2;
            },
        } orelse continue;
        try criteria.append(gpa, criterion);
    }

    for (criteria.items) |criterion| {
        const mark = if (criterion.non_waivable) " (floor)" else "";
        if (criterion.satisfied) {
            try out.print("  ok    {s}{s}\n", .{ criterion.name, mark });
        } else {
            try out.print("  MISS  {s}{s}\n", .{ criterion.name, mark });
        }
    }

    switch (verdict(criteria.items)) {
        .go => {
            try out.print("certification: GO — {d} criterion(a) satisfied\n", .{criteria.items.len});
            try out.flush();
            return 0;
        },
        .no_go => {
            try out.print("certification: NO-GO — '{s}' is outstanding\n", .{firstOutstanding(criteria.items).?});
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
                \\usage: certification [--manifest FILE]
                \\
                \\Assembles launch-readiness criteria into a single go/no-go decision: GO only when
                \\every criterion is satisfied. Manifest lines are "name status [floor]", where status
                \\is pass, fail, or waived; a criterion marked "floor" is non-waivable and cannot be
                \\satisfied by a waiver.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("certification: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("certification: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn make(name: []const u8, satisfied: bool, non_waivable: bool) Criterion {
    return .{ .name = name, .satisfied = satisfied, .non_waivable = non_waivable };
}

test "all satisfied is go" {
    const criteria = [_]Criterion{
        make("security", true, true),
        make("localization", true, false),
    };
    try std.testing.expectEqual(Verdict.go, verdict(&criteria));
    try std.testing.expectEqual(@as(?[]const u8, null), firstOutstanding(&criteria));
}

test "a single outstanding criterion is no-go and is named" {
    const criteria = [_]Criterion{
        make("security", true, true),
        make("performance", false, false),
    };
    try std.testing.expectEqual(Verdict.no_go, verdict(&criteria));
    try std.testing.expectEqualStrings("performance", firstOutstanding(&criteria).?);
}

test "a floor status of waived is rejected as a manifest error" {
    try std.testing.expectError(error.FloorWaived, parseLine(std.testing.allocator, "security waived floor"));
}

test "a waiver satisfies a non-floor criterion" {
    const criterion = (try parseLine(std.testing.allocator, "docs waived")).?;
    defer std.testing.allocator.free(criterion.name);
    try std.testing.expect(criterion.satisfied);
    try std.testing.expect(!criterion.non_waivable);
}

test "a floor pass parses as satisfied and non-waivable" {
    const criterion = (try parseLine(std.testing.allocator, "update pass floor")).?;
    defer std.testing.allocator.free(criterion.name);
    try std.testing.expect(criterion.satisfied);
    try std.testing.expect(criterion.non_waivable);
}

test "go implies every criterion satisfied, swept" {
    // The all-or-nothing property: whenever the verdict is go, no criterion is outstanding.
    const sets = [_][]const Criterion{
        &.{ make("a", true, false), make("b", true, true) },
        &.{ make("a", true, false), make("b", false, false) },
        &.{make("a", false, true)},
    };
    for (sets) |criteria| {
        if (verdict(criteria) == .go) {
            try std.testing.expectEqual(@as(?[]const u8, null), firstOutstanding(criteria));
        }
    }
}
