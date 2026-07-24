//! The live shell: the designed UI rendered from a real control-plane run.
//!
//! This is where the render layer and the control plane meet. It runs the canonical scenario — the same
//! one the text simulator runs, with its real human and agents acting, one action denied and one held
//! for approval — and then renders the platform's designed activity screen directly from the audit
//! ledger that run produced. The rows on screen are not demonstration content; they are the actual
//! events the agents generated, each actor resolved to its real principal and coloured by its kind, each
//! outcome the outcome the authority model actually returned. So running this shows the design with the
//! real agents doing the real work inside it, rather than a text dump or a placeholder. The same bridge
//! extends to the other surfaces; the activity ledger is the clearest place to see the agents at work.
//!
//! Usage: shell [OUTPUT.png]  (defaults to shell.png)

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const simulator = @import("simulator");
const graphics = @import("graphics");
const design = @import("design");

const Host = simulator.host.Host;
const canonical = simulator.canonical;
const Framebuffer = graphics.framebuffer.Framebuffer;
const screens = graphics.screens;
const theme = design.theme;

/// The accent colour for a principal, by its kind — the same mapping the principals inspector uses.
fn kindColour(kind: anytype) theme.Colour {
    return switch (kind) {
        .human => theme.human,
        .agent => theme.agent,
        .application => theme.teal,
        .service => theme.amber,
        .organization => theme.coral,
        .device => theme.human,
        .session => theme.agent_soft,
    };
}

/// A readable phrase for an audit action.
fn actionText(action: anytype) []const u8 {
    return switch (action) {
        .authenticated => "authenticated",
        .capability_issued => "issued a capability",
        .capability_delegated => "delegated a capability",
        .capability_used => "used a capability",
        .capability_revoked => "revoked a capability",
        .capability_expired => "a capability expired",
        .task_created => "created a task",
        .task_transitioned => "advanced a task",
        .task_cancelled => "cancelled a task",
        .task_completed => "completed a task",
        .model_invoked => "invoked a model",
        .tool_invoked => "invoked a tool",
        .action_denied => "was denied",
        .approval_requested => "requested approval",
        .approval_decided => "decided an approval",
        else => "acted",
    };
}

const OutcomeView = struct { text: []const u8, denied: bool };

fn outcomeView(outcome: anytype) OutcomeView {
    return switch (outcome) {
        .succeeded => .{ .text = "ok", .denied = false },
        .denied => .{ .text = "denied", .denied = true },
        .awaiting_approval => .{ .text = "held", .denied = false },
        .cancelled => .{ .text = "cancelled", .denied = false },
        .failed => .{ .text = "failed", .denied = true },
        .outcome_unknown => .{ .text = "unknown", .denied = false },
    };
}

/// Whether an action is one worth surfacing on the activity screen — the agent-visible work, not the
/// internal bookkeeping.
fn surfaced(action: anytype) bool {
    return switch (action) {
        .capability_used, .action_denied, .approval_requested, .approval_decided, .task_completed, .model_invoked => true,
        else => false,
    };
}

const max_rows: usize = 7;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const output = if (args.len > 1) args[1] else "shell.png";

    // Run the real scenario: the agents act, one action is denied, one is held and approved.
    var host: Host = undefined;
    Host.init(&host, gpa, .{ .seed = 0x51 });
    defer host.deinit();
    _ = try canonical.run(&host);

    // Build the activity rows from the actual audit ledger this run produced.
    var rows: std.ArrayList(screens.LedgerRow) = .empty;
    defer rows.deinit(gpa);

    var index: usize = host.ledger.count();
    while (index > 0 and rows.items.len < max_rows) {
        index -= 1;
        const event = host.ledger.at(index) orelse continue;
        if (!surfaced(event.action)) continue;
        const actor = host.registry.lookup(event.actor) orelse continue;
        const is_human = actor.kind == .human;
        const outcome = outcomeView(event.outcome);
        const capability = if (event.target_kind.len > 0) event.target_kind else "capability";
        try rows.append(gpa, .{
            .actor = if (is_human) "You" else actor.display_name,
            .action = actionText(event.action),
            .capability = capability,
            .outcome = outcome.text,
            .colour = kindColour(actor.kind),
            .denied = outcome.denied,
        });
    }
    // The ledger was read newest-first; present it oldest-first as the screen reads top to bottom.
    std.mem.reverse(screens.LedgerRow, rows.items);

    var target = try Framebuffer.init(gpa, screens.width, screens.height, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 });
    defer target.deinit();
    screens.renderActivity(&target, rows.items);

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("shell: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}
