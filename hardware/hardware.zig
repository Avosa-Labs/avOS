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
pub const camera = @import("camera/camera.zig");
pub const input = @import("input/input.zig");
pub const sim = @import("sim/sim.zig");
pub const bluetooth = @import("bluetooth/bluetooth.zig");
pub const accessories = @import("accessories/accessories.zig");
pub const biometrics = @import("biometrics/biometrics.zig");
pub const charging = @import("charging/charging.zig");
pub const display = @import("display/display.zig");
pub const gnss = @import("gnss/gnss.zig");
pub const haptics = @import("haptics/haptics.zig");
pub const modem = @import("modem/modem.zig");
pub const nfc = @import("nfc/nfc.zig");
pub const usb = @import("usb/usb.zig");
pub const wifi = @import("wifi/wifi.zig");
pub const sensors = @import("sensors/sensors.zig");
pub const emulator_board = @import("boards/emulator/emulator.zig");
pub const reference_board = @import("boards/reference/reference.zig");
pub const bound_board = @import("boards/bound.zig");
pub const board_integration = @import("tests/board_integration.zig");
pub const secure_element = @import("secure-element/secure_element.zig");
pub const thermal = @import("thermal/thermal.zig");

test {
    _ = abstraction;
    _ = audio;
    _ = battery;
    _ = camera;
    _ = input;
    _ = sim;
    _ = bluetooth;
    _ = accessories;
    _ = biometrics;
    _ = charging;
    _ = display;
    _ = gnss;
    _ = haptics;
    _ = modem;
    _ = nfc;
    _ = usb;
    _ = wifi;
    _ = sensors;
    _ = emulator_board;
    _ = reference_board;
    _ = bound_board;
    _ = board_integration;
    _ = secure_element;
    _ = thermal;
}
