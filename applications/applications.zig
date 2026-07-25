//! The default, agent-native applications.
//!
//! These are the apps a phone ships with — never installed, always present — and every
//! one is agent-native at the core: one shared domain reached through two doors, the
//! person's surface and an agent's registered capabilities, both funnelling every
//! operation through one frame that gates it on the capability it needs, holds a
//! consequential act by an agent for the person, and records every step to the audit
//! ledger the activity feed is derived from. Messages is the complete vertical slice —
//! a real domain both doors call, sending held then approved exactly once — and the
//! rest declare their capabilities over the same frame with their own security rules:
//! Calendar's free/busy projection, Files' grant confinement, Camera's capture gate,
//! Phone's screening, Contacts' field scope, Settings' protected panes, the Store's
//! install sources, and the Calculator's pure arithmetic.
//!
//! Apps a person chooses to add arrive from the Store; these do not. What they share is
//! the frame: an agent in any of them is a first-class, visible, authorized actor whose
//! every action is ground truth in the ledger.

pub const framework = @import("framework/agent_app.zig");

pub const messages_domain = @import("messages/domain.zig");
pub const messages = @import("messages/messages.zig");
pub const calendar = @import("calendar/calendar.zig");
pub const files = @import("files/files.zig");
pub const camera = @import("camera/camera.zig");
pub const phone = @import("phone/phone.zig");
pub const contacts = @import("contacts/contacts.zig");
pub const settings = @import("settings/settings.zig");
pub const store = @import("store/store.zig");
pub const calculator = @import("calculator/calculator.zig");
pub const agents = @import("agents/console.zig");
pub const acceptance_tests = @import("tests/acceptance.zig");

test {
    _ = framework;
    _ = messages_domain;
    _ = messages;
    _ = calendar;
    _ = files;
    _ = camera;
    _ = phone;
    _ = contacts;
    _ = settings;
    _ = store;
    _ = calculator;
    _ = agents;
    _ = acceptance_tests;
}
