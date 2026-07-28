//! The local mind adapter: an on-device model presented as a mind behind the swap seam, honestly
//! unavailable until its runtime is loaded, then a first-class mind like any other.
//!
//! The default mind is meant to be local — an open-weights model running on the device, keyless and
//! offline. That model reaches the rest of the system the same way every mind does: through the mind
//! contract, so nothing above the seam knows or cares that the default is local. This module is that
//! presentation. A local mind holds a runtime backend — the thing that actually turns a request into a
//! proposal, which the inference runtime provides once it is bound and its weights are loaded. Until a
//! backend is loaded the mind reports itself unavailable, and by the seam's own rule its capabilities
//! are inert: it cannot act, visibly, rather than pretending to think. Load the backend and it is
//! available and proposes for real; unload it and it returns to unavailable. Because it is a plain mind
//! it swaps in and out like any other, so a person can make the local model the default, replace it,
//! or set it beside a remote one, all through the same contract.
//!
//! This module runs no model itself — the bound runtime does — and it never fabricates a proposal when
//! no backend is present. It presents a local runtime as a mind, and fixes the honest-until-loaded
//! behaviour.

const std = @import("std");
const mind = @import("../mind.zig");
const interface = @import("../interface/interface.zig");

/// The runtime behind a local mind: what actually generates a proposal from a request. The inference
/// runtime supplies one once its weights are loaded; the local mind holds it and calls through it.
pub const Backend = struct {
    context: *anyopaque,
    generate_fn: *const fn (context: *anyopaque, request: interface.Request) mind.Proposal,
};

/// A local, on-device mind. It is a mind behind the seam whose backend is the loaded runtime; with no
/// backend it is honestly unavailable.
pub const LocalMind = struct {
    backend: ?Backend = null,

    fn proposeThunk(context: *anyopaque, request: interface.Request) mind.Proposal {
        const self: *LocalMind = @ptrCast(@alignCast(context));
        if (self.backend) |backend| return backend.generate_fn(backend.context, request);
        // No backend loaded: nothing is generated. The health gate keeps this from being reached in a
        // real flow, but even if it is, no proposal is fabricated.
        return .{ .tokens = 0 };
    }

    fn healthThunk(context: *anyopaque) mind.Health {
        const self: *LocalMind = @ptrCast(@alignCast(context));
        return if (self.backend != null) .available else .unavailable;
    }

    /// Presents this local mind as a mind behind the swap seam.
    pub fn asMind(self: *LocalMind) mind.Mind {
        return .{ .context = self, .propose_fn = proposeThunk, .health_fn = healthThunk };
    }

    /// Loads the runtime backend — the mind becomes available and proposes through it.
    pub fn load(self: *LocalMind, backend: Backend) void {
        self.backend = backend;
    }

    /// Unloads the runtime — the mind returns to unavailable.
    pub fn unload(self: *LocalMind) void {
        self.backend = null;
    }

    pub fn isLoaded(self: LocalMind) bool {
        return self.backend != null;
    }
};

// --- Tests ---

const testing = std.testing;

// A trivial deterministic backend standing for a loaded runtime: it proposes exactly the tokens the
// call admitted, so the loaded path is observable without a real model.
var backend_ctx: u8 = 0;
fn stubGenerate(_: *anyopaque, request: interface.Request) mind.Proposal {
    return .{ .tokens = request.max_tokens };
}
fn stubBackend() Backend {
    return .{ .context = &backend_ctx, .generate_fn = stubGenerate };
}

test "a local mind with no runtime loaded is unavailable and cannot act" {
    var local = LocalMind{};
    try testing.expect(!local.isLoaded());
    const binding = mind.Binding{ .agent = 1, .mind = local.asMind() };
    try testing.expectEqual(mind.Health.unavailable, binding.mind.health());
    try testing.expect(!binding.canAct()); // inert until the runtime loads
}

test "loading a runtime makes the local mind available and proposing for real" {
    var local = LocalMind{};
    local.load(stubBackend());
    try testing.expect(local.isLoaded());
    const m = local.asMind();
    try testing.expectEqual(mind.Health.available, m.health());
    const proposal = m.propose(.{ .max_tokens = 128 });
    try testing.expectEqual(@as(u32, 128), proposal.tokens);
    // The proposal is untrusted like any mind's output.
    try testing.expectEqual(interface.Provenance.untrusted, proposal.provenance);
    // Unloading returns it to unavailable.
    local.unload();
    try testing.expectEqual(mind.Health.unavailable, m.health());
}

test "the local mind swaps in and out like any mind, preserving the agent's identity" {
    var local = LocalMind{};
    local.load(stubBackend());
    const before = mind.Binding{ .agent = 0xABCD, .mind = local.asMind() };
    // Swapping to a fresh unloaded local mind changes the engine, not the agent.
    var other = LocalMind{};
    const after = mind.swap(before, other.asMind());
    try testing.expectEqual(before.agent, after.agent);
    try testing.expect(before.canAct()); // the loaded one could act
    try testing.expect(!after.canAct()); // the unloaded one cannot
}
