//! Verifies that raw colour is constructed only in the design token layer.
//!
//! A design system's promise — that what the accessibility tests prove legible is
//! what the screen shows — holds only while every colour a renderer paints comes from
//! one resolved source. The moment a rendering file constructs its own colour from raw
//! channel values, that promise is silently broken: the palette the contrast tests
//! cover and the palette the display emits are two different things. This check keeps
//! them one. Colour may be written as literal channel values only under the token
//! layer, which is the resolution's single home; anywhere in the graphics tree that
//! builds a colour from raw hex bytes is a leak, caught here rather than shipped as a
//! divergence a person would see but a test would not.
//!
//! Exit codes: 0 clean, 1 a raw colour leak found.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The tree whose files must not construct raw colour: the renderers. They read the
/// resolved palette; they do not author it.
const scanned_root = "graphics";

/// The one place raw colour legitimately lives, named in the leak message.
const token_home = "design/tokens";

const max_scanned_file_bytes: usize = 4 * 1024 * 1024;

/// A colour channel written with its full, unambiguous name. Nothing but a colour
/// is called `red`/`green`/`blue`/`alpha`, so an assignment of one of these to a
/// numeric literal — hex or decimal — is a raw colour being built by value.
const full_channels = [_][]const u8{ "red", "green", "blue", "alpha" };

/// A colour channel written as a single letter. These collide with ordinary math
/// fields (a bezier's `.a`, a vector's `.b`), so they are a leak only in the hex
/// form a colour is authored in — `.r = 0xNN` — never a bare decimal.
const short_channels = [_][]const u8{ "r", "g", "b", "a" };

const Finding = struct {
    path: []const u8,
    line: usize,
    pattern: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    var root = try io_adapters.cwd().openDir(io, scanned_root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(max_scanned_file_bytes)) catch |read_error| switch (read_error) {
            error.StreamTooLong => continue,
            else => return read_error,
        };
        defer gpa.free(contents);

        // Colour written by value inside a test is a fixture, not a renderer
        // authoring the palette; the check is about what paints the screen. Test
        // blocks are skipped so a legitimate `Color{ .red = 0, ... }` in a test
        // does not read as a leak, which lets the check reach decimal literals in
        // real code without flagging every test that builds a sample colour.
        const in_test = try markTestLines(gpa, contents);
        defer gpa.free(in_test);

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_number += 1) {
            if (in_test[line_number]) continue;
            const code = withoutComment(line);
            if (rawColourConstruct(code)) |channel| {
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ scanned_root, entry.path });
                try findings.append(gpa, .{ .path = full, .line = line_number + 1, .pattern = channel });
            }
        }
    }

    if (findings.items.len == 0) {
        try out.writeAll("palette-check: no raw colour is constructed outside the token layer\n");
        try out.flush();
        return 0;
    }
    for (findings.items) |finding| {
        try out.print("{s}:{d}: raw colour constructed outside the token layer ('{s}')\n", .{ finding.path, finding.line, finding.pattern });
    }
    try out.print("palette-check: {d} raw colour leak(s); construct colour only under {s}\n", .{ findings.items.len, token_home });
    try out.flush();
    return 1;
}

/// The colour channel a line constructs from a raw numeric literal, or null.
///
/// Three shapes are a leak: the `rgb(`/`rgba(` helpers given a number, a full
/// channel name (`red`/`green`/`blue`/`alpha`) assigned a number in either hex or
/// decimal, and a single-letter channel assigned a hex byte. A channel assigned a
/// non-literal — `.red = palette.accent` — is reading a resolved colour and is
/// fine; only a literal value is authoring one.
fn rawColourConstruct(code: []const u8) ?[]const u8 {
    for ([_][]const u8{ "rgba(", "rgb(" }) |helper| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, code, start, helper)) |position| {
            if (firstNonSpaceIsDigit(code[position + helper.len ..])) return helper;
            start = position + 1;
        }
    }

    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        if (code[index] != '.') continue;
        const rest = code[index + 1 ..];
        for (full_channels) |channel| {
            if (assignedLiteral(rest, channel)) |value| {
                if (value.len > 0 and std.ascii.isDigit(value[0])) return channel;
            }
        }
        for (short_channels) |channel| {
            if (assignedLiteral(rest, channel)) |value| {
                if (std.mem.startsWith(u8, value, "0x")) return channel;
            }
        }
    }
    return null;
}

/// If `rest` is `<channel> = <value>` (an assignment, not `==`), the trimmed
/// value; else null. `channel` must appear as a whole identifier.
fn assignedLiteral(rest: []const u8, channel: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest, channel)) return null;
    const after_name = rest[channel.len..];
    if (after_name.len > 0 and isIdentifierCharacter(after_name[0])) return null;
    const trimmed = std.mem.trimStart(u8, after_name, " \t");
    if (trimmed.len == 0 or trimmed[0] != '=') return null;
    if (trimmed.len >= 2 and trimmed[1] == '=') return null; // A comparison, not an assignment.
    return std.mem.trimStart(u8, trimmed[1..], " \t");
}

fn firstNonSpaceIsDigit(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    return trimmed.len > 0 and std.ascii.isDigit(trimmed[0]);
}

fn isIdentifierCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

/// Marks every line that sits inside a `test { ... }` block. Brace depth is
/// counted over comment-stripped, string-aware code so a `{` in a literal does
/// not open a phantom block.
fn markTestLines(gpa: std.mem.Allocator, contents: []const u8) ![]bool {
    const total = countLines(contents);
    const in_test = try gpa.alloc(bool, total);
    @memset(in_test, false);

    var depth: i32 = 0;
    var test_open_depth: i32 = -1;
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (index += 1) {
        const code = withoutComment(line);
        const trimmed = std.mem.trimStart(u8, code, " \t");
        if (test_open_depth >= 0) {
            in_test[index] = true;
        } else if (depth == 0 and isTestHeader(trimmed)) {
            in_test[index] = true;
            test_open_depth = depth;
        }
        depth += braceDelta(code);
        if (test_open_depth >= 0 and depth <= test_open_depth) test_open_depth = -1;
    }
    return in_test;
}

fn countLines(contents: []const u8) usize {
    var total: usize = 1;
    for (contents) |character| {
        if (character == '\n') total += 1;
    }
    return total;
}

fn isTestHeader(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "test")) return false;
    if (trimmed.len == 4) return true;
    return trimmed[4] == ' ' or trimmed[4] == '{' or trimmed[4] == '"';
}

/// The net `{` minus `}` on a line, ignoring braces inside string and character
/// literals so a `"{"` never miscounts the block structure.
fn braceDelta(code: []const u8) i32 {
    var delta: i32 = 0;
    var in_string = false;
    var in_char = false;
    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        const character = code[index];
        if ((in_string or in_char) and character == '\\') {
            index += 1;
            continue;
        }
        if (!in_char and character == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string and character == '\'') {
            in_char = !in_char;
            continue;
        }
        if (in_string or in_char) continue;
        if (character == '{') delta += 1;
        if (character == '}') delta -= 1;
    }
    return delta;
}

/// The text of a line with any line comment removed. A `//` inside a string or
/// character literal is not a comment, so string and char literals are tracked
/// and only a `//` outside them ends the code — otherwise a colour built after a
/// string containing `//` on the same line would be missed.
fn withoutComment(line: []const u8) []const u8 {
    var index: usize = 0;
    var in_string = false;
    var in_char = false;
    while (index < line.len) : (index += 1) {
        const character = line[index];
        if ((in_string or in_char) and character == '\\') {
            index += 1;
            continue;
        }
        if (!in_char and character == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string and character == '\'') {
            in_char = !in_char;
            continue;
        }
        if (!in_string and !in_char and character == '/' and
            index + 1 < line.len and line[index + 1] == '/')
        {
            return line[0..index];
        }
    }
    return line;
}

test "a full channel assigned a literal is a leak, in either radix" {
    try std.testing.expect(rawColourConstruct(".red = 255") != null);
    try std.testing.expect(rawColourConstruct("Color{ .green = 128, .blue = 0 }") != null);
    try std.testing.expect(rawColourConstruct(".alpha = 0xFF") != null);
}

test "the rgb and rgba helpers are a leak with either radix" {
    try std.testing.expect(rawColourConstruct("rgb(255, 0, 0)") != null);
    try std.testing.expect(rawColourConstruct("rgba(0x11, 0x22, 0x33, 0xff)") != null);
}

test "a short channel is a leak only in hex, never a bare decimal" {
    // .r/.g/.b/.a collide with ordinary math fields, so a decimal is not flagged.
    try std.testing.expect(rawColourConstruct(".r = 0xFF") != null);
    try std.testing.expect(rawColourConstruct(".a = 2") == null);
    try std.testing.expect(rawColourConstruct(".b = 4") == null);
}

test "a channel read from a resolved value is not a leak" {
    try std.testing.expect(rawColourConstruct(".red = palette.accent") == null);
    try std.testing.expect(rawColourConstruct("if (color.red == 0) {}") == null);
}

test "a colour built after a string with a comment marker is still seen" {
    // The string holds `//`; a stripper that truncated there would miss the colour.
    const code = withoutComment("const s = \"a//b\"; const c = .{ .red = 255 };");
    try std.testing.expect(rawColourConstruct(code) != null);
}

test "a colour literal inside a test block is skipped" {
    const source =
        \\pub fn paint() void {}
        \\test "sample" {
        \\    const black = .{ .red = 0, .green = 0, .blue = 0 };
        \\    _ = black;
        \\}
        \\
    ;
    const gpa = std.testing.allocator;
    const mask = try markTestLines(gpa, source);
    defer gpa.free(mask);
    try std.testing.expect(!mask[0]); // the renderer function
    try std.testing.expect(mask[2]); // the colour fixture inside the test
}
