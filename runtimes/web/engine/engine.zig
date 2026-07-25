//! The web engine seam: which origins share a render process and which are isolated
//! into their own, so a compromise in one site's content cannot reach another's.
//!
//! A browser engine runs untrusted content from many origins, and the boundary that
//! matters is the process: content from two origins that share an address space can,
//! if one is compromised, read the other's secrets. Site isolation is the answer —
//! each site gets its own render process, so a memory-safety break in one site's
//! content is confined to that site. This module owns the decision of which origins
//! belong to which isolation group: two pages of the same site coexist in one
//! process, while a cross-site frame is split into its own. A page that hosts a frame
//! from another site does not get to run that frame's code in its own process, which
//! is exactly the confusion site isolation exists to prevent.
//!
//! It decides isolation and assigns processes; it renders nothing. Spawning the real
//! render process and enforcing the address-space boundary is the host's, on the
//! grouping this module computes.

const std = @import("std");

/// An origin: the scheme and host that identify where content came from. The unit
/// the same-origin policy is stated over.
pub const Origin = struct {
    scheme: []const u8,
    host: []const u8,

    pub fn eql(origin: Origin, other: Origin) bool {
        return std.mem.eql(u8, origin.scheme, other.scheme) and
            std.mem.eql(u8, origin.host, other.host);
    }

    /// The registrable site an origin belongs to, for site isolation. Here the site
    /// is the scheme-and-host pair; a real engine would fold subdomains of one
    /// registrable domain together, but the isolation rule is the same: same site,
    /// same process; different site, different process.
    pub fn sameSite(origin: Origin, other: Origin) bool {
        return origin.eql(other);
    }
};

/// A render process hosting content from one site.
pub const Process = struct {
    id: u32,
    /// The site this process is dedicated to. Only same-site content may join it.
    site: Origin,
    /// Frames currently hosted in this process.
    frames: u32 = 0,
};

pub const Error = error{
    /// No more render processes may be created; the engine is at its process ceiling.
    ProcessLimitReached,
};

/// Assigns origins to isolated render processes, one site per process.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    processes: std.ArrayListUnmanaged(Process) = .empty,
    next_id: u32 = 1,
    /// A ceiling on render processes, so a page opening endless cross-site frames
    /// cannot exhaust the host by forcing an unbounded number of processes.
    max_processes: u32 = 128,

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .gpa = gpa };
    }

    pub fn deinit(engine: *Engine) void {
        engine.processes.deinit(engine.gpa);
        engine.* = undefined;
    }

    /// Returns the process that should host content from `origin`, reusing the one
    /// dedicated to its site or creating a new one. Same-site content shares a
    /// process; cross-site content is isolated into its own.
    pub fn processFor(engine: *Engine, origin: Origin) Error!*Process {
        for (engine.processes.items) |*process| {
            if (process.site.sameSite(origin)) return process;
        }
        if (engine.processes.items.len >= engine.max_processes) return error.ProcessLimitReached;
        const id = engine.next_id;
        engine.processes.append(engine.gpa, .{ .id = id, .site = origin }) catch return error.ProcessLimitReached;
        engine.next_id += 1;
        return &engine.processes.items[engine.processes.items.len - 1];
    }

    /// Hosts a frame of `origin`, returning the process it was placed in. A cross-site
    /// frame lands in a different process from its host page — the isolation boundary.
    pub fn hostFrame(engine: *Engine, origin: Origin) Error!*Process {
        const process = try engine.processFor(origin);
        process.frames += 1;
        return process;
    }

    pub fn processCount(engine: Engine) usize {
        return engine.processes.items.len;
    }
};

// --- Tests ---

const testing = std.testing;

const site_a: Origin = .{ .scheme = "https", .host = "a.example" };
const site_a_page2: Origin = .{ .scheme = "https", .host = "a.example" };
const site_b: Origin = .{ .scheme = "https", .host = "b.example" };
const site_a_http: Origin = .{ .scheme = "http", .host = "a.example" };

test "same-site content shares one render process" {
    const gpa = testing.allocator;
    var engine = Engine.init(gpa);
    defer engine.deinit();

    const first = try engine.hostFrame(site_a);
    const second = try engine.hostFrame(site_a_page2);
    try testing.expectEqual(first.id, second.id);
    try testing.expectEqual(@as(usize, 1), engine.processCount());
    try testing.expectEqual(@as(u32, 2), first.frames);
}

test "a cross-site frame is isolated into its own process" {
    const gpa = testing.allocator;
    var engine = Engine.init(gpa);
    defer engine.deinit();

    const page = try engine.hostFrame(site_a);
    const frame = try engine.hostFrame(site_b);
    try testing.expect(page.id != frame.id);
    try testing.expectEqual(@as(usize, 2), engine.processCount());
}

test "a different scheme is a different site" {
    const gpa = testing.allocator;
    var engine = Engine.init(gpa);
    defer engine.deinit();

    const secure = try engine.hostFrame(site_a);
    const insecure = try engine.hostFrame(site_a_http);
    try testing.expect(secure.id != insecure.id);
}

test "the process ceiling bounds cross-site frame explosion" {
    const gpa = testing.allocator;
    var engine = Engine.init(gpa);
    engine.max_processes = 2;
    defer engine.deinit();

    _ = try engine.hostFrame(.{ .scheme = "https", .host = "one.example" });
    _ = try engine.hostFrame(.{ .scheme = "https", .host = "two.example" });
    try testing.expectError(error.ProcessLimitReached, engine.hostFrame(.{ .scheme = "https", .host = "three.example" }));
}
