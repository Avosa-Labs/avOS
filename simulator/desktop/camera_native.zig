//! Binds the device's real camera backend on non-Apple platforms into the shell's Camera capture path.
//!
//! Accurate host camera capture comes from each operating system's own capture stack — AVFoundation on
//! Apple (camera_apple.zig), Video4Linux2 on Linux — reached through a per-OS adapter behind the platform
//! camera seam. This file provides the same `bind` entry point for every other platform, so the desktop
//! shell links and runs the identical way on all of them.
//!
//! A platform whose backend is wired binds it here; a platform without one leaves the seam unbound, and
//! the Camera capture path honestly stays dark rather than pretending a device is delivering. The Linux
//! V4L2 adapter (services/media/v4l2) is a real, tested backend behind the seam; binding it into the
//! windowed shell here — guarded on a `/dev/video*` device being present — slots in behind this entry
//! point. Until a host wires one, the seam stays honestly dark: no frame is ever fabricated.

const live = @import("live_render");

/// Leaves the interaction's camera seam unbound: on a platform whose backend is not yet wired into the
/// windowed shell, the capture path stays honestly dark and no frame is fabricated.
pub fn bind(_: *live.Interaction) void {}
