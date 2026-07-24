//! Deciding whether a voicemail is kept or may be auto-deleted, so old messages clear
//! themselves while anything the person saved stays until they say otherwise.
//!
//! Voicemail accumulates, and a mailbox that never clears fills up until it can take no new
//! messages — the reason people miss calls they did not know they missed. Automatic deletion
//! keeps it clear, but it must never delete something the person wanted. Two facts protect a
//! message. A message the person explicitly saved is kept indefinitely; saving is the signal
//! "do not delete this", and auto-deletion must honour it whatever its age. And an unheard
//! message is never auto-deleted, because deleting a message the person has not even listened
//! to is deleting information they never received. Only a message that is both heard and not
//! saved, and older than the retention window, is eligible to be cleared. So auto-deletion is
//! deliberately timid: it removes only what has been heard, left unsaved, and grown old, and
//! leaves everything else, which is what lets the mailbox stay clear without ever losing a
//! message that mattered.
//!
//! This module deletes nothing. It decides whether a voicemail may be auto-deleted, from its
//! age, whether it was heard, and whether it was saved, as a pure function.

const std = @import("std");

/// How old, in milliseconds, a heard and unsaved voicemail must be before it may be
/// auto-deleted.
pub const retention_ms: i64 = 30 * 24 * 60 * 60 * 1000; // 30 days

/// A voicemail's retention-relevant state.
pub const Voicemail = struct {
    /// Age in milliseconds since the message arrived.
    age_ms: i64,
    /// Whether the person has listened to it.
    heard: bool,
    /// Whether the person explicitly saved it.
    saved: bool,
};

/// Whether a voicemail may be auto-deleted.
///
/// A saved message is never auto-deleted — saving means keep. An unheard message is never
/// auto-deleted — the person has not received its information yet. Only a message that has been
/// heard, was not saved, and is older than the retention window is eligible. The default is to
/// keep: anything that fails a single condition stays.
pub fn mayAutoDelete(voicemail: Voicemail) bool {
    if (voicemail.saved) return false;
    if (!voicemail.heard) return false;
    return voicemail.age_ms > retention_ms;
}

fn vm(age: i64, heard: bool, saved: bool) Voicemail {
    return .{ .age_ms = age, .heard = heard, .saved = saved };
}

test "an old, heard, unsaved message may be auto-deleted" {
    try std.testing.expect(mayAutoDelete(vm(retention_ms + 1, true, false)));
}

test "a saved message is never auto-deleted, however old" {
    try std.testing.expect(!mayAutoDelete(vm(retention_ms * 10, true, true)));
}

test "an unheard message is never auto-deleted, however old" {
    try std.testing.expect(!mayAutoDelete(vm(retention_ms * 10, false, false)));
}

test "a recent message is kept" {
    try std.testing.expect(!mayAutoDelete(vm(1000, true, false)));
}

test "the retention boundary keeps a message exactly at the window" {
    try std.testing.expect(!mayAutoDelete(vm(retention_ms, true, false)));
    try std.testing.expect(mayAutoDelete(vm(retention_ms + 1, true, false)));
}

test "nothing saved or unheard is ever auto-deleted, swept" {
    // The no-lost-message property: whenever auto-delete is allowed, the message was heard,
    // unsaved, and past the window.
    for ([_]bool{ false, true }) |heard| {
        for ([_]bool{ false, true }) |saved| {
            for ([_]i64{ 1000, retention_ms, retention_ms * 2 }) |age| {
                if (mayAutoDelete(vm(age, heard, saved))) {
                    try std.testing.expect(heard and !saved and age > retention_ms);
                }
            }
        }
    }
}
