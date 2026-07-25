//! Deciding which recovery options a device posture offers and in what order, so a person in
//! trouble reaches for the gentlest fix first and the irreversible one only when nothing is left.
//!
//! Recovery is presented when a device cannot bring itself up normally, and the person reading
//! it is often stressed and not an expert. The options differ enormously in cost: a retry loses
//! nothing, safe mode loses nothing, restoring a backup rewinds recent changes, and a factory
//! reset erases everything. Presenting them least-destructive first is not cosmetic — it steers
//! the frightened person toward the fix that solves the problem with the least loss, and it
//! keeps the erase-everything option last so it is never the reflexive first tap. A healthy
//! device is not in recovery at all, so it offers nothing. Which options appear depends on how
//! badly the device is broken, but wherever factory reset appears it appears last.
//!
//! This module resets nothing. It decides which recovery options a posture offers and their
//! order, as a pure function over the posture, written into a caller-provided buffer.

const std = @import("std");

/// How the device is faring, which decides how much recovery it needs.
pub const Posture = enum {
    /// Booting and running normally. Offers no recovery.
    healthy,
    /// Running but misbehaving. Offers the gentle fixes.
    degraded,
    /// Cannot complete boot. Offers the fuller ladder including a reset.
    boot_failed,
    /// Storage is unreadable, so nothing gentler can help. Only a reset remains.
    storage_failed,
};

/// A recovery option, ordered by how much the person stands to lose, least first.
pub const Option = enum(u8) {
    /// Try the same boot again; loses nothing.
    retry = 0,
    /// Boot with third-party extensions disabled; loses nothing.
    safe_mode = 1,
    /// Restore from the last backup; rewinds recent changes.
    restore_backup = 2,
    /// Erase everything and start clean; irreversible, the last resort.
    factory_reset = 3,
};

/// The most options any single posture can offer, so callers can size a fixed buffer.
pub const max_options = @typeInfo(Option).@"enum".fields.len;

/// Writes the recovery options offered for a posture into `buf`, least-destructive first, and
/// returns the slice actually written.
///
/// A healthy device is not in recovery, so it offers nothing. A degraded device gets the gentle
/// fixes that lose no data. A failed boot gets the full ladder, with the irreversible reset last
/// so a less costly option is always tried first. Total storage failure leaves nothing gentler
/// able to help, so only the reset is offered — but it is still the one and only entry, never
/// jumped to ahead of an option that could have worked.
pub fn optionsFor(posture: Posture, buf: []Option) []const Option {
    const offered: []const Option = switch (posture) {
        .healthy => &.{},
        .degraded => &.{ .retry, .safe_mode },
        .boot_failed => &.{ .retry, .safe_mode, .restore_backup, .factory_reset },
        .storage_failed => &.{.factory_reset},
    };
    std.mem.copyForwards(Option, buf[0..offered.len], offered);
    return buf[0..offered.len];
}

/// Whether a set of offered options is ordered strictly least-destructive first.
///
/// The order is the whole safety guarantee: it is what keeps the erase-everything option from
/// ever sitting above a fix that loses less. Encoding destructiveness in the enum value lets the
/// check be a simple strict-increasing scan, so any regression in `optionsFor` is caught here.
pub fn isLeastDestructiveFirst(options: []const Option) bool {
    var i: usize = 1;
    while (i < options.len) : (i += 1) {
        if (@intFromEnum(options[i]) <= @intFromEnum(options[i - 1])) return false;
    }
    return true;
}

test "a healthy device offers no recovery" {
    var buf: [max_options]Option = undefined;
    try std.testing.expectEqual(@as(usize, 0), optionsFor(.healthy, &buf).len);
}

test "a degraded device offers only the gentle fixes" {
    var buf: [max_options]Option = undefined;
    try std.testing.expectEqualSlices(Option, &.{ .retry, .safe_mode }, optionsFor(.degraded, &buf));
}

test "a failed boot offers the full ladder with reset last" {
    var buf: [max_options]Option = undefined;
    const opts = optionsFor(.boot_failed, &buf);
    try std.testing.expectEqual(Option.factory_reset, opts[opts.len - 1]);
}

test "total storage failure leaves only the reset" {
    var buf: [max_options]Option = undefined;
    try std.testing.expectEqualSlices(Option, &.{.factory_reset}, optionsFor(.storage_failed, &buf));
}

test "every posture offers its options least-destructive first, swept" {
    // The escalation property: no posture ever offers a more-destructive option ahead of a
    // less-destructive one, so factory reset can never precede a gentler fix.
    var buf: [max_options]Option = undefined;
    for (std.enums.values(Posture)) |posture| {
        try std.testing.expect(isLeastDestructiveFirst(optionsFor(posture, &buf)));
    }
}
