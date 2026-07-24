//! Verifies localization completeness and fallback, so no shipping locale leaves a person facing a
//! missing string.
//!
//! A localized platform promises that a person who chose a language sees that language. The way that
//! promise breaks is quiet: a new string is added, most locales translate it, one does not, and a
//! person in that locale meets a blank or a raw key at exactly the moment the feature is new. Two rules
//! keep the promise. A shipping locale must be complete — it translates every key the base locale
//! defines — or, where it is not yet complete, every missing key must fall back to a locale that does
//! have it, so the person sees a real string in some language rather than nothing. A locale that is
//! neither complete nor fully covered by fallback is not shippable, because it has keys that resolve to
//! emptiness. The tool reports, per locale, the keys that are missing and whether fallback covers them,
//! so the gap is either translated or consciously accepted as a fallback rather than shipped as a hole.
//!
//! Exit codes: 0 every shipping locale resolves every key, 1 a locale has an uncovered missing key or a
//! manifest cannot be read, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// Whether a set of provided keys contains a key.
fn provides(keys: []const []const u8, key: []const u8) bool {
    for (keys) |provided| {
        if (std.mem.eql(u8, provided, key)) return true;
    }
    return false;
}

/// Whether a locale resolves a key: it either translates the key itself, or a fallback locale does.
///
/// Resolution is not the same as translation. A locale that lacks a key still resolves it if the
/// fallback provides it, because the person sees a real string; a locale that lacks a key the fallback
/// also lacks does not resolve it, and that is the hole the check exists to catch.
pub fn resolves(locale_keys: []const []const u8, fallback_keys: []const []const u8, key: []const u8) bool {
    return provides(locale_keys, key) or provides(fallback_keys, key);
}

/// The first base key a locale fails to resolve — missing from both the locale and its fallback — or
/// null if the locale resolves every base key. Base keys are checked in order for a deterministic
/// report.
pub fn firstUnresolved(
    base_keys: []const []const u8,
    locale_keys: []const []const u8,
    fallback_keys: []const []const u8,
) ?[]const u8 {
    for (base_keys) |key| {
        if (!resolves(locale_keys, fallback_keys, key)) return key;
    }
    return null;
}

/// Whether a locale is shippable: it resolves every base key, by its own translation or by fallback.
pub fn shippable(
    base_keys: []const []const u8,
    locale_keys: []const []const u8,
    fallback_keys: []const []const u8,
) bool {
    return firstUnresolved(base_keys, locale_keys, fallback_keys) == null;
}

const Options = struct {
    manifest: []const u8 = "locales.txt",
};

/// A locale parsed from the manifest: its name and the keys it translates.
const Locale = struct {
    name: []const u8,
    keys: []const []const u8,
    is_base: bool,
    is_fallback: bool,
};

/// Parses the manifest. Each line is "locale key1 key2 …"; a locale may be tagged by a leading marker
/// on its name: "@base" designates the base key set, "@fallback" the fallback locale. All other lines
/// are shipping locales checked against the base, with the fallback covering their gaps.
fn parseManifest(arena: std.mem.Allocator, contents: []const u8) ![]const Locale {
    var locales: std.ArrayList(Locale) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        var name = fields.next() orelse return error.Malformed;
        var is_base = false;
        var is_fallback = false;
        if (std.mem.startsWith(u8, name, "@base:")) {
            is_base = true;
            name = name["@base:".len..];
        } else if (std.mem.startsWith(u8, name, "@fallback:")) {
            is_fallback = true;
            name = name["@fallback:".len..];
        }
        var keys: std.ArrayList([]const u8) = .empty;
        while (fields.next()) |key| try keys.append(arena, try arena.dupe(u8, key));
        try locales.append(arena, .{
            .name = try arena.dupe(u8, name),
            .keys = try keys.toOwnedSlice(arena),
            .is_base = is_base,
            .is_fallback = is_fallback,
        });
    }
    return locales.toOwnedSlice(arena);
}

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
        try err.print("localization: cannot read manifest '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    const locales = parseManifest(arena, contents) catch {
        try err.print("localization: malformed manifest '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };

    var base_keys: []const []const u8 = &.{};
    var fallback_keys: []const []const u8 = &.{};
    for (locales) |locale| {
        if (locale.is_base) base_keys = locale.keys;
        if (locale.is_fallback) fallback_keys = locale.keys;
    }

    var unshippable: usize = 0;
    var checked: usize = 0;
    for (locales) |locale| {
        if (locale.is_base) continue; // The base defines the keys; it is not checked against itself.
        checked += 1;
        if (firstUnresolved(base_keys, locale.keys, fallback_keys)) |key| {
            unshippable += 1;
            try out.print("  FAIL  {s}  (key '{s}' missing with no fallback)\n", .{ locale.name, key });
        } else {
            try out.print("  ok    {s}\n", .{locale.name});
        }
    }

    if (unshippable == 0) {
        try out.print("localization: {d} locale(s) checked, all resolve every key\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("localization: {d} of {d} locale(s) have an uncovered missing key\n", .{ unshippable, checked });
    try out.flush();
    return 1;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: localization [--manifest FILE]
                \\
                \\Verifies that every shipping locale resolves every base key, by its own translation
                \\or by fallback. Manifest lines are "locale key1 key2 ...", with "@base:name" marking
                \\the base key set and "@fallback:name" the fallback locale.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("localization: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("localization: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

const base = [_][]const u8{ "greeting", "farewell", "confirm" };

test "a complete locale resolves every key" {
    const full = [_][]const u8{ "greeting", "farewell", "confirm" };
    try std.testing.expect(shippable(&base, &full, &.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), firstUnresolved(&base, &full, &.{}));
}

test "a missing key covered by fallback still resolves" {
    const partial = [_][]const u8{ "greeting", "confirm" };
    const fallback = [_][]const u8{ "greeting", "farewell", "confirm" };
    try std.testing.expect(shippable(&base, &partial, &fallback));
}

test "a missing key with no fallback is unresolved and reported" {
    const partial = [_][]const u8{ "greeting", "confirm" };
    try std.testing.expect(!shippable(&base, &partial, &.{}));
    try std.testing.expectEqualStrings("farewell", firstUnresolved(&base, &partial, &.{}).?);
}

test "a key missing from both locale and fallback is unresolved" {
    const partial = [_][]const u8{"greeting"};
    const weak_fallback = [_][]const u8{"greeting"};
    try std.testing.expectEqualStrings("farewell", firstUnresolved(&base, &partial, &weak_fallback).?);
}

test "a shippable locale resolves every base key, swept" {
    // The no-hole property: if a locale is shippable, every base key is provided by it or the fallback.
    const locale_sets = [_][]const []const u8{
        &.{ "greeting", "farewell", "confirm" },
        &.{ "greeting", "confirm" },
        &.{"greeting"},
    };
    const fallback = [_][]const u8{ "greeting", "farewell" };
    for (locale_sets) |locale_keys| {
        if (shippable(&base, locale_keys, &fallback)) {
            for (base) |key| {
                try std.testing.expect(resolves(locale_keys, &fallback, key));
            }
        }
    }
}
