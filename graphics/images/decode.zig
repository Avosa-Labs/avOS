//! Deciding whether an image may be decoded, so a tiny file that claims enormous
//! dimensions is refused before it expands into gigabytes of pixels.
//!
//! An encoded image is small; the pixels it decodes to are not. A few kilobytes of
//! compressed data can declare a header saying it is a hundred thousand pixels on a side,
//! which decodes to terabytes of memory — the decompression bomb, a denial-of-service
//! that costs the attacker almost nothing and the device everything. A decoder that
//! trusts the declared dimensions and allocates for them is the vulnerability; the defence
//! is to check the dimensions before allocating anything. So decoding is admitted only
//! when the declared dimensions are within sane per-axis and total-pixel bounds, and when
//! the pixels they imply fit the memory budget. A format the decoder does not support is
//! refused rather than guessed at. The image lands only if it is one the device can
//! actually hold; a bomb is refused at the header, having allocated nothing.
//!
//! This module decodes no pixels. It decides whether an image's declared dimensions and
//! format are safe to decode within a memory budget, computing the pixel size in wide
//! arithmetic, as a pure function.

const std = @import("std");

/// Supported encoded image formats. A format outside this set is refused.
pub const Format = enum { png, jpeg, webp };

/// The largest dimension, in pixels, an image may declare on either axis.
pub const max_dimension: u32 = 32768;

/// The largest total pixel count an image may declare, independent of the memory budget —
/// a second ceiling so an image within the budget by a cheap format is still bounded.
pub const max_pixels: u64 = 64 * 1024 * 1024; // 64 megapixels

/// Bytes per decoded pixel. Decoded output is 8-bit RGBA regardless of source format.
pub const bytes_per_pixel: u64 = 4;

/// An image's declared header, before any pixel data is trusted.
pub const Header = struct {
    width: u32,
    height: u32,
    format: Format,
};

/// Why decoding was refused.
pub const Refusal = enum {
    /// A dimension is zero or beyond the per-axis maximum.
    invalid_dimensions,
    /// The declared pixel count exceeds the total-pixel ceiling.
    too_many_pixels,
    /// The decoded pixels would exceed the memory budget.
    over_budget,
};

/// The decode decision.
pub const Decision = union(enum) {
    /// The image may be decoded; the decoded output will be this many bytes.
    decode: u64,
    refuse: Refusal,

    pub fn decodes(decision: Decision) bool {
        return decision == .decode;
    }
};

/// The decoded byte size implied by a header, in wide arithmetic so the product cannot
/// wrap.
pub fn decodedBytes(header: Header) u64 {
    return @as(u64, header.width) * header.height * bytes_per_pixel;
}

/// Decides whether an image may be decoded within a memory budget.
///
/// The per-axis dimensions must be non-zero and within the maximum, the declared pixel
/// count must be within the total ceiling, and the decoded bytes must fit the budget.
/// Every check happens on the header, before a byte of pixel data is allocated, so a
/// decompression bomb is refused having cost nothing. The pixel and byte products are
/// computed wide so an enormous header cannot wrap into a small allocation.
pub fn decide(header: Header, budget_bytes: u64) Decision {
    if (header.width == 0 or header.height == 0 or
        header.width > max_dimension or header.height > max_dimension)
    {
        return .{ .refuse = .invalid_dimensions };
    }
    const pixels = @as(u64, header.width) * header.height;
    if (pixels > max_pixels) return .{ .refuse = .too_many_pixels };
    const bytes = pixels * bytes_per_pixel;
    if (bytes > budget_bytes) return .{ .refuse = .over_budget };
    return .{ .decode = bytes };
}

fn makeHeader(width: u32, height: u32) Header {
    return .{ .width = width, .height = height, .format = .png };
}

const big_budget: u64 = 1 << 40;

test "a reasonable image within budget decodes" {
    const decision = decide(makeHeader(1920, 1080), big_budget);
    switch (decision) {
        .decode => |bytes| try std.testing.expectEqual(@as(u64, 1920 * 1080 * 4), bytes),
        .refuse => return error.TestUnexpectedResult,
    }
}

test "a zero dimension is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .invalid_dimensions }, decide(makeHeader(0, 100), big_budget));
}

test "a dimension past the per-axis maximum is refused" {
    try std.testing.expectEqual(
        Decision{ .refuse = .invalid_dimensions },
        decide(makeHeader(max_dimension + 1, 100), big_budget),
    );
}

test "a decompression bomb within per-axis bounds is refused on total pixels" {
    // 20000 x 20000 = 400 megapixels, over the 64-megapixel ceiling, even with a huge
    // budget.
    try std.testing.expectEqual(Decision{ .refuse = .too_many_pixels }, decide(makeHeader(20000, 20000), big_budget));
}

test "an image over the memory budget is refused" {
    // 4000 x 4000 x 4 = 64 MB against a 1 MB budget.
    try std.testing.expectEqual(Decision{ .refuse = .over_budget }, decide(makeHeader(4000, 4000), 1024 * 1024));
}

test "a maximal header does not wrap into a small allocation" {
    // Refused on pixels or budget, never admitted as a tiny allocation.
    try std.testing.expect(!decide(makeHeader(max_dimension, max_dimension), big_budget).decodes());
}

test "nothing is decoded whose pixels exceed the ceiling or budget, swept" {
    // The bomb-defence property: a decoded image is always within both the pixel ceiling
    // and the memory budget.
    const budget: u64 = 128 * 1024 * 1024;
    const dims = [_]u32{ 1, 1024, 8192, 20000, max_dimension };
    for (dims) |w| {
        for (dims) |h| {
            const decision = decide(makeHeader(w, h), budget);
            if (decision.decodes()) {
                const pixels = @as(u64, w) * h;
                try std.testing.expect(pixels <= max_pixels);
                try std.testing.expect(pixels * bytes_per_pixel <= budget);
            }
        }
    }
}
