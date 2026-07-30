//! The mind seam: the swappable adapter behind an agent, bound to the agent by a fixed
//! contract so the OS is indifferent to what actually thinks for it.
//!
//! An agent has an identity — a principal, with capabilities and budgets — and a mind,
//! the thing that produces its proposals. The whole strategic bet is that these are
//! separable: the mind is an adapter behind a fixed contract, and swapping it changes
//! how an agent thinks, never who it is or what it may do. A buyer integrates their own
//! agent by writing one adapter; every app, setting, and safety guarantee already works
//! around it unchanged, because nothing above this seam knows or cares whether the mind
//! is one model, another, a local model, a rules engine, or a robot's onboard controller.
//! This module fixes two properties of that seam. Swapping a binding's mind preserves the
//! agent's identity exactly — same principal, same grants — so a mid-life swap is a change
//! of engine, not of actor. And a mind has health: when its adapter is unavailable (a model
//! offline, a device unreachable) the agent cannot act, visibly and honestly, rather than
//! acting on a mind that is not there.
//!
//! This module calls no model — the interface module already bounds and taints every call.
//! It defines the mind contract, the agent-to-mind binding, and the pure rules of swapping
//! and health, so substrate-neutrality is a property proven here, once, for every mind.

const std = @import("std");
const interface = @import("interface/interface.zig");

/// An agent's stable identity — its principal. Fixed across any mind swap.
pub const AgentId = u128;

/// Whether a mind's adapter can serve right now.
pub const Health = enum {
    /// The adapter is reachable and can produce proposals.
    available,
    /// The adapter is unavailable — model offline, device unreachable. The agent cannot
    /// act, and this is shown, never silent.
    unavailable,
};

/// A mind's output: always an untrusted proposal (the interface fixes this), bounded to
/// the tokens the call admitted. What the agent does with it passes the same endorsement
/// gate any untrusted value would.
pub const Proposal = struct {
    provenance: interface.Provenance = interface.output_provenance,
    tokens: u32,
    /// The generated text, when the mind produces it — a slice of the caller's buffer, owned by the
    /// caller, never by the mind. A mind that proves only a bounded pass (or one that fabricates
    /// nothing) leaves this empty; it carries the same untrusted taint as the proposal itself.
    text: []const u8 = "",
};

/// The mind contract every adapter conforms to: it proposes, and it reports its health.
/// The provider behind it — which model, which controller — is the adapter's business and
/// never crosses this seam.
pub const Mind = struct {
    context: *anyopaque,
    propose_fn: *const fn (context: *anyopaque, request: interface.Request) Proposal,
    health_fn: *const fn (context: *anyopaque) Health,

    pub fn propose(mind: Mind, request: interface.Request) Proposal {
        return mind.propose_fn(mind.context, request);
    }

    pub fn health(mind: Mind) Health {
        return mind.health_fn(mind.context);
    }
};

/// An agent bound to its current mind: the identity is fixed, the mind is a swappable slot.
pub const Binding = struct {
    agent: AgentId,
    mind: Mind,

    /// Whether the agent may act: only when its mind is available. When the mind is
    /// unavailable the agent's capabilities are inert — held authority that cannot be
    /// exercised until the mind returns.
    pub fn canAct(binding: Binding) bool {
        return binding.mind.health() == .available;
    }
};

/// Swaps the mind behind an agent, preserving the agent's identity exactly. The returned
/// binding is the same agent with a new engine — grants, budgets, and ledger identity are
/// unchanged, because none of them live in the mind.
pub fn swap(binding: Binding, new_mind: Mind) Binding {
    return .{ .agent = binding.agent, .mind = new_mind };
}

// --- Tests ---

const testing = std.testing;

/// A deterministic mind for tests: available, and it proposes exactly the tokens the
/// interface admitted, so a proposal is reproducible and its taint observable.
const StubMind = struct {
    var available_ctx: u8 = 0;
    var unavailable_ctx: u8 = 0;

    fn proposeAvailable(_: *anyopaque, request: interface.Request) Proposal {
        return .{ .tokens = request.max_tokens };
    }
    fn proposeUnavailable(_: *anyopaque, request: interface.Request) Proposal {
        return .{ .tokens = request.max_tokens };
    }
    fn healthAvailable(_: *anyopaque) Health {
        return .available;
    }
    fn healthUnavailable(_: *anyopaque) Health {
        return .unavailable;
    }

    fn available() Mind {
        return .{ .context = &available_ctx, .propose_fn = proposeAvailable, .health_fn = healthAvailable };
    }
    fn unavailable() Mind {
        return .{ .context = &unavailable_ctx, .propose_fn = proposeUnavailable, .health_fn = healthUnavailable };
    }
};

test "a mind's proposal is always untrusted" {
    const proposal = StubMind.available().propose(.{ .max_tokens = 256 });
    try testing.expectEqual(interface.Provenance.untrusted, proposal.provenance);
}

test "swapping a mind preserves the agent's identity exactly" {
    const original = Binding{ .agent = 0xABCD, .mind = StubMind.available() };
    const swapped = swap(original, StubMind.unavailable());
    // Same agent — the swap changed the engine, not the actor.
    try testing.expectEqual(original.agent, swapped.agent);
}

test "an agent with an available mind may act; with an unavailable one it may not" {
    const acting = Binding{ .agent = 1, .mind = StubMind.available() };
    const stalled = Binding{ .agent = 1, .mind = StubMind.unavailable() };
    try testing.expect(acting.canAct());
    try testing.expect(!stalled.canAct());
}

test "neutrality: the swap and health rules hold identically for any mind, swept" {
    // Whichever mind backs an agent, swapping preserves identity and health gates action.
    // This is the substrate-neutrality property, proven over every mind the contract admits.
    const minds = [_]Mind{ StubMind.available(), StubMind.unavailable() };
    for (minds) |before| {
        for (minds) |after| {
            const binding = Binding{ .agent = 42, .mind = before };
            const swapped = swap(binding, after);
            try testing.expectEqual(@as(AgentId, 42), swapped.agent); // identity preserved, always
            try testing.expectEqual(after.health() == .available, swapped.canAct()); // health gates, always
        }
    }
}
