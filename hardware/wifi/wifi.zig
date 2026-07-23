//! Choosing which wireless network to join, and refusing the ones that lie about
//! who they are.
//!
//! A wireless network is an invitation from a stranger. The dangerous ones are
//! not the weak or the slow; they are the ones that impersonate a network the
//! device already trusts, so that a device auto-joining "home" connects to an
//! attacker who named their access point the same thing. So joining is not a
//! matter of picking the strongest signal with a known name — it is bound to
//! whether the network authenticates itself the way the trusted one did, and an
//! open network is never treated as one a device saw before.
//!
//! This selects; it associates with nothing. It takes the networks a scan found
//! and what the device remembers, and returns which to join or that none is
//! safe to join automatically. The selection is logic, testable across scan
//! results a radio would have to be surrounded by real access points to produce.

const std = @import("std");

/// How a network proves who it is.
///
/// The security is what makes a remembered network the same network. An open
/// network proves nothing, so it can be impersonated by anyone, which is why it
/// is never auto-joined on the strength of a familiar name.
pub const Security = enum {
    /// No authentication. Anyone can stand up a network with any name.
    open,
    /// A pre-shared key. The device and the network share a secret, so a
    /// network that completes the handshake holds the same key the trusted one
    /// did.
    personal,
    /// Enterprise authentication against a certificate. The strongest: the
    /// network proves itself with a credential an impersonator cannot forge.
    enterprise,

    /// Whether joining this kind of network proves it is the one remembered.
    ///
    /// Only the authenticated kinds do. An open network with a familiar name is
    /// exactly the impersonation risk, so it never qualifies.
    pub fn authenticatesNetwork(security: Security) bool {
        return security != .open;
    }
};

/// A network a scan found.
pub const Scanned = struct {
    /// The network name. Not identity: two networks may share one.
    name: []const u8,
    security: Security,
    /// Signal strength, higher is stronger. Used only to break ties among
    /// networks that are equally safe to join.
    signal: i16,
};

/// A network the device remembers joining before.
pub const Known = struct {
    name: []const u8,
    /// The security the network authenticated with when it was trusted. A
    /// remembered network that now presents weaker security is not the same
    /// network.
    security: Security,
};

/// Why no network was joined automatically.
pub const Refusal = enum {
    /// No scanned network matches a remembered one.
    none_known,
    /// A remembered name was seen, but only as an open network, which cannot
    /// prove it is the network that was trusted.
    only_open_impostor,
    /// A remembered name was seen, but with weaker security than it was trusted
    /// with — a possible downgrade attack.
    security_downgraded,
};

/// What the selector decided.
pub const Decision = union(enum) {
    /// Join this scanned network. Carries its index into the scan.
    join: usize,
    /// Join nothing automatically, with the reason.
    hold: Refusal,

    pub fn joins(decision: Decision) bool {
        return decision == .join;
    }
};

/// Chooses a network to join automatically.
///
/// A network is joinable only if its name is remembered *and* it authenticates
/// with at least the security it was trusted with. Among the joinable ones the
/// strongest signal wins, because signal is a comfort choice once safety is
/// settled. The distinct refusals matter: a person told "an impostor is claiming
/// your home network" can act, where "no network" leaves them guessing.
pub fn select(scanned: []const Scanned, known: []const Known) Decision {
    var best: ?usize = null;
    var best_signal: i16 = std.math.minInt(i16);
    var saw_open_impostor = false;
    var saw_downgrade = false;

    for (scanned, 0..) |network, index| {
        const remembered = find(known, network.name) orelse continue;

        // A remembered name with no authentication is the impersonation case: an
        // open network anyone could have named the same thing.
        if (!network.security.authenticatesNetwork()) {
            saw_open_impostor = true;
            continue;
        }

        // A remembered name presenting weaker security than it was trusted with
        // is a downgrade: the network that earned trust proved more than this
        // one is proving.
        if (@intFromEnum(network.security) < @intFromEnum(remembered.security)) {
            saw_downgrade = true;
            continue;
        }

        if (network.signal > best_signal) {
            best = index;
            best_signal = network.signal;
        }
    }

    if (best) |index| return .{ .join = index };
    if (saw_downgrade) return .{ .hold = .security_downgraded };
    if (saw_open_impostor) return .{ .hold = .only_open_impostor };
    return .{ .hold = .none_known };
}

fn find(known: []const Known, name: []const u8) ?Known {
    for (known) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const home: Known = .{ .name = "home", .security = .personal };
const work: Known = .{ .name = "work", .security = .enterprise };

test "a remembered authenticated network is joined" {
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .personal, .signal = -50 },
    };
    const decision = select(&scanned, &.{home});
    try std.testing.expect(decision.joins());
    try std.testing.expectEqual(@as(usize, 0), decision.join);
}

test "an open network with a remembered name is not joined" {
    // The core impersonation case: an attacker names an open access point
    // "home". It cannot prove it is the home network, so it is refused.
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .open, .signal = -30 },
    };
    const decision = select(&scanned, &.{home});
    try std.testing.expectEqual(Decision{ .hold = .only_open_impostor }, decision);
}

test "a downgraded security on a remembered name is refused" {
    // "work" was trusted as enterprise; a network claiming "work" with only a
    // pre-shared key is proving less than the trusted one did.
    const scanned = [_]Scanned{
        .{ .name = "work", .security = .personal, .signal = -30 },
    };
    const decision = select(&scanned, &.{work});
    try std.testing.expectEqual(Decision{ .hold = .security_downgraded }, decision);
}

test "an unknown network is never joined automatically" {
    const scanned = [_]Scanned{
        .{ .name = "coffee-shop", .security = .open, .signal = -20 },
    };
    try std.testing.expectEqual(Decision{ .hold = .none_known }, select(&scanned, &.{home}));
}

test "the strongest safe network wins" {
    // Two remembered, authenticated networks; the stronger signal is chosen.
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .personal, .signal = -70 },
        .{ .name = "work", .security = .enterprise, .signal = -40 },
    };
    const decision = select(&scanned, &.{ home, work });
    try std.testing.expect(decision.joins());
    try std.testing.expectEqual(@as(usize, 1), decision.join);
}

test "a stronger impostor never beats a weaker genuine network" {
    // The impostor has a much stronger signal, but signal only breaks ties among
    // safe networks; it never makes an unsafe one joinable.
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .open, .signal = -10 }, // loud impostor
        .{ .name = "home", .security = .personal, .signal = -80 }, // genuine, faint
    };
    const decision = select(&scanned, &.{home});
    try std.testing.expect(decision.joins());
    // The genuine one, not the loud impostor.
    try std.testing.expectEqual(Security.personal, scanned[decision.join].security);
}

test "stronger-than-remembered security is accepted" {
    // "home" was trusted as personal; a network claiming "home" with enterprise
    // security proves more, not less, so it is fine.
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .enterprise, .signal = -50 },
    };
    try std.testing.expect(select(&scanned, &.{home}).joins());
}

test "an empty scan holds for none known" {
    try std.testing.expectEqual(Decision{ .hold = .none_known }, select(&.{}, &.{home}));
}

test "only authenticated security kinds prove a network" {
    try std.testing.expect(!Security.open.authenticatesNetwork());
    try std.testing.expect(Security.personal.authenticatesNetwork());
    try std.testing.expect(Security.enterprise.authenticatesNetwork());
}

test "the downgrade reason is preferred when both an impostor and a downgrade appear" {
    // A downgrade is a more specific and more alarming finding than a bare
    // open impostor, so it is the reason surfaced.
    const scanned = [_]Scanned{
        .{ .name = "home", .security = .open, .signal = -20 },
        .{ .name = "work", .security = .personal, .signal = -20 },
    };
    try std.testing.expectEqual(
        Decision{ .hold = .security_downgraded },
        select(&scanned, &.{ home, work }),
    );
}
