//! Computing the provenance of a value derived from several inputs, so trust never
//! rises across an operation and a result is only as trusted as its least-trusted
//! part.
//!
//! Agents transform data constantly — they summarise a document, merge a retrieved
//! passage with a person's note, compute over a model's output. Each transformation
//! produces a new value, and the safety of everything downstream depends on getting
//! that value's provenance right. The rule is that trust cannot be created by
//! computation: mixing anything untrusted into a result makes the result untrusted,
//! because a summary of a poisoned document is still a poisoned summary, and a note
//! that quotes an untrusted passage carries that passage's taint. Provenance therefore
//! propagates by taking the least-trusted of the inputs — a join toward untrusted —
//! so a single untrusted input taints the whole result, and only a result derived
//! entirely from trusted inputs stays trusted. This is what stops laundering: there is
//! no sequence of ordinary operations that turns untrusted data into trusted data.
//!
//! This module transforms no data. It computes the provenance of a derived value from
//! its inputs' provenances, as a pure function so the no-laundering rule holds in one
//! place.

const std = @import("std");

/// How trusted a value is, ordered so a join can take the minimum.
pub const Provenance = enum(u8) {
    /// Untrusted: from outside — a fetched document, a model's output over untrusted
    /// input, a third party.
    untrusted = 0,
    /// Endorsed: was untrusted but explicitly vouched for by a trusted authority for
    /// a specific use. Between untrusted and trusted.
    endorsed = 1,
    /// Trusted: from the person directly or a trusted system component.
    trusted = 2,

    fn rank(provenance: Provenance) u8 {
        return @intFromEnum(provenance);
    }
};

/// The provenance of a value derived from two inputs: the less trusted of the two.
///
/// Trust joins downward. Combining a trusted value with an untrusted one yields
/// untrusted, because the result reflects the untrusted part; two trusted inputs yield
/// trusted; and an endorsed input pulls a trusted one down to endorsed, since the
/// result is only as vouched-for as its weakest link. There is no combination that
/// produces a result more trusted than its least-trusted input.
pub fn combine(a: Provenance, b: Provenance) Provenance {
    return if (a.rank() <= b.rank()) a else b;
}

/// The provenance of a value derived from many inputs: the least trusted of all of
/// them. A value with no inputs is trusted, since it was produced from nothing
/// external — the caller supplies constants as trusted.
pub fn combineAll(inputs: []const Provenance) Provenance {
    var result: Provenance = .trusted;
    for (inputs) |input| result = combine(result, input);
    return result;
}

test "two trusted inputs stay trusted" {
    try std.testing.expectEqual(Provenance.trusted, combine(.trusted, .trusted));
}

test "any untrusted input makes the result untrusted" {
    try std.testing.expectEqual(Provenance.untrusted, combine(.trusted, .untrusted));
    try std.testing.expectEqual(Provenance.untrusted, combine(.untrusted, .trusted));
    try std.testing.expectEqual(Provenance.untrusted, combine(.endorsed, .untrusted));
}

test "endorsed pulls a trusted input down to endorsed" {
    try std.testing.expectEqual(Provenance.endorsed, combine(.trusted, .endorsed));
    try std.testing.expectEqual(Provenance.endorsed, combine(.endorsed, .endorsed));
}

test "combine is commutative" {
    for (std.enums.values(Provenance)) |a| {
        for (std.enums.values(Provenance)) |b| {
            try std.testing.expectEqual(combine(a, b), combine(b, a));
        }
    }
}

test "combining many inputs takes the least trusted" {
    try std.testing.expectEqual(Provenance.trusted, combineAll(&.{ .trusted, .trusted, .trusted }));
    try std.testing.expectEqual(Provenance.endorsed, combineAll(&.{ .trusted, .endorsed, .trusted }));
    try std.testing.expectEqual(Provenance.untrusted, combineAll(&.{ .trusted, .endorsed, .untrusted }));
}

test "no inputs is trusted" {
    try std.testing.expectEqual(Provenance.trusted, combineAll(&.{}));
}

test "a result is never more trusted than its least-trusted input, swept" {
    // The no-laundering property: for any pair, the combined provenance rank is at
    // most the minimum of the two.
    for (std.enums.values(Provenance)) |a| {
        for (std.enums.values(Provenance)) |b| {
            const result = combine(a, b);
            try std.testing.expect(result.rank() <= @min(a.rank(), b.rank()));
        }
    }
}

test "adding an untrusted input can never raise trust, swept" {
    // Appending untrusted data to any set of inputs yields untrusted.
    const bases = [_][]const Provenance{
        &.{.trusted}, &.{ .trusted, .endorsed }, &.{.endorsed}, &.{},
    };
    for (bases) |base| {
        var buf: [8]Provenance = undefined;
        @memcpy(buf[0..base.len], base);
        buf[base.len] = .untrusted;
        try std.testing.expectEqual(Provenance.untrusted, combineAll(buf[0 .. base.len + 1]));
    }
}
