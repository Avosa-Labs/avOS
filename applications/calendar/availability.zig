//! Deciding how much of a calendar event a query may see, so answering "are you free then?" reveals
//! only that — free or busy — and not who the person is meeting or why.
//!
//! Scheduling needs one bit: is this time taken. Event details — the title, the other attendees, the
//! location, the notes — are far more than that bit, and a person answering availability requests all
//! day should not be leaking their whole itinerary to do it. So a query about a time window is
//! answered at the granularity the requester was granted: an ordinary requester learns only free or
//! busy, while a requester the person granted detail access learns the event itself. The default is
//! free/busy because that is what scheduling actually requires, and every step beyond it discloses
//! something the requester did not need to schedule around. Granting detail is a deliberate act for
//! the people who should see it — a partner, an assistant — not the baseline for anyone who can send a
//! meeting request. Answering at the granted granularity keeps a calendar shareable for scheduling
//! without turning it into a public log of the person's life.
//!
//! This module discloses nothing itself. It decides what a query about a busy window may learn, from
//! the requester's granted access, as a pure function.

const std = @import("std");

/// What a requester was granted over the person's calendar.
pub const Access = enum {
    /// May learn only whether a window is free or busy.
    free_busy,
    /// May learn the event's details, granted explicitly.
    details,
};

/// What a query about a busy time window is allowed to learn.
pub const Disclosure = enum {
    /// Only that the window is busy — no detail.
    busy_only,
    /// The full event: title, attendees, location.
    full_event,
};

/// Decides what a query about a busy window may learn, given the requester's access.
///
/// A free/busy requester learns only that the window is busy; a details requester learns the event.
/// The busy-only answer is the default because it is all scheduling needs, so a calendar can be
/// consulted for availability without disclosing what fills it to anyone who was not granted that.
pub fn disclose(access: Access) Disclosure {
    return switch (access) {
        .free_busy => .busy_only,
        .details => .full_event,
    };
}

test "a free/busy requester learns only busy" {
    try std.testing.expectEqual(Disclosure.busy_only, disclose(.free_busy));
}

test "a details requester learns the full event" {
    try std.testing.expectEqual(Disclosure.full_event, disclose(.details));
}

test "full detail is disclosed only under a details grant, swept" {
    // The need-to-know property: a query learns the full event only when granted details access.
    for ([_]Access{ .free_busy, .details }) |access| {
        if (disclose(access) == .full_event) {
            try std.testing.expectEqual(Access.details, access);
        }
    }
}
