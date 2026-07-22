//! Resolves the I/O adapters for the running compiler line.
//!
//! This is the only place that knows which per-line directory to import.
//! Callers import `compat_io` and never name a line, so adding a qualified
//! line changes this file and nothing else.

const compat = @import("../line.zig");

const line = compat.current_line orelse @compileError(
    "this compiler release is outside the supported window; see docs/operations/build.md",
);

const adapters = switch (compat.qualificationOf(line)) {
    .canonical => switch (line) {
        .@"0_16" => @import("../0_16/io.zig"),
        // A line reaching this branch is marked canonical without adapters,
        // which is a defect in `compat.qualificationOf` rather than a user error.
        .@"0_14", .@"0_15" => @compileError("line marked canonical without adapters"),
    },
    .unqualified => @compileError(
        "this compiler line has no qualified lane; build with the canonical release named in toolchain.lock.json",
    ),
};

pub const Io = adapters.Io;
pub const Dir = adapters.Dir;
pub const File = adapters.File;
pub const Writer = adapters.Writer;
pub const Reader = adapters.Reader;
pub const Limit = adapters.Limit;
pub const Init = adapters.Init;

pub const cwd = adapters.cwd;
pub const stdout = adapters.stdout;
pub const stderr = adapters.stderr;
pub const readFile = adapters.readFile;
pub const writeFile = adapters.writeFile;
pub const args = adapters.args;
