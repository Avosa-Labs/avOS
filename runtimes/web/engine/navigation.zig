//! Deciding whether the web engine may navigate to a destination, so page content
//! cannot steer the engine to a privileged internal surface or downgrade a secure
//! session.
//!
//! Navigation is the web engine following a link or a script's instruction to load a
//! new destination, and because that instruction can come from untrusted page content,
//! where it is allowed to go is a security decision. A page must never navigate the
//! engine to an internal, privileged scheme — the surfaces that drive the host itself —
//! because that would let a web page reach controls the web has no business touching.
//! And a navigation that would carry a secure session down to an insecure transport is
//! refused, because a page that began protected must not be silently exposed by
//! following a link. Ordinary web-to-web navigation is allowed and simply loads the new
//! origin as fresh untrusted content, isolated from the last by the same-origin policy.
//! The engine goes where the web may go and refuses where page content is trying to
//! reach past it.
//!
//! This module loads no page. It decides whether a navigation to a destination is
//! allowed, from the destination's scheme and the current session's security, as a pure
//! function.

const std = @import("std");

/// The scheme class of a navigation destination, which sets whether the web may go
/// there.
pub const Scheme = enum {
    /// A secure web transport (https, wss). Allowed.
    secure_web,
    /// An insecure web transport (http, ws). Allowed only when not downgrading a
    /// secure session.
    insecure_web,
    /// An internal, privileged scheme that addresses host surfaces. Never a
    /// destination for web content.
    privileged_internal,

    fn isWeb(scheme: Scheme) bool {
        return scheme == .secure_web or scheme == .insecure_web;
    }
};

/// A navigation the engine is asked to perform.
pub const Navigation = struct {
    /// The destination's scheme class.
    destination: Scheme,
    /// Whether the current session is on a secure transport. A navigation off a secure
    /// session onto an insecure one is a downgrade.
    from_secure_session: bool,
};

/// Why a navigation was refused.
pub const Refusal = enum {
    /// The destination is a privileged internal scheme, which web content may not
    /// reach.
    privileged_scheme,
    /// The navigation would downgrade a secure session to an insecure transport.
    insecure_downgrade,
};

/// The navigation decision.
pub const Decision = union(enum) {
    /// The navigation proceeds; the destination loads as fresh untrusted content.
    navigate,
    refuse: Refusal,

    pub fn allowed(decision: Decision) bool {
        return decision == .navigate;
    }
};

/// Decides whether a navigation may proceed.
///
/// A privileged internal destination is refused outright: web content never navigates
/// to a host surface. An insecure destination reached from a secure session is refused
/// as a downgrade, so a protected session is not silently exposed. Any other web
/// navigation proceeds and loads the destination as fresh untrusted content.
pub fn decide(navigation: Navigation) Decision {
    if (navigation.destination == .privileged_internal) return .{ .refuse = .privileged_scheme };
    if (navigation.from_secure_session and navigation.destination == .insecure_web) {
        return .{ .refuse = .insecure_downgrade };
    }
    return .navigate;
}

test "secure web navigation proceeds" {
    try std.testing.expectEqual(Decision.navigate, decide(.{ .destination = .secure_web, .from_secure_session = true }));
}

test "web content may not navigate to a privileged internal scheme" {
    try std.testing.expectEqual(
        Decision{ .refuse = .privileged_scheme },
        decide(.{ .destination = .privileged_internal, .from_secure_session = false }),
    );
}

test "a secure session may not downgrade to insecure transport" {
    try std.testing.expectEqual(
        Decision{ .refuse = .insecure_downgrade },
        decide(.{ .destination = .insecure_web, .from_secure_session = true }),
    );
}

test "an insecure session may navigate to insecure web" {
    // No downgrade if the session was already insecure.
    try std.testing.expectEqual(Decision.navigate, decide(.{ .destination = .insecure_web, .from_secure_session = false }));
}

test "web content never reaches a privileged scheme, swept" {
    // The reach-past property: a privileged internal destination is refused whatever the
    // session state.
    for ([_]bool{ false, true }) |secure| {
        try std.testing.expect(!decide(.{ .destination = .privileged_internal, .from_secure_session = secure }).allowed());
    }
}

test "a secure session never silently downgrades, swept" {
    // From a secure session, any web destination allowed is itself secure.
    for ([_]Scheme{ .secure_web, .insecure_web }) |destination| {
        const decision = decide(.{ .destination = destination, .from_secure_session = true });
        if (decision.allowed()) try std.testing.expectEqual(Scheme.secure_web, destination);
    }
}
