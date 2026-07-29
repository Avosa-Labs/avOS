// The Objective-C implementation of the camera enumeration ABI declared in shim.h.
//
// AVCaptureDevice has no pure-C API, so this file — the only Objective-C in the adapter — reaches
// AVFoundation and hands the Zig side nothing but plain C. It discovers the host's video capture
// devices through AVCaptureDeviceDiscoverySession (built-in wide-angle plus external device types,
// video media type), maps each device to a stable small integer id (an FNV-1a hash of its uniqueID),
// and reads its localizedName as UTF-8. Every entry point runs a fresh discovery, so count, id, name,
// and has-camera always speak of one live device set.
//
// Built only on macOS (see the build's os gate); off macOS this file is never compiled and the seam
// keeps its honest-until-bound default.

#import <AVFoundation/AVFoundation.h>

// A stable small integer id for a device, hashed from its uniqueID string so it survives
// re-enumeration within a process run. FNV-1a over the UTF-8 bytes; 0 is reserved for "no device", so
// a hash of 0 is nudged to 1.
static unsigned int avf_hash_unique_id(NSString *unique_id) {
    const char *bytes = [unique_id UTF8String];
    unsigned int hash = 2166136261u; // FNV offset basis
    if (bytes != NULL) {
        for (const char *p = bytes; *p != '\0'; p++) {
            hash ^= (unsigned char)*p;
            hash *= 16777619u; // FNV prime
        }
    }
    return hash == 0u ? 1u : hash;
}

// The current set of video capture devices, in discovery order. Built-in wide-angle covers the
// FaceTime/webcam class; external covers USB and Continuity cameras. The array is autoreleased.
static NSArray<AVCaptureDevice *> *avf_devices(void) {
    NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray array];
    [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    if (@available(macOS 10.15, *)) {
        [types addObject:AVCaptureDeviceTypeExternalUnknown];
    }
    AVCaptureDeviceDiscoverySession *session =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    return session.devices;
}

int avf_camera_count(void) {
    @autoreleasepool {
        return (int)avf_devices().count;
    }
}

unsigned int avf_camera_id(int index) {
    @autoreleasepool {
        NSArray<AVCaptureDevice *> *devices = avf_devices();
        if (index < 0 || (NSUInteger)index >= devices.count) return 0u;
        return avf_hash_unique_id(devices[(NSUInteger)index].uniqueID);
    }
}

int avf_camera_name(unsigned int id, char *buf, int buf_len) {
    @autoreleasepool {
        if (buf == NULL || buf_len <= 0) return -1;
        NSArray<AVCaptureDevice *> *devices = avf_devices();
        for (AVCaptureDevice *device in devices) {
            if (avf_hash_unique_id(device.uniqueID) != id) continue;
            const char *name = [device.localizedName UTF8String];
            if (name == NULL) return -1;
            // Copy up to buf_len-1 bytes and NUL-terminate; fail if the name would be truncated.
            NSUInteger len = strlen(name);
            if (len >= (NSUInteger)buf_len) return -1;
            memcpy(buf, name, len);
            buf[len] = '\0';
            return (int)len;
        }
        return -1;
    }
}

int avf_has_camera(unsigned int id) {
    @autoreleasepool {
        NSArray<AVCaptureDevice *> *devices = avf_devices();
        for (AVCaptureDevice *device in devices) {
            if (avf_hash_unique_id(device.uniqueID) == id) return 1;
        }
        return 0;
    }
}
