//! The runtime-to-host boundary, shared by every runtime.
//!
//! A runtime is an adapter that runs untrusted code; it is never an authority. When
//! that code reaches for a host capability, the request crosses this boundary, where
//! it is authorized against the capability the guest actually holds — the same way
//! for native, wasm, Android, and web. One boundary, one answer.

pub const host_capability = @import("host_capability.zig");
const acceptance = @import("acceptance.zig");

pub const Bridge = host_capability.Bridge;
pub const Request = host_capability.Request;
pub const Decision = host_capability.Decision;
pub const Denial = host_capability.Denial;

test {
    _ = host_capability;
    _ = acceptance;
}
