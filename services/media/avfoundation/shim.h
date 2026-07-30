// The AVFoundation camera enumeration surface for the Zig adapter, exposed as a tiny pure-C ABI.
//
// AVCaptureDevice is Objective-C only — there is no pure-C entry point and no umbrella header Zig's
// translate-c can parse — so the adapter cannot @cImport <AVFoundation/AVFoundation.h> directly. This
// header declares nothing but plain C prototypes; their implementation in shim.m does the Objective-C
// enumeration and hands back only ints, unsigned ints, and UTF-8 bytes. bindings.zig @cIncludes this
// file, so no Objective-C or AVFoundation type ever crosses into Zig.
//
// A camera's id is a stable small integer derived from its AVCaptureDevice uniqueID (an FNV-1a hash),
// so the same physical device keeps the same id across calls within a process run. Every call
// re-runs a fresh discovery so count, id, name, and has-camera all agree on one live device set.

#ifndef AVF_CAMERA_SHIM_H
#define AVF_CAMERA_SHIM_H

// The number of video capture devices AVFoundation currently discovers on this host. A headless or
// TCC-restricted host may honestly report zero.
int avf_camera_count(void);

// The stable id of the camera at `index` (0-based, into the current discovery order), or 0 if the
// index is out of range. The id is a hash of the device's uniqueID, so it survives re-enumeration.
unsigned int avf_camera_id(int index);

// Writes the camera's localizedName (UTF-8, NUL-terminated) for the device with `id` into `buf`
// (capacity `buf_len`) and returns the string length written, or -1 if no such camera exists or the
// name does not fit.
int avf_camera_name(unsigned int id, char *buf, int buf_len);

// 1 if a video capture device with `id` is currently discoverable, else 0.
int avf_has_camera(unsigned int id);

// --- Capture-session streaming surface ---
//
// Beyond enumeration, the adapter runs a real AVCaptureSession + AVCaptureVideoDataOutput on the
// camera and, on every delivered CMSampleBuffer, records only the frame's shape — width, height, and
// the CoreVideo pixel format as its raw OSType. The pixel buffer itself never leaves the delegate; only
// the shape crosses this ABI, so frame delivery stays O(1) with no per-pixel copy. The delegate runs on
// its own capture queue while the reader runs on the caller's thread, so the shape is guarded by a lock.

// Starts a capture session on the camera with `id`. Returns 0 when the camera exists and a session was
// brought up, -1 when no such camera exists, and -2 when the camera exists but the session could not be
// built (leaving nothing running). A prior session is torn down first, so this is safe to re-enter.
int avf_stream_start(unsigned int id);

// Stops and tears down the running session, if any. Idempotent.
void avf_stream_stop(void);

// 1 while the session is actually running (read from AVCaptureSession at the source), else 0.
int avf_stream_live(void);

// Writes the most recent delivered frame's shape into `*width`, `*height`, and `*format` (the raw
// CoreVideo OSType pixel format) and returns 1; returns 0 before any frame has arrived. No pixels are
// copied — only the shape.
int avf_latest_frame(unsigned int *width, unsigned int *height, unsigned int *format);

#endif // AVF_CAMERA_SHIM_H
