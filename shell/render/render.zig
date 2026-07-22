//! The boundary a renderer implements.
//!
//! Surfaces produce a presentation: what to show, in what order, with which
//! semantic roles. A renderer turns that into pixels. Nothing above this line
//! knows which toolkit is in use, and the renderer holds no state of its own —
//! it is handed everything it needs for a frame and keeps nothing between them.
//!
//! Keeping the renderer stateless is what stops it becoming a second place
//! where the system's state lives. A renderer that cached a task's status would
//! eventually show a status the control plane no longer holds.

const std = @import("std");
const core = @import("core");
const design = @import("design");

const tokens = design.tokens;
const accessibility = design.accessibility;

pub const Error = error{
    /// The presentation is malformed and must not be rendered.
    InvalidPresentation,
    /// The renderer cannot express something the presentation requires.
    Unsupported,
};

/// What a renderer is handed for one frame.
///
/// Ownership: borrowed for the duration of the call. A renderer that needs
/// anything beyond the frame must copy it, which makes the retention explicit.
pub const Frame = struct {
    surface: accessibility.Surface,
    appearance: tokens.Appearance,
    preferences: accessibility.Preferences,
    /// Logical size in points, before the text scale is applied.
    width_points: f32,
    height_points: f32,

    /// Checks a frame before anything draws it.
    ///
    /// A renderer must refuse a malformed presentation rather than drawing its
    /// best guess: a surface with an element missing from the focus order would
    /// render as something a keyboard user cannot reach, and drawing it would
    /// hide the defect behind a picture that looks right.
    pub fn validate(frame: Frame, gpa: std.mem.Allocator) !void {
        if (frame.width_points <= 0 or frame.height_points <= 0) {
            return error.InvalidPresentation;
        }
        frame.surface.validate(gpa) catch return error.InvalidPresentation;
    }

    /// Resolved point size for a text role under this frame's preferences.
    pub fn textPoints(frame: Frame, role: tokens.TextRole) f32 {
        return tokens.textPoints(role, frame.preferences.text_scale);
    }

    /// Resolved colour for a role under this frame's appearance.
    pub fn colour(frame: Frame, role: tokens.ColourRole) tokens.Colour {
        return tokens.colour(role, frame.appearance);
    }

    /// Motion duration under this frame's preferences.
    pub fn motionMilliseconds(frame: Frame, role: tokens.MotionRole) u16 {
        return frame.preferences.motionMilliseconds(role);
    }
};

/// What a renderer must provide.
///
/// Deliberately small. Everything a toolkit differs on — layout engine, widget
/// set, event loop — sits behind these three operations, so replacing a
/// renderer changes one implementation and nothing above it.
pub const Renderer = struct {
    context: *anyopaque,
    presentFn: *const fn (context: *anyopaque, frame: Frame) Error!void,
    /// Reports the accessibility tree to the platform. Separate from
    /// presenting, because a renderer may present without the tree changing
    /// and must not be tempted to skip publishing it when it does.
    publishAccessibilityFn: *const fn (
        context: *anyopaque,
        surface: accessibility.Surface,
    ) Error!void,
    /// Whether the renderer can express everything the frame requires.
    supportsFn: *const fn (context: *anyopaque, frame: Frame) bool,

    pub fn present(renderer: Renderer, frame: Frame, gpa: std.mem.Allocator) Error!void {
        frame.validate(gpa) catch return error.InvalidPresentation;
        if (!renderer.supportsFn(renderer.context, frame)) return error.Unsupported;
        try renderer.publishAccessibilityFn(renderer.context, frame.surface);
        try renderer.presentFn(renderer.context, frame);
    }
};

/// A renderer that draws nothing and records what it was asked to draw.
///
/// This is how the boundary is exercised before a toolkit is selected: the
/// contract can be held to its guarantees without any of them depending on a
/// particular toolkit being present.
pub const RecordingRenderer = struct {
    frames_presented: usize = 0,
    accessibility_publications: usize = 0,
    last_appearance: ?tokens.Appearance = null,
    last_text_scale: ?tokens.TextScale = null,
    /// Set when the renderer is told it cannot express a frame.
    refuse_unsupported: bool = false,

    pub fn renderer(recording: *RecordingRenderer) Renderer {
        return .{
            .context = recording,
            .presentFn = present,
            .publishAccessibilityFn = publishAccessibility,
            .supportsFn = supports,
        };
    }

    fn present(context: *anyopaque, frame: Frame) Error!void {
        const recording: *RecordingRenderer = @ptrCast(@alignCast(context));
        recording.frames_presented += 1;
        recording.last_appearance = frame.appearance;
        recording.last_text_scale = frame.preferences.text_scale;
    }

    fn publishAccessibility(context: *anyopaque, surface: accessibility.Surface) Error!void {
        const recording: *RecordingRenderer = @ptrCast(@alignCast(context));
        _ = surface;
        recording.accessibility_publications += 1;
    }

    fn supports(context: *anyopaque, frame: Frame) bool {
        const recording: *RecordingRenderer = @ptrCast(@alignCast(context));
        _ = frame;
        return !recording.refuse_unsupported;
    }
};

fn sampleSurface() accessibility.Surface {
    return .{
        .title = "Approvals",
        .elements = &.{
            .{ .role = .heading, .accessible_name = "Waiting for approval" },
            .{
                .role = .list_item,
                .accessible_name = "send a confirmation to the venue",
                .status = .status_awaiting_approval,
                .status_text = "Waiting for your approval",
            },
        },
        .focus_order = &.{1},
    };
}

fn sampleFrame(preferences: accessibility.Preferences, appearance: tokens.Appearance) Frame {
    return .{
        .surface = sampleSurface(),
        .appearance = appearance,
        .preferences = preferences,
        .width_points = 390,
        .height_points = 844,
    };
}

test "a valid frame is presented and its accessibility tree published" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{};

    try recording.renderer().present(sampleFrame(.standard, .light), gpa);

    try std.testing.expectEqual(@as(usize, 1), recording.frames_presented);
    // The tree is published on every frame, not only when it changes: a
    // renderer that skipped it would leave assistive technology describing a
    // surface that is no longer on screen.
    try std.testing.expectEqual(@as(usize, 1), recording.accessibility_publications);
}

test "a malformed presentation is refused rather than drawn" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{};

    var frame = sampleFrame(.standard, .light);
    // A focusable element missing from the focus order.
    frame.surface = .{
        .title = "Approvals",
        .elements = &.{
            .{ .role = .button, .accessible_name = "Approve" },
            .{ .role = .button, .accessible_name = "Deny" },
        },
        .focus_order = &.{0},
    };

    try std.testing.expectError(
        error.InvalidPresentation,
        recording.renderer().present(frame, gpa),
    );
    try std.testing.expectEqual(@as(usize, 0), recording.frames_presented);
}

test "a frame with no area is refused" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{};

    var frame = sampleFrame(.standard, .light);
    frame.width_points = 0;
    try std.testing.expectError(
        error.InvalidPresentation,
        recording.renderer().present(frame, gpa),
    );

    frame = sampleFrame(.standard, .light);
    frame.height_points = -1;
    try std.testing.expectError(
        error.InvalidPresentation,
        recording.renderer().present(frame, gpa),
    );
}

test "a renderer that cannot express a frame refuses it before drawing" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{ .refuse_unsupported = true };

    try std.testing.expectError(
        error.Unsupported,
        recording.renderer().present(sampleFrame(.standard, .light), gpa),
    );
    try std.testing.expectEqual(@as(usize, 0), recording.frames_presented);
    // Nothing is published either: an unsupported frame is not a surface the
    // user is on.
    try std.testing.expectEqual(@as(usize, 0), recording.accessibility_publications);
}

test "the frame resolves tokens rather than the renderer choosing values" {
    const frame = sampleFrame(.standard, .dark);

    try std.testing.expectEqual(
        tokens.colour(.status_awaiting_approval, .dark),
        frame.colour(.status_awaiting_approval),
    );
    try std.testing.expectEqual(
        tokens.textPoints(.body, .standard),
        frame.textPoints(.body),
    );
}

test "the boundary carries every accessibility preference through to the frame" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{};

    const demanding = accessibility.Preferences.most_demanding;
    const frame = sampleFrame(demanding, .dark);

    try recording.renderer().present(frame, gpa);

    try std.testing.expectEqual(tokens.TextScale.accessibility_largest, recording.last_text_scale.?);
    try std.testing.expectEqual(tokens.Appearance.dark, recording.last_appearance.?);
    // Reduced motion reaches the renderer as a duration, so it cannot be
    // ignored by a renderer that never checks the preference.
    for (std.enums.values(tokens.MotionRole)) |role| {
        try std.testing.expectEqual(@as(u16, 0), frame.motionMilliseconds(role));
    }
}

test "a surface renders at every text scale in both appearances" {
    const gpa = std.testing.allocator;
    var recording: RecordingRenderer = .{};

    for (std.enums.values(tokens.Appearance)) |appearance| {
        for (std.enums.values(tokens.TextScale)) |scale| {
            const frame = sampleFrame(.{ .text_scale = scale }, appearance);
            try recording.renderer().present(frame, gpa);
        }
    }

    const expected = std.enums.values(tokens.Appearance).len *
        std.enums.values(tokens.TextScale).len;
    try std.testing.expectEqual(expected, recording.frames_presented);
}

test "the renderer holds no state between frames" {
    // The contract passes everything needed for a frame in the frame. A
    // renderer with fields for surface state would be a second place the
    // system's state lives.
    inline for (@typeInfo(Renderer).@"struct".fields) |field| {
        const is_context = std.mem.eql(u8, field.name, "context");
        const is_operation = std.mem.endsWith(u8, field.name, "Fn");
        try std.testing.expect(is_context or is_operation);
    }
}

test "the renderer is never handed a capability" {
    // Presentation is not authority. A renderer that received one could act,
    // and the approval surface asks the policy precisely so that it cannot.
    inline for (@typeInfo(Frame).@"struct".fields) |field| {
        try std.testing.expect(field.type != core.capability.Handle);
        try std.testing.expect(field.type != core.capability.Capability);
    }
}
