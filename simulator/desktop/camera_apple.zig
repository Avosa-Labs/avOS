//! Binds the device's real camera backend on Apple platforms into the shell's Camera capture path.
//!
//! This is the Apple backend of the shell's `camera_bind` entry point; other platforms implement the
//! same signature in `camera_native.zig`. It builds the AVFoundation adapter (real device enumeration
//! and, once the viewfinder opens, a real capture session that delivers frames behind the seam) and
//! binds it into the running interaction's camera seam, so the Camera app finds a real capture device
//! where the host has one — and honestly reports none where it does not. Binding only hands the seam the
//! backend; it enumerates nothing and starts no session until the capture path asks, so wiring the shell
//! never lights the camera.
//!
//! The backend is process-static: the seam holds it by reference, and it must outlive every frame of the
//! render loop, so it lives for the life of the process rather than on a stack frame.

const live = @import("live_render");
const avfoundation = @import("avfoundation");

/// The AVFoundation backend the seam is bound to — process-static, so the seam's reference stays valid
/// for the life of the run.
var backend_state: avfoundation.AvfCameraBackend = avfoundation.AvfCameraBackend.init();

/// Binds the real AVFoundation backend into the interaction's camera seam.
pub fn bind(interaction: *live.Interaction) void {
    interaction.bindCameraBackend(backend_state.backend());
}
