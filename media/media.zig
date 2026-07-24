//! The media layer.
//!
//! Capturing, encoding, playing, and routing audio and video. The modules decide rather than
//! process: which codec both sides support, which quality the network can sustain, where audio
//! comes out, and which session owns the controls. Two safety floors run through it — the camera
//! and a recording never run without a visible indicator, and the master volume can never reach
//! a hearing-damaging level — testable without a speaker or a lens.

pub const mixing = @import("audio/mixing.zig");
pub const camera = @import("camera/access.zig");
pub const codecs = @import("codecs/selection.zig");
pub const photo = @import("photo/metadata.zig");
pub const playback = @import("playback/playback.zig");
pub const recording = @import("recording/recording.zig");
pub const routing = @import("routing/routing.zig");
pub const sessions = @import("sessions/sessions.zig");
pub const video = @import("video/bitrate.zig");

test {
    _ = mixing;
    _ = camera;
    _ = codecs;
    _ = photo;
    _ = playback;
    _ = recording;
    _ = routing;
    _ = sessions;
    _ = video;
}
