//! Symbolicates a crash report against a build's symbols, refusing a mismatched build.
//!
//! A crash report carries fault addresses — offsets into the binary that was running — and a build's
//! symbols map address ranges to function names. Turning the first into the second is only meaningful
//! when the symbols are for the exact build that crashed: an address resolved against a different build's
//! symbols yields a confident, wrong function name, which is worse than no name at all because it sends
//! the investigation down a false trail. So symbolication first checks that the report's build identifier
//! matches the symbol set's, and refuses outright on a mismatch rather than resolving against the wrong
//! map. When the build matches, each fault address is resolved to the function whose range contains it;
//! an address in no known range is reported as unknown rather than guessed. Refusing a build mismatch and
//! never guessing an address is what makes a symbolicated crash report evidence rather than a plausible
//! story.
//!
//! The symbol table is read from a file whose first line is the build identifier and whose remaining
//! lines are "name startHex endHex" entries, so the tool resolves against a real build's symbols rather
//! than any built-in table.
//!
//! Exit codes: 0 symbolicated, 1 the build does not match the symbols, 2 usage error or unreadable
//! symbol file.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A function's address range in a build, half-open: [start, end).
pub const Symbol = struct {
    name: []const u8,
    start: u64,
    end: u64,
};

/// Whether a report's build matches the symbol set's build. Symbolication is refused unless they are
/// equal, because resolving against another build's symbols produces confidently wrong names.
pub fn buildsMatch(report_build_id: u64, symbols_build_id: u64) bool {
    return report_build_id == symbols_build_id;
}

/// Resolves an address to the name of the function whose range contains it, or null if no range does.
///
/// The ranges are half-open and assumed non-overlapping; an address is resolved to the single range
/// that contains it. An address outside every range returns null — reported as unknown rather than
/// attributed to the nearest function, which would be a guess.
pub fn resolve(symbols: []const Symbol, address: u64) ?[]const u8 {
    for (symbols) |symbol| {
        if (address >= symbol.start and address < symbol.end) return symbol.name;
    }
    return null;
}

/// The build id and symbols parsed from a symbol file.
const SymbolTable = struct {
    build_id: u64,
    symbols: []const Symbol,
};

fn parseHexOrDecimal(text: []const u8) !u64 {
    if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseUnsigned(u64, text[2..], 16);
    return std.fmt.parseUnsigned(u64, text, 10);
}

/// Parses a symbol file's contents. The first non-blank, non-comment line is the build id; each
/// remaining line is "name start end". Ranges must be well-formed (start < end).
fn parseSymbolTable(arena: std.mem.Allocator, contents: []const u8) !SymbolTable {
    var symbols: std.ArrayList(Symbol) = .empty;
    var build_id: ?u64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (build_id == null) {
            build_id = try parseHexOrDecimal(line);
            continue;
        }
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse return error.Malformed;
        const start = try parseHexOrDecimal(fields.next() orelse return error.Malformed);
        const end = try parseHexOrDecimal(fields.next() orelse return error.Malformed);
        if (fields.next() != null) return error.Malformed;
        if (start >= end) return error.Malformed;
        try symbols.append(arena, .{ .name = try arena.dupe(u8, name), .start = start, .end = end });
    }
    return .{ .build_id = build_id orelse return error.Malformed, .symbols = try symbols.toOwnedSlice(arena) };
}

const Options = struct {
    report_build_id: u64 = 0,
    symbols_file: []const u8 = "",
    address: u64 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
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

    if (options.symbols_file.len == 0) {
        try err.print("crash-symbols: --symbols is required\n", .{});
        try err.flush();
        return 2;
    }

    const contents = io_adapters.cwd().readFileAlloc(io, options.symbols_file, gpa, .limited(16 << 20)) catch {
        try err.print("crash-symbols: cannot read symbol file '{s}'\n", .{options.symbols_file});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    const table = parseSymbolTable(arena, contents) catch {
        try err.print("crash-symbols: malformed symbol file '{s}'\n", .{options.symbols_file});
        try err.flush();
        return 2;
    };

    if (!buildsMatch(options.report_build_id, table.build_id)) {
        try out.print("crash-symbols: refused; report build {d} does not match symbols build {d}\n", .{
            options.report_build_id, table.build_id,
        });
        try out.flush();
        return 1;
    }

    if (resolve(table.symbols, options.address)) |name| {
        try out.print("crash-symbols: 0x{x} -> {s}\n", .{ options.address, name });
    } else {
        try out.print("crash-symbols: 0x{x} -> <unknown>\n", .{options.address});
    }
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
                \\usage: crash-symbols --report-build ID --symbols FILE --address ADDR
                \\
                \\Symbolicates a fault address against a build's symbols. Refuses when the report's
                \\build does not match the symbol file's, and reports an unresolved address as unknown
                \\rather than guessing. The symbol file's first line is the build id; each remaining
                \\line is "name start end".
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--report-build")) {
            index += 1;
            options.report_build_id = try parseUnsigned(args, index, err, "--report-build");
        } else if (std.mem.eql(u8, arg, "--symbols")) {
            index += 1;
            if (index >= args.len) {
                try err.print("crash-symbols: --symbols needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.symbols_file = args[index];
        } else if (std.mem.eql(u8, arg, "--address")) {
            index += 1;
            options.address = try parseAddress(args, index, err);
        } else {
            try err.print("crash-symbols: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn parseUnsigned(args: []const []const u8, index: usize, err: *std.Io.Writer, flag: []const u8) !u64 {
    if (index >= args.len) {
        try err.print("crash-symbols: {s} needs a number\n", .{flag});
        return error.InvalidArguments;
    }
    return std.fmt.parseUnsigned(u64, args[index], 10) catch {
        try err.print("crash-symbols: {s} needs a number, got '{s}'\n", .{ flag, args[index] });
        return error.InvalidArguments;
    };
}

fn parseAddress(args: []const []const u8, index: usize, err: *std.Io.Writer) !u64 {
    if (index >= args.len) {
        try err.print("crash-symbols: --address needs a value\n", .{});
        return error.InvalidArguments;
    }
    return parseHexOrDecimal(args[index]) catch {
        try err.print("crash-symbols: --address needs a number, got '{s}'\n", .{args[index]});
        return error.InvalidArguments;
    };
}

const test_symbols = [_]Symbol{
    .{ .name = "alpha", .start = 0x100, .end = 0x200 },
    .{ .name = "beta", .start = 0x200, .end = 0x300 },
};

test "matching builds symbolicate; mismatched builds do not" {
    try std.testing.expect(buildsMatch(42, 42));
    try std.testing.expect(!buildsMatch(42, 43));
}

test "an address resolves to the function whose range contains it" {
    try std.testing.expectEqualStrings("alpha", resolve(&test_symbols, 0x150).?);
    try std.testing.expectEqualStrings("beta", resolve(&test_symbols, 0x250).?);
}

test "a range is half-open: its end belongs to the next function" {
    try std.testing.expectEqualStrings("beta", resolve(&test_symbols, 0x200).?);
    try std.testing.expectEqualStrings("alpha", resolve(&test_symbols, 0x1ff).?);
}

test "an address outside every range is unknown, not guessed" {
    try std.testing.expectEqual(@as(?[]const u8, null), resolve(&test_symbols, 0x50));
    try std.testing.expectEqual(@as(?[]const u8, null), resolve(&test_symbols, 0x300));
}

test "parsing a symbol file reads the build id and ranges" {
    const table = try parseSymbolTable(std.testing.allocator,
        \\# a symbol file
        \\42
        \\boot_main 0x1000 0x1400
        \\kernel_entry 0x1400 0x1c00
    );
    defer {
        for (table.symbols) |symbol| std.testing.allocator.free(symbol.name);
        std.testing.allocator.free(table.symbols);
    }
    try std.testing.expectEqual(@as(u64, 42), table.build_id);
    try std.testing.expectEqual(@as(usize, 2), table.symbols.len);
    try std.testing.expectEqualStrings("boot_main", resolve(table.symbols, 0x1200).?);
}

test "a malformed range is rejected" {
    // start not below end.
    try std.testing.expectError(error.Malformed, parseSymbolTable(std.testing.allocator, "7\nbad 0x200 0x100"));
}

test "a resolved address is always within the returned function's range, swept" {
    var address: u64 = 0x80;
    while (address <= 0x320) : (address += 0x10) {
        if (resolve(&test_symbols, address)) |name| {
            var found = false;
            for (test_symbols) |symbol| {
                if (std.mem.eql(u8, symbol.name, name)) {
                    try std.testing.expect(address >= symbol.start and address < symbol.end);
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
    }
}
