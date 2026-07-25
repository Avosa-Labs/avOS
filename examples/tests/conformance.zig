//! Confirms every example's manifest is coherent by the SDK's own rule and declares
//! exactly the tools the example actually registers — so a developer reading an example's
//! manifest sees the real surface it exposes, never a claim that drifted from the code.
//!
//! An example is a teaching artifact: a developer copies its shape. If its manifest
//! declared a capability its code did not register, or a tool the SDK would reject as
//! incoherent, the example would be teaching a mistake. This pins them together at build
//! time. For each example the manifest's tool set must equal the example's registered
//! tool set — same names, same required capabilities — and the manifest must pass
//! `sdk.agent_manifest.validate`, the identical check the platform runs on a real
//! developer's agent. An example that drifts is a build error, not a bad lesson shipped.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");

const hello_agent = @import("../hello-agent/hello_agent.zig");
const todo_app = @import("../todo-app/todo_app.zig");
const camera_capture = @import("../camera-capture/camera_capture.zig");

/// Asserts the manifest's declared tools are exactly the example's registered tools:
/// same names, each requiring the same capability. The manifest's public claim and the
/// code's real surface must be one set.
fn expectSurfaceMatches(comptime manifest: anytype, tools: anytype) !void {
    try testing.expectEqual(@as(usize, tools.len), manifest.tools.len);
    inline for (manifest.tools) |declared| {
        var found = false;
        for (tools) |tool| {
            if (std.mem.eql(u8, tool.name, declared.name) and
                std.mem.eql(u8, tool.required_capability, declared.requires_capability))
            {
                found = true;
            }
        }
        try testing.expect(found);
    }
    for (tools) |tool| {
        var declared = false;
        inline for (manifest.tools) |entry| {
            if (std.mem.eql(u8, tool.name, entry.name) and
                std.mem.eql(u8, tool.required_capability, entry.requires_capability))
            {
                declared = true;
            }
        }
        try testing.expect(declared);
    }
}

/// Asserts the manifest passes the SDK's own coherence check — the same one the platform
/// runs on a real developer's agent manifest: every tool backed by a requested
/// capability, no duplicate tool names.
fn expectCoherent(comptime manifest: anytype) !void {
    const caps = comptime blk: {
        var arr: [manifest.requested_capabilities.len][]const u8 = undefined;
        for (manifest.requested_capabilities, 0..) |capability, index| arr[index] = capability;
        break :blk arr;
    };
    const tools = comptime blk: {
        var arr: [manifest.tools.len]sdk.agent_manifest.Tool = undefined;
        for (manifest.tools, 0..) |tool, index| {
            arr[index] = .{ .name = tool.name, .requires_capability = tool.requires_capability };
        }
        break :blk arr;
    };
    try sdk.agent_manifest.validate(.{ .requested_capabilities = &caps, .tools = &tools });
}

test "hello-agent's manifest is coherent and matches its registered tools" {
    const manifest = @import("../hello-agent/manifest.zon");
    try expectCoherent(manifest);
    try expectSurfaceMatches(manifest, hello_agent.tools);
}

test "todo-app's manifest is coherent and matches its registered tools" {
    const manifest = @import("../todo-app/manifest.zon");
    try expectCoherent(manifest);
    try expectSurfaceMatches(manifest, todo_app.tools);
}

test "camera-capture's manifest is coherent and matches its registered tools" {
    const manifest = @import("../camera-capture/manifest.zon");
    try expectCoherent(manifest);
    try expectSurfaceMatches(manifest, camera_capture.tools);
}
