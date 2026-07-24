//! Deciding whether the camera may capture, so a photo or video is never taken without the
//! hardware in-use indicator lit and the person's foreground intent behind it.
//!
//! A camera that can capture silently is a surveillance device. The defence against that is not a
//! policy an app promises to honour but a rule the platform enforces: capture is permitted only
//! while the hardware use indicator — the light the person can see — is active, and only for an app
//! the person put in the foreground and granted the camera to. If the indicator cannot be lit,
//! capture is refused, because a capture the person cannot observe is exactly the one that must not
//! happen. A background app, or one without a camera grant, cannot capture at all regardless of the
//! indicator. Tying capture to a visible indicator and foreground intent means the person always
//! knows when the camera is live — the light being on is not decoration, it is a precondition the
//! capture path checks.
//!
//! This module captures nothing. It decides whether a capture is permitted, from the app's grant,
//! its foreground state, and whether the use indicator is active, as a pure function.

const std = @import("std");

/// The conditions under which an app asks to capture.
pub const Request = struct {
    /// Whether the person granted this app the camera.
    has_camera_grant: bool,
    /// Whether the app is the one in the foreground the person is looking at.
    is_foreground: bool,
    /// Whether the hardware in-use indicator is lit, so the person can see the camera is live.
    indicator_active: bool,
};

/// Whether a capture is permitted.
///
/// All three conditions must hold: the app holds a camera grant, it is in the foreground, and the
/// visible use indicator is active. Missing any one refuses the capture — most importantly, an
/// unlit indicator refuses it, so no frame is ever taken that the person could not have seen was
/// being taken.
pub fn mayCapture(request: Request) bool {
    return request.has_camera_grant and request.is_foreground and request.indicator_active;
}

fn makeRequest(grant: bool, foreground: bool, indicator: bool) Request {
    return .{ .has_camera_grant = grant, .is_foreground = foreground, .indicator_active = indicator };
}

test "a granted foreground app with the indicator lit may capture" {
    try std.testing.expect(mayCapture(makeRequest(true, true, true)));
}

test "an unlit indicator refuses capture" {
    try std.testing.expect(!mayCapture(makeRequest(true, true, false)));
}

test "a background app cannot capture" {
    try std.testing.expect(!mayCapture(makeRequest(true, false, true)));
}

test "an ungranted app cannot capture" {
    try std.testing.expect(!mayCapture(makeRequest(false, true, true)));
}

test "no capture ever happens with the indicator dark, swept" {
    // The visible-capture property: a permitted capture always has the use indicator lit.
    for ([_]bool{ false, true }) |grant| {
        for ([_]bool{ false, true }) |foreground| {
            for ([_]bool{ false, true }) |indicator| {
                if (mayCapture(makeRequest(grant, foreground, indicator))) {
                    try std.testing.expect(indicator);
                }
            }
        }
    }
}
