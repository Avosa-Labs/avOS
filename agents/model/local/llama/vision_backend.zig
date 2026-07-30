//! Wiring the compiled multimodal engine into the vision seam: a `vision.VisionBackend` whose read is
//! a real libmtmd + llama.cpp pass over a held frame.
//!
//! The vision seam presents a mind that is honestly unavailable until a backend is loaded, and passes
//! only a frame's shape across itself — never the pixels, which stay below the seam. This is the real
//! backend: it holds a loaded multimodal model and the current frame (its RGB pixels, dimensions, and
//! the question asked of it) alongside a caption buffer, and its `read_fn` admits the request through
//! `interface.admit` (which caps the token budget), runs a bounded pass through the engine, and
//! returns the tokens produced and the decoded caption as an untrusted reading — the same taint any
//! mind's output carries. On any engine failure it produces nothing rather than fabricating a caption,
//! matching the seam's honesty rule. No C type crosses this seam; the engine is entirely behind the
//! vision engine module.
//!
//! This is the root of a separate built-when-present module: it reaches the engine through the named
//! `vision_engine` module and the seam through the named `agents` module, so nothing crosses a
//! relative module boundary. Compiled only where the vendored multimodal source is present (the build
//! gates it on that); absent, the vision mind keeps its existing unavailable fallback.

const std = @import("std");
const vision = @import("vision_engine");
const agents = @import("agents");

const seam = agents.model_local_vision;
const interface = agents.model_interface;

/// A loaded multimodal runtime bound to the frame it reads, presentable as a `seam.VisionBackend`.
/// The seam carries only a token budget and the frame's shape, so the pixels and prompt the pass runs
/// over are held here with the model. The caption the pass writes lands in `caption`, and the reading
/// borrows it. The `MultimodalModel` (and the process `Runtime` behind it) must outlive this backend.
pub const VisionRuntimeBackend = struct {
    model: vision.MultimodalModel,
    /// The current frame as tightly packed RGB — `nx * ny * 3` bytes.
    pixels: []const u8,
    nx: u32,
    ny: u32,
    /// The question asked of the frame; empty for a bare "describe this".
    prompt: []const u8,
    /// Where the decoded caption is written; the reading's text borrows this.
    caption: []u8,

    fn readThunk(context: *anyopaque, frame: seam.Frame, request: interface.Request) seam.Reading {
        const self: *VisionRuntimeBackend = @ptrCast(@alignCast(context));
        // The seam has already checked the frame fits the window; the shape it passes is not needed
        // again here because the pixels it belongs to are held with this backend.
        _ = frame;
        // The interface caps the budget and refuses a zero or over-ceiling request; a refusal reads
        // nothing, never touching the engine.
        const budget = switch (interface.admit(request)) {
            .admit => |limit| limit,
            .refuse => return .{ .tokens = 0 },
        };
        // A real bounded pass. Any engine failure yields nothing rather than a fabricated caption.
        const gen = self.model.describe(self.pixels, self.nx, self.ny, self.prompt, budget, self.caption) catch
            return .{ .tokens = 0 };
        return .{ .tokens = gen.tokens, .text = gen.text, .provenance = .untrusted };
    }

    /// Presents this loaded runtime as a backend the vision mind can load.
    pub fn backend(self: *VisionRuntimeBackend) seam.VisionBackend {
        return .{ .context = self, .read_fn = readThunk };
    }
};

// --- Tests ---

const testing = std.testing;

fn refusedBackend() VisionRuntimeBackend {
    // The model is never consulted on a refused request, so it can be left undefined for the refuse
    // paths — the interface turns the call away before the engine is touched.
    return .{ .model = undefined, .pixels = &.{}, .nx = 0, .ny = 0, .prompt = "describe this", .caption = &.{} };
}

test "a refused request reads nothing, never touching the engine" {
    // A zero-token request is refused by the interface before the model is ever consulted.
    var vb = refusedBackend();
    const b = vb.backend();
    const reading = b.read_fn(b.context, .{ .width = 640, .height = 480 }, .{ .max_tokens = 0 });
    try testing.expectEqual(@as(u32, 0), reading.tokens);
    try testing.expectEqualStrings("", reading.text);
}

test "an over-ceiling request is refused, reading nothing" {
    var vb = refusedBackend();
    const b = vb.backend();
    const reading = b.read_fn(b.context, .{ .width = 640, .height = 480 }, .{ .max_tokens = interface.max_output_tokens + 1 });
    try testing.expectEqual(@as(u32, 0), reading.tokens);
}

test "the backend presents as a real VisionBackend the vision mind can load" {
    var vb = refusedBackend();
    var vm = seam.VisionMind{};
    vm.load(vb.backend());
    try testing.expect(vm.isLoaded());
    // Loaded, the mind is available.
    try testing.expectEqual(agents.model_mind.Health.available, vm.health());
    // The seam declines a zero-token read before the backend is reached, so the engine is never
    // touched even through the loaded mind.
    try testing.expectEqual(@as(?seam.Reading, null), vm.read(.{ .width = 640, .height = 480 }, .{ .max_tokens = 0 }));
}
