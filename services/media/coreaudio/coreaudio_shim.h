// Core Audio HAL surface for the Zig adapter, trimmed to what Zig's translate-c can parse.
//
// The umbrella header <CoreAudio/AudioHardware.h> declares Objective-C block typedefs (e.g.
// AudioObjectPropertyListenerBlock, AudioDeviceIOBlock) unconditionally — with no __BLOCKS__ guard —
// and Zig's translate-c has no -fblocks mode, so importing it fails to translate. The block-based
// listener and IO-proc APIs are not part of enumeration, so this shim pulls in the block-free base
// header (the AudioObject types, the property-address struct, and the selector/scope/element
// constants) and then declares by hand the three symbols enumeration needs that live only in the
// umbrella header. They are declared against the real framework ABI; the CoreAudio framework is linked,
// so every call reaches the actual HAL, not a stand-in.

#include <CoreAudio/AudioHardwareBase.h>
// Only CFString (device names) and CFBase (CFRelease) are needed. The CoreFoundation umbrella header
// also pulls in the mach message headers, whose packed descriptor structs translate-c renders as
// zero-size opaque types that then trip the SDK's own size static-asserts; the two narrow headers carry
// everything the adapter uses without that.
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFString.h>

// A device is just an AudioObject; the umbrella header names that role AudioDeviceID.
typedef AudioObjectID AudioDeviceID;

// The system object — the root AudioObject whose device-list property enumerates every HAL device.
enum { kAudioObjectSystemObject = 1 };

// The system object's device-list selector: reads the array of AudioDeviceIDs for every HAL device.
enum { kAudioHardwarePropertyDevices = 'dev#' };

// The per-device stream-configuration selector: reads an AudioBufferList describing a device's streams
// in a given scope (input for capture, output for playback). Same four-char code as the SDK header.
enum { kAudioDevicePropertyStreamConfiguration = 'slay' };

// The two property accessors enumeration uses. Signatures match <CoreAudio/AudioHardware.h> exactly.
extern OSStatus
AudioObjectGetPropertyDataSize( AudioObjectID                       inObjectID,
                                const AudioObjectPropertyAddress*   inAddress,
                                UInt32                              inQualifierDataSize,
                                const void*                         inQualifierData,
                                UInt32*                             outDataSize);

extern OSStatus
AudioObjectGetPropertyData( AudioObjectID                       inObjectID,
                            const AudioObjectPropertyAddress*   inAddress,
                            UInt32                              inQualifierDataSize,
                            const void*                         inQualifierData,
                            UInt32*                             ioDataSize,
                            void*                               outData);
