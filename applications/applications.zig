//! The first-party applications.
//!
//! The apps a device ships with, and the ones that set the standard every third-party app is held
//! to. Each module decides rather than presents: whether an unverified caller may ring, whether an
//! unknown sender's remote content loads, which contact fields and which photos an app may read,
//! whether the camera may capture, whether a saved credential or passkey is offered to a page,
//! whether a file access stays inside its grant, whether a sensitive setting demands
//! re-authentication, whether an alarm pierces silent mode, whether the calculator may hold any
//! capability at all, what a calendar query may learn, whether a locked note is shown, whether an
//! email's sender is authenticated, how precise a location an app receives, whether an install needs
//! acknowledgement, what a support bundle discloses, and whether a lost device obeys a remote
//! command. The through-line is that the safe, private choice is the default and the revealing one is
//! a deliberate act — testable without a screen.

pub const phone = @import("phone/screening.zig");
pub const messages = @import("messages/remote_content.zig");
pub const contacts = @import("contacts/field_scope.zig");
pub const camera = @import("camera/capture.zig");
pub const photos = @import("photos/library_access.zig");
pub const browser = @import("browser/autofill.zig");
pub const files = @import("files/scope.zig");
pub const settings = @import("settings/reauth.zig");
pub const clock = @import("clock/alarm.zig");
pub const calculator = @import("calculator/sealed.zig");
pub const calendar = @import("calendar/availability.zig");
pub const notes = @import("notes/locked.zig");
pub const mail = @import("mail/authentication.zig");
pub const maps = @import("maps/precision.zig");
pub const store = @import("store/install_source.zig");
pub const support = @import("support/bundle.zig");
pub const locator = @import("locator/command.zig");
pub const credentials = @import("credentials/passkey.zig");

test {
    _ = phone;
    _ = messages;
    _ = contacts;
    _ = camera;
    _ = photos;
    _ = browser;
    _ = files;
    _ = settings;
    _ = clock;
    _ = calculator;
    _ = calendar;
    _ = notes;
    _ = mail;
    _ = maps;
    _ = store;
    _ = support;
    _ = locator;
    _ = credentials;
}
