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

/// The GGUF weight file the vision path loads for a tier — the language half of the multimodal pair,
/// pinned to the same open-weights family the text tiers use (Qwen2-VL, Apache-2.0). The pitch tier
/// runs the 7B; a memory-tight device runs the 2B. This names only the language model; the projector
/// that turns pixels into embeddings is named by `visionProjectorName` and the two load together.
pub fn visionWeightsName(tier: Tier) []const u8 {
    return switch (tier) {
        .pitch => "qwen2-vl-7b-instruct-q4_k_m.gguf",
        .constrained => "qwen2-vl-2b-instruct-q4_k_m.gguf",
    };
}

/// The multimodal projector (the "mmproj") a tier loads beside its vision weights — the small model
/// that embeds an image into the language model's token space. It is paired to the language weights,
/// so each tier names its own; a projector built for one size does not fit the other. Loaded from a
/// path at runtime alongside the language model, and like the weights it is a provisioning concern,
/// never shipped in the image.
pub fn visionProjectorName(tier: Tier) []const u8 {
    return switch (tier) {
        .pitch => "qwen2-vl-7b-instruct-mmproj-f16.gguf",
        .constrained => "qwen2-vl-2b-instruct-mmproj-f16.gguf",
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

test "each tier names a distinct vision model and a projector paired to it" {
    // The two tiers load different vision weights, and each names its own projector — the pitch
    // projector is not the constrained one.
    try testing.expect(!std.mem.eql(u8, visionWeightsName(.pitch), visionWeightsName(.constrained)));
    try testing.expect(!std.mem.eql(u8, visionProjectorName(.pitch), visionProjectorName(.constrained)));
    // A projector is a distinct file from its language weights, both GGUF.
    for ([_]Tier{ .pitch, .constrained }) |t| {
        try testing.expect(!std.mem.eql(u8, visionWeightsName(t), visionProjectorName(t)));
        try testing.expect(std.mem.endsWith(u8, visionWeightsName(t), ".gguf"));
        try testing.expect(std.mem.endsWith(u8, visionProjectorName(t), ".gguf"));
    }
}
