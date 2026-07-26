//! Whether the environment guarantees a Vulkan implementation, so tests can be strict.
//!
//! The adapter's tests must pass on two kinds of host: one with no Vulkan loader (a developer's
//! machine, the macOS CI lane) where the right behaviour is a clean typed absence, and one that
//! provisions a software implementation (the Linux lane running Mesa lavapipe) where the right
//! behaviour is a real device that must actually come up. A test that merely tolerates both
//! proves nothing on the second. This reads the signal the CI lane sets when it has provisioned
//! an implementation: where it is set, absence is a failure, not an accepted outcome.

const std = @import("std");

/// True when the environment guarantees a working Vulkan implementation (the lavapipe lane sets
/// `REQUIRE_VULKAN_DEVICE`). Where true, a bring-up that reports absence is a test failure. The
/// adapter links libc, so the C environment is the portable way to read the signal.
pub fn deviceRequired() bool {
    return std.c.getenv("REQUIRE_VULKAN_DEVICE") != null;
}
