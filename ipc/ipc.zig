//! Inter-service message contracts.
//!
//! Services do not share memory or call into one another directly. They
//! exchange typed, versioned, bounded, authenticated messages that carry the
//! authority and deadline they act under. That is what makes a service boundary
//! a trust boundary rather than a naming convention.
//!
//! This module holds the contract itself. It depends on the domain model for
//! the error taxonomy and nothing else: no transport, no service logic, and no
//! knowledge of which services exist.

pub const wire = @import("schema/wire.zig");
pub const envelope = @import("schema/envelope.zig");
pub const authenticator = @import("authentication/authenticator.zig");
pub const routing = @import("routing/routing.zig");
pub const cancellation = @import("cancellation/cancellation.zig");

test {
    _ = wire;
    _ = envelope;
    _ = authenticator;
    _ = routing;
    _ = cancellation;
}
