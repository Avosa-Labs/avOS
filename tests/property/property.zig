//! Property tests.
//!
//! Where a module's inline swept test checks its own invariant, these sweep the same decisions from
//! outside and assert the platform-wide properties they are meant to uphold: fail-closed defaults,
//! ceilings that authority cannot exceed, and monotonic state. A property test is exhaustive over a
//! small input space rather than checking a handful of points, so a regression that only shows up for
//! one combination is still caught.
//!
//! Each property is phrased in the safe direction: whenever the permissive outcome occurs, the
//! precondition that justifies it held. Nothing here reaches past the public decision of the module it
//! exercises.

const std = @import("std");
const applications = @import("applications");
const session = @import("session");
const emulator = @import("emulator");
const shell = @import("shell");

test "property: a camera capture always has the use indicator lit" {
    // Fail-closed: over every combination of grant, foreground, and indicator, a permitted capture
    // implies the visible indicator was active.
    for ([_]bool{ false, true }) |grant| {
        for ([_]bool{ false, true }) |foreground| {
            for ([_]bool{ false, true }) |indicator| {
                const request = applications.camera.Request{
                    .has_camera_grant = grant,
                    .is_foreground = foreground,
                    .indicator_active = indicator,
                };
                if (applications.camera.mayCapture(request)) {
                    try std.testing.expect(indicator);
                }
            }
        }
    }
}

test "property: delivered location never exceeds the granted precision" {
    // The exact precision is delivered only under a precise grant.
    for ([_]applications.maps.Grant{ .none, .approximate, .precise }) |grant| {
        if (applications.maps.deliver(grant) == .exact) {
            try std.testing.expectEqual(applications.maps.Grant.precise, grant);
        }
    }
}

test "property: state version is monotonic under any base" {
    // Applying an update never lowers the version, and only a current-based update advances it.
    const current: u64 = 10;
    var base: u64 = 6;
    while (base <= 14) : (base += 1) {
        switch (session.state.apply(current, .{ .base_version = base })) {
            .accepted => |version| try std.testing.expect(version > current),
            .stale => try std.testing.expect(base != current),
        }
    }
}

test "property: reconnect never delivers a category the endpoint cannot hold" {
    const categories = [_]session.synchronization.Category{ .presentation, .durable_personal, .secret };
    const trusts = [_]session.synchronization.Trust{ .presenting_only, .trusted_personal };
    for (categories) |category| {
        for (trusts) |trust| {
            var version: u64 = 1;
            while (version <= 5) : (version += 1) {
                const change = session.synchronization.Change{ .version = version, .category = category };
                if (session.synchronization.include(change, 3, trust)) {
                    // Secret is never included; durable-personal only for trusted_personal.
                    try std.testing.expect(category != .secret);
                    if (category == .durable_personal) {
                        try std.testing.expectEqual(session.synchronization.Trust.trusted_personal, trust);
                    }
                }
            }
        }
    }
}

test "property: a vehicle in motion presents nothing that demands visual attention" {
    for ([_]shell.vehicle.AttentionDemand{ .glanceable, .visual }) |demand| {
        if (shell.vehicle.mayPresent(demand, true)) {
            try std.testing.expectEqual(shell.vehicle.AttentionDemand.glanceable, demand);
        }
    }
}

test "property: a screenless endpoint commits no consequential action unconfirmed" {
    for ([_]bool{ false, true }) |confirmed| {
        if (shell.screenless.mayCommit(.consequential, confirmed)) {
            try std.testing.expect(confirmed);
        }
    }
}

test "property: a virtual image boots only on an exact digest match" {
    const authorized: emulator.image.Digest = [_]u8{0x00} ** 32;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var measured = authorized;
        measured[index] = 0xFF;
        try std.testing.expect(!emulator.image.mayBoot(measured, authorized));
    }
    try std.testing.expect(emulator.image.mayBoot(authorized, authorized));
}
