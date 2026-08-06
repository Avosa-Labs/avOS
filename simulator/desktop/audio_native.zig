//! Binds the device's real audio backend on non-Apple platforms into the shell's screening path.
//!
//! Accurate host audio comes from each operating system's own audio stack — CoreAudio on Apple
//! (audio_apple.zig), ALSA or PipeWire on Linux — reached through a per-OS adapter behind the platform
//! audio seam. This file provides the same `bind` entry point for every other platform, so the desktop
//! shell links and runs the identical way on all of them.
//!
//! A platform whose backend is wired binds it here; a platform without one leaves the seam unbound, and
//! the Phone screening path honestly reports "audio unavailable" rather than pretending an agent is
//! listening. The Linux ALSA adapter (services/media/alsa) is a real, tested backend behind the seam;
//! binding it into the windowed shell here — guarded on the library being present at load, so a host
//! without libasound still runs — slots in behind this entry point. Until a host wires one, the seam
//! stays honestly silent: nothing is ever fabricated.

const live = @import("live_render");

/// Leaves the interaction's audio seam unbound: on a platform whose backend is not yet wired into the
/// windowed shell, the screening path reports audio honestly unavailable.
pub fn bind(_: *live.Interaction) void {}
