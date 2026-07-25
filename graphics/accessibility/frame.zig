//! Validating a built frame against the accessibility contract, at the point the
//! frame is produced, so the guarantees the contract makes are checked on what is
//! actually rendered rather than only on hand-written unit cases.
//!
//! The design layer defines the accessibility contract — a focusable control has a
//! name, focus reaches every control, no meaning rests on colour alone — and proves it
//! holds for elements written by hand in tests. That is necessary but not sufficient:
//! the elements a person actually navigates are the ones a real frame produces, and a
//! frame that quietly drops a name or omits a control from the focus order would pass
//! every isolated test and still fail a real user. This pass closes that gap. It takes
//! the accessible view of a rendered frame — its title, its elements, the order focus
//! moves through them — and runs it through the same contract, so a frame that would
//! ship an unreachable or unnamed control is a caught error at render time, the way a
//! security property is only real once something checks it.
//!
//! This module renders nothing and defines no new rule. It runs the design
//! accessibility contract over a produced frame, as a validation pass.

const std = @import("std");
const design = @import("design");

const accessibility = design.accessibility;
pub const Element = accessibility.Element;
pub const Role = accessibility.Role;

/// The accessible view of a rendered frame: what a screen reader or switch control
/// traverses. Produced alongside the pixels, from the same source, so the two cannot
/// disagree.
pub const Frame = struct {
    title: []const u8,
    elements: []const Element,
    /// Indices into `elements`, in the order focus moves through them.
    focus_order: []const usize,
    has_escape_path: bool = true,

    fn surface(frame: Frame) accessibility.Surface {
        return .{
            .title = frame.title,
            .elements = frame.elements,
            .focus_order = frame.focus_order,
            .has_escape_path = frame.has_escape_path,
        };
    }

    /// Validates the frame against the accessibility contract: every focusable element
    /// named, reachable in the focus order exactly once, and no meaning carried by
    /// colour without accompanying text. A frame that fails is one that would ship an
    /// interface someone could not use.
    pub fn validate(frame: Frame, gpa: std.mem.Allocator) !void {
        try frame.surface().validate(gpa);
    }

    /// The number of live regions in the frame — surfaces that announce their own
    /// changes — for a caller confirming that agent activity a person must hear about
    /// is actually announced.
    pub fn liveRegionCount(frame: Frame) usize {
        return frame.surface().liveRegionCount();
    }
};

// --- Tests ---

const testing = std.testing;

test "a well-formed frame passes the accessibility contract at render time" {
    const elements = [_]Element{
        .{ .role = .heading, .accessible_name = "Today" },
        .{ .role = .button, .accessible_name = "New task" },
        .{ .role = .button, .accessible_name = "Settings" },
    };
    const frame: Frame = .{
        .title = "Home",
        .elements = &elements,
        .focus_order = &.{ 1, 2 }, // the two focusable buttons, each once
    };
    try frame.validate(testing.allocator);
}

test "a frame with an unnamed focusable control fails validation" {
    const elements = [_]Element{
        .{ .role = .button, .accessible_name = "" }, // a control with no name
    };
    const frame: Frame = .{ .title = "Home", .elements = &elements, .focus_order = &.{0} };
    try testing.expectError(error.MissingAccessibleName, frame.validate(testing.allocator));
}

test "a frame whose status rests on colour alone fails validation" {
    const elements = [_]Element{
        // A status conveyed by colour with no accompanying text.
        .{ .role = .status, .accessible_name = "Task", .status = .status_denied, .status_text = "" },
    };
    const frame: Frame = .{ .title = "Activity", .elements = &elements, .focus_order = &.{} };
    try testing.expectError(error.ColourOnlyMeaning, frame.validate(testing.allocator));
}

test "a frame that omits a focusable control from the focus order fails validation" {
    const elements = [_]Element{
        .{ .role = .button, .accessible_name = "Reachable" },
        .{ .role = .button, .accessible_name = "Stranded" }, // focusable but not in the order
    };
    const frame: Frame = .{ .title = "Home", .elements = &elements, .focus_order = &.{0} };
    try testing.expectError(error.UnreachableByKeyboard, frame.validate(testing.allocator));
}
