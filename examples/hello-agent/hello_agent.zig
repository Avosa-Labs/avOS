//! hello-agent — the smallest useful agent, and the first principal in the canonical
//! demonstration.
//!
//! It answers one question — "am I free then?" — and that is the whole point: it is the
//! baseline an agent that *acts* is measured against. It holds exactly one capability,
//! free/busy read on the calendar, and the platform holds it to that. Asked whether a
//! window is busy it learns only busy or free, never the title or the attendees, because
//! the detail tool requires a capability it was never granted and the registry refuses
//! the call before the domain sees it. Reading availability changes nothing outside the
//! device, so it runs with no approval gate — the contrast that makes the approval an
//! acting agent needs meaningful.
//!
//! This is a real program on the real frame, not a description of one. The read runs
//! through `App.invoke`, the same gate and record a shipped app uses; the refusal of the
//! detail read is a real registry denial written to the ledger; and `run` returns what
//! the ledger recorded, so a passing example is proof the path ran.

const std = @import("std");
const core = @import("core");
const applications = @import("applications");
const harness = @import("../harness.zig");

const framework = applications.framework;
const Actor = framework.Actor;
const Input = framework.Input;
const DomainResult = framework.DomainResult;

/// A window the calendar knows about. The example holds detail — a title — precisely so
/// there is something the free/busy agent must not be able to reach.
const Window = struct {
    slot: u8,
    title: []const u8,
};

/// The calendar the agent reads. It holds real events with real detail; the free/busy
/// door exposes only whether a slot is taken, and the detail door is a separate,
/// separately-authorized tool.
pub const Calendar = struct {
    windows: []const Window,

    fn busy(calendar: Calendar, slot: u8) bool {
        for (calendar.windows) |window| {
            if (window.slot == slot) return true;
        }
        return false;
    }

    /// The one entry point both a free/busy query and a detail query reach — the same
    /// shared domain. Which one the caller may run is decided by the capability gate in
    /// the framework, not here: the domain simply answers what it is asked.
    pub fn execute(context: *anyopaque, input: Input, actor: Actor, key: u128) DomainResult {
        _ = actor;
        _ = key; // A read has no effect to make exactly-once.
        const calendar: *Calendar = @ptrCast(@alignCast(context));

        if (std.mem.eql(u8, input.operation, "availability.free_busy")) {
            const slot = std.fmt.parseInt(u8, input.args, 10) catch return .failed;
            return .{ .ok = if (calendar.busy(slot)) "busy" else "free" };
        }
        if (std.mem.eql(u8, input.operation, "availability.detail")) {
            // Reached only if the caller presented the detail capability. The agent in
            // this example never can, so this path exists to be refused, not run.
            const slot = std.fmt.parseInt(u8, input.args, 10) catch return .failed;
            for (calendar.windows) |window| {
                if (window.slot == slot) return .{ .ok = window.title };
            }
            return .{ .ok = "free" };
        }
        return .failed;
    }

    pub fn domain(calendar: *Calendar) framework.Domain {
        return .{ .context = calendar, .execute_fn = execute };
    }
};

/// The tools the calendar publishes. Free/busy and detail are separate capabilities, so
/// holding one grants nothing of the other — the attenuation the example turns on.
pub const tools = [_]framework.Tool{
    .{ .name = "availability.free_busy", .required_capability = "calendar.free_busy", .effect = .read_only },
    .{ .name = "availability.detail", .required_capability = "calendar.detail", .effect = .read_only },
};

/// The capability the agent is granted — and the only one. It is not granted
/// `calendar.detail`, which is what confines it to free/busy.
pub const agent_capability = "calendar.free_busy";

pub fn open(calendar: *Calendar, ledger: *framework.Ledger) framework.App {
    return .{
        .name = "hello-agent",
        .domain = calendar.domain(),
        .tools = .{ .tools = &tools },
        .ledger = ledger,
    };
}

/// What running the example established, read back from the ledger.
pub const Result = struct {
    free_busy_answer: []const u8,
    detail_refused: bool,
};

/// Runs the agent against a real world: it asks whether a busy slot is free, then
/// reaches for the detail it does not hold. The first is answered; the second is refused
/// by the registry before the domain runs, and both facts come back from the ledger.
pub fn run(world: *harness.World) !Result {
    var calendar: Calendar = .{ .windows = &.{
        .{ .slot = 9, .title = "Budget review with Finance" },
        .{ .slot = 14, .title = "1:1 with Sam" },
    } };
    var app = open(&calendar, &world.ledger);

    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };

    // The granted read: is 9:00 free? The agent holds free/busy, so this runs.
    const free_busy = try app.invoke(
        agent,
        .{ .operation = "availability.free_busy", .args = "9" },
        agent_capability,
        true,
        0x01,
    );

    // The reach past its grant: read the detail of that window. The agent presents the
    // only capability it holds, which is not the one the detail tool requires, so the
    // registry denies the call before the domain is touched.
    const detail = try app.invoke(
        agent,
        .{ .operation = "availability.detail", .args = "9" },
        agent_capability,
        true,
        0x02,
    );

    return .{
        .free_busy_answer = switch (free_busy) {
            .executed => |bytes| bytes,
            else => "",
        },
        .detail_refused = detail == .denied,
    };
}

// --- Tests: the example is asserted against the ledger it wrote, not its return path ---

const testing = std.testing;

test "the agent learns busy, is refused detail, and the ledger shows both" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x101);
    defer world.deinit();

    const result = try run(&world);

    // The free/busy read succeeded and told the agent only that the slot is taken.
    try testing.expectEqualStrings("busy", result.free_busy_answer);
    // The detail read was refused.
    try testing.expect(result.detail_refused);

    // The ground truth: the ledger records the granted read succeeding and the detail
    // read denied. A person watching sees exactly this.
    const agent = harness.World.principal(0x0A);
    const feed = try world.feed(agent);
    defer gpa.free(feed);
    try testing.expect(harness.feedHas(feed, "availability.free_busy", .succeeded));
    try testing.expect(harness.feedHas(feed, "availability.detail", .denied));
}

test "free and busy are answered without revealing which event" {
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x102);
    defer world.deinit();

    var calendar: Calendar = .{ .windows = &.{.{ .slot = 9, .title = "secret" }} };
    var app = open(&calendar, &world.ledger);
    const agent: Actor = .{ .kind = .agent, .principal = harness.World.principal(0x0A) };

    const busy = try app.invoke(agent, .{ .operation = "availability.free_busy", .args = "9" }, agent_capability, true, 1);
    const free = try app.invoke(agent, .{ .operation = "availability.free_busy", .args = "10" }, agent_capability, true, 2);

    try testing.expectEqualStrings("busy", busy.executed);
    try testing.expectEqualStrings("free", free.executed);
    // Neither answer is the event title: free/busy never carries detail.
    try testing.expect(!std.mem.eql(u8, busy.executed, "secret"));
}

test "the detail capability the agent lacks would reach the detail, proving the confinement is the grant" {
    // Not the agent: a caller that *does* hold calendar.detail reaches the title. This
    // asserts the refusal above is the missing capability, not a missing tool.
    const gpa = testing.allocator;
    var world: harness.World = undefined;
    harness.World.init(gpa, &world, 0x103);
    defer world.deinit();

    var calendar: Calendar = .{ .windows = &.{.{ .slot = 9, .title = "Budget review" }} };
    var app = open(&calendar, &world.ledger);
    const holder: Actor = .{ .kind = .human, .principal = harness.World.principal(0x01) };

    const detail = try app.invoke(holder, .{ .operation = "availability.detail", .args = "9" }, "calendar.detail", true, 1);
    try testing.expectEqualStrings("Budget review", detail.executed);
}
