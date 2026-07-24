//! The input layer.
//!
//! Everything a person does to the device arrives here as raw signal — a contact, a key, a
//! movement, a gaze, a spoken word — and these modules decide what that signal means. They
//! reject the accidental (a palm, a passing glance), tell intent apart from noise (a tap
//! from a drag, a swipe from a wiggle), and give people who cannot use touch a reliable way
//! in (dwell-to-select, single-switch scanning). Each decides rather than dispatches, so
//! the same input always resolves the same way, testable without a sensor.

pub const touch = @import("touch/touch.zig");
pub const pointer = @import("pointer/pointer.zig");
pub const gesture = @import("gesture/gesture.zig");
pub const keyboard = @import("keyboard/keyboard.zig");
pub const composition = @import("text-services/composition.zig");
pub const handwriting = @import("handwriting/handwriting.zig");
pub const dictation = @import("voice/dictation.zig");
pub const gaze = @import("gaze/gaze.zig");
pub const scanning = @import("switch-control/scanning.zig");

test {
    _ = touch;
    _ = pointer;
    _ = gesture;
    _ = keyboard;
    _ = composition;
    _ = handwriting;
    _ = dictation;
    _ = gaze;
    _ = scanning;
}
