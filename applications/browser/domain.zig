//! The Browser domain: real navigation a person and their agents drive, over a page read through a
//! provider-neutral engine, with per-site permissions the person holds.
//!
//! This is the "one domain" both doors reach. It holds the person's history, the page they are on,
//! their bookmarks, and the permissions each site has been granted. A page is fetched through an
//! engine — an interface, so which web engine actually renders it is an adapter choice made elsewhere,
//! never part of the domain. The simulator's deterministic engine answers in CI and offline, derived
//! only from the URL, so a run is reproducible; a real WPE-backed adapter would implement the same
//! seam. Navigating and bookmarking are ordinary local changes. Reading the page returns only the
//! engine's projection — what the page is and how much it holds — never a way to sweep the raw
//! document. Granting a site a sensitive permission is the one consequential act: an agent proposing
//! it is held for the person, exactly-once, the same as any external effect.
//!
//! This module is the app's real logic and storage; the gating, holding, and recording are the
//! framework's.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");

pub const Actor = framework.Actor;
pub const DomainResult = framework.DomainResult;
pub const Input = framework.Input;

/// The kind of page the engine resolved a URL to — the projection an agent may read, not the raw
/// document.
pub const PageKind = enum { article, search, video, shop, docs };

/// A sensitive capability a site can be granted. These are the permissions a website asks for; an
/// agent cannot grant one on the person's behalf without the person approving.
pub const Permission = enum { location, camera, notifications };

/// The engine's projection of a page: the URL that was loaded, what kind of page it is, and roughly
/// how much it holds. This is all a reading agent sees — never the document itself.
pub const Page = struct {
    url: []const u8,
    kind: PageKind,
    words: u32,
};

/// The provider-neutral engine the domain reads pages through. A real web-engine adapter or the
/// simulator's deterministic engine implements it; the engine's identity never enters the domain.
pub const Engine = struct {
    context: *anyopaque,
    load_fn: *const fn (context: *anyopaque, url: []const u8) Page,

    pub fn load(engine: Engine, url: []const u8) Page {
        return engine.load_fn(engine.context, url);
    }
};

/// A deterministic engine for CI and offline: it derives a stable projection from the URL alone, so
/// the same address always resolves the same and a run is reproducible.
pub const Deterministic = struct {
    var unused: u8 = 0;

    fn load(_: *anyopaque, url: []const u8) Page {
        var hash: u32 = 2166136261;
        for (url) |byte| hash = (hash ^ byte) *% 16777619;
        return .{
            .url = url,
            .kind = @enumFromInt(hash % @typeInfo(PageKind).@"enum".fields.len),
            .words = 200 + (hash % 4000),
        };
    }

    /// The engine handle for the deterministic provider.
    pub fn engine() Engine {
        return .{ .context = &unused, .load_fn = load };
    }
};

/// The origin of a URL — its scheme and host, up to the first path separator. Permissions attach to
/// the origin, not the full URL, so a grant covers a whole site rather than one page.
pub fn originOf(url: []const u8) []const u8 {
    // Find the "://" so the scheme stays part of the origin; a URL without one is its own origin
    // up to the first slash.
    var host_start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| host_start = scheme_end + 3;
    if (std.mem.indexOfScalarPos(u8, url, host_start, '/')) |slash| return url[0..slash];
    return url;
}

const Grant = struct { origin: []const u8, permission: Permission };
const Applied = struct { key: u128, result: []const u8 };

pub const Store = struct {
    gpa: std.mem.Allocator,
    engine: Engine,
    history: std.ArrayListUnmanaged([]const u8) = .empty,
    bookmarks: std.ArrayListUnmanaged([]const u8) = .empty,
    grants: std.ArrayListUnmanaged(Grant) = .empty,
    applied: std.ArrayListUnmanaged(Applied) = .empty,
    current: ?Page = null,
    reply: [48]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, engine: Engine) Store {
        return .{ .gpa = gpa, .engine = engine };
    }

    pub fn deinit(store: *Store) void {
        store.history.deinit(store.gpa);
        store.bookmarks.deinit(store.gpa);
        store.grants.deinit(store.gpa);
        store.applied.deinit(store.gpa);
        store.* = undefined;
    }

    pub fn historyCount(store: Store) usize {
        return store.history.items.len;
    }

    pub fn isBookmarked(store: Store, url: []const u8) bool {
        for (store.bookmarks.items) |b| if (std.mem.eql(u8, b, url)) return true;
        return false;
    }

    /// Whether a site has been granted a permission — the real per-origin permission state.
    pub fn hasPermission(store: Store, url: []const u8, permission: Permission) bool {
        const origin = originOf(url);
        for (store.grants.items) |g| {
            if (g.permission == permission and std.mem.eql(u8, g.origin, origin)) return true;
        }
        return false;
    }

    fn priorResult(store: *Store, key: u128) ?[]const u8 {
        for (store.applied.items) |e| if (e.key == key) return e.result;
        return null;
    }

    fn commit(store: *Store, key: u128, result: []const u8) DomainResult {
        store.applied.append(store.gpa, .{ .key = key, .result = result }) catch return .failed;
        return .{ .ok = result };
    }

    /// The one entry point both doors reach. `args` is a URL, or "url|permission" for a grant.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const store: *Store = @ptrCast(@alignCast(context));
        const op = input.operation;

        // Reading the page returns only the engine's projection — what the page is and how much it
        // holds — never the document. Silent, so it may be repeated freely.
        if (std.mem.eql(u8, op, "browser.read_page")) {
            const page = store.current orelse return .failed;
            const text = std.fmt.bufPrint(&store.reply, "{s} {d}w", .{ @tagName(page.kind), page.words }) catch return .failed;
            return .{ .ok = text };
        }

        // Changes are exactly-once by key.
        if (store.priorResult(key)) |prior| return .{ .ok = prior };

        if (std.mem.eql(u8, op, "browser.open")) {
            if (input.args.len == 0) return .failed;
            const page = store.engine.load(input.args);
            store.current = page;
            store.history.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "opened");
        }
        if (std.mem.eql(u8, op, "browser.bookmark")) {
            if (input.args.len == 0) return .failed;
            if (!store.isBookmarked(input.args)) store.bookmarks.append(store.gpa, input.args) catch return .failed;
            return store.commit(key, "bookmarked");
        }
        if (std.mem.eql(u8, op, "browser.grant_site")) {
            // Granting a site a sensitive permission is the consequential act — the frame holds an
            // agent's proposal for the person. `args` is "url|permission".
            const bar = std.mem.indexOfScalar(u8, input.args, '|') orelse return .failed;
            const url = input.args[0..bar];
            const permission = std.meta.stringToEnum(Permission, input.args[bar + 1 ..]) orelse return .failed;
            const origin = originOf(url);
            if (!store.hasPermission(url, permission)) {
                store.grants.append(store.gpa, .{ .origin = origin, .permission = permission }) catch return .failed;
            }
            return store.commit(key, "granted");
        }
        return .failed;
    }

    pub fn domain(store: *Store) framework.Domain {
        return .{ .context = store, .execute_fn = execute };
    }
};

// --- Tests ---

const testing = std.testing;

fn agent() Actor {
    return .{ .kind = .agent, .principal = .{ .value = 0xA } };
}

fn fixture() Store {
    return Store.init(testing.allocator, Deterministic.engine());
}

test "the deterministic engine resolves a URL the same way every time" {
    const a = Deterministic.engine().load("https://lisbon.example/guide");
    const b = Deterministic.engine().load("https://lisbon.example/guide");
    try testing.expectEqual(a.kind, b.kind);
    try testing.expectEqual(a.words, b.words);
    // A different URL resolves differently.
    const other = Deterministic.engine().load("https://porto.example/");
    try testing.expect(a.kind != other.kind or a.words != other.words);
}

test "an origin is the scheme and host, so a grant covers the whole site" {
    try testing.expectEqualStrings("https://lisbon.example", originOf("https://lisbon.example/guide/day-1"));
    try testing.expectEqualStrings("https://porto.example", originOf("https://porto.example"));
}

test "opening a page records history and lets the page be read as a projection" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "browser.open", .args = "https://lisbon.example/guide" }, agent(), 1);
    try testing.expectEqual(@as(usize, 1), store.historyCount());
    // The read returns the projection, not the document.
    const read = Store.execute(&store, .{ .operation = "browser.read_page", .args = "" }, agent(), 0);
    switch (read) {
        .ok => |text| try testing.expect(text.len > 0),
        .failed => return error.TestUnexpectedResult,
    }
    // Reading with nothing open fails.
    var empty = fixture();
    defer empty.deinit();
    try testing.expectEqual(DomainResult.failed, Store.execute(&empty, .{ .operation = "browser.read_page", .args = "" }, agent(), 0));
}

test "a change is exactly-once by key" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "browser.open", .args = "https://lisbon.example/" }, agent(), 7);
    _ = Store.execute(&store, .{ .operation = "browser.open", .args = "https://lisbon.example/" }, agent(), 7); // same key
    try testing.expectEqual(@as(usize, 1), store.historyCount());
}

test "bookmarking a page adds it once" {
    var store = fixture();
    defer store.deinit();
    _ = Store.execute(&store, .{ .operation = "browser.bookmark", .args = "https://lisbon.example/" }, agent(), 1);
    _ = Store.execute(&store, .{ .operation = "browser.bookmark", .args = "https://lisbon.example/" }, agent(), 2); // same page, different key
    try testing.expect(store.isBookmarked("https://lisbon.example/"));
    try testing.expectEqual(@as(usize, 1), store.bookmarks.items.len);
}

test "granting a site a permission marks the whole origin, exactly once" {
    var store = fixture();
    defer store.deinit();
    try testing.expect(!store.hasPermission("https://lisbon.example/guide", .location));
    _ = Store.execute(&store, .{ .operation = "browser.grant_site", .args = "https://lisbon.example/guide|location" }, agent(), 1);
    try testing.expect(store.hasPermission("https://lisbon.example/guide", .location));
    // The grant is on the origin, so another page on the same site is covered too.
    try testing.expect(store.hasPermission("https://lisbon.example/day-2", .location));
    // A different permission is not implied.
    try testing.expect(!store.hasPermission("https://lisbon.example/guide", .camera));
}
