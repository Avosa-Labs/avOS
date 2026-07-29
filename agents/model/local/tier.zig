//! Choosing which on-device model a device runs, by its memory budget — one adapter, two tiers.
//!
//! The default mind is local and keyless, but one fixed weight size does not fit every device: a
//! roomy machine should run a strong model that can actually plan a trip and reason over an inbox,
//! while a memory-tight phone must run a smaller one or thrash. Both sit behind the same model adapter
//! (`llama/`), so nothing above the mind seam changes; only which weights load differs. This module is
//! that choice, made from the device's RAM at provision time — a constant-time decision, not a probe —
//! and the weight file each tier names. The two families themselves are pinned by ADR 0009; this is the
//! mechanism that selects between them.

const std = @import("std");

/// The capability tier a device provisions. `pitch` is the strong model (quality that makes the agents
/// look smart); `constrained` is the smaller model for memory-tight devices. Same adapter, same seam.
pub const Tier = enum { pitch, constrained };

/// The memory floor, in whole MiB, at or above which a device runs the pitch tier. The pitch model is
/// a 7–8B 4-bit model — roughly 4–5 GB of weights, plus a KV cache and headroom for the compositor and
/// apps — so a device below this cannot hold it comfortably and runs the constrained tier instead.
pub const pitch_min_ram_mib: u32 = 8 * 1024;

/// The tier a device with `device_ram_mib` of RAM runs. Constant time: a single comparison, decided
/// once at provision, never re-probed per request.
pub fn tierFor(device_ram_mib: u32) Tier {
    return if (device_ram_mib >= pitch_min_ram_mib) .pitch else .constrained;
}

/// The GGUF weight file a tier loads — the family pinned in ADR 0009 (Qwen2.5-Instruct, Apache-2.0,
/// permissive to ship). The weights are provisioned into the image or fetched once and cached; the
/// adapter loads whichever the tier names, and `model.describe` validates the file before binding.
pub fn weightsName(tier: Tier) []const u8 {
    return switch (tier) {
        .pitch => "qwen2.5-7b-instruct-q4_k_m.gguf",
        .constrained => "qwen2.5-1.5b-instruct-q4_k_m.gguf",
    };
}

// --- Tests ---

const testing = std.testing;

test "a roomy device runs the pitch tier, a tight one the constrained tier" {
    try testing.expectEqual(Tier.pitch, tierFor(16 * 1024)); // 16 GiB
    try testing.expectEqual(Tier.pitch, tierFor(pitch_min_ram_mib)); // exactly the floor qualifies
    try testing.expectEqual(Tier.constrained, tierFor(pitch_min_ram_mib - 1)); // just under
    try testing.expectEqual(Tier.constrained, tierFor(4 * 1024)); // 4 GiB phone
}

test "each tier names a distinct weight file" {
    try testing.expect(!std.mem.eql(u8, weightsName(.pitch), weightsName(.constrained)));
    try testing.expect(weightsName(.pitch).len > 0);
    try testing.expect(std.mem.endsWith(u8, weightsName(.constrained), ".gguf"));
}
