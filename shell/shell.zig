//! The session shell.
//!
//! Surfaces project control-plane state rather than holding their own copy of
//! it, so what the user sees is what the system can account for. The command
//! surface stays reachable, agent activity stays visible, and no surface can
//! present an action as complete before it is.

pub const surfaces = @import("surfaces/surfaces.zig");
pub const command = @import("command/command.zig");
pub const inspectors = @import("inspectors/inspectors.zig");
pub const session = @import("session/session.zig");
pub const render = @import("render/render.zig");
pub const boot = @import("boot/boot.zig");
pub const onboarding = @import("onboarding/onboarding.zig");
pub const lock = @import("lock/lock.zig");
pub const home = @import("home/home.zig");
pub const launcher = @import("launcher/launcher.zig");
pub const task_graph = @import("task-graph/task_graph.zig");
pub const approvals = @import("approvals/approvals.zig");
pub const notifications = @import("notifications/stack.zig");
pub const settings = @import("settings/settings.zig");
pub const quick_controls = @import("quick-controls/quick_controls.zig");
pub const multitasking = @import("multitasking/recents.zig");

// Form-factor adaptations: identity and task graphs move across endpoints, but each form factor's
// capabilities are its own — a deliberate reduction from, or extension of, the phone baseline.
pub const phone = @import("phone/adaptation.zig");
pub const tablet = @import("tablet/adaptation.zig");
pub const desktop = @import("desktop/adaptation.zig");
pub const wearable = @import("wearable/adaptation.zig");
pub const spatial = @import("spatial/adaptation.zig");
pub const vehicle = @import("vehicle/adaptation.zig");
pub const room = @import("room/adaptation.zig");
pub const robot = @import("robot/adaptation.zig");
pub const screenless = @import("screenless/adaptation.zig");

test {
    _ = surfaces;
    _ = command;
    _ = inspectors;
    _ = session;
    _ = render;
    _ = boot;
    _ = onboarding;
    _ = lock;
    _ = home;
    _ = launcher;
    _ = task_graph;
    _ = approvals;
    _ = notifications;
    _ = settings;
    _ = quick_controls;
    _ = multitasking;
    _ = phone;
    _ = tablet;
    _ = desktop;
    _ = wearable;
    _ = spatial;
    _ = vehicle;
    _ = room;
    _ = robot;
    _ = screenless;
}
