//! Verifies that no stand-in reaches production code.
//!
//! A stand-in is something that satisfies an interface without providing what
//! the interface exists to guarantee: a secure element implemented in software,
//! a clock a caller advances by hand, a generator seeded to repeat. Each is
//! necessary — the platform cannot be exercised without them — and each is a
//! bypass if it ends up on a path a device takes.
//!
//! The danger is not that they exist. It is that substituting one is invisible.
//! A build that quietly used the software element would pass every test, because
//! every test would be testing the stand-in.
//!
//! What this checks: production trees name no stand-in outside their tests. Test
//! support is recognized rather than exempted by convention — a private
//! declaration that nothing outside a test block refers to is test support, and
//! that is computed rather than asserted, so a helper cannot be smuggled onto a
//! production path by naming it something innocuous.
//!
//! Exit codes: 0 clean, 1 a stand-in reaches production code, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// Trees whose code runs on a device.
const production_trees = [_][]const u8{
    "agents/",
    "applications/",
    "boot/",
    "communications/",
    "core/",
    "design/",
    "graphics/",
    "hardware/",
    "input/",
    "ipc/",
    "kernel/",
    "media/",
    "networking/",
    "packaging/",
    "runtimes/",
    "security/",
    "services/",
    "session/",
    "shell/",
    "storage/",
    "store/",
};

/// Trees that exist to exercise the platform. A stand-in here is the point.
///
/// Absent from `production_trees` rather than listed as exempt, so a new tree is
/// unchecked until someone decides which it is, and the decision is a visible
/// edit either way.
const names = [_][]const u8{
    "SoftwareElement",
    "ManualClock",
    "MemorySigner",
    "initDeterministic",
    "generateDeterministic",
    "initFromEntropy",
};

const max_scanned_file_bytes = 4 * 1024 * 1024;

const Finding = struct {
    path: []const u8,
    line_number: usize,
    name: []const u8,
    text: []const u8,
};

const Options = struct {
    root: []const u8 = ".",
    format: Format = .text,

    const Format = enum { text, json };
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

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    var root = try io_adapters.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (!isProduction(entry.path)) continue;

        const contents = root.readFileAlloc(
            io,
            entry.path,
            gpa,
            .limited(max_scanned_file_bytes),
        ) catch |read_error| switch (read_error) {
            error.StreamTooLong => continue,
            else => return read_error,
        };
        defer gpa.free(contents);

        const owned_path = try arena.dupe(u8, entry.path);
        try collectFindings(arena, gpa, owned_path, contents, &findings);
    }

    switch (options.format) {
        .text => try reportText(out, findings.items),
        .json => try reportJson(out, findings.items),
    }
    try out.flush();

    return if (findings.items.len == 0) 0 else 1;
}

pub fn isProduction(path: []const u8) bool {
    for (production_trees) |tree| {
        if (std.mem.startsWith(u8, path, tree)) return true;
    }
    return false;
}

/// Which lines a device's code could execute.
///
/// Everything else is test support: a `test` block, or a declaration that only
/// test blocks refer to. The second is computed to a fixed point, because test
/// support built from other test support is still test support, and one pass
/// would miss the fixture that a fixture uses.
const Reachable = struct {
    /// One entry per line. False means no production path reaches it.
    lines: []bool,

    fn deinit(reachable: Reachable, gpa: std.mem.Allocator) void {
        gpa.free(reachable.lines);
    }
};

fn classify(gpa: std.mem.Allocator, contents: []const u8) !Reachable {
    const total = countLines(contents);
    const reachable = try gpa.alloc(bool, total);
    @memset(reachable, true);

    // Test blocks first: a `test` at column zero, through to the line whose
    // closing brace returns to depth zero.
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |text| : (index += 1) {
        if (!isTestHeader(text)) continue;
        var depth: isize = 0;
        var scan = index;
        var scanner = std.mem.splitScalar(u8, contents, '\n');
        for (0..index) |_| _ = scanner.next();
        while (scanner.next()) |body| {
            reachable[scan] = false;
            depth += braceDelta(body);
            scan += 1;
            if (depth <= 0 and scan > index) break;
            if (scan >= total) break;
        }
    }

    // Then declarations nothing reachable refers to, repeatedly, until a pass
    // finds nothing more.
    while (true) {
        var removed = false;
        var declaration_index: usize = 0;
        var declarations = std.mem.splitScalar(u8, contents, '\n');
        while (declarations.next()) |text| : (declaration_index += 1) {
            if (!reachable[declaration_index]) continue;
            const declared = declaredName(text) orelse continue;
            // A published declaration is reachable by definition: something
            // outside this file may use it, and this tool cannot see that.
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t"), "pub ")) continue;

            // The declaration's own body is not evidence that anything uses it.
            // A struct whose methods take a pointer to it would otherwise look
            // permanently referenced by itself.
            const end = declarationEnd(contents, declaration_index, total);
            if (referencedByReachable(contents, reachable, declared, declaration_index, end)) continue;

            for (declaration_index..end) |line| reachable[line] = false;
            removed = true;
        }
        if (!removed) break;
    }

    return .{ .lines = reachable };
}

/// Whether the top-level declaration containing this line is itself a stand-in.
fn enclosingStandIn(contents: []const u8, line: usize) bool {
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var enclosing: ?[]const u8 = null;
    var enclosing_end: usize = 0;
    while (lines.next()) |text| : (index += 1) {
        if (index > line) break;
        if (index >= enclosing_end) enclosing = null;
        if (declaredName(text)) |declared| {
            const end = declarationEnd(contents, index, countLines(contents));
            if (line >= index and line < end) {
                enclosing = declared;
                enclosing_end = end;
            }
        }
    }
    const declared = enclosing orelse return false;
    for (names) |name| {
        if (std.mem.eql(u8, declared, name)) return true;
    }
    return false;
}

/// The line after the last one belonging to a declaration.
fn declarationEnd(contents: []const u8, start: usize, total: usize) usize {
    var depth: isize = 0;
    var index = start;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    for (0..start) |_| _ = lines.next();
    while (lines.next()) |text| {
        depth += braceDelta(text);
        index += 1;
        if (depth <= 0) return index;
        if (index >= total) return total;
    }
    return total;
}

/// Whether any line a device could execute, outside the declaration itself,
/// mentions this name.
fn referencedByReachable(
    contents: []const u8,
    reachable: []const bool,
    name: []const u8,
    start: usize,
    end: usize,
) bool {
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |text| : (index += 1) {
        if (index >= start and index < end) continue;
        if (!reachable[index]) continue;
        if (containsWord(withoutComment(text), name)) return true;
    }
    return false;
}

fn collectFindings(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const reachable = try classify(gpa, contents);
    defer reachable.deinit(gpa);

    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |text| : (index += 1) {
        if (!reachable.lines[index]) continue;
        const code = withoutComment(text);
        for (names) |name| {
            if (!containsWord(code, name)) continue;
            // The file that declares a stand-in necessarily names it.
            if (declaresName(contents, name)) continue;
            // A stand-in is built out of stand-in machinery. Reporting the
            // software element for generating a key deterministically would be
            // reporting it for being what it says it is.
            if (enclosingStandIn(contents, index)) continue;
            try findings.append(gpa, .{
                .path = path,
                .line_number = index + 1,
                .name = name,
                .text = try arena.dupe(u8, std.mem.trim(u8, text, " \t\r")),
            });
            break;
        }
    }
}

fn countLines(contents: []const u8) usize {
    var total: usize = 1;
    for (contents) |character| {
        if (character == '\n') total += 1;
    }
    return total;
}

fn isTestHeader(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "test")) return false;
    if (text.len == 4) return true;
    return text[4] == ' ' or text[4] == '{';
}

fn braceDelta(text: []const u8) isize {
    const code = withoutComment(text);
    var delta: isize = 0;
    var in_string = false;
    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        const character = code[index];
        if (character == '\\' and in_string) {
            index += 1;
            continue;
        }
        if (character == '"') in_string = !in_string;
        if (in_string) continue;
        if (character == '{') delta += 1;
        if (character == '}') delta -= 1;
    }
    return delta;
}

/// The name a line declares, if it declares one at the top level of a file.
fn declaredName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len == text.len) {
        // Only top-level declarations: an indented one belongs to something
        // that has already been classified.
    } else return null;

    // A published declaration is still a declaration. Whether it is reachable
    // is decided separately; this only reports what it is called.
    const body = if (std.mem.startsWith(u8, trimmed, "pub "))
        trimmed["pub ".len..]
    else
        trimmed;

    const keywords = [_][]const u8{ "const ", "fn ", "var " };
    for (keywords) |keyword| {
        if (!std.mem.startsWith(u8, body, keyword)) continue;
        const rest = body[keyword.len..];
        var end: usize = 0;
        while (end < rest.len and isIdentifierCharacter(rest[end])) : (end += 1) {}
        if (end == 0) return null;
        return rest[0..end];
    }
    return null;
}

/// Whether this file declares the name itself.
fn declaresName(contents: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |text| {
        const trimmed = std.mem.trimStart(u8, text, " \t");
        const forms = [_][]const u8{ "pub const ", "const ", "pub fn ", "fn " };
        for (forms) |form| {
            if (!std.mem.startsWith(u8, trimmed, form)) continue;
            const rest = trimmed[form.len..];
            if (!std.mem.startsWith(u8, rest, name)) continue;
            if (rest.len == name.len) return true;
            if (!isIdentifierCharacter(rest[name.len])) return true;
        }
    }
    return false;
}

fn withoutComment(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "//")) |position| return text[0..position];
    return text;
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |position| {
        const before_ok = position == 0 or !isIdentifierCharacter(haystack[position - 1]);
        const after = position + needle.len;
        const after_ok = after >= haystack.len or !isIdentifierCharacter(haystack[after]);
        if (before_ok and after_ok) return true;
        start = position + 1;
    }
    return false;
}

fn isIdentifierCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

fn reportText(out: *std.Io.Writer, findings: []const Finding) !void {
    if (findings.len == 0) {
        try out.writeAll("standin-check: no stand-in reaches production code\n");
        return;
    }
    for (findings) |finding| {
        try out.print("{s}:{d}: stand-in '{s}' on a production path\n    {s}\n", .{
            finding.path,
            finding.line_number,
            finding.name,
            finding.text,
        });
    }
    try out.print("\nstandin-check: {d} stand-in(s) reachable from production code\n", .{
        findings.len,
    });
}

fn reportJson(out: *std.Io.Writer, findings: []const Finding) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("clean");
    try stringify.write(findings.len == 0);
    try stringify.objectField("findings");
    try stringify.beginArray();
    for (findings) |finding| {
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(finding.path);
        try stringify.objectField("line");
        try stringify.write(finding.line_number);
        try stringify.objectField("name");
        try stringify.write(finding.name);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    try out.writeByte('\n');
}

fn parseArguments(
    args: []const [:0]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            try writeUsage(out);
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, argument, "--root=")) {
            options.root = argument["--root=".len..];
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("standin-check: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            try err.print("standin-check: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: standin-check [options]
        \\
        \\Reports any stand-in named on a path a device could execute. A stand-in
        \\satisfies an interface without providing what the interface exists to
        \\guarantee: a secure element in software, a clock advanced by hand, a
        \\generator seeded to repeat.
        \\
        \\Test blocks are excluded, as are declarations that only test blocks
        \\refer to. That is computed rather than assumed, so a helper cannot be
        \\moved onto a production path by renaming it.
        \\
        \\Options:
        \\  --root=<path>       Directory to scan (default: .)
        \\  --format=text|json  Output format (default: text)
        \\  -h, --help          Show this message
        \\
        \\Exit codes:
        \\  0  no stand-in reaches production code
        \\  1  at least one does
        \\  2  usage error
        \\
    );
}

test "the trees a device runs are the ones checked" {
    try std.testing.expect(isProduction("core/time/time.zig"));
    try std.testing.expect(isProduction("hardware/secure-element/secure_element.zig"));

    // The simulator, the emulator, the tests, and the tools exist to exercise
    // the platform. A stand-in there is the point.
    try std.testing.expect(!isProduction("simulator/scenarios/boot.zig"));
    try std.testing.expect(!isProduction("emulator/device/device.zig"));
    try std.testing.expect(!isProduction("tests/acceptance/agent_shell.zig"));
    try std.testing.expect(!isProduction("tools/standin-check/main.zig"));
}

test "a stand-in used by production code is reported" {
    const source =
        \\const secure_element = @import("hardware").secure_element;
        \\
        \\pub fn start() void {
        \\    var element: secure_element.SoftwareElement = .{};
        \\    _ = element;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try countFindings(source));
}

test "a stand-in used only by a test is not reported" {
    const source =
        \\pub fn start() void {}
        \\
        \\test "it starts" {
        \\    var element: secure_element.SoftwareElement = .{};
        \\    _ = element;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "a fixture that only tests use is test support" {
    // The pattern this tool exists to handle: a helper declared beside the code
    // it exercises, at the top level, used by several tests.
    const source =
        \\pub fn start() void {}
        \\
        \\const Fixture = struct {
        \\    fn make() void {
        \\        var element: secure_element.SoftwareElement = .{};
        \\        _ = element;
        \\    }
        \\};
        \\
        \\test "one" {
        \\    Fixture.make();
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "a fixture reached from production code is not test support" {
    const source =
        \\pub fn start() void {
        \\    Helper.make();
        \\}
        \\
        \\const Helper = struct {
        \\    fn make() void {
        \\        var element: secure_element.SoftwareElement = .{};
        \\        _ = element;
        \\    }
        \\};
        \\
        \\test "one" {
        \\    Helper.make();
        \\}
        \\
    ;
    // Renaming a fixture does not move it off the production path, and neither
    // does calling it from a test as well.
    try std.testing.expectEqual(@as(usize, 1), try countFindings(source));
}

test "test support built from test support is still test support" {
    const source =
        \\pub fn start() void {}
        \\
        \\const Inner = struct {
        \\    fn make() void {
        \\        var clock: ManualClock = .{};
        \\        _ = clock;
        \\    }
        \\};
        \\
        \\const Outer = struct {
        \\    fn make() void {
        \\        Inner.make();
        \\    }
        \\};
        \\
        \\test "one" {
        \\    Outer.make();
        \\}
        \\
    ;
    // One pass would clear Outer and stop, leaving Inner looking reachable.
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "the file that declares a stand-in may name it" {
    const source =
        \\pub const SoftwareElement = struct {
        \\    pub fn element(software: *SoftwareElement) void {
        \\        _ = software;
        \\    }
        \\};
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "a published declaration is treated as reachable" {
    // Nothing in this file uses it, but another module might, and this tool
    // cannot see that. Assuming otherwise would let a stand-in be exported.
    const source =
        \\pub fn makeElement() void {
        \\    var element: secure_element.SoftwareElement = .{};
        \\    _ = element;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try countFindings(source));
}

test "a stand-in may be built out of stand-in machinery" {
    // The software element generates its keys deterministically. Reporting that
    // would be reporting it for being what it already says it is.
    const source =
        \\pub const SoftwareElement = struct {
        \\    fn create() void {
        \\        const pair = KeyPair.generateDeterministic(seed);
        \\        _ = pair;
        \\    }
        \\};
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "code beside a stand-in is still checked" {
    const source =
        \\pub const SoftwareElement = struct {
        \\    fn create() void {}
        \\};
        \\
        \\pub fn start() void {
        \\    const pair = KeyPair.generateDeterministic(seed);
        \\    _ = pair;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try countFindings(source));
}

test "a mention in a comment is not a use" {
    const source =
        \\// Never construct a SoftwareElement here.
        \\pub fn start() void {}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

test "a longer identifier that contains a stand-in name is not a use" {
    const source =
        \\pub fn start() void {
        \\    var thing: SoftwareElementFactoryish = .{};
        \\    _ = thing;
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try countFindings(source));
}

fn countFindings(source: []const u8) !usize {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    try collectFindings(arena_state.allocator(), gpa, "sample.zig", source, &findings);
    return findings.items.len;
}
