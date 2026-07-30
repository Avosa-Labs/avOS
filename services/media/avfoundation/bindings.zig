//! The AVFoundation camera enumeration ABI, imported once.
//!
//! AVCaptureDevice is Objective-C only, so this adapter cannot @cImport the AVFoundation umbrella
//! header — Zig's translate-c has no Objective-C mode. The Objective-C lives entirely in `shim.m`,
//! which exposes a tiny pure-C ABI in `shim.h`; this is the single place that header is imported, so no
//! AVFoundation or Objective-C type escapes the adapter. The surface in `avfoundation.zig` speaks only
//! Zig over the camera seam.
//!
//! The AVFoundation, Foundation, and CoreMedia frameworks are linked (see the build's os gate), so the
//! calls reach the real capture stack. Built only on macOS; on any other host this file is never
//! compiled.

pub const c = @cImport({
    @cInclude("shim.h");
});

// The capture-session streaming entry points, hand-declared against the C ABI in shim.h. They are
// declared here directly (rather than reached through `c`) so the streaming surface the adapter binds
// is spelled out in Zig, in the same style the ALSA adapter declares its libasound ABI. `avf_latest_frame`
// takes plain out-params — the frame's shape only — so no pixel buffer ever crosses into Zig.
pub extern fn avf_stream_start(id: c_uint) c_int;
pub extern fn avf_stream_stop() void;
pub extern fn avf_stream_live() c_int;
pub extern fn avf_latest_frame(width: *c_uint, height: *c_uint, format: *c_uint) c_int;
