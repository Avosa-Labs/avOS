//! The examples, run together, are the canonical demonstration in miniature.
//!
//! Each SDK example proves one beat on its own. Run against a single shared ledger, in
//! sequence, they are the whole story the platform exists to tell: a least-authority
//! agent reads and is refused what it did not ask for; a person and an agent both act on
//! one shared domain; an agent's consequential act is held, approved by the person, and
//! run exactly once. This acceptance test runs the real example programs — not stand-ins
//! for them — and then reads the one ledger they all wrote, asserting the recorded events
//! are the demonstration. Because the feed is read from that ledger rather than reported
//! by the examples, a passing run is evidence the real path executed: the demo is the
//! real thing running, watched through the record that gated it.

const std = @import("std");
const examples = @import("examples");

const harness = examples.harness;
const World = harness.World;

test "the three examples run for real against one ledger and the ledger is the demo" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    World.init(gpa, &world, 0xDECA);
    defer world.deinit();

    // Beat one: least authority. The agent reads free/busy and is refused detail.
    const hello = try examples.hello_agent.run(&world);
    try std.testing.expectEqualStrings("busy", hello.free_busy_answer);
    try std.testing.expect(hello.detail_refused);

    // Beat two: one domain, two doors. A person and an agent both act; the retry is
    // absorbed; the ledger carries both principals.
    const todo = try examples.todo_app.run(&world);
    try std.testing.expectEqual(@as(usize, 2), todo.item_count);
    try std.testing.expect(todo.human_and_agent_both_in_feed);

    // Beat three: a consequential act, held and approved once.
    const camera = try examples.camera_capture.run(&world);
    try std.testing.expect(camera.held_for_approval);
    try std.testing.expectEqual(@as(usize, 1), camera.captures);

    // The ledger is the demonstration. Read back, it shows the whole sequence: the
    // granted read, the refused reach past authority, the two-door mutation, the held
    // request, and the capture that ran on approval.
    const agent = World.principal(0x0A);
    const agent_feed = try world.feed(agent);
    defer gpa.free(agent_feed);
    try std.testing.expect(harness.feedHas(agent_feed, "availability.free_busy", .succeeded));
    try std.testing.expect(harness.feedHas(agent_feed, "availability.detail", .denied));
    try std.testing.expect(harness.feedHas(agent_feed, "todo.add", .succeeded));
    try std.testing.expect(harness.feedHas(agent_feed, "camera.capture", .awaiting_approval));

    // The denial is visible in the ledger's denials, as a person watching would see it.
    const denials = try world.denials();
    defer gpa.free(denials);
    try std.testing.expect(harness.feedHas(denials, "availability.detail", .denied));
}
