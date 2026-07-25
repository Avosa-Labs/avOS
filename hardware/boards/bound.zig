//! Binding a board's declared capabilities to working driver instances.
//!
//! The `abstraction.Board` protocol answers whether a capability is present and
//! ready; a query hands back a token, not a driver. This wraps a board with the
//! driver instances that stand behind its capabilities, so a subsystem can obtain
//! a secure element, a thermal sensor, a battery source, or a motion source and
//! actually use it.
//!
//! The instances are held as their interface types, never as a concrete
//! implementation, so nothing here names a stand-in: the emulator supplies its
//! software drivers, a reference board supplies its silicon, and this file cannot
//! tell them apart. Binding is typed — each capability yields a different
//! driver type, so a caller asks for the one it means — and every accessor first
//! confirms the capability is present and ready before handing the instance back.
//!
//! Ownership: the instances are supplied by whoever built this board and must
//! outlive it; a bound board borrows them and never frees them.

const std = @import("std");
const abstraction = @import("../abstraction/abstraction.zig");
const secure_element = @import("../secure-element/secure_element.zig");
const thermal = @import("../thermal/thermal.zig");
const battery = @import("../battery/battery.zig");
const sensors = @import("../sensors/sensors.zig");

pub const BoundBoard = struct {
    board: abstraction.Board,
    element_instance: ?secure_element.Element = null,
    thermal_instance: ?thermal.Sensor = null,
    battery_instance: ?battery.Source = null,
    motion_instance: ?sensors.Source = null,

    /// The secure element, if the board declares it present and one was supplied.
    pub fn element(binding: BoundBoard) ?secure_element.Element {
        return binding.driverFor(.secure_element, binding.element_instance);
    }

    /// The thermal sensor, if present.
    pub fn thermalSensor(binding: BoundBoard) ?thermal.Sensor {
        return binding.driverFor(.thermal_sensors, binding.thermal_instance);
    }

    /// The battery source, if present.
    pub fn batterySource(binding: BoundBoard) ?battery.Source {
        return binding.driverFor(.battery, binding.battery_instance);
    }

    /// The motion source, if present.
    pub fn motionSource(binding: BoundBoard) ?sensors.Source {
        return binding.driverFor(.motion_sensors, binding.motion_instance);
    }

    /// A capability yields its instance only when the board reports it available,
    /// so a driver held for a capability the board has withdrawn is never handed
    /// out.
    fn driverFor(binding: BoundBoard, capability: abstraction.Capability, instance: anytype) @TypeOf(instance) {
        if (!binding.board.query(capability).isAvailable()) return null;
        return instance;
    }
};

const testing = std.testing;

test "a bound board hands back the drivers behind its capabilities" {
    const emulator = @import("emulator/emulator.zig");
    var table = emulator.build();

    // The stand-in drivers are built here, in a test block, where a stand-in is
    // the point; production code above only ever sees the interfaces.
    var element_state: secure_element.SoftwareElement = .{};
    var thermal_state: thermal.TestSensor = .{ .temperature = 30_000 };
    var battery_state: battery.TestSource = .{ .charge = 4_000 };
    var motion_state: sensors.TestSource = .{};

    const bound: BoundBoard = .{
        .board = table.board(),
        .element_instance = element_state.element(),
        .thermal_instance = thermal_state.sensor(),
        .battery_instance = battery_state.source(),
        .motion_instance = motion_state.source(),
    };

    // The secure element resolves and works end to end.
    const element = bound.element().?;
    const handle = try element.create(.device_attestation, .{});
    _ = try element.sign(handle, .device_attestation, @splat(9));

    try testing.expect(bound.thermalSensor() != null);
    try testing.expect(bound.batterySource() != null);
    try testing.expect(bound.motionSource() != null);
}

test "a capability the board has withdrawn resolves to null" {
    const emulator = @import("emulator/emulator.zig");
    var table = emulator.build();
    table.not_ready.insert(.secure_element);

    var element_state: secure_element.SoftwareElement = .{};
    const bound: BoundBoard = .{
        .board = table.board(),
        .element_instance = element_state.element(),
    };

    // The element instance exists, but the board says the capability is not
    // ready, so resolution refuses to hand it out.
    try testing.expect(bound.element() == null);
}
