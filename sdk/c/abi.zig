//! Deciding whether a compiled binary's ABI matches the runtime's, so a native module built against
//! one C ABI is never loaded into a runtime that lays memory out differently.
//!
//! The C ABI is the exact binary contract between a compiled module and the runtime that loads it:
//! how big each struct is, where each field sits, how arguments are passed. Unlike a source-level
//! API, the ABI has no room for partial compatibility — a module compiled against a struct that was
//! 16 bytes cannot be loaded into a runtime where that struct is now 24 bytes, because it reads and
//! writes the wrong offsets and corrupts memory silently. So the ABI carries a version that changes
//! whenever the binary layout changes, and a module is loadable only when its ABI version exactly
//! matches the runtime's. There is no "newer is fine" here as there is for a source SDK; a mismatch
//! in either direction is a refusal, because the layouts differ and loading anyway is undefined
//! behaviour. Checking the exact match at load time turns silent memory corruption into a clean,
//! explained load failure.
//!
//! This module loads nothing. It decides whether a module's ABI version matches the runtime's, as a
//! pure function.

const std = @import("std");

/// Whether a module compiled against `module_abi` may be loaded into a runtime at `runtime_abi`.
///
/// The versions must match exactly. Unlike a source API, a binary ABI has no forward or backward
/// compatibility: any difference in the version means the memory layout differs, and loading a
/// module whose layout disagrees with the runtime corrupts memory. So a mismatch in either
/// direction — older or newer — is refused.
pub fn loadable(module_abi: u32, runtime_abi: u32) bool {
    return module_abi == runtime_abi;
}

test "a matching ABI is loadable" {
    try std.testing.expect(loadable(7, 7));
}

test "an older module ABI is not loadable" {
    try std.testing.expect(!loadable(6, 7));
}

test "a newer module ABI is not loadable" {
    // Unlike a source SDK, newer is not fine — the layout differs.
    try std.testing.expect(!loadable(8, 7));
}

test "loadability is exact equality, swept" {
    // The exact-match property: loadable is true only when the versions are identical.
    var module: u32 = 0;
    while (module <= 10) : (module += 1) {
        var runtime: u32 = 0;
        while (runtime <= 10) : (runtime += 1) {
            try std.testing.expectEqual(module == runtime, loadable(module, runtime));
        }
    }
}
