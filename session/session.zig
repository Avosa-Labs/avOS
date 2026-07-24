//! Session virtualization.
//!
//! A person's environment is a Personal Compute Instance, not a device. It
//! exists while every endpoint is offline, and endpoints are authenticated
//! manifestations of it rather than the place it lives.
//!
//! Moving between endpoints changes which one is presenting. It does not change
//! the principal, the work in flight, or what has already happened — and a
//! consequential action performed on one endpoint is never repeated by another.

pub const endpoint = @import("endpoint/endpoint.zig");
pub const instance = @import("instance/instance.zig");
pub const transport = @import("transport/transport.zig");
pub const presenter = @import("host/presenter.zig");
pub const attach = @import("client/attach.zig");
pub const protocol = @import("protocol/negotiate.zig");
pub const state = @import("state/version.zig");
pub const synchronization = @import("synchronization/reconnect.zig");
pub const revocation = @import("revocation/endpoint.zig");
pub const conflict = @import("conflict/claim.zig");
pub const presentation = @import("presentation/frame.zig");

test {
    _ = endpoint;
    _ = instance;
    _ = transport;
    _ = presenter;
    _ = attach;
    _ = protocol;
    _ = state;
    _ = synchronization;
    _ = revocation;
    _ = conflict;
    _ = presentation;
}
