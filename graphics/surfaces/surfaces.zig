//! Deciding whether a surface may be allocated, so a request for a buffer the device
//! cannot afford is refused before the memory is committed rather than after it runs out.
//!
//! A surface is a block of pixel memory, and its size is width times height times bytes
//! per pixel — a product that grows fast. A surface a few thousand pixels on a side is
//! tens of megabytes; a bug or a hostile caller asking for one a hundred thousand pixels
//! on a side asks for terabytes. Graphics memory is finite and shared, so allocation is
//! a decision, not a reflex: the requested dimensions must be within sane bounds, the
//! pixel format must be one the device supports, and the resulting byte size must fit
//! the memory budget the surface pool has left. A request that fails any of these is
//! refused at request time, because a surface allocation that succeeds and then cannot be
//! backed by real memory fails somewhere deep in rendering, far from the request that
//! caused it. The size arithmetic is done in wide integers so an enormous request cannot
//! wrap into a small one that slips through.
//!
//! This module allocates no memory. It decides whether a surface request fits the format
//! and budget, computing its byte size safely, as a pure function.

const std = @import("std");

/// A supported pixel format and its bytes per pixel.
pub const Format = enum {
    /// 8-bit RGBA, the common case.
    rgba8,
    /// 8-bit RGB, no alpha.
    rgb8,
    /// 16-bit-per-channel RGBA, for wide-gamut and HDR.
    rgba16,

    fn bytesPerPixel(format: Format) u32 {
        return switch (format) {
            .rgba8 => 4,
            .rgb8 => 3,
            .rgba16 => 8,
        };
    }
};

/// The largest dimension, in pixels, a surface may have on either axis. Generous for
/// real displays, far below where the size product becomes absurd.
pub const max_dimension: u32 = 16384;

/// A surface allocation request.
pub const Request = struct {
    width: u32,
    height: u32,
    format: Format,
};

/// Why an allocation was refused.
pub const Refusal = enum {
    /// A dimension is zero or beyond the maximum.
    invalid_dimensions,
    /// The surface's byte size exceeds the remaining budget.
    over_budget,
};

/// The allocation decision.
pub const Decision = union(enum) {
    /// The surface may be allocated at this many bytes.
    allocate: u64,
    refuse: Refusal,

    pub fn allocated(decision: Decision) bool {
        return decision == .allocate;
    }
};

/// The byte size of a surface, computed in wide arithmetic so the product cannot wrap.
pub fn byteSize(request: Request) u64 {
    const pixels = @as(u64, request.width) * request.height;
    return pixels * request.format.bytesPerPixel();
}

/// Decides whether a surface may be allocated within a byte budget.
///
/// The dimensions must be non-zero and within the maximum, or the request is nonsense
/// and refused. Otherwise the byte size — computed as a wide product so a huge request
/// cannot wrap into a small one — must fit the remaining budget. A request that passes
/// both is allocated at its computed size; anything else is refused before any memory is
/// committed.
pub fn decide(request: Request, budget_bytes: u64) Decision {
    if (request.width == 0 or request.height == 0 or
        request.width > max_dimension or request.height > max_dimension)
    {
        return .{ .refuse = .invalid_dimensions };
    }
    const size = byteSize(request);
    if (size > budget_bytes) return .{ .refuse = .over_budget };
    return .{ .allocate = size };
}

fn req(width: u32, height: u32, format: Format) Request {
    return .{ .width = width, .height = height, .format = format };
}

test "a reasonable surface within budget is allocated" {
    const decision = decide(req(1920, 1080, .rgba8), 64 * 1024 * 1024);
    switch (decision) {
        .allocate => |bytes| try std.testing.expectEqual(@as(u64, 1920 * 1080 * 4), bytes),
        .refuse => return error.TestUnexpectedResult,
    }
}

test "a zero dimension is invalid" {
    try std.testing.expectEqual(Decision{ .refuse = .invalid_dimensions }, decide(req(0, 100, .rgba8), 1 << 40));
    try std.testing.expectEqual(Decision{ .refuse = .invalid_dimensions }, decide(req(100, 0, .rgba8), 1 << 40));
}

test "a dimension beyond the maximum is invalid" {
    try std.testing.expectEqual(
        Decision{ .refuse = .invalid_dimensions },
        decide(req(max_dimension + 1, 100, .rgba8), 1 << 40),
    );
}

test "a surface over budget is refused" {
    // A large surface against a small budget.
    try std.testing.expectEqual(Decision{ .refuse = .over_budget }, decide(req(4096, 4096, .rgba16), 1024));
}

test "the byte size accounts for the format" {
    try std.testing.expectEqual(@as(u64, 100 * 100 * 4), byteSize(req(100, 100, .rgba8)));
    try std.testing.expectEqual(@as(u64, 100 * 100 * 8), byteSize(req(100, 100, .rgba16)));
    try std.testing.expectEqual(@as(u64, 100 * 100 * 3), byteSize(req(100, 100, .rgb8)));
}

test "a maximal-dimension request does not wrap into a small size" {
    // 16384 x 16384 x 8 bytes is 2 GiB; against a tiny budget it must be refused, not
    // wrapped into something that fits.
    try std.testing.expectEqual(
        Decision{ .refuse = .over_budget },
        decide(req(max_dimension, max_dimension, .rgba16), 1 << 20),
    );
}

test "no allocation ever exceeds the budget, swept" {
    // The safety property: an allocated surface's size is always within the budget and
    // its dimensions within the maximum.
    const budget: u64 = 32 * 1024 * 1024;
    const sizes = [_]u32{ 1, 512, 2048, 8192, max_dimension };
    for (sizes) |w| {
        for (sizes) |h| {
            for ([_]Format{ .rgba8, .rgb8, .rgba16 }) |format| {
                const decision = decide(req(w, h, format), budget);
                if (decision.allocated()) {
                    try std.testing.expect(byteSize(req(w, h, format)) <= budget);
                    try std.testing.expect(w <= max_dimension and h <= max_dimension);
                }
            }
        }
    }
}
