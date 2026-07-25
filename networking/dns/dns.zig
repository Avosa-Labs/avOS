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
/// (::), unique-local (fc00::/7), and link-local (fe80::/10). An address that
/// embeds an IPv4 destination is classified by that destination, so a v6 answer
/// cannot smuggle an internal IPv4 address past the rebinding check.
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
    // An IPv6 answer can carry an IPv4 destination inside it, and the socket layer
    // routes such an address to that IPv4 host. If the classifier judged only the
    // v6 prefix, an untrusted name could resolve to ::ffff:127.0.0.1 and pivot
    // inward exactly as 127.0.0.1 would — the rebinding this module exists to stop,
    // in v6 dress. So an embedded-v4 form is classified by the address it reaches.
    if (embeddedV4(bytes)) |octets| return classifyV4(octets);

    if (bytes[0] & 0xfe == 0xfc) return .private; // fc00::/7 unique-local
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return .link_local; // fe80::/10
    return .public;
}

/// The IPv4 address an IPv6 address embeds, if it is one of the forms a stack
/// routes to IPv4: IPv4-mapped (::ffff:0:0/96), IPv4-compatible (::/96, deprecated
/// but still routed by some stacks), or NAT64 with the well-known prefix
/// (64:ff9b::/96). Null for any other address. The `::`/`::1` forms are handled by
/// the caller before this runs, so they never reach here as a v4-compatible answer.
fn embeddedV4(bytes: [16]u8) ?[4]u8 {
    const last_four: [4]u8 = .{ bytes[12], bytes[13], bytes[14], bytes[15] };
    const first_ten_zero = isZero(bytes[0..10]);

    // ::ffff:a.b.c.d
    if (first_ten_zero and bytes[10] == 0xff and bytes[11] == 0xff) return last_four;
    // ::a.b.c.d — IPv4-compatible: the first twelve bytes are zero.
    if (first_ten_zero and bytes[10] == 0 and bytes[11] == 0) return last_four;
    // 64:ff9b::a.b.c.d — NAT64 well-known prefix.
    if (bytes[0] == 0x00 and bytes[1] == 0x64 and bytes[2] == 0xff and bytes[3] == 0x9b and
        isZero(bytes[4..12])) return last_four;
    return null;
}

fn isZero(slice: []const u8) bool {
    for (slice) |b| {
        if (b != 0) return false;
    }
    return true;
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

test "an IPv6 answer embedding an internal IPv4 address is classified by that address" {
    // ::ffff:127.0.0.1 — IPv4-mapped loopback. Must not read as public, or an
    // untrusted name resolving to it would pivot to 127.0.0.1.
    var mapped_loopback = [_]u8{0} ** 16;
    mapped_loopback[10] = 0xff;
    mapped_loopback[11] = 0xff;
    mapped_loopback[12] = 127;
    mapped_loopback[15] = 1;
    try std.testing.expectEqual(AddressClass.loopback, classifyV6(mapped_loopback));

    // ::ffff:192.168.1.1 — IPv4-mapped private.
    var mapped_private = [_]u8{0} ** 16;
    mapped_private[10] = 0xff;
    mapped_private[11] = 0xff;
    mapped_private[12] = 192;
    mapped_private[13] = 168;
    mapped_private[14] = 1;
    mapped_private[15] = 1;
    try std.testing.expectEqual(AddressClass.private, classifyV6(mapped_private));

    // ::127.0.0.1 — deprecated IPv4-compatible loopback.
    var compat_loopback = [_]u8{0} ** 16;
    compat_loopback[12] = 127;
    compat_loopback[15] = 1;
    try std.testing.expectEqual(AddressClass.loopback, classifyV6(compat_loopback));

    // 64:ff9b::7f00:1 — NAT64 well-known prefix wrapping 127.0.0.1.
    var nat64_loopback = [_]u8{0} ** 16;
    nat64_loopback[1] = 0x64;
    nat64_loopback[2] = 0xff;
    nat64_loopback[3] = 0x9b;
    nat64_loopback[12] = 127;
    nat64_loopback[15] = 1;
    try std.testing.expectEqual(AddressClass.loopback, classifyV6(nat64_loopback));

    // ::ffff:8.8.8.8 — a mapped public address stays public.
    var mapped_public = [_]u8{0} ** 16;
    mapped_public[10] = 0xff;
    mapped_public[11] = 0xff;
    mapped_public[12] = 8;
    mapped_public[13] = 8;
    mapped_public[14] = 8;
    mapped_public[15] = 8;
    try std.testing.expectEqual(AddressClass.public, classifyV6(mapped_public));
}

test "an untrusted query to a mapped-loopback answer is refused as rebinding" {
    // The end-to-end path the classifier fix protects: the answer is admitted for
    // an untrusted origin only if it is genuinely public.
    var mapped_loopback = [_]u8{0} ** 16;
    mapped_loopback[10] = 0xff;
    mapped_loopback[11] = 0xff;
    mapped_loopback[12] = 127;
    mapped_loopback[15] = 1;
    const answer: Answer = .{ .class = classifyV6(mapped_loopback), .ttl_seconds = 300 };
    try std.testing.expectEqual(Decision{ .refuse = .rebinding }, admit(answer, .untrusted));
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
