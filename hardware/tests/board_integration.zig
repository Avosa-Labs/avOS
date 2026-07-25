//! Hardware integration: the drivers behind a board, exercised together.
//!
//! The abstraction's promise is that a platform written once fits both the
//! emulator and a reference board. The unit tests check each driver alone; this
//! obtains several from a bound board and drives them together — a secure element
//! that quotes boot state, a camera that lights its indicator, a microphone under
//! a hardware mute — plus the failure seams a real device shows: a use-limited
//! key, and an element that goes unavailable mid-operation.

const std = @import("std");
const bound = @import("../boards/bound.zig");
const emulator = @import("../boards/emulator/emulator.zig");
const secure_element = @import("../secure-element/secure_element.zig");
const thermal = @import("../thermal/thermal.zig");
const battery = @import("../battery/battery.zig");
const sensors = @import("../sensors/sensors.zig");
const camera = @import("../camera/camera.zig");
const audio = @import("../audio/audio.zig");

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

test "a bound board's drivers work together for a real device flow" {
    var table = emulator.build();
    var element_state: secure_element.SoftwareElement = .{};
    var thermal_state: thermal.TestSensor = .{ .temperature = 30_000 };
    var battery_state: battery.TestSource = .{ .charge = 4_000 };
    var motion_state: sensors.TestSource = .{};

    const binding: bound.BoundBoard = .{
        .board = table.board(),
        .element_instance = element_state.element(),
        .thermal_instance = thermal_state.sensor(),
        .battery_instance = battery_state.source(),
        .motion_instance = motion_state.source(),
    };

    // The secure element resolves and quotes the boot state.
    const element = binding.element().?;
    const attest_key = try element.create(.device_attestation, .{});
    const quote = try element.attestBootState(attest_key, @splat(0x33));
    const public = try element.publicKey(attest_key);
    try (Ed25519.Signature.fromBytes(quote)).verify(&[_]u8{0x33} ** 32, try Ed25519.PublicKey.fromBytes(public));

    // The sensor drivers resolve.
    try testing.expect(binding.thermalSensor() != null);
    try testing.expect(binding.batterySource() != null);
    try testing.expect(binding.motionSource() != null);

    // A camera capture lights its indicator, and a muted microphone refuses.
    var cam: camera.Camera = .{};
    const capture = cam.begin(.back);
    try testing.expect(capture.isStarted());
    try testing.expect(cam.indicator_lit);

    var mic: audio.Microphone = .{ .muted = true };
    try testing.expectEqual(audio.CaptureRefusal.muted, mic.begin().refused);
}

test "a use-limited key stops signing at its limit" {
    var element_state: secure_element.SoftwareElement = .{};
    const element = element_state.element();
    // A key good for exactly two uses.
    const handle = try element.create(.storage_protection, .{ .use_limit = 2 });
    _ = try element.sign(handle, .storage_protection, @splat(1));
    _ = try element.sign(handle, .storage_protection, @splat(2));
    // The third use, whether it races or follows, is refused.
    try testing.expectError(error.ConditionUnmet, element.sign(handle, .storage_protection, @splat(3)));
}

test "an element that goes unavailable fails every operation closed" {
    var element_state: secure_element.SoftwareElement = .{};
    const handle = try element_state.element().create(.device_attestation, .{});

    element_state.unavailable = true;
    const element = element_state.element();
    try testing.expectError(error.Unavailable, element.sign(handle, .device_attestation, @splat(1)));
    try testing.expectError(error.Unavailable, element.attestBootState(handle, @splat(1)));
    try testing.expectError(error.Unavailable, element.advanceMonotonic());
    try testing.expectError(error.Unavailable, element.publicKey(handle));
}
