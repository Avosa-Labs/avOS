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
