//! Rendering the designed surfaces from a real control-plane run, framed as the phone.
//!
//! This is the bridge between the control plane and the render layer, shared by every front end: the
//! headless frame writer, the whole-session renderer, and the windowed desktop shell all call these
//! functions. Each takes a live `Host` — a run of the canonical scenario, with its real human and
//! agents, one action denied and one held for approval — and renders one designed surface from that
//! run's real audit ledger, registry, and store decisions. Every surface is drawn on the light phone
//! screen and composited into the device frame (dark bezel on a dark desktop), so the running OS shows
//! the design: a light, agent-native handset with the real agents doing the real work inside it.
//!
//! These functions decide nothing; they read the run's state and paint it. `t` is elapsed seconds, so
//! the living motion (breathing dots, the turning orb) advances; a still frame passes 0.

const std = @import("std");
const simulator = @import("simulator");
const graphics = @import("graphics");
const design = @import("design");
const applications = @import("applications");

pub const Host = simulator.host.Host;
const Framebuffer = graphics.framebuffer.Framebuffer;
const phone = graphics.phone;
const logo = graphics.logo;
const home = graphics.home;
const paint = graphics.paint;
const vector = graphics.vector;
const text = graphics.font;
const anim = graphics.anim;
const theme = design.theme;

/// The render target is the whole window: the framed device on its desktop.
pub const width: u32 = phone.window_w;
pub const height: u32 = phone.window_h;

const max_rows: usize = 6;

/// The surfaces the shell can show.
pub const Surface = enum { boot, lock, home, activity, approval, principals, store, rest, phone, messages, camera, agents, calendar, weather, contacts, files, settings };

/// Runs the canonical scenario into a fresh host. The caller owns it and must `deinit`.
pub fn runScenario(host: *Host, gpa: std.mem.Allocator) !void {
    Host.init(host, gpa, .{ .seed = 0x51 });
    _ = try simulator.canonical.run(host);
}

fn s(colour: theme.Colour) graphics.framebuffer.Rgba {
    return paint.sample(colour);
}

/// Renders a surface into the window `target`, from the run's real state, at time `t`.
pub fn renderSurface(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host, surface: Surface, t: f32) !void {
    phone.renderDevice(target);

    var screen = try phone.blankScreen(gpa);
    defer screen.deinit();

    switch (surface) {
        .boot => renderBoot(&screen, t),
        .rest => renderRest(&screen),
        .lock => {
            // The lock screen is a light field with the status bar but its own swipe-up affordance,
            // so it takes the wash and status bar but not the standard home indicator.
            phone.screenWash(&screen);
            phone.statusBar(&screen);
            renderLock(&screen, t);
        },
        else => {
            phone.screenWash(&screen);
            phone.statusBar(&screen);
            switch (surface) {
                .home => renderHome(&screen, host, t),
                .activity => try renderActivity(gpa, &screen, host),
                .approval => renderApproval(&screen, host),
                .principals => try renderPrincipals(gpa, &screen, host),
                .store => renderStore(&screen),
                .phone => renderPhone(&screen, host, t),
                .messages => renderMessages(&screen, host),
                .camera => renderCamera(&screen, host, t),
                .agents => renderAgents(&screen, host),
                .calendar => renderCalendar(&screen),
                .weather => renderWeather(&screen),
                .contacts => renderContacts(&screen),
                .files => renderFiles(&screen),
                .settings => renderSettings(&screen),
                else => unreachable,
            }
            phone.homeIndicator(&screen);
        },
    }

    phone.composite(target, screen);
}

// --- Mappings from control-plane enums to the design's accent language ---

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

// --- Light-screen chrome shared by the list surfaces ---

const pad: i32 = 22;

/// The reference lays its screens out on a 326px-wide device; this one is wider, so a reference
/// dimension is taken times this ratio to keep the type at the reference's proportions rather than a
/// third smaller. Matches the same factor the home screen scales by.
const ui: f32 = @as(f32, @floatFromInt(theme.screen_w)) / 326.0;

fn u(reference_px: f32) f32 {
    return reference_px * ui;
}

/// A screen header: a large title and a subtitle, below the status bar. The title takes the reference's
/// 21px semibold, the subtitle its muted regular, both at the screen's scale.
fn header(screen: *Framebuffer, title: []const u8, subtitle: []const u8) void {
    // At these sizes the weight heuristic already lands right: the 21px title in semibold, the 11.5px
    // subtitle in regular. The subtitle is clipped to the content column so a long one cannot spill off
    // the screen edge.
    const edge: f32 = @as(f32, @floatFromInt(width_screen())) - @as(f32, @floatFromInt(pad));
    _ = text.draw(screen, @floatFromInt(pad), u(58), title, u(21), s(theme.screen_text));
    _ = text.drawClipped(screen, @floatFromInt(pad), u(74), subtitle, u(11.5), s(theme.screen_text_muted), edge);
}

/// The geometry of a content card at a given top: the content column, inset by `pad`.
fn cardRect(y: i32, h: u32) graphics.paint.Rect {
    return .{ .x = pad, .y = y, .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = h };
}

/// Paints a white card (a soft drop shadow, then the card fill) into a known rectangle.
fn paintCard(screen: *Framebuffer, rect: graphics.paint.Rect) void {
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = rect.x, .y = rect.y + 6, .w = @intCast(rect.w), .h = rect.h },
        .radius = theme.radius_xl,
        .colour = .{ .r = 0x6a, .g = 0x4b, .b = 0xb0, .a = 18 },
    } }});
    paint.paint(screen, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_xl, .colour = s(theme.screen_card) } }});
}

/// A white card the width of the content column.
fn card(screen: *Framebuffer, y: i32, h: u32) graphics.paint.Rect {
    const rect = cardRect(y, h);
    paintCard(screen, rect);
    return rect;
}

fn width_screen() u32 {
    return theme.screen_w;
}

/// The right edge of a card, in float, avoiding i32/u32 mixing.
fn rightF(rect: graphics.paint.Rect) f32 {
    return @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w));
}

fn rightI(rect: graphics.paint.Rect) i32 {
    return rect.x + @as(i32, @intCast(rect.w));
}

// --- Surfaces ---

/// Boot, matching the design: a near-black screen, a large soft-blue radial glow that breathes, and
/// the round mark revealing — scaling up from 0.8 with the design's ease over 1.6s, then breathing.
/// No caption; the mark alone, over the top.
// The boot mark is 116px in the reference — radius 58 — on a near-black field, over a 300px blue glow.
const boot_logo_r: f32 = 58.0;

pub fn renderBoot(screen: *Framebuffer, t: f32) void {
    // The near-black boot field.
    paint.paint(screen, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = phone.screen_w, .h = phone.screen_h }, .colour = s(theme.base) } }});
    const cx: f32 = @floatFromInt(phone.screen_w / 2);
    const cy: f32 = @floatFromInt(phone.screen_h / 2);

    // The 300px blue glow disc, a smooth radial wash pulsing on the reference's 4.5s cycle:
    // opacity .5 → 1 → .5. `0.75 - 0.25*cos` lands on .5 at the cycle ends and 1.0 at the half.
    const glow = 0.75 - 0.25 * @cos(t * (2.0 * std.math.pi / 4.5));
    const glow_peak: u8 = @intFromFloat(20.0 + glow * 26.0);
    vector.fillGlow(screen, cx, cy, 150.0, s(theme.human), glow_peak);

    // The mark's motion, exactly the reference's layering:
    //   reveal  1.6s cubic-bezier(.16,.9,.24,1): scale .8 → 1, opacity 0 → 1
    //   breathe 6s from 1.7s: scale 1 → 1.05 → 1
    const reveal_dur: f32 = 1.6;
    var scale: f32 = 1.0;
    var opacity: f32 = 1.0;
    if (t < reveal_dur) {
        const p = anim.ease(t / reveal_dur, 0.16, 0.9, 0.24, 1.0);
        scale = 0.8 + 0.2 * p;
        opacity = p;
    } else if (t >= 1.7) {
        scale = 1.025 - 0.025 * @cos((t - 1.7) * (2.0 * std.math.pi / 6.0));
    }
    const r = boot_logo_r * scale;
    logo.draw(screen, cx, cy, r);

    // The reveal's fade-in, done by veiling the mark with the field colour at the inverse of its opacity.
    if (opacity < 1.0) {
        const veil: u8 = @intFromFloat((1.0 - opacity) * 255.0);
        vector.fillDisc(screen, cx, cy, r + 2.0, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = veil });
    }

    // The sheen: a white diagonal band sweeps across the mark once, 1.35s → 2.55s.
    if (t >= 1.35 and t < 2.55) bootSheen(screen, cx, cy, r, (t - 1.35) / 1.2);
}

/// The reference's `sheen` sweep: a soft white band, skewed ~14°, travelling left→right across the mark
/// and clipped to its disc. `p` runs 0→1 over the sweep. Peak brightness eases in and out at the ends.
fn bootSheen(screen: *Framebuffer, cx: f32, cy: f32, r: f32, p: f32) void {
    const skew: f32 = 0.249; // tan(14°)
    const band_x = cx + (-1.6 + p * 4.0) * r; // translateX(-160% → 240%) of the logo width
    const half = 0.55 * r; // the band is ~55% of the logo wide
    const envelope = @sin(p * std.math.pi); // fade the highlight in and out over the sweep
    const peak: f32 = 90.0 * envelope;
    if (peak < 1.0) return;
    const white: graphics.framebuffer.Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    var y: i32 = @intFromFloat(cy - r);
    const y1: i32 = @intFromFloat(cy + r);
    while (y <= y1) : (y += 1) {
        const fy: f32 = @floatFromInt(y);
        const dy = fy - cy;
        var x: i32 = @intFromFloat(cx - r);
        const x1: i32 = @intFromFloat(cx + r);
        while (x <= x1) : (x += 1) {
            const fx: f32 = @floatFromInt(x);
            const dx = fx - cx;
            if (dx * dx + dy * dy > r * r) continue;
            const d = @abs((fx + dy * skew) - band_x); // distance to the skewed band centre
            if (d >= half) continue;
            const a: u8 = @intFromFloat(peak * (1.0 - d / half));
            if (a == 0) continue;
            screen.blend(@intCast(x), @intCast(y), white, a);
        }
    }
}

/// The lock screen — the reference's "Hello, world." moment between boot and home. A light field
/// carrying two soft corner glows, the brand mark on a dark disc pulsing inside an expanding ring,
/// a "Face recognized" confirmation, the greeting, and the swipe-up affordance. `t` drives the ring
/// and breathe; the caller has already washed the screen light and drawn the status bar.
pub fn renderLock(screen: *Framebuffer, t: f32) void {
    const cw: f32 = @floatFromInt(phone.screen_w);
    const cx = cw / 2.0;

    // Two blurred corner glows: coral off the top-left, blue off the bottom-right.
    softGlow(screen, cw * 0.08, 120.0, 150.0, theme.coral);
    softGlow(screen, cw * 0.92, @floatFromInt(phone.screen_h - 220), 165.0, theme.human);

    // The mark on a dark disc, centred high, inside a ring that expands and fades on the 3.6s cycle.
    const disc_cy: f32 = 300.0;
    const disc_r: f32 = 66.0;
    const ring_p = @mod(t, 3.6) / 3.6;
    const ring_r = disc_r * (1.08 + 0.62 * ring_p); // scale .7 → 1.5 relative to the 150px ring
    const ring_a: u8 = @intFromFloat(140.0 * (1.0 - ring_p));
    vector.strokeCircle(screen, cx, disc_cy, ring_r, 2.0, .{ .r = theme.agent.red, .g = theme.agent.green, .b = theme.agent.blue, .a = ring_a });
    const breathe = 1.0 + 0.025 - 0.025 * @cos(t * (2.0 * std.math.pi / 5.0));
    vector.fillDisc(screen, cx, disc_cy, disc_r * breathe, s(theme.base));
    logo.draw(screen, cx, disc_cy, 44.0 * breathe);

    // The "Face recognized" pill: a light chip with a shield-check, in the success accent.
    const pill_w: f32 = 156.0;
    const pill_y: i32 = 408;
    const pill: paint.Rect = .{ .x = @intFromFloat(cx - pill_w / 2.0), .y = pill_y, .w = @intFromFloat(pill_w), .h = 30 };
    paint.paint(screen, &.{.{ .rounded = .{ .rect = pill, .radius = 15, .colour = s(theme.screen_card) } }});
    lockShieldCheck(screen, cx - pill_w / 2.0 + 20.0, @floatFromInt(pill_y + 15), theme.teal);
    _ = text.draw(screen, cx - pill_w / 2.0 + 34.0, @floatFromInt(pill_y + 20), "Face recognized", 12.5, s(theme.teal));

    // The greeting and the reassurance line.
    text.drawCentred(screen, cx, 476, "Hello, world.", 27, s(theme.screen_text));
    text.drawCentred(screen, cx, 502, "3 agents resting \u{00B7} everything's handled", 13, s(theme.screen_text_muted));

    // The swipe-up affordance: a home bar, an up chevron, and the prompt, all near the bottom.
    const by: f32 = @floatFromInt(phone.screen_h - 60);
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = @intFromFloat(cx - 20.0), .y = @intFromFloat(by), .w = 40, .h = 5 }, .radius = 3, .colour = s(theme.screen_line) } }});
    vector.strokePolyline(screen, &.{
        .{ .x = cx - 9.0, .y = by + 20.0 },
        .{ .x = cx, .y = by + 11.0 },
        .{ .x = cx + 9.0, .y = by + 20.0 },
    }, 2.4, s(theme.screen_text_muted), false);
    text.drawCentred(screen, cx, by + 42.0, "Swipe up to open", 12, s(theme.screen_text_muted));
}

/// A soft radial glow disc — a smooth wash that fades to nothing at its edge, no concentric banding.
fn softGlow(screen: *Framebuffer, cx: f32, cy: f32, radius: f32, hue: theme.Colour) void {
    vector.fillGlow(screen, cx, cy, radius, s(hue), 60);
}

/// A small shield with a check inside — the face-recognition confirmation mark.
fn lockShieldCheck(screen: *Framebuffer, cx: f32, cy: f32, hue: theme.Colour) void {
    const col = s(hue);
    // The shield outline: shoulders, sides tapering to a point.
    vector.strokePolyline(screen, &.{
        .{ .x = cx, .y = cy - 7.0 },
        .{ .x = cx + 6.0, .y = cy - 4.5 },
        .{ .x = cx + 6.0, .y = cy + 1.0 },
        .{ .x = cx, .y = cy + 7.0 },
        .{ .x = cx - 6.0, .y = cy + 1.0 },
        .{ .x = cx - 6.0, .y = cy - 4.5 },
    }, 1.6, col, true);
    // The check.
    vector.strokePolyline(screen, &.{
        .{ .x = cx - 3.0, .y = cy },
        .{ .x = cx - 0.8, .y = cy + 2.4 },
        .{ .x = cx + 3.2, .y = cy - 2.2 },
    }, 1.6, col, false);
}

pub fn renderRest(screen: *Framebuffer) void {
    paint.paint(screen, &.{.{ .vgradient = .{ .rect = .{ .x = 0, .y = 0, .w = phone.screen_w, .h = phone.screen_h }, .top = s(theme.panel), .bottom = s(theme.base) } }});
    const cx: f32 = @floatFromInt(phone.screen_w / 2);
    text.drawCentred(screen, cx, @floatFromInt(phone.screen_h / 2 - 8), "Everything handled.", 18, s(theme.text_primary));
    text.drawCentred(screen, cx, @floatFromInt(phone.screen_h / 2 + 24), "Hello, world.", 14, s(theme.text_secondary));
}

pub fn renderHome(screen: *Framebuffer, host: *Host, t: f32) void {
    var greeting: []const u8 = "Good morning";
    var buf: [96]u8 = undefined;
    if (host.registry.lookup(host.human)) |human| {
        greeting = std.fmt.bufPrint(&buf, "Good morning, {s}", .{human.display_name}) catch "Good morning";
    }
    var day_buf: [64]u8 = undefined;
    const day_line = std.fmt.bufPrint(&day_buf, "Tuesday \u{00B7} {d} agents working", .{host.agents.items.len}) catch "Tuesday";

    // The held-for-approval action becomes the active task title.
    var active: ?[]const u8 = "Planning your Lisbon trip";
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        active = "Confirming your Lisbon venue";
        break;
    }

    home.render(screen, .{
        .greeting = greeting,
        .day_line = day_line,
        .tasks = &.{
            .{ .title = "Arranging your day", .note = "just now \u{00B7} agents coordinating", .hue = theme.teal },
        },
        .active_title = active,
    }, t);
}

pub fn renderActivity(gpa: std.mem.Allocator, screen: *Framebuffer, host: *Host) !void {
    header(screen, "Activity", "Every action, under a capability");

    var rows: std.ArrayList(struct { actor: []const u8, action: []const u8, outcome: OutcomeView, colour: theme.Colour }) = .empty;
    defer rows.deinit(gpa);

    var index: usize = host.ledger.count();
    while (index > 0 and rows.items.len < max_rows) {
        index -= 1;
        const event = host.ledger.at(index) orelse continue;
        if (!surfaced(event.action)) continue;
        const actor = host.registry.lookup(event.actor) orelse continue;
        const is_human = actor.kind == .human;
        try rows.append(gpa, .{
            .actor = if (is_human) "You" else actor.display_name,
            .action = actionText(event.action),
            .outcome = outcomeView(event.outcome),
            .colour = kindColour(actor.kind),
        });
    }
    std.mem.reverse(@TypeOf(rows.items[0]), rows.items);

    // The ledger is a flex column of equal-height cards; the engine places them.
    var heights: [graphics.stack.max_blocks]f32 = undefined;
    for (rows.items, 0..) |_, i| heights[i] = 58;
    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(120, heights[0..rows.items.len], 8, tops[0..rows.items.len]);

    for (rows.items, 0..) |row, i| {
        const rect = card(screen, @intFromFloat(tops[i]), 58);
        vector.fillDisc(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 29), 5, s(row.colour));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 25), row.actor, 12.5, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 38), @floatFromInt(rect.y + 42), row.action, 10.5, s(theme.screen_text_muted));
        const badge = row.outcome.text;
        const bw = text.measure(badge, 10.5);
        const hue = if (row.outcome.denied) theme.denied else theme.teal;
        _ = text.draw(screen, rightF(rect) - 18 - bw, @floatFromInt(rect.y + 34), badge, 10.5, s(hue));
    }
}

// People & agents — "First-class citizens", the seven kinds of principal that inhabit
// the OS as co-equals, verbatim from the design.
const principals_screen: Screen = .{ .title = "People & agents", .sub = "Humans \u{00B7} agents \u{00B7} apps \u{00B7} services \u{00B7} orgs \u{00B7} devices \u{00B7} sessions", .sections = &.{
    .{ .label = "FIRST-CLASS CITIZENS", .rows = &.{
        .{ .title = "Humans", .sub = "you and your contacts", .colour = theme.coral, .value = "1" },
        .{ .title = "Agents", .sub = "planner, route", .colour = theme.agent, .value = "2" },
        .{ .title = "Applications", .sub = "sandboxed", .colour = theme.app_principal, .value = "4" },
        .{ .title = "Services", .sub = "reached via agents", .colour = theme.human, .value = "3" },
        .{ .title = "Organizations", .sub = "work", .colour = theme.coral, .value = "1" },
        .{ .title = "Devices", .sub = "trusted endpoints", .colour = theme.teal, .value = "2" },
        .{ .title = "Sessions", .sub = "ephemeral", .colour = theme.session_principal, .value = "live" },
    } },
} };

pub fn renderPrincipals(gpa: std.mem.Allocator, screen: *Framebuffer, host: *Host) !void {
    _ = gpa;
    _ = host;
    renderScreen(screen, principals_screen);
}

/// Files: the granted folder's contents, and the agent search confined to it.
pub fn renderFiles(screen: *Framebuffer) void {
    const entries = [_]Row{
        .{ .title = "Trip-Lisbon.md", .sub = "documents \u{00B7} 4 KB", .colour = theme.human, .value = "" },
        .{ .title = "budget.csv", .sub = "documents \u{00B7} 2 KB", .colour = theme.human, .value = "" },
        .{ .title = "lisbon.jpg", .sub = "photos \u{00B7} 1.8 MB", .colour = theme.teal, .value = "" },
    };
    const sections = [_]Section{.{ .label = "Documents \u{00B7} within your grant", .rows = &entries }};
    renderScreen(screen, .{ .title = "Files", .sub = "Search stays inside the grant", .sections = &sections });
}

/// Settings: rendered from the policy registry, each setting shown with its sensitivity — what an
/// agent may do with it, decided by the setting, not the caller. human_only is the person's alone.
pub fn renderSettings(screen: *Framebuffer) void {
    const registry = applications.framework.settings.registry;
    var rows: [max_rows]Row = undefined;
    var count: usize = 0;
    for (registry) |entry| {
        if (count >= rows.len) break;
        const badge: []const u8 = switch (entry.class) {
            .open => "OPEN",
            .notify => "NOTIFY",
            .hold => "HOLD",
            .human_only => "YOU ONLY",
        };
        const colour = switch (entry.class) {
            .open => theme.teal,
            .notify => theme.human,
            .hold => theme.amber,
            .human_only => theme.denied,
        };
        rows[count] = .{ .title = entry.key, .sub = entry.owner, .colour = colour, .value = badge };
        count += 1;
    }
    const sections = [_]Section{.{ .label = "Settings are policy \u{00B7} the class is the setting's", .rows = rows[0..count] }};
    renderScreen(screen, .{ .title = "Settings", .sub = "Every setting, and what an agent may do with it", .sections = &sections });
}

/// Calendar: the day arranged into focus blocks — committed time, in the teal of a done block, and
/// the one held for the person in the awaiting amber.
pub fn renderCalendar(screen: *Framebuffer) void {
    const blocks = [_]Row{
        .{ .title = "Design review", .sub = "09:00 – 10:30 \u{00B7} focus", .colour = theme.teal, .value = "" },
        .{ .title = "Lisbon trip planning", .sub = "11:00 – 12:00 \u{00B7} with your agents", .colour = theme.agent, .value = "LIVE" },
        .{ .title = "Hotel deposit", .sub = "held for you to approve", .colour = theme.amber, .value = "HOLD" },
    };
    const sections = [_]Section{.{ .label = "Today \u{00B7} focus blocks", .rows = &blocks }};
    renderScreen(screen, .{ .title = "Calendar", .sub = "Your day, in blocks", .sections = &sections });
}

/// Weather: saved locations and their current reading, external data an agent may retrieve.
pub fn renderWeather(screen: *Framebuffer) void {
    const places = [_]Row{
        .{ .title = "Lisbon", .sub = "Clear \u{00B7} light breeze", .colour = theme.amber, .value = "24\u{00B0}" },
        .{ .title = "Porto", .sub = "Cloudy", .colour = theme.human, .value = "19\u{00B0}" },
        .{ .title = "Home", .sub = "Rain later", .colour = theme.human, .value = "17\u{00B0}" },
    };
    const sections = [_]Section{.{ .label = "Your places", .rows = &places }};
    renderScreen(screen, .{ .title = "Weather", .sub = "Saved locations", .sections = &sections });
}

/// Contacts: people, and — surfaced honestly alongside them — the non-human principals a person
/// shares their world with.
pub fn renderContacts(screen: *Framebuffer) void {
    const people = [_]Row{
        .{ .title = "Ana Silva", .sub = "mobile \u{00B7} email", .colour = theme.human, .value = "" },
        .{ .title = "Marco Dias", .sub = "work", .colour = theme.human, .value = "" },
    };
    const world = [_]Row{
        .{ .title = "Weather", .sub = "service", .colour = theme.amber, .value = "" },
        .{ .title = "Living-room display", .sub = "device", .colour = theme.human, .value = "" },
        .{ .title = "Kitchen session", .sub = "session", .colour = theme.agent_soft, .value = "" },
    };
    const sections = [_]Section{
        .{ .label = "People", .rows = &people },
        .{ .label = "Also in your world", .rows = &world },
    };
    renderScreen(screen, .{ .title = "Contacts", .sub = "People and principals", .sections = &sections });
}

/// The Agents flagship: the roster of agents acting in the person's world, read from the real run —
/// each agent named, in agent-violet, marked LIVE while it works.
pub fn renderAgents(screen: *Framebuffer, host: *Host) void {
    var rows: [max_rows]Row = undefined;
    var count: usize = 0;
    for (host.agents.items) |a| {
        if (count >= rows.len) break;
        rows[count] = .{ .title = a.name, .sub = "coordinating your day", .colour = theme.agent, .value = "LIVE" };
        count += 1;
    }
    const sections = [_]Section{.{ .label = "Agents at work", .rows = rows[0..count] }};
    renderScreen(screen, .{ .title = "Agents", .sub = "Who is acting in your world", .sections = &sections });
}

pub fn renderApproval(screen: *Framebuffer, host: *Host) void {
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

    header(screen, "Approval", "Nothing consequential without you");

    const rect = card(screen, 128, 240);
    vector.fillDisc(screen, @floatFromInt(rect.x + 34), @floatFromInt(rect.y + 40), 16, s(theme.agent));
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 36), agent, 14, s(theme.screen_text));
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 54), "asks to confirm the venue", 11, s(theme.screen_text_muted));

    const rowsy: i32 = rect.y + 84;
    const facts = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "Action", .v = "confirm attendance" },
        .{ .k = "Reaches", .v = reaches },
        .{ .k = "Scope", .v = "Once \u{00B7} cannot repeat" },
    };
    for (facts, 0..) |f, i| {
        const fy = rowsy + @as(i32, @intCast(i)) * 30;
        _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(fy), f.k, 11, s(theme.screen_text_muted));
        _ = text.draw(screen, rightF(rect) - 22 - text.measure(f.v, 11.5), @floatFromInt(fy), f.v, 11.5, s(theme.screen_text));
    }

    // Approve / hold buttons — a flex row of two equal cells split by the layout engine.
    const by: i32 = rect.y + @as(i32, @intCast(rect.h)) - 52;
    var buttons: [2]graphics.flex.Rect = undefined;
    graphics.flex.solve(
        .{ .axis = .row, .gap = 12 },
        &.{ .{ .main = .{ .flex = 1 } }, .{ .main = .{ .flex = 1 } } },
        .{ .w = @floatFromInt(rect.w), .h = 40 },
        &buttons,
    );
    const cells = [_]struct { rect: graphics.flex.Rect, fill: theme.Colour, label: []const u8, ink: theme.Colour }{
        .{ .rect = buttons[0], .fill = theme.agent, .label = "Approve", .ink = theme.screen_card },
        .{ .rect = buttons[1], .fill = theme.screen_hairline, .label = "Hold", .ink = theme.screen_text },
    };
    for (cells) |cell| {
        const x: i32 = rect.x + @as(i32, @intFromFloat(cell.rect.x));
        paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = x, .y = by, .w = @intFromFloat(cell.rect.w), .h = 40 }, .radius = theme.radius_lg, .colour = s(cell.fill) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(x)) + cell.rect.w / 2, @floatFromInt(by + 25), cell.label, 12.5, s(cell.ink));
    }
}

pub fn renderStore(screen: *Framebuffer) void {
    header(screen, "Store", "Reviewed, signed, and sandboxed");

    const install_source = applications.store;
    const Catalog = struct { name: []const u8, publisher: []const u8, source: install_source.Source, acknowledged: bool, colour: theme.Colour };
    const catalog = [_]Catalog{
        .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.teal },
        .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.agent },
        .{ .name = "Field Tools", .publisher = "Outside source", .source = .sideload, .acknowledged = true, .colour = theme.amber },
        .{ .name = "Unknown Build", .publisher = "Unreviewed source", .source = .sideload, .acknowledged = false, .colour = theme.denied },
    };

    var heights: [graphics.stack.max_blocks]f32 = undefined;
    for (catalog, 0..) |_, i| heights[i] = 66;
    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(120, heights[0..catalog.len], 8, tops[0..catalog.len]);

    for (catalog, 0..) |item, i| {
        // A Store install proceeds; a sideload needs the person's acknowledgement, and
        // an unacknowledged sideload is blocked.
        const needs_ack = install_source.installNeedsAcknowledgement(item.source);
        const blocked = needs_ack and !item.acknowledged;
        const action: []const u8 = if (blocked) "Blocked" else if (needs_ack) "Acknowledge" else "Get";
        const rect = card(screen, @intFromFloat(tops[i]), 66);
        paint.paint(screen, &.{.{ .rounded_vgradient = .{
            .rect = .{ .x = rect.x + 16, .y = rect.y + 15, .w = 36, .h = 36 },
            .radius = 10,
            .top = s(item.colour),
            .bottom = s(item.colour),
        } }});
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 28), item.name, 13, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 46), item.publisher, 10.5, s(theme.screen_text_muted));
        const hue = if (blocked) theme.denied else theme.agent;
        const bw = text.measure(action, 11);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = rightI(rect) - 20 - @as(i32, @intFromFloat(bw)) - 20, .y = rect.y + 20, .w = @as(u32, @intFromFloat(bw)) + 24, .h = 26 }, .radius = 13, .colour = s(hue) } }});
        text.drawCentred(screen, rightF(rect) - 20 - bw / 2 - 12, @floatFromInt(rect.y + 37), action, 11, s(theme.screen_card));
    }
}

// --- The design's data-driven screen model ---
//
// Every app screen in the design is the same shape: a title and sub, then sections, each
// a small label over rows, and each row a coloured dot, a title, a subtitle, and an
// optional value on the right. Rendering from this model — with content taken verbatim
// from the design — is what makes the apps look and read as the design intends.

const Row = struct { title: []const u8, sub: []const u8, colour: theme.Colour, value: []const u8 = "" };
const Section = struct { label: []const u8, rows: []const Row };
const Screen = struct { title: []const u8, sub: []const u8, sections: []const Section };

fn sa(colour: theme.Colour, alpha: u8) graphics.framebuffer.Rgba {
    return .{ .r = colour.red, .g = colour.green, .b = colour.blue, .a = alpha };
}

/// A block the layout engine placed on a screen: a section label or a row card, with the
/// rectangle it was assigned. This is the single placement the renderer paints and the
/// conformance gate samples — neither re-derives coordinates on its own.
const PlacedKind = enum { label, card };
const Placed = struct { kind: PlacedKind, rect: graphics.paint.Rect, section: usize, row: usize };

/// Places a screen's blocks with the flex engine — a section is a label then its row cards,
/// with a trailing spacer between sections. Fills `out` with the label and card placements
/// (spacers are consumed as gaps, not emitted) and returns how many were written.
fn layoutScreen(model: Screen, out: []Placed) usize {
    const Kind = enum { label, card, spacer };
    const Block = struct { kind: Kind, section: usize, row: usize };
    var blocks: [graphics.stack.max_blocks]Block = undefined;
    var heights: [graphics.stack.max_blocks]f32 = undefined;
    var n: usize = 0;
    for (model.sections, 0..) |section, si| {
        blocks[n] = .{ .kind = .label, .section = si, .row = 0 };
        heights[n] = 24;
        n += 1;
        for (section.rows, 0..) |_, ri| {
            blocks[n] = .{ .kind = .card, .section = si, .row = ri };
            heights[n] = u(50) + u(8); // a reference-scaled card plus the gap below it
            n += 1;
        }
        blocks[n] = .{ .kind = .spacer, .section = si, .row = 0 };
        heights[n] = 8;
        n += 1;
    }

    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(122, heights[0..n], 0, tops[0..n]);

    var count: usize = 0;
    for (blocks[0..n], 0..) |b, i| {
        const y: i32 = @intFromFloat(tops[i]);
        switch (b.kind) {
            .spacer => {},
            .label => {
                out[count] = .{ .kind = .label, .rect = cardRect(y, 24), .section = b.section, .row = b.row };
                count += 1;
            },
            .card => {
                out[count] = .{ .kind = .card, .rect = cardRect(y, @intFromFloat(u(50))), .section = b.section, .row = b.row };
                count += 1;
            },
        }
    }
    return count;
}

/// Renders a design screen: the header, then each section's label and its rows as light
/// cards — a soft colour halo and dot on the left, the title and subtitle, the value on
/// the right in the row's own accent. Placement comes from `layoutScreen`; this only paints.
fn renderScreen(screen: *Framebuffer, model: Screen) void {
    header(screen, model.title, model.sub);

    var placed: [graphics.stack.max_blocks]Placed = undefined;
    const count = layoutScreen(model, &placed);
    for (placed[0..count]) |p| {
        const rect = p.rect;
        switch (p.kind) {
            .label => _ = text.drawClipped(screen, @as(f32, @floatFromInt(pad)) + u(4), @as(f32, @floatFromInt(rect.y)) + u(9), model.sections[p.section].label, u(11), s(theme.screen_label), rightF(rect) - u(8)),
            .card => {
                const row = model.sections[p.section].rows[p.row];
                const rx: f32 = @floatFromInt(rect.x);
                const ry: f32 = @floatFromInt(rect.y);
                paintCard(screen, rect);
                // A soft halo behind the dot, in the row's colour, then the dot.
                vector.fillDisc(screen, rx + u(22), ry + u(25), u(11), sa(row.colour, 32));
                vector.fillDisc(screen, rx + u(22), ry + u(25), u(4.5), s(row.colour));
                // The value badge takes the right edge; the title and subtitle are clipped to stop before
                // it, so a long name is cut at the badge rather than running under it.
                const value_left = if (row.value.len > 0) rightF(rect) - u(16) - text.measure(row.value, u(10.5)) - u(8) else rightF(rect) - u(16);
                _ = text.drawClipped(screen, rx + u(42), ry + u(21), row.title, u(12.5), s(theme.screen_text), value_left);
                _ = text.drawClipped(screen, rx + u(42), ry + u(37), row.sub, u(10.5), s(theme.screen_text_muted), value_left);
                if (row.value.len > 0) {
                    const vw = text.measure(row.value, u(10.5));
                    _ = text.draw(screen, rightF(rect) - u(16) - vw, ry + u(28), row.value, u(10.5), s(row.colour));
                }
            },
        }
    }
}

// Phone — "Recents", verbatim from the design.
const phone_screen: Screen = .{ .title = "Recents", .sub = "Calls, with context", .sections = &.{
    .{ .label = "TODAY", .rows = &.{
        .{ .title = "Sam", .sub = "12 min \u{00B7} outgoing", .colour = theme.coral, .value = "12:04" },
        .{ .title = "Clinic", .sub = "handled by agent", .colour = theme.teal, .value = "10:40" },
        .{ .title = "Spam blocked \u{00D7}4", .sub = "you were not disturbed", .colour = theme.denied },
    } },
    .{ .label = "SCREENED BY AGENT", .rows = &.{
        .{ .title = "Unknown \u{203A} clinic", .sub = "confirming Thu 3pm \u{00B7} added", .colour = theme.teal, .value = "Kept" },
        .{ .title = "Delivery", .sub = "rescheduled to Fri", .colour = theme.human, .value = "Done" },
    } },
} };

// Messages — the agent-to-agent negotiation, verbatim from the design.
const messages_screen: Screen = .{ .title = "Planner & Airline", .sub = "Negotiated on your behalf", .sections = &.{
    .{ .label = "THREAD", .rows = &.{
        .{ .title = "Seat + bag for LIS?", .sub = "Planner", .colour = theme.agent },
        .{ .title = "12A confirmed, bag added", .sub = "Airline agent \u{00B7} \u{20AC}0", .colour = theme.human },
        .{ .title = "Summarized for you", .sub = "nothing needs action", .colour = theme.teal },
    } },
    .{ .label = "SAM", .rows = &.{
        .{ .title = "see you at lunch!", .sub = "Sam", .colour = theme.coral },
        .{ .title = "booked the corner table", .sub = "you", .colour = theme.human },
    } },
} };

// Camera — "Lens modes", verbatim from the design.
const camera_screen: Screen = .{ .title = "Lens modes", .sub = "One camera, three intents", .sections = &.{
    .{ .label = "MODES", .rows = &.{
        .{ .title = "Lens", .sub = "front \u{00B7} in-screen", .colour = theme.agent, .value = "On" },
        .{ .title = "Describe", .sub = "ask about what you see", .colour = theme.teal },
        .{ .title = "Capture", .sub = "photo \u{00B7} video", .colour = theme.human },
    } },
    .{ .label = "PRIVACY", .rows = &.{
        .{ .title = "Front camera", .sub = "invisible until opened", .colour = theme.coral, .value = "Hidden" },
    } },
} };

pub fn renderPhone(screen: *Framebuffer, host: *Host, t: f32) void {
    _ = host;
    _ = t;
    renderScreen(screen, phone_screen);
}

pub fn renderMessages(screen: *Framebuffer, host: *Host) void {
    _ = host;
    renderScreen(screen, messages_screen);
}

pub fn renderCamera(screen: *Framebuffer, host: *Host, t: f32) void {
    _ = host;
    _ = t;
    renderScreen(screen, camera_screen);
}

// --- The per-screen pixel gate (P6.3) ---
//
// The rebuild's rule is conformance against the design, checked, not demoed. These render
// each verbatim-from-design surface and sample the framebuffer at the exact rectangles the
// layout engine assigned: every card must be filled with the design's card colour, and each
// row's accent dot must carry that row's token colour at its centre. A surface that drifts —
// a card that moved, a colour that changed, a row that failed to draw — fails here. The
// sampled points are solid fills, so the check is exact and identical on every architecture.

const testing = std.testing;

fn expectScreenConformant(gpa: std.mem.Allocator, model: Screen) !void {
    var screen = try phone.blankScreen(gpa);
    defer screen.deinit();
    phone.screenWash(&screen);
    phone.statusBar(&screen);
    renderScreen(&screen, model);

    var placed: [graphics.stack.max_blocks]Placed = undefined;
    const count = layoutScreen(model, &placed);
    var cards: usize = 0;
    for (placed[0..count]) |p| {
        if (p.kind != .card) continue;
        cards += 1;
        const row = model.sections[p.section].rows[p.row];
        // The card fill: a solid interior point above the row's text, well clear of the
        // rounded corners and the accent dot on the left.
        const bg = screen.get(@intCast(p.rect.x + 120), @intCast(p.rect.y + 8));
        try testing.expectEqual(paint.sample(theme.screen_card), bg);
        // The accent dot at its centre carries the row's token colour exactly.
        const dot = screen.get(@intCast(p.rect.x + 30), @intCast(p.rect.y + 30));
        try testing.expectEqual(paint.sample(row.colour), dot);
    }
    try testing.expect(cards >= 1); // the surface actually drew its cards
}

test "the phone surface carries its design tokens at the placed rectangles" {
    try expectScreenConformant(testing.allocator, phone_screen);
}

test "the messages surface carries its design tokens at the placed rectangles" {
    try expectScreenConformant(testing.allocator, messages_screen);
}

test "the camera surface carries its design tokens at the placed rectangles" {
    try expectScreenConformant(testing.allocator, camera_screen);
}

test "the principals surface carries its design tokens at the placed rectangles" {
    try expectScreenConformant(testing.allocator, principals_screen);
}
