//! Verifies that a default app reaches the system only through its framework, never
//! by importing a control-plane or agent-plane module directly.
//!
//! The whole integrity of the agent-native app model rests on one boundary: an app's
//! logic goes through the shared frame, which is the single place capability checks,
//! ledger writes, and approval holds happen. If an app file could import the capability
//! store, the audit ledger, the services, or the agent plane on its own, it could act
//! outside that frame — perform an operation the framework never gated, or write the
//! ledger the feed trusts without the gate that makes the write meaningful. That is the
//! door back to simulation. So an app's files may import only their sibling files and
//! the framework; the framework alone imports the core and agent-plane clients it needs.
//! This check enforces that: a control-plane or agent-plane import inside an app is a
//! build error, caught before the app ships, not a boundary that erodes one app at a
//! time.
//!
//! Exit codes: 0 clean, 1 a boundary violation found.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The tree of default apps. Every file under here is an app file, except the framework
/// itself, which is the one place the boundary is crossed on purpose.
const scanned_root = "applications";

/// Prefixes exempt from the boundary. The framework is the frame apps reach the system
/// through, so it alone imports the core and agent-plane clients; the acceptance tests
/// stand up a real ledger to check the framework and are not shipped app code.
const exempt_prefixes = [_][]const u8{
    "framework/",
    "tests/",
};

const max_scanned_file_bytes: usize = 4 * 1024 * 1024;

/// Module imports an app file must not make directly. Reaching any of these outside the
/// framework is acting outside the frame that gates and records.
const forbidden_imports = [_][]const u8{
    "@import(\"core\")",
    "@import(\"services\")",
    "@import(\"agents\")",
    "@import(\"ipc\")",
    "@import(\"kernel\")",
    "@import(\"hardware\")",
};

const Finding = struct {
    path: []const u8,
    line: usize,
    import: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    var root = try io_adapters.cwd().openDir(io, scanned_root, .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // The framework and the acceptance tests are exempt crossing points.
        var exempt = false;
        for (exempt_prefixes) |prefix| {
            if (std.mem.startsWith(u8, entry.path, prefix)) exempt = true;
        }
        if (exempt) continue;

        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(max_scanned_file_bytes)) catch |read_error| switch (read_error) {
            error.StreamTooLong => continue,
            else => return read_error,
        };
        defer gpa.free(contents);

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            for (forbidden_imports) |forbidden| {
                if (std.mem.indexOf(u8, line, forbidden) == null) continue;
                const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ scanned_root, entry.path });
                try findings.append(gpa, .{ .path = full, .line = line_number, .import = forbidden });
                break;
            }
        }
    }

    if (findings.items.len == 0) {
        try out.writeAll("boundary-check: every app reaches the system only through its framework\n");
        try out.flush();
        return 0;
    }
    for (findings.items) |finding| {
        try out.print("{s}:{d}: an app imports {s} directly; reach the system through the framework\n", .{ finding.path, finding.line, finding.import });
    }
    try out.print("boundary-check: {d} boundary violation(s)\n", .{findings.items.len});
    try out.flush();
    return 1;
}
