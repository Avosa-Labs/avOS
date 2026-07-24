//! Deciding which media session owns the now-playing controls, so the lock screen and headset
//! buttons control the thing the person is actually listening to.
//!
//! Several apps can play media, but there is one set of now-playing controls — on the lock
//! screen, in the control centre, on the headset's play button — and they must control the right
//! one. The rule is that the session currently producing sound owns the controls: if music is
//! playing and a podcast is paused, the play button belongs to the music, because that is what
//! the person hears and would expect to control. When more than one could claim it, the most
//! recently active playing session wins, because that is the one the person last chose to hear.
//! A paused session does not hold the controls against a playing one, so pressing play does not
//! resume something silent while music keeps going. Getting this ownership right is what makes
//! the physical and lock-screen controls feel like they are wired to whatever is actually
//! playing, rather than to whichever app happened to open last.
//!
//! This module plays no media. It decides which of the candidate sessions owns the now-playing
//! controls, as a pure function.

const std = @import("std");

/// A media session that could own the now-playing controls.
pub const Session = struct {
    id: u32,
    /// Whether the session is currently producing audio.
    playing: bool,
    /// When the session last became active, in milliseconds. Higher is more recent.
    last_active_ms: i64,
};

/// Chooses which session owns the now-playing controls, or none.
///
/// A playing session always outranks a paused one, so the controls follow what is actually
/// making sound. Among playing sessions, the most recently active wins, because it is the one
/// the person last chose to hear. If no session is playing, the most recently active paused
/// session holds the controls so a play press resumes something sensible; with no sessions at
/// all, no one owns them.
pub fn owner(sessions: []const Session) ?u32 {
    var best: ?Session = null;
    for (sessions) |session| {
        if (best) |current| {
            if (beats(session, current)) best = session;
        } else {
            best = session;
        }
    }
    return if (best) |b| b.id else null;
}

/// Whether session a should own the controls over session b: a playing session beats a paused
/// one, and among equal playing state the more recently active wins.
fn beats(a: Session, b: Session) bool {
    if (a.playing != b.playing) return a.playing;
    return a.last_active_ms > b.last_active_ms;
}

fn makeSession(id: u32, playing: bool, last_active: i64) Session {
    return .{ .id = id, .playing = playing, .last_active_ms = last_active };
}

test "a playing session owns the controls over a paused one" {
    const sessions = [_]Session{
        makeSession(1, false, 200), // paused, more recent
        makeSession(2, true, 100), // playing, older
    };
    try std.testing.expectEqual(@as(?u32, 2), owner(&sessions));
}

test "among playing sessions the most recent wins" {
    const sessions = [_]Session{
        makeSession(1, true, 100),
        makeSession(2, true, 300),
        makeSession(3, true, 200),
    };
    try std.testing.expectEqual(@as(?u32, 2), owner(&sessions));
}

test "with nothing playing the most recent paused session holds the controls" {
    const sessions = [_]Session{
        makeSession(1, false, 100),
        makeSession(2, false, 300),
    };
    try std.testing.expectEqual(@as(?u32, 2), owner(&sessions));
}

test "no sessions means no owner" {
    try std.testing.expectEqual(@as(?u32, null), owner(&.{}));
}

test "a single session owns the controls" {
    const sessions = [_]Session{makeSession(7, false, 50)};
    try std.testing.expectEqual(@as(?u32, 7), owner(&sessions));
}

test "a playing session always owns over any paused one, swept" {
    // The follows-the-sound property: if any session is playing, the owner is a playing session.
    const sessions = [_]Session{
        makeSession(1, false, 500), // paused, most recent
        makeSession(2, true, 100), // playing, oldest
        makeSession(3, false, 400),
    };
    const id = owner(&sessions).?;
    // The owner must be the playing one.
    try std.testing.expectEqual(@as(u32, 2), id);
}
