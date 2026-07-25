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

/// Patterns that construct a colour from raw channel literals. A match is a leak.
/// These catch the two ways a colour is built by value — the `rgb(0x..`/`rgba(0x..`
/// helpers and a struct literal setting a colour channel to a hex byte — without
/// matching bit masks or checksum constants, which never name a colour channel.
const leak_patterns = [_][]const u8{
    "rgb(0x",
    "rgba(0x",
    ".red = 0x",
    ".green = 0x",
    ".blue = 0x",
    ".r = 0x",
    ".g = 0x",
    ".b = 0x",
};

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

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            const code = withoutComment(line);
            for (leak_patterns) |pattern| {
                if (std.mem.indexOf(u8, code, pattern) == null) continue;
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ scanned_root, entry.path });
                try findings.append(gpa, .{ .path = full, .line = line_number, .pattern = pattern });
                break;
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

/// The text of a line with any line comment removed, so a colour named in prose is
/// not mistaken for one constructed in code.
fn withoutComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "//")) |at| return line[0..at];
    return line;
}
