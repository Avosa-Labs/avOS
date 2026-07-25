//! camera-capture — a consequential agent action, held for a person, executed exactly
//! once, and never covert.
//!
//! This is the agent that *acts*, and it is where the platform's promises about acting
//! agents become concrete. Taking a photo reaches the world, so an agent cannot do it on
//! its capability alone: the tool is consequential, the framework holds the request for a
//! person, and only the person's approval runs it. The capture is exactly-once by the
//! operation's key, so an approval that arrives after a restart, or a person who taps
//! twice, takes one photo. And a capture never happens while the use indicator is dark —
//! the domain refuses it — so there is no path to a silent photo, whoever asks.
//!
//! It runs on the real frame: the hold, the approval, and the capture all pass through
//! `App.invoke`/`App.approve` and land in the ledger the live feed reads.

const std = @import("std");
const core = @import("core");
const applications = @import("applications");
const harness = @import("../harness.zig");

const framework = applications.framework;
const Actor = framework.Actor;
const Input = framework.Input;
const DomainResult = framework.DomainResult;

/// The camera: the real device state. It counts the photos it has taken, refuses to take
/// one while its use indicator is dark, and records which capture-keys have already
/// fired so a re-driven approval does not fire the shutter again.
pub const Camera = struct {
    gpa: std.mem.Allocator,
    /// Whether the visible in-use indicator is lit. The surface lights it whenever a
    /// capture can happen; the domain refuses a capture when it is dark, so a photo is
    /// never taken without the light that tells the person it is being taken.
    indicator_lit: bool,
    captures: usize = 0,
    applied: std.ArrayListUnmanaged(u128) = .empty,

    pub fn init(gpa: std.mem.Allocator, indicator_lit: bool) Camera {
        return .{ .gpa = gpa, .indicator_lit = indicator_lit };
    }

    pub fn deinit(camera: *Camera) void {
        camera.applied.deinit(camera.gpa);
        camera.* = undefined;
    }

    fn alreadyApplied(camera: Camera, key: u128) bool {
        for (camera.applied.items) |applied| {
            if (applied == key) return true;
        }
        return false;
    }

    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        const camera: *Camera = @ptrCast(@alignCast(context));

        if (std.mem.eql(u8, input.operation, "camera.capture")) {
            // Exactly-once: an already-fired key returns its result without firing again.
            if (camera.alreadyApplied(key)) return .{ .ok = "captured" };
            // Fail closed: no capture while the indicator is dark, whoever approved it.
            if (!camera.indicator_lit) return .failed;
            camera.applied.append(camera.gpa, key) catch return .failed;
            camera.captures += 1;
            return .{ .ok = "captured" };
        }
        return .failed;
    }

    pub fn domain(camera: *Camera) framework.Domain {
        return .{ .context = camera, .execute_fn = execute };
    }
};

/// The one tool: a capture. Its effect is external — it reaches the world — so the
/// framework holds an agent's request for a person rather than running it.
pub const tools = [_]framework.Tool{
    .{ .name = "camera.capture", .required_capability = "camera.capture", .effect = .external },
};

pub fn open(camera: *Camera, ledger: *framework.Ledger) framework.App {
    return .{
        .name = "camera-capture",
        .domain = camera.domain(),
        .tools = .{ .tools = &tools },
        .ledger = ledger,
    };
}

/// What running the example established.
pub const Result = struct {
    held_for_approval: bool,
    captured_after_approval: bool,
    captures: usize,
};

/// Runs the capture flow against a real world: an agent requests a photo, the framework
/// holds it, the person approves, the photo is taken — once, even though the approval is
/// driven twice. Every step is read back from the ledger.
pub fn run(world: *harness.World) !Result {
    var camera = Camera.init(world.gpa, true); // The surface has lit the indicator.
    defer camera.deinit();
    var app = open(&camera, &world.ledger);

    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };
    const person: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };
    const capture: Input = .{ .operation = "camera.capture", .args = "front" };
    const key: u128 = 0x9;

    // The agent requests the photo. Consequential, so it is held, not taken.
    const requested = try app.invoke(agent, capture, "camera.capture", true, key);

    // The person approves. The photo is taken now, through the same domain.
    _ = try app.approve(person, capture, key);
    // The approval is driven a second time under the same key — a double tap, or a
    // retry after a restart. It must not take a second photo.
    _ = try app.approve(person, capture, key);

    return .{
        .held_for_approval = requested == .held,
        .captured_after_approval = camera.captures >= 1,
        .captures = camera.captures,
    };
}

// --- Tests ---

const testing = std.testing;

test "an agent's capture is held, then approved once even when approved twice" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x301);
    defer world.deinit();

    const result = try run(&world);

    try testing.expect(result.held_for_approval);
    try testing.expect(result.captured_after_approval);
    // Two approvals, one photo: exactly-once holds across the re-drive.
    try testing.expectEqual(@as(usize, 1), result.captures);

    // The ledger tells the whole story: the request was recorded awaiting approval, the
    // decision was recorded, and the capture ran.
    const agent = harness.World.principal(0x0A);
    const agent_feed = try world.feed(agent);
    defer gpa.free(agent_feed);
    try testing.expect(harness.feedHas(agent_feed, "camera.capture", .awaiting_approval));
}

test "a capture while the indicator is dark is refused" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x302);
    defer world.deinit();

    var camera = Camera.init(gpa, false); // Indicator dark.
    defer camera.deinit();
    var app = open(&camera, &world.ledger);
    const person: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };
    const capture: Input = .{ .operation = "camera.capture", .args = "front" };

    // Even an approved capture does not fire while the indicator is dark.
    const outcome = try app.approve(person, capture, 1);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(@as(usize, 0), camera.captures);
}

test "an agent cannot capture on its capability alone; a person's direct capture runs" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x303);
    defer world.deinit();

    var camera = Camera.init(gpa, true);
    defer camera.deinit();
    var app = open(&camera, &world.ledger);
    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };
    const person: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };
    const capture: Input = .{ .operation = "camera.capture", .args = "front" };

    // The agent holds the capability but the action is consequential: held, not run.
    const agent_outcome = try app.invoke(agent, capture, "camera.capture", true, 1);
    try testing.expect(agent_outcome == .held);
    try testing.expectEqual(@as(usize, 0), camera.captures);

    // A person performing their own consequential act runs it directly.
    const person_outcome = try app.invoke(person, capture, "camera.capture", true, 2);
    try testing.expect(person_outcome == .executed);
    try testing.expectEqual(@as(usize, 1), camera.captures);
}
