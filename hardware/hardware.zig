//! The device itself, behind interfaces.
//!
//! Each subsystem is an interface with at least two implementations: the real
//! one for a board, and one that stands in for it so the rest of the platform
//! can be exercised without hardware. A stand-in always says it is one, because
//! code tested against a guarantee it was not getting is code that has not been
//! tested.

pub const abstraction = @import("abstraction/abstraction.zig");
pub const audio = @import("audio/audio.zig");
pub const battery = @import("battery/battery.zig");
pub const biometrics = @import("biometrics/biometrics.zig");
pub const charging = @import("charging/charging.zig");
pub const display = @import("display/display.zig");
pub const haptics = @import("haptics/haptics.zig");
pub const modem = @import("modem/modem.zig");
pub const sensors = @import("sensors/sensors.zig");
pub const emulator_board = @import("boards/emulator/emulator.zig");
pub const reference_board = @import("boards/reference/reference.zig");
pub const secure_element = @import("secure-element/secure_element.zig");
pub const thermal = @import("thermal/thermal.zig");

test {
    _ = abstraction;
    _ = audio;
    _ = battery;
    _ = biometrics;
    _ = charging;
    _ = display;
    _ = haptics;
    _ = modem;
    _ = sensors;
    _ = emulator_board;
    _ = reference_board;
    _ = secure_element;
    _ = thermal;
}
