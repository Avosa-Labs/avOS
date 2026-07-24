//! The device emulator.
//!
//! A virtual device that stands in faithfully for a real one — the layer that makes "the environment
//! isn't tied to the handset" testable, where a virtual phone is a real, bootable, capability-secured
//! device rather than a mock. The modules decide rather than emulate: whether a device profile is
//! coherent, whether an image's digest authorizes it to boot, whether a snapshot is intact and belongs
//! to the profile restoring it, how injected input is attributed so it can never pass as a present
//! human, and whether an outbound connection is allowed under isolation-by-default. The through-line is
//! fidelity with the real device's guarantees: the emulator boots only verified images, restores only
//! consistent state, never launders synthetic input into human authority, and reaches only declared
//! hosts — so what holds in emulation holds on hardware.

pub const device = @import("device/profile.zig");
pub const image = @import("image/integrity.zig");
pub const snapshots = @import("snapshots/restore.zig");
pub const controls = @import("controls/injection.zig");
pub const networking = @import("networking/isolation.zig");

test {
    _ = device;
    _ = image;
    _ = snapshots;
    _ = controls;
    _ = networking;
}
