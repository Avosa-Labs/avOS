//! The map-or-justify gate: every significant colour the design uses must be accounted
//! for — bound to a token role or listed as a justified exception.
//!
//! The reference map records what each design colour means; this gate holds the map to
//! the extraction. It reads the committed colour vectors and, for every opaque colour the
//! design uses often enough to be semantic, checks that it is either mapped to a token
//! role or justified in `design.reference_map`. A significant colour that is neither fails
//! the build — which is what turns "100% conformant" into an enumerable claim: a new
//! colour in the design cannot slip in unexamined; someone must map it or justify it.
//!
//! It reads the vectors as text (not the 1 MB design), so it runs on every machine. The
//! token-level check — that a mapped token still equals its design colour — lives as a
//! test beside the map; this is the coverage half.
//!
//! Exit codes: 0 every significant colour accounted for, 1 an unaccounted colour, 3 the
//! vectors are missing (run `zig build design-extract`).

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const design = @import("design");

const colour_vectors = "test-vectors/design/colour.zon";

/// A colour used at least this many times, and fully opaque, is treated as semantic and
/// must be accounted for. Rarer colours and translucent overlays are exempt: they are
/// one-offs and scrims, not the design's palette.
const significant_count: u32 = 20;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buf);
    const out = &out_file.interface;

    const text = io_adapters.cwd().readFileAlloc(io, colour_vectors, gpa, .limited(4 * 1024 * 1024)) catch {
        try out.print("design-conformance: {s} missing; run 'zig build design-extract' first\n", .{colour_vectors});
        try out.flush();
        return 3;
    };
    defer gpa.free(text);

    var unaccounted: usize = 0;
    var checked: usize = 0;

    // Each entry line carries `.hex = "X", .count = N`. Walk them.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, ".hex = \"")) |at| {
        const hex_start = at + ".hex = \"".len;
        const hex_end = std.mem.indexOfScalarPos(u8, text, hex_start, '"') orelse break;
        const hex = text[hex_start..hex_end];
        search = hex_end + 1;

        const count = readCount(text, hex_end) orelse 0;
        // Only opaque (rrggbb) colours at or above the threshold are semantic.
        if (hex.len != 6) continue;
        if (count < significant_count) continue;

        checked += 1;
        if (accountedFor(hex)) continue;
        unaccounted += 1;
        try out.print("{s}: colour #{s} (used {d}\u{00D7}) is neither mapped to a token nor justified\n", .{ colour_vectors, hex, count });
    }

    if (unaccounted == 0) {
        try out.print("design-conformance: all {d} significant design colours are mapped or justified\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("\ndesign-conformance: {d} unaccounted colour(s) — map each to a token role or justify it in design/tokens/reference_map.zig\n", .{unaccounted});
    try out.flush();
    return 1;
}

/// Whether a hex is bound to a token role or listed as a justified exception.
fn accountedFor(hex: []const u8) bool {
    for (design.reference_map.mappings) |mapping| {
        if (std.mem.eql(u8, mapping.hex, hex)) return true;
    }
    for (design.reference_map.justifications) |j| {
        if (std.mem.eql(u8, j.hex, hex)) return true;
    }
    return false;
}

/// The `.count = N` that follows a hex on the same entry.
fn readCount(text: []const u8, from: usize) ?u32 {
    const marker = ".count = ";
    const at = std.mem.indexOfPos(u8, text, from, marker) orelse return null;
    var i = at + marker.len;
    var value: u32 = 0;
    var any = false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = value * 10 + (text[i] - '0');
        any = true;
    }
    return if (any) value else null;
}

const testing = std.testing;

test "readCount reads the count after a hex entry" {
    const line = ".{ .hex = \"9a6cff\", .count = 131, .linear = ";
    const hex_end = std.mem.indexOfScalarPos(u8, line, 9, '"').?;
    try testing.expectEqual(@as(?u32, 131), readCount(line, hex_end));
}

test "the mapped agent colour and a justified neutral are both accounted for" {
    try testing.expect(accountedFor("9a6cff")); // mapped to agent
    try testing.expect(accountedFor("ffffff")); // justified neutral
    try testing.expect(!accountedFor("123456")); // an invented colour is not
}
