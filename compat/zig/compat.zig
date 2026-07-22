//! Compiler and host compatibility boundary.
//!
//! Everything that differs between supported Zig lines is reached through this
//! module. Callers never name a line and never import a per-line directory, so
//! qualifying a new line changes only what is under `compat/zig/`.
//!
//! This boundary may hold build-system adapters, standard-library adapters,
//! I/O adapters, target-query adapters, and compiler-feature probes. It must
//! not fork business logic, security logic, capability semantics, task state
//! machines, protocol schemas, or tests by compiler version.

/// Which compiler line is running and whether it is qualified.
pub const line = @import("line.zig");

/// I/O adapters for the running line.
pub const io = @import("selected/io.zig");

test {
    // Pull the tests of every file behind this boundary into the module's test
    // binary; they would otherwise be skipped for lack of a reference.
    _ = line;
    _ = io;
}
