//! The render-path policy: which renderer draws a frame, and why.
//!
//! The rebuild inverts the old default. The GPU device is the primary path — a retained
//! compositor feeding a Vulkan device — and the software rasterizer is the fallback, not the
//! architecture. But "fallback" has to mean something precise, or it quietly becomes the
//! everyday path again. This states exactly when software draws: during early boot before a
//! device exists, in recovery where the simplest reliable path is wanted, when no usable GPU
//! is present, and when an operator forces it. Everywhere else the GPU path draws. The choice
//! is a pure function of the moment, so it is decided in one place and testable, rather than
//! scattered through the renderer as implicit conditionals.
//!
//! This decides nothing about how a frame is drawn — only which renderer draws it. The
//! compositor owns the frame either way.

const std = @import("std");

/// The renderer that draws a frame.
pub const Path = enum {
    /// The primary path: the compositor feeding the GPU device.
    gpu,
    /// The fallback path: the software rasterizer.
    software,
};

/// Why software was chosen, for logging and for the display policy to reason about. `none`
/// means the GPU path was taken.
pub const Fallback = enum { none, boot, recovery, no_gpu, forced };

/// The phase the system is in when a frame is requested.
pub const Phase = enum {
    /// Early boot, before the GPU device has been brought up.
    boot,
    /// Recovery mode: the minimal, most reliable path is wanted.
    recovery,
    /// Normal operation.
    running,
};

/// The moment a render path is chosen from.
pub const Context = struct {
    phase: Phase,
    /// Whether a usable GPU device was brought up (a Vulkan device was created).
    gpu_available: bool,
    /// An operator override forcing the software path (diagnostics, a suspected driver fault).
    force_software: bool = false,
};

/// The chosen path and the reason, so a caller can act on both.
pub const Decision = struct {
    path: Path,
    fallback: Fallback,
};

/// Chooses the render path. The GPU path is taken only in normal running, with a device
/// available, and no override; every other case is the software fallback, tagged with why.
pub fn choose(context: Context) Decision {
    if (context.force_software) return .{ .path = .software, .fallback = .forced };
    return switch (context.phase) {
        .boot => .{ .path = .software, .fallback = .boot },
        .recovery => .{ .path = .software, .fallback = .recovery },
        .running => if (context.gpu_available)
            .{ .path = .gpu, .fallback = .none }
        else
            .{ .path = .software, .fallback = .no_gpu },
    };
}

// --- Tests ---

const testing = std.testing;

test "normal running with a GPU takes the primary path" {
    const decision = choose(.{ .phase = .running, .gpu_available = true });
    try testing.expectEqual(Path.gpu, decision.path);
    try testing.expectEqual(Fallback.none, decision.fallback);
}

test "running without a GPU falls back to software, tagged no_gpu" {
    const decision = choose(.{ .phase = .running, .gpu_available = false });
    try testing.expectEqual(Path.software, decision.path);
    try testing.expectEqual(Fallback.no_gpu, decision.fallback);
}

test "boot and recovery always draw with software, whatever the GPU state" {
    for ([_]bool{ true, false }) |gpu| {
        const at_boot = choose(.{ .phase = .boot, .gpu_available = gpu });
        try testing.expectEqual(Path.software, at_boot.path);
        try testing.expectEqual(Fallback.boot, at_boot.fallback);

        const in_recovery = choose(.{ .phase = .recovery, .gpu_available = gpu });
        try testing.expectEqual(Path.software, in_recovery.path);
        try testing.expectEqual(Fallback.recovery, in_recovery.fallback);
    }
}

test "a forced-software override wins even when a GPU is available while running" {
    const decision = choose(.{ .phase = .running, .gpu_available = true, .force_software = true });
    try testing.expectEqual(Path.software, decision.path);
    try testing.expectEqual(Fallback.forced, decision.fallback);
}
