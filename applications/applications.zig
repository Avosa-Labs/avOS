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
pub const surface = @import("framework/surface.zig");

pub const messages_domain = @import("messages/domain.zig");
pub const messages = @import("messages/messages.zig");
pub const messages_surface = @import("messages/surface.zig");
pub const calendar_domain = @import("calendar/domain.zig");
pub const calendar = @import("calendar/calendar.zig");
pub const calendar_surface = @import("calendar/surface.zig");
pub const calendar_recurrence = @import("calendar/recurrence.zig");
pub const files_domain = @import("files/domain.zig");
pub const files = @import("files/files.zig");
pub const files_surface = @import("files/surface.zig");
pub const camera_domain = @import("camera/domain.zig");
pub const camera = @import("camera/camera.zig");
pub const camera_surface = @import("camera/surface.zig");
pub const phone_domain = @import("phone/domain.zig");
pub const phone = @import("phone/phone.zig");
pub const phone_surface = @import("phone/surface.zig");
pub const contacts_domain = @import("contacts/domain.zig");
pub const contacts = @import("contacts/contacts.zig");
pub const contacts_surface = @import("contacts/surface.zig");
pub const settings_domain = @import("settings/domain.zig");
pub const settings = @import("settings/settings.zig");
pub const settings_surface = @import("settings/surface.zig");
pub const settings_panels = @import("settings/panels.zig");
pub const settings_capabilities = @import("settings/capabilities.zig");
pub const weather_domain = @import("weather/domain.zig");
pub const weather = @import("weather/weather.zig");
pub const weather_surface = @import("weather/surface.zig");
pub const browser_domain = @import("browser/domain.zig");
pub const browser = @import("browser/browser.zig");
pub const browser_surface = @import("browser/surface.zig");
pub const store_domain = @import("store/domain.zig");
pub const store = @import("store/store.zig");
pub const store_surface = @import("store/surface.zig");
pub const calculator_domain = @import("calculator/domain.zig");
pub const calculator = @import("calculator/calculator.zig");
pub const calculator_surface = @import("calculator/surface.zig");
pub const agents_console = @import("agents/console.zig");
pub const agents_domain = @import("agents/domain.zig");
pub const agents = @import("agents/agents.zig");
pub const agents_surface = @import("agents/surface.zig");
pub const acceptance_tests = @import("tests/acceptance.zig");
pub const manifest_conformance = @import("tests/manifest_conformance.zig");
pub const data_privacy = @import("tests/data_privacy.zig");
pub const connector_need = @import("tests/connector_need.zig");
pub const agent_classes = @import("tests/agent_classes.zig");

test {
    _ = framework;
    _ = suite;
    _ = surface;
    _ = messages_domain;
    _ = messages;
    _ = messages_surface;
    _ = calendar_domain;
    _ = calendar;
    _ = calendar_surface;
    _ = files_domain;
    _ = files;
    _ = files_surface;
    _ = camera_domain;
    _ = camera;
    _ = camera_surface;
    _ = phone_domain;
    _ = phone;
    _ = phone_surface;
    _ = contacts_domain;
    _ = contacts;
    _ = contacts_surface;
    _ = settings_domain;
    _ = settings;
    _ = settings_surface;
    _ = settings_panels;
    _ = settings_capabilities;
    _ = weather_domain;
    _ = weather;
    _ = weather_surface;
    _ = browser_domain;
    _ = browser;
    _ = browser_surface;
    _ = store_domain;
    _ = store;
    _ = store_surface;
    _ = calculator_domain;
    _ = calculator;
    _ = calculator_surface;
    _ = agents_console;
    _ = agents_domain;
    _ = agents;
    _ = agents_surface;
    _ = acceptance_tests;
    _ = manifest_conformance;
    _ = agent_classes;
    _ = data_privacy;
    _ = connector_need;
}
