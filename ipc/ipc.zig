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
pub const capability_binding = @import("capability-binding/capability_binding.zig");
pub const framing = @import("transport/framing.zig");
pub const descriptor = @import("codegen/descriptor.zig");
pub const vectors = @import("test-vectors/vectors.zig");
pub const pipeline = @import("pipeline/pipeline.zig");

// The message and method ceilings are stated in several modules — the schema
// that decodes them, the framing that reads them off the wire, and the layers
// that match a method name. They must agree: a framing ceiling above the
// envelope's would buffer a message the envelope then rejects, and a method
// bound that differed between the router and the binding check would let a name
// resolve that authority would not. This asserts the agreement at build time, so
// a change to one that forgets the others fails to compile rather than shipping a
// gap.
comptime {
    const message_bound = envelope.max_message_bytes;
    if (framing.max_message_bytes != message_bound) {
        @compileError("framing and envelope disagree on the maximum message size");
    }
    const method_bound = envelope.max_method_bytes;
    if (routing.max_method_bytes != method_bound or
        capability_binding.max_method_bytes != method_bound or
        descriptor.max_method_bytes != method_bound)
    {
        @compileError("the maximum method name length differs across modules");
    }
}

test {
    _ = wire;
    _ = envelope;
    _ = authenticator;
    _ = routing;
    _ = cancellation;
    _ = capability_binding;
    _ = framing;
    _ = descriptor;
    _ = vectors;
    _ = pipeline;
}
