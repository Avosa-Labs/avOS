//! Validates a test-vector manifest, so the shared contract data every implementation checks against
//! is itself well-formed.
//!
//! Test vectors are the contract between implementations: a table of inputs and the outcome any correct
//! implementation must produce. They are only trustworthy if the table itself is sound, and two flaws
//! quietly ruin one. A duplicate input with two different expected outcomes makes the contract
//! self-contradictory — an implementation cannot satisfy both, and which one a checker enforces becomes
//! an accident of iteration order. An outcome outside the agreed vocabulary is unenforceable — a checker
//! does not know what "mostly-pass" means, so a vector claiming it is checked by no one. This tool
//! rejects both: every input must be unique, and every outcome must be one of the vocabulary the vector
//! set declares. A manifest that passes is a contract an implementation can actually be held to; one that
//! fails is reported with the offending line, so the contract is fixed rather than shipped ambiguous.
//! Validating the vectors is what lets the vectors validate everything else.
//!
//! Exit codes: 0 the manifest is well-formed, 1 it has a duplicate input or an unknown outcome, 2 usage
//! error or an unreadable manifest.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The outcomes a vector may declare. A vector's expected outcome must be one of these; anything else is
/// unenforceable and rejected.
pub const known_outcomes = [_][]const u8{ "pass", "refuse", "trap", "unknown" };

/// Whether an outcome is in the known vocabulary.
pub fn isKnownOutcome(outcome: []const u8) bool {
    for (known_outcomes) |known| {
        if (std.mem.eql(u8, known, outcome)) return true;
    }
    return false;
}

/// One parsed vector: an input name and its expected outcome.
pub const Vector = struct {
    input: []const u8,
    outcome: []const u8,
};

/// Parses one manifest line: "input outcome". Blank and comment lines yield null.
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Vector {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const input = fields.next() orelse return error.Malformed;
    const outcome = fields.next() orelse return error.Malformed;
    if (fields.next() != null) return error.Malformed;
    return .{ .input = try arena.dupe(u8, input), .outcome = try arena.dupe(u8, outcome) };
}

/// A validation problem found in a vector set.
pub const Problem = union(enum) {
    /// Two vectors declare the same input. Carries the input.
    duplicate_input: []const u8,
    /// A vector declares an outcome outside the vocabulary. Carries the input and the bad outcome.
    unknown_outcome: struct { input: []const u8, outcome: []const u8 },
};

/// Finds the first validation problem in a vector set, or null if it is well-formed. Vectors are
/// checked in order for a deterministic report: an unknown outcome is caught at its vector, a duplicate
/// at its second occurrence.
pub fn firstProblem(vectors: []const Vector) ?Problem {
    for (vectors, 0..) |vector, index| {
        if (!isKnownOutcome(vector.outcome)) {
            return .{ .unknown_outcome = .{ .input = vector.input, .outcome = vector.outcome } };
        }
        for (vectors[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.input, vector.input)) {
                return .{ .duplicate_input = vector.input };
            }
        }
    }
    return null;
}

const Options = struct {
    manifest: []const u8 = "vectors.txt",
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

    const contents = io_adapters.cwd().readFileAlloc(io, options.manifest, gpa, .limited(4 << 20)) catch {
        try err.print("test-vector: cannot read manifest '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var vectors: std.ArrayList(Vector) = .empty;
    defer vectors.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const vector = parseLine(arena, line) catch {
            try err.print("test-vector: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        try vectors.append(gpa, vector);
    }

    if (firstProblem(vectors.items)) |problem| {
        switch (problem) {
            .duplicate_input => |input| try out.print("test-vector: duplicate input '{s}'\n", .{input}),
            .unknown_outcome => |bad| try out.print("test-vector: unknown outcome '{s}' for input '{s}'\n", .{ bad.outcome, bad.input }),
        }
        try out.flush();
        return 1;
    }

    try out.print("test-vector: {d} vector(s) well-formed\n", .{vectors.items.len});
    try out.flush();
    return 0;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: test-vector [--manifest FILE]
                \\
                \\Validates a test-vector manifest: every input unique, every outcome in the known
                \\vocabulary (pass, refuse, trap, unknown). Manifest lines are "input outcome".
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("test-vector: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("test-vector: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn v(input: []const u8, outcome: []const u8) Vector {
    return .{ .input = input, .outcome = outcome };
}

test "a well-formed vector set has no problem" {
    const vectors = [_]Vector{ v("benign", "pass"), v("malformed", "refuse"), v("unreachable", "trap") };
    try std.testing.expectEqual(@as(?Problem, null), firstProblem(&vectors));
}

test "a duplicate input is caught" {
    const vectors = [_]Vector{ v("benign", "pass"), v("benign", "refuse") };
    switch (firstProblem(&vectors).?) {
        .duplicate_input => |input| try std.testing.expectEqualStrings("benign", input),
        else => try std.testing.expect(false),
    }
}

test "an unknown outcome is caught" {
    const vectors = [_]Vector{ v("benign", "pass"), v("weird", "mostly-pass") };
    switch (firstProblem(&vectors).?) {
        .unknown_outcome => |bad| {
            try std.testing.expectEqualStrings("weird", bad.input);
            try std.testing.expectEqualStrings("mostly-pass", bad.outcome);
        },
        else => try std.testing.expect(false),
    }
}

test "an unknown outcome is reported ahead of a later duplicate" {
    // The bad outcome at index 1 is found before the duplicate at index 2 would be.
    const vectors = [_]Vector{ v("a", "pass"), v("b", "bogus"), v("a", "refuse") };
    try std.testing.expect(firstProblem(&vectors).? == .unknown_outcome);
}

test "a well-formed set has unique inputs and known outcomes, swept" {
    // The soundness property: when a set passes, every outcome is known and no input repeats.
    const vectors = [_]Vector{ v("x", "pass"), v("y", "refuse"), v("z", "trap") };
    if (firstProblem(&vectors) == null) {
        for (vectors, 0..) |vector, index| {
            try std.testing.expect(isKnownOutcome(vector.outcome));
            for (vectors[0..index]) |earlier| {
                try std.testing.expect(!std.mem.eql(u8, earlier.input, vector.input));
            }
        }
    }
}
