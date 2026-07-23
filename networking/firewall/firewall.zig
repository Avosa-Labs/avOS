//! Deciding whether a principal may open a connection, and to where.
//!
//! On an agent-native device, outbound network access is the most dangerous
//! capability an untrusted principal can hold, because it is how data leaves. A
//! compromised component or a manipulated model that can reach an arbitrary host
//! can exfiltrate anything it can read. So egress is not open by default and
//! narrowed later; it is closed by default and opened per principal to named
//! destinations, and every connection a principal opens is checked against what
//! it was actually allowed to reach.
//!
//! This module is that check. It carries no packets and holds no sockets; it
//! answers whether a given principal may connect to a given destination, as a
//! pure function over the egress rules that principal holds, so a connection an
//! attacker tries to open to a host nobody granted is refused here rather than
//! after the bytes are already flowing.

const std = @import("std");

/// A class of destination, coarse enough that a rule is meaningful without
/// enumerating every host.
pub const DestinationClass = enum {
    /// A specific service the principal was granted: an app's own backend, a
    /// named model endpoint.
    granted_service,
    /// The device's own control plane, over the loopback boundary.
    loopback,
    /// A local-network address, which can reach other devices the person owns
    /// and also probe a home network.
    local_network,
    /// Any public internet host not otherwise named. The broadest and most
    /// dangerous.
    public_internet,

    /// Whether reaching this class can send data off the device and out of the
    /// person's control.
    pub fn leavesTheDevice(class: DestinationClass) bool {
        return class == .public_internet or class == .granted_service or class == .local_network;
    }
};

/// A destination a principal wants to reach.
pub const Destination = struct {
    class: DestinationClass,
    /// An identifier for the specific service, when the class is
    /// granted_service. Matched exactly against the principal's grants.
    service: []const u8 = "",
    /// The port. A rule may restrict which ports a class is reachable on.
    port: u16,
};

/// An egress rule a principal holds.
pub const Rule = struct {
    class: DestinationClass,
    /// For granted_service, the exact service this rule permits. Empty for other
    /// classes, which are matched by class alone.
    service: []const u8 = "",
    /// The ports this rule permits, inclusive. A rule for a service usually pins
    /// a single port.
    port_low: u16 = 0,
    port_high: u16 = 65535,

    fn matches(rule: Rule, destination: Destination) bool {
        if (rule.class != destination.class) return false;
        if (destination.port < rule.port_low or destination.port > rule.port_high) return false;
        if (rule.class == .granted_service) {
            return std.mem.eql(u8, rule.service, destination.service);
        }
        return true;
    }
};

/// Why a connection was refused.
pub const Refusal = enum {
    /// No rule permits this destination. The default answer, because egress is
    /// closed by default.
    not_permitted,
    /// A rule permits the destination class but not this port.
    port_not_permitted,
    /// A rule names a different service than the one requested.
    service_not_granted,
};

/// The outcome of an egress attempt.
pub const Decision = union(enum) {
    allow,
    deny: Refusal,

    pub fn isAllowed(decision: Decision) bool {
        return decision == .allow;
    }
};

/// The egress rules a principal holds. Empty means it may reach nothing.
pub const Policy = struct {
    rules: []const Rule,

    /// Decides whether a destination may be reached.
    ///
    /// A connection is allowed only if a rule matches it exactly — class, port,
    /// and service. With no rules, nothing is reachable, which is the closed-by-
    /// default posture. The refusal is specific so a caller can tell a wrong
    /// port from a wrong service from an ungranted class, which matters for
    /// diagnosing a legitimate request as much as for logging an attack.
    pub fn permits(policy: Policy, destination: Destination) Decision {
        var saw_class = false;
        var saw_service = false;
        for (policy.rules) |rule| {
            if (rule.matches(destination)) return .allow;
            if (rule.class == destination.class) {
                saw_class = true;
                if (destination.class == .granted_service and
                    std.mem.eql(u8, rule.service, destination.service))
                {
                    saw_service = true;
                }
            }
        }

        // Refine the refusal from what almost matched.
        if (destination.class == .granted_service and !saw_service) {
            return .{ .deny = .service_not_granted };
        }
        if (saw_class) return .{ .deny = .port_not_permitted };
        return .{ .deny = .not_permitted };
    }
};

const loopback_rule: Rule = .{ .class = .loopback, .port_low = 8080, .port_high = 8080 };
const service_rule: Rule = .{ .class = .granted_service, .service = "calendar-backend", .port_low = 443, .port_high = 443 };

test "with no rules nothing is reachable" {
    // The closed-by-default posture: a principal that was granted nothing reaches
    // nowhere.
    const policy: Policy = .{ .rules = &.{} };
    try std.testing.expectEqual(
        Decision{ .deny = .not_permitted },
        policy.permits(.{ .class = .public_internet, .port = 443 }),
    );
}

test "a granted service on its port is allowed" {
    const policy: Policy = .{ .rules = &.{service_rule} };
    try std.testing.expect(policy.permits(.{
        .class = .granted_service,
        .service = "calendar-backend",
        .port = 443,
    }).isAllowed());
}

test "a different service is refused even on the same class and port" {
    const policy: Policy = .{ .rules = &.{service_rule} };
    // The grant is for calendar-backend; a request to reach another service is
    // refused, which is the exfiltration case: an agent redirected to a host it
    // was not given.
    try std.testing.expectEqual(
        Decision{ .deny = .service_not_granted },
        policy.permits(.{ .class = .granted_service, .service = "attacker-host", .port = 443 }),
    );
}

test "a granted service on the wrong port is refused" {
    const policy: Policy = .{ .rules = &.{service_rule} };
    try std.testing.expectEqual(
        Decision{ .deny = .port_not_permitted },
        policy.permits(.{ .class = .granted_service, .service = "calendar-backend", .port = 80 }),
    );
}

test "loopback is allowed only on its permitted port" {
    const policy: Policy = .{ .rules = &.{loopback_rule} };
    try std.testing.expect(policy.permits(.{ .class = .loopback, .port = 8080 }).isAllowed());
    try std.testing.expectEqual(
        Decision{ .deny = .port_not_permitted },
        policy.permits(.{ .class = .loopback, .port = 9090 }),
    );
}

test "public internet requires an explicit rule" {
    // Even the broad class is closed until granted.
    const closed: Policy = .{ .rules = &.{service_rule} };
    try std.testing.expectEqual(
        Decision{ .deny = .not_permitted },
        closed.permits(.{ .class = .public_internet, .port = 443 }),
    );

    const open: Policy = .{ .rules = &.{.{ .class = .public_internet, .port_low = 443, .port_high = 443 }} };
    try std.testing.expect(open.permits(.{ .class = .public_internet, .port = 443 }).isAllowed());
}

test "a port range permits every port within it" {
    const policy: Policy = .{ .rules = &.{.{ .class = .local_network, .port_low = 1024, .port_high = 2048 }} };
    try std.testing.expect(policy.permits(.{ .class = .local_network, .port = 1024 }).isAllowed());
    try std.testing.expect(policy.permits(.{ .class = .local_network, .port = 1500 }).isAllowed());
    try std.testing.expect(policy.permits(.{ .class = .local_network, .port = 2048 }).isAllowed());
    try std.testing.expect(!policy.permits(.{ .class = .local_network, .port = 2049 }).isAllowed());
}

test "several rules combine as a union" {
    const policy: Policy = .{ .rules = &.{ loopback_rule, service_rule } };
    try std.testing.expect(policy.permits(.{ .class = .loopback, .port = 8080 }).isAllowed());
    try std.testing.expect(policy.permits(.{
        .class = .granted_service,
        .service = "calendar-backend",
        .port = 443,
    }).isAllowed());
    // But nothing outside either rule.
    try std.testing.expect(!policy.permits(.{ .class = .public_internet, .port = 443 }).isAllowed());
}

test "the classes that leave the device are marked" {
    // Loopback stays on the device; the rest can carry data off it, which is why
    // they need grants.
    try std.testing.expect(!DestinationClass.loopback.leavesTheDevice());
    try std.testing.expect(DestinationClass.public_internet.leavesTheDevice());
    try std.testing.expect(DestinationClass.granted_service.leavesTheDevice());
    try std.testing.expect(DestinationClass.local_network.leavesTheDevice());
}

test "no destination is reachable that no rule matches, swept" {
    // The property the firewall exists for: for a policy granting exactly one
    // service, every other destination is refused.
    const policy: Policy = .{ .rules = &.{service_rule} };
    for (std.enums.values(DestinationClass)) |class| {
        const destination: Destination = .{ .class = class, .service = "something-else", .port = 443 };
        if (class == .granted_service) {
            // The one grant is for a different service name, so still refused.
            try std.testing.expect(!policy.permits(destination).isAllowed());
        } else {
            try std.testing.expect(!policy.permits(destination).isAllowed());
        }
    }
}
