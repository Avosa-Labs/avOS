//! The CoreAudio and CoreFoundation C API, imported once.
//!
//! CoreAudio is the macOS host audio HAL; CoreFoundation carries the device names as CFStrings.
//! This is the single place their headers are imported, so no CoreAudio or CoreFoundation C type
//! escapes the adapter — the surface in `coreaudio.zig` speaks only Zig over the audio seam.
//!
//! The import goes through `coreaudio_shim.h` rather than straight at `<CoreAudio/AudioHardware.h>`
//! because this SDK's umbrella header declares Objective-C block typedefs unconditionally, which Zig's
//! translate-c cannot parse (there is no -fblocks translate mode). The shim brings in the block-free
//! base header for the types and constants and hand-declares the three enumeration symbols that live
//! only in the umbrella header, against the real framework ABI — see the shim for detail. The CoreAudio
//! framework is linked, so the calls reach the actual HAL.
//!
//! Built only on macOS (see the build's os gate); on any other host this file is never compiled.

pub const c = @cImport({
    @cInclude("coreaudio_shim.h");
});
