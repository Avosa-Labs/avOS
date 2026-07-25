//! Deciding how media items are grouped and ordered, so the library reads as a person remembers
//! their moments — by kind, newest first, with the ones they marked worth keeping on top.
//!
//! A media library is memory made browsable, and it only feels like memory if its order matches
//! how a person reaches for it. Kinds stay together, because someone looking for a photo is not
//! looking for a screen recording and should not have to sift the two apart. Within a kind the
//! newest comes first, since the moment just captured is the one most likely being sought.
//! Favourites float to the top of their kind, because a person marks a favourite precisely to
//! find it again without scrolling, and that promise would be empty if a later ordinary capture
//! buried it.
//!
//! This module orders nothing. It decides how media items are grouped and ranked, as a pure
//! function over each item's kind, capture time, and favourite mark.

const std = @import("std");

/// One item in the media library.
pub const Media = struct {
    /// What sort of capture it is; items of one kind group together, in enum order.
    kind: enum { photo, video, screenshot },
    /// When it was captured; a higher value is more recent.
    captured_at: u64,
    /// Whether the person marked it a favourite, which floats it to the top of its kind.
    favourite: bool,
};

/// Whether `a` should appear before `b` in the library.
///
/// Kind groups first so like sits with like. Within a kind, favourites lead — a marked item
/// must be easy to return to — and then the newest capture comes first, because the most recent
/// moment is the one most often sought.
pub fn moreProminent(a: Media, b: Media) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.favourite != b.favourite) return a.favourite;
    return a.captured_at > b.captured_at;
}

test "kinds group together in order" {
    const photo = Media{ .kind = .photo, .captured_at = 1, .favourite = false };
    const video = Media{ .kind = .video, .captured_at = 100, .favourite = true };
    try std.testing.expect(moreProminent(photo, video));
}

test "favourites lead their kind then newest comes first" {
    const fav = Media{ .kind = .photo, .captured_at = 1, .favourite = true };
    const plain = Media{ .kind = .photo, .captured_at = 100, .favourite = false };
    try std.testing.expect(moreProminent(fav, plain));
    const older = Media{ .kind = .photo, .captured_at = 2, .favourite = false };
    const newer = Media{ .kind = .photo, .captured_at = 8, .favourite = false };
    try std.testing.expect(moreProminent(newer, older));
}

test "within one kind a favourite never sorts below a non-favourite, swept" {
    // The favourite-promise property: inside a kind, a marked item always precedes an unmarked
    // one, whatever their capture times.
    const times = [_]u64{ 0, 3, 50, 900 };
    for (times) |ta| for (times) |tb| {
        const fav = Media{ .kind = .video, .captured_at = ta, .favourite = true };
        const plain = Media{ .kind = .video, .captured_at = tb, .favourite = false };
        try std.testing.expect(moreProminent(fav, plain));
        try std.testing.expect(!moreProminent(plain, fav));
    };
}
