//! The presentation interface: where a rendered frame reaches a display, abstracted from
//! how it gets there.
//!
//! This is the second axis of the two-axis architecture. The GPU device (the other axis)
//! decides how pixels are computed; a `Surface` here is the seam between a finished frame
//! and the screen — acquire a drawable, render into it, present it. Keeping presentation
//! behind this interface is what stops a window toolkit from quietly becoming the
//! architecture: the compositor and device speak only to `Surface`, never to Wayland,
//! AppKit, DRM-KMS, or a dev-host window library directly.
//!
//! A provider is classed. Product surfaces — Wayland-client, AppKit, DRM-KMS — ship in
//! product images. A development host may present through a window toolkit (SDL2) or an
//! offscreen target, but those are `dev_host` providers: permitted only behind this
//! interface and only in a dev image, and a product build that selects one is a defect.
//! The class is what makes "SDL2 is dev-only" enforceable rather than aspirational — the
//! policy below is a pure function a build and a gate both check.
//!
//! This module presents nothing itself. It defines the surface contract, the provider
//! registry, and the shippability policy; the device-backed providers (bound to Vulkan or
//! Metal) implement the contract.

const std = @import("std");

pub const offscreen = @import("offscreen.zig");

/// Whether a provider may appear in a product image.
pub const Class = enum {
    /// A real display path that ships in product images.
    product,
    /// A development-host provider — a window toolkit or an offscreen target. Compiled out
    /// of product images; a product build that links one is a defect.
    dev_host,
};

/// The presentation providers the platform knows. The device-backed implementation for
/// each is bound where the GPU device is (Vulkan/Metal); this enumerates them and fixes
/// each one's class so the shippability policy is total.
pub const Provider = enum {
    /// Wayland client surface — the Linux product path.
    wayland,
    /// AppKit-backed surface — the Apple product path.
    appkit,
    /// Direct DRM-KMS scanout — the reference-device product path, no compositor.
    drm_kms,
    /// A dev-host window toolkit (SDL2). Development only.
    sdl2,
    /// An offscreen target — renders to memory, presents nothing. Development and tests.
    offscreen,

    pub fn class(provider: Provider) Class {
        return switch (provider) {
            .wayland, .appkit, .drm_kms => .product,
            .sdl2, .offscreen => .dev_host,
        };
    }
};

/// The shippability policy, as a pure function a build step and the prohibitions gate both
/// check: a dev-host provider may never be selected for a product image.
pub fn mayShip(provider: Provider, product_image: bool) bool {
    if (!product_image) return true; // a dev image may use any provider
    return provider.class() == .product;
}

/// The pixel extent of a surface's drawable.
pub const Extent = struct { width: u32, height: u32 };

/// How presented frames are paced. Mailbox is the low-latency default; fifo is
/// v-synced without tearing; immediate tears for the lowest latency.
pub const PresentMode = enum { mailbox, fifo, immediate };

pub const PresentError = error{
    /// The surface is no longer valid (display disconnected, window closed).
    SurfaceLost,
    /// The device backing the surface was lost and must be recreated.
    DeviceLost,
};

/// A presentation surface: the device acquires its drawable, renders, and presents. The
/// implementation is a device-backed provider; the compositor holds only this handle.
///
/// Ownership: the surface does not own the device or the frame content; it owns the
/// swapchain resources its provider allocated, released by `deinit`.
pub const Surface = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        provider: Provider,
        extent: *const fn (context: *anyopaque) Extent,
        present: *const fn (context: *anyopaque, mode: PresentMode) PresentError!void,
        deinit: *const fn (context: *anyopaque) void,
    };

    pub fn provider(surface: Surface) Provider {
        return surface.vtable.provider;
    }

    pub fn class(surface: Surface) Class {
        return surface.vtable.provider.class();
    }

    pub fn extent(surface: Surface) Extent {
        return surface.vtable.extent(surface.context);
    }

    pub fn present(surface: Surface, mode: PresentMode) PresentError!void {
        return surface.vtable.present(surface.context, mode);
    }

    pub fn deinit(surface: Surface) void {
        surface.vtable.deinit(surface.context);
    }
};

const testing = std.testing;

test "every provider has a class and the policy is total" {
    // The wall is total: for each provider and each image kind, the policy has an answer.
    for (std.enums.values(Provider)) |provider| {
        _ = provider.class();
        _ = mayShip(provider, true);
        _ = mayShip(provider, false);
    }
}

test "a dev-host provider may never ship in a product image" {
    // SDL2 and offscreen are dev-only; a product image refuses them.
    try testing.expect(!mayShip(.sdl2, true));
    try testing.expect(!mayShip(.offscreen, true));
    // But a dev image may use them.
    try testing.expect(mayShip(.sdl2, false));
    try testing.expect(mayShip(.offscreen, false));
}

test "the product providers ship in a product image" {
    try testing.expect(mayShip(.wayland, true));
    try testing.expect(mayShip(.appkit, true));
    try testing.expect(mayShip(.drm_kms, true));
}

test "exactly the window and offscreen providers are dev-host" {
    for (std.enums.values(Provider)) |provider| {
        const is_dev = provider.class() == .dev_host;
        const named_dev = provider == .sdl2 or provider == .offscreen;
        try testing.expectEqual(named_dev, is_dev);
    }
}

test {
    _ = offscreen;
}
