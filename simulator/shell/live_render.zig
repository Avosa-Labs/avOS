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
const iconography = graphics.iconography;
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
pub const Surface = enum { boot, lock, home, library, calculator, activity, approval, principals, store, rest, shutdown, phone, messages, camera, agents, agent_detail, calendar, weather, contacts, files, settings };

/// The interactive state the shell carries between frames — what a tap has changed on a live surface.
/// The headless renderer passes a default; the windowed shell owns one and mutates it on input, so a
/// button press runs a real domain call and the next frame shows the result.
pub const Interaction = struct {
    /// The calculator's current expression (what the keypad has entered), or a result after "=".
    calc_buf: [48]u8 = [_]u8{0} ** 48,
    calc_len: usize = 0,
    calc_is_result: bool = false,
    /// The store's real installed set, so installing actually installs.
    store_state: applications.store.Store = undefined,
    /// The messages thread's real exchanges, and whether the person has sent their reply.
    msgs_state: applications.messages.Store = undefined,
    person_replied: bool = false,
    /// Which agent's detail is open (an index into the roster), and which agents the person has paused.
    open_agent: ?usize = null,
    agent_paused: [8]bool = [_]bool{false} ** 8,
    store_ready: bool = false,
    next_key: u128 = 1,

    pub fn calcExpr(self: *const Interaction) []const u8 {
        return self.calc_buf[0..self.calc_len];
    }

    /// Appends a character the keypad produced. A fresh entry after a result starts a new expression.
    pub fn calcPush(self: *Interaction, ch: u8) void {
        if (self.calc_is_result) {
            self.calc_len = 0;
            self.calc_is_result = false;
        }
        if (self.calc_len < self.calc_buf.len) {
            self.calc_buf[self.calc_len] = ch;
            self.calc_len += 1;
        }
    }

    pub fn calcClear(self: *Interaction) void {
        self.calc_len = 0;
        self.calc_is_result = false;
    }

    pub fn calcBack(self: *Interaction) void {
        if (self.calc_is_result) {
            self.calcClear();
        } else if (self.calc_len > 0) {
            self.calc_len -= 1;
        }
    }

    /// Evaluates the expression through the real calculator domain — the same `calc.evaluate` an agent
    /// would call — and shows the result, or "Error" for a bad expression or a division by zero.
    pub fn calcEval(self: *Interaction) void {
        const value = applications.calculator.evaluateExpression(self.calcExpr()) catch {
            self.setCalc("Error");
            return;
        };
        var formatted: [48]u8 = undefined;
        const text_out = std.fmt.bufPrint(&formatted, "{d}", .{value}) catch "0";
        self.setCalc(text_out);
    }

    fn setCalc(self: *Interaction, value: []const u8) void {
        const n = @min(value.len, self.calc_buf.len);
        @memcpy(self.calc_buf[0..n], value[0..n]);
        self.calc_len = n;
        self.calc_is_result = true;
    }

    /// Gives the interaction the heap-backed state it needs (the store's installed set). The caller owns
    /// it and must `release` it.
    pub fn attach(self: *Interaction, gpa: std.mem.Allocator) void {
        self.store_state = applications.store.Store.init(gpa);
        self.msgs_state = applications.messages.Store.init(gpa);
        // Seed the two agent-to-agent exchanges the thread shows, so the a2a count is real.
        self.msgs_state.recordExchange(.agent, .agent) catch {};
        self.msgs_state.recordExchange(.agent, .agent) catch {};
        self.store_ready = true;
    }

    pub fn release(self: *Interaction) void {
        if (self.store_ready) {
            self.store_state.deinit();
            self.msgs_state.deinit();
        }
    }

    /// The person sends their reply through the real messages domain — the same `message.send` an agent
    /// reaches, here completing as the person's own send.
    pub fn sendReply(self: *Interaction) void {
        if (!self.store_ready or self.person_replied) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.messages.Store.execute(&self.msgs_state, .{ .operation = "message.send" }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        self.person_replied = true;
    }

    pub fn agentToAgent(self: *const Interaction) usize {
        if (!self.store_ready) return 0;
        return self.msgs_state.agentToAgentCount();
    }

    pub fn isAgentPaused(self: *const Interaction, index: usize) bool {
        return index < self.agent_paused.len and self.agent_paused[index];
    }

    pub fn toggleAgentPaused(self: *Interaction, index: usize) void {
        if (index < self.agent_paused.len) self.agent_paused[index] = !self.agent_paused[index];
    }

    /// Installs `name` through the store's real domain — the same `store.install` an agent reaches, here
    /// completing because it is the person's own decision.
    pub fn install(self: *Interaction, name: []const u8) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.store.Store.execute(&self.store_state, .{ .operation = "store.install", .args = name }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    pub fn isInstalled(self: *const Interaction, name: []const u8) bool {
        if (!self.store_ready) return false;
        for (self.store_state.installed.items) |installed| {
            if (std.mem.eql(u8, installed, name)) return true;
        }
        return false;
    }
};

/// Runs the canonical scenario into a fresh host. The caller owns it and must `deinit`.
pub fn runScenario(host: *Host, gpa: std.mem.Allocator) !void {
    Host.init(host, gpa, .{ .seed = 0x51 });
    _ = try simulator.canonical.run(host);
}

fn s(colour: theme.Colour) graphics.framebuffer.Rgba {
    return paint.sample(colour);
}

/// Renders a surface into the window `target`, from the run's real state, at time `t`. `inter` carries
/// the live interaction state (e.g. what the calculator keypad has entered).
pub fn renderSurface(gpa: std.mem.Allocator, target: *Framebuffer, host: *Host, surface: Surface, t: f32, inter: *const Interaction) !void {
    phone.renderDevice(target);

    var screen = try phone.blankScreen(gpa);
    defer screen.deinit();

    switch (surface) {
        .boot => renderBoot(&screen, t),
        .rest => renderRest(&screen),
        .shutdown => renderShutdown(&screen, t),
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
                .library => renderLibrary(&screen),
                .calculator => renderCalculator(&screen, inter),
                .activity => try renderActivity(gpa, &screen, host),
                .approval => renderApproval(&screen, host),
                .principals => try renderPrincipals(gpa, &screen, host),
                .store => renderStore(&screen, inter),
                .phone => renderPhone(&screen, host, t),
                .messages => renderMessages(&screen, inter),
                .camera => renderCamera(&screen, host, t),
                .agents => renderAgents(&screen, host, inter),
                .agent_detail => renderAgentDetail(&screen, host, inter),
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

    // The reference's blue glow: a faint bloom close behind the mark, not a broad halo. Its opacity
    // pulses on the 4.5s cycle (.5 → 1 → .5); `0.75 - 0.25*cos` lands on .5 at the ends and 1.0 at the
    // half. Kept low and tight so it reads as a whisper of light, never a circular shadow.
    const glow = 0.75 - 0.25 * @cos(t * (2.0 * std.math.pi / 4.5));
    const glow_peak: u8 = @intFromFloat(glow * 26.0);
    vector.fillGlow(screen, cx, cy, u(84), s(theme.human), glow_peak);

    // The mark's motion: a quick reveal (the design's ease, but snappy so the logo appears at once),
    // then a gentle breathe. reveal: scale .8 → 1, opacity 0 → 1; breathe: scale 1 → 1.05 → 1.
    const reveal_dur: f32 = 0.7;
    const breathe_from: f32 = 0.8;
    var scale: f32 = 1.0;
    var opacity: f32 = 1.0;
    if (t < reveal_dur) {
        const p = anim.ease(t / reveal_dur, 0.16, 0.9, 0.24, 1.0);
        scale = 0.8 + 0.2 * p;
        opacity = p;
    } else if (t >= breathe_from) {
        scale = 1.025 - 0.025 * @cos((t - breathe_from) * (2.0 * std.math.pi / 6.0));
    }
    // The mark is the reference's 116px, scaled to this screen's proportions (a third larger than raw),
    // then by the reveal/breathe.
    const r = u(boot_logo_r) * scale;
    logo.draw(screen, cx, cy, r);

    // The reveal's fade-in, done by veiling the mark with the field colour at the inverse of its opacity.
    if (opacity < 1.0) {
        const veil: u8 = @intFromFloat((1.0 - opacity) * 255.0);
        vector.fillDisc(screen, cx, cy, r + 2.0, .{ .r = theme.base.red, .g = theme.base.green, .b = theme.base.blue, .a = veil });
    }

    // The sheen: a white diagonal band sweeps across the mark once, just after it appears (0.5s → 1.4s).
    if (t >= 0.5 and t < 1.4) bootSheen(screen, cx, cy, r, (t - 0.5) / 0.9);
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
    // Clip to the mark's visible disc, not the full draw radius: the mark artwork fills ~92% of its box,
    // so masking to `r` would paint the highlight into the transparent margin around the disc — a grey
    // arc over the dark field as the band passes. Staying inside the disc keeps the sheen on the mark.
    const disc = r * 0.9;
    var y: i32 = @intFromFloat(cy - disc);
    const y1: i32 = @intFromFloat(cy + disc);
    while (y <= y1) : (y += 1) {
        const fy: f32 = @floatFromInt(y);
        const dy = fy - cy;
        var x: i32 = @intFromFloat(cx - disc);
        const x1: i32 = @intFromFloat(cx + disc);
        while (x <= x1) : (x += 1) {
            const fx: f32 = @floatFromInt(x);
            const dx = fx - cx;
            if (dx * dx + dy * dy > disc * disc) continue;
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

/// The shutdown screen: the device winds down to black with the reference's CRT power-off — a bright
/// line that flashes on, collapses to a point, and fades. `t` is seconds since shutdown began.
pub fn renderShutdown(screen: *Framebuffer, t: f32) void {
    paint.paint(screen, &.{.{ .solid = .{ .rect = .{ .x = 0, .y = 0, .w = phone.screen_w, .h = phone.screen_h }, .colour = .{ .r = 0, .g = 0, .b = 0, .a = 255 } } }});

    // The crtoff timeline: 0.25s delay, then 1.6s. width 80% → a point, opacity in then out.
    const local = t - 0.25;
    if (local <= 0) return;
    const p = std.math.clamp(local / 1.6, 0.0, 1.0);
    const full = @as(f32, @floatFromInt(phone.screen_w)) * 0.8;

    var w_px: f32 = full;
    var h_px: f32 = 2.0;
    var op: f32 = 1.0;
    if (p < 0.18) {
        op = p / 0.18; // flash on
    } else if (p < 0.68) {
        const k = (p - 0.18) / 0.5;
        w_px = full + (10.0 - full) * k; // collapse horizontally to ~10px
    } else {
        const k = (p - 0.68) / 0.32;
        w_px = 10.0 + (4.0 - 10.0) * k;
        h_px = 2.0 + 2.0 * k;
        op = 1.0 - k; // the point fades out
    }
    if (op <= 0.0) return;

    const cx: f32 = @floatFromInt(phone.screen_w / 2);
    const cy: f32 = @floatFromInt(phone.screen_h / 2);
    const a: u8 = @intFromFloat(op * 255.0);
    // A soft glow around the line, then the bright line itself.
    vector.fillGlow(screen, cx, cy, @max(h_px * 6.0, w_px * 0.5), .{ .r = 255, .g = 255, .b = 255, .a = 255 }, @intFromFloat(op * 90.0));
    paint.paint(screen, &.{.{ .rounded = .{
        .rect = .{ .x = @intFromFloat(cx - w_px / 2.0), .y = @intFromFloat(cy - h_px / 2.0), .w = @intFromFloat(@max(w_px, 1.0)), .h = @intFromFloat(@max(h_px, 1.0)) },
        .radius = @intFromFloat(@max(h_px / 2.0, 1.0)),
        .colour = .{ .r = 255, .g = 255, .b = 255, .a = a },
    } }});
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

/// The fixed home layout the live shell always shows — one in-motion task and an active task — used to
/// hit-test the home app grid without rebuilding the full model.
fn homeLayoutModel() home.Model {
    return .{ .tasks = &.{.{ .title = "", .note = "", .hue = theme.teal }}, .active_title = "" };
}

/// The surface an app opens to, or null when its screen does not exist yet (so the tap is ignored rather
/// than opening the wrong screen).
pub fn appSurface(app: iconography.App) ?Surface {
    return switch (app) {
        .phone => .phone,
        .messages => .messages,
        .camera => .camera,
        .agents => .agents,
        .calendar => .calendar,
        .files => .files,
        .contacts => .contacts,
        .settings => .settings,
        .weather => .weather,
        .store => .store,
        .calculator => .calculator,
        .browser, .health, .mail, .notes, .maps => null,
    };
}

/// The surface a tap on the home app grid opens, or null. Hit-tests the grid through the same layout it
/// is drawn with.
pub fn homeGridApp(sx: i32, sy: i32) ?Surface {
    if (home.gridTileAt(homeLayoutModel(), sx, sy)) |app| return appSurface(app);
    return null;
}

/// Whether a tap on the home screen falls on the "All apps" link.
pub fn homeAllApps(sx: i32, sy: i32) bool {
    return home.allAppsAt(homeLayoutModel(), sx, sy);
}

/// Every default application, in the order the library lists them.
const library_apps = [_]iconography.App{
    .agents,   .settings, .messages, .phone,   .calendar,   .files,
    .contacts, .camera,   .weather,  .browser, .calculator, .store,
};

/// The four-column grid geometry the library draws and hit-tests against.
const LibGrid = struct {
    const cols: usize = 4;
    fn cellW() f32 {
        const content = @as(f32, @floatFromInt(width_screen())) - 2.0 * @as(f32, @floatFromInt(pad));
        return (content - u(10) * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    }
    fn tileRect(i: usize) graphics.paint.Rect {
        const col: usize = i % cols;
        const row: usize = i / cols;
        const cw = cellW();
        const tile = u(58);
        const cell_x = @as(f32, @floatFromInt(pad)) + @as(f32, @floatFromInt(col)) * (cw + u(10));
        const top = u(120) + @as(f32, @floatFromInt(row)) * u(90);
        return .{ .x = @intFromFloat(cell_x + (cw - tile) / 2.0), .y = @intFromFloat(top), .w = @intFromFloat(tile), .h = @intFromFloat(tile) };
    }
};

/// The full app list: the reference's "All apps" library, every default application as a labelled tile.
fn renderLibrary(screen: *Framebuffer) void {
    header(screen, "All apps", "Every app on your device");
    for (library_apps, 0..) |app, i| {
        const r = LibGrid.tileRect(i);
        iconography.draw(screen, r, app);
        const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2.0;
        text.drawCentred(screen, cx, @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) + u(13), home.appName(app), u(9.5), s(theme.screen_text_muted));
    }
}

/// The surface a tap on the library grid opens, or null.
pub fn libraryApp(sx: i32, sy: i32) ?Surface {
    for (library_apps, 0..) |app, i| {
        const r = LibGrid.tileRect(i);
        if (sx >= r.x and sx <= r.x + @as(i32, @intCast(r.w)) and sy >= r.y and sy <= r.y + @as(i32, @intCast(r.w)) + @as(i32, @intFromFloat(u(18)))) {
            return appSurface(app);
        }
    }
    return null;
}

// --- Calculator: a working keypad on the real expression domain, open to agents too ---

const CalcKey = struct {
    label: []const u8,
    kind: enum { char, clear, eval, back },
    ch: u8 = 0,
    /// Whether the key is an operator/action, tinted apart from the digits.
    accent: bool = false,
};

/// The keypad, four columns by five rows. Operator characters feed the expression the domain parses.
const calc_keys = [_]CalcKey{
    .{ .label = "C", .kind = .clear, .accent = true },
    .{ .label = "(", .kind = .char, .ch = '(', .accent = true },
    .{ .label = ")", .kind = .char, .ch = ')', .accent = true },
    .{ .label = "/", .kind = .char, .ch = '/', .accent = true },
    .{ .label = "7", .kind = .char, .ch = '7' },
    .{ .label = "8", .kind = .char, .ch = '8' },
    .{ .label = "9", .kind = .char, .ch = '9' },
    .{ .label = "*", .kind = .char, .ch = '*', .accent = true },
    .{ .label = "4", .kind = .char, .ch = '4' },
    .{ .label = "5", .kind = .char, .ch = '5' },
    .{ .label = "6", .kind = .char, .ch = '6' },
    .{ .label = "-", .kind = .char, .ch = '-', .accent = true },
    .{ .label = "1", .kind = .char, .ch = '1' },
    .{ .label = "2", .kind = .char, .ch = '2' },
    .{ .label = "3", .kind = .char, .ch = '3' },
    .{ .label = "+", .kind = .char, .ch = '+', .accent = true },
    .{ .label = "0", .kind = .char, .ch = '0' },
    .{ .label = ".", .kind = .char, .ch = '.' },
    .{ .label = "<", .kind = .back },
    .{ .label = "=", .kind = .eval, .accent = true },
};

fn calcKeyRect(i: usize) graphics.paint.Rect {
    const col: usize = i % 4;
    const row: usize = i / 4;
    const content = @as(f32, @floatFromInt(width_screen())) - 2.0 * @as(f32, @floatFromInt(pad));
    const gap = u(9);
    const kw = (content - gap * 3.0) / 4.0;
    const kh = u(52);
    const top = u(240); // below the display card
    const x = @as(f32, @floatFromInt(pad)) + @as(f32, @floatFromInt(col)) * (kw + gap);
    const y = top + @as(f32, @floatFromInt(row)) * (kh + gap);
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(kw), .h = @intFromFloat(kh) };
}

/// Renders the calculator: a display of the current expression, a keypad, and an agent-presence line
/// that names the very door an agent would compute through — the two doors, side by side.
fn renderCalculator(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Calculator", "Compute \u{00B7} agents welcome here");

    // The display card: the running expression, right-aligned and large.
    const display: graphics.paint.Rect = .{ .x = pad, .y = @intFromFloat(u(112)), .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(74)) };
    paintCard(screen, display);
    const shown = if (inter.calc_len == 0) "0" else inter.calcExpr();
    const size = u(30);
    const tw = text.measure(shown, size);
    _ = text.draw(screen, rightF(display) - u(18) - tw, @as(f32, @floatFromInt(display.y)) + u(48), shown, size, s(theme.screen_text));

    // The agent-presence chip: this app's agent door, open and unprivileged — co-inhabitance made literal.
    agentDoorChip(screen, @floatFromInt(display.x), @as(f32, @floatFromInt(display.y)) + u(90), "calc.evaluate \u{00B7} open to agents");

    // The keypad.
    for (calc_keys, 0..) |key, i| {
        const r = calcKeyRect(i);
        const fill = if (key.accent) sa(theme.agent, 28) else s(theme.screen_card);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = r, .radius = theme.radius_lg, .colour = fill } }});
        const colour = if (key.accent) s(theme.agent) else s(theme.screen_text);
        text.drawCentred(screen, @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2.0, @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2.0 + u(6), key.label, u(17), colour);
    }
}

/// A small violet chip that names an app's agent door — the tool an agent uses on the same surface a
/// person does, so the co-inhabitance is on screen rather than implied.
fn agentDoorChip(screen: *Framebuffer, x: f32, y: f32, label: []const u8) void {
    const max_w = @as(f32, @floatFromInt(width_screen())) - 2.0 * @as(f32, @floatFromInt(pad));
    const tw = @min(text.measureWeighted(label, u(10.5), .semibold), max_w - u(28));
    const chip: graphics.paint.Rect = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(tw + u(28)), .h = @intFromFloat(u(22)) };
    paint.paint(screen, &.{.{ .rounded = .{ .rect = chip, .radius = @intFromFloat(u(11)), .colour = sa(theme.agent, 30) } }});
    vector.fillDisc(screen, x + u(12), y + u(11), u(3.0), s(theme.agent));
    _ = text.drawClipped(screen, x + u(20), y + u(15), label, u(10.5), s(theme.agent), x + u(20) + tw);
}

/// Applies a keypad tap to the interaction state, or does nothing if the tap missed every key. Returns
/// true when a key was hit, so the caller knows the frame changed.
pub fn calcTap(inter: *Interaction, sx: i32, sy: i32) bool {
    for (calc_keys, 0..) |key, i| {
        const r = calcKeyRect(i);
        if (sx >= r.x and sx <= r.x + @as(i32, @intCast(r.w)) and sy >= r.y and sy <= r.y + @as(i32, @intCast(r.h))) {
            switch (key.kind) {
                .char => inter.calcPush(key.ch),
                .clear => inter.calcClear(),
                .back => inter.calcBack(),
                .eval => inter.calcEval(),
            }
            return true;
        }
    }
    return false;
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
    renderScreen(screen, .{ .title = "Files", .sub = "Search stays inside the grant", .sections = &sections, .agent_tool = "files.list \u{00B7} agents search here" });
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
    renderScreen(screen, .{ .title = "Calendar", .sub = "Your day, in blocks", .sections = &sections, .agent_tool = "calendar.read \u{00B7} agents plan here" });
}

/// Weather: saved locations and their current reading, external data an agent may retrieve.
pub fn renderWeather(screen: *Framebuffer) void {
    const places = [_]Row{
        .{ .title = "Lisbon", .sub = "Clear \u{00B7} light breeze", .colour = theme.amber, .value = "24\u{00B0}" },
        .{ .title = "Porto", .sub = "Cloudy", .colour = theme.human, .value = "19\u{00B0}" },
        .{ .title = "Home", .sub = "Rain later", .colour = theme.human, .value = "17\u{00B0}" },
    };
    const sections = [_]Section{.{ .label = "Your places", .rows = &places }};
    renderScreen(screen, .{ .title = "Weather", .sub = "Saved locations", .sections = &sections, .agent_tool = "weather.read \u{00B7} open to agents" });
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
    renderScreen(screen, .{ .title = "Contacts", .sub = "People and principals", .sections = &sections, .agent_tool = "contacts.lookup \u{00B7} agents & principals" });
}

/// The Agents flagship: the roster of agents acting in the person's world, read from the real run —
/// each agent named, in agent-violet, marked LIVE while it works.
const agents_start: i32 = 172;
const agents_row_h: i32 = 62;

fn agentRowRect(i: usize) graphics.paint.Rect {
    return cardRect(agents_start + @as(i32, @intCast(i)) * (agents_row_h + 10), agents_row_h);
}

/// The agent whose row a tap landed on, or null.
pub fn agentRowAt(host: *Host, sx: i32, sy: i32) ?usize {
    const n = @min(host.agents.items.len, @as(usize, @intCast(max_rows)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = agentRowRect(i);
        if (sx >= r.x and sx <= rightI(r) and sy >= r.y and sy <= r.y + @as(i32, @intCast(r.h))) return i;
    }
    return null;
}

/// The agent's live task purpose, read from the graph, or a resting note.
fn agentPurpose(host: *Host, agent: anytype) []const u8 {
    if (host.graph.get(agent.task)) |task| {
        if (task.purpose.len > 0) return task.purpose;
    }
    return "coordinating your day";
}

pub fn renderAgents(screen: *Framebuffer, host: *Host, inter: *const Interaction) void {
    header(screen, "Agents", "Who is acting in your world");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "your agents \u{00B7} tap to open one");

    const n = @min(host.agents.items.len, @as(usize, @intCast(max_rows)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const agent = host.agents.items[i];
        const paused = inter.isAgentPaused(i);
        const rect = card(screen, agentRowRect(i).y, agents_row_h);
        const hue = if (paused) theme.amber else theme.agent;
        vector.fillDisc(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2.0, u(11), sa(hue, 32));
        vector.fillDisc(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2.0, u(4.5), s(hue));
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(42), @as(f32, @floatFromInt(rect.y)) + u(24), agent.name, u(13), s(theme.screen_text));
        _ = text.drawClipped(screen, @as(f32, @floatFromInt(rect.x)) + u(42), @as(f32, @floatFromInt(rect.y)) + u(40), agentPurpose(host, agent), u(10.5), s(theme.screen_text_muted), rightF(rect) - u(70));
        const badge: []const u8 = if (paused) "PAUSED" else "LIVE";
        const bw = text.measureWeighted(badge, u(10), .semibold);
        _ = text.drawWeighted(screen, rightF(rect) - u(18) - bw, @as(f32, @floatFromInt(rect.y)) + u(28), badge, u(10), s(hue), .semibold);
    }
}

/// The detail for the open agent: its name, its live task purpose, and a pause the person controls.
fn renderAgentDetail(screen: *Framebuffer, host: *Host, inter: *const Interaction) void {
    const index = inter.open_agent orelse 0;
    if (index >= host.agents.items.len) {
        header(screen, "Agent", "");
        return;
    }
    const agent = host.agents.items[index];
    const paused = inter.isAgentPaused(index);
    header(screen, agent.name, if (paused) "Paused by you" else "Working in your world");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "scoped, revocable authority");

    const rect = card(screen, 172, 132);
    _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 30), "Doing now", 11, s(theme.screen_text_muted));
    _ = text.drawClipped(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 52), agentPurpose(host, agent), 13, s(theme.screen_text), rightF(rect) - u(22));
    _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 82), "Authority", 11, s(theme.screen_text_muted));
    _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(rect.y + 104), "Scoped \u{00B7} revocable \u{00B7} budgeted", 12, s(theme.screen_text));

    // The pause control — the person holding or releasing this agent.
    const btn = agentPauseRect();
    paint.paint(screen, &.{.{ .rounded = .{ .rect = btn, .radius = @intFromFloat(u(19)), .colour = s(if (paused) theme.teal else theme.amber) } }});
    text.drawCentred(screen, @as(f32, @floatFromInt(btn.x)) + @as(f32, @floatFromInt(btn.w)) / 2.0, @as(f32, @floatFromInt(btn.y)) + u(25), if (paused) "Resume agent" else "Pause agent", u(12.5), s(theme.screen_card));
}

fn agentPauseRect() graphics.paint.Rect {
    const w_px: i32 = @intFromFloat(u(160));
    return .{ .x = @divTrunc(@as(i32, @intCast(width_screen())) - w_px, 2), .y = 340, .w = @intCast(w_px), .h = @intFromFloat(u(40)) };
}

/// Toggles the open agent's pause when the tap lands on the pause button.
pub fn agentDetailTap(inter: *Interaction, sx: i32, sy: i32) bool {
    const btn = agentPauseRect();
    if (sx >= btn.x and sx <= btn.x + @as(i32, @intCast(btn.w)) and sy >= btn.y and sy <= btn.y + @as(i32, @intCast(btn.h))) {
        if (inter.open_agent) |index| inter.toggleAgentPaused(index);
        return true;
    }
    return false;
}

// The approval card's geometry, shared by the renderer and the button hit-test so a tap lands on the
// button drawn.
const approval_card_y: i32 = 128;
const approval_card_h: i32 = 240;
const approval_button_y: i32 = approval_card_y + approval_card_h - 52;

/// A held action awaiting the person, read from the live approvals — the requesting agent, what it
/// reaches, and whether it is still pending.
const HeldAction = struct { agent: []const u8, summary: []const u8, reaches: []const u8, pending: bool };

fn heldAction(host: *Host) HeldAction {
    var it = host.approvals.requests.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.state != .pending) continue;
        var agent: []const u8 = "An agent";
        if (host.registry.lookup(entry.value_ptr.requester)) |actor| agent = actor.display_name;
        const reaches = if (entry.value_ptr.target_kind.len > 0) entry.value_ptr.target_kind else "an external destination";
        return .{ .agent = agent, .summary = entry.value_ptr.summary, .reaches = reaches, .pending = true };
    }
    return .{ .agent = "An agent", .summary = "", .reaches = "", .pending = false };
}

pub fn renderApproval(screen: *Framebuffer, host: *Host) void {
    header(screen, "Approval", "Nothing consequential without you");

    const held = heldAction(host);
    const rect = card(screen, approval_card_y, @intCast(approval_card_h));

    // The requesting agent — an agent proposed this, and it waits for the person: co-inhabitance, at the
    // one point the two are in the loop together.
    vector.fillDisc(screen, @floatFromInt(rect.x + 34), @floatFromInt(rect.y + 40), 16, s(theme.agent));
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 34), held.agent, 14, s(theme.screen_text));
    const asks = if (held.pending) "asks for your decision" else "acted on your decision";
    _ = text.draw(screen, @floatFromInt(rect.x + 60), @floatFromInt(rect.y + 54), asks, 11, s(theme.screen_text_muted));

    const summary = if (held.summary.len > 0) held.summary else "confirm attendance with the venue";
    const rowsy: i32 = rect.y + 84;
    const facts = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "Action", .v = summary },
        .{ .k = "Reaches", .v = if (held.reaches.len > 0) held.reaches else "the venue" },
        .{ .k = "Scope", .v = "Once \u{00B7} cannot repeat" },
    };
    for (facts, 0..) |f, i| {
        const fy = rowsy + @as(i32, @intCast(i)) * 30;
        _ = text.draw(screen, @floatFromInt(rect.x + 22), @floatFromInt(fy), f.k, 11, s(theme.screen_text_muted));
        _ = text.drawClipped(screen, @floatFromInt(rect.x + 22 + 62), @floatFromInt(fy), f.v, 11.5, s(theme.screen_text), rightF(rect) - 22);
    }

    if (held.pending) {
        // Approve / hold buttons — a flex row of two equal cells split by the layout engine.
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
            paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = x, .y = approval_button_y, .w = @intFromFloat(cell.rect.w), .h = 40 }, .radius = theme.radius_lg, .colour = s(cell.fill) } }});
            text.drawCentred(screen, @as(f32, @floatFromInt(x)) + cell.rect.w / 2, @floatFromInt(approval_button_y + 25), cell.label, 12.5, s(cell.ink));
        }
    } else {
        // Decided: a confirmation in place of the buttons, so the screen reflects the real state.
        const done: graphics.paint.Rect = .{ .x = rect.x, .y = approval_button_y, .w = @intCast(rect.w), .h = 40 };
        paint.paint(screen, &.{.{ .rounded = .{ .rect = done, .radius = theme.radius_lg, .colour = sa(theme.teal, 34) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(rect.x)) + @as(f32, @floatFromInt(rect.w)) / 2.0, @floatFromInt(approval_button_y + 25), "Approved \u{00B7} it runs exactly once", 12.5, s(theme.teal));
    }
}

/// A held action the shell offers the person to decide — the travel agent proposes a booking and it
/// waits, so the windowed shell has a live pending approval to approve or hold. Distinct from the
/// canonical run's own approval, which that scenario decides itself.
pub fn arrangePendingApproval(host: *Host) void {
    const travel = host.agentNamed("travel") orelse return;
    // A standalone held task — the run's own tree was cancelled at the end, so this action stands on its
    // own rather than hanging off a cancelled parent.
    const task = host.graph.create(.{
        .owner = travel.id,
        .requester = host.human,
        .purpose = "reserve the venue",
        .budget_bytes = 4 * 1024,
    }) catch return;
    host.graph.transition(task, .waiting_for_approval) catch {};
    _ = host.approvals.request(.{
        .requester = travel.id,
        .approver = host.human,
        .task = task,
        .operation = .send,
        .target_kind = "the venue",
        .summary = "reserve the venue for your trip",
    }) catch return;
    _ = host.ledger.append(.{
        .actor = travel.id,
        .on_behalf_of = host.human,
        .action = .approval_requested,
        .outcome = .awaiting_approval,
        .task = task,
        .target_kind = "the venue",
    }) catch {};
}

/// Decides the held action from a tap on the Approve/Hold buttons. Approve records the human's decision
/// through the real approvals centre; Hold leaves it pending. Returns true when the tap was on a button.
pub fn approvalDecide(host: *Host, sx: i32, sy: i32) bool {
    if (sy < approval_button_y or sy > approval_button_y + 40) return false;
    const content_right = rightI(cardRect(approval_card_y, @intCast(approval_card_h)));
    const mid = @divTrunc(pad + content_right, 2);
    if (sx >= pad and sx < mid - 6) {
        // Approve: record the person's decision on the pending action.
        var it = host.approvals.requests.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .pending) continue;
            host.approvals.decide(entry.value_ptr.id, host.human, .approved) catch {};
            _ = host.ledger.append(.{
                .actor = host.human,
                .action = .approval_decided,
                .outcome = .succeeded,
                .task = entry.value_ptr.task,
                .target_kind = entry.value_ptr.target_kind,
            }) catch {};
            return true;
        }
        return false;
    }
    if (sx >= mid + 6 and sx <= content_right) return true; // Hold: leave it pending
    return false;
}

const StoreItem = struct { name: []const u8, publisher: []const u8, source: applications.store.Source, acknowledged: bool, colour: theme.Colour };

/// The store catalog the person and their agents browse. A reviewed store app installs; a sideload
/// needs the person's acknowledgement; an unacknowledged sideload is blocked.
const store_catalog = [_]StoreItem{
    .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.teal },
    .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.agent },
    .{ .name = "Field Tools", .publisher = "Outside source", .source = .sideload, .acknowledged = true, .colour = theme.amber },
    .{ .name = "Unknown Build", .publisher = "Unreviewed source", .source = .sideload, .acknowledged = false, .colour = theme.denied },
};

const store_start: i32 = 156;
const store_row_h: i32 = 66;

fn storeCardRect(i: usize) graphics.paint.Rect {
    return cardRect(store_start + @as(i32, @intCast(i)) * (store_row_h + 8), store_row_h);
}

/// Whether a catalog item can be installed with one tap — a reviewed store item that is not already in.
fn storeInstallable(item: StoreItem, inter: *const Interaction) bool {
    if (inter.isInstalled(item.name)) return false;
    const needs_ack = applications.store.installNeedsAcknowledgement(item.source);
    return !(needs_ack and !item.acknowledged);
}

pub fn renderStore(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Store", "Reviewed, signed, and sandboxed");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "store.search \u{00B7} agents browse here");

    for (store_catalog, 0..) |item, i| {
        const installed = inter.isInstalled(item.name);
        const needs_ack = applications.store.installNeedsAcknowledgement(item.source);
        const blocked = needs_ack and !item.acknowledged;
        const action: []const u8 = if (installed) "Installed" else if (blocked) "Blocked" else if (needs_ack) "Acknowledge" else "Get";
        const rect = card(screen, storeCardRect(i).y, store_row_h);
        paint.paint(screen, &.{.{ .rounded_vgradient = .{
            .rect = .{ .x = rect.x + 16, .y = rect.y + 15, .w = 36, .h = 36 },
            .radius = 10,
            .top = s(item.colour),
            .bottom = s(item.colour),
        } }});
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 28), item.name, 13, s(theme.screen_text));
        _ = text.draw(screen, @floatFromInt(rect.x + 64), @floatFromInt(rect.y + 46), item.publisher, 10.5, s(theme.screen_text_muted));
        const hue = if (installed) theme.teal else if (blocked) theme.denied else theme.agent;
        const bw = text.measure(action, 11);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = rightI(rect) - 20 - @as(i32, @intFromFloat(bw)) - 20, .y = rect.y + 20, .w = @as(u32, @intFromFloat(bw)) + 24, .h = 26 }, .radius = 13, .colour = s(hue) } }});
        text.drawCentred(screen, rightF(rect) - 20 - bw / 2 - 12, @floatFromInt(rect.y + 37), action, 11, s(theme.screen_card));
    }
}

/// Installs the catalog item whose "Get" a tap landed on, through the real store domain. Returns true
/// when a tap installed something.
pub fn storeTap(inter: *Interaction, sx: i32, sy: i32) bool {
    for (store_catalog, 0..) |item, i| {
        const rect = storeCardRect(i);
        // The action button sits on the right of the row; a generous region so the tap is forgiving.
        if (sy >= rect.y + 20 and sy <= rect.y + 46 and sx >= rightI(rect) - 120 and sx <= rightI(rect) - 12) {
            if (storeInstallable(item, inter)) {
                inter.install(item.name);
                return true;
            }
        }
    }
    return false;
}

// --- The design's data-driven screen model ---
//
// Every app screen in the design is the same shape: a title and sub, then sections, each
// a small label over rows, and each row a coloured dot, a title, a subtitle, and an
// optional value on the right. Rendering from this model — with content taken verbatim
// from the design — is what makes the apps look and read as the design intends.

const Row = struct { title: []const u8, sub: []const u8, colour: theme.Colour, value: []const u8 = "" };
const Section = struct { label: []const u8, rows: []const Row };
const Screen = struct { title: []const u8, sub: []const u8, sections: []const Section, agent_tool: ?[]const u8 = null };

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
    // When the screen names an agent door, the content starts lower to leave room for the chip below
    // the header; otherwise it sits directly under the subtitle.
    const content_top: f32 = if (model.agent_tool != null) 172 else 122;
    graphics.stack.columnTops(content_top, heights[0..n], 0, tops[0..n]);

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

    // The app's agent door, on its own screen: what an agent may do here, so co-inhabitance is visible
    // on every app rather than only where an agent happens to be acting.
    if (model.agent_tool) |tool| agentDoorChip(screen, @floatFromInt(pad), u(96), tool);

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

const MsgBubble = struct { body: []const u8, sender: []const u8, mine: bool };

/// The thread the person is looking in on: two agents negotiating the venue on their behalf, then asking
/// for the one consequential confirmation. The agent-to-agent structure is real in the domain; the words
/// are the human-readable surface of it.
const msg_thread = [_]MsgBubble{
    .{ .body = "The 14th is clear.", .sender = "Calendar agent", .mine = false },
    .{ .body = "Reserving the 2pm slot.", .sender = "Travel agent", .mine = false },
    .{ .body = "Confirm the booking?", .sender = "Travel agent", .mine = false },
};

const msg_reply = MsgBubble{ .body = "Yes \u{2014} go ahead.", .sender = "You", .mine = true };

/// The send button at the foot of the thread, shared by the renderer and the hit-test.
fn msgSendRect() graphics.paint.Rect {
    const w_px: i32 = @intFromFloat(u(120));
    return .{ .x = @divTrunc(@as(i32, @intCast(width_screen())) - w_px, 2), .y = @intCast(phone.screen_h - 96), .w = @intCast(w_px), .h = @intFromFloat(u(38)) };
}

/// Draws one chat bubble at `top`, returning the y below it. The person's messages sit right in the
/// accent; the agents' sit left in a light card, each under its sender's name.
fn chatBubble(screen: *Framebuffer, top: f32, bubble: MsgBubble) f32 {
    const size = u(12.5);
    const max_w = @as(f32, @floatFromInt(width_screen())) * 0.78;
    const tw = @min(text.measure(bubble.body, size), max_w);
    const bw = tw + u(26);
    const bh = u(38);
    const x = if (bubble.mine) @as(f32, @floatFromInt(width_screen())) - @as(f32, @floatFromInt(pad)) - bw else @as(f32, @floatFromInt(pad));
    const fill = if (bubble.mine) s(theme.agent) else s(theme.screen_card);
    const ink = if (bubble.mine) s(theme.screen_card) else s(theme.screen_text);
    paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = @intFromFloat(x), .y = @intFromFloat(top), .w = @intFromFloat(bw), .h = @intFromFloat(bh) }, .radius = @intFromFloat(u(15)), .colour = fill } }});
    _ = text.drawClipped(screen, x + u(13), top + u(24), bubble.body, size, ink, x + bw - u(10));
    // The sender, small and muted, under the bubble on its side.
    const label_x = if (bubble.mine) x + bw - text.measure(bubble.sender, u(9.5)) else x;
    _ = text.draw(screen, label_x, top + bh + u(13), bubble.sender, u(9.5), s(if (bubble.mine) theme.agent else theme.screen_text_muted));
    return top + bh + u(26);
}

pub fn renderMessages(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Messages", "Your agents, negotiating");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "message.send \u{00B7} held for you");

    var y: f32 = u(128);
    for (msg_thread) |bubble| y = chatBubble(screen, y, bubble);
    if (inter.person_replied) _ = chatBubble(screen, y, msg_reply);

    // The foot: how many of the exchanges above were agent-to-agent — read from the real domain — and
    // the send control, which sends the person's reply for real.
    var count_buf: [64]u8 = undefined;
    const count_line = std.fmt.bufPrint(&count_buf, "{d} agent-to-agent exchanges above", .{inter.agentToAgent()}) catch "agent-to-agent above";
    text.drawCentred(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, @floatFromInt(phone.screen_h - 118), count_line, u(10.5), s(theme.screen_text_muted));

    if (!inter.person_replied) {
        const send = msgSendRect();
        paint.paint(screen, &.{.{ .rounded = .{ .rect = send, .radius = @intFromFloat(u(19)), .colour = s(theme.agent) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(send.x)) + @as(f32, @floatFromInt(send.w)) / 2.0, @as(f32, @floatFromInt(send.y)) + u(25), "Send reply", u(12.5), s(theme.screen_card));
    }
}

/// Sends the person's reply when the tap lands on the send button. Returns true when it did.
pub fn messagesTap(inter: *Interaction, sx: i32, sy: i32) bool {
    if (inter.person_replied) return false;
    const send = msgSendRect();
    if (sx >= send.x and sx <= send.x + @as(i32, @intCast(send.w)) and sy >= send.y and sy <= send.y + @as(i32, @intCast(send.h))) {
        inter.sendReply();
        return true;
    }
    return false;
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

test "the calculator keypad drives the real expression domain" {
    var inter = Interaction{};
    // Enter 2+3*4 through the keypad's push, then evaluate — precedence is the domain's, not the shell's.
    for ("2+3*4") |ch| inter.calcPush(ch);
    inter.calcEval();
    try testing.expectEqualStrings("14", inter.calcExpr());
    // A fresh digit after a result starts a new expression rather than appending to it.
    inter.calcPush('9');
    try testing.expectEqualStrings("9", inter.calcExpr());
    // A malformed expression is refused, shown as an error rather than trapping.
    inter.calcClear();
    for ("1/0") |ch| inter.calcPush(ch);
    inter.calcEval();
    try testing.expectEqualStrings("Error", inter.calcExpr());
}

test "the approval screen decides a held action through the real approvals centre" {
    var host: Host = undefined;
    try runScenario(&host, testing.allocator);
    defer host.deinit();
    arrangePendingApproval(&host);
    // The travel agent's held action is waiting for the person.
    try testing.expect(heldAction(&host).pending);
    // A tap on Approve records the decision through the real centre; nothing is left pending.
    try testing.expect(approvalDecide(&host, pad + 4, approval_button_y + 10));
    try testing.expect(!heldAction(&host).pending);
}

test "the store screen installs through the real store domain" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // A reviewed store item is installable and not yet installed.
    try testing.expect(!inter.isInstalled("Itinerary"));
    // A tap on its Get button installs it through the domain; the row now reads as installed.
    const rect = storeCardRect(0);
    try testing.expect(storeTap(&inter, rightI(rect) - 30, rect.y + 33));
    try testing.expect(inter.isInstalled("Itinerary"));
    // A blocked sideload does not install from a tap.
    const blocked = storeCardRect(3);
    try testing.expect(!storeTap(&inter, rightI(blocked) - 30, blocked.y + 33));
    try testing.expect(!inter.isInstalled("Unknown Build"));
}

test "the messages screen sends the person's reply through the real domain" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The seeded thread carries two real agent-to-agent exchanges.
    try testing.expectEqual(@as(usize, 2), inter.agentToAgent());
    try testing.expect(!inter.person_replied);
    // A tap on Send sends the reply through the domain and marks it sent.
    const send = msgSendRect();
    try testing.expect(messagesTap(&inter, send.x + 10, send.y + 10));
    try testing.expect(inter.person_replied);
}

test "the agents screen opens an agent on its real task and the person can pause it" {
    var host: Host = undefined;
    try runScenario(&host, testing.allocator);
    defer host.deinit();
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // A tap on the first agent row selects that agent.
    const r = agentRowRect(0);
    const index = agentRowAt(&host, r.x + 10, r.y + 10) orelse return error.TestUnexpectedResult;
    // The roster shows the agent's real task purpose, not a placeholder.
    try testing.expect(!std.mem.eql(u8, agentPurpose(&host, host.agents.items[index]), "coordinating your day"));
    // The person pauses it from the detail; the state flips.
    inter.open_agent = index;
    try testing.expect(!inter.isAgentPaused(index));
    const btn = agentPauseRect();
    try testing.expect(agentDetailTap(&inter, btn.x + 10, btn.y + 10));
    try testing.expect(inter.isAgentPaused(index));
}
