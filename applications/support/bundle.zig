//! Deciding what goes into a support diagnostic bundle, so getting help does not mean handing over
//! the person's private data along with the logs.
//!
//! A support bundle is meant to carry the technical evidence of a problem — versions, error traces,
//! timings — to whoever can diagnose it. The danger is that the same logs are dense with personal
//! data: message contents, locations, account identifiers, the person's own files caught in a trace.
//! A bundle that swept all of that up would turn a request for help into a privacy disclosure to a
//! support channel the person did not think of that way. So a bundle includes technical diagnostics
//! by default and excludes personal data by default; a personal field is added only when the person
//! explicitly opts to include it for a diagnosis that genuinely needs it. The default runs toward
//! the least data that could explain a fault, not the most that might, because a support bundle
//! leaves the device and the person cannot pull it back. Redacting personal data unless it was
//! deliberately included keeps a diagnostic useful without making it a leak.
//!
//! This module builds no bundle. It decides whether a field is included in a support bundle, from
//! its kind and the person's inclusion choice, as a pure function.

const std = @import("std");

/// What kind of data a candidate bundle field holds.
pub const Field = enum {
    /// Technical diagnostics: versions, error codes, stack traces, timings. Included by default.
    diagnostic,
    /// Personal data: message content, location, account identifiers, files. Excluded by default.
    personal,
};

/// Whether a field is included in a support bundle.
///
/// A diagnostic field is included by default — it is what the bundle is for. A personal field is
/// included only when the person explicitly opted to include it; otherwise it is redacted, so the
/// bundle carries the evidence of the fault and not the person's private data.
pub fn include(field: Field, person_opted_in: bool) bool {
    return switch (field) {
        .diagnostic => true,
        .personal => person_opted_in,
    };
}

test "diagnostic data is included by default" {
    try std.testing.expect(include(.diagnostic, false));
}

test "personal data is redacted unless the person opts in" {
    try std.testing.expect(!include(.personal, false));
    try std.testing.expect(include(.personal, true));
}

test "personal data is included only on an explicit opt-in, swept" {
    // The redaction property: an included personal field was explicitly opted into.
    for ([_]bool{ false, true }) |opted_in| {
        if (include(.personal, opted_in)) {
            try std.testing.expect(opted_in);
        }
    }
}
