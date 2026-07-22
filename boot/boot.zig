//! The boot path.
//!
//! Each stage verifies the next before handing control to it, and measures it
//! before it does. A stage that cannot verify what comes next stops rather than
//! continuing: a boot that proceeds past a failed verification has verified
//! nothing, because the check was advisory.
//!
//! Verification asks whether a stage is one the device accepts; measurement
//! records which one ran. A device that only verifies can say it booted
//! something acceptable, and one that measures can say which.

pub const chain = @import("chain/chain.zig");
pub const measurements = @import("measurements/measurements.zig");
pub const recovery = @import("recovery/recovery.zig");
pub const verified = @import("verified/verified.zig");

test {
    _ = chain;
    _ = measurements;
    _ = recovery;
    _ = verified;
}
