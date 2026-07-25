//! The lifecycle of an Android application on the device: the states it moves
//! through and the rule that one application's crash is contained to itself.
//!
//! An Android application is installed, launched, runs, and stops — and sometimes
//! crashes. The host needs a single account of which state each application is in,
//! because the answer gates everything else: an application that is not running
//! cannot be sent an intent, one that is crashed must be relaunched before it is used
//! again, one that was never installed cannot be launched at all. The property that
//! matters most is containment: a crash moves exactly one application to a crashed
//! state and touches no other, so a misbehaving application cannot take its neighbours
//! or the host down with it. This module holds that state machine and enforces its
//! transitions, refusing the ones that do not make sense — launching what is not
//! installed, stopping what is not running — so an impossible transition is an error
//! here rather than an inconsistent state later.
//!
//! It tracks state and validates transitions; it launches no process. Starting and
//! stopping the underlying Android runtime is the host's, driven by the transitions
//! this module admits.

const std = @import("std");
const core = @import("core");

const identity = core.identity;

/// Where an application is in its lifecycle.
pub const State = enum {
    /// Installed but not running.
    installed,
    /// Launching: the runtime is starting it.
    launching,
    /// Running normally.
    running,
    /// Stopped cleanly and may be launched again.
    stopped,
    /// Ended in a crash. Must be relaunched before use; its crash touched nothing
    /// else.
    crashed,
};

pub const Error = error{
    /// The application is not in a state from which this transition is valid.
    InvalidTransition,
};

/// One managed Android application and its lifecycle state.
pub const Application = struct {
    /// The host principal the application acts as. Distinct from its Android package
    /// identity, which never authorizes anything.
    id: identity.PrincipalId,
    package: []const u8,
    state: State = .installed,
    /// Times this application has crashed. A rising count marks an application worth
    /// a person's attention.
    crashes: u32 = 0,

    pub fn isRunning(application: Application) bool {
        return application.state == .running;
    }

    /// Begins launching. Valid only from installed, stopped, or a prior crash — an
    /// already-running or launching application is not launched again.
    pub fn launch(application: *Application) Error!void {
        switch (application.state) {
            .installed, .stopped, .crashed => application.state = .launching,
            .launching, .running => return error.InvalidTransition,
        }
    }

    /// Confirms a launching application is now running.
    pub fn markRunning(application: *Application) Error!void {
        if (application.state != .launching) return error.InvalidTransition;
        application.state = .running;
    }

    /// Stops a running application cleanly.
    pub fn stop(application: *Application) Error!void {
        if (application.state != .running and application.state != .launching) {
            return error.InvalidTransition;
        }
        application.state = .stopped;
    }

    /// Records that the application crashed. Valid from any live state; a crash is
    /// not something the application chooses, so it is never refused, only counted.
    /// It moves only this application, which is the containment property.
    pub fn markCrashed(application: *Application) void {
        application.state = .crashed;
        application.crashes += 1;
    }
};

/// Tracks the lifecycle of every managed Android application.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    applications: std.ArrayListUnmanaged(*Application) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(registry: *Registry) void {
        for (registry.applications.items) |application| registry.gpa.destroy(application);
        registry.applications.deinit(registry.gpa);
        registry.* = undefined;
    }

    pub fn install(registry: *Registry, id: identity.PrincipalId, package: []const u8) !*Application {
        const application = try registry.gpa.create(Application);
        errdefer registry.gpa.destroy(application);
        application.* = .{ .id = id, .package = package };
        try registry.applications.append(registry.gpa, application);
        return application;
    }

    pub fn find(registry: *Registry, package: []const u8) ?*Application {
        for (registry.applications.items) |application| {
            if (std.mem.eql(u8, application.package, package)) return application;
        }
        return null;
    }

    /// How many applications are currently running.
    pub fn runningCount(registry: Registry) usize {
        var count: usize = 0;
        for (registry.applications.items) |application| {
            if (application.isRunning()) count += 1;
        }
        return count;
    }
};

// --- Tests ---

const testing = std.testing;

fn idFor(value: u128) identity.PrincipalId {
    return .{ .value = value };
}

test "an application launches, runs, and stops through valid transitions" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const app = try registry.install(idFor(1), "com.example.reader");
    try app.launch();
    try app.markRunning();
    try testing.expect(app.isRunning());
    try app.stop();
    try testing.expectEqual(State.stopped, app.state);
}

test "launching an already-running application is refused" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const app = try registry.install(idFor(1), "com.example.reader");
    try app.launch();
    try app.markRunning();
    try testing.expectError(error.InvalidTransition, app.launch());
}

test "one application's crash moves only itself and leaves its neighbour running" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const one = try registry.install(idFor(1), "com.example.one");
    const two = try registry.install(idFor(2), "com.example.two");
    try one.launch();
    try one.markRunning();
    try two.launch();
    try two.markRunning();

    one.markCrashed();
    try testing.expectEqual(State.crashed, one.state);
    try testing.expectEqual(@as(u32, 1), one.crashes);
    // The neighbour is untouched by its sibling's crash.
    try testing.expect(two.isRunning());
    try testing.expectEqual(@as(usize, 1), registry.runningCount());
}

test "a crashed application can be relaunched" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const app = try registry.install(idFor(1), "com.example.reader");
    try app.launch();
    try app.markRunning();
    app.markCrashed();
    // A crash is a valid state to launch from.
    try app.launch();
    try app.markRunning();
    try testing.expect(app.isRunning());
}

test "stopping an application that is not running is refused" {
    const gpa = testing.allocator;
    var registry = Registry.init(gpa);
    defer registry.deinit();

    const app = try registry.install(idFor(1), "com.example.reader");
    try testing.expectError(error.InvalidTransition, app.stop());
}
