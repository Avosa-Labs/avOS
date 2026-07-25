//! Kernel integration: one privileged operation across every policy module.
//!
//! The unit tests prove each kernel module decides correctly on its own; this
//! proves they are one system. A camera access is authorized by the device
//! policy through the security pipeline, its working memory is placed in a domain
//! the memory policy accepts, its scheduling class is mapped to a host priority
//! by the adapter, and the scheduler confirms it would run. If any module drifted
//! from the shared vocabulary the others use, this would fail to compile or fail
//! to pass.

const std = @import("std");
const security_hooks = @import("../security-hooks/security_hooks.zig");
const device_policy = @import("../device-policy/device_policy.zig");
const memory_policy = @import("../memory-policy/memory_policy.zig");
const scheduler_policy = @import("../scheduler-policy/scheduler_policy.zig");
const adapters = @import("../adapters/adapters.zig");

const testing = std.testing;

fn cameraStreamGrant() device_policy.Grant {
    var classes = std.EnumSet(device_policy.DeviceClass).initEmpty();
    classes.insert(.camera);
    var accesses = std.EnumSet(device_policy.Access).initEmpty();
    accesses.insert(.stream);
    return .{ .classes = classes, .accesses = accesses };
}

test "an authorized camera stream flows through mediation, memory, and scheduling" {
    // 1. The security pipeline authorizes the access through the device policy,
    //    lighting the capture indicator when it performs.
    var indicator: device_policy.Indicator = .{};
    var operation: security_hooks.DeviceAccess = .{
        .authenticated = true,
        .class = .camera,
        .access = .stream,
        .grant = cameraStreamGrant(),
        .situation = .{ .person_present = true },
        .target_ready = true,
        .indicator = &indicator,
    };
    try testing.expect(operation.perform().wasCompleted());
    try testing.expect(indicator.isLit(.camera));

    // 2. The memory policy accepts a per-request buffer for the frame work and
    //    holds it to its ceiling.
    try memory_policy.place(.per_request, .{});
    try testing.expect(!memory_policy.wouldExceed(.per_request, 1 << 20, 0));

    // 3. The work is human-interactive; the adapter maps that class to a host
    //    priority, and the scheduler would run it ahead of background work.
    var posix: adapters.PosixAdapter = .{};
    const priority = posix.adapter().priorityFor(.human_interactive);
    const background = posix.adapter().priorityFor(.speculative);
    try testing.expect(priority.value < background.value); // lower is more urgent

    const demands = [_]scheduler_policy.Demand{
        .{ .class = .human_interactive, .ready = 1 },
        .{ .class = .speculative, .ready = 1 },
    };
    try testing.expectEqual(
        scheduler_policy.Decision{ .run = .human_interactive },
        scheduler_policy.selectNext(&demands, scheduler_policy.Budgets.reference),
    );
}

test "an unauthenticated access is stopped at the pipeline and never reaches the sensor" {
    var indicator: device_policy.Indicator = .{};
    var operation: security_hooks.DeviceAccess = .{
        .authenticated = false,
        .class = .camera,
        .access = .stream,
        .grant = cameraStreamGrant(),
        .situation = .{ .person_present = true },
        .target_ready = true,
        .indicator = &indicator,
    };
    const outcome = operation.perform();
    try testing.expectEqual(security_hooks.Outcome{ .refused_at = .authenticate }, outcome);
    // The refusal is recorded and the indicator was never lit.
    try testing.expect(!indicator.isLit(.camera));
    try testing.expect(operation.audited != null);
}
