//! Native component runtime.
//!
//! Native components are signed packages that run outside the trusted control
//! plane under a declared resource boundary, a memory ceiling, an execution
//! meter, and a cancellation token. They reach host resources only through the
//! sandbox, and their failures are contained rather than propagated.

pub const sandbox = @import("sandbox/sandbox.zig");
pub const host = @import("host/host.zig");

test {
    _ = sandbox;
    _ = host;
}
