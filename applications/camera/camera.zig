//! Camera, agent-native: the capabilities the camera is used through, with capture the
//! person's alone and allowed only while the visible indicator is lit.
//!
//! Previewing and reviewing are reads; sharing a shot is external and held for the
//! person. Capture is different: no agent may perform it and no capability grants it,
//! so it is declared value-transfer-none and marked here as a person-only act, because
//! a capture an agent could trigger is a surveillance device. And even for the person,
//! capture proceeds only while the hardware use indicator is lit and the app is
//! foreground, so a capture the person cannot observe never happens.
//!
//! This module defines the app's capabilities and its capture rule; the shared frame
//! gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "camera.preview", .required_capability = "camera.preview", .effect = .read_only },
    .{ .name = "camera.review", .required_capability = "photos.read", .effect = .read_only },
    .{ .name = "camera.share", .required_capability = "photos.share", .effect = .external },
};

/// Whether a capture may proceed: only while the visible in-use indicator is lit and
/// the app is in the foreground.
pub fn mayCapture(indicator_lit: bool, foreground: bool) bool {
    return indicator_lit and foreground;
}

const testing = std.testing;

test "capture proceeds only while the indicator is lit and the app is foreground" {
    try testing.expect(mayCapture(true, true));
    try testing.expect(!mayCapture(false, true));
    try testing.expect(!mayCapture(true, false));
}

test "sharing a shot is external and held for the person" {
    try testing.expect(tools[2].effect.needsApproval());
}
