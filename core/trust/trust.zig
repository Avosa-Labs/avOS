//! The agent trust layer: the verifiable trust between principals that do not already trust each other.
//!
//! Prevention (capabilities) and recovery (ledger + approval) exist elsewhere; this is the third pillar.
//! A `manifest` is the signed contract a human accepts and the core enforces — endorsed to a trust root,
//! deny-by-default, re-consent on widening. A `grant` is deliberate cross-owner sharing — scoped, signed,
//! bounded, delegable-but-narrowing, and revocable instantly, a single grant or a whole principal. A
//! `provenance` chain answers, tamper-evidently, who did what to a shared or owned namespace, under which
//! capability, endorsed by which root. Whichever mind backs an agent, its trust is established the same
//! way: identity and manifest, verified and revocable.

pub const manifest = @import("manifest.zig");
pub const endorsement = @import("endorsement.zig");
pub const rotation = @import("rotation.zig");
pub const grant = @import("grant.zig");
pub const provenance = @import("provenance.zig");
pub const enforcement = @import("enforcement.zig");

test {
    _ = manifest;
    _ = endorsement;
    _ = rotation;
    _ = grant;
    _ = provenance;
    _ = enforcement;
}
