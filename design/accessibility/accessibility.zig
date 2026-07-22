//! The accessibility contract every surface satisfies.
//!
//! Accessibility is part of the surface's structure, not a pass made over a
//! finished layout. A control without an accessible name, a status conveyed
//! only by colour, or a focus order that skips the primary action is a defect
//! in the surface rather than an omission to be corrected later.
//!
//! Everything here is checkable without rendering, which is the point: a
//! property that can only be verified by looking at pixels is a property nobody
//! verifies on every change.

const std = @import("std");
const tokens = @import("../tokens/tokens.zig");

/// What a control does, so assistive technology can describe it.
pub const Role = enum {
    button,
    link,
    text_field,
    list,
    list_item,
    heading,
    status,
    dialog,
    progress,
    disclosure,

    /// Whether a control of this role can receive keyboard focus.
    pub fn isFocusable(role: Role) bool {
        return switch (role) {
            .button, .link, .text_field, .list_item, .disclosure => true,
            .list, .heading, .status, .dialog, .progress => false,
        };
    }

    /// Whether a change to this control must be announced without the user
    /// moving focus to it.
    pub fn announcesChanges(role: Role) bool {
        return switch (role) {
            .status, .progress => true,
            else => false,
        };
    }
};

pub const Error = error{
    /// A control carries no name for assistive technology to read.
    MissingAccessibleName,
    /// A name repeats its role, which assistive technology already announces.
    RedundantAccessibleName,
    /// Meaning is carried by colour alone.
    ColourOnlyMeaning,
    /// A focusable control is absent from the focus order.
    UnreachableByKeyboard,
    /// The focus order lists something twice.
    DuplicateFocusEntry,
    /// A surface offers no way back.
    NoEscapePath,
};

/// Longest accessible name. A name that runs on is not read out usefully.
pub const max_accessible_name_bytes: usize = 120;

/// One element of a surface, as assistive technology sees it.
pub const Element = struct {
    role: Role,
    /// What assistive technology reads. Never empty for a focusable control.
    accessible_name: []const u8,
    /// Longer description, when the name alone is insufficient.
    accessible_description: []const u8 = "",
    /// The status this element conveys, when it conveys one.
    status: ?tokens.ColourRole = null,
    /// Text accompanying a status, so meaning never rests on colour alone.
    status_text: []const u8 = "",
    /// Whether the element is currently disabled.
    disabled: bool = false,

    /// Checks this element against the contract.
    pub fn validate(element: Element) Error!void {
        if (element.role.isFocusable() and element.accessible_name.len == 0) {
            return error.MissingAccessibleName;
        }
        if (element.accessible_name.len > max_accessible_name_bytes) {
            return error.MissingAccessibleName;
        }
        if (namesItsOwnRole(element)) return error.RedundantAccessibleName;

        // A status shown only as a colour is invisible to anyone who cannot
        // distinguish it, and to anyone using a screen reader.
        if (element.status != null and element.status_text.len == 0) {
            return error.ColourOnlyMeaning;
        }
    }

    fn namesItsOwnRole(element: Element) bool {
        const role_word = @tagName(element.role);
        if (element.accessible_name.len < role_word.len) return false;
        const tail = element.accessible_name[element.accessible_name.len - role_word.len ..];
        return std.ascii.eqlIgnoreCase(tail, role_word);
    }
};

/// A surface as assistive technology traverses it.
pub const Surface = struct {
    /// What the surface is called.
    title: []const u8,
    elements: []const Element,
    /// Indices into `elements`, in the order focus moves through them.
    focus_order: []const usize,
    /// Whether the surface can be left without completing it.
    has_escape_path: bool = true,

    /// Checks the whole surface.
    ///
    /// Every focusable element must appear exactly once in the focus order. An
    /// element reachable only by pointer is unreachable to anyone navigating by
    /// keyboard or switch control.
    pub fn validate(surface: Surface, gpa: std.mem.Allocator) !void {
        for (surface.elements) |element| try element.validate();

        if (!surface.has_escape_path) return error.NoEscapePath;

        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen.deinit(gpa);

        for (surface.focus_order) |index| {
            if (index >= surface.elements.len) return error.UnreachableByKeyboard;
            const entry = try seen.getOrPut(gpa, index);
            if (entry.found_existing) return error.DuplicateFocusEntry;
        }

        for (surface.elements, 0..) |element, index| {
            if (!element.role.isFocusable()) continue;
            if (element.disabled) continue;
            if (!seen.contains(index)) return error.UnreachableByKeyboard;
        }
    }

    /// Elements whose changes must be announced without moving focus.
    pub fn liveRegionCount(surface: Surface) usize {
        var count: usize = 0;
        for (surface.elements) |element| {
            if (element.role.announcesChanges()) count += 1;
        }
        return count;
    }
};

/// The user's accessibility preferences, which surfaces must honour rather
/// than detect and work around.
pub const Preferences = struct {
    text_scale: tokens.TextScale = .standard,
    reduce_motion: bool = false,
    reduce_transparency: bool = false,
    increase_contrast: bool = false,
    /// Navigation is by switch or keyboard only; nothing may require a pointer.
    pointer_unavailable: bool = false,

    pub const standard: Preferences = .{};

    /// The most demanding combination a surface must still satisfy. Layout is
    /// tested here rather than at the default, because the default is the case
    /// that never breaks.
    pub const most_demanding: Preferences = .{
        .text_scale = .accessibility_largest,
        .reduce_motion = true,
        .reduce_transparency = true,
        .increase_contrast = true,
        .pointer_unavailable = true,
    };

    pub fn motionMilliseconds(preferences: Preferences, role: tokens.MotionRole) u16 {
        if (preferences.reduce_motion) return tokens.reducedMotionMilliseconds(role);
        return role.milliseconds();
    }
};

test "a focusable control without a name is a defect" {
    const unnamed: Element = .{ .role = .button, .accessible_name = "" };
    try std.testing.expectError(error.MissingAccessibleName, unnamed.validate());

    const named: Element = .{ .role = .button, .accessible_name = "Approve" };
    try named.validate();
}

test "a name that repeats its role is redundant" {
    // Assistive technology already announces the role, so this reads as
    // "Approve button button".
    const redundant: Element = .{ .role = .button, .accessible_name = "Approve button" };
    try std.testing.expectError(error.RedundantAccessibleName, redundant.validate());
}

test "a status conveyed only by colour is a defect" {
    const colour_only: Element = .{
        .role = .status,
        .accessible_name = "Outcome",
        .status = .status_denied,
    };
    try std.testing.expectError(error.ColourOnlyMeaning, colour_only.validate());

    const with_text: Element = .{
        .role = .status,
        .accessible_name = "Outcome",
        .status = .status_denied,
        .status_text = "Denied",
    };
    try with_text.validate();
}

test "every focusable element is reachable by keyboard" {
    const gpa = std.testing.allocator;

    const unreachable_surface: Surface = .{
        .title = "Approvals",
        .elements = &.{
            .{ .role = .button, .accessible_name = "Approve" },
            .{ .role = .button, .accessible_name = "Deny" },
        },
        // The second control is reachable only by pointer.
        .focus_order = &.{0},
    };
    try std.testing.expectError(
        error.UnreachableByKeyboard,
        unreachable_surface.validate(gpa),
    );

    const complete: Surface = .{
        .title = "Approvals",
        .elements = &.{
            .{ .role = .button, .accessible_name = "Approve" },
            .{ .role = .button, .accessible_name = "Deny" },
        },
        .focus_order = &.{ 0, 1 },
    };
    try complete.validate(gpa);
}

test "a disabled control need not be in the focus order" {
    const gpa = std.testing.allocator;
    const surface: Surface = .{
        .title = "Approvals",
        .elements = &.{
            .{ .role = .button, .accessible_name = "Approve" },
            .{ .role = .button, .accessible_name = "Deny", .disabled = true },
        },
        .focus_order = &.{0},
    };
    try surface.validate(gpa);
}

test "a focus order that repeats or overruns is a defect" {
    const gpa = std.testing.allocator;

    const repeated: Surface = .{
        .title = "Approvals",
        .elements = &.{.{ .role = .button, .accessible_name = "Approve" }},
        .focus_order = &.{ 0, 0 },
    };
    try std.testing.expectError(error.DuplicateFocusEntry, repeated.validate(gpa));

    const overrun: Surface = .{
        .title = "Approvals",
        .elements = &.{.{ .role = .button, .accessible_name = "Approve" }},
        .focus_order = &.{ 0, 5 },
    };
    try std.testing.expectError(error.UnreachableByKeyboard, overrun.validate(gpa));
}

test "a surface with no way out is a defect" {
    const gpa = std.testing.allocator;
    const trapped: Surface = .{
        .title = "Approvals",
        .elements = &.{.{ .role = .button, .accessible_name = "Approve" }},
        .focus_order = &.{0},
        .has_escape_path = false,
    };
    try std.testing.expectError(error.NoEscapePath, trapped.validate(gpa));
}

test "status and progress announce without the user moving focus" {
    for (std.enums.values(Role)) |role| {
        const expected = role == .status or role == .progress;
        try std.testing.expectEqual(expected, role.announcesChanges());
    }

    const surface: Surface = .{
        .title = "Task graph",
        .elements = &.{
            .{ .role = .heading, .accessible_name = "Prepare for the event" },
            .{
                .role = .status,
                .accessible_name = "Branch outcome",
                .status = .status_running,
                .status_text = "Running",
            },
            .{ .role = .progress, .accessible_name = "Branch completion" },
        },
        .focus_order = &.{},
    };
    try surface.validate(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), surface.liveRegionCount());
}

test "reduced motion removes movement for every motion role" {
    const preferences: Preferences = .{ .reduce_motion = true };
    for (std.enums.values(tokens.MotionRole)) |role| {
        try std.testing.expectEqual(@as(u16, 0), preferences.motionMilliseconds(role));
        try std.testing.expect(Preferences.standard.motionMilliseconds(role) > 0);
    }
}

test "the most demanding preferences are genuinely the extremes" {
    const demanding = Preferences.most_demanding;
    try std.testing.expectEqual(tokens.TextScale.accessibility_largest, demanding.text_scale);
    try std.testing.expect(demanding.reduce_motion);
    try std.testing.expect(demanding.reduce_transparency);
    try std.testing.expect(demanding.increase_contrast);
    try std.testing.expect(demanding.pointer_unavailable);
}

test "no control is reachable only by pointer when a pointer is unavailable" {
    const gpa = std.testing.allocator;
    // With a pointer unavailable, focus order is the only way in, so the same
    // check that guarantees keyboard reachability guarantees usability here.
    const surface: Surface = .{
        .title = "Command",
        .elements = &.{
            .{ .role = .text_field, .accessible_name = "Command entry" },
            .{ .role = .button, .accessible_name = "Run" },
        },
        .focus_order = &.{ 0, 1 },
    };
    try surface.validate(gpa);
    try std.testing.expect(Preferences.most_demanding.pointer_unavailable);
}
