//! Deciding whether two phone numbers are the same contact, so a call from a saved number
//! shows the person's name however the number happens to be formatted.
//!
//! A phone number is written a dozen ways — with a country code or without, with spaces,
//! dashes, parentheses, a leading plus — and they all reach the same phone. Matching an
//! incoming number to a saved contact means seeing through that formatting, because a call
//! that shows a stranger's raw digits instead of "Mum" because the saved copy had dashes and
//! the incoming one did not is a match that failed at its one job. So numbers are normalized
//! to bare digits first, and then compared. The comparison is careful about country codes: a
//! number saved in international form and one dialed locally are the same phone, so matching
//! compares the significant trailing digits — the part that identifies the line — rather than
//! demanding the country prefix be present on both. It errs toward the identity being stable:
//! two numbers match when their significant digits are equal, so a saved contact is recognized
//! whether the call came in local or international form.
//!
//! This module stores no contacts. It normalizes a number and decides whether two numbers are
//! the same contact, as pure functions.

const std = @import("std");

/// How many trailing digits identify a phone line for matching purposes. Comparing the
/// significant tail lets a locally-dialed number match a saved international one.
pub const significant_digits: usize = 7;

/// Normalizes a phone number into bare digits, stripping formatting, into `buffer`. Returns
/// the digit slice.
pub fn normalize(number: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (number) |ch| {
        if (ch >= '0' and ch <= '9') {
            if (len < buffer.len) {
                buffer[len] = ch;
                len += 1;
            }
        }
    }
    return buffer[0..len];
}

/// The significant trailing digits of a normalized number: the last `significant_digits`, or
/// the whole number if it is shorter.
fn significantTail(digits: []const u8) []const u8 {
    if (digits.len <= significant_digits) return digits;
    return digits[digits.len - significant_digits ..];
}

/// Whether two phone numbers identify the same contact.
///
/// Both are normalized to bare digits, then their significant trailing digits are compared, so
/// a number in international form matches the same line dialed locally. Two numbers match when
/// their significant tails are equal and non-empty; an empty number matches nothing, so a
/// blank caller ID is never folded into a saved contact.
pub fn sameContact(a: []const u8, b: []const u8) bool {
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const da = normalize(a, &buf_a);
    const db = normalize(b, &buf_b);
    if (da.len == 0 or db.len == 0) return false;
    return std.mem.eql(u8, significantTail(da), significantTail(db));
}

test "the same number in different formats matches" {
    try std.testing.expect(sameContact("555-123-4567", "5551234567"));
    try std.testing.expect(sameContact("(555) 123 4567", "555.123.4567"));
}

test "a local and an international form of the same line match" {
    // +1 555 123 4567 (international) matches 123-4567 dialed locally on the significant tail.
    try std.testing.expect(sameContact("+1 555 123 4567", "123-4567"));
}

test "different numbers do not match" {
    try std.testing.expect(!sameContact("5551234567", "5559999999"));
}

test "an empty number matches nothing" {
    try std.testing.expect(!sameContact("", "5551234567"));
    try std.testing.expect(!sameContact("5551234567", ""));
}

test "normalization strips all formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("15551234567", normalize("+1 (555) 123-4567", &buf));
}

test "matching is symmetric, swept" {
    const numbers = [_][]const u8{ "5551234567", "+1-555-123-4567", "123-4567", "5559999999", "" };
    for (numbers) |a| {
        for (numbers) |b| {
            try std.testing.expectEqual(sameContact(a, b), sameContact(b, a));
        }
    }
}
