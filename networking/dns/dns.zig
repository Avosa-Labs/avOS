//! Deciding whether a name's resolved address may be used, before anyone connects
//! to it.
//!
//! Name resolution looks like a lookup, but it is a trust boundary. The answer to
//! a DNS query is attacker-influenceable in a way the query is not: whoever
//! controls a name — or a resolver on the path, or a poisoned cache — chooses the
//! address it resolves to. The classic attack is rebinding: a public name the
//! person's agent is allowed to reach resolves, on a second lookup, to
//! 127.0.0.1 or a 192.168 address, and now a request meant for the internet is
//! aimed at a service inside the device or the home network that never expected a
//! caller. The firewall governs which destinations a principal may reach; this
//! module governs the step before it, where a name becomes an address, so a
//! public name can never launder itself into a private address.
//!
//! This module resolves nothing over the wire. It classifies the address an
//! answer carries, decides whether that address is allowed for the context the
//! query came from, and clamps the record's lifetime into sane bounds so a
//! poisoned tiny or enormous TTL cannot pin or thrash the cache. It is pure logic
//! over an answer someone else fetched.

const std = @import("std");

/// What kind of address an answer resolved to, coarse enough to make a trust
/// decision without inspecting every octet.
pub const AddressClass = enum {
    /// A routable public address. The only class a public name is expected to
    /// resolve to.
    public,
    /// The device itself, over loopback. Reaching it from an untrusted query is
    /// how rebinding pivots inward.
    loopback,
    /// A private-range address (RFC 1918 / unique-local): another device on the
    /// person's own network.
    private,
    /// A link-local address, reachable only on the immediate segment.
    link_local,
    /// The unspecified or otherwise unusable address. Never a valid answer.
    unspecified,

    /// Whether an address of this class is inside the person's trust boundary —
    /// the device itself or its local network — rather than out on the public
    /// internet.
    pub fn isInternal(class: AddressClass) bool {
        return class == .loopback or class == .private or class == .link_local;
    }
};

/// Classifies an IPv4 address by its leading octets. The ranges are the standard
/// special-use allocations; everything outside them is treated as public.
pub fn classifyV4(octets: [4]u8) AddressClass {
    if (octets[0] == 0) return .unspecified; // 0.0.0.0/8
    if (octets[0] == 127) return .loopback; // 127.0.0.0/8
    if (octets[0] == 10) return .private; // 10.0.0.0/8
    if (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) return .private; // 172.16.0.0/12
    if (octets[0] == 192 and octets[1] == 168) return .private; // 192.168.0.0/16
    if (octets[0] == 169 and octets[1] == 254) return .link_local; // 169.254.0.0/16
    return .public;
}

/// Classifies an IPv6 address by its leading bytes: loopback (::1), unspecified
/// (::), unique-local (fc00::/7), and link-local (fe80::/10).
pub fn classifyV6(bytes: [16]u8) AddressClass {
    var all_zero_but_last = true;
    for (bytes[0..15]) |b| {
        if (b != 0) {
            all_zero_but_last = false;
            break;
        }
    }
    if (all_zero_but_last) {
        return switch (bytes[15]) {
            0 => .unspecified, // ::
            1 => .loopback, // ::1
            else => .public,
        };
    }
    if (bytes[0] & 0xfe == 0xfc) return .private; // fc00::/7 unique-local
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return .link_local; // fe80::/10
    return .public;
}

/// Where a query came from, which fixes what its answer is allowed to be.
pub const Origin = enum {
    /// A trusted system component resolving a name for its own purposes: an
    /// update service, a diagnostics probe. Permitted to resolve names to
    /// internal addresses, because reaching the local network is sometimes its
    /// job.
    system,
    /// An untrusted principal: an agent acting on model output, content fetched
    /// from the web, a sandboxed app. A public name resolving to an internal
    /// address for this origin is rebinding and is refused.
    untrusted,

    /// Whether a query from this origin is allowed to follow a name to an
    /// internal address at all.
    fn mayReachInternal(origin: Origin) bool {
        return origin == .system;
    }
};

/// Why a resolved answer was refused.
pub const Refusal = enum {
    /// The answer resolved to an internal address for an untrusted query: the
    /// rebinding case. Refused so a public name cannot aim a caller inward.
    rebinding,
    /// The address is unspecified or otherwise unusable; not a real destination.
    unusable_address,
    /// The name is on the resolution blocklist and is never resolved.
    blocked,
};

/// The outcome of admitting a resolved answer.
pub const Decision = union(enum) {
    /// The answer may be used, with its lifetime clamped to this many seconds.
    accept: u32,
    /// The answer is refused.
    refuse: Refusal,

    pub fn accepted(decision: Decision) bool {
        return decision == .accept;
    }
};

/// The bounds a record's time-to-live is clamped into.
///
/// A cache honours the TTL an answer carries, which means a poisoned answer can
/// set it. A TTL of zero forces a re-lookup on every use, turning the cache off
/// and amplifying a poisoning attempt into constant traffic; an enormous TTL pins
/// a poisoned answer for days. Clamping into a sane window bounds both.
pub const ttl_floor_seconds: u32 = 30;
pub const ttl_ceiling_seconds: u32 = 24 * 60 * 60;

/// Clamps a record's lifetime into the allowed window.
pub fn clampTtl(ttl_seconds: u32) u32 {
    return std.math.clamp(ttl_seconds, ttl_floor_seconds, ttl_ceiling_seconds);
}

/// A resolved answer waiting to be admitted.
pub const Answer = struct {
    /// The class the resolved address falls into, from classifyV4 / classifyV6.
    class: AddressClass,
    /// The lifetime the answer claims, in seconds, before clamping.
    ttl_seconds: u32,
    /// Whether the queried name is on the blocklist.
    blocked: bool = false,
};

/// Decides whether a resolved answer may be used by a query from a given origin.
///
/// A blocked name is refused outright. An unspecified address is never a usable
/// destination. The rebinding check is the heart of it: an untrusted query whose
/// answer points inside the trust boundary — loopback, private, or link-local —
/// is refused, because that is a public name being followed to a private service.
/// A trusted system query is permitted to reach internal addresses, because doing
/// so is sometimes its purpose. An accepted answer carries its lifetime clamped
/// into the allowed window.
pub fn admit(answer: Answer, origin: Origin) Decision {
    if (answer.blocked) return .{ .refuse = .blocked };
    if (answer.class == .unspecified) return .{ .refuse = .unusable_address };
    if (answer.class.isInternal() and !origin.mayReachInternal()) {
        return .{ .refuse = .rebinding };
    }
    return .{ .accept = clampTtl(answer.ttl_seconds) };
}

test "public IPv4 ranges are public and special ranges are classified" {
    try std.testing.expectEqual(AddressClass.public, classifyV4(.{ 8, 8, 8, 8 }));
    try std.testing.expectEqual(AddressClass.loopback, classifyV4(.{ 127, 0, 0, 1 }));
    try std.testing.expectEqual(AddressClass.private, classifyV4(.{ 10, 1, 2, 3 }));
    try std.testing.expectEqual(AddressClass.private, classifyV4(.{ 192, 168, 1, 1 }));
    try std.testing.expectEqual(AddressClass.link_local, classifyV4(.{ 169, 254, 5, 5 }));
    try std.testing.expectEqual(AddressClass.unspecified, classifyV4(.{ 0, 0, 0, 0 }));
}

test "the 172.16/12 private range is bounded exactly" {
    // 172.16 through 172.31 are private; 172.15 and 172.32 are public.
    try std.testing.expectEqual(AddressClass.public, classifyV4(.{ 172, 15, 0, 1 }));
    try std.testing.expectEqual(AddressClass.private, classifyV4(.{ 172, 16, 0, 1 }));
    try std.testing.expectEqual(AddressClass.private, classifyV4(.{ 172, 31, 255, 255 }));
    try std.testing.expectEqual(AddressClass.public, classifyV4(.{ 172, 32, 0, 1 }));
}

test "IPv6 loopback, unspecified, unique-local, and link-local are classified" {
    var loopback = [_]u8{0} ** 16;
    loopback[15] = 1;
    try std.testing.expectEqual(AddressClass.loopback, classifyV6(loopback));

    const unspecified = [_]u8{0} ** 16;
    try std.testing.expectEqual(AddressClass.unspecified, classifyV6(unspecified));

    var unique_local = [_]u8{0} ** 16;
    unique_local[0] = 0xfd;
    try std.testing.expectEqual(AddressClass.private, classifyV6(unique_local));

    var link_local = [_]u8{0} ** 16;
    link_local[0] = 0xfe;
    link_local[1] = 0x80;
    try std.testing.expectEqual(AddressClass.link_local, classifyV6(link_local));

    var public = [_]u8{0} ** 16;
    public[0] = 0x20;
    public[1] = 0x01;
    try std.testing.expectEqual(AddressClass.public, classifyV6(public));
}

test "an untrusted query to an internal address is refused as rebinding" {
    // The attack: a public name the agent may reach resolves to loopback.
    for ([_]AddressClass{ .loopback, .private, .link_local }) |class| {
        const answer: Answer = .{ .class = class, .ttl_seconds = 300 };
        try std.testing.expectEqual(Decision{ .refuse = .rebinding }, admit(answer, .untrusted));
    }
}

test "a system query may reach an internal address" {
    // Resolving a local device by name is sometimes a system component's job.
    const answer: Answer = .{ .class = .private, .ttl_seconds = 300 };
    try std.testing.expect(admit(answer, .system).accepted());
}

test "a public answer is accepted for either origin" {
    const answer: Answer = .{ .class = .public, .ttl_seconds = 300 };
    try std.testing.expect(admit(answer, .untrusted).accepted());
    try std.testing.expect(admit(answer, .system).accepted());
}

test "a blocked name is refused whatever it resolves to" {
    const answer: Answer = .{ .class = .public, .ttl_seconds = 300, .blocked = true };
    try std.testing.expectEqual(Decision{ .refuse = .blocked }, admit(answer, .system));
    try std.testing.expectEqual(Decision{ .refuse = .blocked }, admit(answer, .untrusted));
}

test "an unspecified address is never a usable destination" {
    const answer: Answer = .{ .class = .unspecified, .ttl_seconds = 300 };
    try std.testing.expectEqual(Decision{ .refuse = .unusable_address }, admit(answer, .system));
}

test "TTL is clamped into the allowed window" {
    try std.testing.expectEqual(ttl_floor_seconds, clampTtl(0));
    try std.testing.expectEqual(ttl_floor_seconds, clampTtl(5));
    try std.testing.expectEqual(@as(u32, 300), clampTtl(300));
    try std.testing.expectEqual(ttl_ceiling_seconds, clampTtl(std.math.maxInt(u32)));
}

test "an accepted answer carries its clamped lifetime" {
    const answer: Answer = .{ .class = .public, .ttl_seconds = 3 };
    // The claimed 3s is below the floor: the cache is given the floor instead.
    try std.testing.expectEqual(Decision{ .accept = ttl_floor_seconds }, admit(answer, .untrusted));
}

test "isInternal covers exactly the inside-the-boundary classes" {
    try std.testing.expect(AddressClass.loopback.isInternal());
    try std.testing.expect(AddressClass.private.isInternal());
    try std.testing.expect(AddressClass.link_local.isInternal());
    try std.testing.expect(!AddressClass.public.isInternal());
    try std.testing.expect(!AddressClass.unspecified.isInternal());
}

test "no untrusted query ever reaches an internal address, swept" {
    // The property the module exists to hold: across every class, an untrusted
    // origin is admitted only to public addresses.
    for (std.enums.values(AddressClass)) |class| {
        const answer: Answer = .{ .class = class, .ttl_seconds = 300 };
        const decision = admit(answer, .untrusted);
        if (decision.accepted()) {
            try std.testing.expectEqual(AddressClass.public, class);
        }
    }
}
