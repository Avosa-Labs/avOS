//! The shell's cross-surface safety properties, exercised together: a locked device
//! stays both useful and safe, and the agent activity a person relies on stays
//! visible and correctly ordered.
//!
//! Each surface enforces its own rule; this checks that the rules compose into the two
//! promises the shell makes as a whole. First, the lock is a real boundary that no
//! surface quietly opens: while locked, a live capture is always indicated, only
//! life-safety emergency actions are reachable, search never surfaces private or
//! secret results, and a quick control that would reveal or act stays behind the lock —
//! all at once, so a person cannot reach private data through any of them. Second, the
//! thing the platform exists to show — agents working — is never buried: an item
//! awaiting a person outranks routine activity however recent the routine item is.

const std = @import("std");
const privacy = @import("../privacy/privacy.zig");
const emergency = @import("../emergency/emergency.zig");
const search = @import("../search/search.zig");
const quick_controls = @import("../quick-controls/quick_controls.zig");
const activity = @import("../activity/activity.zig");

const testing = std.testing;

test "a locked device reveals no private data through any surface" {
    // A live capture is indicated whatever the lock state — the one thing that can
    // never be hidden.
    try testing.expect(privacy.indicatorRequired(.camera));
    try testing.expect(privacy.indicatorRequired(.microphone));
    // The detailed access history is not readable from the lock screen.
    try testing.expect(!privacy.historyVisibleWhileLocked());

    // Search returns nothing private or secret while locked.
    try testing.expect(!search.visible(.personal_data, true));
    try testing.expect(!search.visible(.secret, true));
    // Public app entries still show, so search stays useful.
    try testing.expect(search.visible(.public_app, true));

    // A quick control that reveals or acts stays behind the lock; a harmless one works.
    try testing.expect(!quick_controls.usable(.reveals_private, true));
    try testing.expect(!quick_controls.usable(.consequential, true));
    try testing.expect(quick_controls.usable(.harmless_toggle, true));
}

test "a locked device still reaches life-safety actions" {
    // The lock never stands between a person and an emergency.
    try testing.expect(emergency.availableWhileLocked(.emergency_call));
    try testing.expect(emergency.availableWhileLocked(.trigger_sos));
    try testing.expect(emergency.availableWhileLocked(.show_medical_id));
    // But it does not become a way to browse unrelated private data.
    try testing.expect(!emergency.availableWhileLocked(.view_messages));
}

test "agent work awaiting a person is never buried under routine activity" {
    // An old item that needs the person outranks a brand-new routine one, so the thing
    // the person must act on rises to the top rather than scrolling away.
    const awaiting_earlier: activity.Item = .{ .kind = .approval_needed, .awaiting_human = true, .at_sequence = 1 };
    const routine_recent: activity.Item = .{ .kind = .message, .awaiting_human = false, .at_sequence = 100 };
    try testing.expect(activity.moreUrgent(awaiting_earlier, routine_recent));
    try testing.expect(!activity.moreUrgent(routine_recent, awaiting_earlier));
    // Anything awaiting a person is always surfaced, never collapsed away.
    try testing.expect(activity.surfaced(awaiting_earlier));
}
