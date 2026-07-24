//! Deciding what happens to a file downloaded from the web — quarantined, refused, or
//! admitted — because a download is untrusted content arriving from outside and must
//! not be trusted or executed on arrival.
//!
//! A download is the web reaching onto the device's storage, and it is untrusted by
//! definition: it came from a page, and a page can offer anything. Three things govern
//! its fate. It must fit the storage the person allotted, so a download that would blow
//! past the quota is refused rather than filling the disk. It is never executed on
//! arrival — an executable download is quarantined, marked as from the web, and left
//! inert until the person explicitly runs it, because a browser that ran what it fetched
//! is the oldest malware vector there is. And ordinary content — a document, an image —
//! is admitted to storage but still tagged with its untrusted web origin so anything
//! that later opens it knows where it came from. The download lands, but it lands marked
//! and inert, never trusted, never running.
//!
//! This module writes no file. It decides the disposition of a download from its size,
//! kind, and the storage available, as a pure function.

const std = @import("std");

/// What kind of thing was downloaded, which sets whether it may ever run.
pub const Kind = enum {
    /// A document, image, archive of data — content to open, not to run.
    data,
    /// An executable or installer. Never run on arrival; quarantined for an explicit
    /// human decision.
    executable,
};

/// A download awaiting a disposition.
pub const Download = struct {
    size_bytes: u64,
    kind: Kind,
};

/// What the runtime does with a download.
pub const Disposition = union(enum) {
    /// Admitted to storage, tagged with its untrusted web origin.
    admit,
    /// Held inert and marked as from the web; runs only on an explicit human decision.
    quarantine,
    /// Refused: it would exceed the storage the person allotted.
    refuse_over_quota,

    pub fn stored(disposition: Disposition) bool {
        return disposition == .admit or disposition == .quarantine;
    }
};

/// Decides the disposition of a download, given the storage available to it.
///
/// The size gate comes first: a download larger than the available storage is refused
/// so the disk cannot be filled by a page. Within the quota, an executable is
/// quarantined — stored but inert, never run on arrival — while ordinary data is
/// admitted, tagged with its untrusted origin. Nothing downloaded is ever trusted or
/// executed merely because it arrived.
pub fn decide(download: Download, storage_available_bytes: u64) Disposition {
    if (download.size_bytes > storage_available_bytes) return .refuse_over_quota;
    return switch (download.kind) {
        .executable => .quarantine,
        .data => .admit,
    };
}

fn dl(size: u64, kind: Kind) Download {
    return .{ .size_bytes = size, .kind = kind };
}

test "ordinary data within quota is admitted" {
    try std.testing.expectEqual(Disposition.admit, decide(dl(1000, .data), 1_000_000));
}

test "an executable within quota is quarantined, not admitted to run" {
    try std.testing.expectEqual(Disposition.quarantine, decide(dl(1000, .executable), 1_000_000));
}

test "a download over the available storage is refused" {
    try std.testing.expectEqual(Disposition.refuse_over_quota, decide(dl(2_000_000, .data), 1_000_000));
    try std.testing.expectEqual(Disposition.refuse_over_quota, decide(dl(2_000_000, .executable), 1_000_000));
}

test "the quota boundary is inclusive" {
    try std.testing.expectEqual(Disposition.admit, decide(dl(1_000_000, .data), 1_000_000));
    try std.testing.expectEqual(Disposition.refuse_over_quota, decide(dl(1_000_001, .data), 1_000_000));
}

test "no executable is ever admitted to run on arrival, swept" {
    // The no-auto-execute property: an executable that is stored is always
    // quarantined, never admitted.
    var size: u64 = 0;
    while (size <= 2000) : (size += 500) {
        const disposition = decide(dl(size, .executable), 1000);
        if (disposition.stored()) {
            try std.testing.expectEqual(Disposition.quarantine, disposition);
        }
    }
}

test "nothing over quota is ever stored, swept" {
    for ([_]Kind{ .data, .executable }) |kind| {
        try std.testing.expect(!decide(dl(5000, kind), 1000).stored());
    }
}
