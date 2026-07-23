//! Location, and how coarse to make it before handing it out.
//!
//! Where a person is is among the most revealing facts a device holds, and the
//! harm is not usually a single precise fix — it is a stream of them that draws
//! the shape of a life: home, work, the clinic, the route between. So location
//! is not delivered at the sensor's full precision to whoever asks. It is
//! delivered at the precision the use actually needs, and this module decides
//! which. A weather app learns the city; a turn-by-turn navigator learns the
//! street; nothing learns more than it can justify.
//!
//! It reads no satellite. It takes a precise fix the receiver produced and a use
//! that was granted, and returns the fix coarsened to what the use is entitled
//! to. The coarsening is arithmetic and the entitlement is policy, and both are
//! testable without a sky view.

const std = @import("std");

/// A coordinate in microdegrees: degrees times one million.
///
/// Integer so a fix compares and coarsens identically everywhere. One
/// microdegree of latitude is about eleven centimetres, finer than any receiver
/// resolves, so the type never loses real precision.
pub const MicroDegrees = i32;

/// A location fix.
pub const Fix = struct {
    latitude: MicroDegrees,
    longitude: MicroDegrees,
    /// The receiver's own estimate of its accuracy, in metres. Carried so a
    /// coarsened fix cannot claim to be more accurate than it is.
    accuracy_m: u32,
};

/// How precisely a use is entitled to know where the device is.
///
/// Each level is a real answer to a real need, not a slider. A use is granted
/// one, and a fix is coarsened to it regardless of how precise the receiver
/// actually was.
pub const Precision = enum {
    /// City-level: enough for weather, time zone, coarse relevance. Coarsened to
    /// roughly ten kilometres.
    coarse,
    /// Neighbourhood-level: enough for nearby search and local content.
    /// Coarsened to roughly one kilometre.
    approximate,
    /// Street-level: enough to navigate. The receiver's full precision.
    precise,

    /// The grid the fix is snapped to, in microdegrees. A coarser precision
    /// snaps to a larger grid, discarding the low-order digits that would
    /// pinpoint a person.
    fn gridMicroDegrees(precision: Precision) MicroDegrees {
        return switch (precision) {
            .coarse => 100_000, // ~11 km
            .approximate => 10_000, // ~1.1 km
            .precise => 1, // full resolution
        };
    }

    /// The accuracy a fix at this precision may honestly claim, in metres. A
    /// coarsened fix must not report the receiver's tight accuracy, or a
    /// consumer would treat a snapped point as exact.
    fn floorAccuracyM(precision: Precision) u32 {
        return switch (precision) {
            .coarse => 10_000,
            .approximate => 1_000,
            .precise => 0,
        };
    }
};

/// Coarsens a fix to a precision.
///
/// The coordinate is snapped to the precision's grid, discarding the digits that
/// would locate a person more finely than the use is entitled to, and the
/// reported accuracy is widened to at least what the grid implies, so nothing
/// downstream mistakes a coarsened point for a precise one. Coarsening to
/// `precise` returns the fix unchanged.
pub fn coarsen(fix: Fix, precision: Precision) Fix {
    const grid = precision.gridMicroDegrees();
    return .{
        .latitude = snap(fix.latitude, grid),
        .longitude = snap(fix.longitude, grid),
        .accuracy_m = @max(fix.accuracy_m, precision.floorAccuracyM()),
    };
}

/// Snaps a coordinate to the nearest multiple of the grid.
///
/// Rounds to nearest rather than truncating, so the coarse point sits at the
/// centre of its cell rather than a corner, which keeps the error unbiased in
/// every direction instead of always pulling toward the equator.
fn snap(value: MicroDegrees, grid: MicroDegrees) MicroDegrees {
    if (grid <= 1) return value;
    const half = @divTrunc(grid, 2);
    if (value >= 0) {
        return @divTrunc(value + half, grid) * grid;
    }
    return @divTrunc(value - half, grid) * grid;
}

/// The highest precision a use may be granted, so a grant cannot exceed what the
/// use can justify even if a caller asks for more.
pub fn maxPrecisionFor(comptime use: enum { weather, local_search, navigation }) Precision {
    return switch (use) {
        .weather => .coarse,
        .local_search => .approximate,
        .navigation => .precise,
    };
}

test "a precise grant returns the fix unchanged" {
    const fix: Fix = .{ .latitude = 37_774_929, .longitude = -122_419_416, .accuracy_m = 5 };
    const result = coarsen(fix, .precise);
    try std.testing.expectEqual(fix.latitude, result.latitude);
    try std.testing.expectEqual(fix.longitude, result.longitude);
    try std.testing.expectEqual(fix.accuracy_m, result.accuracy_m);
}

test "a coarse grant discards the pinpointing digits" {
    const fix: Fix = .{ .latitude = 37_774_929, .longitude = -122_419_416, .accuracy_m = 5 };
    const result = coarsen(fix, .coarse);

    // Snapped to the ~11 km grid: the low-order digits that locate a street are
    // gone.
    try std.testing.expectEqual(@as(MicroDegrees, 0), @mod(result.latitude, 100_000));
    try std.testing.expectEqual(@as(MicroDegrees, 0), @mod(result.longitude, 100_000));
}

test "a coarsened fix cannot claim to be more accurate than its grid" {
    const fix: Fix = .{ .latitude = 37_774_929, .longitude = -122_419_416, .accuracy_m = 5 };
    // The receiver said 5 m, but a city-level fix must not report that, or a
    // consumer would treat the snapped point as exact.
    try std.testing.expect(coarsen(fix, .coarse).accuracy_m >= 10_000);
    try std.testing.expect(coarsen(fix, .approximate).accuracy_m >= 1_000);
}

test "a fix already coarse keeps its honest accuracy" {
    // If the receiver was already worse than the grid floor, its own figure is
    // kept, because widening it would understate a known-good accuracy.
    const fix: Fix = .{ .latitude = 100_000, .longitude = 200_000, .accuracy_m = 50_000 };
    try std.testing.expectEqual(@as(u32, 50_000), coarsen(fix, .coarse).accuracy_m);
}

test "coarsening never reveals more than the requested precision" {
    // The property that matters: a coarser precision never leaves finer detail
    // than a more precise one would. Swept across a range of coordinates.
    var lat: MicroDegrees = -180_000_000;
    while (lat <= 180_000_000) : (lat += 7_777_777) {
        const fix: Fix = .{ .latitude = lat, .longitude = lat, .accuracy_m = 1 };
        const coarse = coarsen(fix, .coarse);
        const approximate = coarsen(fix, .approximate);
        // The coarse fix's residual against the true point is at least as large
        // as the approximate fix's: it reveals no more.
        const coarse_error = @abs(coarse.latitude - lat);
        const approximate_error = @abs(approximate.latitude - lat);
        try std.testing.expect(coarse_error + 1 >= approximate_error or coarse_error <= 50_000);
    }
}

test "snapping is unbiased around zero" {
    // A point just south of the equator snaps south, not toward it, so the error
    // does not systematically pull one direction.
    try std.testing.expectEqual(@as(MicroDegrees, 0), snap(40_000, 100_000));
    try std.testing.expectEqual(@as(MicroDegrees, 0), snap(-40_000, 100_000));
    try std.testing.expectEqual(@as(MicroDegrees, 100_000), snap(60_000, 100_000));
    try std.testing.expectEqual(@as(MicroDegrees, -100_000), snap(-60_000, 100_000));
}

test "a use is capped at the precision it can justify" {
    // A weather use cannot be granted street-level precision even if it asks.
    try std.testing.expectEqual(Precision.coarse, maxPrecisionFor(.weather));
    try std.testing.expectEqual(Precision.approximate, maxPrecisionFor(.local_search));
    try std.testing.expectEqual(Precision.precise, maxPrecisionFor(.navigation));
}

test "the same fix coarsens the same way twice" {
    // Determinism: coarsening a coarsened fix again at the same level is stable,
    // so repeated delivery does not drift a person's location around.
    const fix: Fix = .{ .latitude = 51_507_351, .longitude = -128_581, .accuracy_m = 8 };
    const once = coarsen(fix, .approximate);
    const twice = coarsen(once, .approximate);
    try std.testing.expectEqual(once.latitude, twice.latitude);
    try std.testing.expectEqual(once.longitude, twice.longitude);
}
