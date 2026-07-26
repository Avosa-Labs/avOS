//! An offscreen presentation surface: renders to memory, presents to nothing.
//!
//! This is the dev-host and test provider, and the one concrete surface that needs no GPU
//! and no display — a real implementation of the presentation contract over a fixed
//! extent, whose `present` completes without a screen. It exists so the compositor and the
//! device path can be exercised end to end in CI, where there is neither a window nor a
//! GPU. Because it is classed `dev_host`, the shippability policy keeps it out of product
//! images exactly as it keeps SDL2 out.

const std = @import("std");
const presentation = @import("presentation.zig");

pub const Offscreen = struct {
    width: u32,
    height: u32,
    /// Frames presented, so a test can confirm the surface was driven.
    presented: u64 = 0,

    pub fn init(width: u32, height: u32) Offscreen {
        return .{ .width = width, .height = height };
    }

    pub fn surface(self: *Offscreen) presentation.Surface {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: presentation.Surface.VTable = .{
        .provider = .offscreen,
        .extent = extentImpl,
        .present = presentImpl,
        .deinit = deinitImpl,
    };

    fn extentImpl(context: *anyopaque) presentation.Extent {
        const self: *Offscreen = @ptrCast(@alignCast(context));
        return .{ .width = self.width, .height = self.height };
    }

    fn presentImpl(context: *anyopaque, mode: presentation.PresentMode) presentation.PresentError!void {
        _ = mode;
        const self: *Offscreen = @ptrCast(@alignCast(context));
        self.presented += 1;
    }

    fn deinitImpl(context: *anyopaque) void {
        _ = context;
    }
};

const testing = std.testing;

test "an offscreen surface reports its extent and presents without a display" {
    var off: Offscreen = .init(440, 956);
    const s = off.surface();
    try testing.expectEqual(presentation.Extent{ .width = 440, .height = 956 }, s.extent());
    try testing.expectEqual(presentation.Provider.offscreen, s.provider());
    try testing.expectEqual(presentation.Class.dev_host, s.class());

    try s.present(.mailbox);
    try s.present(.fifo);
    try testing.expectEqual(@as(u64, 2), off.presented);
    s.deinit();
}

test "the offscreen surface is never shippable in a product image" {
    var off: Offscreen = .init(10, 10);
    try testing.expect(!presentation.mayShip(off.surface().provider(), true));
}
