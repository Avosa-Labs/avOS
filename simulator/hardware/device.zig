//! A simulated embodied device, driven for real through the agent contract.
//!
//! Physical robot and vehicle transports are C ecosystems that arrive with a chosen hardware
//! target. Until then the device path must be exercised genuinely rather than faked, or the
//! embodied story is only a mock. So the simulator provides a device profile: a device with an
//! on-device reflex controller for its safety loops and a deliberative mind that plans, each a mind
//! under the same contract every agent obeys. The neutrality suite and the Agents surface drive
//! this device through that contract, so the reflex/deliberative split and the safety envelope are
//! tested against a real participant, not a stand-in for one.
//!
//! The device's authority follows the contract's split-brain rule: reflex capabilities are held by
//! the on-device reflex controller, planning capabilities by the deliberative mind — which may be
//! local or remote, and which can be swapped without changing what the device is allowed to do.

const std = @import("std");
const sdk = @import("sdk");
const contract = sdk.agent_contract;

/// A capability a device exposes, tagged with the control path it belongs to.
pub const Capability = struct {
    name: []const u8,
    control_class: contract.ControlClass,
};

/// The capabilities the simulated device exposes: reflex ones for the loops that keep it safe, and
/// deliberative ones for planned behaviour.
pub const capabilities = [_]Capability{
    .{ .name = "device.emergency_stop", .control_class = .reflex },
    .{ .name = "device.balance", .control_class = .reflex },
    .{ .name = "device.obstacle_stop", .control_class = .reflex },
    .{ .name = "device.move", .control_class = .deliberative },
    .{ .name = "device.perceive", .control_class = .deliberative },
};

/// A simulated embodied device: its fixed on-device reflex controller and the deliberative mind
/// inhabiting it. The device is a principal; the deliberative mind is an adapter bound to it.
pub const Device = struct {
    /// The reflex controller runs on-device by construction — a reflex loop across the network is
    /// not a coherent mind.
    reflex: contract.Mind = .{ .control_class = .reflex, .locality = .on_device },
    /// The deliberative mind that plans; local or remote, swappable.
    deliberative: contract.Mind,

    /// A device inhabited by a local deliberative mind.
    pub fn withLocalMind() Device {
        return .{ .deliberative = .{ .control_class = .deliberative, .locality = .on_device } };
    }

    /// A device inhabited by a remote deliberative mind.
    pub fn withRemoteMind() Device {
        return .{ .deliberative = .{ .control_class = .deliberative, .locality = .remote } };
    }

    /// Whether the device may run `capability` — the reflex controller holds the reflex loops, the
    /// deliberative mind holds the planning, and the contract decides each. A reflex capability is
    /// routed to the reflex controller, so a remote deliberative mind never reaches a reflex loop.
    pub fn mayRun(device: Device, capability: Capability) bool {
        const mind = switch (capability.control_class) {
            .reflex => device.reflex,
            .deliberative => device.deliberative,
        };
        return contract.mayGrant(mind, capability.control_class);
    }
};

// --- Tests ---

const testing = std.testing;

test "the device runs its reflex loops and its planning, each on the right mind" {
    const device = Device.withLocalMind();
    for (capabilities) |capability| {
        try testing.expect(device.mayRun(capability)); // a coherent device runs all its capabilities
    }
}

test "swapping the deliberative mind for a remote one changes nothing about the device's authority" {
    const local = Device.withLocalMind();
    const remote = Device.withRemoteMind();
    // The property from the contract: the mind is an adapter; the device's grants are unchanged by
    // which mind plans. Every capability resolves the same either way — reflex loops stay with the
    // on-device controller, planning is grantable to any mind.
    for (capabilities) |capability| {
        try testing.expectEqual(local.mayRun(capability), remote.mayRun(capability));
    }
}

test "a reflex loop is never reachable by the deliberative mind, however it runs" {
    // Even when the deliberative mind is remote, the reflex capabilities are held by the on-device
    // reflex controller — the deliberative mind is never granted a reflex loop.
    const remote = Device.withRemoteMind();
    try testing.expect(!contract.mayGrant(remote.deliberative, .reflex));
    // But the device still runs its reflex loops, because they route to the reflex controller.
    try testing.expect(remote.mayRun(.{ .name = "device.emergency_stop", .control_class = .reflex }));
}
