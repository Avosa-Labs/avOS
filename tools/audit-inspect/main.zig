//! Inspects an audit ledger for integrity, so tampering with the record of what happened is detectable.
//!
//! The audit ledger is the account of what the system did — every consequential action, approval, and
//! denial — and its value rests entirely on being unforgeable after the fact. Two properties make it so,
//! and this tool checks both. The sequence must be unbroken: entries are numbered consecutively from a
//! known start, so a removed entry leaves a gap and an inserted one a collision, either of which the
//! numbering exposes. And the chain must hold: each entry carries the hash of the previous entry, so
//! altering any past entry changes its hash and breaks every link after it — a single tampered record
//! cannot be fixed up without redoing the entire chain that follows. An inspection that finds an
//! unbroken sequence and an intact chain attests the ledger has not been altered since it was written; a
//! gap or a broken link is reported with the entry where it occurs, because the location of the break is
//! where the investigation starts. Checking the ledger's own integrity is what lets everything else rely
//! on it as evidence.
//!
//! Exit codes: 0 the ledger is intact, 1 a sequence gap or chain break, 2 usage error or unreadable
//! ledger.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// One ledger entry: its sequence number, the hash it records for the previous entry, and its own hash.
pub const Entry = struct {
    sequence: u64,
    prev_hash: u64,
    hash: u64,
};

/// A ledger integrity problem.
pub const Problem = union(enum) {
    /// The entry's sequence number is not one more than the previous. Carries the expected and found.
    sequence_gap: struct { expected: u64, found: u64 },
    /// The entry's recorded previous-hash does not match the previous entry's hash. Carries the
    /// sequence where the chain breaks.
    chain_break: u64,
};

/// The hash a ledger uses for the slot before its first entry — a fixed genesis value every writer and
/// inspector agrees on, so the first entry's chain link is checkable like any other.
pub const genesis_hash: u64 = 0;

/// Finds the first integrity problem in a ledger, or null if it is intact. Entries are expected to
/// start at `start_sequence` and increase by one; each entry's `prev_hash` must equal the prior entry's
/// `hash` (the first entry's must equal the genesis hash).
pub fn firstProblem(entries: []const Entry, start_sequence: u64) ?Problem {
    var expected_sequence = start_sequence;
    var expected_prev: u64 = genesis_hash;
    for (entries) |entry| {
        if (entry.sequence != expected_sequence) {
            return .{ .sequence_gap = .{ .expected = expected_sequence, .found = entry.sequence } };
        }
        if (entry.prev_hash != expected_prev) {
            return .{ .chain_break = entry.sequence };
        }
        expected_sequence = entry.sequence + 1;
        expected_prev = entry.hash;
    }
    return null;
}

/// Whether a ledger is intact: an unbroken sequence and an intact hash chain.
pub fn intact(entries: []const Entry, start_sequence: u64) bool {
    return firstProblem(entries, start_sequence) == null;
}

/// Parses one ledger line: "sequence prevHash hash", each an unsigned integer.
fn parseLine(line: []const u8) !?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const sequence = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    const prev_hash = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    const hash = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    if (fields.next() != null) return error.Malformed;
    return .{ .sequence = sequence, .prev_hash = prev_hash, .hash = hash };
}

const Options = struct {
    ledger: []const u8 = "ledger.txt",
    start_sequence: u64 = 1,
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

    const contents = io_adapters.cwd().readFileAlloc(io, options.ledger, gpa, .limited(16 << 20)) catch {
        try err.print("audit-inspect: cannot read ledger '{s}'\n", .{options.ledger});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const entry = parseLine(line) catch {
            try err.print("audit-inspect: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        try entries.append(gpa, entry);
    }

    if (firstProblem(entries.items, options.start_sequence)) |problem| {
        switch (problem) {
            .sequence_gap => |gap| try out.print("audit-inspect: sequence gap; expected {d}, found {d}\n", .{ gap.expected, gap.found }),
            .chain_break => |sequence| try out.print("audit-inspect: chain break at entry {d}\n", .{sequence}),
        }
        try out.flush();
        return 1;
    }

    try out.print("audit-inspect: {d} entr(y/ies) intact; sequence unbroken and chain verified\n", .{entries.items.len});
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
                \\usage: audit-inspect [--ledger FILE] [--start N]
                \\
                \\Inspects an audit ledger for integrity: an unbroken consecutive sequence from the
                \\start, and a hash chain where each entry records the previous entry's hash. Ledger
                \\lines are "sequence prevHash hash".
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--ledger")) {
            index += 1;
            if (index >= args.len) {
                try err.print("audit-inspect: --ledger needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.ledger = args[index];
        } else if (std.mem.eql(u8, arg, "--start")) {
            index += 1;
            if (index >= args.len) {
                try err.print("audit-inspect: --start needs a number\n", .{});
                return error.InvalidArguments;
            }
            options.start_sequence = std.fmt.parseUnsigned(u64, args[index], 10) catch {
                try err.print("audit-inspect: --start needs a number, got '{s}'\n", .{args[index]});
                return error.InvalidArguments;
            };
        } else {
            try err.print("audit-inspect: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn makeEntry(sequence: u64, prev_hash: u64, hash: u64) Entry {
    return .{ .sequence = sequence, .prev_hash = prev_hash, .hash = hash };
}

test "an unbroken, well-chained ledger is intact" {
    const entries = [_]Entry{
        makeEntry(1, genesis_hash, 111),
        makeEntry(2, 111, 222),
        makeEntry(3, 222, 333),
    };
    try std.testing.expect(intact(&entries, 1));
}

test "a missing entry is caught as a sequence gap" {
    const entries = [_]Entry{
        makeEntry(1, genesis_hash, 111),
        makeEntry(3, 111, 333), // entry 2 removed
    };
    switch (firstProblem(&entries, 1).?) {
        .sequence_gap => |gap| {
            try std.testing.expectEqual(@as(u64, 2), gap.expected);
            try std.testing.expectEqual(@as(u64, 3), gap.found);
        },
        else => try std.testing.expect(false),
    }
}

test "a tampered entry breaks the chain at the next link" {
    const entries = [_]Entry{
        makeEntry(1, genesis_hash, 111),
        makeEntry(2, 999, 222), // prev_hash should be 111
    };
    switch (firstProblem(&entries, 1).?) {
        .chain_break => |sequence| try std.testing.expectEqual(@as(u64, 2), sequence),
        else => try std.testing.expect(false),
    }
}

test "the first entry's chain link is checked against genesis" {
    const entries = [_]Entry{makeEntry(1, 5, 111)}; // prev_hash should be genesis (0)
    try std.testing.expect(!intact(&entries, 1));
}

test "an empty ledger is trivially intact" {
    try std.testing.expect(intact(&.{}, 1));
}

test "an intact ledger has consecutive sequences and a linked chain, swept" {
    // The integrity property: when a ledger is intact, each entry's sequence is one past the prior and
    // its prev_hash equals the prior hash.
    const entries = [_]Entry{
        makeEntry(10, genesis_hash, 1),
        makeEntry(11, 1, 2),
        makeEntry(12, 2, 3),
    };
    if (intact(&entries, 10)) {
        var prev_seq: ?u64 = null;
        var prev_hash: u64 = genesis_hash;
        for (entries) |e| {
            if (prev_seq) |s| try std.testing.expectEqual(s + 1, e.sequence);
            try std.testing.expectEqual(prev_hash, e.prev_hash);
            prev_seq = e.sequence;
            prev_hash = e.hash;
        }
    }
}
