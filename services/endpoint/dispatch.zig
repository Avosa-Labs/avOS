//! The map from a request's method name to the handler that serves it, and the
//! reply a handler produces, so a decoded envelope reaches exactly one piece of
//! service code and comes back as a typed result.
//!
//! Authentication, capability binding, and routing decide *that* a message may be
//! delivered to a service; dispatch decides *which* method of that service runs and
//! what it returns. Keeping this a small, explicit table rather than a switch buried
//! in each service has two payoffs. The set of methods a service exposes is data the
//! endpoint can reconcile against the routing table and the capability descriptor at
//! build time, so a method that routes but has no handler, or a handler with no
//! capability, is a compile error rather than a runtime `unavailable`. And every
//! handler shares one signature, so the endpoint can wrap all of them uniformly in
//! metering, cancellation, and transition journaling without knowing what any one of
//! them does.
//!
//! This module holds no state and serves no request itself. It defines the handler
//! contract and the lookup from method to handler, as data over which the endpoint
//! operates.

const std = @import("std");
const ipc = @import("ipc");

pub const Envelope = ipc.envelope.Envelope;
pub const FaultCode = ipc.envelope.FaultCode;
pub const Effect = ipc.descriptor.Effect;

/// The bound on a method name a handler may serve, kept in step with the IPC method
/// bound so a handler cannot claim a method the wire refuses to carry.
pub const max_method_bytes: usize = 64;

/// What a handler is given: the authenticated request and a view of cancellation so
/// a long-running handler can stop cooperatively.
pub const Call = struct {
    /// The decoded request envelope. Authenticated, capability-bound, and routed to
    /// this service before the handler ever sees it.
    envelope: Envelope,
    /// The current time in nanoseconds, so a handler can check its own deadline.
    now_ns: i64,
    /// The in-flight registry the endpoint tracks this call in. A handler at a safe
    /// point calls `stopped` to see whether it has been cancelled or has run past
    /// its deadline, and returns a `cancelled` fault if so.
    cancels: *const ipc.cancellation.Registry,

    /// Whether this call should stop now — cancelled or past its deadline. A handler
    /// that does real work checks this between steps so cancellation is cooperative.
    pub fn stopped(call: Call) bool {
        return call.cancels.shouldStop(call.envelope.correlation, call.now_ns);
    }
};

/// What a handler returns: a reply payload or a typed fault. A handler converts its
/// own errors into faults rather than propagating them, so the endpoint's dispatch
/// path is total — every call becomes a reply or a fault, never an escaping error.
pub const Reply = union(enum) {
    /// The call succeeded; these bytes are the response payload. Borrowed from the
    /// handler's own storage and must outlive the endpoint's use of them.
    ok: []const u8,
    /// The call was refused or failed, as this fault.
    fault: FaultCode,

    pub fn succeeded(reply: Reply) bool {
        return reply == .ok;
    }
};

/// One method a service serves.
pub const Handler = struct {
    /// The wire method name this handler answers to, e.g. "capability.issue".
    method: []const u8,
    /// The capability a caller must present, mirroring the service descriptor. The
    /// binding check enforces it before the handler runs; it is carried here so the
    /// handler set and the descriptor can be reconciled.
    required_capability: []const u8,
    /// What the method does. Fixes whether a call is journaled as a transition (any
    /// mutating effect is) and whether it needs approval beyond the capability.
    effect: Effect,
    /// The resource units a call to this method reserves while it runs. Charged
    /// against the service's meter on entry and released on return.
    cost_units: u64 = 1,
    /// Whether this method's reply may carry a secret, so the endpoint keeps it out
    /// of any diagnostic or audit surface.
    sensitive: bool = false,
    context: *anyopaque,
    serve: *const fn (context: *anyopaque, call: Call) Reply,

    /// Whether a call to this method changes state and so must be journaled.
    pub fn mutates(handler: Handler) bool {
        return handler.effect.mutates();
    }
};

/// A service's set of handlers, looked up by method.
pub const Table = struct {
    handlers: []const Handler,

    /// Finds the handler for a method, or null if the service serves no such method.
    /// A valid table has at most one handler per method, so the first match is the
    /// only match.
    pub fn find(table: Table, method: []const u8) ?*const Handler {
        for (table.handlers) |*handler| {
            if (std.mem.eql(u8, handler.method, method)) return handler;
        }
        return null;
    }
};

/// Confirms a handler set and a capability descriptor describe the same methods.
///
/// The descriptor is the contract clients and the router derive from; the handler
/// table is what actually serves. If they drift — a method in one and not the other,
/// or the same method demanding different capabilities — a client is generated for a
/// method that will not run, or a handler runs under an authority the descriptor
/// never declared. This checks they agree, so the drift is a build error. Intended
/// for a `comptime` call in a service module, alongside `descriptor.validate` and
/// `descriptor.reconcileWithRoutes`, so the three views are pinned together.
pub fn reconcile(table: Table, service_descriptor: ipc.descriptor.Descriptor) ReconcileError!void {
    if (table.handlers.len != service_descriptor.methods.len) return error.MethodCountMismatch;
    for (service_descriptor.methods) |method| {
        const handler = table.find(method.name) orelse return error.MethodNotHandled;
        if (!std.mem.eql(u8, handler.required_capability, method.required_capability)) {
            return error.CapabilityMismatch;
        }
        if (handler.effect != method.effect) return error.EffectMismatch;
    }
}

pub const ReconcileError = error{
    /// The table and the descriptor declare different numbers of methods.
    MethodCountMismatch,
    /// A descriptor method has no handler in the table.
    MethodNotHandled,
    /// A method's handler requires a different capability than the descriptor.
    CapabilityMismatch,
    /// A method's handler declares a different effect than the descriptor.
    EffectMismatch,
};

// --- Tests ---

const echo_reply = "ok";

fn echo(_: *anyopaque, _: Call) Reply {
    return .{ .ok = echo_reply };
}

const sample_handlers = [_]Handler{
    .{ .method = "sample.read", .required_capability = "sample.read", .effect = .read_only, .context = undefined, .serve = echo },
    .{ .method = "sample.write", .required_capability = "sample.write", .effect = .local_mutation, .context = undefined, .serve = echo },
};

const sample_methods = [_]ipc.descriptor.Method{
    .{ .name = "sample.read", .required_capability = "sample.read", .effect = .read_only },
    .{ .name = "sample.write", .required_capability = "sample.write", .effect = .local_mutation },
};

const sample_descriptor: ipc.descriptor.Descriptor = .{ .service = "sample", .methods = &sample_methods };

test "a method resolves to its handler and an unknown method resolves to none" {
    const table: Table = .{ .handlers = &sample_handlers };
    try std.testing.expect(table.find("sample.read") != null);
    try std.testing.expect(table.find("sample.write") != null);
    try std.testing.expect(table.find("sample.delete") == null);
}

test "a read handler does not mutate and a write handler does" {
    const table: Table = .{ .handlers = &sample_handlers };
    try std.testing.expect(!table.find("sample.read").?.mutates());
    try std.testing.expect(table.find("sample.write").?.mutates());
}

test "a handler table reconciles with a matching descriptor" {
    const table: Table = .{ .handlers = &sample_handlers };
    try reconcile(table, sample_descriptor);
}

test "a descriptor method with no handler fails reconciliation" {
    const extra_methods = sample_methods ++ [_]ipc.descriptor.Method{
        .{ .name = "sample.delete", .required_capability = "sample.delete", .effect = .local_mutation },
    };
    const descriptor: ipc.descriptor.Descriptor = .{ .service = "sample", .methods = &extra_methods };
    const table: Table = .{ .handlers = &sample_handlers };
    try std.testing.expectError(error.MethodCountMismatch, reconcile(table, descriptor));
}

test "a handler requiring a different capability than the descriptor fails reconciliation" {
    const mismatched = [_]Handler{
        .{ .method = "sample.read", .required_capability = "sample.read", .effect = .read_only, .context = undefined, .serve = echo },
        .{ .method = "sample.write", .required_capability = "sample.admin", .effect = .local_mutation, .context = undefined, .serve = echo },
    };
    const table: Table = .{ .handlers = &mismatched };
    try std.testing.expectError(error.CapabilityMismatch, reconcile(table, sample_descriptor));
}

test "a handler declaring a different effect than the descriptor fails reconciliation" {
    const mismatched = [_]Handler{
        .{ .method = "sample.read", .required_capability = "sample.read", .effect = .read_only, .context = undefined, .serve = echo },
        .{ .method = "sample.write", .required_capability = "sample.write", .effect = .external, .context = undefined, .serve = echo },
    };
    const table: Table = .{ .handlers = &mismatched };
    try std.testing.expectError(error.EffectMismatch, reconcile(table, sample_descriptor));
}
