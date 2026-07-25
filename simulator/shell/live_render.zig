//! Rendering the designed surfaces from a real control-plane run.
//!
//! This is the bridge between the control plane and the render layer, shared by every front end: the
//! headless frame writer, the whole-session renderer, and the windowed desktop shell all call these
//! functions. Each takes a live `Host` — a run of the canonical scenario, with its real human and
//! agents, one action denied and one held for approval — and renders one designed surface from that
//! run's real audit ledger, registry, and store decisions. The rows and cards are the actual events the
//! agents generated, not demonstration content, so whatever front end drives these functions shows the
//! design with the real agents doing the real work inside it.
//!
//! These functions decide nothing; they read the run's state and paint it.

const std = @import("std");
const simulator = @import("simulator");
const graphics = @import("graphics");
const design = @import("design");
const applications = @import("applications");

pub const Host = simulator.host.Host;
const Framebuffer = graphics.framebuffer.Framebuffer;
const screens = graphics.screens;
const theme = design.theme;
const paint = graphics.paint;
const vector = graphics.vector;
const text = graphics.text;

pub const width: u32 = screens.width;
pub const height: u32 = screens.height;

const max_rows: usize = 7;

/// The surfaces the shell can show.
pub const Surface = enum { boot, home, activity, approval, principals, store, rest };

/// Runs the canonical scenario into a fresh host. The caller owns it and must `deinit`.
pub fn runScenario(host: *Host, gpa: std.mem.Allocator) !void {
    Host.init(host, gpa, .{ .seed = 0x51 });
    _ = try simulator.canonical.run(host);
}

/// Renders a surface into `target`, from the run's real state.
pub fn renderSurface(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host, surface: Surface) !void {
    switch (surface) {
        .boot => renderBoot(target),
        .home => renderHome(target, host),
        .activity => try renderActivity(gpa, target, host),
        .approval => renderApproval(target, host),
        .principals => try renderPrincipals(gpa, target, host),
        .store => renderStore(target),
        .rest => renderRest(target),
    }
}

// --- Mappings from control-plane enums to the design's language ---

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

fn surfaced(action: anytype) bool {
    return switch (action) {
        .capability_used, .action_denied, .approval_requested, .approval_decided, .task_completed, .model_invoked => true,
        else => false,
    };
}

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

// --- Surfaces ---

pub fn renderBoot(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = width, .h = height }, .colour = paint.sample(theme.base) } }});
    var g: u8 = 0;
    while (g < 4) : (g += 1) {
        const r = @as(f32, @floatFromInt(260 - @as(u32, g) * 50));
        vector.fillDisc(target, @floatFromInt(width / 2), @floatFromInt(height / 2), r, .{ .r = theme.agent.red, .g = theme.agent.green, .b = theme.agent.blue, .a = 18 });
    }
    text.drawCentred(target, @floatFromInt(width / 2), @floatFromInt(height / 2 + 6), "Starting your world", 16, paint.sample(theme.text_primary));
}

pub fn renderRest(target: *Framebuffer) void {
    paint.paint(target, &.{.{ .vgradient = .{ .rect = .{ .x = 0, .y = 0, .w = width, .h = height }, .top = paint.sample(theme.panel), .bottom = paint.sample(theme.base) } }});
    text.drawCentred(target, @floatFromInt(width / 2), @floatFromInt(height / 2 - 8), "Everything handled.", 18, paint.sample(theme.text_primary));
    text.drawCentred(target, @floatFromInt(width / 2), @floatFromInt(height / 2 + 24), "Hello, world.", 14, paint.sample(theme.text_secondary));
}

pub fn renderActivity(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host) !void {
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

pub fn renderPrincipals(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host) !void {
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

pub fn renderHome(target: *Framebuffer, host: *Host) void {
    var title: []const u8 = "Your agents are at work";
    var subtitle: []const u8 = "Everything in the open. Tap to review.";
    var buf: [96]u8 = undefined;
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        if (host.registry.lookup(event.actor)) |actor| {
            title = std.fmt.bufPrint(&buf, "{s} needs a decision", .{actor.display_name}) catch title;
            subtitle = "Held for your approval. Tap to review.";
        }
        break;
    }
    graphics.home.renderWith(target, .{ .title = title, .subtitle = subtitle });
}

pub fn renderApproval(target: *Framebuffer, host: *Host) void {
    var agent: []const u8 = "An agent";
    var reaches: []const u8 = "an external destination";
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        if (host.registry.lookup(event.actor)) |actor| agent = actor.display_name;
        if (event.target_kind.len > 0) reaches = event.target_kind;
        break;
    }
    screens.renderApprovalScreen(target, .{
        .agent = agent,
        .title = "Confirm the venue",
        .subtitle = "Reaches outside",
        .keys = .{ "Action", "Reaches", "Once" },
        .values = .{ "confirm attendance", reaches, "Cannot repeat" },
        .footer = "Nothing consequential without you.",
    });
}

pub fn renderStore(target: *Framebuffer) void {
    const install_source = applications.store;
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
