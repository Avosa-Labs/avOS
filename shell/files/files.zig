//! Deciding how a directory listing is ordered and which entries are shown, so browsing files
//! is predictable and hidden entries stay out of the way until the person asks for them.
//!
//! A file listing is something a person scans for a name they already have in mind, so its order
//! has to be the one a person expects rather than whatever order the filesystem returns. Folders
//! come before files, so the structure of a place reads first and the leaves after; within each
//! group names sort case-insensitively, because a person thinks of "Notes" and "notes" as the
//! same word and would lose one that sorted by byte value. Hidden entries — dotfiles and the
//! machinery a person did not create — stay out of the listing until they opt in, keeping the
//! everyday view uncluttered without ever pretending the files are gone.
//!
//! This module lists nothing. It decides which entries are shown and how they are ordered, as a
//! pure function over each entry's kind, hidden flag, and name.

const std = @import("std");

/// One entry in a directory listing.
pub const Entry = struct {
    /// Whether the entry is a directory, which sorts it ahead of plain files.
    is_directory: bool,
    /// Whether the entry is hidden (a dotfile or system entry) and shown only on request.
    hidden: bool,
    /// The entry's name, compared case-insensitively so it sorts the way a person reads it.
    name: []const u8,
};

/// Whether an entry is shown given whether the person opted to see hidden entries.
///
/// Hidden entries appear only when the person has asked to see them; everything else always
/// shows. The default hides the machinery so the everyday listing stays about the person's own
/// files, without ever deleting or concealing anything permanently.
pub fn shown(entry: Entry, show_hidden: bool) bool {
    if (entry.hidden) return show_hidden;
    return true;
}

/// Whether `a` should sort before `b` in the listing.
///
/// Directories come before files so a place's structure reads first. Within the same kind,
/// names sort case-insensitively, matching how a person reads a name rather than its bytes.
pub fn before(a: Entry, b: Entry) bool {
    if (a.is_directory != b.is_directory) return a.is_directory;
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}

test "hidden entries show only when the person opts in" {
    const dotfile = Entry{ .is_directory = false, .hidden = true, .name = ".config" };
    try std.testing.expect(!shown(dotfile, false));
    try std.testing.expect(shown(dotfile, true));
}

test "ordinary entries always show" {
    const note = Entry{ .is_directory = false, .hidden = false, .name = "note.txt" };
    try std.testing.expect(shown(note, false));
}

test "directories sort first then names sort case-insensitively" {
    const dir = Entry{ .is_directory = true, .hidden = false, .name = "zebra" };
    const file = Entry{ .is_directory = false, .hidden = false, .name = "apple" };
    try std.testing.expect(before(dir, file));
    const lower = Entry{ .is_directory = false, .hidden = false, .name = "apple" };
    const upper = Entry{ .is_directory = false, .hidden = false, .name = "Banana" };
    try std.testing.expect(before(lower, upper));
}

test "a directory never sorts after a file, swept" {
    // The structure-first property: any directory precedes any file regardless of names.
    const names = [_][]const u8{ "a", "Z", "middle", "AAA" };
    for (names) |dn| for (names) |fn_| {
        const dir = Entry{ .is_directory = true, .hidden = false, .name = dn };
        const file = Entry{ .is_directory = false, .hidden = false, .name = fn_ };
        try std.testing.expect(before(dir, file));
        try std.testing.expect(!before(file, dir));
    };
}
