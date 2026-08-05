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

// --- AudioUnit / AudioToolbox surface for opening a real output stream ---
//
// The AudioUnit umbrella (<AudioUnit/AudioUnit.h>) transitively drags in the same block typedefs that
// keep <CoreAudio/AudioHardware.h> out of translate-c, so — exactly as the enumeration symbols above —
// the output-stream API is hand-declared here against the real framework ABI. AudioStreamBasicDescription,
// AudioBufferList, AudioBuffer and AudioTimeStamp (plus kAudioFormatLinearPCM and the linear-PCM format
// flags) already arrive through <CoreAudio/CoreAudioTypes.h>, pulled in by AudioHardwareBase.h above, so
// only the AudioComponent/AudioUnit types, the property/scope constants, the render-callback shape, and
// the seven functions the output path calls are declared below. The AudioToolbox and AudioUnit frameworks
// are linked (see build.zig), so every call reaches the real stack.

typedef UInt32 AudioUnitPropertyID;
typedef UInt32 AudioUnitScope;
typedef UInt32 AudioUnitElement;
typedef UInt32 AudioUnitRenderActionFlags;

typedef struct OpaqueAudioComponent*          AudioComponent;
typedef struct OpaqueAudioComponentInstance*  AudioComponentInstance;
typedef AudioComponentInstance                AudioUnit;

typedef struct AudioComponentDescription {
    OSType  componentType;
    OSType  componentSubType;
    OSType  componentManufacturer;
    UInt32  componentFlags;
    UInt32  componentFlagsMask;
} AudioComponentDescription;

// The render proc the output unit pulls samples from. A zero-fill proc renders running silence.
typedef OSStatus (*AURenderCallback)( void*                        inRefCon,
                                      AudioUnitRenderActionFlags*  ioActionFlags,
                                      const AudioTimeStamp*        inTimeStamp,
                                      UInt32                       inBusNumber,
                                      UInt32                       inNumberFrames,
                                      AudioBufferList*             ioData);

typedef struct AURenderCallbackStruct {
    AURenderCallback  inputProc;
    void*             inputProcRefCon;
} AURenderCallbackStruct;

// AudioComponent identifiers for the system default-output unit (Apple-manufactured).
enum { kAudioUnitType_Output       = 'auou' };
enum { kAudioUnitSubType_DefaultOutput = 'def ' };
enum { kAudioUnitManufacturer_Apple = 'appl' };

// The HAL output unit ('ahal') is the same component driven in reverse for capture: with input enabled
// on bus 1 and output disabled on bus 0, it pulls samples from a hardware input device. The capture path
// opens this subtype and binds it to the system default input device.
enum { kAudioUnitSubType_HALOutput = 'ahal' };

// The system object's default-input-device selector: reads the AudioDeviceID of the current default
// input, the device the capture unit is pointed at.
enum { kAudioHardwarePropertyDefaultInputDevice = 'dIn ' };

// The two AudioUnit properties the output path sets: the stream format and the render callback.
enum { kAudioUnitProperty_StreamFormat      = 8  };
enum { kAudioUnitProperty_SetRenderCallback = 23 };

// The output-unit properties the capture path sets: enable/disable I/O per bus (2003), point the unit at
// a device (2000), and install the input callback the unit fires when a captured block is ready (2005).
enum { kAudioOutputUnitProperty_CurrentDevice   = 2000 };
enum { kAudioOutputUnitProperty_EnableIO        = 2003 };
enum { kAudioOutputUnitProperty_SetInputCallback = 2005 };

// AudioUnit scopes. The output unit's input scope (element 0) is where the client format and the render
// callback are installed — it is the side the client feeds.
enum { kAudioUnitScope_Global = 0 };
enum { kAudioUnitScope_Input  = 1 };
enum { kAudioUnitScope_Output = 2 };

extern AudioComponent
AudioComponentFindNext( AudioComponent                     inComponent,
                        const AudioComponentDescription*   inDesc);

extern OSStatus
AudioComponentInstanceNew( AudioComponent            inComponent,
                           AudioComponentInstance*   outInstance);

extern OSStatus
AudioComponentInstanceDispose( AudioComponentInstance inInstance);

extern OSStatus
AudioUnitSetProperty( AudioUnit             inUnit,
                      AudioUnitPropertyID   inID,
                      AudioUnitScope        inScope,
                      AudioUnitElement      inElement,
                      const void*           inData,
                      UInt32                inDataSize);

extern OSStatus AudioUnitInitialize(AudioUnit inUnit);
extern OSStatus AudioUnitUninitialize(AudioUnit inUnit);
extern OSStatus AudioOutputUnitStart(AudioUnit ci);
extern OSStatus AudioOutputUnitStop(AudioUnit ci);

// The capture path's input callback pulls the ready block out of the unit with AudioUnitRender, filling
// an AudioBufferList the callback owns. Signature matches <AudioUnit/AudioOutputUnit.h> exactly.
extern OSStatus
AudioUnitRender( AudioUnit                     inUnit,
                 AudioUnitRenderActionFlags*   ioActionFlags,
                 const AudioTimeStamp*         inTimeStamp,
                 UInt32                        inOutputBusNumber,
                 UInt32                        inNumberFrames,
                 AudioBufferList*              ioData);
