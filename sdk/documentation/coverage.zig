//! Deciding whether an SDK surface is documented well enough to publish, so no public symbol ships
//! without an explanation a developer can read.
//!
//! The SDK's public surface is a contract, and a public function with no documentation is a contract
//! with a blank clause: a developer meets it, cannot tell what it does or what its arguments mean,
//! and guesses — which is how misuse and support burden are born. So publishing an SDK version
//! requires that every public symbol carries documentation. Internal symbols are exempt, because
//! they are not part of the promise a developer builds against, but anything exposed must be
//! explained. The check is coverage: the count of documented public symbols against the total, and
//! full coverage is the bar to publish. A surface below full coverage is not published; the
//! undocumented symbols are reported so the author can write the missing docs. Requiring complete
//! documentation of the public surface is what makes the SDK learnable from the SDK itself rather
//! than from trial and error.
//!
//! This module writes no docs. It decides whether a public surface is fully documented, from the
//! per-symbol documentation state, as pure functions.

const std = @import("std");

/// A public SDK symbol and whether it is documented.
pub const Symbol = struct {
    name: []const u8,
    documented: bool,
};

/// The count of documented public symbols and the total.
pub const Coverage = struct {
    documented: u32,
    total: u32,

    /// Whether the surface is fully documented — every public symbol has documentation. An empty
    /// surface is trivially covered.
    pub fn complete(coverage: Coverage) bool {
        return coverage.documented == coverage.total;
    }
};

/// Measures documentation coverage over a set of public symbols.
pub fn measure(symbols: []const Symbol) Coverage {
    var documented: u32 = 0;
    for (symbols) |symbol| {
        if (symbol.documented) documented += 1;
    }
    return .{ .documented = documented, .total = @intCast(symbols.len) };
}

/// Whether a public surface may be published: it must be fully documented.
pub fn mayPublish(symbols: []const Symbol) bool {
    return measure(symbols).complete();
}

/// Finds the first undocumented public symbol, or null if all are documented, so the author knows
/// exactly what to write.
pub fn firstUndocumented(symbols: []const Symbol) ?[]const u8 {
    for (symbols) |symbol| {
        if (!symbol.documented) return symbol.name;
    }
    return null;
}

test "a fully documented surface may publish" {
    const symbols = [_]Symbol{
        .{ .name = "connect", .documented = true },
        .{ .name = "send", .documented = true },
    };
    try std.testing.expect(mayPublish(&symbols));
}

test "an undocumented symbol blocks publishing and is reported" {
    const symbols = [_]Symbol{
        .{ .name = "connect", .documented = true },
        .{ .name = "send", .documented = false },
    };
    try std.testing.expect(!mayPublish(&symbols));
    try std.testing.expectEqualStrings("send", firstUndocumented(&symbols).?);
}

test "an empty surface is trivially publishable" {
    try std.testing.expect(mayPublish(&.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), firstUndocumented(&.{}));
}

test "coverage counts documented against total" {
    const symbols = [_]Symbol{
        .{ .name = "a", .documented = true },
        .{ .name = "b", .documented = false },
        .{ .name = "c", .documented = true },
    };
    const coverage = measure(&symbols);
    try std.testing.expectEqual(@as(u32, 2), coverage.documented);
    try std.testing.expectEqual(@as(u32, 3), coverage.total);
}

test "publishing implies every symbol documented, swept" {
    // The complete-contract property: whenever a surface may publish, there is no undocumented
    // symbol.
    const surfaces = [_][]const Symbol{
        &.{.{ .name = "a", .documented = true }},
        &.{.{ .name = "a", .documented = false }},
        &.{ .{ .name = "a", .documented = true }, .{ .name = "b", .documented = false } },
    };
    for (surfaces) |symbols| {
        if (mayPublish(symbols)) {
            try std.testing.expectEqual(@as(?[]const u8, null), firstUndocumented(symbols));
        }
    }
}
