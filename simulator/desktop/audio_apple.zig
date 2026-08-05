//! Binds the device's real audio backend on Apple platforms into the shell's screening path.
//!
//! This is the Apple backend of the shell's `audio_bind` entry point; other platforms implement the same
//! signature in `audio_native.zig`. It builds the CoreAudio adapter (real device enumeration and, when a
//! stream is opened, a real capture+playback path) and binds it into the running interaction's audio
//! seam, so the Phone screening path finds a real capture and playback device where the host has them —
//! and honestly reports none where it does not. Binding only hands the seam the backend; it enumerates
//! nothing and opens no stream until the screening path asks, so wiring the shell never lights the mic.
//!
//! The backend and its capture relay are process-static: the seam holds the backend by reference, and it
//! must outlive every frame of the render loop, so they live for the life of the process rather than on a
//! stack frame. The relay is the lock-free path a capture stream's realtime thread would hand samples
//! across; it is attached here so the route is fully wired, though the shell only surveys devices.

const live = @import("live_render");
const audio = @import("audio");
const coreaudio = @import("coreaudio");

/// The CoreAudio backend the seam is bound to — process-static, so the seam's reference stays valid for
/// the life of the run.
var backend_state: coreaudio.CoreAudioBackend = coreaudio.CoreAudioBackend.init();
/// The lock-free relay a capture stream's realtime callback delivers blocks across, off its realtime
/// thread. Attached to the backend so the capture path is complete when a stream is opened.
var capture_relay: audio.CaptureRelay = audio.CaptureRelay.init();

/// Binds the real CoreAudio backend into the interaction's screening audio seam.
pub fn bind(interaction: *live.Interaction) void {
    backend_state.attachCaptureRelay(&capture_relay);
    interaction.bindAudioBackend(backend_state.backend());
}
