//! Reduces an icon set to a single deterministic digest, so the icons in a build are content-addressed.
//!
//! Icons are assets a build carries, and like any asset they must be reproducible: two builds of the
//! same icons must produce the same result, and a changed icon must be visible as a change. This tool
//! reduces an icon set — each icon named by its role and carrying a content digest — to one digest over
//! the whole set. The reduction is order-independent: the icons are sorted by role before folding, so
//! the digest depends on which icons are present and what they contain, not on the order they were
//! listed. It carries nothing that varies between checkouts — no timestamps, no paths, no listing order
//! — so the same icon set always yields the same digest, and a single changed icon changes it. A build's
//! icon digest can then be compared across builds and recorded in the bill of materials, making the icon
//! set an auditable part of the build rather than an opaque bag of files.
//!
//! Exit codes: 0 the digest was computed, 1 the icon set is malformed (a duplicate role), 2 usage error
//! or an unreadable manifest.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// One icon: the role it fills and the digest of its contents.
pub const Icon = struct {
    role: []const u8,
    /// A short content digest of the icon, as an unsigned value (a real build would carry a full hash;
    /// the fold is identical either way).
    content: u64,
};

fn lessThanByRole(_: void, a: Icon, b: Icon) bool {
    return std.mem.lessThan(u8, a.role, b.role);
}

/// Whether an icon set has two icons claiming the same role — an ambiguity a build must not carry.
pub fn duplicateRole(icons: []const Icon) ?[]const u8 {
    for (icons, 0..) |icon, index| {
        for (icons[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.role, icon.role)) return icon.role;
        }
    }
    return null;
}

/// Reduces a sorted icon set to a single digest over each icon's role and content, in role order.
///
/// The caller must sort the icons by role first; the fold then depends only on the set's contents, not
/// on the order the icons were provided. Each icon contributes its role and its content digest, so
/// changing either an icon's role or its bytes changes the set digest.
pub fn digestOf(sorted_icons: []const Icon) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (sorted_icons) |icon| {
        hasher.update(icon.role);
        hasher.update(&.{0});
        hasher.update(std.mem.asBytes(&icon.content));
    }
    return hasher.final();
}

/// Parses one manifest line: "role content", where content is an unsigned integer digest.
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Icon {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const role = fields.next() orelse return error.Malformed;
    const content = try std.fmt.parseUnsigned(u64, fields.next() orelse return error.Malformed, 10);
    if (fields.next() != null) return error.Malformed;
    return .{ .role = try arena.dupe(u8, role), .content = content };
}

const Options = struct {
    manifest: []const u8 = "icons.txt",
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
        try err.print("icon-build: cannot read manifest '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var icons: std.ArrayList(Icon) = .empty;
    defer icons.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const icon = parseLine(arena, line) catch {
            try err.print("icon-build: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        try icons.append(gpa, icon);
    }

    if (duplicateRole(icons.items)) |role| {
        try err.print("icon-build: two icons claim the role '{s}'\n", .{role});
        try err.flush();
        return 1;
    }

    std.mem.sort(Icon, icons.items, {}, lessThanByRole);
    try out.print("icon-build: {d} icon(s), digest {x}\n", .{ icons.items.len, digestOf(icons.items) });
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
                \\usage: icon-build [--manifest FILE]
                \\
                \\Reduces an icon set to a single deterministic digest. Manifest lines are
                \\"role content"; the digest is order-independent and changes when any icon's role or
                \\content changes. A duplicate role is an error.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("icon-build: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("icon-build: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn sortedDigest(icons: []Icon) u64 {
    std.mem.sort(Icon, icons, {}, lessThanByRole);
    return digestOf(icons);
}

test "the digest is independent of listing order" {
    var a = [_]Icon{ .{ .role = "app", .content = 1 }, .{ .role = "settings", .content = 2 } };
    var b = [_]Icon{ .{ .role = "settings", .content = 2 }, .{ .role = "app", .content = 1 } };
    try std.testing.expectEqual(sortedDigest(&a), sortedDigest(&b));
}

test "a changed icon content changes the digest" {
    var base = [_]Icon{ .{ .role = "app", .content = 1 }, .{ .role = "settings", .content = 2 } };
    var changed = [_]Icon{ .{ .role = "app", .content = 9 }, .{ .role = "settings", .content = 2 } };
    try std.testing.expect(sortedDigest(&base) != sortedDigest(&changed));
}

test "a changed role changes the digest" {
    var base = [_]Icon{.{ .role = "app", .content = 1 }};
    var renamed = [_]Icon{.{ .role = "launcher", .content = 1 }};
    try std.testing.expect(sortedDigest(&base) != sortedDigest(&renamed));
}

test "a duplicate role is detected" {
    const icons = [_]Icon{ .{ .role = "app", .content = 1 }, .{ .role = "app", .content = 2 } };
    try std.testing.expectEqualStrings("app", duplicateRole(&icons).?);
}

test "a set with unique roles has no duplicate" {
    const icons = [_]Icon{ .{ .role = "app", .content = 1 }, .{ .role = "settings", .content = 2 } };
    try std.testing.expectEqual(@as(?[]const u8, null), duplicateRole(&icons));
}

test "the digest is stable across repeated computation" {
    var icons = [_]Icon{ .{ .role = "b", .content = 5 }, .{ .role = "a", .content = 3 } };
    const first = sortedDigest(&icons);
    const second = sortedDigest(&icons);
    try std.testing.expectEqual(first, second);
}
