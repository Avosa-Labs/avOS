//! What keeps the device's secrets and proves its state.
//!
//! Everything here rests on keys held where the software using them cannot read
//! them. That is why the interfaces are interfaces: a build that substitutes a
//! key in memory for one in hardware must be a visible change rather than an
//! invisible one.

pub const attestation = @import("attestation/attestation.zig");
pub const integrity = @import("integrity/integrity.zig");
pub const keystore = @import("keystore/keystore.zig");
pub const secret_memory = @import("secret-memory/secret_memory.zig");

test {
    _ = attestation;
    _ = integrity;
    _ = keystore;
    _ = secret_memory;
}
