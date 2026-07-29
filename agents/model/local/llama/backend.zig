//! Wiring the compiled on-device engine into the mind seam: an `adapter.Backend` whose forward pass
//! is a real llama.cpp generation, bounded by the interface's admission.
//!
//! The local adapter presents a local mind that is honestly unavailable until a backend is loaded.
//! This is the real backend: it holds a loaded `Model` and a seed prompt, and its `generate_fn`
//! admits the request through `interface.admit` (which caps the token budget), runs a bounded pass
//! through the engine, and returns the tokens produced as an untrusted proposal — the same taint
//! any mind's output carries. On any engine failure it produces nothing rather than fabricating,
//! matching the seam's honesty rule. No C type crosses this seam; the engine is entirely behind the
//! engine module.
//!
//! This is the root of a separate built-when-present module: it reaches the engine through the
//! named `llama_engine` module and the mind seam through the named `agents` module, so nothing
//! crosses a relative module boundary. Compiled only where the vendored source is present (the
//! build gates it on that); absent, the local mind keeps its existing unavailable fallback.

const std = @import("std");
const llama = @import("llama_engine");
const agents = @import("agents");

const adapter = agents.model_local_adapter;
const interface = agents.model_interface;
const mind = agents.model_mind;

/// A loaded local runtime bound to a seed prompt, presentable as an `adapter.Backend`. The mind
/// contract carries only a token budget, so the prompt the pass runs over is held here with the
/// model. The `Model` (and the process `Runtime` behind it) must outlive this backend.
pub const LocalBackend = struct {
    model: llama.Model,
    prompt: []const u8,

    pub fn init(model: llama.Model, prompt: []const u8) LocalBackend {
        return .{ .model = model, .prompt = prompt };
    }

    fn generateThunk(context: *anyopaque, request: interface.Request) mind.Proposal {
        const self: *LocalBackend = @ptrCast(@alignCast(context));
        // The interface caps the budget and refuses a zero or over-ceiling request; a refusal
        // generates nothing.
        const budget = switch (interface.admit(request)) {
            .admit => |limit| limit,
            .refuse => return .{ .tokens = 0 },
        };
        // A real bounded pass. Any engine failure yields nothing rather than a fabricated proposal.
        const produced = self.model.generate(self.prompt, budget) catch return .{ .tokens = 0 };
        return .{ .tokens = produced, .provenance = .untrusted };
    }

    /// Presents this loaded runtime as a backend the local mind can load.
    pub fn backend(self: *LocalBackend) adapter.Backend {
        return .{ .context = self, .generate_fn = generateThunk };
    }
};

// --- Tests ---

const testing = std.testing;

test "a refused request generates nothing, never touching the engine" {
    // A zero-token request is refused by the interface before the model is ever consulted, so the
    // backend can be exercised on the refuse path without a loaded model.
    var lb = LocalBackend{ .model = undefined, .prompt = "hello" };
    const b = lb.backend();
    const proposal = b.generate_fn(b.context, .{ .max_tokens = 0 });
    try testing.expectEqual(@as(u32, 0), proposal.tokens);
}

test "an over-ceiling request is refused, generating nothing" {
    var lb = LocalBackend{ .model = undefined, .prompt = "hello" };
    const b = lb.backend();
    const proposal = b.generate_fn(b.context, .{ .max_tokens = interface.max_output_tokens + 1 });
    try testing.expectEqual(@as(u32, 0), proposal.tokens);
}

test "the backend presents as a real adapter.Backend the local mind can load" {
    var lb = LocalBackend{ .model = undefined, .prompt = "hello" };
    var local = adapter.LocalMind{};
    local.load(lb.backend());
    try testing.expect(local.isLoaded());
    // A refused call through the loaded mind still generates nothing, without touching the engine.
    const m = local.asMind();
    try testing.expectEqual(mind.Health.available, m.health());
    try testing.expectEqual(@as(u32, 0), m.propose(.{ .max_tokens = 0 }).tokens);
}
