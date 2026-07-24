//! The communications layer.
//!
//! Calls, messages, and the contacts and history around them. The modules decide rather than
//! connect: which dialed string is a call for help, what call-state transitions are legal, when
//! two numbers are the same person, and how a message's status may change. The safety floor
//! runs through all of it — an emergency number is recognized however it is formatted and
//! whatever the network, a call that ended stays ended, and the device keeps emergency calling
//! even when it can register on no plan — testable without a radio.

pub const emergency = @import("emergency/numbers.zig");
pub const telephony = @import("telephony/callstate.zig");
pub const contacts = @import("contacts/matching.zig");
pub const messaging = @import("messaging/delivery.zig");
pub const call_history = @import("call-history/log.zig");
pub const voicemail = @import("voicemail/retention.zig");
pub const carrier = @import("carrier/selection.zig");

test {
    _ = emergency;
    _ = telephony;
    _ = contacts;
    _ = messaging;
    _ = call_history;
    _ = voicemail;
    _ = carrier;
}
