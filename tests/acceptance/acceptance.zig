//! Acceptance tests.
//!
//! Each file here holds one milestone to what it must demonstrate. They live
//! outside the modules they exercise and reach them only through the interfaces
//! a real caller has, so an acceptance test cannot pass by using a seam that
//! nothing else uses.

pub const agent_shell = @import("agent_shell.zig");
pub const android_compatibility = @import("android_compatibility.zig");

test {
    _ = agent_shell;
    _ = android_compatibility;
}
