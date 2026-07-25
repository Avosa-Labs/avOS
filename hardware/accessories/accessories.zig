//! Accessory attachment and authorization.
//!
//! Anything a user can plug in is something an attacker can plug in. An accessory
//! is inert until it is enumerated, described, and authorized; until then it gets
//! no capability, and an accessory that claims a capability it cannot prove — a
//! cable that says it is a keyboard, a dock that says it is a display — is denied
//! rather than trusted on its own word. This is the policy; a board handles the
//! physical port.

const std = @import("std");

/// What an accessory offers. The classes a hostile accessory would most want are
/// the ones that inject input or exfiltrate data.
pub const Function = enum {
    input,
    display,
    audio,
    storage,
    power,
    other,
};

pub const Refusal = enum {
    /// The accessory was not authorized by the user for this function.
    not_authorized,
    /// The accessory claims a function it did not present valid identification
    /// for, so it may be pretending to be something it is not.
    unverified_claim,
    /// No room to track another attached accessory.
    port_table_full,
};

pub const Accessory = struct {
    id: u32,
    function: Function,
    /// Whether the accessory presented identification the port could verify.
    identified: bool,
    /// Whether the user authorized this function for this accessory.
    authorized: bool,
    /// Set once attached and cleared on detach.
    attached: bool = false,
};

pub const capacity: usize = 8;

/// The attached accessories and the attach policy.
pub const Port = struct {
    slots: [capacity]?Accessory = @splat(null),

    /// Attaches an accessory if it is identified and authorized for its function.
    /// An accessory that injects input is held to the same rule as any other:
    /// there is no implicit trust for being plugged in.
    pub fn attach(port: *Port, accessory: Accessory) ?Refusal {
        if (!accessory.identified) return .unverified_claim;
        if (!accessory.authorized) return .not_authorized;
        for (&port.slots) |*slot| {
            if (slot.* == null) {
                var attached = accessory;
                attached.attached = true;
                slot.* = attached;
                return null;
            }
        }
        return .port_table_full;
    }

    pub fn detach(port: *Port, id: u32) void {
        for (&port.slots) |*slot| {
            if (slot.*) |accessory| {
                if (accessory.id == id) slot.* = null;
            }
        }
    }

    /// Whether an attached accessory may act as the given function. Only an
    /// attached, authorized accessory of that function may.
    pub fn permits(port: Port, id: u32, function: Function) bool {
        for (port.slots) |slot| {
            if (slot) |accessory| {
                if (accessory.id == id) {
                    return accessory.attached and accessory.authorized and accessory.function == function;
                }
            }
        }
        return false;
    }

    pub fn count(port: Port) usize {
        var total: usize = 0;
        for (port.slots) |slot| {
            if (slot != null) total += 1;
        }
        return total;
    }
};

const testing = std.testing;

test "an identified, authorized accessory attaches and may act as its function" {
    var port: Port = .{};
    try testing.expect(port.attach(.{ .id = 1, .function = .input, .identified = true, .authorized = true }) == null);
    try testing.expect(port.permits(1, .input));
    // It may not act as a function it did not present.
    try testing.expect(!port.permits(1, .display));
}

test "an unverified or unauthorized accessory is refused" {
    var port: Port = .{};
    try testing.expectEqual(Refusal.unverified_claim, port.attach(.{ .id = 1, .function = .input, .identified = false, .authorized = true }).?);
    try testing.expectEqual(Refusal.not_authorized, port.attach(.{ .id = 2, .function = .storage, .identified = true, .authorized = false }).?);
    try testing.expectEqual(@as(usize, 0), port.count());
}

test "a detached accessory no longer permits anything" {
    var port: Port = .{};
    _ = port.attach(.{ .id = 1, .function = .audio, .identified = true, .authorized = true });
    port.detach(1);
    try testing.expect(!port.permits(1, .audio));
    try testing.expectEqual(@as(usize, 0), port.count());
}
