//! Deciding what metadata is stripped when an item is shared, so sharing a photo or
//! a file does not silently hand over where a person was and what else they were
//! doing.
//!
//! Sharing feels like sending the thing on the screen, but the thing carries more
//! than it shows. A photo embeds the exact place and time it was taken; a document
//! embeds its author, its revision history, sometimes text a person thought they
//! deleted. Send it to a group chat and that hidden data goes too — a home address
//! in a holiday snap, a client's name in a file's history — disclosed to everyone
//! the item reaches without the person ever intending it. So sharing minimises by
//! default: the revealing metadata is stripped before the item leaves, and it is
//! kept only when the destination is one the person trusts with it or has explicitly
//! chosen to include it. What counts as revealing is graded — the location where a
//! photo was taken is far more sensitive than its resolution — so minimisation
//! removes what discloses a person and keeps what is merely technical.
//!
//! This module sends nothing. It decides which metadata fields survive a share to a
//! given destination, as a pure function over each field's sensitivity, the
//! destination's trust, and whether the person chose to include it.

const std = @import("std");

/// How revealing a metadata field is.
pub const Sensitivity = enum {
    /// Technical detail that reveals nothing about the person: dimensions, format,
    /// colour profile. Always kept.
    technical,
    /// Reveals the person or their context: capture location, author identity,
    /// device name, edit history. Stripped by default.
    revealing,
};

/// How much the share destination is trusted with revealing metadata.
pub const Destination = enum {
    /// A destination the person trusts with their context: their own storage, a
    /// device they own. Revealing metadata may be kept.
    trusted,
    /// An outside destination: another person, a public post, a third-party app.
    /// Revealing metadata is stripped unless the person chose to include it.
    external,

    fn trustsRevealing(destination: Destination) bool {
        return destination == .trusted;
    }
};

/// One metadata field attached to a shared item.
pub const Field = struct {
    name: []const u8,
    sensitivity: Sensitivity,
};

/// Whether a field is kept when sharing to a destination.
///
/// Technical metadata is always kept — it discloses nothing. Revealing metadata is
/// kept only when the destination is trusted, or when the person explicitly chose to
/// include it for this share; otherwise it is stripped. The default for revealing
/// metadata to an external destination is therefore to remove it, so nothing about
/// the person leaves unless it was meant to.
pub fn keepField(field: Field, destination: Destination, person_included: bool) bool {
    return switch (field.sensitivity) {
        .technical => true,
        .revealing => destination.trustsRevealing() or person_included,
    };
}

const item = [_]Field{
    .{ .name = "dimensions", .sensitivity = .technical },
    .{ .name = "format", .sensitivity = .technical },
    .{ .name = "capture_location", .sensitivity = .revealing },
    .{ .name = "author", .sensitivity = .revealing },
};

test "technical metadata is always kept" {
    for ([_]Destination{ .trusted, .external }) |destination| {
        try std.testing.expect(keepField(.{ .name = "d", .sensitivity = .technical }, destination, false));
    }
}

test "revealing metadata is stripped when sharing externally by default" {
    try std.testing.expect(!keepField(.{ .name = "capture_location", .sensitivity = .revealing }, .external, false));
}

test "revealing metadata is kept to a trusted destination" {
    try std.testing.expect(keepField(.{ .name = "capture_location", .sensitivity = .revealing }, .trusted, false));
}

test "the person may choose to include revealing metadata externally" {
    try std.testing.expect(keepField(.{ .name = "author", .sensitivity = .revealing }, .external, true));
}

test "a default external share drops exactly the revealing fields" {
    var kept: usize = 0;
    for (item) |field| {
        if (keepField(field, .external, false)) kept += 1;
    }
    // Only the two technical fields survive.
    try std.testing.expectEqual(@as(usize, 2), kept);
}

test "no revealing field ever leaves to an external destination without consent, swept" {
    // The minimisation property: for an external share the person did not opt into,
    // every kept field is technical.
    for (item) |field| {
        if (keepField(field, .external, false)) {
            try std.testing.expectEqual(Sensitivity.technical, field.sensitivity);
        }
    }
}
