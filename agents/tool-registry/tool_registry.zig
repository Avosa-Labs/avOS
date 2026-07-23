//! The tools an agent may call, and the capability each call must present.
//!
//! An agent acts on the world by calling tools — send a message, read a file,
//! make a payment. A tool is where an agent's reasoning becomes an effect, so a
//! tool registry is not a convenience list; it is a boundary. Every tool
//! declares the one capability a caller must hold to invoke it and whether
//! invoking it is consequential enough to need a person, and an agent that does
//! not hold the capability cannot call the tool however much its plan wants to.
//! The registry is closed: an agent may call only tools registered for it, so a
//! model cannot invent a tool name and have it dispatched.
//!
//! This module holds the registry and the admission check. It invokes no tool;
//! it answers whether a named call, presenting a given capability, may proceed —
//! and reports why not — so the same gate governs every tool call rather than
//! each tool rechecking authority its own way.

const std = @import("std");

/// What a tool does to the world, which sets whether it needs approval.
pub const Effect = enum {
    /// Reads state without changing anything.
    read_only,
    /// Changes state on the device but reaches nowhere outside it.
    local_mutation,
    /// Reaches outside the device: sends, posts, publishes.
    external,
    /// Moves value or grants authority.
    value_transfer,

    /// Whether a call with this effect needs a person to approve it, beyond
    /// holding the capability. Reading and local changes are the agent's to
    /// make within its grant; anything leaving the device or moving value is
    /// not.
    pub fn needsApproval(effect: Effect) bool {
        return effect == .external or effect == .value_transfer;
    }
};

/// A tool registered for an agent.
pub const Tool = struct {
    name: []const u8,
    /// The capability a caller must present to invoke this tool. A tool with a
    /// distinct capability per tool is what makes a grant specific: holding the
    /// capability to read files does not grant the capability to send messages.
    required_capability: []const u8,
    effect: Effect,
};

/// Why a call was refused.
pub const Refusal = enum {
    /// No tool by that name is registered. A model cannot invent a tool and have
    /// it dispatched.
    unknown_tool,
    /// The presented capability does not match the tool's required one.
    capability_mismatch,
};

/// The outcome of a call attempt.
pub const Decision = union(enum) {
    /// The call may proceed with no further gate.
    invoke,
    /// The call is permitted but must be held for a person first.
    require_approval,
    /// The call is refused.
    deny: Refusal,

    pub fn permitsInvocation(decision: Decision) bool {
        return decision == .invoke or decision == .require_approval;
    }
};

/// The tools available to one agent.
pub const Registry = struct {
    tools: []const Tool,

    fn find(registry: Registry, name: []const u8) ?Tool {
        for (registry.tools) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    /// Decides whether a call may proceed.
    ///
    /// The tool must be registered — an unknown name is refused rather than
    /// guessed at, so a hallucinated tool goes nowhere — and the presented
    /// capability must match the one the tool requires, so holding authority for
    /// one tool never dispatches another. A permitted call whose effect is
    /// consequential is returned as require_approval rather than invoke, so the
    /// registry never lets an external or value effect run without a person even
    /// when the capability is held.
    pub fn admit(
        registry: Registry,
        tool_name: []const u8,
        presented_capability: []const u8,
    ) Decision {
        const tool = registry.find(tool_name) orelse return .{ .deny = .unknown_tool };
        if (!std.mem.eql(u8, tool.required_capability, presented_capability)) {
            return .{ .deny = .capability_mismatch };
        }
        if (tool.effect.needsApproval()) return .require_approval;
        return .invoke;
    }

    /// Whether a tool is registered at all.
    pub fn has(registry: Registry, name: []const u8) bool {
        return registry.find(name) != null;
    }
};

const sample = [_]Tool{
    .{ .name = "read_file", .required_capability = "files.read", .effect = .read_only },
    .{ .name = "write_note", .required_capability = "notes.write", .effect = .local_mutation },
    .{ .name = "send_message", .required_capability = "messages.send", .effect = .external },
    .{ .name = "make_payment", .required_capability = "wallet.pay", .effect = .value_transfer },
};

const sample_registry: Registry = .{ .tools = &sample };

test "a read-only tool with the right capability invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_registry.admit("read_file", "files.read"));
}

test "a local mutation with the right capability invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_registry.admit("write_note", "notes.write"));
}

test "an external tool requires approval even with the capability" {
    // Holding messages.send lets the agent propose a send; a person still
    // approves it, because it leaves the device.
    try std.testing.expectEqual(
        Decision.require_approval,
        sample_registry.admit("send_message", "messages.send"),
    );
}

test "a value transfer requires approval" {
    try std.testing.expectEqual(
        Decision.require_approval,
        sample_registry.admit("make_payment", "wallet.pay"),
    );
}

test "an unknown tool is refused, not guessed at" {
    // A hallucinated tool name goes nowhere.
    try std.testing.expectEqual(
        Decision{ .deny = .unknown_tool },
        sample_registry.admit("delete_everything", "files.read"),
    );
}

test "the wrong capability for a tool is refused" {
    // Holding files.read does not let the agent call send_message: each tool has
    // its own capability.
    try std.testing.expectEqual(
        Decision{ .deny = .capability_mismatch },
        sample_registry.admit("send_message", "files.read"),
    );
}

test "a capability for one tool never dispatches another" {
    // Swept: presenting each tool's capability admits that tool and no other.
    for (sample) |holder| {
        for (sample) |target| {
            const decision = sample_registry.admit(target.name, holder.required_capability);
            const same = std.mem.eql(u8, holder.required_capability, target.required_capability);
            if (same) {
                try std.testing.expect(decision.permitsInvocation());
            } else {
                try std.testing.expectEqual(Decision{ .deny = .capability_mismatch }, decision);
            }
        }
    }
}

test "no external or value tool ever invokes without approval" {
    // The property the registry holds: a consequential effect is never returned
    // as a bare invoke, even with the correct capability.
    for (sample) |tool| {
        const decision = sample_registry.admit(tool.name, tool.required_capability);
        if (tool.effect.needsApproval()) {
            try std.testing.expectEqual(Decision.require_approval, decision);
        } else {
            try std.testing.expectEqual(Decision.invoke, decision);
        }
    }
}

test "the registry is closed" {
    // An agent may call only registered tools; membership is exact.
    try std.testing.expect(sample_registry.has("read_file"));
    try std.testing.expect(!sample_registry.has("read_files")); // near miss
    try std.testing.expect(!sample_registry.has(""));
}

test "the effects that need approval are external and value transfer" {
    try std.testing.expect(!Effect.read_only.needsApproval());
    try std.testing.expect(!Effect.local_mutation.needsApproval());
    try std.testing.expect(Effect.external.needsApproval());
    try std.testing.expect(Effect.value_transfer.needsApproval());
}

test "an empty registry admits nothing" {
    const empty: Registry = .{ .tools = &.{} };
    try std.testing.expectEqual(Decision{ .deny = .unknown_tool }, empty.admit("read_file", "files.read"));
}
