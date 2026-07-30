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
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

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

// --- Capture-session streaming ---
//
// The delegate stores only the latest frame's shape as buffers arrive on the capture queue; the reader
// thread fetches it. The shape and the session are guarded by their own locks: the shape lock is taken
// on the hot capture path (kept tiny — three integer writes), the session lock on start/stop/live.

// The latest delivered frame's shape. `has_frame` stays 0 until the first buffer arrives, so the seam's
// honest "no frame before delivery" holds. Guarded by avf_frame_lock.
static os_unfair_lock avf_frame_lock = OS_UNFAIR_LOCK_INIT;
static int          avf_has_frame = 0;
static unsigned int avf_frame_width = 0;
static unsigned int avf_frame_height = 0;
static unsigned int avf_frame_format = 0; // the CoreVideo pixel format OSType, mapped to the seam in Zig

// The running session and its wiring. Under ARC these file-scope object pointers are strong, so
// assigning releases the prior value; nil means nothing is running. Guarded by avf_session_lock.
@class AvfSampleReceiver;
static os_unfair_lock avf_session_lock = OS_UNFAIR_LOCK_INIT;
static AVCaptureSession *avf_session = nil;
static AVCaptureVideoDataOutput *avf_output = nil;
static AvfSampleReceiver *avf_receiver = nil;
static dispatch_queue_t avf_queue = NULL;

// The delegate that receives sample buffers and records each frame's shape. It touches no pixels: it
// reads the image buffer's dimensions and pixel-format type and stores them, so delivery is O(1).
@interface AvfSampleReceiver : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation AvfSampleReceiver
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (image == NULL) return;
    size_t width = CVPixelBufferGetWidth(image);
    size_t height = CVPixelBufferGetHeight(image);
    OSType format = CVPixelBufferGetPixelFormatType(image);
    os_unfair_lock_lock(&avf_frame_lock);
    avf_has_frame = 1;
    avf_frame_width = (unsigned int)width;
    avf_frame_height = (unsigned int)height;
    avf_frame_format = (unsigned int)format;
    os_unfair_lock_unlock(&avf_frame_lock);
}
@end

// Finds the device whose uniqueID hashes to `id`, or nil. Caller holds an autorelease pool.
static AVCaptureDevice *avf_device_for_id(unsigned int id) {
    for (AVCaptureDevice *device in avf_devices()) {
        if (avf_hash_unique_id(device.uniqueID) == id) return device;
    }
    return nil;
}

// Tears the running session down and clears the latest-frame shape. Caller holds avf_session_lock.
static void avf_stream_stop_locked(void) {
    if (avf_session != nil) [avf_session stopRunning];
    if (avf_output != nil) [avf_output setSampleBufferDelegate:nil queue:NULL];
    avf_output = nil;
    avf_session = nil;
    os_unfair_lock_lock(&avf_frame_lock);
    avf_has_frame = 0;
    os_unfair_lock_unlock(&avf_frame_lock);
}

int avf_stream_start(unsigned int id) {
    @autoreleasepool {
        os_unfair_lock_lock(&avf_session_lock);
        avf_stream_stop_locked(); // never leak a prior session

        AVCaptureDevice *device = avf_device_for_id(id);
        if (device == nil) {
            os_unfair_lock_unlock(&avf_session_lock);
            return -1; // no such camera
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        videoOutput.alwaysDiscardsLateVideoFrames = YES; // the reader wants the latest, not a backlog

        if (input == nil || ![session canAddInput:input] || ![session canAddOutput:videoOutput]) {
            os_unfair_lock_unlock(&avf_session_lock);
            return -2; // the camera is real but the session would not build
        }
        [session addInput:input];
        [session addOutput:videoOutput];

        if (avf_queue == NULL) {
            avf_queue = dispatch_queue_create("camera.capture.samples", DISPATCH_QUEUE_SERIAL);
        }
        if (avf_receiver == nil) avf_receiver = [[AvfSampleReceiver alloc] init];
        [videoOutput setSampleBufferDelegate:avf_receiver queue:avf_queue];

        avf_session = session;
        avf_output = videoOutput;
        [session startRunning]; // frames begin arriving on the capture queue

        os_unfair_lock_unlock(&avf_session_lock);
        return 0;
    }
}

void avf_stream_stop(void) {
    @autoreleasepool {
        os_unfair_lock_lock(&avf_session_lock);
        avf_stream_stop_locked();
        os_unfair_lock_unlock(&avf_session_lock);
    }
}

int avf_stream_live(void) {
    os_unfair_lock_lock(&avf_session_lock);
    int running = (avf_session != nil && avf_session.running) ? 1 : 0;
    os_unfair_lock_unlock(&avf_session_lock);
    return running;
}

int avf_latest_frame(unsigned int *width, unsigned int *height, unsigned int *format) {
    os_unfair_lock_lock(&avf_frame_lock);
    int has_frame = avf_has_frame;
    if (has_frame) {
        if (width != NULL) *width = avf_frame_width;
        if (height != NULL) *height = avf_frame_height;
        if (format != NULL) *format = avf_frame_format;
    }
    os_unfair_lock_unlock(&avf_frame_lock);
    return has_frame;
}
