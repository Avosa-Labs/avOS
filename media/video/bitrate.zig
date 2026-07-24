//! Choosing the video quality that fits the available bandwidth, so streaming plays the best
//! picture it can sustain without stalling to rebuffer.
//!
//! Adaptive streaming offers a video at several quality levels, each needing a certain bitrate,
//! and the player picks one to match the network. The choice is a trade-off the person feels
//! directly: pick a level whose bitrate exceeds what the connection can sustain and the video
//! stalls to rebuffer every few seconds, which is worse than a slightly softer picture; pick too
//! low and the picture is needlessly blocky on a connection that could do better. So the player
//! chooses the highest level whose bitrate fits within the sustainable bandwidth, leaving a
//! little headroom so a normal dip does not immediately stall. When even the lowest level exceeds
//! the bandwidth, it still selects the lowest — a struggling low-quality stream is better than
//! no video — rather than refusing to play. Selecting the best sustainable quality, with headroom,
//! is what keeps streaming smooth on a good connection and watchable on a poor one.
//!
//! This module streams nothing. It selects the video quality level that fits the available
//! bandwidth, as a pure function over the offered levels.

const std = @import("std");

/// A quality level offered for a video: a label and the bitrate it needs, in kilobits per
/// second.
pub const Level = struct {
    name: []const u8,
    bitrate_kbps: u32,
};

/// The fraction of measured bandwidth a chosen level may use, as a numerator over a denominator,
/// leaving headroom so a normal dip does not immediately stall. 8/10 keeps 20% in reserve.
pub const headroom_numerator: u64 = 8;
pub const headroom_denominator: u64 = 10;

/// Selects the video quality level for the available bandwidth.
///
/// The highest level whose bitrate fits within the sustainable bandwidth — the measured
/// bandwidth minus the reserved headroom — is chosen, for the best picture that will not stall.
/// If no level fits, the lowest-bitrate level is chosen anyway, because a struggling low-quality
/// stream is better than refusing to play. The levels need not be pre-sorted; the selection
/// scans for the best fit and the outright lowest.
pub fn select(levels: []const Level, bandwidth_kbps: u32) ?usize {
    if (levels.len == 0) return null;
    const sustainable = @as(u64, bandwidth_kbps) * headroom_numerator / headroom_denominator;

    var best_fit: ?usize = null;
    var lowest: usize = 0;
    for (levels, 0..) |level, index| {
        if (level.bitrate_kbps < levels[lowest].bitrate_kbps) lowest = index;
        if (level.bitrate_kbps <= sustainable) {
            if (best_fit == null or level.bitrate_kbps > levels[best_fit.?].bitrate_kbps) {
                best_fit = index;
            }
        }
    }
    return best_fit orelse lowest;
}

const sample_levels = [_]Level{
    .{ .name = "240p", .bitrate_kbps = 400 },
    .{ .name = "480p", .bitrate_kbps = 1000 },
    .{ .name = "720p", .bitrate_kbps = 2500 },
    .{ .name = "1080p", .bitrate_kbps = 5000 },
};

test "a fast connection gets the highest fitting level" {
    // 8000 kbps * 0.8 = 6400 sustainable; 1080p (5000) fits.
    const index = select(&sample_levels, 8000).?;
    try std.testing.expectEqualStrings("1080p", sample_levels[index].name);
}

test "a moderate connection gets a middle level" {
    // 2000 * 0.8 = 1600 sustainable; 480p (1000) fits, 720p (2500) does not.
    const index = select(&sample_levels, 2000).?;
    try std.testing.expectEqualStrings("480p", sample_levels[index].name);
}

test "a slow connection still gets the lowest level rather than nothing" {
    // 100 * 0.8 = 80 sustainable; nothing fits, so the lowest (240p) is chosen anyway.
    const index = select(&sample_levels, 100).?;
    try std.testing.expectEqualStrings("240p", sample_levels[index].name);
}

test "no levels means no selection" {
    try std.testing.expectEqual(@as(?usize, null), select(&.{}, 5000));
}

test "the chosen level fits the sustainable bandwidth when any does, swept" {
    // The no-stall property: whenever some level fits, the chosen one fits.
    var bw: u32 = 500;
    while (bw <= 10000) : (bw += 500) {
        const sustainable = @as(u64, bw) * headroom_numerator / headroom_denominator;
        var any_fits = false;
        for (sample_levels) |level| {
            if (level.bitrate_kbps <= sustainable) any_fits = true;
        }
        const index = select(&sample_levels, bw).?;
        if (any_fits) try std.testing.expect(sample_levels[index].bitrate_kbps <= sustainable);
    }
}

test "the chosen level is always the highest that fits, swept" {
    var bw: u32 = 500;
    while (bw <= 10000) : (bw += 500) {
        const sustainable = @as(u64, bw) * headroom_numerator / headroom_denominator;
        const chosen = sample_levels[select(&sample_levels, bw).?].bitrate_kbps;
        // No fitting level is higher than the chosen one.
        for (sample_levels) |level| {
            if (level.bitrate_kbps <= sustainable) {
                try std.testing.expect(level.bitrate_kbps <= chosen);
            }
        }
    }
}
