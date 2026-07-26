//! The frame scheduler: the zero-idle-GPU property, made concrete and asserted.
//!
//! A retained scene tree earns its keep only if an idle interface costs nothing. The
//! damage set already says what changed; this ties that to presentation: a frame is
//! submitted to the surface only when the damage is non-empty. When nothing changed the
//! scheduler presents nothing — no acquire, no submit, no power — and it drives a real
//! `presentation.Surface`, so the property can be *asserted* (the surface's present count
//! stays zero across idle frames) rather than merely believed. That is the discipline the
//! rebuild demands: zero-idle GPU is checked, not hoped for.
//!
//! It composites nothing itself; the device renders the damaged region into the surface's
//! drawable. This decides only whether a frame happens at all.

const std = @import("std");
const damage = @import("../scene/damage.zig");
const presentation = @import("../presentation/presentation.zig");

pub const FrameScheduler = struct {
    surface: presentation.Surface,
    mode: presentation.PresentMode = .mailbox,
    /// Frames actually submitted to the surface.
    submitted: u64 = 0,
    /// Frames skipped because nothing changed — the idle case.
    skipped_idle: u64 = 0,

    pub fn init(surface: presentation.Surface) FrameScheduler {
        return .{ .surface = surface };
    }

    /// Runs one frame given its accumulated damage. Presents only if something changed;
    /// an idle frame submits nothing to the GPU.
    pub fn frame(scheduler: *FrameScheduler, set: damage.DamageSet) presentation.PresentError!void {
        if (set.isClean()) {
            scheduler.skipped_idle += 1;
            return;
        }
        try scheduler.surface.present(scheduler.mode);
        scheduler.submitted += 1;
    }
};

const testing = std.testing;
const Offscreen = presentation.offscreen.Offscreen;

test "an idle interface submits zero frames to the GPU" {
    // The property, asserted: over any number of clean frames, nothing is presented.
    var off: Offscreen = .init(440, 956);
    var scheduler: FrameScheduler = .init(off.surface());

    var buffer: [8]damage.Rect = undefined;
    const clean: damage.DamageSet = .init(&buffer); // nothing added → clean

    var i: usize = 0;
    while (i < 1000) : (i += 1) try scheduler.frame(clean);

    try testing.expectEqual(@as(u64, 0), scheduler.submitted);
    try testing.expectEqual(@as(u64, 0), off.presented); // no GPU submission at the surface
    try testing.expectEqual(@as(u64, 1000), scheduler.skipped_idle);
}

test "a frame with damage is submitted exactly once" {
    var off: Offscreen = .init(440, 956);
    var scheduler: FrameScheduler = .init(off.surface());

    var buffer: [8]damage.Rect = undefined;
    var dirty: damage.DamageSet = .init(&buffer);
    dirty.add(.{ .x = 0, .y = 0, .w = 100, .h = 100 });

    try scheduler.frame(dirty);
    try testing.expectEqual(@as(u64, 1), scheduler.submitted);
    try testing.expectEqual(@as(u64, 1), off.presented);
}

test "only the damaged frames in a sequence are presented" {
    var off: Offscreen = .init(100, 100);
    var scheduler: FrameScheduler = .init(off.surface());
    var clean_buffer: [8]damage.Rect = undefined;
    var dirty_buffer: [8]damage.Rect = undefined;

    const clean: damage.DamageSet = .init(&clean_buffer);
    var dirty: damage.DamageSet = .init(&dirty_buffer);
    dirty.add(.{ .x = 1, .y = 1, .w = 2, .h = 2 });

    // idle, idle, dirty, idle, dirty → two presents.
    try scheduler.frame(clean);
    try scheduler.frame(clean);
    try scheduler.frame(dirty);
    try scheduler.frame(clean);
    try scheduler.frame(dirty);

    try testing.expectEqual(@as(u64, 2), scheduler.submitted);
    try testing.expectEqual(@as(u64, 3), scheduler.skipped_idle);
}
