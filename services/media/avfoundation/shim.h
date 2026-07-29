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

#endif // AVF_CAMERA_SHIM_H
