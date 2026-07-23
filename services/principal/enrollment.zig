//! Deciding who may enroll a new principal and on whose authority, so identities are
//! created by an authority that holds them rather than by anyone who asks.
//!
//! Every actor on the device — a person, an agent, a service — is a principal, and
//! creating one is creating authority, because the new principal will hold
//! capabilities and act. If anyone could enroll a principal, an attacker could mint
//! an actor and grant it whatever it liked; so enrollment is itself an authorized
//! operation. A human is enrolled by the device's own trusted setup, the root of the
//! chain. An agent or a service is never self-created: it is enrolled by a human, or
//! by a service that a human authorized, so every non-human principal traces back to
//! a person who stands behind it. And an issuer may only enroll a principal no more
//! powerful than itself — a service cannot conjure a principal with authority it does
//! not itself hold — because enrollment that could escalate is a privilege escalation
//! wearing the costume of account creation.
//!
//! This module enrolls nothing. It decides whether an enrollment request is permitted
//! given who is asking and what kind of principal they want to create, as a pure
//! function over the issuer and the request.

const std = @import("std");

/// The kind of principal, which fixes how it may be enrolled.
pub const Kind = enum(u8) {
    /// A person. Enrolled only by the device's trusted setup, the root of authority.
    human = 3,
    /// A trusted control-plane service. Enrolled by a human or an authorized service.
    service = 2,
    /// An agent acting for a person. Enrolled by a human or a service, never itself.
    agent = 1,

    fn authorityRank(kind: Kind) u8 {
        return @intFromEnum(kind);
    }
};

/// Who is requesting the enrollment.
pub const Issuer = union(enum) {
    /// The device's trusted setup flow. The root: may enroll the first human.
    trusted_setup,
    /// An existing principal enrolling another.
    principal: Kind,
};

/// An enrollment request.
pub const Request = struct {
    /// The kind of principal to create.
    kind: Kind,
};

/// Why an enrollment was refused.
pub const Refusal = enum {
    /// A human may be enrolled only by trusted setup, not by another principal.
    human_needs_trusted_setup,
    /// The issuer would create a principal more powerful than itself.
    would_escalate,
    /// The issuer is an agent, which may not enroll principals at all.
    issuer_not_authorized,
};

/// The enrollment decision.
pub const Decision = union(enum) {
    enroll,
    refuse: Refusal,

    pub fn enrolls(decision: Decision) bool {
        return decision == .enroll;
    }
};

/// Decides whether an enrollment request is permitted.
///
/// A human is enrolled only by trusted setup — no principal may mint a person. Any
/// other principal is enrolled by an issuing principal, which must be authorized to
/// enroll (an agent may not) and must hold authority at least equal to what it is
/// creating, so enrollment can never escalate: a service may enroll an agent or a
/// peer service, but nothing may enroll a principal outranking its issuer.
pub fn decide(issuer: Issuer, request: Request) Decision {
    switch (issuer) {
        .trusted_setup => {
            // Trusted setup exists to establish the first human authority.
            return .enroll;
        },
        .principal => |issuer_kind| {
            if (request.kind == .human) return .{ .refuse = .human_needs_trusted_setup };
            if (issuer_kind == .agent) return .{ .refuse = .issuer_not_authorized };
            if (request.kind.authorityRank() > issuer_kind.authorityRank()) {
                return .{ .refuse = .would_escalate };
            }
            return .enroll;
        },
    }
}

test "trusted setup enrolls the first human" {
    try std.testing.expect(decide(.trusted_setup, .{ .kind = .human }).enrolls());
}

test "a human cannot be enrolled by another principal" {
    try std.testing.expectEqual(
        Decision{ .refuse = .human_needs_trusted_setup },
        decide(.{ .principal = .human }, .{ .kind = .human }),
    );
}

test "a human enrolls a service and an agent" {
    try std.testing.expect(decide(.{ .principal = .human }, .{ .kind = .service }).enrolls());
    try std.testing.expect(decide(.{ .principal = .human }, .{ .kind = .agent }).enrolls());
}

test "a service enrolls an agent and a peer service" {
    try std.testing.expect(decide(.{ .principal = .service }, .{ .kind = .agent }).enrolls());
    try std.testing.expect(decide(.{ .principal = .service }, .{ .kind = .service }).enrolls());
}

test "an agent may not enroll anything" {
    try std.testing.expectEqual(
        Decision{ .refuse = .issuer_not_authorized },
        decide(.{ .principal = .agent }, .{ .kind = .agent }),
    );
}

test "a service cannot enroll a human — that would escalate past a person" {
    // Reported as needing trusted setup, since a human never comes from a principal.
    try std.testing.expectEqual(
        Decision{ .refuse = .human_needs_trusted_setup },
        decide(.{ .principal = .service }, .{ .kind = .human }),
    );
}

test "no principal enrollment ever creates authority above its issuer, swept" {
    // The no-escalation property: for any issuing principal, an enrolled kind never
    // outranks the issuer.
    const kinds = [_]Kind{ .human, .service, .agent };
    for (kinds) |issuer_kind| {
        for (kinds) |requested| {
            const decision = decide(.{ .principal = issuer_kind }, .{ .kind = requested });
            if (decision.enrolls()) {
                try std.testing.expect(requested.authorityRank() <= issuer_kind.authorityRank());
            }
        }
    }
}
