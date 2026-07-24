//! The developer SDK.
//!
//! The platform a developer builds against. The modules decide rather than generate: whether an
//! agent manifest is coherent, whether an SDK version is compatible with what an app was built for,
//! whether an interface may evolve, whether a native ABI matches, and whether a documented surface
//! may publish. The through-line is that a developer's mistake is caught at build time — an
//! incoherent manifest, a breaking interface change, a mismatched ABI, an undocumented public symbol
//! — rather than becoming a runtime failure a user hits, testable without a toolchain.

pub const semver = @import("zig/semver.zig");
pub const agent_manifest = @import("agents/manifest.zig");
pub const testing = @import("testing/harness.zig");
pub const wit = @import("wit/interface.zig");
pub const c_abi = @import("c/abi.zig");
pub const web_permissions = @import("web/permissions.zig");
pub const android_bridge = @import("android/bridge.zig");
pub const swift = @import("swift/abi.zig");
pub const templates = @import("templates/manifest.zig");
pub const examples = @import("examples/registry.zig");
pub const documentation = @import("documentation/coverage.zig");
pub const design = @import("design/reference.zig");

test {
    _ = semver;
    _ = agent_manifest;
    _ = testing;
    _ = wit;
    _ = c_abi;
    _ = web_permissions;
    _ = android_bridge;
    _ = swift;
    _ = templates;
    _ = examples;
    _ = documentation;
    _ = design;
}
