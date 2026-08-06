//! The seam a service consults to enforce an agent's accepted manifest without depending on the service
//! that owns it.
//!
//! The accepted-manifest store lives in the principal service's provisioner, but the capability service —
//! a separate service — must gate on it every call. Rather than couple the two, the provisioner hands out
//! a `Gate`: a borrowed context and a decide function, exactly like the endpoint's borrowed capability
//! resolver. The gate answers one question — may this agent exercise this capability — as an
//! ungoverned/granted/denied ruling, so the capability service reads authority through a dependency-free
//! boundary. The same seam later becomes an IPC stub across the process boundary without touching either
//! gate, and it reads only the manifest and the principal, never the mind, so substrate-neutrality holds
//! by construction.

/// The ruling the gate returns for one agent exercising one capability. `ungoverned` is the principal that
/// holds no accepted manifest at all — a human root or a system caller — which passes through to the
/// existing capability-record gate rather than being denied by default. `granted` and `denied` are the
/// two outcomes for a manifest-governed agent.
pub const Ruling = enum { ungoverned, granted, denied };

/// A borrowed enforcement seam: the store that holds accepted manifests, and the function that rules on
/// one operation against it. The context must outlive every holder of the gate, like the endpoint's
/// borrowed verifier and resolver.
pub const Gate = struct {
    context: *anyopaque,
    decide: *const fn (context: *anyopaque, agent: u128, capability_name: []const u8) Ruling,

    /// Rules on one agent exercising one capability.
    pub fn rule(gate: Gate, agent: u128, capability_name: []const u8) Ruling {
        return gate.decide(gate.context, agent, capability_name);
    }
};

// --- Tests ---

const std = @import("std");

test "a gate routes through its context and returns the store's ruling" {
    const Store = struct {
        governed: u128,
        fn decide(context: *anyopaque, agent: u128, capability_name: []const u8) Ruling {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (agent != self.governed) return .ungoverned;
            if (std.mem.eql(u8, capability_name, "calendar.read")) return .granted;
            return .denied;
        }
    };
    var store: Store = .{ .governed = 0x7 };
    const gate: Gate = .{ .context = &store, .decide = Store.decide };

    try std.testing.expectEqual(Ruling.ungoverned, gate.rule(0x1, "calendar.read"));
    try std.testing.expectEqual(Ruling.granted, gate.rule(0x7, "calendar.read"));
    try std.testing.expectEqual(Ruling.denied, gate.rule(0x7, "files.delete"));
}
