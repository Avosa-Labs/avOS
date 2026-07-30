//! The on-device vision path: an image in, untrusted text out, and never a pixel off the
//! device — the private eye behind Camera Lens and Describe.
//!
//! A vision model is a mind that also takes an image. Its defining property is the same one
//! the local text model has: it runs on the device's own compute, so the frame in front of the
//! camera — a face, a document, a room — is read where it was captured and the pixels never
//! leave. That is the whole reason Lens and Describe default to local: a camera frame is about
//! as private as data gets, and sending it to a server to be understood is the thing this path
//! exists to avoid.
//!
//! Two honest limits shape the path, both inherited rather than reinvented. A vision model turns
//! an image into tokens — it splits the frame into fixed patches, so a bigger or more detailed
//! image costs more of the same context window a prompt does — and this module computes that cost
//! from the frame's dimensions alone, in constant time, then routes the whole request through the
//! same local window check the text path uses. A frame that does not fit is declined plainly, so
//! the caller can downscale it (with the person's knowledge) or route it off-device (with the
//! person's consent), exactly as an over-long prompt is; it is never silently downscaled to fit,
//! because a quietly shrunk image is a different, worse-answered question. And a reading is a
//! mind's output like any other: untrusted, a proposal about what is in the frame, never an
//! instruction the OS obeys.
//!
//! This module runs no model. It computes an image's token cost and whether a request fits the
//! device, as pure functions, and presents a vision runtime as an honest-until-loaded mind that
//! fabricates no reading when no backend is bound.

const std = @import("std");
const interface = @import("../interface/interface.zig");
const local = @import("local.zig");
const mind = @import("../mind.zig");

/// The side, in pixels, of one square patch a vision model splits an image into before embedding
/// it. The patch grid is what turns a picture into a sequence the model can attend over.
pub const patch_pixels: u32 = 28;

/// How many patches per side collapse into a single token. A 2×2 merge — four neighbouring patches
/// become one token — is the common arrangement that keeps a full frame within a modest window; it
/// means one token covers a `patch_pixels * patch_merge` square of the image.
pub const patch_merge: u32 = 2;

/// The number of input tokens an image of `width`×`height` pixels consumes, computed from its
/// dimensions alone — one token per merged patch cell, rounding a partial cell up so no edge of the
/// image is dropped. Constant time: a division and a multiply, never a per-pixel pass. Saturates at
/// the u32 ceiling so an absurd dimension cannot wrap into a small, apparently-cheap count.
pub fn imageTokens(width: u32, height: u32) u32 {
    const cell = patch_pixels * patch_merge; // pixels one token covers, per side
    const cols = std.math.divCeil(u32, width, cell) catch return std.math.maxInt(u32);
    const rows = std.math.divCeil(u32, height, cell) catch return std.math.maxInt(u32);
    const total = @as(u64, cols) * rows;
    return if (total > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(total);
}

/// A vision request considered for local serving: the image, any accompanying prompt (the question
/// asked of the frame — "what does this sign say?"), and the output tokens reserved for the answer.
pub const Request = struct {
    width: u32,
    height: u32,
    /// Tokens of accompanying text prompt. Zero for a bare "describe this".
    prompt_tokens: u32 = 0,
    /// Tokens reserved for the reading the model produces.
    output_tokens: u32,
};

/// Routes a vision request through the same local window check the text path uses: the image's
/// token cost plus the prompt is the input, and input plus reserved output must fit the device's
/// context window. Reuses `local.route`, so the honest-fit rule is proven once and shared — a
/// request that does not fit is reported too large, never silently downscaled. The input sum is
/// taken in wide arithmetic and saturated, so a giant frame cannot wrap into an apparent fit.
pub fn route(request: Request) local.Decision {
    const input = @as(u64, imageTokens(request.width, request.height)) + request.prompt_tokens;
    const capped: u32 = if (input > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(input);
    return local.route(.{ .input_tokens = capped, .output_tokens = request.output_tokens });
}

/// A frame handed to the vision path — the image the model reads, by its dimensions.
pub const Frame = struct { width: u32, height: u32 };

/// A vision model's reading of a frame: untrusted, like any mind's output, and bounded to the
/// tokens the call admitted. What the OS does with the text passes the same endorsement gate any
/// untrusted value would — a sign the model claims to read is a proposal, not a fact.
pub const Reading = struct {
    provenance: interface.Provenance = interface.output_provenance,
    tokens: u32,
};

/// The runtime behind a vision mind: what actually turns a frame and a request into a reading. The
/// inference runtime supplies one once the vision weights are loaded; the vision mind holds it and
/// calls through it.
pub const VisionBackend = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, frame: Frame, request: interface.Request) Reading,
};

/// A local, on-device vision mind. It reads a frame into untrusted text, but only when a runtime is
/// loaded and only for a request that fits the device — honest on both counts, fabricating nothing.
pub const VisionMind = struct {
    backend: ?VisionBackend = null,

    /// Loads the vision runtime — the mind becomes available and reads for real.
    pub fn load(self: *VisionMind, backend: VisionBackend) void {
        self.backend = backend;
    }

    /// Unloads the runtime — the mind returns to unavailable.
    pub fn unload(self: *VisionMind) void {
        self.backend = null;
    }

    pub fn isLoaded(self: VisionMind) bool {
        return self.backend != null;
    }

    /// Whether the vision mind can serve right now — available only with a runtime loaded. When
    /// unavailable, by the seam's rule the capability is inert: Lens and Describe show honestly
    /// that no vision mind is bound, rather than pretending to read.
    pub fn health(self: VisionMind) mind.Health {
        return if (self.backend != null) .available else .unavailable;
    }

    /// Reads a frame into untrusted text, or declines. It declines — returning null — when the mind
    /// is unavailable (no runtime), when the requested output exceeds the interface's ceiling, or
    /// when the frame plus its reserved output does not fit the local window. The last is the honest
    /// refusal: an oversized frame is reported, never quietly downscaled to fit. Only a fitting
    /// request on a loaded runtime produces a reading, and that reading is untrusted.
    pub fn read(self: VisionMind, frame: Frame, request: interface.Request) ?Reading {
        const backend = self.backend orelse return null;
        if (!interface.admit(request).admitted()) return null;
        const fits = route(.{ .width = frame.width, .height = frame.height, .output_tokens = request.max_tokens });
        if (!fits.local()) return null;
        return backend.read_fn(backend.context, frame, request);
    }
};

// --- Tests ---

const testing = std.testing;

test "an image's token cost is one token per merged patch cell, edges rounded up" {
    // A 1440×1440 frame at a 56-pixel cell is a 26×26 grid: 676 tokens, comfortably within the window.
    try testing.expectEqual(@as(u32, 26 * 26), imageTokens(1440, 1440));
    // A partial cell rounds up so no edge is dropped: one pixel over a cell boundary is still a
    // second cell.
    const cell = patch_pixels * patch_merge;
    try testing.expectEqual(@as(u32, 1), imageTokens(cell, cell));
    try testing.expectEqual(@as(u32, 2 * 1), imageTokens(cell + 1, cell));
}

test "a frame that fits the window is served locally; an oversized one is too large" {
    // A phone-sized frame with room for an answer fits.
    try testing.expectEqual(
        local.Decision.serve_locally,
        route(.{ .width = 1440, .height = 1440, .output_tokens = 256 }),
    );
    // A frame whose patch grid alone overruns the window is declined, not downscaled.
    try testing.expectEqual(
        local.Decision.too_large,
        route(.{ .width = 8000, .height = 8000, .output_tokens = 64 }),
    );
}

test "the reserved output counts against the window, not just the image" {
    // An image that fits on its own can still push the request over once its answer is reserved.
    const image = imageTokens(1440, 1440); // 676
    const headroom = local.context_window_tokens - image; // tokens left for prompt + output
    try testing.expectEqual(
        local.Decision.serve_locally,
        route(.{ .width = 1440, .height = 1440, .output_tokens = headroom }),
    );
    try testing.expectEqual(
        local.Decision.too_large,
        route(.{ .width = 1440, .height = 1440, .output_tokens = headroom + 1 }),
    );
}

test "a huge frame cannot wrap into an apparent fit" {
    try testing.expectEqual(
        local.Decision.too_large,
        route(.{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .output_tokens = 1 }),
    );
}

var backend_ctx: u8 = 0;
fn stubRead(_: *anyopaque, frame: Frame, request: interface.Request) Reading {
    // A deterministic stand-in for a loaded vision runtime: it reports the tokens the call admitted,
    // scaled by nothing, so the loaded path is observable without real weights.
    _ = frame;
    return .{ .tokens = request.max_tokens };
}
fn stubBackend() VisionBackend {
    return .{ .context = &backend_ctx, .read_fn = stubRead };
}

test "a vision mind with no runtime loaded is unavailable and reads nothing" {
    var vm = VisionMind{};
    try testing.expect(!vm.isLoaded());
    try testing.expectEqual(mind.Health.unavailable, vm.health());
    // Even asked directly, an unloaded vision mind fabricates no reading.
    try testing.expectEqual(@as(?Reading, null), vm.read(.{ .width = 640, .height = 480 }, .{ .max_tokens = 64 }));
}

test "loading a runtime makes the vision mind available and reading for real, untrusted" {
    var vm = VisionMind{};
    vm.load(stubBackend());
    try testing.expect(vm.isLoaded());
    try testing.expectEqual(mind.Health.available, vm.health());
    const reading = vm.read(.{ .width = 1440, .height = 1440 }, .{ .max_tokens = 128 }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 128), reading.tokens);
    // A reading is untrusted content, like any mind's output.
    try testing.expectEqual(interface.Provenance.untrusted, reading.provenance);
    // Unloading returns it to unavailable.
    vm.unload();
    try testing.expectEqual(mind.Health.unavailable, vm.health());
}

test "a loaded vision mind still declines an oversized frame or an over-ceiling request" {
    var vm = VisionMind{};
    vm.load(stubBackend());
    // An oversized frame is declined even with a runtime loaded — never silently downscaled.
    try testing.expectEqual(@as(?Reading, null), vm.read(.{ .width = 8000, .height = 8000 }, .{ .max_tokens = 64 }));
    // A request over the interface's output ceiling is refused, not clamped.
    try testing.expectEqual(@as(?Reading, null), vm.read(.{ .width = 640, .height = 480 }, .{ .max_tokens = interface.max_output_tokens + 1 }));
    // A zero-token request is not a real generation and is refused.
    try testing.expectEqual(@as(?Reading, null), vm.read(.{ .width = 640, .height = 480 }, .{ .max_tokens = 0 }));
}

test "the honest-fit and honest-availability rules hold together, swept over frame sizes" {
    // A loaded vision mind reads exactly the requests that both fit the window and are admitted, and
    // no others; an unloaded one reads nothing regardless of the frame.
    var loaded = VisionMind{};
    loaded.load(stubBackend());
    const unloaded = VisionMind{};
    var side: u32 = 64;
    while (side <= 8192) : (side += 512) {
        const frame = Frame{ .width = side, .height = side };
        const request = interface.Request{ .max_tokens = 128 };
        const should_serve = route(.{ .width = side, .height = side, .output_tokens = 128 }).local();
        try testing.expectEqual(should_serve, loaded.read(frame, request) != null);
        try testing.expectEqual(@as(?Reading, null), unloaded.read(frame, request)); // never, unloaded
    }
}
