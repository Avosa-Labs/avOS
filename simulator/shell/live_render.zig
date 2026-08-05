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
const agents = @import("agents");
const core = @import("core");
/// The platform audio seam and the screening audio route. The shell holds one seam, unbound by default,
/// so the headless renderer and CI report "audio unavailable" honestly; the windowed desktop binds a
/// real per-OS backend into it, so the Phone screening path finds a real capture+playback route where a
/// device exists.
const audio_seam = @import("audio");
const screening_audio = @import("screening_route");
/// The platform camera seam. The shell holds one source, unbound by default, so the headless renderer
/// and CI keep the Camera capture path honestly dark; the windowed desktop binds a real per-OS backend
/// into it, so a shutter press takes a real frame where a device exists. The privacy indicator is read
/// from the frame source itself, so a frame cannot be delivered with the light off.
const camera_seam = @import("camera");

/// The app frame the domains already run behind: an in-app agent action reaches a domain only through
/// `framework.App.invoke`, which gates it on the capability, holds a consequential act, and records
/// every step to the ledger — the very same frame the human door funnels through. The shell reaches it
/// so an agent operating an app is gated and ledgered, never a parallel path.
const framework = applications.framework;

/// The on-device mind behind the assistant: honestly unavailable until a runtime is loaded into it.
/// The windowed shell loads the real llama.cpp backend when a weights file is present; the headless
/// renderer and CI leave it unloaded, so the assistant reports itself offline rather than faking a
/// reply.
const LocalMind = agents.model_local_adapter.LocalMind;
const model_interface = agents.model_interface;

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

// The messaging app's fixed shape: how many conversations it holds, how many messages a conversation
// keeps, and the byte length of one message. Fixed capacity keeps the shell's state flat and copy-free.
const max_conv: usize = 12;
const max_conv_msg: usize = 32;
const max_msg_bytes: usize = 96;

// The most cameras the capture path surveys in one pass when opening the viewfinder — past any real
// device's camera count, so the first enumerated camera is always found.
const max_cameras: usize = 16;

/// A live network transport for the running OS: one HTTP GET over `std.http.Client`, presented as the
/// transport seam the weather and geolocation modules read through. The only place the shell touches a
/// socket; the offline tests inject a recorded body instead and never construct this.
const HttpTransport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    fn get(context: *anyopaque, url: []const u8, out: []u8) anyerror![]const u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        var body = std.Io.Writer.fixed(out);
        const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body });
        if (result.status != .ok) return error.HttpStatus;
        return body.buffered();
    }

    fn transport(self: *HttpTransport) applications.weather.open_meteo.Transport {
        return .{ .context = self, .get_fn = get };
    }
};

/// The surfaces the shell can show.
pub const Surface = enum { boot, lock, home, library, calculator, activity, approval, principals, store, rest, shutdown, phone, messages, camera, agents, agent_detail, calendar, weather, contacts, files, settings, browser, notes, health, maps, tasks, music, wallet, photos, clock, smarthome };

// --- In-app agents: the door beside the person's, gated and recorded through the same frame ---
//
// Each of these apps carries a real in-app agent that operates the app through its registered
// capabilities. An agent action runs the app's own domain `execute` — the exact function the person's
// finger runs — reached through `framework.App.invoke`, so it is capability-gated, held when it would
// notify others, and recorded to the ledger. The presence a surface shows is DERIVED from the domain
// result and the ledger outcome, never a self-reported transcript.

/// The principals the in-app agents act under — distinct ids so each app's action is attributable and
/// separate from the person (principal 0). An agent holds only its own app's capability.
const files_agent: core.identity.PrincipalId = .{ .value = 0xA1 };
const weather_agent: core.identity.PrincipalId = .{ .value = 0xA2 };
const calendar_agent: core.identity.PrincipalId = .{ .value = 0xA3 };
const notes_agent: core.identity.PrincipalId = .{ .value = 0xA4 };
const contacts_agent: core.identity.PrincipalId = .{ .value = 0xA5 };
const browser_agent: core.identity.PrincipalId = .{ .value = 0xB1 };
const store_agent: core.identity.PrincipalId = .{ .value = 0xB2 };
const phone_agent: core.identity.PrincipalId = .{ .value = 0xB3 };
const settings_agent: core.identity.PrincipalId = .{ .value = 0xB4 };
const maps_agent: core.identity.PrincipalId = .{ .value = 0xB5 };
const health_agent: core.identity.PrincipalId = .{ .value = 0xB6 };
const messages_agent: core.identity.PrincipalId = .{ .value = 0xB7 };
const tasks_agent: core.identity.PrincipalId = .{ .value = 0xB8 };
const music_agent: core.identity.PrincipalId = .{ .value = 0xB9 };
const wallet_agent: core.identity.PrincipalId = .{ .value = 0xBA };
const photos_agent: core.identity.PrincipalId = .{ .value = 0xBB };
const clock_agent: core.identity.PrincipalId = .{ .value = 0xBC };
const home_agent: core.identity.PrincipalId = .{ .value = 0xBD };

fn agentActor(principal: core.identity.PrincipalId) framework.Actor {
    return .{ .kind = .agent, .principal = principal };
}

// The capabilities each in-app agent may present, keyed by the operation string the human door uses,
// with the approval class the operation carries: a read is silent, a local change notifies, and an act
// that reaches other people is held. `admit` matches the tool name to the operation, so a call an agent
// makes reaches exactly the domain door the person's does.
const files_tools = [_]framework.Tool{
    .{ .name = "file.search", .required_capability = "files.search", .effect = .read_only },
    .{ .name = "file.move", .required_capability = "files.organize", .effect = .local_mutation },
    .{ .name = "file.revert", .required_capability = "files.organize", .effect = .local_mutation },
};
const weather_tools = [_]framework.Tool{
    .{ .name = "weather.current", .required_capability = "weather.current", .effect = .read_only },
};
const calendar_tools = [_]framework.Tool{
    .{ .name = "calendar.add", .required_capability = "calendar.propose", .effect = .local_mutation },
    .{ .name = "calendar.invite", .required_capability = "calendar.commit", .effect = .external },
};
const notes_tools = [_]framework.Tool{
    .{ .name = "note.search", .required_capability = "notes.read", .effect = .read_only },
    .{ .name = "note.create", .required_capability = "notes.write", .effect = .local_mutation },
};
const contacts_tools = [_]framework.Tool{
    .{ .name = "contact.search", .required_capability = "contacts.lookup", .effect = .read_only },
};
// The messages agent: reading the thread is silent, drafting a reply is a local notify (it changes only
// the person's own draft), but sending reaches another person, so it is always held.
const messages_tools = [_]framework.Tool{
    .{ .name = "message.read", .required_capability = "messages.read", .effect = .read_only },
    .{ .name = "message.draft", .required_capability = "messages.draft", .effect = .local_mutation },
    .{ .name = "message.send", .required_capability = "messages.send", .effect = .external },
};
// The web-research agent: reading the current page's projection is silent, navigating to a page is a
// notify, and filling a form is a local stage — but submitting it sends off the device, so it is held.
const browser_tools = [_]framework.Tool{
    .{ .name = "browser.read_page", .required_capability = "browser.read", .effect = .read_only },
    .{ .name = "browser.open", .required_capability = "browser.open", .effect = .local_mutation },
    .{ .name = "browser.fill", .required_capability = "browser.form", .effect = .local_mutation },
    .{ .name = "browser.submit", .required_capability = "browser.form", .effect = .external },
};
// The store agent: browsing the catalogue is silent, but installing grants a package its declared
// authority — a value-bearing act that is always held for the person, whatever the package.
const store_tools = [_]framework.Tool{
    .{ .name = "store.browse", .required_capability = "store.search", .effect = .read_only },
    .{ .name = "store.install", .required_capability = "store.install", .effect = .value_transfer },
};
// The screening agent: screening an unknown caller is a local notify (it records an untrusted state
// for the person to judge); placing a call reaches another person, so it is held.
const phone_tools = [_]framework.Tool{
    .{ .name = "call.screen", .required_capability = "phone.screen", .effect = .local_mutation },
    .{ .name = "call.dial", .required_capability = "phone.call", .effect = .external },
};
// The settings agent: reading a value is silent; toggling an open setting is a notify. A sensitive
// (human_only) key is refused by the domain itself, so no agent write can flip it.
const settings_tools = [_]framework.Tool{
    .{ .name = "settings.read", .required_capability = "settings.read", .effect = .read_only },
    .{ .name = "settings.toggle", .required_capability = "settings.write", .effect = .local_mutation },
};
// Maps and Health are read-mostly for agents: an on-device distance and an on-device summary, both
// silent reads over the app's real local domain.
const maps_tools = [_]framework.Tool{
    .{ .name = "maps.distance", .required_capability = "maps.read", .effect = .read_only },
};
const health_tools = [_]framework.Tool{
    .{ .name = "health.summary", .required_capability = "health.read", .effect = .read_only },
};
// The six apps below already declare their capability registry and an `open` constructor in their own
// module (`applications.tasks.tools`, `applications.tasks.open`, …), so the shell reuses those rather
// than restating them — the same door the app itself publishes.

/// The last real agent action in an app, for the uniform presence layer. Every field is derived from
/// the domain result and the ledger outcome, so the row is ground truth, never a scripted line. A held
/// action carries the exact keyed operation to run once when the person approves; a revertible one
/// carries the undo. Fixed buffer: the render reads it without allocating.
pub const AgentRow = struct {
    status: enum { none, executed, held, denied, unavailable } = .none,
    /// The door the agent used — the operation and the capability it presented, shown in the chip.
    door: []const u8 = "",
    detail: [96]u8 = undefined,
    detail_len: usize = 0,
    /// The one control the footer offers and the keyed operation it runs, both exactly-once: Approve
    /// completes a held commit, Revert undoes a revertible organize.
    control: enum { none, approve, revert } = .none,
    op: []const u8 = "",
    args: []const u8 = "",
    key: u128 = 0,

    fn say(row: *AgentRow, line: []const u8) void {
        const n = @min(line.len, row.detail.len);
        @memcpy(row.detail[0..n], line[0..n]);
        row.detail_len = n;
    }

    pub fn message(row: *const AgentRow) []const u8 {
        return row.detail[0..row.detail_len];
    }
};

/// Formats a whole-cent amount as a currency string into `buf`, e.g. 8650 → "$86.50".
fn centsLabel(cents: i64, buf: []u8) []const u8 {
    const magnitude = if (cents < 0) -cents else cents;
    const whole = @divTrunc(magnitude, 100);
    const frac: u64 = @intCast(@mod(magnitude, 100));
    const sign = if (cents < 0) "-" else "";
    return std.fmt.bufPrint(buf, "{s}${d}.{d:0>2}", .{ sign, whole, frac }) catch "$-";
}

/// The in-grant image paths the device holds, written into `out` — the real media the photo gallery is
/// built from, filtered from the file tree by grant and extension. Same set the library seeds with.
fn imagePaths(out: [][]const u8) []const []const u8 {
    var n: usize = 0;
    for (file_entries) |entry| {
        if (n >= out.len) break;
        if (!applications.files.withinGrant(entry.path)) continue;
        if (!isImagePath(entry.path)) continue;
        out[n] = entry.path;
        n += 1;
    }
    return out[0..n];
}

/// Whether a file path names an image the photo library should hold — decided by its extension, so the
/// gallery is populated from the real media on the device rather than a fabricated set.
fn isImagePath(path: []const u8) bool {
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".heic", ".gif" };
    for (exts) |ext| {
        if (path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// The person's own tasks the list seeds with. The surface renders exactly this set and queries each
/// for its real done state, so an agent's or a tap's completion shows against the same rows.
const task_seeds = [_][]const u8{ "Confirm the studio booking", "Pay the electricity bill", "Reply to Marco", "Water the plants" };

/// The person's own cards in the wallet — only the last four ever live here, as the domain models — and
/// the wallet's opening stored-value balance in whole cents.
const WalletCard = struct { name: []const u8, last4: []const u8 };
const wallet_cards = [_]WalletCard{
    .{ .name = "Everyday", .last4 = "4242" },
    .{ .name = "Travel", .last4 = "0005" },
};
const wallet_opening_cents: i64 = 8650;
/// The payment the wallet agent stages for the person to approve: amount in cents and a merchant label.
const wallet_pay_arg = "1250@Roastery";

/// The smart-home devices the home seeds with — real lights, a plug, and a lock the UI toggles. A lock
/// starts engaged.
const HomeDevice = struct { name: []const u8, kind: applications.home_domain.Kind };
const home_devices = [_]HomeDevice{
    .{ .name = "Living Room", .kind = .light },
    .{ .name = "Desk Lamp", .kind = .light },
    .{ .name = "Coffee Maker", .kind = .plug },
    .{ .name = "Front Door", .kind = .lock },
};
/// The lock the home agent stages an unlock of (held), and the light it switches on (notify).
const home_lock_name = "Front Door";
const home_light_on_arg = "Living Room@on";

/// The saved world clocks, labelled by their UTC offset (no place names) and computed on device from the
/// real zone arithmetic. Each seeds through the clock's text door as "<label>@<offset hours>".
const WorldClockSeed = struct { label: []const u8, offset_hours: i32 };
const world_clocks = [_]WorldClockSeed{
    .{ .label = "UTC-08:00", .offset_hours = -8 },
    .{ .label = "UTC+01:00", .offset_hours = 1 },
    .{ .label = "UTC+09:00", .offset_hours = 9 },
};

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
    /// The settings' real values, so a toggle actually changes one.
    settings_state: applications.settings.Store = undefined,
    /// The weather app's live current reading, hourly forecast, and alert, held in its domain.
    weather_state: applications.weather.Store = undefined,
    /// The device's current city, resolved from the network at start; empty until a lookup succeeds.
    weather_city: [48]u8 = undefined,
    weather_city_len: usize = 0,
    /// The contacts book — real people and the non-human principals co-inhabiting the person's world.
    contacts_state: applications.contacts.Store = undefined,
    /// Which contact fields the person has granted their agents to read (a field-scoped grant).
    agent_grant: applications.contacts.FieldSet = .initEmpty(),
    /// The files tree, and the last entry a tap tried to open (with whether the grant allowed it).
    files_state: applications.files.Store = undefined,
    file_opened: ?usize = null,
    file_open_ok: bool = false,
    /// The notebook — real notes the person and their agents write and read.
    notes_state: applications.notes.Store = undefined,
    /// The task list — real tasks, some added or completed by an agent.
    tasks_state: applications.tasks.Store = undefined,
    /// The music library, what is playing, and the queue — a fully local media domain (no seeded
    /// catalogue: the library is whatever real tracks the device holds, honestly empty until then).
    music_state: applications.music.Store = undefined,
    /// The wallet — the person's cards and a real stored-value balance a payment debits exactly once.
    wallet_state: applications.wallet.Store = undefined,
    /// The photo library, over the real media the device holds — imported from the on-device file tree.
    photos_state: applications.photos.Store = undefined,
    /// The saved world clocks, whose local times are computed on device from the real zone rules.
    clock_state: applications.clock.Store = undefined,
    /// The instant the clock surface reads as the device's current time, captured once at start.
    clock_now: core.time.Timestamp = undefined,
    /// The smart-home devices — lights, plugs, and a lock — with real on/off state the UI toggles.
    home_state: applications.home.Store = undefined,
    /// Health readings, kept strictly on device; the surface shows their real averages.
    health_state: applications.health.Store = undefined,
    /// Saved places, and the on-device distances between them.
    maps_state: applications.maps.Store = undefined,
    /// The calendar's real events, from which each hour's free/busy is computed.
    calendar_state: applications.calendar.Store = undefined,
    /// The browser's real history, current page, bookmarks, and per-site permissions.
    browser_state: applications.browser.Store = undefined,
    /// The call log, block list, and the untrusted screenings the agent records for the person.
    phone_state: applications.phone.Store = undefined,
    /// The platform audio seam the Phone screening path answers a call over. Unbound by default, so the
    /// headless renderer and CI honestly report no audio; the windowed desktop binds a real per-OS
    /// backend into it. Held here (not a global) so each interaction owns its own audio state.
    audio_route: audio_seam.Audio = .{},
    /// The platform camera seam the Camera capture path takes frames from. Unbound and dark by default,
    /// so the headless renderer and CI never light a camera; the windowed desktop binds a real per-OS
    /// backend into it. Held here (not a global) so each interaction owns its own camera state, and the
    /// privacy indicator is read from this source, never from a flag the shell sets.
    camera_source: camera_seam.CameraSource = .{},
    // The messaging app's conversations, held in the shell: each a correspondent and the messages
    // exchanged, one of which the person is looking at. A sent message is written here and pushed
    // through the messages domain, so the send is recorded and the thread shows what was said.
    conv_count: usize = 0,
    open_conv: ?usize = null,
    conv_names: [max_conv][24]u8 = undefined,
    conv_name_lens: [max_conv]usize = [_]usize{0} ** max_conv,
    conv_msg_count: [max_conv]usize = [_]usize{0} ** max_conv,
    conv_bodies: [max_conv][max_conv_msg][max_msg_bytes]u8 = undefined,
    conv_body_lens: [max_conv][max_conv_msg]usize = undefined,
    conv_mine: [max_conv][max_conv_msg]bool = undefined,
    compose_len: usize = 0,
    compose_buf: [max_msg_bytes]u8 = undefined,
    // True while the person is typing the name of someone to start a new conversation with. The typed
    // text shares `compose_buf`, since only one text field is ever active at a time.
    composing_new: bool = false,
    /// Which agent's detail is open (an index into the roster), and which agents the person has paused.
    open_agent: ?usize = null,
    agent_paused: [8]bool = [_]bool{false} ** 8,
    /// The person's decision on the screened incoming call: null while it waits, then answered or not.
    call_answered: ?bool = null,
    /// The camera mode the person has selected.
    camera_mode: applications.camera.Mode = .capture,
    /// The camera's captured shots, held in the app's domain so a shutter press records a real shot.
    camera_state: applications.camera.Store = undefined,
    /// The selected zoom step (an index into `camera_zooms`) and whether Video is armed over Photo.
    camera_zoom: usize = 1,
    camera_video: bool = false,
    /// The shape of the most recent frame a real bound camera delivered to a shutter press, or null on a
    /// host without one. Only a frame's shape is held — never pixels, never a fabricated frame — so the
    /// surface can show the real capture resolution where a device delivered one.
    camera_frame: ?camera_seam.Frame = null,
    store_ready: bool = false,
    next_key: u128 = 1,
    /// The control plane the in-app agents' actions are gated and recorded through: an identifier
    /// source, a clock, and the audit ledger every `framework.App.invoke` writes to. The shell owns
    /// them so an agent operating an app funnels through the same frame the person's door does, rather
    /// than a shell-only shortcut. Live after `attach`.
    ids: core.identity.Source = undefined,
    agent_clock: core.time.ManualClock = undefined,
    ledger: framework.Ledger = undefined,
    /// The last real agent action in each agentic app, derived from the domain result — what the
    /// uniform agent-presence layer renders. Populated by `seedAgentPresence` and the live paths.
    files_agent_row: AgentRow = .{},
    weather_agent_row: AgentRow = .{},
    calendar_agent_row: AgentRow = .{},
    notes_agent_row: AgentRow = .{},
    contacts_agent_row: AgentRow = .{},
    browser_agent_row: AgentRow = .{},
    store_agent_row: AgentRow = .{},
    phone_agent_row: AgentRow = .{},
    settings_agent_row: AgentRow = .{},
    maps_agent_row: AgentRow = .{},
    health_agent_row: AgentRow = .{},
    messages_agent_row: AgentRow = .{},
    tasks_agent_row: AgentRow = .{},
    music_agent_row: AgentRow = .{},
    wallet_agent_row: AgentRow = .{},
    photos_agent_row: AgentRow = .{},
    clock_agent_row: AgentRow = .{},
    home_agent_row: AgentRow = .{},
    /// The hour the calendar agent proposed a focus block on, so the day renders that block in the
    /// agent's outline rather than as an indistinguishable committed one. Null until it proposes.
    calendar_proposed_slot: ?u32 = null,
    /// The on-device mind the assistant asks. Unloaded (offline) until the windowed shell binds a real
    /// runtime; the seam keeps this honest, so an unbound mind returns no reply rather than a fake one.
    assistant_mind: LocalMind = .{},
    /// The assistant's last reply (a slice into this buffer), untrusted like any mind output.
    assistant_reply: [512]u8 = [_]u8{0} ** 512,
    assistant_reply_len: usize = 0,
    /// What the person has typed into the command bar, before they send it.
    assistant_prompt: [128]u8 = [_]u8{0} ** 128,
    assistant_prompt_len: usize = 0,

    /// Appends a typed byte to the command-bar question.
    pub fn assistantType(self: *Interaction, ch: u8) void {
        if (self.assistant_prompt_len < self.assistant_prompt.len) {
            self.assistant_prompt[self.assistant_prompt_len] = ch;
            self.assistant_prompt_len += 1;
        }
    }

    /// Removes the last typed byte from the command-bar question.
    pub fn assistantBackspace(self: *Interaction) void {
        if (self.assistant_prompt_len > 0) self.assistant_prompt_len -= 1;
    }

    pub fn assistantPrompt(self: *const Interaction) []const u8 {
        return self.assistant_prompt[0..self.assistant_prompt_len];
    }

    /// Whether the assistant can answer right now: only when a mind runtime is bound. Read at the
    /// source, so the home surface shows "offline" honestly when no model is loaded.
    pub fn assistantAvailable(self: *const Interaction) bool {
        return self.assistant_mind.isLoaded();
    }

    /// Binds a real on-device runtime to the assistant's mind. The windowed shell calls this with the
    /// llama.cpp backend when a weights file is present; without one the mind stays offline.
    pub fn loadMind(self: *Interaction, backend: agents.model_local_adapter.Backend) void {
        self.assistant_mind.load(backend);
    }

    /// Asks the assistant through the bound mind, storing the untrusted reply. With no mind bound it
    /// produces nothing - offline, honestly, never a fabricated answer. The bound backend holds the
    /// prompt context the runtime runs over.
    pub fn assistantAsk(self: *Interaction) void {
        self.assistant_reply_len = 0;
        const bound = self.assistant_mind.asMind();
        if (bound.health() != .available) return;
        const proposal = bound.propose(.{ .max_tokens = 128 });
        const n = @min(proposal.text.len, self.assistant_reply.len);
        @memcpy(self.assistant_reply[0..n], proposal.text[0..n]);
        self.assistant_reply_len = n;
    }

    pub fn assistantReply(self: *const Interaction) []const u8 {
        return self.assistant_reply[0..self.assistant_reply_len];
    }

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
        // The control plane the in-app agents record through. The ledger borrows `self.ids`, so the
        // interaction must not be copied after this — the same rule the host holds its services under.
        self.ids = .initDeterministic(0xA6);
        self.agent_clock = .init(.fromSeconds(1_767_225_600));
        self.ledger = .init(gpa, &self.ids, self.agent_clock.clock());
        self.store_state = applications.store.Store.init(gpa);
        self.msgs_state = applications.messages.Store.init(gpa);
        self.settings_state = applications.settings.Store.init(gpa);
        self.weather_state = applications.weather.Store.init(gpa, applications.weather.Deterministic.connector());
        self.contacts_state = applications.contacts.Store.init(gpa);
        self.files_state = applications.files.Store.init(gpa);
        // Seed the tree: the in-grant entries the screen opens for real (the escaping one is not
        // added — the grant refuses it before the tree is ever touched).
        for (file_entries) |entry| {
            if (applications.files.withinGrant(entry.path)) self.files_state.add(entry.path, entry.is_dir) catch {};
        }
        // The notebook: a few notes the person and their agents keep.
        self.notes_state = applications.notes.Store.init(gpa);
        for ([_][]const u8{ "Groceries|milk, eggs, coffee", "Trip ideas|Lisbon in autumn", "Studio|book the room for Friday" }, 1..) |note, key| {
            _ = applications.notes.Store.execute(&self.notes_state, .{ .operation = "note.create", .args = note }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        // The task list: real tasks, one already completed by the person.
        self.tasks_state = applications.tasks.Store.init(gpa);
        for (task_seeds, 1..) |task, key| {
            _ = applications.tasks.Store.execute(&self.tasks_state, .{ .operation = "task.add", .args = task }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        _ = applications.tasks.Store.execute(&self.tasks_state, .{ .operation = "task.complete", .args = "Reply to Marco" }, .{ .kind = .human, .principal = .{ .value = 0 } }, 90);
        // A few on-device health readings so the summary reads live.
        self.health_state = applications.health.Store.init(gpa);
        for ([_][]const u8{ "steps@6240@2026-07-29", "steps@8100@2026-07-28", "heart_rate@62@2026-07-29", "weight@71@2026-07-29" }, 1..) |r, key| {
            _ = applications.health.Store.execute(&self.health_state, .{ .operation = "health.record", .args = r }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        // A few saved places, with real coordinates the distance is computed from.
        self.maps_state = applications.maps.Store.init(gpa);
        for ([_][]const u8{ "Home@0,0", "Studio@30,40", "Market@30,0" }, 1..) |place, key| {
            _ = applications.maps.Store.execute(&self.maps_state, .{ .operation = "maps.save", .args = place }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        // The wallet: the person's own cards and a real stored-value balance a payment debits once.
        self.wallet_state = applications.wallet.Store.init(gpa);
        for (wallet_cards, 1..) |c, key| {
            var arg_buf: [40]u8 = undefined;
            const arg = std.fmt.bufPrint(&arg_buf, "{s}@{s}", .{ c.name, c.last4 }) catch continue;
            _ = applications.wallet.Store.execute(&self.wallet_state, .{ .operation = "wallet.add_card", .args = arg }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        self.wallet_state.fund(wallet_opening_cents);
        // The smart home: real lights, a plug, and a lock, each in its starting state (a lock engaged).
        self.home_state = applications.home.Store.init(gpa);
        for (home_devices) |d| {
            self.home_state.addDevice(d.name, d.kind, d.kind == .lock) catch {};
        }
        // The photo library, over the real on-device media: the in-grant image files the file tree holds.
        self.photos_state = applications.photos.Store.init(gpa);
        var photo_key: u128 = 1;
        for (file_entries) |entry| {
            if (!applications.files.withinGrant(entry.path)) continue;
            if (!isImagePath(entry.path)) continue;
            _ = applications.photos.Store.execute(&self.photos_state, .{ .operation = "photo.import", .args = entry.path }, .{ .kind = .human, .principal = .{ .value = 0 } }, photo_key);
            photo_key += 1;
        }
        // The music library carries no seeded catalogue: it holds whatever real tracks the device has, so
        // it opens honestly empty until the person adds their own. The domain is live all the same.
        self.music_state = applications.music.Store.init(gpa);
        // The world clocks, labelled by UTC offset and read against the device's current instant. This
        // starts at a fixed instant so a headless render is deterministic; the running shell calls
        // `captureDeviceTime` with its io to read the device's real wall clock.
        self.clock_state = applications.clock.Store.init(gpa);
        self.clock_now = core.time.Timestamp.fromSeconds(1_767_225_600);
        // Seed through the typed entry point with the stable label constants — the domain keeps the label
        // by reference, so a stack-buffer arg through the text door would dangle.
        for (world_clocks) |wc| {
            self.clock_state.addClock(wc.label, .{ .standard_offset_seconds = wc.offset_hours * 3600 }) catch {};
        }
        self.camera_state = applications.camera.Store.init(gpa);
        self.calendar_state = applications.calendar.Store.init(gpa);
        // Seed the day: a two-hour block and a meeting, so the day already reads as committed time.
        for ([_][]const u8{ "Design review@9", "Design review@10", "Team sync@14" }, 1..) |ev, key| {
            _ = applications.calendar.Store.execute(&self.calendar_state, .{ .operation = "calendar.add", .args = ev }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        // Weather has no seeded places: the running shell resolves the device's real current location
        // and fetches its live reading through `weatherRefresh`. Offline, the app says it is unlocated.
        // The seeds above used small per-domain keys; advance the shared key sequence past them so a
        // later tap-driven change (a booking, a send) never collides with a seed key and gets swallowed
        // by the exactly-once guard.
        self.next_key = 1000;
        // Seed the address book: people, and the non-human principals a person co-inhabits with.
        self.contactsSeed();
        // The person starts by letting agents read a contact's name and phone, not their private fields.
        self.agent_grant.insert(.name);
        self.agent_grant.insert(.phone);
        self.browser_state = applications.browser.Store.init(gpa, applications.browser.Deterministic.engine());
        // Land on a starting page so the address bar and its projection read live.
        self.browserOpen(browser_home);
        self.phone_state = applications.phone.Store.init(gpa);
        self.store_ready = true;
    }

    pub fn release(self: *Interaction) void {
        // Stop any live capture session before the interaction goes away, so the camera is never left
        // running past the run — the indicator follows the source off. Idempotent when nothing streams.
        self.camera_source.stop();
        if (self.store_ready) {
            self.store_state.deinit();
            self.msgs_state.deinit();
            self.settings_state.deinit();
            self.weather_state.deinit();
            self.contacts_state.deinit();
            self.files_state.deinit();
            self.notes_state.deinit();
            self.tasks_state.deinit();
            self.music_state.deinit();
            self.wallet_state.deinit();
            self.photos_state.deinit();
            self.clock_state.deinit();
            self.home_state.deinit();
            self.health_state.deinit();
            self.maps_state.deinit();
            self.calendar_state.deinit();
            self.browser_state.deinit();
            self.phone_state.deinit();
            self.camera_state.deinit();
            self.ledger.deinit();
        }
    }

    // --- The in-app agents: real, gated, ledgered work over the same domains the person's door reaches ---

    /// The Files agent's door onto the real files tree. Constructed over the shared ledger, so a move it
    /// makes runs `files.Store.execute` — the exact function `fileOpen` runs — recorded as it goes.
    fn filesApp(self: *Interaction) framework.App {
        return .{ .name = "Files", .domain = self.files_state.domain(), .tools = .{ .tools = &files_tools }, .ledger = &self.ledger };
    }
    fn weatherApp(self: *Interaction) framework.App {
        return .{ .name = "Weather", .domain = self.weather_state.domain(), .tools = .{ .tools = &weather_tools }, .ledger = &self.ledger };
    }
    fn calendarApp(self: *Interaction) framework.App {
        return .{ .name = "Calendar", .domain = self.calendar_state.domain(), .tools = .{ .tools = &calendar_tools }, .ledger = &self.ledger };
    }
    fn notesApp(self: *Interaction) framework.App {
        return .{ .name = "Notes", .domain = self.notes_state.domain(), .tools = .{ .tools = &notes_tools }, .ledger = &self.ledger };
    }
    fn contactsApp(self: *Interaction) framework.App {
        return .{ .name = "Contacts", .domain = self.contacts_state.domain(), .tools = .{ .tools = &contacts_tools }, .ledger = &self.ledger };
    }
    fn browserApp(self: *Interaction) framework.App {
        return .{ .name = "Browser", .domain = self.browser_state.domain(), .tools = .{ .tools = &browser_tools }, .ledger = &self.ledger };
    }
    fn storeApp(self: *Interaction) framework.App {
        return .{ .name = "Store", .domain = self.store_state.domain(), .tools = .{ .tools = &store_tools }, .ledger = &self.ledger };
    }
    fn phoneApp(self: *Interaction) framework.App {
        return .{ .name = "Phone", .domain = self.phone_state.domain(), .tools = .{ .tools = &phone_tools }, .ledger = &self.ledger };
    }
    fn settingsApp(self: *Interaction) framework.App {
        return .{ .name = "Settings", .domain = self.settings_state.domain(), .tools = .{ .tools = &settings_tools }, .ledger = &self.ledger };
    }
    fn mapsApp(self: *Interaction) framework.App {
        return .{ .name = "Maps", .domain = self.maps_state.domain(), .tools = .{ .tools = &maps_tools }, .ledger = &self.ledger };
    }
    fn healthApp(self: *Interaction) framework.App {
        return .{ .name = "Health", .domain = self.health_state.domain(), .tools = .{ .tools = &health_tools }, .ledger = &self.ledger };
    }
    fn messagesApp(self: *Interaction) framework.App {
        return .{ .name = "Messages", .domain = self.msgs_state.domain(), .tools = .{ .tools = &messages_tools }, .ledger = &self.ledger };
    }
    fn tasksApp(self: *Interaction) framework.App {
        return applications.tasks.open(&self.tasks_state, &self.ledger);
    }
    fn musicApp(self: *Interaction) framework.App {
        return applications.music.open(&self.music_state, &self.ledger);
    }
    fn walletApp(self: *Interaction) framework.App {
        return applications.wallet.open(&self.wallet_state, &self.ledger);
    }
    fn photosApp(self: *Interaction) framework.App {
        return applications.photos.open(&self.photos_state, &self.ledger);
    }
    fn clockApp(self: *Interaction) framework.App {
        return applications.clock.open(&self.clock_state, &self.ledger);
    }
    fn homeApp(self: *Interaction) framework.App {
        return applications.home.open(&self.home_state, &self.ledger);
    }

    /// The Files agent tidies the real tree: it moves a document into an archive folder through
    /// `file.move` (notify — a local change the person is told about, not asked). The files actually
    /// move, and the move is revertible from the recorded state, so the footer offers a one-tap undo.
    pub fn filesAgentOrganize(self: *Interaction) void {
        if (!self.store_ready or self.files_agent_row.status != .none) return;
        var app = self.filesApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.files_agent_row;
        row.door = "files.organize";
        const outcome = app.invoke(agentActor(files_agent), .{ .operation = "file.move", .args = "documents/budget.csv>documents/archive/budget.csv" }, "files.organize", true, key) catch {
            row.status = .unavailable;
            row.say("Files agent unavailable");
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                row.control = .revert;
                row.op = "file.revert";
                row.args = "";
                // Derived from the tree: how many files now live under the archive folder the agent made.
                var buf: [8][]const u8 = undefined;
                const filed = self.files_state.search("archive/", &buf).len;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Filed budget.csv \u{00B7} {d} archived", .{filed}) catch "Filed a document into archive");
            },
            .held => row.status = .held,
            .denied => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
            .failed => {
                row.status = .executed;
                row.say("Nothing to organize");
            },
        }
    }

    /// Undoes the Files agent's last move through `file.revert` (agent door, exactly-once by key),
    /// restoring the exact prior tree. The footer's Revert control runs this.
    pub fn filesAgentRevert(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.files_agent_row;
        if (row.control != .revert) return;
        var app = self.filesApp();
        const key = self.next_key;
        self.next_key += 1;
        const outcome = app.invoke(agentActor(files_agent), .{ .operation = row.op, .args = row.args }, "files.organize", true, key) catch return;
        if (outcome == .executed) {
            row.control = .none;
            var buf: [8][]const u8 = undefined;
            const filed = self.files_state.search("archive/", &buf).len;
            var line: [96]u8 = undefined;
            row.say(std.fmt.bufPrint(&line, "Reverted \u{00B7} {d} archived, tree restored", .{filed}) catch "Reverted \u{00B7} tree restored");
        }
    }

    /// The Weather agent refreshes the current forecast through `weather.current` (silent — a read of
    /// external data). It reads the real device location's reading through the domain; a read must not
    /// disturb what the device fetched live, so the live reading the CI connector would overwrite is
    /// restored (in production the connector returns the live reading and this is a no-op).
    pub fn weatherAgentRefresh(self: *Interaction) void {
        if (!self.store_ready or self.weather_city_len == 0) return;
        const city = self.weatherCity();
        const live_before = self.weather_state.cached(city);
        var app = self.weatherApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.weather_agent_row;
        row.door = "weather.current \u{00B7} live";
        const outcome = app.invoke(agentActor(weather_agent), .{ .operation = "weather.current", .args = city }, "weather.current", true, key) catch {
            row.status = .unavailable;
            row.say("Weather agent unavailable");
            return;
        };
        if (live_before) |b| self.weather_state.injectCurrent(city, b.reading);
        switch (outcome) {
            .executed => {
                row.status = .executed;
                if (self.weatherReading()) |r| {
                    var line: [96]u8 = undefined;
                    row.say(std.fmt.bufPrint(&line, "Refreshed {s} \u{00B7} {d}\u{00B0} {s}", .{ city, r.temp_c, weatherLabel(r.condition) }) catch "Refreshed the current forecast");
                } else row.say("Refreshed the current forecast");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} the agent holds no location grant");
            },
        }
    }

    /// The Calendar agent proposes a focus block on the first free working hour, computed over the real
    /// events already in the calendar, and commits it through `calendar.add` (notify). The booked hour
    /// is remembered so the day draws it in the agent's outline, distinct from the person's own blocks.
    pub fn calendarAgentPropose(self: *Interaction) void {
        if (!self.store_ready or self.calendar_proposed_slot != null) return;
        // The proposal is real: scan the working day for the first hour the events leave free.
        var hour: u32 = cal_first_hour;
        const free: ?u32 = while (hour < cal_first_hour + cal_hours) : (hour += 1) {
            if (self.calendar_state.availabilityOf(hour) == .free) break hour;
        } else null;
        const slot = free orelse return;
        const arg = focusArg(slot) orelse return;
        var app = self.calendarApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.calendar_agent_row;
        const outcome = app.invoke(agentActor(calendar_agent), .{ .operation = "calendar.add", .args = arg }, "calendar.propose", true, key) catch {
            row.status = .unavailable;
            return;
        };
        if (outcome == .executed) self.calendar_proposed_slot = slot;
    }

    /// The Calendar agent's commit that would notify other people — `calendar.invite` (held, always,
    /// because it reaches outside the person's own day). The frame records the request and returns it
    /// held rather than running it; the footer shows the person an Approve control. Nothing is sent
    /// until they tap it.
    pub fn calendarAgentStageCommit(self: *Interaction) void {
        if (!self.store_ready or self.calendar_agent_row.status == .held) return;
        var app = self.calendarApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.calendar_agent_row;
        row.door = "calendar.commit";
        const outcome = app.invoke(agentActor(calendar_agent), .{ .operation = "calendar.invite", .args = "Review with the team@15" }, "calendar.commit", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "calendar.invite";
                row.args = "Review with the team@15";
                row.key = key;
                row.say("Invite held \u{00B7} notifies others \u{00B7} 15:00");
            },
            .executed => {
                row.status = .executed;
                row.say("Invite committed");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held calendar commit on the person's approval — the same keyed operation the agent
    /// staged, run exactly-once through `App.approve`, so a double-tap or a restart never sends twice.
    pub fn calendarApproveCommit(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.calendar_agent_row;
        if (row.control != .approve) return;
        var app = self.calendarApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            row.say("Approved \u{00B7} invite sent once");
        }
    }

    /// The Notes agent keeps the notebook: it writes a real note through `note.create` (notify — a local
    /// change), the same door the person's create runs. The note actually appears in the notebook.
    pub fn notesAgentCreate(self: *Interaction) void {
        if (!self.store_ready or self.notes_agent_row.status != .none) return;
        var app = self.notesApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.notes_agent_row;
        row.door = "note.create \u{00B7} notes.write";
        const outcome = app.invoke(agentActor(notes_agent), .{ .operation = "note.create", .args = "Follow up|Confirm the studio booking on Friday" }, "notes.write", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                // Derived from the notebook: the count of notes after the agent's write.
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Wrote \u{201C}Follow up\u{201D} \u{00B7} {d} notes", .{self.notes_state.count()}) catch "Wrote a note into the notebook");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The Contacts agent looks up the book through `contact.search` (silent — a read that names
    /// contacts, never their private fields). The count it reports is the real number of matches.
    pub fn contactsAgentLookup(self: *Interaction) void {
        if (!self.store_ready or self.contacts_agent_row.status != .none) return;
        var app = self.contactsApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.contacts_agent_row;
        row.door = "contact.search \u{00B7} contacts.lookup";
        const outcome = app.invoke(agentActor(contacts_agent), .{ .operation = "contact.search", .args = "a" }, "contacts.lookup", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => |result| {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Looked up \u{201C}a\u{201D} \u{00B7} {s} in the book match", .{result}) catch "Looked up the book");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The reply the Messages agent drafts — a real body that goes through the messages domain and is
    /// read back for the held send, the same way the Notes agent's note text is real content.
    const messages_agent_reply = "On my way, be there in ten";

    /// The Messages agent drafts a reply through `message.draft` (notify — a local change to the person's
    /// own draft, not asked). The draft is stored in the real thread store, and the presence line reads
    /// the body back through the domain, so the row is the real drafted content, never a reported one.
    pub fn messagesAgentDraft(self: *Interaction) void {
        if (!self.store_ready or self.messages_agent_row.status != .none) return;
        var app = self.messagesApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.messages_agent_row;
        row.door = "message.draft \u{00B7} messages.draft";
        const outcome = app.invoke(agentActor(messages_agent), .{ .operation = "message.draft", .args = messages_agent_reply }, "messages.draft", true, key) catch {
            row.status = .unavailable;
            row.say("Messages agent unavailable");
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                const drafted = self.msgs_state.draftedBody() orelse messages_agent_reply;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Drafted a reply \u{00B7} \u{201C}{s}\u{201D}", .{drafted}) catch "Drafted a reply");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The Messages agent's send would reach another person — `message.send` (held, always, because it
    /// leaves the device). The frame records the request and returns it held rather than sending; the
    /// footer shows an Approve control with the real recipient (the first person in the book) and the
    /// drafted content read back from the domain. Nothing is sent until the person taps it.
    pub fn messagesAgentStageSend(self: *Interaction) void {
        if (!self.store_ready or self.messages_agent_row.status == .held) return;
        const body = self.msgs_state.draftedBody() orelse return;
        var app = self.messagesApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.messages_agent_row;
        row.door = "message.send \u{00B7} messages.send";
        const outcome = app.invoke(agentActor(messages_agent), .{ .operation = "message.send", .args = body }, "messages.send", true, key) catch {
            row.status = .unavailable;
            row.say("Messages agent unavailable");
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "message.send";
                row.args = body;
                row.key = key;
                var buf: [24][]const u8 = undefined;
                const people = self.contacts_state.people(&buf);
                const to = if (people.len > 0) people[0] else "the recipient";
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Send held \u{00B7} to {s} \u{00B7} \u{201C}{s}\u{201D}", .{ to, body }) catch "Send held \u{00B7} reaches another person");
            },
            .executed => {
                row.status = .executed;
                row.say("Sent");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held send on the person's approval — the same keyed `message.send` the agent staged,
    /// run exactly-once through `App.approve`, so a double-tap or a restart never sends twice.
    pub fn messagesApproveSend(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.messages_agent_row;
        if (row.control != .approve) return;
        var app = self.messagesApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            row.say("Approved \u{00B7} sent once");
        }
    }

    /// The Browser agent reads the current page through `browser.read_page` (silent — the engine's
    /// projection only, never the document). The presence row is derived from the same page the person
    /// sees, so it is the real read, not a self-reported one.
    pub fn browserAgentRead(self: *Interaction) void {
        if (!self.store_ready or self.browser_agent_row.status != .none) return;
        var app = self.browserApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.browser_agent_row;
        row.door = "browser.read_page \u{00B7} projected";
        const outcome = app.invoke(agentActor(browser_agent), .{ .operation = "browser.read_page", .args = "" }, "browser.read", true, key) catch {
            row.status = .unavailable;
            row.say("Browser agent unavailable");
            return;
        };
        switch (outcome) {
            .executed => |projection| {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Read the page \u{00B7} {s}", .{projection}) catch "Read the current page");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Stages the Browser agent's form submit — `browser.fill` (notify — a local stage on the page) then
    /// `browser.submit` (held, always, because it sends the form off the device). The frame records the
    /// submit request and returns it held; the footer shows an Approve. Nothing is sent until it is
    /// tapped. Used by the tests; the seeded surface shows the silent read instead.
    pub fn browserAgentStageSubmit(self: *Interaction) void {
        if (!self.store_ready or self.browser_agent_row.status == .held) return;
        var app = self.browserApp();
        // Fill the form first: a local change that stages a value, applied at once.
        const fill_key = self.next_key;
        self.next_key += 1;
        _ = app.invoke(agentActor(browser_agent), .{ .operation = "browser.fill", .args = "email=me@example.com" }, "browser.form", true, fill_key) catch return;
        // Then stage the submit, which is held for the person.
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.browser_agent_row;
        row.door = "browser.submit \u{00B7} browser.form";
        const outcome = app.invoke(agentActor(browser_agent), .{ .operation = "browser.submit", .args = "" }, "browser.form", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "browser.submit";
                row.args = "";
                row.key = key;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Submit held \u{00B7} sends off device \u{00B7} {d} field", .{self.browser_state.filledCount()}) catch "Submit held \u{00B7} sends off device");
            },
            .executed => {
                row.status = .executed;
                row.say("Form submitted");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held Browser submit on the person's approval — the same keyed submit the agent
    /// staged, run exactly-once through `App.approve`, so a double-tap never sends twice.
    pub fn browserApproveSubmit(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.browser_agent_row;
        if (row.control != .approve) return;
        var app = self.browserApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            row.say("Approved \u{00B7} form sent once");
        }
    }

    /// The Store agent browses the catalogue through `store.browse` (silent). The count it reports is the
    /// real installed count read back from the store domain.
    pub fn storeAgentBrowse(self: *Interaction) void {
        if (!self.store_ready or self.store_agent_row.status != .none) return;
        var app = self.storeApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.store_agent_row;
        row.door = "store.search \u{00B7} store.search";
        const outcome = app.invoke(agentActor(store_agent), .{ .operation = "store.browse", .args = "" }, "store.search", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Browsed \u{00B7} {d} in catalogue \u{00B7} {d} installed", .{ store_catalog.len, self.store_state.installedCount() }) catch "Browsed the catalogue");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Stages the Store agent's install of a reviewed package — `store.install` (held, always, because
    /// installing grants the package its declared authority). The frame returns it held; the footer shows
    /// an Approve whose sheet names the real declared capabilities. Nothing is granted until it is tapped.
    pub fn storeAgentStageInstall(self: *Interaction) void {
        if (!self.store_ready or self.store_agent_row.status == .held) return;
        const item = store_agent_target;
        if (self.isInstalled(item.name)) return;
        var app = self.storeApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.store_agent_row;
        row.door = "store.install \u{00B7} store.install";
        const outcome = app.invoke(agentActor(store_agent), .{ .operation = "store.install", .args = store_agent_install_arg }, "store.install", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "store.install";
                row.args = store_agent_install_arg;
                row.key = key;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "{s} held \u{00B7} grants {s}", .{ item.name, item.caps }) catch "Install held \u{00B7} grants declared capabilities");
            },
            .executed => {
                row.status = .executed;
                row.say("Installed");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held Store install on the person's approval — the same keyed install the agent
    /// staged, run exactly-once through `App.approve`. Guards against an already-installed package (the
    /// person may have installed it themselves in the meantime) so approving never double-grants.
    pub fn storeApproveInstall(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.store_agent_row;
        if (row.control != .approve) return;
        if (self.isInstalled(store_agent_target.name)) {
            row.status = .executed;
            row.control = .none;
            row.say("Already installed");
            return;
        }
        var app = self.storeApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            var line: [96]u8 = undefined;
            row.say(std.fmt.bufPrint(&line, "Approved \u{00B7} {s} installed once", .{store_agent_target.name}) catch "Approved \u{00B7} installed once");
        }
    }

    /// Binds a real platform audio backend into the screening path's seam. The windowed desktop calls
    /// this once at start with the per-OS backend (CoreAudio on macOS); the headless renderer never does,
    /// so it stays honestly unbound. The backend context must outlive the interaction — the caller owns
    /// it — since the seam holds it by reference.
    pub fn bindAudioBackend(self: *Interaction, backend: audio_seam.Backend) void {
        self.audio_route.bind(backend);
    }

    /// Binds a real platform camera backend into the Camera capture path's seam. The windowed desktop
    /// calls this once at start with the per-OS backend (AVFoundation on macOS); the headless renderer
    /// never does, so the camera stays honestly dark. The backend context must outlive the interaction —
    /// the caller owns it — since the seam holds it by reference. Binding lights nothing: it enumerates no
    /// camera and starts no session, so wiring the shell never activates the camera.
    pub fn bindCameraBackend(self: *Interaction, backend: camera_seam.Backend) void {
        self.camera_source.bind(backend);
    }

    /// Opens the viewfinder: starts a real capture session on the first camera the bound backend exposes,
    /// which is what lights the privacy indicator at the source. Called when the Camera surface comes to
    /// the foreground, so the indicator is on for as long as the viewfinder is live — exactly as the
    /// hardware behaves. A no-op with no backend bound, no camera present, or a session already running,
    /// so the headless renderer and CI never light a camera.
    pub fn cameraViewfinderOpen(self: *Interaction) void {
        if (!self.camera_source.available() or self.camera_source.indicatorLit()) return;
        var buf: [max_cameras]camera_seam.Camera = undefined;
        const cams = self.camera_source.cameras(&buf);
        if (cams.len == 0) return;
        self.camera_source.start(cams[0].id) catch {};
    }

    /// Closes the viewfinder: stops the capture session, so the privacy indicator follows the source off.
    /// Called when the Camera surface leaves the foreground. Idempotent — with nothing running it does
    /// nothing, so it is safe to call on every surface change.
    pub fn cameraViewfinderClose(self: *Interaction) void {
        self.camera_source.stop();
    }

    /// Whether the camera's privacy indicator is lit, read from the frame source itself. A frame cannot
    /// be delivered with this off, so the surface's live dot reflects the truth of the hardware, never a
    /// flag the shell sets.
    pub fn cameraIndicatorLit(self: *const Interaction) bool {
        return self.camera_source.indicatorLit();
    }

    /// The shape of the most recent frame a bound, live camera delivered, or null where none is bound or
    /// none has arrived. Only a frame's shape crosses the seam — never a fabricated one — so the surface
    /// can show a real device's resolution where one is delivering, and nothing where none is.
    pub fn cameraLatestFrame(self: *const Interaction) ?camera_seam.Frame {
        return self.camera_source.latestFrame();
    }

    /// The screening agent's audio route over the bound seam: a real capture+playback path where a device
    /// exists, honestly unavailable otherwise. Re-derived each call so it tracks a backend bound after the
    /// interaction was constructed.
    fn screeningRoute(self: *Interaction) screening_audio.ScreeningRoute {
        return screening_audio.ScreeningRoute.init(&self.audio_route);
    }

    /// The Phone agent screens the unknown, unverified caller the surface shows: `call.screen` (notify)
    /// runs the real screening check through the domain, then the result is recorded as a real Screening
    /// the person can judge. The recorded state is untrusted — its content originates with the caller
    /// through the agent. The screening agent answers over the platform audio route: where a real
    /// capture+playback device is bound, the summary records that a real route is present; where none is
    /// (the headless renderer, CI, an unbound host), it records the honest, specific reason audio is
    /// unavailable. No transcript is invented either way — the telephony trunk is a labeled connector.
    pub fn phoneAgentScreen(self: *Interaction) void {
        if (!self.store_ready or self.phone_agent_row.status != .none) return;
        const caller = applications.phone.Caller{ .known = false, .verified = false };
        if (applications.phone.ringsThrough(caller)) return; // a caller that rings through is not screened
        var app = self.phoneApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.phone_agent_row;
        row.door = "call.screen \u{00B7} phone.screen";
        const outcome = app.invoke(agentActor(phone_agent), .{ .operation = "call.screen", .args = "" }, "phone.screen", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                // The audio route the agent would answer over: a real device pair, or an honest reason it
                // is unavailable. Its description is a static string, so the recorded screening holds a
                // stable summary (the domain keeps the slice) — no transcript is invented; what is real
                // (the audio route, or its honest absence) is stated.
                var route = self.screeningRoute();
                const audio_status = route.availability().describe();
                _ = self.phone_state.recordScreening(caller, audio_status) catch {};
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Screened unknown \u{00B7} {s} \u{00B7} {d} held", .{ audio_status, self.phone_state.screeningCount() }) catch "Screened an unknown caller \u{00B7} untrusted");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Stages the Phone agent's outbound call — `call.dial` (held, always, because a call reaches another
    /// person). The frame returns it held; on approval it appends to the real call log exactly-once.
    /// Used by the tests; the seeded Phone surface shows the screening instead.
    pub fn phoneAgentStageCall(self: *Interaction) void {
        if (!self.store_ready or self.phone_agent_row.status == .held) return;
        var app = self.phoneApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.phone_agent_row;
        row.door = "call.dial \u{00B7} phone.call";
        const outcome = app.invoke(agentActor(phone_agent), .{ .operation = "call.dial", .args = "5550137" }, "phone.call", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "call.dial";
                row.args = "5550137";
                row.key = key;
                row.say("Call held \u{00B7} reaches another person \u{00B7} 5550137");
            },
            .executed => {
                row.status = .executed;
                row.say("Call placed");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held Phone call on the person's approval — the same keyed dial the agent staged, run
    /// exactly-once through `App.approve`, so a double-tap never dials twice.
    pub fn phoneApproveCall(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.phone_agent_row;
        if (row.control != .approve) return;
        var app = self.phoneApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            row.say("Approved \u{00B7} call placed once");
        }
    }

    /// The Settings agent reads an open setting through `settings.read` (silent). The value it reports is
    /// the real current value the person's toggles change.
    pub fn settingsAgentRead(self: *Interaction) void {
        if (!self.store_ready or self.settings_agent_row.status != .none) return;
        var app = self.settingsApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.settings_agent_row;
        row.door = "settings.read \u{00B7} the class gates every write";
        const outcome = app.invoke(agentActor(settings_agent), .{ .operation = "settings.read", .args = "wifi_enabled" }, "settings.read", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                const on = self.settingValue(.wifi_enabled) != 0;
                row.say(if (on) "Read Wi-Fi \u{00B7} on \u{00B7} sensitive keys are yours alone" else "Read Wi-Fi \u{00B7} off \u{00B7} sensitive keys are yours alone");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The Maps agent reads an on-device distance through `maps.distance` (silent) — the same distance
    /// the surface shows, computed by the maps domain, never leaving the device.
    pub fn mapsAgentDistance(self: *Interaction) void {
        if (!self.store_ready or self.maps_agent_row.status != .none) return;
        var app = self.mapsApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.maps_agent_row;
        row.door = "maps.distance \u{00B7} on device";
        const outcome = app.invoke(agentActor(maps_agent), .{ .operation = "maps.distance", .args = "Home@Studio" }, "maps.read", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => |distance| {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Home to Studio \u{00B7} {s} units \u{00B7} on device", .{distance}) catch "Read an on-device distance");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The Health agent reads an on-device summary through `health.summary` (silent) — a metric average
    /// computed by the health domain, kept strictly on device.
    pub fn healthAgentSummary(self: *Interaction) void {
        if (!self.store_ready or self.health_agent_row.status != .none) return;
        var app = self.healthApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.health_agent_row;
        row.door = "health.summary \u{00B7} on device";
        const outcome = app.invoke(agentActor(health_agent), .{ .operation = "health.summary", .args = "steps" }, "health.read", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => |avg| {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Steps average \u{00B7} {s} \u{00B7} never leaves device", .{avg}) catch "Read an on-device summary");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    // --- Tasks: an agent completes a task, the person completes one, over the same list ---

    /// The Tasks agent ticks off a real task through `task.complete` (notify — a local change to the
    /// person's own list, applied and shown, never held). It runs the exact door the person's tap runs.
    pub fn tasksAgentComplete(self: *Interaction) void {
        if (!self.store_ready or self.tasks_agent_row.status != .none) return;
        var app = self.tasksApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.tasks_agent_row;
        row.door = "task.complete \u{00B7} tasks.write";
        const outcome = app.invoke(agentActor(tasks_agent), .{ .operation = "task.complete", .args = "Pay the electricity bill" }, "tasks.write", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Completed a task \u{00B7} {d} still open", .{self.tasksRemaining()}) catch "Completed a task");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes a task on the person's tap, through the same `task.complete` door the agent uses.
    pub fn tasksComplete(self: *Interaction, title: []const u8) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.tasks.Store.execute(&self.tasks_state, .{ .operation = "task.complete", .args = title }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Whether a task is done — the real state the list renders, reflecting an agent's or a tap's tick.
    pub fn taskDone(self: *const Interaction, title: []const u8) bool {
        var st = self.tasks_state;
        return st.isDone(title) orelse false;
    }

    // --- Music: a silent read over a fully-local library that opens honestly empty ---

    /// The Music agent reads what is playing through `music.now_playing` (silent). Over an empty library
    /// this honestly reports nothing playing — no fabricated track, only the real state.
    pub fn musicAgentRead(self: *Interaction) void {
        if (!self.store_ready or self.music_agent_row.status != .none) return;
        var app = self.musicApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.music_agent_row;
        row.door = "music.now_playing \u{00B7} on device";
        const outcome = app.invoke(agentActor(music_agent), .{ .operation = "music.now_playing", .args = "" }, "music.read", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                var line: [96]u8 = undefined;
                const playing = self.musicNowPlaying() orelse "Nothing playing";
                row.say(std.fmt.bufPrint(&line, "{s} \u{00B7} {d} tracks on device", .{ playing, self.musicCount() }) catch "Read the library");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// The title playing now, or null — the real now-playing state.
    pub fn musicNowPlaying(self: *const Interaction) ?[]const u8 {
        var st = self.music_state;
        return st.nowPlayingTitle();
    }
    /// How many tracks the library holds — zero until the person adds their own.
    pub fn musicCount(self: *const Interaction) usize {
        return self.music_state.count();
    }

    // --- Wallet: an agent stages a payment held for the person, applied exactly once on approval ---

    /// Stages the Wallet agent's payment — `wallet.pay` (held, always, because it transfers value). The
    /// frame returns it held; the footer offers an Approve that pays exactly once. Nothing is debited yet.
    pub fn walletAgentStagePay(self: *Interaction) void {
        if (!self.store_ready or self.wallet_agent_row.status == .held) return;
        var app = self.walletApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.wallet_agent_row;
        row.door = "wallet.pay \u{00B7} wallet.pay";
        const outcome = app.invoke(agentActor(wallet_agent), .{ .operation = "wallet.pay", .args = wallet_pay_arg }, "wallet.pay", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "wallet.pay";
                row.args = wallet_pay_arg;
                row.key = key;
                var line: [96]u8 = undefined;
                var money: [16]u8 = undefined;
                const at = std.mem.indexOfScalar(u8, wallet_pay_arg, '@') orelse 0;
                const cents = std.fmt.parseInt(i64, wallet_pay_arg[0..at], 10) catch 0;
                row.say(std.fmt.bufPrint(&line, "Held \u{00B7} pay {s} once", .{centsLabel(cents, &money)}) catch "Payment held for you");
            },
            .executed => {
                row.status = .executed;
                row.say("Paid");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held payment on the person's approval — the same keyed `wallet.pay`, run once through
    /// `App.approve`, so a double tap or a restart never debits twice.
    pub fn walletApprovePay(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.wallet_agent_row;
        if (row.control != .approve) return;
        var app = self.walletApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            var line: [96]u8 = undefined;
            var money: [16]u8 = undefined;
            row.say(std.fmt.bufPrint(&line, "Approved \u{00B7} paid once \u{00B7} balance {s}", .{centsLabel(self.walletBalanceCents(), &money)}) catch "Approved \u{00B7} paid once");
        }
    }

    /// The wallet's stored-value balance in cents — the real number a payment debits.
    pub fn walletBalanceCents(self: *const Interaction) i64 {
        return self.wallet_state.balance();
    }

    // --- Photos: an agent favourites a real photo (notify), the person taps to favourite too ---

    /// The Photos agent favourites a real photo through `photo.favorite` (notify). With no photos on the
    /// device it honestly reports an empty library rather than acting on nothing.
    pub fn photosAgentFavorite(self: *Interaction) void {
        if (!self.store_ready or self.photos_agent_row.status != .none) return;
        const row = &self.photos_agent_row;
        var paths: [8][]const u8 = undefined;
        const images = imagePaths(&paths);
        if (images.len == 0) {
            row.status = .executed;
            row.door = "photo.view \u{00B7} on device";
            row.say("No photos on device yet");
            return;
        }
        var app = self.photosApp();
        const key = self.next_key;
        self.next_key += 1;
        row.door = "photo.favorite \u{00B7} photos.write";
        const outcome = app.invoke(agentActor(photos_agent), .{ .operation = "photo.favorite", .args = images[0] }, "photos.write", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Favourited a photo \u{00B7} {d} in the library", .{self.photosCount()}) catch "Favourited a photo");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Favourites a photo on the person's tap, through the same `photo.favorite` door the agent uses.
    pub fn photosFavorite(self: *Interaction, id: []const u8) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.photos.Store.execute(&self.photos_state, .{ .operation = "photo.favorite", .args = id }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Whether a photo is favourited — the real state the gallery marks.
    pub fn photoFavorited(self: *const Interaction, id: []const u8) bool {
        var st = self.photos_state;
        return st.isFavorite(id);
    }
    /// How many photos the library holds.
    pub fn photosCount(self: *const Interaction) usize {
        return self.photos_state.count();
    }

    // --- Clock: a silent, on-device read of a world clock's real local time ---

    /// The Clock agent reads a world clock's local time through `clock.time` (silent), computed from the
    /// real zone arithmetic against the device's current instant.
    pub fn clockAgentRead(self: *Interaction) void {
        if (!self.store_ready or self.clock_agent_row.status != .none) return;
        var app = self.clockApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.clock_agent_row;
        const label = world_clocks[world_clocks.len - 1].label;
        row.door = "clock.time \u{00B7} on device";
        var arg_buf: [40]u8 = undefined;
        const arg = std.fmt.bufPrint(&arg_buf, "{s}@{d}", .{ label, self.clock_now.seconds() }) catch {
            row.status = .unavailable;
            return;
        };
        const outcome = app.invoke(agentActor(clock_agent), .{ .operation = "clock.time", .args = arg }, "clock.read", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => |local| {
                row.status = .executed;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "{s} now {s} \u{00B7} computed on device", .{ label, local }) catch "Read a world clock");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Reads the device's real wall clock through io and sets it as the instant the Clock surface shows.
    /// The running shell calls this once at start; without it the surface reads the deterministic default.
    pub fn captureDeviceTime(self: *Interaction, io: std.Io) void {
        const ns = std.Io.Clock.now(.real, io).nanoseconds;
        self.clock_now = core.time.Timestamp.fromSeconds(@intCast(@divFloor(ns, 1_000_000_000)));
    }

    /// A world clock's local time, "HH:MM", read against the device's current instant, into `buf`.
    pub fn clockLocal(self: *const Interaction, label: []const u8, buf: []u8) []const u8 {
        const dt = self.clock_state.localTimeAt(label, self.clock_now) orelse return "--:--";
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute }) catch "--:--";
    }

    // --- Home: an agent switches a light (notify) and stages a lock's unlock, held for the person ---

    /// The Home agent switches a light on through `home.set` (notify — a local change the person sees on
    /// the device grid). The identical door the person's toggle runs.
    pub fn homeAgentAdjust(self: *Interaction) void {
        if (!self.store_ready or self.home_agent_row.status == .held) return;
        var app = self.homeApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.home_agent_row;
        row.door = "home.set \u{00B7} home.control";
        const outcome = app.invoke(agentActor(home_agent), .{ .operation = "home.set", .args = home_light_on_arg }, "home.control", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .executed => {
                row.status = .executed;
                row.say("Switched a light on \u{00B7} the home stays local");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Stages the Home agent's unlock — `home.unlock` (held, always, because it lowers a physical
    /// barrier). The frame returns it held; the footer's Approve opens the lock exactly once on tap.
    pub fn homeAgentStageUnlock(self: *Interaction) void {
        if (!self.store_ready or self.home_agent_row.status == .held) return;
        var app = self.homeApp();
        const key = self.next_key;
        self.next_key += 1;
        const row = &self.home_agent_row;
        row.door = "home.unlock \u{00B7} home.unlock";
        const outcome = app.invoke(agentActor(home_agent), .{ .operation = "home.unlock", .args = home_lock_name }, "home.unlock", true, key) catch {
            row.status = .unavailable;
            return;
        };
        switch (outcome) {
            .held => {
                row.status = .held;
                row.control = .approve;
                row.op = "home.unlock";
                row.args = home_lock_name;
                row.key = key;
                var line: [96]u8 = undefined;
                row.say(std.fmt.bufPrint(&line, "Unlock held \u{00B7} {s}", .{home_lock_name}) catch "Unlock held for you");
            },
            .executed => {
                row.status = .executed;
                row.say("Unlocked");
            },
            else => {
                row.status = .denied;
                row.say("Denied \u{00B7} capability did not match the door");
            },
        }
    }

    /// Completes the held unlock on the person's approval — the same keyed `home.unlock`, run once.
    pub fn homeApproveUnlock(self: *Interaction) void {
        if (!self.store_ready) return;
        const row = &self.home_agent_row;
        if (row.control != .approve) return;
        var app = self.homeApp();
        const outcome = app.approve(.{ .kind = .human, .principal = .{ .value = 0 } }, .{ .operation = row.op, .args = row.args }, row.key) catch return;
        if (outcome == .executed) {
            row.status = .executed;
            row.control = .none;
            var line: [96]u8 = undefined;
            row.say(std.fmt.bufPrint(&line, "Approved \u{00B7} {s} opened once", .{home_lock_name}) catch "Approved \u{00B7} opened once");
        }
    }

    /// Switches a device on or off on the person's tap, through the same `home.set` door the agent uses.
    pub fn homeSet(self: *Interaction, name: []const u8, on: bool) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        var buf: [48]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{s}@{s}", .{ name, if (on) "on" else "off" }) catch return;
        _ = applications.home.Store.execute(&self.home_state, .{ .operation = "home.set", .args = arg }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Whether a device is on (a light lit, a plug powered, a lock engaged), or null if unknown.
    pub fn homeOn(self: *const Interaction, name: []const u8) ?bool {
        var st = self.home_state;
        return st.isOn(name);
    }

    /// Fires the shutter: records a shot through the camera domain, but only while the indicator is lit
    /// and the app is foreground — the domain's own capture rule. Returns whether a shot was taken.
    ///
    /// The indicator gates the capture. Where a real camera is bound (the windowed desktop with a
    /// device), it is the live viewfinder session's own state, read at the source and structurally
    /// unbypassable — the seam cannot hand back a frame with the light off, so a shot is taken only while
    /// the camera is genuinely delivering, and the shutter takes that device's real frame. Where none is
    /// bound (the headless renderer, CI, a host without a camera), the foreground Camera app the person
    /// tapped is itself the lit-and-foreground condition, so the person's own shutter still records a
    /// shot — never a fabricated device frame.
    pub fn cameraCapture(self: *Interaction) bool {
        if (!self.store_ready) return false;
        const indicator_lit = if (self.camera_source.available()) self.camera_source.indicatorLit() else true;
        if (!applications.camera.mayCapture(indicator_lit, true)) return false;
        // Where a device is delivering, take its real frame — obtainable only while the indicator is lit,
        // by construction of the seam. No device, no frame: the person's shot still stands, honestly.
        if (self.camera_source.latestFrame()) |frame| self.camera_frame = frame;
        const key = self.next_key;
        self.next_key += 1;
        const before = self.camera_state.shots;
        _ = self.camera_state.capture(key);
        return self.camera_state.shots > before;
    }
    /// How many shots the person has captured this session — read from the domain.
    pub fn cameraShots(self: *const Interaction) usize {
        if (!self.store_ready) return 0;
        return self.camera_state.shots;
    }

    /// The note titles, for the Notes surface to list. A silent read of the real notebook.
    pub fn notesList(self: *const Interaction, out: [][]const u8) []const []const u8 {
        return self.notes_state.search("", out);
    }

    /// The on-device distance between two saved places, computed by the maps domain.
    pub fn mapsDistance(self: *const Interaction, from: []const u8, to: []const u8) ?u32 {
        return self.maps_state.distanceBetween(from, to);
    }

    /// A health metric.s real on-device average, or null when nothing is logged.
    pub fn healthAverage(self: *const Interaction, metric: applications.health_domain.Metric) ?u32 {
        return self.health_state.average(metric);
    }

    /// How many tasks are still open, and how many total — the real counts the Tasks surface shows.
    pub fn tasksRemaining(self: *const Interaction) usize {
        return self.tasks_state.remaining();
    }
    pub fn tasksTotal(self: *const Interaction) usize {
        return self.tasks_state.count();
    }

    /// The page the browser is currently on, read from the real browser store.
    pub fn browserCurrent(self: *const Interaction) ?applications.browser.Page {
        if (!self.store_ready) return null;
        return self.browser_state.current;
    }

    /// Opens a URL through the real browser domain — the same `browser.open` an agent reaches.
    pub fn browserOpen(self: *Interaction, url: []const u8) void {
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.browser.Store.execute(&self.browser_state, .{ .operation = "browser.open", .args = url }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    pub fn browserBookmarked(self: *const Interaction, url: []const u8) bool {
        if (!self.store_ready) return false;
        return self.browser_state.isBookmarked(url);
    }

    /// Bookmarks the current page through the real domain (add-only, as the domain models it).
    pub fn browserBookmark(self: *Interaction, url: []const u8) void {
        if (!self.store_ready or self.browserBookmarked(url)) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.browser.Store.execute(&self.browser_state, .{ .operation = "browser.bookmark", .args = url }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    pub fn siteHas(self: *const Interaction, url: []const u8, permission: applications.browser.Permission) bool {
        if (!self.store_ready) return false;
        return self.browser_state.hasPermission(url, permission);
    }

    /// Grants the current site a sensitive permission through the real domain. This is the person's own
    /// grant, immediate; the same act proposed by an agent is held for the person by the frame.
    pub fn grantSite(self: *Interaction, url_perm: []const u8) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.browser.Store.execute(&self.browser_state, .{ .operation = "browser.grant_site", .args = url_perm }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Whether an hour is committed time, computed from the real events by the calendar domain.
    pub fn slotBusy(self: *const Interaction, slot: u32) bool {
        if (!self.store_ready) return false;
        return self.calendar_state.availabilityOf(slot) == .busy;
    }

    /// The number of focus blocks the day holds — the maximal runs of consecutive busy hours, derived
    /// from the events, never stored.
    pub fn focusBlockCount(self: *const Interaction) usize {
        if (!self.store_ready) return 0;
        var buffer: [24]applications.calendar.FocusBlock = undefined;
        return self.calendar_state.focusBlocks(&buffer).len;
    }

    /// Books focus time on a free hour through the real calendar domain — the same `calendar.add` an
    /// agent would reach. A busy hour is left as it is. The add arg is a static string, since the
    /// domain keeps the title by reference; a stack buffer would dangle in the stored event.
    pub fn bookFocus(self: *Interaction, slot: u32) void {
        if (!self.store_ready or self.slotBusy(slot)) return;
        const args = focusArg(slot) orelse return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.calendar.Store.execute(&self.calendar_state, .{ .operation = "calendar.add", .args = args }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Opens the i-th file entry through the real files domain. A path within the grant opens; one that
    /// escapes the grant is refused before the tree is touched — the same `file.open` an agent reaches.
    pub fn fileOpen(self: *Interaction, i: usize) void {
        if (!self.store_ready or i >= file_entries.len) return;
        const key = self.next_key;
        self.next_key += 1;
        const result = applications.files.Store.execute(&self.files_state, .{ .operation = "file.open", .args = file_entries[i].path }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        self.file_opened = i;
        self.file_open_ok = switch (result) {
            .ok => true,
            .failed => false,
        };
    }

    /// Whether the i-th entry was the last opened, and if so whether the grant allowed it.
    pub fn fileOpenedState(self: *const Interaction, i: usize) ?bool {
        if (self.file_opened) |opened| {
            if (opened == i) return self.file_open_ok;
        }
        return null;
    }

    /// Seeds the address book through the real contacts store: two people via `contact.add`, and the
    /// non-human principals via `addPrincipal`, so the "also in your world" section is the store read.
    fn contactsSeed(self: *Interaction) void {
        for ([_][]const u8{ "Ana Silva", "Marco Dias" }, 1..) |name, key| {
            _ = applications.contacts.Store.execute(&self.contacts_state, .{ .operation = "contact.add", .args = name }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        }
        for (world_principals) |p| self.contacts_state.addPrincipal(p.name, p.kind) catch {};
    }

    /// The people in the book, read from the real store.
    pub fn contactPeople(self: *const Interaction, out: [][]const u8) []const []const u8 {
        if (!self.store_ready) return out[0..0];
        return self.contacts_state.people(out);
    }

    /// The non-human principals in the book, read from the real store.
    pub fn contactWorld(self: *const Interaction, out: [][]const u8) []const []const u8 {
        if (!self.store_ready) return out[0..0];
        return self.contacts_state.alsoInYourWorld(out);
    }

    /// Whether an agent may currently read a contact field, decided by the person's field-scoped grant
    /// through the domain's own `fieldVisible`.
    pub fn agentMayRead(self: *const Interaction, field: applications.contacts.Field) bool {
        return applications.contacts.fieldVisible(self.agent_grant, field);
    }

    /// Grants or revokes an agent's read of a contact field. A contact's name always stays visible —
    /// an agent that cannot see who a contact is could not act on it at all.
    pub fn toggleGrant(self: *Interaction, field: applications.contacts.Field) void {
        if (field == .name) return;
        if (self.agent_grant.contains(field)) self.agent_grant.remove(field) else self.agent_grant.insert(field);
    }

    /// Whether the device's current location has been resolved and a reading fetched.
    pub fn weatherLocated(self: *const Interaction) bool {
        return self.weather_city_len > 0;
    }
    /// The device's current city, or empty before a lookup succeeds.
    pub fn weatherCity(self: *const Interaction) []const u8 {
        return self.weather_city[0..self.weather_city_len];
    }
    /// The live current reading for the device's location, or null if none has been fetched (offline).
    pub fn weatherReading(self: *const Interaction) ?applications.weather.Reading {
        if (!self.store_ready or self.weather_city_len == 0) return null;
        const c = self.weather_state.cached(self.weatherCity()) orelse return null;
        return c.reading;
    }
    pub fn weatherHasAlert(self: *const Interaction) bool {
        if (!self.store_ready or self.weather_city_len == 0) return false;
        return self.weather_state.hasAlert(self.weatherCity());
    }
    /// Arms severe-weather alerts for the current location through the domain (enable-only).
    pub fn weatherArmAlert(self: *Interaction) void {
        if (!self.store_ready or self.weather_city_len == 0) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.weather.Store.execute(&self.weather_state, .{ .operation = "weather.enable_alert", .args = self.weatherCity() }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }
    /// The live hourly forecast for the current location, written into `out`; empty when none fetched.
    pub fn weatherHourly(self: *const Interaction, out: []applications.weather.Reading) []const applications.weather.Reading {
        if (!self.store_ready or self.weather_city_len == 0) return out[0..0];
        return self.weather_state.hourlyOf(self.weatherCity(), out);
    }

    /// Resolves the device's current location over the network and fetches its live current reading and
    /// hourly forecast, recording them in the weather domain. Called once by the running shell with a
    /// real transport; on any failure it leaves the app unlocated, which the surface shows honestly.
    /// Never reached by the offline tests, so they need no network.
    pub fn weatherRefresh(self: *Interaction, gpa: std.mem.Allocator, io: std.Io) void {
        if (!self.store_ready) return;
        var http = HttpTransport{ .gpa = gpa, .io = io };
        const transport = http.transport();
        const meteo = applications.weather.open_meteo;
        // Where the device actually is.
        const located = applications.weather.geolocation.fetch(gpa, transport, self.weather_city[0..]) catch return;
        self.weather_city_len = located.city.len;
        // Save the current place through the domain, then inject its live current reading and hourly.
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.weather.Store.execute(&self.weather_state, .{ .operation = "weather.add_location", .args = self.weatherCity() }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        if (meteo.fetchCurrent(gpa, transport, located.coord)) |reading| {
            self.weather_state.injectCurrent(self.weatherCity(), reading);
        } else |_| {}
        self.weatherFetchInto(gpa, transport, located.coord);
    }

    /// Fetches and records the live weather at a precise coordinate the device reported (CoreLocation on
    /// macOS), under the given city name — the accurate path, preferred over the coarse IP lookup.
    pub fn weatherRefreshAt(self: *Interaction, gpa: std.mem.Allocator, io: std.Io, latitude: f64, longitude: f64, city: []const u8) void {
        if (!self.store_ready) return;
        const n = @min(city.len, self.weather_city.len);
        @memcpy(self.weather_city[0..n], city[0..n]);
        self.weather_city_len = n;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.weather.Store.execute(&self.weather_state, .{ .operation = "weather.add_location", .args = self.weatherCity() }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
        var http = HttpTransport{ .gpa = gpa, .io = io };
        self.weatherFetchInto(gpa, http.transport(), .{ .latitude = latitude, .longitude = longitude });
    }

    /// Fetches the current reading and hourly forecast at a coordinate and records both under the
    /// current city. Shared by the precise and the IP-lookup refresh paths.
    fn weatherFetchInto(self: *Interaction, gpa: std.mem.Allocator, transport: applications.weather.open_meteo.Transport, coord: applications.weather.open_meteo.Coord) void {
        const meteo = applications.weather.open_meteo;
        if (meteo.fetchCurrent(gpa, transport, coord)) |reading| {
            self.weather_state.injectCurrent(self.weatherCity(), reading);
        } else |_| {}
        var hours: [applications.weather.hourly_span]applications.weather.Reading = undefined;
        if (meteo.fetchHourly(gpa, transport, coord, &hours)) |series| {
            self.weather_state.injectHourly(self.weatherCity(), series);
        } else |_| {}
        // With a live reading in the domain, run the Weather agent's refresh so the surface shows a real
        // agent presence derived from that reading — the agent reading the same forecast the person sees.
        self.weatherAgentRefresh();
    }

    /// The current value of a setting from the real settings store.
    pub fn settingValue(self: *const Interaction, setting: applications.settings.Setting) u16 {
        if (!self.store_ready) return 0;
        return self.settings_state.get(setting);
    }

    /// Toggles a setting through the real settings domain — refused by the domain for a sensitive one,
    /// exactly as an agent's write would be gated by its class.
    pub fn settingToggle(self: *Interaction, setting: applications.settings.Setting) void {
        if (!self.store_ready) return;
        const key = self.next_key;
        self.next_key += 1;
        _ = applications.settings.Store.execute(&self.settings_state, .{ .operation = "settings.toggle", .args = @tagName(setting) }, .{ .kind = .human, .principal = .{ .value = 0 } }, key);
    }

    /// Opens the conversation at `i` (the thread view); clears any half-typed message.
    pub fn msgOpen(self: *Interaction, i: usize) void {
        if (i < self.conv_count) {
            self.open_conv = i;
            self.compose_len = 0;
        }
    }
    /// Closes the open thread back to the conversation list.
    pub fn msgCloseThread(self: *Interaction) void {
        self.open_conv = null;
    }
    /// Enters the new-conversation screen with an empty recipient field.
    pub fn msgBeginConversation(self: *Interaction) void {
        self.composing_new = true;
        self.compose_len = 0;
    }
    /// Leaves the new-conversation screen without starting anything.
    pub fn msgCancelConversation(self: *Interaction) void {
        self.composing_new = false;
        self.compose_len = 0;
    }
    /// Starts the conversation from the typed field and opens its empty thread. The text is recognised:
    /// a phone number (digits and the separators a number carries) starts a conversation with that
    /// number; otherwise it is a name, resolved against the real contacts book so a typed name that
    /// matches a real person starts the conversation with that person, and an unknown name starts one
    /// with the text as typed. A blank field does nothing.
    pub fn msgConfirmConversation(self: *Interaction) void {
        if (!self.composing_new or self.compose_len == 0) return;
        const typed = self.compose_buf[0..self.compose_len];
        if (looksLikePhone(typed)) {
            self.composing_new = false;
            self.msgStart(typed);
            return;
        }
        // A name: resolve it to a real contact when the book holds a match, else start with what was typed.
        var buf: [1][]const u8 = undefined;
        const matches = self.msgContactCandidates(&buf);
        self.composing_new = false;
        self.msgStart(if (matches.len > 0) matches[0] else typed);
    }

    /// The real contacts whose name matches what has been typed into the recipient field — the people the
    /// new-conversation screen offers to start a conversation with, read from the same book the Contacts
    /// app shows. An empty field offers everyone; a phone number matches no name and offers no one.
    pub fn msgContactCandidates(self: *const Interaction, out: [][]const u8) []const []const u8 {
        if (!self.store_ready or out.len == 0) return out[0..0];
        const query = self.compose_buf[0..self.compose_len];
        var people_buf: [max_conv][]const u8 = undefined;
        const humans = self.contacts_state.people(&people_buf);
        var n: usize = 0;
        for (humans) |name| {
            if (n >= out.len) break;
            if (query.len == 0 or std.ascii.indexOfIgnoreCase(name, query) != null) {
                out[n] = name;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// Starts a conversation with the real contact `name` picked from the candidate list, leaving the
    /// new-conversation screen. The identical entry point the typed door reaches, so a looked-up contact
    /// and a typed one open the same kind of thread.
    pub fn msgStartContact(self: *Interaction, name: []const u8) void {
        if (!self.composing_new) return;
        self.composing_new = false;
        self.msgStart(name);
    }
    /// Starts a conversation with `name` and opens it — an empty thread, nothing pre-filled.
    pub fn msgStart(self: *Interaction, name: []const u8) void {
        if (self.conv_count >= max_conv) return;
        const i = self.conv_count;
        const n = @min(name.len, self.conv_names[i].len);
        @memcpy(self.conv_names[i][0..n], name[0..n]);
        self.conv_name_lens[i] = n;
        self.conv_msg_count[i] = 0;
        self.conv_count += 1;
        self.open_conv = i;
        self.compose_len = 0;
    }
    pub fn msgComposeType(self: *Interaction, ch: u8) void {
        if (self.compose_len < self.compose_buf.len) {
            self.compose_buf[self.compose_len] = ch;
            self.compose_len += 1;
        }
    }
    pub fn msgComposeBackspace(self: *Interaction) void {
        if (self.compose_len > 0) self.compose_len -= 1;
    }
    /// Sends the typed message into the open thread and through the messages domain, then clears the
    /// compose line. Empty input sends nothing.
    pub fn msgSend(self: *Interaction) void {
        const conv = self.open_conv orelse return;
        if (self.compose_len == 0) return;
        const m = self.conv_msg_count[conv];
        if (m >= max_conv_msg) return;
        const n = @min(self.compose_len, max_msg_bytes);
        @memcpy(self.conv_bodies[conv][m][0..n], self.compose_buf[0..n]);
        self.conv_body_lens[conv][m] = n;
        self.conv_mine[conv][m] = true;
        self.conv_msg_count[conv] = m + 1;
        _ = applications.messages.Store.execute(&self.msgs_state, .{ .operation = "message.send", .args = self.compose_buf[0..n] }, .{ .kind = .human, .principal = .{ .value = 0 } }, self.next_key);
        self.next_key += 1;
        self.compose_len = 0;
    }
    pub fn msgConvName(self: *const Interaction, i: usize) []const u8 {
        return self.conv_names[i][0..self.conv_name_lens[i]];
    }
    pub fn msgConvMessages(self: *const Interaction, i: usize) usize {
        return self.conv_msg_count[i];
    }
    pub fn msgBody(self: *const Interaction, ci: usize, mi: usize) []const u8 {
        return self.conv_bodies[ci][mi][0..self.conv_body_lens[ci][mi]];
    }
    pub fn msgMine(self: *const Interaction, ci: usize, mi: usize) bool {
        return self.conv_mine[ci][mi];
    }
    pub fn msgComposeText(self: *const Interaction) []const u8 {
        return self.compose_buf[0..self.compose_len];
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

/// Runs each in-app agent's real work once so every agentic app opens showing its genuine last agent
/// action, derived from the domain. The windowed shell and the headless renderer call this after
/// `attach`; the offline unit tests do not, so a test drives whichever agent path it is exercising and
/// asserts on it in isolation. Weather is refreshed on its own live-fetch path, so it is not here.
pub fn seedAgentPresence(inter: *Interaction) void {
    inter.filesAgentOrganize();
    inter.calendarAgentPropose();
    inter.calendarAgentStageCommit();
    inter.notesAgentCreate();
    inter.contactsAgentLookup();
    // The messages agent drafts a real reply (notify) then stages the send it cannot complete on its own,
    // held for the person with the real recipient and content.
    inter.messagesAgentDraft();
    inter.messagesAgentStageSend();
    // The web-research agent reads the current page (silent); the store agent browses then stages a held
    // install the person approves; the screening agent records a real untrusted screening; Settings,
    // Maps, and Health show a silent agent read over their real local domains.
    inter.browserAgentRead();
    inter.storeAgentBrowse();
    inter.storeAgentStageInstall();
    inter.phoneAgentScreen();
    inter.settingsAgentRead();
    inter.mapsAgentDistance();
    inter.healthAgentSummary();
    // The six newly-surfaced apps: the tasks agent ticks a task (notify); music reads its empty library
    // (silent); the wallet agent stages a payment held for the person; the photos agent favourites a real
    // photo (notify); the clock agent reads a world time (silent); the home agent switches a light on
    // (notify) then stages the lock's unlock, held for the person.
    inter.tasksAgentComplete();
    inter.musicAgentRead();
    inter.walletAgentStagePay();
    inter.photosAgentFavorite();
    inter.clockAgentRead();
    inter.homeAgentAdjust();
    inter.homeAgentStageUnlock();
}

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
/// The Notes surface: the real notebook, each note a raised card. Driven by the notes domain.
pub fn renderNotes(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Notes", "Your notebook, on device");
    var buf: [12][]const u8 = undefined;
    const titles = inter.notesList(&buf);
    var y: i32 = @intFromFloat(u(118));
    for (titles) |title| {
        const rect = card(screen, y, @intFromFloat(u(52)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(31), title, u(14.5), s(theme.screen_text), .semibold);
        y += @intFromFloat(u(52) + u(10));
    }
    agentBand(screen, &inter.notes_agent_row);
}

/// The Health surface: the person's on-device metrics, each a raised stat card, from real averages.
pub fn renderHealth(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Health", "On device, private to you");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "health.summary \u{00B7} granted");
    const metrics = [_]struct { label: []const u8, unit: []const u8, m: applications.health_domain.Metric }{
        .{ .label = "Steps", .unit = "", .m = .steps },
        .{ .label = "Heart rate", .unit = "bpm", .m = .heart_rate },
        .{ .label = "Weight", .unit = "kg", .m = .weight },
    };
    var y: i32 = @intFromFloat(u(118));
    for (metrics) |mt| {
        const rect = card(screen, y, @intFromFloat(u(66)));
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(24), mt.label, u(12), s(theme.screen_text_muted));
        var vbuf: [24]u8 = undefined;
        const vtext = if (inter.healthAverage(mt.m)) |avg|
            (std.fmt.bufPrint(&vbuf, "{d} {s}", .{ avg, mt.unit }) catch "-")
        else
            "no data yet";
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(50), vtext, u(20), s(theme.agent), .semibold);
        y += @intFromFloat(u(66) + u(10));
    }
    agentBand(screen, &inter.health_agent_row);
}

/// The Maps surface: saved places and the real on-device distance between them.
pub fn renderMaps(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Maps", "Saved places, distances on device");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "maps.distance \u{00B7} on device");
    const places = [_][]const u8{ "Home", "Studio", "Market" };
    var y: i32 = @intFromFloat(u(118));
    for (places) |place| {
        const rect = card(screen, y, @intFromFloat(u(48)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(29), place, u(14.5), s(theme.screen_text), .semibold);
        y += @intFromFloat(u(48) + u(9));
    }
    // A real distance between two of them.
    const drect = card(screen, y + @as(i32, @intFromFloat(u(6))), @intFromFloat(u(60)));
    _ = text.draw(screen, @as(f32, @floatFromInt(drect.x)) + u(18), @as(f32, @floatFromInt(drect.y)) + u(24), "Home to Studio", u(12), s(theme.screen_text_muted));
    var dbuf: [24]u8 = undefined;
    const dtext = if (inter.mapsDistance("Home", "Studio")) |d| (std.fmt.bufPrint(&dbuf, "{d} units", .{d}) catch "-") else "-";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(drect.x)) + u(18), @as(f32, @floatFromInt(drect.y)) + u(48), dtext, u(18), s(theme.agent), .semibold);
    agentBand(screen, &inter.maps_agent_row);
}

// --- Tasks: the real to-do list, completed by a tap or by the agent through one door ---

fn taskRowRect(i: usize) graphics.paint.Rect {
    const h = u(52);
    const top = u(118) + @as(f32, @floatFromInt(i)) * (h + u(9));
    return cardRect(@intFromFloat(top), @intFromFloat(h));
}

/// The Tasks surface: the person's real list, each task a card marked done or open, with the live
/// remaining/total count. A tap completes a task through the same door the agent's tick runs.
pub fn renderTasks(screen: *Framebuffer, inter: *const Interaction) void {
    var sub_buf: [48]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "{d} of {d} still open", .{ inter.tasksRemaining(), inter.tasksTotal() }) catch "Your list";
    header(screen, "Tasks", sub);
    for (task_seeds, 0..) |title, i| {
        const rect = card(screen, taskRowRect(i).y, @intFromFloat(u(52)));
        const done = inter.taskDone(title);
        const cx = @as(f32, @floatFromInt(rect.x)) + u(24);
        const cy = @as(f32, @floatFromInt(rect.y)) + u(26);
        if (done) {
            vector.fillDisc(screen, cx, cy, u(8), s(theme.teal));
        } else {
            vector.strokeCircle(screen, cx, cy, u(8), u(1.6), s(theme.screen_hairline));
        }
        const state_label: []const u8 = if (done) "Done" else "Open";
        const state_colour = if (done) theme.teal else theme.screen_text_muted;
        const state_x = rightF(rect) - u(18) - text.measure(state_label, u(10.5));
        _ = text.draw(screen, state_x, @as(f32, @floatFromInt(rect.y)) + u(31), state_label, u(10.5), s(state_colour));
        // The title is clipped before the state label so a long one never runs under it.
        const colour = if (done) theme.screen_text_muted else theme.screen_text;
        _ = text.drawClippedWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(42), @as(f32, @floatFromInt(rect.y)) + u(31), title, u(13.5), s(colour), state_x - u(10), .semibold);
    }
    agentBand(screen, &inter.tasks_agent_row);
}

/// Completes the task a tap landed on, through the real domain. Returns true when a row was hit.
pub fn tasksTap(inter: *Interaction, sx: i32, sy: i32) bool {
    for (task_seeds, 0..) |title, i| {
        if (inRect(taskRowRect(i), sx, sy)) {
            if (!inter.taskDone(title)) inter.tasksComplete(title);
            return true;
        }
    }
    return false;
}

// --- Music: a fully-local library that opens honestly empty, with a silent agent read ---

/// The Music surface: what is playing and the library — which carries no seeded catalogue, so it opens
/// honestly empty until the person adds their own tracks. The domain is live all the same.
pub fn renderMusic(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Music", "Your library, on device");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "music.now_playing \u{00B7} on device");

    const np = card(screen, @intFromFloat(u(122)), @intFromFloat(u(64)));
    _ = text.draw(screen, @as(f32, @floatFromInt(np.x)) + u(18), @as(f32, @floatFromInt(np.y)) + u(24), "Now playing", u(11), s(theme.screen_text_muted));
    const title = inter.musicNowPlaying() orelse "Nothing playing";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(np.x)) + u(18), @as(f32, @floatFromInt(np.y)) + u(48), title, u(16), s(theme.screen_text), .semibold);

    const lib = card(screen, @intFromFloat(u(122) + u(64) + u(12)), @intFromFloat(u(120)));
    if (inter.musicCount() == 0) {
        const mid = @as(f32, @floatFromInt(lib.x)) + @as(f32, @floatFromInt(lib.w)) / 2.0;
        text.drawCentred(screen, mid, @as(f32, @floatFromInt(lib.y)) + u(52), "Your library is empty", u(14), s(theme.screen_text));
        text.drawCentred(screen, mid, @as(f32, @floatFromInt(lib.y)) + u(74), "Add music from Files to start", u(11.5), s(theme.screen_text_muted));
    } else {
        var count_buf: [24]u8 = undefined;
        _ = text.draw(screen, @as(f32, @floatFromInt(lib.x)) + u(18), @as(f32, @floatFromInt(lib.y)) + u(31), std.fmt.bufPrint(&count_buf, "{d} tracks", .{inter.musicCount()}) catch "tracks", u(13), s(theme.screen_text));
    }
    agentBand(screen, &inter.music_agent_row);
}

// --- Wallet: cards and a real balance; an agent's payment is held and applied exactly once ---

fn walletCardRect(i: usize) graphics.paint.Rect {
    const h = u(56);
    const top = u(206) + @as(f32, @floatFromInt(i)) * (h + u(9));
    return cardRect(@intFromFloat(top), @intFromFloat(h));
}

/// The Wallet surface: the stored-value balance and the person's cards. The agent-presence band stages a
/// payment held for the person; a tap on its Approve pays exactly once through the real domain.
pub fn renderWallet(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Wallet", "Cards and balance, on device");
    const bal = card(screen, @intFromFloat(u(112)), @intFromFloat(u(74)));
    _ = text.draw(screen, @as(f32, @floatFromInt(bal.x)) + u(18), @as(f32, @floatFromInt(bal.y)) + u(26), "Balance", u(12), s(theme.screen_text_muted));
    var money: [16]u8 = undefined;
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(bal.x)) + u(18), @as(f32, @floatFromInt(bal.y)) + u(56), centsLabel(inter.walletBalanceCents(), &money), u(28), s(theme.screen_text), .semibold);

    for (wallet_cards, 0..) |c, i| {
        const rect = card(screen, walletCardRect(i).y, @intFromFloat(u(56)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(24), c.name, u(14), s(theme.screen_text), .semibold);
        var last4: [24]u8 = undefined;
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(42), std.fmt.bufPrint(&last4, "ending {s}", .{c.last4}) catch c.last4, u(11), s(theme.screen_text_muted));
    }
    agentBand(screen, &inter.wallet_agent_row);
}

/// Approves the wallet agent's held payment on a tap of the band's control. Returns true when handled.
pub fn walletTap(inter: *Interaction, sx: i32, sy: i32) bool {
    if (inter.wallet_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.walletApprovePay();
        return true;
    }
    return false;
}

// --- Photos: a real gallery over the on-device media, with a tap to favourite ---

fn photoTileRect(i: usize) graphics.paint.Rect {
    const cols: usize = 3;
    const col = i % cols;
    const row = i / cols;
    const content = @as(f32, @floatFromInt(width_screen())) - 2.0 * @as(f32, @floatFromInt(pad));
    const gap = u(10);
    const tile = (content - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const x = @as(f32, @floatFromInt(pad)) + @as(f32, @floatFromInt(col)) * (tile + gap);
    const y = u(120) + @as(f32, @floatFromInt(row)) * (tile + u(28));
    return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(tile), .h = @intFromFloat(tile) };
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// The Photos surface: a gallery over the real media the device holds — each in-grant image a thumbnail
/// tile, favourited by a tap. An honest empty state when the device holds no photos.
pub fn renderPhotos(screen: *Framebuffer, inter: *const Interaction) void {
    var sub_buf: [32]u8 = undefined;
    const sub = std.fmt.bufPrint(&sub_buf, "{d} on this device", .{inter.photosCount()}) catch "On device";
    header(screen, "Photos", sub);
    var paths: [8][]const u8 = undefined;
    const images = imagePaths(&paths);
    if (images.len == 0) {
        const empty = card(screen, @intFromFloat(u(140)), @intFromFloat(u(120)));
        const mid = @as(f32, @floatFromInt(empty.x)) + @as(f32, @floatFromInt(empty.w)) / 2.0;
        text.drawCentred(screen, mid, @as(f32, @floatFromInt(empty.y)) + u(56), "No photos on this device", u(14), s(theme.screen_text));
        text.drawCentred(screen, mid, @as(f32, @floatFromInt(empty.y)) + u(78), "Import from Files or the Camera", u(11.5), s(theme.screen_text_muted));
    } else {
        for (images, 0..) |id, i| {
            const rect = photoTileRect(i);
            // A soft thumbnail placeholder: the library entry exists over the media domain even where the
            // pixels are not decodable here, so the tile stands for the real photo, labelled by its name.
            paint.paint(screen, &.{.{ .rounded = .{ .rect = rect, .radius = theme.radius_lg, .colour = sa(theme.agent, 40) } }});
            if (inter.photoFavorited(id)) {
                vector.fillDisc(screen, rightF(rect) - u(12), @as(f32, @floatFromInt(rect.y)) + u(12), u(4.5), s(theme.coral));
            }
            const name = basename(id);
            _ = text.drawClipped(screen, @as(f32, @floatFromInt(rect.x)) + u(2), @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) + u(14), name, u(9.5), s(theme.screen_text_muted), rightF(rect) + u(20));
        }
    }
    agentBand(screen, &inter.photos_agent_row);
}

/// Favourites the photo a tap landed on, through the real domain. Returns true when a tile was hit.
pub fn photosTap(inter: *Interaction, sx: i32, sy: i32) bool {
    var paths: [8][]const u8 = undefined;
    const images = imagePaths(&paths);
    for (images, 0..) |id, i| {
        if (inRect(photoTileRect(i), sx, sy)) {
            inter.photosFavorite(id);
            return true;
        }
    }
    return false;
}

// --- Clock: the device time, world clocks computed on device, and a live stopwatch ---

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn worldClockRect(i: usize) graphics.paint.Rect {
    const h = u(46);
    const top = u(268) + @as(f32, @floatFromInt(i)) * (h + u(8));
    return cardRect(@intFromFloat(top), @intFromFloat(h));
}

/// The Clock surface: the device's current time and date, the saved world clocks (each computed on
/// device from the real zone rules against the current instant), and a live stopwatch driven by the
/// frame clock. `t` is elapsed seconds, so the seconds and the stopwatch advance.
pub fn renderClock(screen: *Framebuffer, inter: *const Interaction, t: f32) void {
    header(screen, "Clock", "Local time and world clocks");
    const now_secs = inter.clock_now.seconds() + @as(i64, @intFromFloat(@max(0.0, t)));
    const now_ts = core.time.Timestamp.fromSeconds(now_secs);
    const dt = core.civil.DateTime.fromTimestamp(now_ts);

    const hero = card(screen, @intFromFloat(u(112)), @intFromFloat(u(88)));
    var clock_buf: [16]u8 = undefined;
    const clock_text = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ dt.hour, dt.minute, dt.second }) catch "--:--:--";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(hero.x)) + u(20), @as(f32, @floatFromInt(hero.y)) + u(46), clock_text, u(34), s(theme.screen_text), .semibold);
    var date_buf: [48]u8 = undefined;
    const wd = weekday_names[core.civil.weekday(dt.date) % 7];
    const mn = month_names[(dt.date.month - 1) % 12];
    const date_text = std.fmt.bufPrint(&date_buf, "UTC \u{00B7} {s}, {d} {s} {d}", .{ wd, dt.date.day, mn, dt.date.year }) catch "UTC";
    _ = text.draw(screen, @as(f32, @floatFromInt(hero.x)) + u(20), @as(f32, @floatFromInt(hero.y)) + u(70), date_text, u(11.5), s(theme.screen_text_muted));

    _ = text.drawWeighted(screen, @floatFromInt(pad), u(240), "WORLD CLOCKS", u(11), s(theme.screen_label), .semibold);
    for (world_clocks, 0..) |wc, i| {
        const rect = card(screen, worldClockRect(i).y, @intFromFloat(u(46)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(28), wc.label, u(13), s(theme.screen_text), .semibold);
        var lbuf: [16]u8 = undefined;
        const local = inter.clockLocal(wc.label, &lbuf);
        _ = text.drawWeighted(screen, rightF(rect) - u(18) - text.measureWeighted(local, u(15), .semibold), @as(f32, @floatFromInt(rect.y)) + u(29), local, u(15), s(theme.agent), .semibold);
    }

    // A live stopwatch, driven by the real frame clock — a genuine elapsed timer, not a fabricated one.
    const sw = card(screen, rectBottom(worldClockRect(world_clocks.len - 1)) + @as(i32, @intFromFloat(u(10))), @intFromFloat(u(56)));
    _ = text.draw(screen, @as(f32, @floatFromInt(sw.x)) + u(18), @as(f32, @floatFromInt(sw.y)) + u(24), "Stopwatch \u{00B7} running", u(11), s(theme.screen_text_muted));
    const total_cs: u64 = @intFromFloat(@max(0.0, t) * 100.0);
    var sw_buf: [16]u8 = undefined;
    const sw_text = std.fmt.bufPrint(&sw_buf, "{d:0>2}:{d:0>2}.{d:0>2}", .{ total_cs / 6000, (total_cs / 100) % 60, total_cs % 100 }) catch "00:00.00";
    _ = text.drawWeighted(screen, rightF(sw) - u(18) - text.measureWeighted(sw_text, u(18), .semibold), @as(f32, @floatFromInt(sw.y)) + u(38), sw_text, u(18), s(theme.screen_text), .semibold);

    agentBand(screen, &inter.clock_agent_row);
}

// --- Home: real devices with on/off state the UI toggles, and a lock's held unlock ---

fn deviceRowRect(i: usize) graphics.paint.Rect {
    const h = u(56);
    const top = u(118) + @as(f32, @floatFromInt(i)) * (h + u(9));
    return cardRect(@intFromFloat(top), @intFromFloat(h));
}

fn deviceToggleRect(i: usize) graphics.paint.Rect {
    const rect = deviceRowRect(i);
    const w_px: i32 = @intFromFloat(u(46));
    const h_px: i32 = @intFromFloat(u(26));
    return .{ .x = rightI(rect) - @as(i32, @intFromFloat(u(18))) - w_px, .y = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - h_px, 2), .w = @intCast(w_px), .h = @intCast(h_px) };
}

fn deviceKindLabel(kind: applications.home_domain.Kind) []const u8 {
    return switch (kind) {
        .light => "Light",
        .plug => "Plug",
        .lock => "Lock",
    };
}

/// The Home surface: the real devices, each with its on/off state. A tap toggles a light or a plug
/// through the real domain; the lock reads locked or open, and only the held-unlock band opens it.
pub fn renderSmartHome(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Home", "Your devices, on device");
    for (home_devices, 0..) |d, i| {
        const rect = card(screen, deviceRowRect(i).y, @intFromFloat(u(56)));
        const on = inter.homeOn(d.name) orelse false;
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(24), d.name, u(14), s(theme.screen_text), .semibold);
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(42), deviceKindLabel(d.kind), u(10.5), s(theme.screen_text_muted));
        if (d.kind == .lock) {
            const state_label: []const u8 = if (on) "LOCKED" else "OPEN";
            const state_colour = if (on) theme.teal else theme.denied;
            _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rightI(rect))) - u(18) - text.measureWeighted(state_label, u(11), .semibold), @as(f32, @floatFromInt(rect.y)) + u(34), state_label, u(11), s(state_colour), .semibold);
        } else {
            const tog = deviceToggleRect(i);
            const track = if (on) s(theme.teal) else s(theme.screen_hairline);
            paint.paint(screen, &.{.{ .rounded = .{ .rect = tog, .radius = @intFromFloat(@as(f32, @floatFromInt(tog.h)) / 2.0), .colour = track } }});
            const knob_r = @as(f32, @floatFromInt(tog.h)) / 2.0 - u(3);
            const knob_x = if (on) @as(f32, @floatFromInt(tog.x + @as(i32, @intCast(tog.w)))) - knob_r - u(3) else @as(f32, @floatFromInt(tog.x)) + knob_r + u(3);
            vector.fillDisc(screen, knob_x, @as(f32, @floatFromInt(tog.y)) + @as(f32, @floatFromInt(tog.h)) / 2.0, knob_r, s(theme.screen_card));
        }
    }
    agentBand(screen, &inter.home_agent_row);
}

/// Toggles a light or plug on a tap, or approves the held unlock on the band's control. Returns true when
/// handled. The lock is never opened by a body tap — only the person's Approve on the held unlock opens it.
pub fn smarthomeTap(inter: *Interaction, sx: i32, sy: i32) bool {
    if (inter.home_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.homeApproveUnlock();
        return true;
    }
    for (home_devices, 0..) |d, i| {
        if (inRect(deviceRowRect(i), sx, sy)) {
            if (d.kind == .lock) return true; // absorbed; the lock opens only through the held-unlock band
            const on = inter.homeOn(d.name) orelse false;
            inter.homeSet(d.name, !on);
            return true;
        }
    }
    return false;
}

/// The scratch light screen every surface is drawn onto, reused across frames. It is backed
/// by static storage the size of one screen, so a repaint neither allocates nor frees a
/// framebuffer — the per-frame churn the old path paid is gone. `clearScreen` resets it to the
/// screen's base fill in place, exactly the state a freshly allocated screen would arrive in.
var scratch_pixels: [@as(usize, phone.screen_w) * @as(usize, phone.screen_h) * 4]u8 = undefined;
var scratch_screen: Framebuffer = .{
    .width = phone.screen_w,
    .height = phone.screen_h,
    .pixels = &scratch_pixels,
    .allocator = undefined, // static-backed; never deinit'd
};

pub fn renderSurface(target: *Framebuffer, host: *Host, surface: Surface, t: f32, inter: *const Interaction) !void {
    phone.renderDevice(target);

    const screen = &scratch_screen;
    phone.clearScreen(screen);

    switch (surface) {
        .boot => renderBoot(screen, t),
        .rest => renderRest(screen),
        .shutdown => renderShutdown(screen, t),
        .lock => {
            // The lock screen is a light field with the status bar but its own swipe-up affordance,
            // so it takes the wash and status bar but not the standard home indicator.
            phone.screenWash(screen);
            phone.statusBar(screen);
            renderLock(screen, t);
        },
        else => {
            phone.screenWash(screen);
            phone.statusBar(screen);
            switch (surface) {
                .home => renderHome(screen, host, t, inter),
                .library => renderLibrary(screen),
                .calculator => renderCalculator(screen, inter),
                .activity => renderActivity(screen, host),
                .approval => renderApproval(screen, host),
                .principals => renderPrincipals(screen, host),
                .store => renderStore(screen, inter),
                .phone => renderPhone(screen, inter),
                .messages => renderMessages(screen, inter),
                .camera => renderCamera(screen, inter),
                .agents => renderAgents(screen, host, inter),
                .agent_detail => renderAgentDetail(screen, host, inter),
                .calendar => renderCalendar(screen, inter),
                .weather => renderWeather(screen, inter),
                .contacts => renderContacts(screen, inter),
                .files => renderFiles(screen, inter),
                .notes => renderNotes(screen, inter),
                .health => renderHealth(screen, inter),
                .maps => renderMaps(screen, inter),
                .settings => renderSettings(screen, inter),
                .browser => renderBrowser(screen, inter),
                .tasks => renderTasks(screen, inter),
                .music => renderMusic(screen, inter),
                .wallet => renderWallet(screen, inter),
                .photos => renderPhotos(screen, inter),
                .clock => renderClock(screen, inter, t),
                .smarthome => renderSmartHome(screen, inter),
                else => unreachable,
            }
            phone.homeIndicator(screen);
        },
    }

    phone.composite(target, screen.*);
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
/// A back chevron drawn at the top-left of an app — the working way out. The tap target for it is the
/// top-left region the desktop shell's `navigate` reads; drawing and hit-test are kept in step.
fn backChevron(screen: *Framebuffer, x: f32, y: f32) void {
    const cw = u(6);
    const ch = u(8);
    vector.strokePolyline(screen, &.{
        .{ .x = x + cw, .y = y - ch }, .{ .x = x, .y = y }, .{ .x = x + cw, .y = y + ch },
    }, u(2.2), s(theme.screen_text), false);
}

fn header(screen: *Framebuffer, title: []const u8, subtitle: []const u8) void {
    // A back chevron at the top-left is the working way back to home; the title and subtitle sit to its
    // right. The 21px title is semibold, the 11.5px subtitle the muted regular weight, clipped so a long
    // one cannot spill off the edge.
    backChevron(screen, @as(f32, @floatFromInt(pad)) + u(2), u(52));
    const tx: f32 = @as(f32, @floatFromInt(pad)) + u(22);
    const edge: f32 = @as(f32, @floatFromInt(width_screen())) - @as(f32, @floatFromInt(pad));
    _ = text.draw(screen, tx, u(58), title, u(21), s(theme.screen_text));
    _ = text.drawClipped(screen, tx, u(74), subtitle, u(11.5), s(theme.screen_text_muted), edge);
}

/// The geometry of a content card at a given top: the content column, inset by `pad`.
fn cardRect(y: i32, h: u32) graphics.paint.Rect {
    return .{ .x = pad, .y = y, .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = h };
}

/// Paints a white card (a soft drop shadow, then the card fill) into a known rectangle.
fn paintCard(screen: *Framebuffer, rect: graphics.paint.Rect) void {
    // A real soft drop shadow feathered beneath the card, then the card itself — so every card in the
    // OS reads as a raised layer instead of a flat fill.
    paint.paint(screen, &.{
        .{ .shadow = .{
            .rect = .{ .x = rect.x, .y = rect.y + theme.shadow_offset_y, .w = @intCast(rect.w), .h = rect.h },
            .radius = theme.radius_xl,
            .blur = theme.shadow_blur,
            .colour = s(theme.shadow_tint),
            .alpha = theme.shadow_tint.alpha,
        } },
        .{ .rounded = .{ .rect = rect, .radius = theme.radius_xl, .colour = s(theme.screen_card) } },
    });
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

/// The bottom edge of a rectangle, as i32.
fn rectBottom(rect: graphics.paint.Rect) i32 {
    return rect.y + @as(i32, @intCast(rect.h));
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

pub fn renderHome(screen: *Framebuffer, host: *Host, t: f32, inter: *const Interaction) void {
    var greeting: []const u8 = "Good morning";
    var buf: [96]u8 = undefined;
    if (host.registry.lookup(host.human)) |human| {
        greeting = std.fmt.bufPrint(&buf, "Good morning, {s}", .{human.display_name}) catch "Good morning";
    }
    var day_buf: [64]u8 = undefined;
    const day_line = std.fmt.bufPrint(&day_buf, "Tuesday \u{00B7} {d} agents working", .{host.agents.items.len}) catch "Tuesday";

    // The held-for-approval action becomes the active task title.
    var active: ?[]const u8 = "Planning your trip";
    var index: usize = 0;
    while (index < host.ledger.count()) : (index += 1) {
        const event = host.ledger.at(index) orelse continue;
        if (event.action != .approval_requested) continue;
        active = "Confirming a venue for you";
        break;
    }

    home.render(screen, .{
        .greeting = greeting,
        .day_line = day_line,
        .tasks = &.{
            .{ .title = "Arranging your day", .note = "just now \u{00B7} agents coordinating", .hue = theme.teal },
        },
        .active_title = active,
        .assistant_online = inter.assistantAvailable(),
        .assistant_reply = inter.assistantReply(),
        .assistant_prompt = inter.assistantPrompt(),
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
        .browser => .browser,
        .notes => .notes,
        .health => .health,
        .maps => .maps,
        .tasks => .tasks,
        .music => .music,
        .wallet => .wallet,
        .photos => .photos,
        .clock => .clock,
        .home => .smarthome,
        .mail => null,
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
    .notes,    .health,   .maps,     .tasks,   .music,      .wallet,
    .photos,   .clock,    .home,
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

    // The agent assist bar: ask a math question in words and the on-device agent answers, computing
    // through the same calc.evaluate an agent tool call reaches. A live command bar, not a label.
    const assist: graphics.paint.Rect = .{ .x = display.x, .y = @intFromFloat(@as(f32, @floatFromInt(display.y)) + u(86)), .w = display.w, .h = @intFromFloat(u(38)) };
    paint.paint(screen, &.{.{ .rounded = .{ .rect = assist, .radius = theme.radius_pill, .colour = sa(theme.agent, 22) } }});
    vector.fillDisc(screen, @as(f32, @floatFromInt(assist.x)) + u(18), @as(f32, @floatFromInt(assist.y)) + u(19), u(3.5), s(theme.agent));
    const assist_x = @as(f32, @floatFromInt(assist.x)) + u(30);
    const assist_edge = @as(f32, @floatFromInt(assist.x + @as(i32, @intCast(assist.w)))) - u(14);
    const assist_mid = @as(f32, @floatFromInt(assist.y)) + u(24);
    if (inter.assistantPrompt().len > 0) {
        _ = text.drawClipped(screen, assist_x, assist_mid, inter.assistantPrompt(), u(12.5), s(theme.screen_text), assist_edge);
    } else if (inter.assistantReply().len > 0) {
        _ = text.drawClipped(screen, assist_x, assist_mid, inter.assistantReply(), u(12.5), s(theme.agent), assist_edge);
    } else if (inter.assistantAvailable()) {
        _ = text.drawWeighted(screen, assist_x, assist_mid, "Ask the agent a math question", u(11.5), s(theme.screen_text_muted), .regular);
    } else {
        _ = text.drawWeighted(screen, assist_x, assist_mid, "calc.evaluate \u{00B7} open to agents", u(11), s(theme.agent), .regular);
    }

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

/// The fixed footer band that carries the uniform agent-presence layer — identical on every agentic
/// app: a violet dot, the door the agent used, and the last real action derived from domain state.
/// Placed above the home indicator, below every app's own content, so it never shifts the app's layout.
fn agentBandRect() graphics.paint.Rect {
    return cardRect(@as(i32, @intCast(phone.screen_h)) - @as(i32, @intFromFloat(u(78))), @intFromFloat(u(58)));
}

/// The band's one control, when the last action needs the person: Approve a held commit, or Revert a
/// revertible organize. A fixed rect so the render and the hit-test read the same button.
fn agentBandActionRect() graphics.paint.Rect {
    const band = agentBandRect();
    const w: i32 = @intFromFloat(u(84));
    const h: i32 = @intFromFloat(u(32));
    return .{ .x = rightI(band) - @as(i32, @intFromFloat(u(12))) - w, .y = band.y + @divTrunc(@as(i32, @intCast(band.h)) - h, 2), .w = @intCast(w), .h = @intCast(h) };
}

/// The label of the band's control for a row, or null when the last action needs nothing from the
/// person (a silent read, a notify already applied).
fn agentBandActionLabel(row: *const AgentRow) ?[]const u8 {
    return switch (row.control) {
        .none => null,
        .approve => "Approve",
        .revert => "Revert",
    };
}

/// Draws the uniform agent-presence layer for `row`. The violet dot and door name make the agent's
/// co-inhabitance literal; the line beneath is the last real action, read from the domain, never a
/// scripted transcript. When the action is held or revertible, one control lets the person act on it.
fn agentBand(screen: *Framebuffer, row: *const AgentRow) void {
    const band = agentBandRect();
    // A faint violet-tinted card, so the agent's presence reads as a distinct layer rather than another
    // content card.
    paint.paint(screen, &.{.{ .rounded = .{ .rect = band, .radius = theme.radius_xl, .colour = sa(theme.agent, 20) } }});
    const left = @as(f32, @floatFromInt(band.x)) + u(16);
    const has_control = agentBandActionLabel(row) != null;
    // Text stops before the control when there is one, so a door or detail never runs under the button.
    const text_edge = if (has_control) @as(f32, @floatFromInt(agentBandActionRect().x)) - u(10) else rightF(band) - u(16);
    vector.fillDisc(screen, left, @as(f32, @floatFromInt(band.y)) + u(20), u(3.0), s(theme.agent));
    const door = if (row.door.len > 0) row.door else "agent \u{00B7} open to agents";
    _ = text.drawClipped(screen, left + u(10), @as(f32, @floatFromInt(band.y)) + u(24), door, u(10.5), s(theme.agent), text_edge);
    const detail = if (row.detail_len > 0) row.message() else "No agent has acted here yet";
    const detail_colour = if (row.status == .denied) theme.denied else theme.screen_text;
    _ = text.drawClipped(screen, left, @as(f32, @floatFromInt(band.y)) + u(44), detail, u(11.5), s(detail_colour), text_edge);

    if (agentBandActionLabel(row)) |label| {
        const a = agentBandActionRect();
        const held = row.status == .held;
        paint.paint(screen, &.{.{ .rounded = .{ .rect = a, .radius = @intFromFloat(u(16)), .colour = if (held) s(theme.agent) else s(theme.screen_hairline) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(a.x)) + @as(f32, @floatFromInt(a.w)) / 2.0, @as(f32, @floatFromInt(a.y)) + u(21), label, u(11.5), s(if (held) theme.base else theme.screen_text));
    }
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

/// One placed row of the Activity ledger. The screen holds at most `max_rows`, so the rows
/// live in a fixed stack array — the render path builds no heap list per frame.
const ActivityRow = struct { actor: []const u8, action: []const u8, outcome: OutcomeView, colour: theme.Colour };

pub fn renderActivity(screen: *Framebuffer, host: *Host) void {
    header(screen, "Activity", "Every action, under a capability");

    var rows: [max_rows]ActivityRow = undefined;
    var count: usize = 0;

    var index: usize = host.ledger.count();
    while (index > 0 and count < max_rows) {
        index -= 1;
        const event = host.ledger.at(index) orelse continue;
        if (!surfaced(event.action)) continue;
        const actor = host.registry.lookup(event.actor) orelse continue;
        const is_human = actor.kind == .human;
        rows[count] = .{
            .actor = if (is_human) "You" else actor.display_name,
            .action = actionText(event.action),
            .outcome = outcomeView(event.outcome),
            .colour = kindColour(actor.kind),
        };
        count += 1;
    }
    std.mem.reverse(ActivityRow, rows[0..count]);

    // The ledger is a flex column of equal-height cards; the engine places them.
    var heights: [graphics.stack.max_blocks]f32 = undefined;
    for (0..count) |i| heights[i] = 58;
    var tops: [graphics.stack.max_blocks]f32 = undefined;
    graphics.stack.columnTops(120, heights[0..count], 8, tops[0..count]);

    for (rows[0..count], 0..) |row, i| {
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

pub fn renderPrincipals(screen: *Framebuffer, host: *Host) void {
    _ = host;
    renderScreen(screen, principals_screen);
}

/// Files: the granted folder's contents, and the agent search confined to it.
/// The entries the Files screen shows: the first are within the grant and open for real; the last
/// escapes it, kept in the list so the grant boundary is visible — opening it is refused.
const FileEntry = struct { path: []const u8, label: []const u8, sub: []const u8, is_dir: bool = false };
const file_entries = [_]FileEntry{
    .{ .path = "documents/Trip-Lisbon.md", .label = "Trip-Lisbon.md", .sub = "documents \u{00B7} 4 KB" },
    .{ .path = "documents/budget.csv", .label = "budget.csv", .sub = "documents \u{00B7} 2 KB" },
    .{ .path = "photos/lisbon.jpg", .label = "lisbon.jpg", .sub = "photos \u{00B7} 1.8 MB" },
    .{ .path = "../system/keychain", .label = "keychain", .sub = "outside your grant" },
};

fn fileRowRect(i: usize) graphics.paint.Rect {
    return cardRect(168 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(56))) + 8), @intFromFloat(u(56)));
}

pub fn renderFiles(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Files", "Everything stays inside your grant");

    for (file_entries, 0..) |entry, i| {
        const rect = card(screen, fileRowRect(i).y, @intFromFloat(u(56)));
        const in_grant = applications.files.withinGrant(entry.path);
        const left = @as(f32, @floatFromInt(rect.x)) + u(20);
        _ = text.drawWeighted(screen, left, @as(f32, @floatFromInt(rect.y)) + u(24), entry.label, u(14), s(theme.screen_text), .semibold);
        _ = text.draw(screen, left, @as(f32, @floatFromInt(rect.y)) + u(41), entry.sub, u(10.5), s(if (in_grant) theme.screen_text_muted else theme.denied));

        // The right-hand state: what the last open decided for this row, or a hint at what it will do.
        const state = inter.fileOpenedState(i);
        const label: []const u8 = if (state) |ok| (if (ok) "Opened" else "Blocked") else if (in_grant) "Open" else "Locked";
        const colour = if (state) |ok| (if (ok) theme.teal else theme.denied) else if (in_grant) theme.screen_text_muted else theme.denied;
        _ = text.drawWeighted(screen, rightF(rect) - u(18) - text.measureWeighted(label, u(11), .semibold), @as(f32, @floatFromInt(rect.y)) + u(34), label, u(11), s(colour), .semibold);
    }
    agentBand(screen, &inter.files_agent_row);
}

/// Opens the file entry a tap landed on, through the real domain. Returns true when a row was hit.
pub fn filesTap(inter: *Interaction, sx: i32, sy: i32) bool {
    // The agent-presence footer's Revert control, when the agent's organize left a move to undo.
    if (inter.files_agent_row.control == .revert and inRect(agentBandActionRect(), sx, sy)) {
        inter.filesAgentRevert();
        return true;
    }
    for (file_entries, 0..) |_, i| {
        const rect = fileRowRect(i);
        if (sy >= rect.y and sy <= rect.y + @as(i32, @intCast(rect.h)) and sx >= rect.x and sx <= rightI(rect)) {
            inter.fileOpen(i);
            return true;
        }
    }
    return false;
}

/// Settings: rendered from the policy registry, each setting shown with its sensitivity — what an
/// agent may do with it, decided by the setting, not the caller. human_only is the person's alone.
const SettingRow = struct { setting: applications.settings.Setting, label: []const u8 };

/// The settings the screen shows: open toggles the person (and their agents) may flip, and a sensitive
/// one that is the person's alone. Each reads and writes the real settings domain.
const settings_rows = [_]SettingRow{
    .{ .setting = .wifi_enabled, .label = "Wi-Fi" },
    .{ .setting = .bluetooth_enabled, .label = "Bluetooth" },
    .{ .setting = .low_power_mode, .label = "Low Power Mode" },
    .{ .setting = .reduce_motion, .label = "Reduce Motion" },
    .{ .setting = .do_not_disturb, .label = "Do Not Disturb" },
    .{ .setting = .biometric_unlock, .label = "Biometric Unlock" },
};

fn settingRowRect(i: usize) graphics.paint.Rect {
    return cardRect(172 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(52))) + 8), @intFromFloat(u(52)));
}

pub fn renderSettings(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Settings", "What you change, and what an agent may");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "settings.read \u{00B7} the class gates every write");

    for (settings_rows, 0..) |row, i| {
        const rect = card(screen, settingRowRect(i).y, @intFromFloat(u(52)));
        const sensitive = row.setting.isSensitive();
        const on = inter.settingValue(row.setting) != 0;
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(24), row.label, u(13), s(theme.screen_text));
        const class_note = if (sensitive) "You only" else "Open to agents";
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(39), class_note, u(10), s(if (sensitive) theme.denied else theme.teal));

        // The control on the right: a real toggle for an open setting, a lock for a sensitive one.
        const t = settingToggleRect(i);
        if (sensitive) {
            _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rightI(t))) - text.measureWeighted("LOCKED", u(10), .semibold), @as(f32, @floatFromInt(rect.y)) + u(30), "LOCKED", u(10), s(theme.denied), .semibold);
        } else {
            const track = if (on) s(theme.teal) else s(theme.screen_hairline);
            paint.paint(screen, &.{.{ .rounded = .{ .rect = t, .radius = @intFromFloat(@as(f32, @floatFromInt(t.h)) / 2.0), .colour = track } }});
            const knob_r = @as(f32, @floatFromInt(t.h)) / 2.0 - u(3);
            const knob_x = if (on) @as(f32, @floatFromInt(t.x + @as(i32, @intCast(t.w)))) - knob_r - u(3) else @as(f32, @floatFromInt(t.x)) + knob_r + u(3);
            vector.fillDisc(screen, knob_x, @as(f32, @floatFromInt(t.y)) + @as(f32, @floatFromInt(t.h)) / 2.0, knob_r, s(theme.screen_card));
        }
    }
    agentBand(screen, &inter.settings_agent_row);
}

fn settingToggleRect(i: usize) graphics.paint.Rect {
    const rect = settingRowRect(i);
    const w_px: i32 = @intFromFloat(u(46));
    const h_px: i32 = @intFromFloat(u(26));
    return .{ .x = rightI(rect) - @as(i32, @intFromFloat(u(18))) - w_px, .y = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - h_px, 2), .w = @intCast(w_px), .h = @intCast(h_px) };
}

/// Toggles the open setting a tap landed on. Returns true when one was toggled (a sensitive setting is
/// not reachable this way — the domain refuses it, like an agent's write).
pub fn settingsTap(inter: *Interaction, sx: i32, sy: i32) bool {
    for (settings_rows, 0..) |row, i| {
        const rect = settingRowRect(i);
        if (sy >= rect.y and sy <= rect.y + @as(i32, @intCast(rect.h)) and sx >= rect.x and sx <= rightI(rect)) {
            if (row.setting.isSensitive()) return false;
            inter.settingToggle(row.setting);
            return true;
        }
    }
    return false;
}

/// The working hours the Calendar day shows, and the static `calendar.add` arg for booking focus on
/// each (the domain keeps a title by reference, so the arg must be a static string, not a buffer).
const cal_first_hour: u32 = 9;
const cal_hours: usize = 9; // 09:00 through 17:00

fn focusArg(slot: u32) ?[]const u8 {
    return switch (slot) {
        9 => "Focus@9",
        10 => "Focus@10",
        11 => "Focus@11",
        12 => "Focus@12",
        13 => "Focus@13",
        14 => "Focus@14",
        15 => "Focus@15",
        16 => "Focus@16",
        17 => "Focus@17",
        else => null,
    };
}

fn calHourRect(i: usize) graphics.paint.Rect {
    return cardRect(150 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(32))) + 6), @intFromFloat(u(32)));
}

/// Calendar: the working day, hour by hour, each free or busy — computed from the real events by the
/// domain. Committed hours read as focus blocks; a free hour is tappable to book focus, which schedules
/// it for real and the day recomputes.
pub fn renderCalendar(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Calendar", "Your day, in free and busy hours");

    var i: usize = 0;
    while (i < cal_hours) : (i += 1) {
        const hour: u32 = cal_first_hour + @as(u32, @intCast(i));
        const rect = card(screen, calHourRect(i).y, @intFromFloat(u(32)));
        const busy = inter.slotBusy(hour);

        // The hour label on the left.
        var label_buf: [8]u8 = undefined;
        const hour_label = std.fmt.bufPrint(&label_buf, "{d:0>2}:00", .{hour}) catch "--:--";
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(16), @as(f32, @floatFromInt(rect.y)) + u(21), hour_label, u(12), s(theme.screen_text_muted), .semibold);

        // The slot bar: filled for committed time, an outline the person can tap when free.
        const bar = graphics.paint.Rect{
            .x = rect.x + @as(i32, @intFromFloat(u(66))),
            .y = rect.y + @as(i32, @intFromFloat(u(6))),
            .w = @intCast(rect.w - @as(u32, @intFromFloat(u(82)))),
            .h = @intFromFloat(u(20)),
        };
        const proposed = inter.calendar_proposed_slot == hour;
        if (busy and proposed) {
            // The hour the agent proposed: the agent's outline, distinct from the person's own blocks,
            // so a real proposal reads as a proposal on the day rather than an indistinguishable commit.
            const bl = @as(f32, @floatFromInt(bar.x));
            const bt = @as(f32, @floatFromInt(bar.y));
            const br = bl + @as(f32, @floatFromInt(bar.w));
            const bb = bt + @as(f32, @floatFromInt(bar.h));
            vector.strokePolyline(screen, &.{ .{ .x = bl, .y = bt }, .{ .x = br, .y = bt }, .{ .x = br, .y = bb }, .{ .x = bl, .y = bb } }, u(1.6), s(theme.agent), true);
            _ = text.drawWeighted(screen, @as(f32, @floatFromInt(bar.x)) + u(12), @as(f32, @floatFromInt(bar.y)) + u(15), "Agent focus", u(11), s(theme.agent), .semibold);
        } else if (busy) {
            paint.paint(screen, &.{.{ .rounded = .{ .rect = bar, .radius = @intFromFloat(u(7)), .colour = s(theme.agent) } }});
            _ = text.drawWeighted(screen, @as(f32, @floatFromInt(bar.x)) + u(12), @as(f32, @floatFromInt(bar.y)) + u(15), "Focus block", u(11), s(theme.base), .semibold);
        } else {
            paint.paint(screen, &.{.{ .rounded = .{ .rect = bar, .radius = @intFromFloat(u(7)), .colour = s(theme.screen_hairline) } }});
            _ = text.draw(screen, @as(f32, @floatFromInt(bar.x)) + u(12), @as(f32, @floatFromInt(bar.y)) + u(15), "Free \u{00B7} tap to focus", u(11), s(theme.screen_text_muted));
        }
    }
    agentBand(screen, &inter.calendar_agent_row);
}

/// Books focus on the free hour a tap landed on, through the real domain. Returns true when a free
/// hour was hit (a busy one absorbs the tap without change).
pub fn calendarTap(inter: *Interaction, sx: i32, sy: i32) bool {
    // The agent-presence footer's Approve control: run the held commit exactly once, on the person's tap.
    if (inter.calendar_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.calendarApproveCommit();
        return true;
    }
    var i: usize = 0;
    while (i < cal_hours) : (i += 1) {
        const rect = calHourRect(i);
        if (sy >= rect.y and sy <= rect.y + @as(i32, @intCast(rect.h)) and sx >= rect.x and sx <= rightI(rect)) {
            const hour: u32 = cal_first_hour + @as(u32, @intCast(i));
            if (inter.slotBusy(hour)) return false;
            inter.bookFocus(hour);
            return true;
        }
    }
    return false;
}

/// The pages the Browser knows: a small set the person can open, each carrying the static grant args
/// for its origin (the domain keeps an origin by reference, so the arg must be a static string). The
/// grants are ordered to match the Permission enum — location, camera, notifications.
const browser_home = "https://lisbon.example/guide";
const BrowserLink = struct { url: []const u8, label: []const u8, host: []const u8, grants: [3][]const u8 };
const browser_links = [_]BrowserLink{
    .{ .url = "https://lisbon.example/guide", .label = "Lisbon travel guide", .host = "lisbon.example", .grants = .{ "https://lisbon.example/guide|location", "https://lisbon.example/guide|camera", "https://lisbon.example/guide|notifications" } },
    .{ .url = "https://trains.example/pt", .label = "Portugal rail times", .host = "trains.example", .grants = .{ "https://trains.example/pt|location", "https://trains.example/pt|camera", "https://trains.example/pt|notifications" } },
    .{ .url = "https://weather.example/lisbon", .label = "Lisbon weather", .host = "weather.example", .grants = .{ "https://weather.example/lisbon|location", "https://weather.example/lisbon|camera", "https://weather.example/lisbon|notifications" } },
};

const BrowserPerm = struct { perm: applications.browser.Permission, label: []const u8 };
const browser_perms = [_]BrowserPerm{
    .{ .perm = .location, .label = "Location" },
    .{ .perm = .camera, .label = "Camera" },
    .{ .perm = .notifications, .label = "Alerts" },
};

fn browserLinkIndex(inter: *const Interaction) usize {
    const page = inter.browserCurrent() orelse return 0;
    for (browser_links, 0..) |link, i| {
        if (std.mem.eql(u8, link.url, page.url)) return i;
    }
    return 0;
}

fn browserPageLabel(kind: applications.browser.PageKind) []const u8 {
    return switch (kind) {
        .article => "Article",
        .search => "Search",
        .video => "Video",
        .shop => "Shop",
        .docs => "Docs",
    };
}

fn browserAddrRect() graphics.paint.Rect {
    return cardRect(148, @intFromFloat(u(62)));
}

fn browserBookmarkRect() graphics.paint.Rect {
    const addr = browserAddrRect();
    const w_px: i32 = @intFromFloat(u(60));
    const h_px: i32 = @intFromFloat(u(28));
    return .{ .x = rightI(addr) - @as(i32, @intFromFloat(u(14))) - w_px, .y = addr.y + @divTrunc(@as(i32, @intCast(addr.h)) - h_px, 2), .w = @intCast(w_px), .h = @intCast(h_px) };
}

fn browserLinkRect(i: usize) graphics.paint.Rect {
    return cardRect(244 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(46))) + 8), @intFromFloat(u(46)));
}

fn browserPermCardRect() graphics.paint.Rect {
    return cardRect(462, @intFromFloat(u(70)));
}

fn browserPermRect(i: usize) graphics.paint.Rect {
    const c = browserPermCardRect();
    const inset = u(12);
    const gap = u(8);
    const usable = @as(f32, @floatFromInt(c.w)) - 2 * inset;
    const chip_w = (usable - 2 * gap) / 3;
    const chip_h = u(26);
    const col: f32 = @floatFromInt(i);
    return .{
        .x = c.x + @as(i32, @intFromFloat(inset + col * (chip_w + gap))),
        .y = c.y + @as(i32, @intFromFloat(u(32))),
        .w = @intFromFloat(chip_w),
        .h = @intFromFloat(chip_h),
    };
}

/// Browser: the address the person is on read as a projection, the pages they can open, and what the
/// current site has been granted. Every read and change goes through the app's real browser domain.
pub fn renderBrowser(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Browser", "The web, read as a projection");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "browser.read_page \u{00B7} projected");

    const cur = browserLinkIndex(inter);
    const link = browser_links[cur];

    // The address card: the current host, the page projection, and a bookmark control.
    const addr = card(screen, browserAddrRect().y, @intFromFloat(u(62)));
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(addr.x)) + u(16), @as(f32, @floatFromInt(addr.y)) + u(24), link.host, u(13), s(theme.screen_text), .semibold);
    if (inter.browserCurrent()) |page| {
        var proj_buf: [40]u8 = undefined;
        const proj = std.fmt.bufPrint(&proj_buf, "{s} \u{00B7} {d} words", .{ browserPageLabel(page.kind), page.words }) catch browserPageLabel(page.kind);
        _ = text.draw(screen, @as(f32, @floatFromInt(addr.x)) + u(16), @as(f32, @floatFromInt(addr.y)) + u(42), proj, u(10.5), s(theme.screen_text_muted));
    }
    const bm = browserBookmarkRect();
    const saved = inter.browserBookmarked(link.url);
    paint.paint(screen, &.{.{ .rounded = .{ .rect = bm, .radius = @intFromFloat(u(14)), .colour = if (saved) s(theme.agent) else s(theme.screen_hairline) } }});
    const bm_label = if (saved) "Saved" else "Save";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(bm.x)) + (@as(f32, @floatFromInt(bm.w)) - text.measureWeighted(bm_label, u(11), .semibold)) / 2.0, @as(f32, @floatFromInt(bm.y)) + u(19), bm_label, u(11), s(if (saved) theme.base else theme.screen_text_muted), .semibold);

    // The pages the person can open; the current one is marked.
    for (browser_links, 0..) |l, i| {
        const rect = card(screen, browserLinkRect(i).y, @intFromFloat(u(46)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(18), @as(f32, @floatFromInt(rect.y)) + u(28), l.label, u(13), s(theme.screen_text), if (i == cur) .semibold else .regular);
        const marker = if (i == cur) "Open" else "\u{203A}";
        const marker_colour = if (i == cur) theme.teal else theme.screen_text_muted;
        _ = text.drawWeighted(screen, rightF(rect) - u(18) - text.measureWeighted(marker, u(11), .semibold), @as(f32, @floatFromInt(rect.y)) + u(28), marker, u(11), s(marker_colour), .semibold);
    }

    // What the current site has been granted — each a chip the person taps to grant.
    const perm_card = card(screen, browserPermCardRect().y, @intFromFloat(u(70)));
    _ = text.draw(screen, @as(f32, @floatFromInt(perm_card.x)) + u(14), @as(f32, @floatFromInt(perm_card.y)) + u(20), "This site can", u(11), s(theme.screen_text_muted));
    for (browser_perms, 0..) |bp, i| {
        const chip = browserPermRect(i);
        const granted = inter.siteHas(link.url, bp.perm);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = chip, .radius = @intFromFloat(u(13)), .colour = if (granted) s(theme.teal) else s(theme.screen_hairline) } }});
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(chip.x)) + (@as(f32, @floatFromInt(chip.w)) - text.measureWeighted(bp.label, u(10.5), .semibold)) / 2.0, @as(f32, @floatFromInt(chip.y)) + u(17), bp.label, u(10.5), s(if (granted) theme.base else theme.screen_text_muted), .semibold);
    }
    agentBand(screen, &inter.browser_agent_row);
}

/// Opens a page, bookmarks the current one, or grants the current site a permission — whichever the
/// tap landed on. Returns true when a browser control was hit.
pub fn browserTap(inter: *Interaction, sx: i32, sy: i32) bool {
    // The agent-presence footer's Approve control: run a held form submit exactly once, on the person's tap.
    if (inter.browser_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.browserApproveSubmit();
        return true;
    }
    const cur = browserLinkIndex(inter);
    const link = browser_links[cur];
    // The bookmark control.
    const bm = browserBookmarkRect();
    if (sx >= bm.x and sx <= bm.x + @as(i32, @intCast(bm.w)) and sy >= bm.y and sy <= bm.y + @as(i32, @intCast(bm.h))) {
        inter.browserBookmark(link.url);
        return true;
    }
    // A page to open.
    for (browser_links, 0..) |l, i| {
        const rect = browserLinkRect(i);
        if (sy >= rect.y and sy <= rect.y + @as(i32, @intCast(rect.h)) and sx >= rect.x and sx <= rightI(rect)) {
            inter.browserOpen(l.url);
            return true;
        }
    }
    // A permission to grant the current site.
    for (browser_perms, 0..) |bp, i| {
        const chip = browserPermRect(i);
        if (sx >= chip.x and sx <= chip.x + @as(i32, @intCast(chip.w)) and sy >= chip.y and sy <= chip.y + @as(i32, @intCast(chip.h))) {
            if (!inter.siteHas(link.url, bp.perm)) inter.grantSite(link.grants[@intFromEnum(bp.perm)]);
            return true;
        }
    }
    return false;
}

fn weatherLabel(condition: applications.weather.Condition) []const u8 {
    return switch (condition) {
        .clear => "Clear",
        .cloudy => "Cloudy",
        .rain => "Rain",
        .snow => "Snow",
        .storm => "Storm",
    };
}

fn weatherColour(condition: applications.weather.Condition) design.theme.Colour {
    return switch (condition) {
        .clear => theme.amber,
        .cloudy => theme.human,
        .rain => theme.teal,
        .snow => theme.human,
        .storm => theme.denied,
    };
}

/// Draws a weather glyph for a condition, centred at (cx, cy) with radius `r`: a sun, a cloud, a
/// raining cloud, a snowing cloud, or a cloud with a bolt.
fn weatherGlyph(screen: *Framebuffer, cx: f32, cy: f32, r: f32, condition: applications.weather.Condition, colour: graphics.framebuffer.Rgba) void {
    switch (condition) {
        .clear => {
            vector.fillDisc(screen, cx, cy, r * 0.62, colour);
            const rays = [_][2]f32{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -0.7, -0.7 }, .{ 0.7, 0.7 }, .{ -0.7, 0.7 }, .{ 0.7, -0.7 } };
            for (rays) |d| {
                vector.strokePolyline(screen, &.{
                    .{ .x = cx + d[0] * r * 0.85, .y = cy + d[1] * r * 0.85 },
                    .{ .x = cx + d[0] * r * 1.15, .y = cy + d[1] * r * 1.15 },
                }, r * 0.16, colour, false);
            }
        },
        else => {
            // Every non-clear sky is a cloud: three discs forming the puff, plus what falls below it.
            vector.fillDisc(screen, cx - r * 0.5, cy, r * 0.5, colour);
            vector.fillDisc(screen, cx + r * 0.5, cy, r * 0.5, colour);
            vector.fillDisc(screen, cx, cy - r * 0.35, r * 0.6, colour);
            switch (condition) {
                .rain, .storm => {
                    const drops = [_]f32{ -0.5, 0, 0.5 };
                    for (drops) |dx| vector.strokePolyline(screen, &.{
                        .{ .x = cx + dx * r, .y = cy + r * 0.7 },
                        .{ .x = cx + dx * r - r * 0.12, .y = cy + r * 1.15 },
                    }, r * 0.13, colour, false);
                    if (condition == .storm) vector.strokePolyline(screen, &.{
                        .{ .x = cx + r * 0.15, .y = cy + r * 0.6 }, .{ .x = cx - r * 0.15, .y = cy + r * 1.0 }, .{ .x = cx + r * 0.1, .y = cy + r * 1.0 }, .{ .x = cx - r * 0.15, .y = cy + r * 1.45 },
                    }, r * 0.13, s(theme.amber), false);
                },
                .snow => {
                    const flakes = [_][2]f32{ .{ -0.5, 0.9 }, .{ 0, 1.15 }, .{ 0.5, 0.9 } };
                    for (flakes) |f| vector.fillDisc(screen, cx + f[0] * r, cy + f[1] * r, r * 0.12, colour);
                },
                else => {},
            }
        },
    }
}

/// The alert control at the foot of the hero card.
fn weatherAlertRect() graphics.paint.Rect {
    const w_px: i32 = @intFromFloat(u(92));
    const h_px: i32 = @intFromFloat(u(30));
    return .{ .x = @as(i32, @intCast(width_screen())) - pad - @as(i32, @intFromFloat(u(14))) - w_px, .y = @intFromFloat(u(206)), .w = @intCast(w_px), .h = @intCast(h_px) };
}

/// Weather: the device's current location, shown large — its live temperature, sky, and hourly
/// forecast, fetched from a real keyless provider at where the device actually is. Nothing is
/// hardcoded: offline, the app says it is unlocated rather than showing an invented place.
pub fn renderWeather(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Weather", "Your location, live");

    if (!inter.weatherLocated() or inter.weatherReading() == null) {
        // No live reading: honest, not a fabricated city. The running OS fetches on start; a host with
        // no network stays here.
        const card_rect = card(screen, @intFromFloat(u(100)), @intFromFloat(u(120)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(card_rect.x)) + u(22), @as(f32, @floatFromInt(card_rect.y)) + u(48), "Weather unavailable", u(17), s(theme.screen_text), .semibold);
        _ = text.draw(screen, @as(f32, @floatFromInt(card_rect.x)) + u(22), @as(f32, @floatFromInt(card_rect.y)) + u(76), "Connect to fetch your local forecast", u(12), s(theme.screen_text_muted));
        agentBand(screen, &inter.weather_agent_row);
        return;
    }

    const reading = inter.weatherReading().?;
    // The hero: the current city, large.
    const hero = card(screen, @intFromFloat(u(100)), @intFromFloat(u(150)));
    const left = @as(f32, @floatFromInt(hero.x)) + u(22);
    _ = text.drawWeighted(screen, left, @as(f32, @floatFromInt(hero.y)) + u(34), inter.weatherCity(), u(17), s(theme.screen_text), .semibold);
    var degrees_buf: [12]u8 = undefined;
    const degrees = std.fmt.bufPrint(&degrees_buf, "{d}\u{00B0}", .{reading.temp_c}) catch "-";
    _ = text.drawWeighted(screen, left, @as(f32, @floatFromInt(hero.y)) + u(96), degrees, u(52), s(theme.screen_text), .semibold);
    _ = text.draw(screen, left, @as(f32, @floatFromInt(hero.y)) + u(124), weatherLabel(reading.condition), u(13), s(weatherColour(reading.condition)));
    weatherGlyph(screen, rightF(hero) - u(52), @as(f32, @floatFromInt(hero.y)) + u(58), u(26), reading.condition, s(weatherColour(reading.condition)));

    // The alert control, on the domain's real alert state.
    const armed = inter.weatherHasAlert();
    const a = weatherAlertRect();
    paint.paint(screen, &.{.{ .rounded = .{ .rect = a, .radius = @intFromFloat(u(15)), .colour = if (armed) s(theme.amber) else s(theme.screen_hairline) } }});
    const badge = if (armed) "Alerts on" else "Alert me";
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(a.x)) + (@as(f32, @floatFromInt(a.w)) - text.measureWeighted(badge, u(11), .semibold)) / 2.0, @as(f32, @floatFromInt(a.y)) + u(20), badge, u(11), s(if (armed) theme.base else theme.screen_text_muted), .semibold);

    // The hourly forecast strip: the next hours, live from the provider, each with its sky and temperature.
    var hours: [applications.weather.hourly_span]applications.weather.Reading = undefined;
    const series = inter.weatherHourly(&hours);
    if (series.len > 0) {
        const strip = card(screen, @intFromFloat(u(264)), @intFromFloat(u(96)));
        const col_w = @as(f32, @floatFromInt(strip.w)) / @as(f32, @floatFromInt(series.len));
        for (series, 0..) |r, i| {
            const cx = @as(f32, @floatFromInt(strip.x)) + col_w * (@as(f32, @floatFromInt(i)) + 0.5);
            var hbuf: [8]u8 = undefined;
            const hlabel = if (i == 0) "Now" else (std.fmt.bufPrint(&hbuf, "+{d}h", .{i}) catch "");
            text.drawCentred(screen, cx, @as(f32, @floatFromInt(strip.y)) + u(20), hlabel, u(10.5), s(theme.screen_text_muted));
            weatherGlyph(screen, cx, @as(f32, @floatFromInt(strip.y)) + u(46), u(11), r.condition, s(weatherColour(r.condition)));
            var tbuf: [8]u8 = undefined;
            const tlabel = std.fmt.bufPrint(&tbuf, "{d}\u{00B0}", .{r.temp_c}) catch "-";
            _ = text.drawWeighted(screen, cx - text.measureWeighted(tlabel, u(12.5), .semibold) / 2.0, @as(f32, @floatFromInt(strip.y)) + u(78), tlabel, u(12.5), s(theme.screen_text), .semibold);
        }
    }
    agentBand(screen, &inter.weather_agent_row);
}

/// A tap on the alert control arms severe-weather alerts for the current location. Returns true when a
/// tap landed on a control.
pub fn weatherTap(inter: *Interaction, sx: i32, sy: i32) bool {
    if (inter.weatherLocated() and inRect(weatherAlertRect(), sx, sy)) {
        if (!inter.weatherHasAlert()) inter.weatherArmAlert();
        return true;
    }
    return false;
}

/// The non-human principals the address book holds — the single source both the seed and the render
/// read, so the "also in your world" section names exactly what was seeded, with its kind.
const WorldPrincipal = struct { name: []const u8, kind: applications.contacts.Kind, label: []const u8 };
const world_principals = [_]WorldPrincipal{
    .{ .name = "Weather", .kind = .service, .label = "service" },
    .{ .name = "Living-room display", .kind = .device, .label = "device" },
    .{ .name = "Kitchen session", .kind = .session, .label = "session" },
};

/// The contact fields the grant card shows: an agent reads a contact field only if the person has
/// granted it. Name stays granted always — an agent that cannot see who a contact is cannot act.
const GrantField = struct { field: applications.contacts.Field, label: []const u8 };
const grant_fields = [_]GrantField{
    .{ .field = .name, .label = "Name" },
    .{ .field = .phone, .label = "Phone" },
    .{ .field = .email, .label = "Email" },
    .{ .field = .address, .label = "Address" },
};

fn contactPersonRect(i: usize) graphics.paint.Rect {
    return cardRect(150 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(44))) + 8), @intFromFloat(u(44)));
}

fn contactGrantRect() graphics.paint.Rect {
    return cardRect(296, @intFromFloat(u(92)));
}

fn contactWorldRect(i: usize) graphics.paint.Rect {
    return cardRect(466 + @as(i32, @intCast(i)) * (@as(i32, @intFromFloat(u(40))) + 8), @intFromFloat(u(40)));
}

/// The rectangle of the i-th field chip inside the grant card: a 2×2 grid below the card's label.
fn grantChipRect(i: usize) graphics.paint.Rect {
    const c = contactGrantRect();
    const inset = u(14);
    const gap = u(9);
    const usable = @as(f32, @floatFromInt(c.w)) - 2 * inset;
    const chip_w = (usable - gap) / 2;
    const chip_h = u(24);
    const col: f32 = @floatFromInt(i % 2);
    const row: f32 = @floatFromInt(i / 2);
    return .{
        .x = c.x + @as(i32, @intFromFloat(inset + col * (chip_w + gap))),
        .y = c.y + @as(i32, @intFromFloat(u(32) + row * (chip_h + gap))),
        .w = @intFromFloat(chip_w),
        .h = @intFromFloat(chip_h),
    };
}

fn worldColour(kind: applications.contacts.Kind) design.theme.Colour {
    return switch (kind) {
        .service => theme.amber,
        .device => theme.teal,
        .session => theme.agent,
        else => theme.human,
    };
}

/// Contacts: people, and — surfaced honestly alongside them — the non-human principals a person
/// co-inhabits their world with. The grant card makes field-scoped reads literal: the person grants,
/// field by field, what their agents may read across the book.
pub fn renderContacts(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Contacts", "People, and your world");

    var name_buf: [8][]const u8 = undefined;
    const people = inter.contactPeople(&name_buf);
    for (people, 0..) |name, i| {
        const rect = card(screen, contactPersonRect(i).y, @intFromFloat(u(44)));
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(28), name, u(14), s(theme.screen_text), .semibold);
    }

    // The grant card: the fields an agent may read, each a chip the person taps to grant or revoke.
    const grant = card(screen, contactGrantRect().y, @intFromFloat(u(88)));
    _ = text.draw(screen, @as(f32, @floatFromInt(grant.x)) + u(14), @as(f32, @floatFromInt(grant.y)) + u(20), "What agents may read", u(11), s(theme.screen_text_muted));
    for (grant_fields, 0..) |gf, i| {
        const chip = grantChipRect(i);
        const granted = inter.agentMayRead(gf.field);
        const locked = gf.field == .name;
        const fill = if (granted) s(theme.teal) else s(theme.screen_hairline);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = chip, .radius = @intFromFloat(u(13)), .colour = fill } }});
        const label_colour = if (granted) theme.base else theme.screen_text_muted;
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(chip.x)) + u(12), @as(f32, @floatFromInt(chip.y)) + u(17), gf.label, u(11), s(label_colour), .semibold);
        if (locked) {
            const dot = "\u{00B7} always";
            _ = text.draw(screen, @as(f32, @floatFromInt(chip.x + @as(i32, @intCast(chip.w)))) - u(8) - text.measure(dot, u(9)), @as(f32, @floatFromInt(chip.y)) + u(17), dot, u(9), s(theme.base));
        }
    }

    // Also in your world: the non-human principals, read from the same book, each in its kind's accent.
    _ = text.draw(screen, @floatFromInt(pad), @as(f32, @floatFromInt(contactWorldRect(0).y)) - u(10), "ALSO IN YOUR WORLD", u(10), s(theme.screen_text_muted));
    var world_buf: [8][]const u8 = undefined;
    const world = inter.contactWorld(&world_buf);
    for (world, 0..) |name, i| {
        const rect = card(screen, contactWorldRect(i).y, @intFromFloat(u(40)));
        const label = worldLabel(name);
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(20), @as(f32, @floatFromInt(rect.y)) + u(25), name, u(13), s(theme.screen_text), .semibold);
        _ = text.draw(screen, rightF(rect) - u(16) - text.measure(label.text, u(10)), @as(f32, @floatFromInt(rect.y)) + u(25), label.text, u(10), s(label.colour));
    }
    agentBand(screen, &inter.contacts_agent_row);
}

const WorldLabel = struct { text: []const u8, colour: design.theme.Colour };
fn worldLabel(name: []const u8) WorldLabel {
    for (world_principals) |p| {
        if (std.mem.eql(u8, p.name, name)) return .{ .text = p.label, .colour = worldColour(p.kind) };
    }
    return .{ .text = "principal", .colour = theme.human };
}

/// Grants or revokes an agent's read of the contact field a tap landed on. Returns true when a chip
/// was hit (the name chip is always granted and does not toggle).
pub fn contactsTap(inter: *Interaction, sx: i32, sy: i32) bool {
    for (grant_fields, 0..) |gf, i| {
        const chip = grantChipRect(i);
        if (sx >= chip.x and sx <= chip.x + @as(i32, @intCast(chip.w)) and sy >= chip.y and sy <= chip.y + @as(i32, @intCast(chip.h))) {
            inter.toggleGrant(gf.field);
            return gf.field != .name;
        }
    }
    return false;
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

const StoreItem = struct { name: []const u8, publisher: []const u8, source: applications.store.Source, acknowledged: bool, colour: theme.Colour, caps: []const u8 };

/// The store catalog the person and their agents browse. A reviewed store app installs; a sideload
/// needs the person's acknowledgement; an unacknowledged sideload is blocked. Each package declares the
/// capabilities its install grants — what the person is asked to approve, shown on a held install.
const store_catalog = [_]StoreItem{
    .{ .name = "Itinerary", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.teal, .caps = "calendar.read, location.read" },
    .{ .name = "Ledger Notes", .publisher = "Reviewed \u{00B7} signed", .source = .store, .acknowledged = false, .colour = theme.agent, .caps = "notes.read, notes.write" },
    .{ .name = "Field Tools", .publisher = "Outside source", .source = .sideload, .acknowledged = true, .colour = theme.amber, .caps = "files.read, location.read" },
    .{ .name = "Unknown Build", .publisher = "Unreviewed source", .source = .sideload, .acknowledged = false, .colour = theme.denied, .caps = "files.write, network.connect" },
};

/// The reviewed package the Store agent stages an install of (held for the person). Its declared
/// capabilities are shown on the Approve; the install arg carries the same caps to the domain, so the
/// grant the person approves is exactly what the package declared.
const store_agent_target = store_catalog[1]; // Ledger Notes — reviewed, signed
const store_agent_install_arg = "Ledger Notes|notes.read,notes.write";

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
    agentBand(screen, &inter.store_agent_row);
}

/// Installs the catalog item whose "Get" a tap landed on, through the real store domain. Returns true
/// when a tap installed something.
pub fn storeTap(inter: *Interaction, sx: i32, sy: i32) bool {
    // The agent-presence footer's Approve control: complete the held install exactly once, on the tap.
    if (inter.store_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.storeApproveInstall();
        return true;
    }
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

/// The two decision buttons on the screened incoming call, laid out for the renderer and the hit-test.
fn phoneButtonRects() [2]graphics.paint.Rect {
    const y: i32 = 236;
    const h: i32 = @intFromFloat(u(42));
    const gap: i32 = @intFromFloat(u(12));
    const half = @divTrunc(@as(i32, @intCast(width_screen())) - pad * 2 - gap, 2);
    return .{
        .{ .x = pad, .y = y, .w = @intCast(half), .h = @intCast(h) },
        .{ .x = pad + half + gap, .y = y, .w = @intCast(half), .h = @intCast(h) },
    };
}

pub fn renderPhone(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Phone", "Screened by your agents");
    agentDoorChip(screen, @floatFromInt(pad), u(96), "call.screen \u{00B7} agents screen unknown callers");

    // An incoming call from an unknown, unverified caller: the real rule screens it rather than ringing.
    const caller = applications.phone.Caller{ .known = false, .verified = false };
    const rings = applications.phone.ringsThrough(caller);

    const banner = card(screen, 150, 74);
    vector.fillDisc(screen, @as(f32, @floatFromInt(banner.x)) + u(30), @as(f32, @floatFromInt(banner.y)) + @as(f32, @floatFromInt(banner.h)) / 2.0, u(16), sa(theme.amber, 40));
    vector.fillDisc(screen, @as(f32, @floatFromInt(banner.x)) + u(30), @as(f32, @floatFromInt(banner.y)) + @as(f32, @floatFromInt(banner.h)) / 2.0, u(7), s(theme.amber));
    _ = text.draw(screen, @floatFromInt(banner.x + 60), @floatFromInt(banner.y + 32), "Unknown caller", 13, s(theme.screen_text));
    const note = if (rings) "ringing through" else "screened by your agent \u{00B7} not verified";
    _ = text.drawClipped(screen, @floatFromInt(banner.x + 60), @floatFromInt(banner.y + 52), note, 11, s(theme.screen_text_muted), rightF(banner) - u(18));

    if (inter.call_answered) |answered| {
        // Decided: the outcome in place of the buttons.
        const done: graphics.paint.Rect = .{ .x = pad, .y = 236, .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(42)) };
        const hue = if (answered) theme.teal else theme.denied;
        paint.paint(screen, &.{.{ .rounded = .{ .rect = done, .radius = theme.radius_lg, .colour = sa(hue, 34) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, @as(f32, @floatFromInt(236)) + u(26), if (answered) "Answered" else "Declined \u{00B7} sent to screening", u(12.5), s(hue));
    } else {
        const btns = phoneButtonRects();
        paint.paint(screen, &.{.{ .rounded = .{ .rect = btns[0], .radius = theme.radius_lg, .colour = s(theme.teal) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(btns[0].x)) + @as(f32, @floatFromInt(btns[0].w)) / 2.0, @as(f32, @floatFromInt(btns[0].y)) + u(26), "Answer", u(12.5), s(theme.screen_card));
        paint.paint(screen, &.{.{ .rounded = .{ .rect = btns[1], .radius = theme.radius_lg, .colour = s(theme.screen_hairline) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(btns[1].x)) + @as(f32, @floatFromInt(btns[1].w)) / 2.0, @as(f32, @floatFromInt(btns[1].y)) + u(26), "Decline", u(12.5), s(theme.screen_text));
    }

    // The recent-calls log below, showing what the agents already screened.
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(pad)) + u(2), 320, "RECENTS", u(11), s(theme.screen_label), .semibold);
    const recents = [_]Row{
        .{ .title = "Sam", .sub = "12 min \u{00B7} outgoing", .colour = theme.coral, .value = "12:04" },
        .{ .title = "Clinic", .sub = "handled by agent", .colour = theme.teal, .value = "10:40" },
        .{ .title = "Spam blocked \u{00D7}4", .sub = "you were not disturbed", .colour = theme.denied, .value = "" },
    };
    for (recents, 0..) |row, i| {
        const rect = card(screen, 334 + @as(i32, @intCast(i)) * @as(i32, @intFromFloat(u(58))), @intFromFloat(u(50)));
        vector.fillDisc(screen, @as(f32, @floatFromInt(rect.x)) + u(22), @as(f32, @floatFromInt(rect.y)) + @as(f32, @floatFromInt(rect.h)) / 2.0, u(4.5), s(row.colour));
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(40), @as(f32, @floatFromInt(rect.y)) + u(21), row.title, u(12.5), s(theme.screen_text));
        _ = text.draw(screen, @as(f32, @floatFromInt(rect.x)) + u(40), @as(f32, @floatFromInt(rect.y)) + u(37), row.sub, u(10.5), s(theme.screen_text_muted));
        if (row.value.len > 0) _ = text.draw(screen, rightF(rect) - u(16) - text.measure(row.value, u(10.5)), @as(f32, @floatFromInt(rect.y)) + u(28), row.value, u(10.5), s(theme.screen_text_muted));
    }
    agentBand(screen, &inter.phone_agent_row);
}

/// Answers or declines the screened call from a tap on its buttons. Returns true when handled.
pub fn phoneTap(inter: *Interaction, sx: i32, sy: i32) bool {
    // The agent-presence footer's Approve control: complete a held outbound call exactly once, on the tap.
    if (inter.phone_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.phoneApproveCall();
        return true;
    }
    if (inter.call_answered != null) return false;
    const btns = phoneButtonRects();
    for (btns, 0..) |b, i| {
        if (sx >= b.x and sx <= b.x + @as(i32, @intCast(b.w)) and sy >= b.y and sy <= b.y + @as(i32, @intCast(b.h))) {
            inter.call_answered = (i == 0);
            return true;
        }
    }
    return false;
}

// --- The messaging app: a conversation list, a new-conversation screen, and a thread with a compose bar.

/// The "+ New" chip at the top-right of the conversation list.
/// Whether the recipient text reads as a phone number rather than a name: only the digits and the
/// separators a number carries (`+`, `-`, space), and at least a few digits, so a name never trips it and
/// a bare number is not mistaken for a contact to look up.
fn looksLikePhone(candidate: []const u8) bool {
    var digits: usize = 0;
    for (candidate) |ch| {
        switch (ch) {
            '0'...'9' => digits += 1,
            '+', '-', ' ' => {},
            else => return false,
        }
    }
    return digits >= 3;
}

fn msgBeginRect() graphics.paint.Rect {
    const w_px: i32 = @intFromFloat(u(58));
    return .{ .x = @as(i32, @intCast(width_screen())) - pad - w_px, .y = @intFromFloat(u(50)), .w = @intCast(w_px), .h = @intFromFloat(u(30)) };
}

/// The card for the i-th conversation row in the list.
fn msgRowRect(i: usize) graphics.paint.Rect {
    const h = u(56);
    const gap = u(10);
    const y = u(112) + @as(f32, @floatFromInt(i)) * (h + gap);
    return .{ .x = pad, .y = @intFromFloat(y), .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(h) };
}

/// The card for the i-th looked-up contact on the new-conversation screen, below the recipient field.
fn msgContactRowRect(i: usize) graphics.paint.Rect {
    const h = u(46);
    const gap = u(8);
    const y = u(238) + @as(f32, @floatFromInt(i)) * (h + gap);
    return .{ .x = pad, .y = @intFromFloat(y), .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(h) };
}

/// The most contact rows the new-conversation screen shows at once — enough to pick from without
/// running the list under the app frame.
const msg_contact_rows_max: usize = 6;

/// The compose bar's field and its send button, at the foot of the thread and the new-conversation
/// screen. `send` is the trailing button; `field` is the text area to its left.
fn msgComposeBar() struct { field: graphics.paint.Rect, send: graphics.paint.Rect } {
    const bar_h = u(42);
    const y: i32 = @as(i32, @intCast(phone.screen_h)) - @as(i32, @intFromFloat(u(58)));
    const send_w = u(64);
    const full = @as(f32, @floatFromInt(width_screen() - @as(u32, @intCast(pad)) * 2));
    const field_w = full - send_w - u(8);
    return .{
        .field = .{ .x = pad, .y = y, .w = @intFromFloat(field_w), .h = @intFromFloat(bar_h) },
        .send = .{ .x = pad + @as(i32, @intFromFloat(field_w + u(8))), .y = y, .w = @intFromFloat(send_w), .h = @intFromFloat(bar_h) },
    };
}

fn inRect(r: graphics.paint.Rect, sx: i32, sy: i32) bool {
    return sx >= r.x and sx <= r.x + @as(i32, @intCast(r.w)) and sy >= r.y and sy <= r.y + @as(i32, @intCast(r.h));
}

/// Draws one chat bubble at `top`, returning the y below it. The person's own messages sit right in the
/// accent; a correspondent's sit left in a light card.
fn chatBubble(screen: *Framebuffer, top: f32, body: []const u8, mine: bool) f32 {
    const size = u(13);
    const max_w = @as(f32, @floatFromInt(width_screen())) * 0.72;
    const tw = @min(text.measure(body, size), max_w);
    const bw = tw + u(26);
    const bh = u(36);
    const x = if (mine) @as(f32, @floatFromInt(width_screen())) - @as(f32, @floatFromInt(pad)) - bw else @as(f32, @floatFromInt(pad));
    const fill = if (mine) s(theme.agent) else s(theme.screen_card);
    const ink = if (mine) s(theme.screen_card) else s(theme.screen_text);
    if (!mine) paintCard(screen, .{ .x = @intFromFloat(x), .y = @intFromFloat(top), .w = @intFromFloat(bw), .h = @intFromFloat(bh) });
    if (mine) paint.paint(screen, &.{.{ .rounded = .{ .rect = .{ .x = @intFromFloat(x), .y = @intFromFloat(top), .w = @intFromFloat(bw), .h = @intFromFloat(bh) }, .radius = @intFromFloat(u(15)), .colour = fill } }});
    _ = text.drawClipped(screen, x + u(13), top + u(23), body, size, ink, x + bw - u(10));
    return top + bh + u(9);
}

/// Draws a rounded text field with its content (or a muted placeholder) and a caret when it is the
/// active field.
fn textField(screen: *Framebuffer, r: graphics.paint.Rect, content: []const u8, placeholder: []const u8, active: bool) void {
    paint.paint(screen, &.{.{ .rounded = .{ .rect = r, .radius = @intFromFloat(u(12)), .colour = s(theme.screen_card) } }});
    const tx = @as(f32, @floatFromInt(r.x)) + u(12);
    const ty = @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) * 0.62;
    if (content.len == 0) {
        _ = text.drawClipped(screen, tx, ty, placeholder, u(12.5), s(theme.screen_text_muted), @as(f32, @floatFromInt(r.x + @as(i32, @intCast(r.w)))) - u(10));
    } else {
        const end = text.drawClipped(screen, tx, ty, content, u(13), s(theme.screen_text), @as(f32, @floatFromInt(r.x + @as(i32, @intCast(r.w)))) - u(14));
        if (active) _ = text.draw(screen, end + u(1), ty, "\u{2502}", u(13), s(theme.agent));
    }
}

/// The messaging app. Three screens sharing this surface: the conversation list, the new-conversation
/// screen, and an open thread with a compose bar. Nothing is pre-filled — a thread holds only what has
/// been sent in it.
pub fn renderMessages(screen: *Framebuffer, inter: *const Interaction) void {
    if (inter.open_conv) |ci| {
        // An open thread: the correspondent as title, the messages exchanged, and the compose bar.
        header(screen, inter.msgConvName(ci), "on device");
        var y: f32 = u(112);
        const n = inter.msgConvMessages(ci);
        if (n == 0) {
            text.drawCentred(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, u(210), "No messages yet \u{00B7} say hello", u(12), s(theme.screen_text_muted));
        } else {
            var i: usize = 0;
            while (i < n) : (i += 1) y = chatBubble(screen, y, inter.msgBody(ci, i), inter.msgMine(ci, i));
        }
        const bar = msgComposeBar();
        textField(screen, bar.field, inter.msgComposeText(), "Message", true);
        paint.paint(screen, &.{.{ .rounded = .{ .rect = bar.send, .radius = @intFromFloat(u(12)), .colour = s(theme.agent) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(bar.send.x)) + @as(f32, @floatFromInt(bar.send.w)) / 2.0, @as(f32, @floatFromInt(bar.send.y)) + u(27), "Send", u(12.5), s(theme.screen_card));
        return;
    }
    if (inter.composing_new) {
        // The new-conversation screen: look up a real contact and tap it, or type a name or phone number
        // and Start. The field is one door; the contact list below it is the other.
        header(screen, "New message", "Who do you want to message?");
        const field: graphics.paint.Rect = .{ .x = pad, .y = @intFromFloat(u(120)), .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(44)) };
        _ = text.draw(screen, @floatFromInt(pad), u(112), "To", u(11), s(theme.screen_text_muted));
        textField(screen, field, inter.msgComposeText(), "Name or phone number", true);
        const start: graphics.paint.Rect = .{ .x = pad, .y = @intFromFloat(u(180)), .w = @intFromFloat(u(96)), .h = @intFromFloat(u(38)) };
        paint.paint(screen, &.{.{ .rounded = .{ .rect = start, .radius = @intFromFloat(u(19)), .colour = s(theme.agent) } }});
        text.drawCentred(screen, @as(f32, @floatFromInt(start.x)) + @as(f32, @floatFromInt(start.w)) / 2.0, @as(f32, @floatFromInt(start.y)) + u(25), "Start", u(12.5), s(theme.screen_card));
        // The contacts read from the real book, filtered by what has been typed — the lookup door.
        var buf: [msg_contact_rows_max][]const u8 = undefined;
        const candidates = inter.msgContactCandidates(&buf);
        if (candidates.len > 0) {
            _ = text.draw(screen, @floatFromInt(pad), u(228), "From your contacts", u(11), s(theme.screen_text_muted));
            for (candidates, 0..) |name, i| {
                const rect = msgContactRowRect(i);
                paintCard(screen, rect);
                _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(16), @as(f32, @floatFromInt(rect.y)) + u(28), name, u(14), s(theme.screen_text), .semibold);
            }
        } else if (looksLikePhone(inter.msgComposeText())) {
            _ = text.draw(screen, @floatFromInt(pad), u(232), "Tap Start to message this number", u(11.5), s(theme.screen_text_muted));
        }
        return;
    }
    // The conversation list.
    header(screen, "Messages", "On device, end to end");
    const nb = msgBeginRect();
    paint.paint(screen, &.{.{ .rounded = .{ .rect = nb, .radius = @intFromFloat(u(15)), .colour = s(theme.agent) } }});
    text.drawCentred(screen, @as(f32, @floatFromInt(nb.x)) + @as(f32, @floatFromInt(nb.w)) / 2.0, @as(f32, @floatFromInt(nb.y)) + u(20), "New", u(12), s(theme.screen_card));
    if (inter.conv_count == 0) {
        text.drawCentred(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, u(240), "No conversations yet", u(13.5), s(theme.screen_text));
        text.drawCentred(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, u(262), "Tap New to start one", u(11.5), s(theme.screen_text_muted));
    } else {
        var i: usize = 0;
        while (i < inter.conv_count) : (i += 1) {
            const rect = msgRowRect(i);
            paintCard(screen, rect);
            _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rect.x)) + u(16), @as(f32, @floatFromInt(rect.y)) + u(23), inter.msgConvName(i), u(14.5), s(theme.screen_text), .semibold);
            const mc = inter.msgConvMessages(i);
            const preview = if (mc == 0) "No messages yet" else inter.msgBody(i, mc - 1);
            _ = text.drawClipped(screen, @as(f32, @floatFromInt(rect.x)) + u(16), @as(f32, @floatFromInt(rect.y)) + u(43), preview, u(11.5), s(theme.screen_text_muted), rightF(rect) - u(14));
        }
    }
    // The agent-presence band: the last real thing the messages agent did, derived from the domain.
    agentBand(screen, &inter.messages_agent_row);
}

/// Handles a tap on the messaging surface. Returns true when it acted (so the shell does not navigate
/// away). The back chevron closes an open thread or the new-conversation screen; at the list level it
/// falls through so the shell takes it home.
pub fn messagesTap(inter: *Interaction, sx: i32, sy: i32) bool {
    const back = sx < 64 and sy < 96;
    if (inter.open_conv != null) {
        if (back) {
            inter.msgCloseThread();
            return true;
        }
        if (inRect(msgComposeBar().send, sx, sy)) {
            inter.msgSend();
            return true;
        }
        return false;
    }
    if (inter.composing_new) {
        if (back) {
            inter.msgCancelConversation();
            return true;
        }
        const start: graphics.paint.Rect = .{ .x = pad, .y = @intFromFloat(u(180)), .w = @intFromFloat(u(96)), .h = @intFromFloat(u(38)) };
        if (inRect(start, sx, sy)) {
            inter.msgConfirmConversation();
            return true;
        }
        // A tap on a looked-up contact starts the conversation with that real person.
        var buf: [msg_contact_rows_max][]const u8 = undefined;
        const candidates = inter.msgContactCandidates(&buf);
        for (candidates, 0..) |name, i| {
            if (inRect(msgContactRowRect(i), sx, sy)) {
                inter.msgStartContact(name);
                return true;
            }
        }
        return false;
    }
    // The agent-presence band's Approve control: complete the held send exactly once, on the person's tap.
    if (inter.messages_agent_row.control == .approve and inRect(agentBandActionRect(), sx, sy)) {
        inter.messagesApproveSend();
        return true;
    }
    if (inRect(msgBeginRect(), sx, sy)) {
        inter.msgBeginConversation();
        return true;
    }
    var i: usize = 0;
    while (i < inter.conv_count) : (i += 1) {
        if (inRect(msgRowRect(i), sx, sy)) {
            inter.msgOpen(i);
            return true;
        }
    }
    return false;
}

// The camera's zoom steps and its capture modes. PHOTO and VIDEO both capture through the domain; Lens
// and Describe are the agent-facing readings of the scene. The selected mode is stored on the
// interaction, and both the render and the hit-test read this one list, so they cannot drift.
const camera_zooms = [_][]const u8{ ".5", "1\u{00D7}", "2", "5" };
const CameraUiMode = struct { label: []const u8, mode: applications.camera.Mode, video: bool };
const camera_ui_modes = [_]CameraUiMode{
    .{ .label = "PHOTO", .mode = .capture, .video = false },
    .{ .label = "VIDEO", .mode = .capture, .video = true },
    .{ .label = "LENS", .mode = .lens, .video = false },
    .{ .label = "DESCRIBE", .mode = .describe, .video = false },
};

const camera_dark = graphics.framebuffer.Rgba{ .r = 22, .g = 22, .b = 28, .a = 255 };
const camera_white = graphics.framebuffer.Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
const camera_record = graphics.framebuffer.Rgba{ .r = 235, .g = 66, .b = 54, .a = 255 };
fn cameraWhiteA(alpha: u8) graphics.framebuffer.Rgba {
    return .{ .r = 255, .g = 255, .b = 255, .a = alpha };
}

/// The dark viewfinder rectangle the whole camera is composed over.
fn cameraViewfinder() graphics.paint.Rect {
    return .{ .x = pad, .y = @intFromFloat(u(96)), .w = @intCast(width_screen() - @as(u32, @intCast(pad)) * 2), .h = @intFromFloat(u(566)) };
}

/// The shutter's centre and radius, at the foot of the viewfinder.
fn cameraShutter() struct { cx: f32, cy: f32, r: f32 } {
    const vf = cameraViewfinder();
    return .{ .cx = @as(f32, @floatFromInt(width_screen())) / 2.0, .cy = @as(f32, @floatFromInt(rectBottom(vf))) - u(56), .r = u(32) };
}

/// A zoom pill's circle centre, in a group centred above the shutter.
fn cameraZoomCentre(i: usize) struct { cx: f32, cy: f32, r: f32 } {
    const r = u(17);
    const gap = u(6);
    const step = r * 2 + gap;
    const group_w = step * @as(f32, @floatFromInt(camera_zooms.len)) - gap;
    const start = @as(f32, @floatFromInt(width_screen())) / 2.0 - group_w / 2.0 + r;
    return .{ .cx = start + @as(f32, @floatFromInt(i)) * step, .cy = cameraShutter().cy - u(58), .r = r };
}

/// The mode label slots run in equal columns across the foot of the viewfinder.
fn cameraModeSlot(i: usize) struct { cx: f32, y: f32, w: f32 } {
    const vf = cameraViewfinder();
    const w = @as(f32, @floatFromInt(vf.w)) / @as(f32, @floatFromInt(camera_ui_modes.len));
    return .{ .cx = @as(f32, @floatFromInt(vf.x)) + w * (@as(f32, @floatFromInt(i)) + 0.5), .y = @as(f32, @floatFromInt(rectBottom(vf))) - u(14), .w = w };
}

fn cameraModeSelected(inter: *const Interaction, m: CameraUiMode) bool {
    return inter.camera_mode == m.mode and (m.mode != .capture or inter.camera_video == m.video);
}

pub fn renderCamera(screen: *Framebuffer, inter: *const Interaction) void {
    header(screen, "Camera", "Only you capture; agents may see");
    const vf = cameraViewfinder();

    // The viewfinder: a dark field with a soft centre glow, a rule-of-thirds grid, and a focus reticle —
    // the framing a camera shows before the shutter. There is no invented scene behind it.
    paint.paint(screen, &.{.{ .rounded = .{ .rect = vf, .radius = theme.radius_xl, .colour = camera_dark } }});
    vector.fillGlow(screen, @as(f32, @floatFromInt(width_screen())) / 2.0, @as(f32, @floatFromInt(vf.y)) + @as(f32, @floatFromInt(vf.h)) * 0.4, u(150), cameraWhiteA(255), 18);
    var t: usize = 1;
    while (t < 3) : (t += 1) {
        const fx = @as(f32, @floatFromInt(vf.x)) + @as(f32, @floatFromInt(vf.w)) * @as(f32, @floatFromInt(t)) / 3.0;
        const fy = @as(f32, @floatFromInt(vf.y)) + @as(f32, @floatFromInt(vf.h)) * @as(f32, @floatFromInt(t)) / 3.0;
        vector.strokePolyline(screen, &.{ .{ .x = fx, .y = @floatFromInt(vf.y) }, .{ .x = fx, .y = @floatFromInt(rectBottom(vf)) } }, u(0.8), cameraWhiteA(28), false);
        vector.strokePolyline(screen, &.{ .{ .x = @floatFromInt(vf.x), .y = fy }, .{ .x = @floatFromInt(rightI(vf)), .y = fy } }, u(0.8), cameraWhiteA(28), false);
    }
    const rx = @as(f32, @floatFromInt(width_screen())) / 2.0;
    const ry = @as(f32, @floatFromInt(vf.y)) + @as(f32, @floatFromInt(vf.h)) * 0.4;
    const rs = u(18);
    vector.strokePolyline(screen, &.{ .{ .x = rx - rs, .y = ry - rs }, .{ .x = rx + rs, .y = ry - rs }, .{ .x = rx + rs, .y = ry + rs }, .{ .x = rx - rs, .y = ry + rs } }, u(1.4), cameraWhiteA(150), true);

    // A live capture indicator top-left of the viewfinder — lit, since capture is allowed here.
    vector.fillDisc(screen, @as(f32, @floatFromInt(vf.x)) + u(20), @as(f32, @floatFromInt(vf.y)) + u(22), u(4), camera_record);
    _ = text.drawWeighted(screen, @as(f32, @floatFromInt(vf.x)) + u(30), @as(f32, @floatFromInt(vf.y)) + u(26), if (inter.camera_video) "REC" else "LIVE", u(10), cameraWhiteA(220), .semibold);

    // Where a real bound camera is delivering, the frame's own resolution is stated top-right, read from
    // the seam — the honest proof a real device is behind the viewfinder. On a host without a camera
    // there is no frame, so nothing is shown here and nothing is fabricated.
    if (inter.cameraLatestFrame()) |frame| {
        var res_buf: [24]u8 = undefined;
        const res = std.fmt.bufPrint(&res_buf, "{d}\u{00D7}{d}", .{ frame.width, frame.height }) catch "";
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(rightI(vf))) - u(20) - text.measureWeighted(res, u(10), .semibold), @as(f32, @floatFromInt(vf.y)) + u(26), res, u(10), cameraWhiteA(200), .semibold);
    }

    // Lens and Describe read the scene through the on-device vision mind; with none bound the reading is
    // honestly absent rather than invented.
    if (inter.camera_mode == .lens or inter.camera_mode == .describe) {
        const line = if (inter.camera_mode == .lens) "Lens \u{00B7} vision offline, no reading" else "Describe \u{00B7} vision offline, no reading";
        text.drawCentred(screen, rx, ry - u(40), line, u(11.5), cameraWhiteA(200));
    }

    // The zoom selector: the chosen step is filled and amber, the rest are faint discs.
    for (camera_zooms, 0..) |z, i| {
        const c = cameraZoomCentre(i);
        const selected = i == inter.camera_zoom;
        vector.fillDisc(screen, c.cx, c.cy, c.r, cameraWhiteA(if (selected) 235 else 40));
        const ink = if (selected) s(theme.base) else camera_white;
        _ = text.drawWeighted(screen, c.cx - text.measureWeighted(z, u(11), .semibold) / 2.0, c.cy + u(4), z, u(11), ink, .semibold);
    }

    // The shutter: a white ring around a fill — white for a photo, red for video.
    const sh = cameraShutter();
    vector.strokeCircle(screen, sh.cx, sh.cy, sh.r, u(4), camera_white);
    vector.fillDisc(screen, sh.cx, sh.cy, sh.r - u(7), if (inter.camera_video) camera_record else camera_white);

    // The most recent shot, bottom-left: a thumbnail carrying the count captured this session.
    if (inter.cameraShots() > 0) {
        const thumb: graphics.paint.Rect = .{ .x = vf.x + @as(i32, @intFromFloat(u(18))), .y = @as(i32, @intFromFloat(sh.cy)) - @as(i32, @intFromFloat(u(20))), .w = @intFromFloat(u(40)), .h = @intFromFloat(u(40)) };
        paint.paint(screen, &.{.{ .rounded = .{ .rect = thumb, .radius = @intFromFloat(u(9)), .colour = cameraWhiteA(210) } }});
        var cbuf: [8]u8 = undefined;
        const clabel = std.fmt.bufPrint(&cbuf, "{d}", .{inter.cameraShots()}) catch "";
        _ = text.drawWeighted(screen, @as(f32, @floatFromInt(thumb.x)) + (@as(f32, @floatFromInt(thumb.w)) - text.measureWeighted(clabel, u(14), .semibold)) / 2.0, @as(f32, @floatFromInt(thumb.y)) + u(26), clabel, u(14), s(theme.screen_text), .semibold);
    }

    // The mode strip: PHOTO / VIDEO / LENS / DESCRIBE, the selected one amber.
    for (camera_ui_modes, 0..) |m, i| {
        const slot = cameraModeSlot(i);
        const selected = cameraModeSelected(inter, m);
        const ink = if (selected) s(theme.amber) else cameraWhiteA(170);
        _ = text.drawWeighted(screen, slot.cx - text.measureWeighted(m.label, u(11), .semibold) / 2.0, slot.y, m.label, u(11), ink, .semibold);
    }
}

/// Handles a tap on the camera: the shutter captures for real, a zoom pill sets the zoom, and a mode
/// label switches mode. Returns true when a control was hit.
pub fn cameraTap(inter: *Interaction, sx: i32, sy: i32) bool {
    const fx = @as(f32, @floatFromInt(sx));
    const fy = @as(f32, @floatFromInt(sy));
    // The shutter.
    const sh = cameraShutter();
    if ((fx - sh.cx) * (fx - sh.cx) + (fy - sh.cy) * (fy - sh.cy) <= sh.r * sh.r) {
        _ = inter.cameraCapture();
        return true;
    }
    // A zoom pill.
    for (camera_zooms, 0..) |_, i| {
        const c = cameraZoomCentre(i);
        if ((fx - c.cx) * (fx - c.cx) + (fy - c.cy) * (fy - c.cy) <= c.r * c.r) {
            inter.camera_zoom = i;
            return true;
        }
    }
    // A mode label: the strip's band across the foot of the viewfinder.
    const strip_y = cameraModeSlot(0).y;
    if (fy >= strip_y - u(20) and fy <= strip_y + u(8)) {
        const vf = cameraViewfinder();
        const col_w = @as(f32, @floatFromInt(vf.w)) / @as(f32, @floatFromInt(camera_ui_modes.len));
        const idx: usize = @intFromFloat(@max(0.0, (fx - @as(f32, @floatFromInt(vf.x))) / col_w));
        if (idx < camera_ui_modes.len) {
            inter.camera_mode = camera_ui_modes[idx].mode;
            inter.camera_video = camera_ui_modes[idx].video;
            return true;
        }
    }
    return false;
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

test "messaging starts empty, and a started conversation carries the messages sent in it" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The app opens with no conversations — nothing is pre-filled.
    try testing.expectEqual(@as(usize, 0), inter.conv_count);
    // Tapping New opens the new-conversation screen; typing a name and Start creates and opens it.
    try testing.expect(messagesTap(&inter, msgBeginRect().x + 4, msgBeginRect().y + 4));
    try testing.expect(inter.composing_new);
    for ("Alex") |ch| inter.msgComposeType(ch);
    const start: graphics.paint.Rect = .{ .x = pad, .y = @intFromFloat(u(180)), .w = @intFromFloat(u(96)), .h = @intFromFloat(u(38)) };
    try testing.expect(messagesTap(&inter, start.x + 4, start.y + 4));
    try testing.expectEqual(@as(usize, 1), inter.conv_count);
    try testing.expectEqualStrings("Alex", inter.msgConvName(0));
    // The thread is empty until something is sent in it.
    try testing.expectEqual(@as(usize, 0), inter.msgConvMessages(0));
    // Typing a message and tapping Send records it in the thread through the domain.
    for ("Hi there") |ch| inter.msgComposeType(ch);
    try testing.expect(messagesTap(&inter, msgComposeBar().send.x + 4, msgComposeBar().send.y + 4));
    try testing.expectEqual(@as(usize, 1), inter.msgConvMessages(0));
    try testing.expectEqualStrings("Hi there", inter.msgBody(0, 0));
    try testing.expect(inter.msgMine(0, 0));
    try testing.expectEqual(@as(usize, 1), inter.msgs_state.sent());
    // The back chevron closes the thread to the list.
    try testing.expect(messagesTap(&inter, 10, 10));
    try testing.expectEqual(@as(?usize, null), inter.open_conv);
}

test "a looked-up contact starts a conversation with the real person from the book" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // On the new-conversation screen, typing narrows the book to a real contact the person can tap.
    try testing.expect(messagesTap(&inter, msgBeginRect().x + 4, msgBeginRect().y + 4));
    for ("Ana") |ch| inter.msgComposeType(ch);
    var buf: [msg_contact_rows_max][]const u8 = undefined;
    const candidates = inter.msgContactCandidates(&buf);
    try testing.expectEqual(@as(usize, 1), candidates.len);
    try testing.expectEqualStrings("Ana Silva", candidates[0]);
    // Tapping the contact starts the conversation with that real person, not the half-typed text.
    const row = msgContactRowRect(0);
    try testing.expect(messagesTap(&inter, row.x + 8, row.y + 8));
    try testing.expect(!inter.composing_new);
    try testing.expectEqual(@as(usize, 1), inter.conv_count);
    try testing.expectEqualStrings("Ana Silva", inter.msgConvName(0));
}

test "a typed name resolves to the real contact; a manual phone number starts its own conversation" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // A name typed into the field and confirmed resolves against the real book to the full contact.
    try testing.expect(messagesTap(&inter, msgBeginRect().x + 4, msgBeginRect().y + 4));
    for ("marco") |ch| inter.msgComposeType(ch);
    inter.msgConfirmConversation();
    try testing.expectEqual(@as(usize, 1), inter.conv_count);
    try testing.expectEqualStrings("Marco Dias", inter.msgConvName(0));
    // Back to the list, then start again — a manual phone number is recognised as a number, not a name.
    inter.msgCloseThread();
    try testing.expect(messagesTap(&inter, msgBeginRect().x + 4, msgBeginRect().y + 4));
    for ("+1 555-0137") |ch| inter.msgComposeType(ch);
    try testing.expect(looksLikePhone(inter.msgComposeText()));
    var phone_buf: [msg_contact_rows_max][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), inter.msgContactCandidates(&phone_buf).len);
    inter.msgConfirmConversation();
    try testing.expectEqual(@as(usize, 2), inter.conv_count);
    try testing.expectEqualStrings("+1 555-0137", inter.msgConvName(1));
}

test "the messages agent drafts as a notify and holds the send until the person approves it once" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The draft is a local notify: it runs through the real domain and is not held.
    inter.messagesAgentDraft();
    try testing.expect(inter.messages_agent_row.status == .executed);
    try testing.expect(inter.messages_agent_row.control == .none);
    try testing.expectEqualStrings("On my way, be there in ten", inter.msgs_state.draftedBody().?);
    // The send reaches another person, so it is held with an Approve control — nothing is sent yet.
    inter.messagesAgentStageSend();
    try testing.expect(inter.messages_agent_row.status == .held);
    try testing.expect(inter.messages_agent_row.control == .approve);
    try testing.expectEqual(@as(usize, 0), inter.msgs_state.sent());
    // Approving runs the exact keyed send once; a second approval tap does not send again.
    try testing.expect(messagesTap(&inter, agentBandActionRect().x + 4, agentBandActionRect().y + 4));
    try testing.expectEqual(@as(usize, 1), inter.msgs_state.sent());
    inter.messagesApproveSend();
    try testing.expectEqual(@as(usize, 1), inter.msgs_state.sent());
    try testing.expect(inter.messages_agent_row.status == .executed);
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

test "the phone screens an unknown caller and the person decides" {
    // The real rule screens an unknown, unverified caller and rings a known one through.
    try testing.expect(!applications.phone.ringsThrough(.{ .known = false, .verified = false }));
    try testing.expect(applications.phone.ringsThrough(.{ .known = true, .verified = false }));
    // The person answers the screened call from its button; the decision is recorded.
    var inter = Interaction{};
    try testing.expect(inter.call_answered == null);
    const btns = phoneButtonRects();
    try testing.expect(phoneTap(&inter, btns[0].x + 10, btns[0].y + 10));
    try testing.expect(inter.call_answered.? == true);
}

test "the camera captures through the domain and switches mode and zoom on tap" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // It opens ready to take a photo, with nothing captured yet.
    try testing.expect(inter.camera_mode == .capture);
    try testing.expectEqual(@as(usize, 0), inter.cameraShots());
    // A tap on the shutter captures a real shot through the domain.
    const sh = cameraShutter();
    try testing.expect(cameraTap(&inter, @intFromFloat(sh.cx), @intFromFloat(sh.cy)));
    try testing.expectEqual(@as(usize, 1), inter.cameraShots());
    // A tap on a zoom pill selects it.
    const z = cameraZoomCentre(3);
    try testing.expect(cameraTap(&inter, @intFromFloat(z.cx), @intFromFloat(z.cy)));
    try testing.expectEqual(@as(usize, 3), inter.camera_zoom);
    // A tap on the LENS slot switches mode; capture is still gated by the domain's own rule.
    const slot = cameraModeSlot(2);
    try testing.expect(cameraTap(&inter, @intFromFloat(slot.cx), @intFromFloat(slot.y - u(6))));
    try testing.expect(inter.camera_mode == .lens);
    try testing.expect(applications.camera.mayCapture(true, true));
    try testing.expect(!applications.camera.mayCapture(false, true));
}

// A streaming camera stub standing for a real bound backend, so the capture path's seam wiring is
// observable without a device. It runs a session, reports the indicator from the session's own state
// (never a flag the shell sets), and delivers a frame only while running — the structural rule the seam
// holds. Pure Zig, so this smoke test runs green on every host, including a device-less CI runner.
const CameraStub = struct {
    running: bool = false,
    const one = [_]camera_seam.Camera{.{ .id = 7, .name = "Stub camera" }};
    fn cameras(_: *anyopaque, out: []camera_seam.Camera) []const camera_seam.Camera {
        const n = @min(out.len, one.len);
        @memcpy(out[0..n], one[0..n]);
        return out[0..n];
    }
    fn hasCamera(_: *anyopaque, id: u32) bool {
        return id == one[0].id;
    }
    fn startStream(context: *anyopaque, id: u32) camera_seam.StartError!void {
        const self: *CameraStub = @ptrCast(@alignCast(context));
        if (id != one[0].id) return camera_seam.StartError.NoSuchCamera;
        self.running = true;
    }
    fn stopStream(context: *anyopaque) void {
        const self: *CameraStub = @ptrCast(@alignCast(context));
        self.running = false;
    }
    fn streamLive(context: *anyopaque) bool {
        const self: *CameraStub = @ptrCast(@alignCast(context));
        return self.running;
    }
    fn latestFrame(context: *anyopaque, out: *camera_seam.Frame) bool {
        const self: *CameraStub = @ptrCast(@alignCast(context));
        if (!self.running) return false; // no frame with the indicator dark — the seam's structural rule
        out.* = .{ .width = 1280, .height = 720, .format = .nv12 };
        return true;
    }
    fn backend(self: *CameraStub) camera_seam.Backend {
        return .{
            .context = self,
            .cameras_fn = cameras,
            .has_camera_fn = hasCamera,
            .start_stream_fn = startStream,
            .stop_stream_fn = stopStream,
            .stream_live_fn = streamLive,
            .latest_frame_fn = latestFrame,
        };
    }
};

test "with no camera bound the shutter still records the person's shot, indicator honestly dark" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // No backend is bound (the headless renderer, CI): the seam is dark, so the indicator is off and no
    // device frame is available — nothing is fabricated.
    try testing.expect(!inter.cameraIndicatorLit());
    try testing.expectEqual(@as(?camera_seam.Frame, null), inter.cameraLatestFrame());
    // The person's own shutter press is their foreground act, so a real shot is still recorded.
    try testing.expect(inter.cameraCapture());
    try testing.expectEqual(@as(usize, 1), inter.cameraShots());
    try testing.expectEqual(@as(?camera_seam.Frame, null), inter.camera_frame); // no device frame taken
}

test "a bound camera lights the indicator at the source and the shutter takes a real frame" {
    var stub = CameraStub{};
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    inter.bindCameraBackend(stub.backend());

    // Binding lights nothing: enumeration alone never starts a session, so the indicator stays dark and
    // no frame is delivered — the camera is not activated by wiring the shell.
    try testing.expect(!inter.cameraIndicatorLit());
    try testing.expectEqual(@as(?camera_seam.Frame, null), inter.cameraLatestFrame());

    // Opening the viewfinder starts a real session: the indicator lights, read from the source itself,
    // and a frame becomes available — a frame cannot be delivered with the light off.
    inter.cameraViewfinderOpen();
    try testing.expect(inter.cameraIndicatorLit());
    const live_frame = inter.cameraLatestFrame() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 1280), live_frame.width);

    // The shutter takes that device's real frame while the indicator is lit, and records the shot.
    try testing.expect(inter.cameraCapture());
    try testing.expectEqual(@as(usize, 1), inter.cameraShots());
    const taken = inter.camera_frame orelse return error.TestUnexpectedResult;
    try testing.expectEqual(camera_seam.PixelFormat.nv12, taken.format);

    // Closing the viewfinder tears the session down: the indicator follows the source off and frames stop.
    inter.cameraViewfinderClose();
    try testing.expect(!inter.cameraIndicatorLit());
    try testing.expectEqual(@as(?camera_seam.Frame, null), inter.cameraLatestFrame());
}

test "browser opens a page, bookmarks it, and grants the site a permission through the domain" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // It lands on the home page; opening another page changes the current link.
    try testing.expectEqual(@as(usize, 0), browserLinkIndex(&inter));
    const second = browserLinkRect(1);
    try testing.expect(browserTap(&inter, second.x + 20, second.y + 10));
    try testing.expectEqual(@as(usize, 1), browserLinkIndex(&inter));
    // Bookmarking the current page marks it through the real domain.
    const link = browser_links[1];
    try testing.expect(!inter.browserBookmarked(link.url));
    const bm = browserBookmarkRect();
    try testing.expect(browserTap(&inter, bm.x + 5, bm.y + 5));
    try testing.expect(inter.browserBookmarked(link.url));
    // Granting the current site a permission marks its whole origin.
    try testing.expect(!inter.siteHas(link.url, .location));
    const loc_chip = browserPermRect(0);
    try testing.expect(browserTap(&inter, loc_chip.x + 5, loc_chip.y + 5));
    try testing.expect(inter.siteHas(link.url, .location));
}

test "calendar books focus on a free hour and the day recomputes its blocks" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Seeded: 9 and 10 busy (one block), 14 busy (another) — two focus blocks to start.
    try testing.expect(inter.slotBusy(9));
    try testing.expect(!inter.slotBusy(11));
    try testing.expectEqual(@as(usize, 2), inter.focusBlockCount());
    // Booking 11 (free) fills it; a tap on a busy hour changes nothing.
    const free_row = calHourRect(11 - cal_first_hour);
    try testing.expect(calendarTap(&inter, free_row.x + 80, free_row.y + 8));
    try testing.expect(inter.slotBusy(11));
    const busy_row = calHourRect(9 - cal_first_hour);
    try testing.expect(!calendarTap(&inter, busy_row.x + 80, busy_row.y + 8));
    // 11 now bridges nothing new (10 was busy, 11 now busy) so 9-11 is one block, 14 another: still 2.
    try testing.expectEqual(@as(usize, 2), inter.focusBlockCount());
}

test "files opens an in-grant entry and the grant refuses one that escapes it" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Nothing opened yet.
    try testing.expect(inter.fileOpenedState(0) == null);
    // An in-grant file opens through the real domain.
    const in_grant = fileRowRect(0);
    try testing.expect(filesTap(&inter, in_grant.x + 20, in_grant.y + 10));
    try testing.expectEqual(@as(?bool, true), inter.fileOpenedState(0));
    // The escaping entry (the last) is refused before the tree is touched.
    const escaping = fileRowRect(file_entries.len - 1);
    try testing.expect(filesTap(&inter, escaping.x + 20, escaping.y + 10));
    try testing.expectEqual(@as(?bool, false), inter.fileOpenedState(file_entries.len - 1));
    // Opening the escaping one moved the "opened" marker off row 0.
    try testing.expect(inter.fileOpenedState(0) == null);
}

test "contacts reads people and principals from the book and grants fields per the domain" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The book, read live: two people and three non-human co-inhabitants.
    var buf: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), inter.contactPeople(&buf).len);
    try testing.expectEqual(@as(usize, 3), inter.contactWorld(&buf).len);
    // Name and phone start granted; email does not. A tap on the email chip grants it.
    try testing.expect(inter.agentMayRead(.name));
    try testing.expect(!inter.agentMayRead(.email));
    const email_chip = grantChipRect(2);
    try testing.expect(contactsTap(&inter, email_chip.x + 4, email_chip.y + 4));
    try testing.expect(inter.agentMayRead(.email));
    // The name chip never revokes — a contact an agent cannot name it cannot act on.
    const name_chip = grantChipRect(0);
    try testing.expect(!contactsTap(&inter, name_chip.x + 4, name_chip.y + 4));
    try testing.expect(inter.agentMayRead(.name));
}

test "weather is unlocated with no live lookup, and reads back an injected current reading" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // With no network lookup (the offline default) the app is honestly unlocated — no fabricated city.
    try testing.expect(!inter.weatherLocated());
    try testing.expect(inter.weatherReading() == null);
    // Simulate what weatherRefresh does with a live provider: set the current city and inject a real
    // reading and hourly series into the domain. The surface then reads them back.
    const city = "Seattle";
    @memcpy(inter.weather_city[0..city.len], city);
    inter.weather_city_len = city.len;
    inter.weather_state.injectCurrent(inter.weatherCity(), .{ .temp_c = 14, .condition = .rain });
    inter.weather_state.injectHourly(inter.weatherCity(), &.{ .{ .temp_c = 14, .condition = .rain }, .{ .temp_c = 15, .condition = .cloudy } });
    try testing.expect(inter.weatherLocated());
    try testing.expectEqualStrings("Seattle", inter.weatherCity());
    try testing.expectEqual(@as(i16, 14), inter.weatherReading().?.temp_c);
    var hours: [applications.weather.hourly_span]applications.weather.Reading = undefined;
    try testing.expectEqual(@as(usize, 2), inter.weatherHourly(&hours).len);
    // The alert control arms one on tap; a second tap leaves it armed (enable-only).
    try testing.expect(!inter.weatherHasAlert());
    const a = weatherAlertRect();
    try testing.expect(weatherTap(&inter, a.x + 5, a.y + 5));
    try testing.expect(inter.weatherHasAlert());
    try testing.expect(weatherTap(&inter, a.x + 5, a.y + 5));
    try testing.expect(inter.weatherHasAlert());
}

test "settings toggles an open setting through the domain and refuses a sensitive one" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Low Power Mode is off by default; a tap on its row flips it through the real domain.
    const before = inter.settingValue(.low_power_mode);
    const open_row = settingRowRect(2);
    try testing.expect(settingsTap(&inter, open_row.x + 20, open_row.y + 10));
    try testing.expect(inter.settingValue(.low_power_mode) != before);
    // The sensitive Biometric Unlock is not reachable from the screen.
    const locked_row = settingRowRect(5);
    try testing.expect(!settingsTap(&inter, locked_row.x + 20, locked_row.y + 10));
}

// --- The in-app agents: the two doors, the approval classes, and exactly-once ---

test "the files agent organizes a real file through the framework, and the footer reverts it" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    var buf: [8][]const u8 = undefined;
    // Nothing archived before the agent acts.
    try testing.expectEqual(@as(usize, 0), inter.files_state.search("archive/", &buf).len);
    // The agent organizes: a real move through the notify door, and the file actually lands in archive.
    inter.filesAgentOrganize();
    try testing.expect(inter.files_agent_row.status == .executed);
    try testing.expectEqual(@as(usize, 1), inter.files_state.search("archive/", &buf).len);
    try testing.expect(inter.files_state.search("documents/budget.csv", &buf).len == 0); // moved, not copied
    // The footer offers a Revert; a tap on it undoes the move from real recorded state, exactly once.
    try testing.expect(inter.files_agent_row.control == .revert);
    const action = agentBandActionRect();
    try testing.expect(filesTap(&inter, action.x + 4, action.y + 4));
    try testing.expectEqual(@as(usize, 0), inter.files_state.search("archive/", &buf).len);
    try testing.expect(inter.files_state.search("documents/budget.csv", &buf).len == 1); // back where it was
    // Revert is spent: the control is gone and a second tap changes nothing.
    try testing.expect(inter.files_agent_row.control == .none);
    try testing.expect(!filesTap(&inter, action.x + 4, action.y + 4));
}

test "an agent presenting the wrong capability is denied at the door, and the tree is untouched" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Reach the same Files domain the person's door reaches, but present a capability that does not
    // match the move tool. The frame denies it before the domain runs — the two doors, one gate.
    var app = inter.filesApp();
    const outcome = try app.invoke(
        agentActor(files_agent),
        .{ .operation = "file.move", .args = "documents/budget.csv>documents/archive/budget.csv" },
        "files.read", // wrong capability for file.move
        true,
        inter.next_key,
    );
    switch (outcome) {
        .denied => {},
        else => return error.TestExpectedDenial,
    }
    var buf: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), inter.files_state.search("archive/", &buf).len); // nothing moved
}

test "the calendar agent proposes a focus block from real events and holds a commit that notifies others" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Seeded busy 9, 10, 14; the first free working hour is 11.
    try testing.expect(!inter.slotBusy(11));
    inter.calendarAgentPropose();
    // The proposal is a real add through the notify door: 11 is now committed, and the day remembers it
    // was the agent's, to draw it distinctly.
    try testing.expect(inter.slotBusy(11));
    try testing.expectEqual(@as(?u32, 11), inter.calendar_proposed_slot);

    // The commit that would notify other people is held, not run: the row waits with an Approve control.
    inter.calendarAgentStageCommit();
    try testing.expect(inter.calendar_agent_row.status == .held);
    try testing.expect(inter.calendar_agent_row.control == .approve);
    // A tap on Approve runs the same held operation exactly once, through the real approve path.
    const action = agentBandActionRect();
    try testing.expect(calendarTap(&inter, action.x + 4, action.y + 4));
    try testing.expect(inter.calendar_agent_row.status == .executed);
    try testing.expect(inter.calendar_agent_row.control == .none);
    // Approving again is inert: the control is gone, so the tap does not run a second commit.
    try testing.expect(!calendarTap(&inter, action.x + 4, action.y + 4));
}

test "the weather agent refreshes through the domain without disturbing the live reading" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Stand up a located device with a live reading, as the fetch path does.
    const city = "Seattle";
    @memcpy(inter.weather_city[0..city.len], city);
    inter.weather_city_len = city.len;
    inter.weather_state.injectCurrent(inter.weatherCity(), .{ .temp_c = 14, .condition = .rain });
    // The agent refreshes through weather.current (silent). The live reading the device fetched is
    // preserved — a read does not overwrite the display with the CI connector's value.
    inter.weatherAgentRefresh();
    try testing.expect(inter.weather_agent_row.status == .executed);
    try testing.expectEqual(@as(i16, 14), inter.weatherReading().?.temp_c);
    try testing.expect(inter.weatherReading().?.condition == .rain);
}

test "the notes agent writes a real note through the same door the person uses" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    const before = inter.notes_state.count();
    inter.notesAgentCreate();
    try testing.expect(inter.notes_agent_row.status == .executed);
    // The note is really in the notebook — the agent's create ran the same note.create the person's does.
    try testing.expectEqual(before + 1, inter.notes_state.count());
    try testing.expect(inter.notes_state.body("Follow up") != null);
}

test "the contacts agent looks up the book silently and reports the real match count" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    inter.contactsAgentLookup();
    try testing.expect(inter.contacts_agent_row.status == .executed);
    // The count the agent reported is the real number of matches the domain returns for the same query.
    var buf: [64][]const u8 = undefined;
    const matches = inter.contacts_state.search("a", &buf).len;
    var expected: [16]u8 = undefined;
    const needle = std.fmt.bufPrint(&expected, "{d} in the book", .{matches}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, inter.contacts_agent_row.message(), needle) != null);
}

test "seeding the agent presence populates every agentic app's last action from real state" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    seedAgentPresence(&inter);
    // Each app now carries a real derived action: files organized, calendar holding a commit, notes and
    // contacts read/written. None is left at the default empty state.
    try testing.expect(inter.files_agent_row.status == .executed);
    try testing.expect(inter.calendar_agent_row.status == .held);
    try testing.expect(inter.notes_agent_row.status == .executed);
    try testing.expect(inter.contacts_agent_row.status == .executed);
    // The extended apps carry their real derived actions too: the browser read a page, the store holds
    // an install, the phone recorded a screening, and settings/maps/health read their local domains.
    try testing.expect(inter.browser_agent_row.status == .executed);
    try testing.expect(inter.store_agent_row.status == .held);
    try testing.expect(inter.phone_agent_row.status == .executed);
    try testing.expect(inter.settings_agent_row.status == .executed);
    try testing.expect(inter.maps_agent_row.status == .executed);
    try testing.expect(inter.health_agent_row.status == .executed);
}

test "the browser agent reads the page silently through the same domain the person's UI reads" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The page the person is on, read directly from the domain.
    const page = inter.browserCurrent().?;
    // The agent's read goes through browser.read_page (silent) and reports the same projection.
    inter.browserAgentRead();
    try testing.expect(inter.browser_agent_row.status == .executed);
    try testing.expect(std.mem.indexOf(u8, inter.browser_agent_row.message(), @tagName(page.kind)) != null);
}

test "the browser agent's form submit is held, sends nothing until approved, and sends exactly once" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Staging fills the form (a local change) and holds the submit — nothing has been submitted yet.
    inter.browserAgentStageSubmit();
    try testing.expect(inter.browser_agent_row.status == .held);
    try testing.expect(inter.browser_agent_row.control == .approve);
    try testing.expectEqual(@as(usize, 1), inter.browser_state.filledCount()); // filled, awaiting submit
    // A tap on Approve runs the same held submit exactly once: the staged fields are consumed.
    const action = agentBandActionRect();
    try testing.expect(browserTap(&inter, action.x + 4, action.y + 4));
    try testing.expect(inter.browser_agent_row.status == .executed);
    try testing.expect(inter.browser_agent_row.control == .none);
    try testing.expectEqual(@as(usize, 0), inter.browser_state.filledCount()); // submitted, form cleared
    // Approving again is inert: the control is gone, so the tap does not submit a second time.
    try testing.expect(!browserTap(&inter, action.x + 4, action.y + 4));
}

test "the store agent's install is held with the package's declared capabilities and installs once on approval" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    try testing.expect(!inter.isInstalled(store_agent_target.name));
    // Staging holds the install — the package is not installed while it waits for the person.
    inter.storeAgentStageInstall();
    try testing.expect(inter.store_agent_row.status == .held);
    try testing.expect(inter.store_agent_row.control == .approve);
    try testing.expect(!inter.isInstalled(store_agent_target.name)); // held, not installed
    // The held row names the package's real declared capabilities.
    try testing.expect(std.mem.indexOf(u8, inter.store_agent_row.message(), store_agent_target.caps) != null);
    // A tap on Approve installs it exactly once through the same domain the person's Get reaches.
    const action = agentBandActionRect();
    try testing.expect(storeTap(&inter, action.x + 4, action.y + 4));
    try testing.expect(inter.isInstalled(store_agent_target.name));
    try testing.expectEqual(@as(usize, 1), inter.store_state.installedCount());
    // Approving again does not install a second time.
    try testing.expect(!storeTap(&inter, action.x + 4, action.y + 4));
    try testing.expectEqual(@as(usize, 1), inter.store_state.installedCount());
}

test "the phone agent screens a caller into a real untrusted state and holds an outbound call" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    try testing.expectEqual(@as(usize, 0), inter.phone_state.screeningCount());
    // Screening (notify) records a real screening the person can judge — untrusted, no invented transcript.
    inter.phoneAgentScreen();
    try testing.expect(inter.phone_agent_row.status == .executed);
    try testing.expectEqual(@as(usize, 1), inter.phone_state.screeningCount());
    try testing.expect(inter.phone_state.screenings.items[0].untrusted());
    // Placing a call is held: nothing is dialled until the person approves, then it dials exactly once.
    try testing.expectEqual(@as(usize, 0), inter.phone_state.calls());
    inter.phoneAgentStageCall();
    try testing.expect(inter.phone_agent_row.status == .held);
    try testing.expectEqual(@as(usize, 0), inter.phone_state.calls()); // held, not dialled
    const action = agentBandActionRect();
    try testing.expect(phoneTap(&inter, action.x + 4, action.y + 4));
    try testing.expectEqual(@as(usize, 1), inter.phone_state.calls());
    try testing.expect(!phoneTap(&inter, action.x + 4, action.y + 4)); // spent, no second dial
    try testing.expectEqual(@as(usize, 1), inter.phone_state.calls());
}

test "the settings agent's write to a sensitive key is refused by the domain, as an agent's is" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // A silent read reports the real value.
    inter.settingsAgentRead();
    try testing.expect(inter.settings_agent_row.status == .executed);
    // An agent toggling a sensitive (human_only) key reaches the same domain the person's toggle does,
    // and the domain refuses it — the key's sensitivity gates the write, whoever the caller.
    var app = inter.settingsApp();
    const before = inter.settingValue(.biometric_unlock);
    const outcome = try app.invoke(
        agentActor(settings_agent),
        .{ .operation = "settings.toggle", .args = "biometric_unlock" },
        "settings.write",
        true,
        inter.next_key,
    );
    try testing.expect(outcome == .failed);
    try testing.expectEqual(before, inter.settingValue(.biometric_unlock)); // unchanged
}

test "the maps and health agents read their real local domains silently" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The distance the agent reports is the same the maps domain computes for the person.
    inter.mapsAgentDistance();
    try testing.expect(inter.maps_agent_row.status == .executed);
    var dbuf: [16]u8 = undefined;
    const d = std.fmt.bufPrint(&dbuf, "{d} units", .{inter.mapsDistance("Home", "Studio").?}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, inter.maps_agent_row.message(), d) != null);
    // The steps average the agent reports is the same the health domain computes.
    inter.healthAgentSummary();
    try testing.expect(inter.health_agent_row.status == .executed);
    var hbuf: [16]u8 = undefined;
    const avg = std.fmt.bufPrint(&hbuf, "{d}", .{inter.healthAverage(.steps).?}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, inter.health_agent_row.message(), avg) != null);
}

// --- The six newly-surfaced apps: their surfaces, their taps, and their agents' two doors ---

test "the tasks agent completes a real task, and a tap completes another through the same door" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Seeded: "Reply to Marco" already done, the rest open.
    try testing.expect(inter.taskDone("Reply to Marco"));
    try testing.expect(!inter.taskDone("Pay the electricity bill"));
    // The agent ticks a task through task.complete (notify) — the real list changes.
    inter.tasksAgentComplete();
    try testing.expect(inter.tasks_agent_row.status == .executed);
    try testing.expect(inter.taskDone("Pay the electricity bill"));
    // A tap on an open task's row completes it through the same domain door.
    const rect = taskRowRect(0); // "Confirm the studio booking"
    try testing.expect(!inter.taskDone("Confirm the studio booking"));
    try testing.expect(tasksTap(&inter, rect.x + 10, rect.y + 10));
    try testing.expect(inter.taskDone("Confirm the studio booking"));
}

test "the music agent reads an honestly empty library through the silent door" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // No seeded catalogue: the library is honestly empty, nothing playing.
    try testing.expectEqual(@as(usize, 0), inter.musicCount());
    try testing.expect(inter.musicNowPlaying() == null);
    inter.musicAgentRead();
    try testing.expect(inter.music_agent_row.status == .executed);
    try testing.expect(std.mem.indexOf(u8, inter.music_agent_row.message(), "Nothing playing") != null);
}

test "the wallet agent's payment is held, debits nothing until approved, and pays exactly once" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    const opening = inter.walletBalanceCents();
    try testing.expect(opening > 0);
    // Staging holds the payment — value has not moved.
    inter.walletAgentStagePay();
    try testing.expect(inter.wallet_agent_row.status == .held);
    try testing.expect(inter.wallet_agent_row.control == .approve);
    try testing.expectEqual(opening, inter.walletBalanceCents()); // held, not debited
    // A tap on Approve pays exactly once through the same domain the person's pay reaches.
    const action = agentBandActionRect();
    try testing.expect(walletTap(&inter, action.x + 4, action.y + 4));
    try testing.expect(inter.walletBalanceCents() < opening);
    const paid = inter.walletBalanceCents();
    // Approving again is inert: the balance is unchanged, never double-charged.
    try testing.expect(!walletTap(&inter, action.x + 4, action.y + 4));
    try testing.expectEqual(paid, inter.walletBalanceCents());
}

test "the photos gallery holds the device's real media, favourited by the agent and by a tap" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The gallery is built from the in-grant image files the device holds — real media, not a seed set.
    var paths: [8][]const u8 = undefined;
    const images = imagePaths(&paths);
    try testing.expect(images.len >= 1);
    try testing.expectEqual(images.len, inter.photosCount());
    try testing.expect(!inter.photoFavorited(images[0]));
    // The agent favourites a real photo (notify) — the library changes.
    inter.photosAgentFavorite();
    try testing.expect(inter.photos_agent_row.status == .executed);
    try testing.expect(inter.photoFavorited(images[0]));
    // A tap on a tile favourites through the same door (idempotent once set).
    const rect = photoTileRect(0);
    try testing.expect(photosTap(&inter, rect.x + 4, rect.y + 4));
    try testing.expect(inter.photoFavorited(images[0]));
}

test "the clock reads world times on device and the agent reads one silently" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // Against the deterministic default instant (2026-01-01 00:00 UTC), the offsets are exact.
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("09:00", inter.clockLocal("UTC+09:00", &buf));
    try testing.expectEqualStrings("01:00", inter.clockLocal("UTC+01:00", &buf));
    // The agent reads a world clock through clock.time (silent), over the same zone arithmetic.
    inter.clockAgentRead();
    try testing.expect(inter.clock_agent_row.status == .executed);
}

test "the home agent switches a light (notify) and holds a lock's unlock, opened once on approval" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    // The lock starts engaged; the light is off.
    try testing.expectEqual(@as(?bool, true), inter.homeOn("Front Door"));
    try testing.expectEqual(@as(?bool, false), inter.homeOn("Living Room"));
    // The agent switches the light on through home.set (notify) — the real device changes.
    inter.homeAgentAdjust();
    try testing.expect(inter.home_agent_row.status == .executed);
    try testing.expectEqual(@as(?bool, true), inter.homeOn("Living Room"));
    // Unlocking is held: the lock stays engaged until the person approves.
    inter.homeAgentStageUnlock();
    try testing.expect(inter.home_agent_row.status == .held);
    try testing.expect(inter.home_agent_row.control == .approve);
    try testing.expectEqual(@as(?bool, true), inter.homeOn("Front Door")); // held, still locked
    // A tap on Approve opens it exactly once through the real domain.
    const action = agentBandActionRect();
    try testing.expect(smarthomeTap(&inter, action.x + 4, action.y + 4));
    try testing.expectEqual(@as(?bool, false), inter.homeOn("Front Door")); // unlocked once
    try testing.expect(inter.home_agent_row.control == .none);
    // A tap on a light's row toggles it through the same door the agent uses.
    const lamp = deviceRowRect(1); // "Desk Lamp"
    try testing.expect(smarthomeTap(&inter, lamp.x + 10, lamp.y + 10));
    try testing.expectEqual(@as(?bool, true), inter.homeOn("Desk Lamp"));
}

test "seeding the agent presence populates the six new apps' rows from real domain state" {
    var inter = Interaction{};
    inter.attach(testing.allocator);
    defer inter.release();
    seedAgentPresence(&inter);
    // Notifies and silent reads land executed; the value-bearing and physical acts land held.
    try testing.expect(inter.tasks_agent_row.status == .executed);
    try testing.expect(inter.music_agent_row.status == .executed);
    try testing.expect(inter.photos_agent_row.status == .executed);
    try testing.expect(inter.clock_agent_row.status == .executed);
    try testing.expect(inter.wallet_agent_row.status == .held);
    try testing.expect(inter.home_agent_row.status == .held);
}

test "every newly-surfaced app is reachable from the library grid and maps to its surface" {
    // Each new app opens the surface the shell renders it on.
    try testing.expectEqual(Surface.tasks, appSurface(.tasks).?);
    try testing.expectEqual(Surface.music, appSurface(.music).?);
    try testing.expectEqual(Surface.wallet, appSurface(.wallet).?);
    try testing.expectEqual(Surface.photos, appSurface(.photos).?);
    try testing.expectEqual(Surface.clock, appSurface(.clock).?);
    try testing.expectEqual(Surface.smarthome, appSurface(.home).?);
    // A tap on the Tasks tile in the "All apps" library opens the Tasks surface — the navigation is wired.
    const idx = for (library_apps, 0..) |app, i| {
        if (app == .tasks) break i;
    } else unreachable;
    const tile = LibGrid.tileRect(idx);
    try testing.expectEqual(Surface.tasks, libraryApp(tile.x + 4, tile.y + 4).?);
}
