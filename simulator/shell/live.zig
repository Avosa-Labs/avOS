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
const applications = @import("applications");

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

/// A short role phrase for a principal kind, shown in the inspector.
fn roleText(kind: anytype) []const u8 {
    return switch (kind) {
        .human => "Full authority",
        .agent => "Scoped, revocable",
        .application => "Sandboxed",
        .service => "Reached via bridge",
        .organization => "Managed policy",
        .device => "Trusted endpoint",
        .session => "Ephemeral, isolated",
    };
}

fn kindName(kind: anytype) []const u8 {
    return switch (kind) {
        .human => "Human",
        .agent => "Agent",
        .application => "Application",
        .service => "Service",
        .organization => "Organization",
        .device => "Device",
        .session => "Session",
    };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    // shell <activity|principals|store> [out.png]
    const which = if (args.len > 1) args[1] else "activity";
    const output = if (args.len > 2) args[2] else "shell.png";

    // Run the real scenario: the agents act, one action is denied, one is held and approved.
    var host: Host = undefined;
    Host.init(&host, gpa, .{ .seed = 0x51 });
    defer host.deinit();
    _ = try canonical.run(&host);

    var target = try Framebuffer.init(gpa, screens.width, screens.height, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = 255 });
    defer target.deinit();

    // Session mode: render the whole live session as a numbered sequence of frames, from one run.
    if (std.mem.eql(u8, which, "session")) {
        const prefix = if (args.len > 2) args[2] else "session_";
        return renderSession(gpa, io, err, &host, prefix);
    }

    if (std.mem.eql(u8, which, "principals")) {
        try renderLivePrincipals(gpa, &target, &host);
    } else if (std.mem.eql(u8, which, "store")) {
        renderLiveStore(&target);
    } else if (std.mem.eql(u8, which, "home")) {
        graphics.home.render(&target);
    } else if (std.mem.eql(u8, which, "boot")) {
        renderBoot(&target);
    } else if (std.mem.eql(u8, which, "rest")) {
        renderRest(&target);
    } else {
        try renderLiveActivity(gpa, &target, &host);
    }

    const png = try target.encodePng(gpa);
    defer gpa.free(png);
    io_adapters.writeFile(io_adapters.cwd(), io, output, png) catch {
        try err.print("shell: cannot write '{s}'\n", .{output});
        try err.flush();
        return 1;
    };
    return 0;
}

const paint = graphics.paint;
const vector = graphics.vector;
const text = graphics.text;
const w: u32 = screens.width;
const h: u32 = screens.height;

fn renderBoot(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .colour = paint.sample(theme.base) } }});
    var g: u8 = 0;
    while (g < 4) : (g += 1) {
        const r = @as(f32, @floatFromInt(260 - @as(u32, g) * 50));
        vector.fillDisc(target, @floatFromInt(w / 2), @floatFromInt(h / 2), r, .{ .r = theme.agent.red, .g = theme.agent.green, .b = theme.agent.blue, .a = 18 });
    }
    text.drawCentred(target, @floatFromInt(w / 2), @floatFromInt(h / 2 + 6), "Starting your world", 16, paint.sample(theme.text_primary));
}

fn renderRest(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .vgradient = .{ .rect = .{ .x = 0, .y = 0, .w = w, .h = h }, .top = paint.sample(theme.panel), .bottom = paint.sample(theme.base) } }});
    text.drawCentred(target, @floatFromInt(w / 2), @floatFromInt(h / 2 - 8), "Everything handled.", 18, paint.sample(theme.text_primary));
    text.drawCentred(target, @floatFromInt(w / 2), @floatFromInt(h / 2 + 24), "Hello, world.", 14, paint.sample(theme.text_secondary));
}

/// The session, as the actual OS plays it: boot, home, then the live agent-native surfaces produced by
/// this run, then rest — each written as a numbered frame under `prefix`.
fn renderSession(gpa: std.mem.Allocator, io: anytype, err: anytype, host: *Host, prefix: []const u8) !u8 {
    const Frame = struct { name: []const u8, kind: enum { boot, home, activity, principals, store, rest } };
    const frames = [_]Frame{
        .{ .name = "00_boot", .kind = .boot },
        .{ .name = "01_home", .kind = .home },
        .{ .name = "02_activity", .kind = .activity },
        .{ .name = "03_principals", .kind = .principals },
        .{ .name = "04_store", .kind = .store },
        .{ .name = "05_rest", .kind = .rest },
    };
    for (frames) |frame| {
        var target = try Framebuffer.init(gpa, w, h, paint.sample(theme.base));
        defer target.deinit();
        switch (frame.kind) {
            .boot => renderBoot(&target),
            .home => graphics.home.render(&target),
            .activity => try renderLiveActivity(gpa, &target, host),
            .principals => try renderLivePrincipals(gpa, &target, host),
            .store => renderLiveStore(&target),
            .rest => renderRest(&target),
        }
        const png = try target.encodePng(gpa);
        defer gpa.free(png);
        const path = try std.fmt.allocPrint(gpa, "{s}{s}.png", .{ prefix, frame.name });
        defer gpa.free(path);
        io_adapters.writeFile(io_adapters.cwd(), io, path, png) catch {
            try err.print("shell: cannot write '{s}'\n", .{path});
            try err.flush();
            return 1;
        };
    }
    return 0;
}

/// Renders the activity screen from the run's real audit ledger.
fn renderLiveActivity(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host) !void {
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
    std.mem.reverse(screens.LedgerRow, rows.items);
    screens.renderActivity(target, rows.items);
}

/// Renders the principals inspector from the run's real registry — the human and each enrolled agent.
fn renderLivePrincipals(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host) !void {
    var list: std.ArrayList(screens.Principal) = .empty;
    defer list.deinit(gpa);

    if (host.registry.lookup(host.human)) |human| {
        try list.append(gpa, .{ .kind = kindName(human.kind), .name = "You", .role = roleText(human.kind), .colour = kindColour(human.kind) });
    }
    for (host.agents.items) |agent| {
        const principal = host.registry.lookup(agent.id) orelse continue;
        try list.append(gpa, .{
            .kind = kindName(principal.kind),
            .name = principal.display_name,
            .role = roleText(principal.kind),
            .colour = kindColour(principal.kind),
        });
    }
    screens.renderPrincipalsScreen(target, list.items);
}

/// Renders the store catalog, each entry's install action decided by the real store decision module.
fn renderLiveStore(target: *Framebuffer) void {
    const install_source = applications.store;
    // Each catalog entry carries a real source; the action shown is the real install decision.
    const Catalog = struct { name: []const u8, publisher: []const u8, source: install_source.Source, acknowledged: bool, colour: design.theme.Colour };
    const catalog = [_]Catalog{
        .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.teal },
        .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.agent },
        .{ .name = "Field Tools", .publisher = "Outside source", .source = .external, .acknowledged = true, .colour = theme.amber },
        .{ .name = "Unknown Build", .publisher = "Unreviewed source", .source = .external, .acknowledged = false, .colour = theme.denied },
        .{ .name = "Trip Planner", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.coral },
    };

    var entries: [catalog.len]screens.StoreEntry = undefined;
    for (catalog, 0..) |item, i| {
        // The real decision: store apps proceed, an acknowledged external source proceeds, an
        // unacknowledged external one is held for acknowledgement.
        const decision = install_source.decide(item.source, item.acknowledged);
        const action: screens.StoreAction = switch (decision) {
            .proceed => .get,
            .require_acknowledgement => .acknowledge,
            .refuse => .blocked,
        };
        const badge: []const u8 = switch (item.source) {
            .store => "Reviewed",
            .external => if (item.acknowledged) "Acknowledged" else "Sideload",
        };
        entries[i] = .{ .name = item.name, .publisher = item.publisher, .badge = badge, .action = action, .colour = item.colour };
    }
    screens.renderStoreScreen(target, &entries);
}
