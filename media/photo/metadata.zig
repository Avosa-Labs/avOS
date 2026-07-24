//! Deciding which photo metadata is kept when a photo leaves the device, so a shared picture
//! does not silently carry where and when it was taken.
//!
//! Every photo a camera takes embeds metadata a person never sees: the exact GPS coordinates of
//! where it was shot, the precise time, sometimes the device and its owner. Kept on the device
//! this is useful — it sorts photos by place and date. Sent to someone else it is a leak: a
//! holiday photo posted publicly reveals a home address, a picture shared with one person
//! carries the location of where the person is right now. So when a photo is exported off the
//! device, the revealing metadata is stripped by default, and kept only for a destination the
//! person trusts with it or when they explicitly chose to include it. Harmless technical fields
//! — the dimensions, the orientation — always stay, because they carry nothing about the
//! person. Stripping location and time on export, and keeping only what the person allowed, is
//! what lets sharing a photo share the picture and not the person's whereabouts.
//!
//! This module reads no photo. It decides whether a metadata field survives an export, from its
//! sensitivity, the destination's trust, and the person's choice, as a pure function.

const std = @import("std");

/// How revealing a metadata field is.
pub const Sensitivity = enum {
    /// Technical and impersonal: dimensions, orientation, colour profile. Always kept.
    technical,
    /// Reveals the person or their context: GPS location, timestamp, device owner. Stripped on
    /// export by default.
    revealing,
};

/// How much the export destination is trusted with revealing metadata.
pub const Destination = enum {
    /// The person's own storage or a device they own. May keep revealing metadata.
    trusted,
    /// An outside destination: another person, a public post, a third-party app. Revealing
    /// metadata stripped unless the person opts in.
    external,

    fn trustsRevealing(destination: Destination) bool {
        return destination == .trusted;
    }
};

/// Whether a metadata field is kept when exporting a photo to a destination.
///
/// Technical metadata is always kept — it discloses nothing. Revealing metadata is kept only
/// when the destination is trusted or the person explicitly chose to include it; otherwise it is
/// stripped. The default for revealing metadata to an external destination is therefore to
/// remove it, so location and time do not leave with a shared photo unless the person meant them
/// to.
pub fn keepField(sensitivity: Sensitivity, destination: Destination, person_opted_in: bool) bool {
    return switch (sensitivity) {
        .technical => true,
        .revealing => destination.trustsRevealing() or person_opted_in,
    };
}

test "technical metadata is always kept" {
    for ([_]Destination{ .trusted, .external }) |destination| {
        try std.testing.expect(keepField(.technical, destination, false));
    }
}

test "location is stripped on an external export by default" {
    try std.testing.expect(!keepField(.revealing, .external, false));
}

test "revealing metadata is kept to a trusted destination" {
    try std.testing.expect(keepField(.revealing, .trusted, false));
}

test "the person may opt in to sharing revealing metadata externally" {
    try std.testing.expect(keepField(.revealing, .external, true));
}

test "no revealing field leaves externally without opt-in, swept" {
    // The whereabouts-privacy property: for an external export the person did not opt into,
    // every kept field is technical.
    for ([_]Sensitivity{ .technical, .revealing }) |sensitivity| {
        if (keepField(sensitivity, .external, false)) {
            try std.testing.expectEqual(Sensitivity.technical, sensitivity);
        }
    }
}
