//! Verifies the UI glyphs obey the geometry rules, so one glyph set serves every mode and state.
//!
//! A UI glyph is interface language, not decoration: it is drawn in whatever colour the consuming
//! component's token role calls for — approve-green, deny-red, agent-violet — by carrying no colour
//! of its own and inheriting `currentColor`. A glyph that baked in a literal colour would break that:
//! it would look wrong in half the states it appears in, and it would need a variant file per colour,
//! which is exactly the drift the single set exists to avoid. So the rule is strict and checkable: a
//! glyph is a 24x24 canvas, and its every fill and stroke is `currentColor` or `none` — never a hex
//! or named literal. This walks the glyph sources and fails the build on any that breaks it, so a
//! coloured glyph is caught before it ships rather than discovered as a wrong-colour icon on a screen.
//!
//! It checks the UI glyphs, whose colour is the component's to decide; the app tiles are a different
//! family with their own colour and are not scanned here.
//!
//! Exit codes: 0 every glyph is clean, 1 a glyph breaks a rule.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// Where the UI glyph sources live.
const glyphs_root = "design/icons/source/glyphs";

/// The canvas every glyph must declare.
const required_viewbox = "viewBox=\"0 0 24 24\"";

const max_glyph_bytes: usize = 256 * 1024;

const Finding = struct {
    file: []const u8,
    reason: []const u8,
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

    var root = try io_adapters.cwd().openDir(io, glyphs_root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();
    var scanned: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".svg")) continue;
        scanned += 1;

        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(max_glyph_bytes)) catch |read_error| switch (read_error) {
            error.StreamTooLong => {
                try findings.append(gpa, .{ .file = try arena.dupe(u8, entry.path), .reason = "glyph is unexpectedly large" });
                continue;
            },
            else => return read_error,
        };
        defer gpa.free(contents);

        const path = try arena.dupe(u8, entry.path);
        if (std.mem.indexOf(u8, contents, required_viewbox) == null) {
            try findings.append(gpa, .{ .file = path, .reason = "missing the 24x24 viewBox" });
        }
        if (hasHexColour(contents)) {
            try findings.append(gpa, .{ .file = path, .reason = "contains a hex colour literal; glyphs use currentColor only" });
        }
        if (badPaintValue(contents, arena)) |value| {
            try findings.append(gpa, .{ .file = path, .reason = try std.fmt.allocPrint(arena, "a fill or stroke is '{s}'; only currentColor or none is allowed", .{value}) });
        }
    }

    if (findings.items.len == 0) {
        try out.print("icon-lint: {d} glyphs are clean — currentColor only, 24x24\n", .{scanned});
        try out.flush();
        return 0;
    }
    for (findings.items) |finding| {
        try out.print("{s}/{s}: {s}\n", .{ glyphs_root, finding.file, finding.reason });
    }
    try out.print("icon-lint: {d} glyph rule violation(s)\n", .{findings.items.len});
    try out.flush();
    return 1;
}

/// Whether the content carries a hex colour: a `#` followed by a hex digit. Glyphs carry no colour,
/// so any hex at all is a literal that should not be there.
fn hasHexColour(content: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < content.len) : (i += 1) {
        if (content[i] == '#' and std.ascii.isHex(content[i + 1])) return true;
    }
    return false;
}

/// The first `fill=` or `stroke=` value that is not `currentColor` or `none`, or null if every one is
/// allowed. A literal here is a baked colour the component can no longer decide.
fn badPaintValue(content: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    for ([_][]const u8{ "fill=\"", "stroke=\"" }) |attr| {
        var rest = content;
        while (std.mem.indexOf(u8, rest, attr)) |at| {
            const start = at + attr.len;
            const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse break;
            const value = rest[start..end];
            if (!std.ascii.eqlIgnoreCase(value, "currentColor") and !std.ascii.eqlIgnoreCase(value, "none")) {
                return arena.dupe(u8, value) catch value;
            }
            rest = rest[end + 1 ..];
        }
    }
    return null;
}

// --- Tests ---

const testing = std.testing;

test "a hex colour anywhere is caught" {
    try testing.expect(hasHexColour("<path fill=\"#9a6cff\"/>"));
    try testing.expect(!hasHexColour("<path fill=\"currentColor\"/>"));
    try testing.expect(!hasHexColour("stroke-width=\"2\"")); // no # at all
}

test "a fill or stroke that is not currentColor or none is caught" {
    const arena = testing.allocator;
    try testing.expect(badPaintValue("<circle fill=\"currentColor\" stroke=\"none\"/>", arena) == null);
    const bad = badPaintValue("<circle fill=\"red\"/>", arena) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("red", bad);
    arena.free(bad);
}
