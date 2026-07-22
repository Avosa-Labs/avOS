//! Standard-library I/O surface as it exists on the 0.16 line.
//!
//! Host tools and services import this rather than reaching into the standard
//! library directly, so that a future qualified line supplies its own file with
//! the same names and no caller changes. The adapters stay thin: this file
//! renames and narrows, it never adds behavior.

const std = @import("std");

pub const Io = std.Io;
pub const Dir = std.Io.Dir;
pub const File = std.Io.File;
pub const Writer = std.Io.Writer;
pub const Reader = std.Io.Reader;
pub const Limit = std.Io.Limit;

/// Entry point argument bundle. A program's `main` accepts this and threads
/// `io` and the allocators onward rather than reaching for process globals.
pub const Init = std.process.Init;

pub fn cwd() Dir {
    return .cwd();
}

/// Buffered writer over standard output. The caller owns `buffer` and must
/// call `flush` on the returned interface before the buffer leaves scope.
pub fn stdout(io: Io, buffer: []u8) File.Writer {
    return File.stdout().writer(io, buffer);
}

/// Buffered writer over standard error, used for diagnostics that must not be
/// interleaved into machine-readable output on standard output.
pub fn stderr(io: Io, buffer: []u8) File.Writer {
    return File.stderr().writer(io, buffer);
}

/// Reads an entire file. Fails with `error.StreamTooLong` at `limit` rather
/// than growing without bound, because tools run against untrusted trees.
pub fn readFile(
    dir: Dir,
    io: Io,
    sub_path: []const u8,
    gpa: std.mem.Allocator,
    limit: Limit,
) ![]u8 {
    return dir.readFileAlloc(io, sub_path, gpa, limit);
}

pub fn writeFile(dir: Dir, io: Io, sub_path: []const u8, bytes: []const u8) !void {
    return dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

/// Command-line arguments, allocated from `gpa`.
pub fn args(init: Init, gpa: std.mem.Allocator) ![]const [:0]const u8 {
    return init.minimal.args.toSlice(gpa);
}

test "standard output is writable and flushes" {
    // Exercised for compile coverage of the adapter signatures; the tests run
    // with output captured, so the bytes are discarded by the harness.
    const io = std.testing.io;
    var buffer: [64]u8 = undefined;
    var writer = stdout(io, &buffer);
    try writer.interface.writeAll("");
    try writer.interface.flush();
}
