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
pub const suite = @import("framework/suite.zig");

pub const messages_domain = @import("messages/domain.zig");
pub const messages = @import("messages/messages.zig");
pub const calendar_domain = @import("calendar/domain.zig");
pub const calendar = @import("calendar/calendar.zig");
pub const files_domain = @import("files/domain.zig");
pub const files = @import("files/files.zig");
pub const camera_domain = @import("camera/domain.zig");
pub const camera = @import("camera/camera.zig");
pub const phone_domain = @import("phone/domain.zig");
pub const phone = @import("phone/phone.zig");
pub const contacts_domain = @import("contacts/domain.zig");
pub const contacts = @import("contacts/contacts.zig");
pub const settings_domain = @import("settings/domain.zig");
pub const settings = @import("settings/settings.zig");
pub const settings_surface = @import("settings/surface.zig");
pub const store_domain = @import("store/domain.zig");
pub const store = @import("store/store.zig");
pub const calculator = @import("calculator/calculator.zig");
pub const agents = @import("agents/console.zig");
pub const acceptance_tests = @import("tests/acceptance.zig");
pub const manifest_conformance = @import("tests/manifest_conformance.zig");

test {
    _ = framework;
    _ = suite;
    _ = messages_domain;
    _ = messages;
    _ = calendar_domain;
    _ = calendar;
    _ = files_domain;
    _ = files;
    _ = camera_domain;
    _ = camera;
    _ = phone_domain;
    _ = phone;
    _ = contacts_domain;
    _ = contacts;
    _ = settings_domain;
    _ = settings;
    _ = settings_surface;
    _ = store_domain;
    _ = store;
    _ = calculator;
    _ = agents;
    _ = acceptance_tests;
    _ = manifest_conformance;
}
