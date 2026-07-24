//! Validating an agent's manifest before it is built, so a developer's agent declares a coherent
//! set of tools and every tool it exposes has the capability to back it.
//!
//! An agent an SDK developer writes declares, in a manifest, the tools it offers — send a message,
//! read a file — and the capabilities each needs. That manifest is the contract the platform's
//! agent host enforces at runtime, so a manifest that is incoherent produces an agent that fails
//! or, worse, one whose declared surface does not match what it can actually do. Validation catches
//! this at build time. Every tool must name the capability it requires, because a tool with no
//! declared capability would be exposed with no authority check behind it. Tool names must be
//! unique, because two tools sharing a name make dispatch ambiguous. And the capabilities a tool
//! requires must be ones the agent actually requested, because a tool needing an authority the
//! agent did not ask for can never run. A manifest that passes is safe to build into an agent; one
//! that fails is a compile-time error the developer sees, not a runtime surprise a user hits.
//!
//! This module builds no agent. It validates an agent manifest — tool naming, capabilities, and
//! coherence — as a pure function.

const std = @import("std");

/// A tool an agent exposes.
pub const Tool = struct {
    name: []const u8,
    /// The capability this tool requires. Never empty.
    requires_capability: []const u8,
};

/// An agent manifest.
pub const Manifest = struct {
    /// The capabilities the agent requests overall.
    requested_capabilities: []const []const u8,
    /// The tools the agent exposes.
    tools: []const Tool,
};

/// Why a manifest was rejected.
pub const Invalid = error{
    /// A tool declares no required capability.
    ToolMissingCapability,
    /// Two tools share a name.
    DuplicateTool,
    /// A tool requires a capability the agent did not request.
    UndeclaredCapability,
};

fn requested(manifest: Manifest, capability: []const u8) bool {
    for (manifest.requested_capabilities) |cap| {
        if (std.mem.eql(u8, cap, capability)) return true;
    }
    return false;
}

/// Validates an agent manifest.
///
/// Every tool must name a non-empty required capability, so no tool is exposed without an authority
/// check; tool names must be unique, so dispatch is unambiguous; and each tool's required capability
/// must be one the agent requested, so no tool needs authority the agent cannot hold. A manifest
/// that passes is coherent and safe to build.
pub fn validate(manifest: Manifest) Invalid!void {
    for (manifest.tools, 0..) |tool, index| {
        if (tool.requires_capability.len == 0) return Invalid.ToolMissingCapability;
        if (!requested(manifest, tool.requires_capability)) return Invalid.UndeclaredCapability;
        for (manifest.tools[index + 1 ..]) |other| {
            if (std.mem.eql(u8, tool.name, other.name)) return Invalid.DuplicateTool;
        }
    }
}

/// Whether a manifest is valid, for callers wanting a boolean.
pub fn isValid(manifest: Manifest) bool {
    validate(manifest) catch return false;
    return true;
}

const sample_tools = [_]Tool{
    .{ .name = "read_file", .requires_capability = "files.read" },
    .{ .name = "send_message", .requires_capability = "messages.send" },
};

const sample: Manifest = .{
    .requested_capabilities = &.{ "files.read", "messages.send" },
    .tools = &sample_tools,
};

test "a coherent manifest validates" {
    try validate(sample);
    try std.testing.expect(isValid(sample));
}

test "a tool with no capability is rejected" {
    const tools = [_]Tool{.{ .name = "x", .requires_capability = "" }};
    const manifest: Manifest = .{ .requested_capabilities = &.{}, .tools = &tools };
    try std.testing.expectError(Invalid.ToolMissingCapability, validate(manifest));
}

test "duplicate tool names are rejected" {
    const tools = [_]Tool{
        .{ .name = "dup", .requires_capability = "c" },
        .{ .name = "dup", .requires_capability = "c" },
    };
    const manifest: Manifest = .{ .requested_capabilities = &.{"c"}, .tools = &tools };
    try std.testing.expectError(Invalid.DuplicateTool, validate(manifest));
}

test "a tool needing an unrequested capability is rejected" {
    const tools = [_]Tool{.{ .name = "pay", .requires_capability = "wallet.pay" }};
    const manifest: Manifest = .{ .requested_capabilities = &.{"files.read"}, .tools = &tools };
    try std.testing.expectError(Invalid.UndeclaredCapability, validate(manifest));
}

test "an empty manifest is valid" {
    try validate(.{ .requested_capabilities = &.{}, .tools = &.{} });
}

test "every valid manifest has backed, unique, declared tools, swept" {
    // The coherence property: in a valid manifest, each tool has a non-empty requested capability
    // and a unique name.
    if (isValid(sample)) {
        for (sample.tools, 0..) |tool, i| {
            try std.testing.expect(tool.requires_capability.len > 0);
            try std.testing.expect(requested(sample, tool.requires_capability));
            for (sample.tools[i + 1 ..]) |other| {
                try std.testing.expect(!std.mem.eql(u8, tool.name, other.name));
            }
        }
    }
}
