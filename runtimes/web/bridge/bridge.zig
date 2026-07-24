//! Deciding whether a call from web content may cross into a host capability, so a
//! page can use only the authority explicitly bridged to it and its untrusted content
//! can never drive a host effect on its own.
//!
//! A web page hosted here may need to do things only the host can do — take a photo,
//! read a granted file — and the bridge is the one doorway between the page's world and
//! the host's. Everything about that doorway is closed by default. A page may call only
//! the host functions explicitly exposed to it; a name it was not bridged is not
//! dispatched, so a page cannot reach a host capability by guessing at it. And the
//! content of a page is untrusted — scripts, and anything they pulled from the network —
//! so a consequential call the bridge does permit is not simply executed on the page's
//! say-so; it is surfaced for the host's approval, because a page driven by injected
//! content must not be able to spend or send by itself. The bridge exposes a small,
//! named surface and treats every consequential crossing as a request, not a command.
//!
//! This module dispatches nothing. It decides whether a bridged call may proceed, and
//! whether it needs host approval, from the exposed surface and the call's effect, as a
//! pure function.

const std = @import("std");

/// What a bridged host function does, which sets whether a page may invoke it on its
/// own.
pub const Effect = enum {
    /// Reads state the page was granted; changes nothing.
    read,
    /// A local, reversible change within the page's grant.
    local,
    /// A consequential effect: sending, publishing, spending. Never runs on the page's
    /// say-so alone.
    consequential,

    fn needsApproval(effect: Effect) bool {
        return effect == .consequential;
    }
};

/// A host function exposed to a page across the bridge.
pub const Exposed = struct {
    name: []const u8,
    effect: Effect,
};

/// Why a bridged call was refused.
pub const Refusal = enum {
    /// The page called a name that was not exposed to it. Not dispatched.
    not_exposed,
};

/// The outcome of a bridged call.
pub const Decision = union(enum) {
    /// The call may run directly.
    invoke,
    /// The call is permitted but must be surfaced for host approval first, because it
    /// is consequential and the page's content is untrusted.
    require_approval,
    /// The call is refused.
    refuse: Refusal,

    pub fn permitted(decision: Decision) bool {
        return decision == .invoke or decision == .require_approval;
    }
};

/// The bridge surface exposed to one page: the closed set of callable host functions.
pub const Surface = struct {
    exposed: []const Exposed,

    fn find(surface: Surface, name: []const u8) ?Exposed {
        for (surface.exposed) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    /// Decides whether a page's call to `name` may cross the bridge.
    ///
    /// The name must be one exposed to this page, or the call is refused rather than
    /// dispatched — a page cannot reach a host function it was not bridged. An exposed
    /// read or local call runs directly; an exposed consequential call is returned as
    /// requiring approval, because the page's content is untrusted and a consequential
    /// effect must not run on its say-so alone.
    pub fn call(surface: Surface, name: []const u8) Decision {
        const function = surface.find(name) orelse return .{ .refuse = .not_exposed };
        if (function.effect.needsApproval()) return .require_approval;
        return .invoke;
    }
};

const exposed = [_]Exposed{
    .{ .name = "readGrantedFile", .effect = .read },
    .{ .name = "saveDraft", .effect = .local },
    .{ .name = "sendMessage", .effect = .consequential },
};

const sample_surface: Surface = .{ .exposed = &exposed };

test "an exposed read call invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_surface.call("readGrantedFile"));
}

test "an exposed local call invokes directly" {
    try std.testing.expectEqual(Decision.invoke, sample_surface.call("saveDraft"));
}

test "an exposed consequential call requires approval" {
    try std.testing.expectEqual(Decision.require_approval, sample_surface.call("sendMessage"));
}

test "a call to an unexposed name is refused, not dispatched" {
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, sample_surface.call("deleteEverything"));
    // A near miss is still not exposed.
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, sample_surface.call("readgrantedfile"));
}

test "an empty surface exposes nothing" {
    const empty: Surface = .{ .exposed = &.{} };
    try std.testing.expectEqual(Decision{ .refuse = .not_exposed }, empty.call("readGrantedFile"));
}

test "no consequential call ever invokes without approval, swept" {
    // The untrusted-content property: any consequential exposed function returns
    // require_approval, never a bare invoke.
    for (exposed) |function| {
        const decision = sample_surface.call(function.name);
        if (function.effect == .consequential) {
            try std.testing.expectEqual(Decision.require_approval, decision);
        } else {
            try std.testing.expectEqual(Decision.invoke, decision);
        }
    }
}

test "only exposed names are ever permitted, swept" {
    const names = [_][]const u8{ "readGrantedFile", "saveDraft", "sendMessage", "unknown", "" };
    for (names) |name| {
        var is_exposed = false;
        for (exposed) |function| {
            if (std.mem.eql(u8, function.name, name)) is_exposed = true;
        }
        try std.testing.expectEqual(is_exposed, sample_surface.call(name).permitted());
    }
}
