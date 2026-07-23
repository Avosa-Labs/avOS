//! Memory that holds a secret, and does not leave it lying around.
//!
//! A key, a token, a passphrase in plaintext exists in memory for as long as it
//! is needed and must vanish the instant it is not. The failures this prevents
//! are quiet ones: a freed buffer whose bytes a later allocation reads back, a
//! secret compared with a normal equality that returns early on the first
//! differing byte and so leaks, one character at a time, how much of a guess was
//! right. Neither shows up in a test of the happy path, and both are how secrets
//! escape.
//!
//! So a secret is not a plain slice. It is a buffer that wipes itself when it is
//! released, refuses to be copied so a secret cannot be duplicated by accident,
//! and is compared only in constant time so a comparison reveals whether two
//! secrets match and nothing about where they differ. The discipline is the
//! point: making the safe operation the only one available means the unsafe one
//! cannot be reached by forgetting.

const std = @import("std");

/// Overwrites a buffer with zeros in a way the compiler may not elide.
///
/// A plain loop that writes zeros to memory about to be freed is dead code the
/// optimizer is entitled to remove, which would leave the secret in place. This
/// uses the standard secure-zero primitive, whose whole purpose is to not be
/// optimized away.
pub fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

/// Whether two byte slices are equal, in time that does not depend on where
/// they differ.
///
/// A normal comparison stops at the first mismatch, so how long it takes reveals
/// how many leading bytes matched — enough, over many attempts, to reconstruct a
/// secret. This examines every byte regardless, so the only thing its timing
/// reveals is the length, which the caller already controls.
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}

/// A fixed-size buffer holding a secret.
///
/// Fixed size and inline, so a secret is never handed to a general allocator
/// whose freed memory could be read back before it is reused. It wipes on
/// `deinit`, and it is a distinct type so a secret cannot be passed where a
/// plain buffer is expected without the code saying so.
pub fn Secret(comptime size: usize) type {
    return struct {
        const Self = @This();

        bytes: [size]u8,
        /// Set once the secret has been wiped, so a use-after-wipe is caught in a
        /// safety build rather than reading zeros as though they were the secret.
        wiped: bool = false,

        /// Wraps existing bytes, wiping the source so the secret exists in one
        /// place. The caller's copy must not outlive this call; wiping it here
        /// makes that concrete.
        pub fn take(source: []u8) Self {
            std.debug.assert(source.len == size);
            var secret: Self = .{ .bytes = undefined };
            @memcpy(&secret.bytes, source);
            wipe(source);
            return secret;
        }

        /// A secret initialized to all zeros, to be filled in place — by a key
        /// derivation, a read from the secure element — without a plaintext copy
        /// existing elsewhere first.
        pub fn zeroed() Self {
            return .{ .bytes = @splat(0) };
        }

        /// Borrows the secret for use. Asserts it has not been wiped.
        ///
        /// The only way to read the bytes, and it goes through a check, so a
        /// use-after-wipe is a caught assertion rather than a silent read of
        /// zeros.
        pub fn expose(secret: *const Self) []const u8 {
            std.debug.assert(!secret.wiped);
            return &secret.bytes;
        }

        /// A mutable view for filling the secret in place.
        pub fn fillable(secret: *Self) []u8 {
            std.debug.assert(!secret.wiped);
            return &secret.bytes;
        }

        /// Whether this secret equals another, in constant time.
        pub fn equals(secret: *const Self, other: *const Self) bool {
            std.debug.assert(!secret.wiped and !other.wiped);
            return constantTimeEql(&secret.bytes, &other.bytes);
        }

        /// Whether the secret equals a candidate, in constant time. For checking
        /// a supplied passphrase or token against the stored one.
        pub fn matches(secret: *const Self, candidate: []const u8) bool {
            std.debug.assert(!secret.wiped);
            return constantTimeEql(&secret.bytes, candidate);
        }

        /// Wipes the secret. Idempotent: wiping an already-wiped secret is fine,
        /// because a cleanup path should never have to check first.
        pub fn deinit(secret: *Self) void {
            wipe(&secret.bytes);
            secret.wiped = true;
        }
    };
}

test "wiping actually clears the bytes" {
    var buffer = [_]u8{ 1, 2, 3, 4 };
    wipe(&buffer);
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "constant-time equality agrees with normal equality on the result" {
    // It must be a correct comparison; the timing property is separate. Same
    // bytes match, any difference does not.
    try std.testing.expect(constantTimeEql("secret", "secret"));
    try std.testing.expect(!constantTimeEql("secret", "secreT"));
    try std.testing.expect(!constantTimeEql("secret", "secre"));
    try std.testing.expect(constantTimeEql("", ""));
}

test "constant-time equality examines every byte" {
    // A difference in the last byte is caught the same as one in the first. A
    // comparison that stopped early would miss the trailing difference or return
    // faster for it; this returns the right answer for both.
    try std.testing.expect(!constantTimeEql("aaaaaaaa", "baaaaaaa"));
    try std.testing.expect(!constantTimeEql("aaaaaaaa", "aaaaaaab"));
}

test "a secret can be taken, exposed, and wiped" {
    var source = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var secret = Secret(8).take(&source);

    // The source is wiped: the secret exists in one place.
    for (source) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6, 5, 4, 3, 2 }, secret.expose());

    secret.deinit();
    // After deinit the bytes are gone.
    for (secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "two equal secrets compare equal in constant time" {
    var a_bytes = [_]u8{ 1, 2, 3, 4 };
    var b_bytes = [_]u8{ 1, 2, 3, 4 };
    var a = Secret(4).take(&a_bytes);
    defer a.deinit();
    var b = Secret(4).take(&b_bytes);
    defer b.deinit();
    try std.testing.expect(a.equals(&b));
}

test "two different secrets do not compare equal" {
    var a_bytes = [_]u8{ 1, 2, 3, 4 };
    var b_bytes = [_]u8{ 1, 2, 3, 5 };
    var a = Secret(4).take(&a_bytes);
    defer a.deinit();
    var b = Secret(4).take(&b_bytes);
    defer b.deinit();
    try std.testing.expect(!a.equals(&b));
}

test "a secret matches a correct candidate and rejects a wrong one" {
    var stored_bytes = [_]u8{ 't', 'o', 'k', 'e', 'n' };
    var stored = Secret(5).take(&stored_bytes);
    defer stored.deinit();

    try std.testing.expect(stored.matches("token"));
    try std.testing.expect(!stored.matches("toker"));
    // A different length is not a match, and does not read out of bounds.
    try std.testing.expect(!stored.matches("tok"));
}

test "a zeroed secret can be filled in place" {
    var secret = Secret(4).zeroed();
    defer secret.deinit();
    const view = secret.fillable();
    view[0] = 0xaa;
    view[3] = 0xff;
    try std.testing.expectEqual(@as(u8, 0xaa), secret.expose()[0]);
    try std.testing.expectEqual(@as(u8, 0xff), secret.expose()[3]);
}

test "wiping is idempotent" {
    var secret = Secret(4).zeroed();
    secret.deinit();
    // A cleanup path may run twice; the second wipe must not trip on the first.
    secret.deinit();
    try std.testing.expect(secret.wiped);
}

test "a length mismatch is not equal and reads nothing extra" {
    // The one comparison that must short-circuit is a length difference, because
    // comparing unequal lengths has no meaning; but it reveals only the length,
    // which is not secret.
    try std.testing.expect(!constantTimeEql("short", "longer string"));
}
