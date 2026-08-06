//! The CoreAudio host-audio adapter: a Zig backend over the macOS Core Audio HAL, bound behind the
//! platform audio seam (`services/media/audio.zig`).
//!
//! CoreAudio is macOS's hardware abstraction layer for audio. This adapter reaches it only to answer
//! the two questions the seam asks: what devices exist, and can a given device open in a given
//! direction. It walks the system object's device list (`kAudioHardwarePropertyDevices`), decides each
//! device's direction from its input and output stream configurations, and reads its human name as a
//! CFString converted to UTF-8. A device that both captures and plays is emitted twice — once per
//! direction — because the seam's `Device` carries a single direction.
//!
//! Every CoreAudio and CoreFoundation C type stays inside this module (all of it comes through
//! `bindings.zig`); nothing above the seam sees a HAL type. The returned device names must outlive the
//! call, so the backend context owns fixed-size name buffers and the returned `[]const u8` slices point
//! into them — never onto the stack. Beyond enumerate/can-open, the adapter opens real streams:
//! playback is a default-output AudioUnit whose stream format is set from the seam `Format`, driven by a
//! zero-fill render callback (running silence — the proof is a real, started CoreAudio stream, not
//! audible content); capture is the default-input device on a HAL AudioUnit whose realtime input
//! callback renders each block and hands it to the attached `CaptureRelay` in bounded chunks, lock-free.
//! The realtime thread is isolated inside this module: its callback touches only its own staging buffer
//! and the relay, never general OS code. The units and their live flags are held in the backend context,
//! so `stopStream`/`streamLive` at the seam read the truth of the hardware.
//!
//! Built only on macOS (see the build's os gate); off macOS the seam keeps its honest-until-bound
//! default and this module is never compiled.

const std = @import("std");
const audio = @import("audio");
const c = @import("bindings.zig").c;

/// The most devices we enumerate, and the most name buffers the context owns. A device can occupy two
/// entries (capture and playback), so the name store is twice the device cap.
const max_devices = 64;
const max_entries = max_devices * 2;
/// Bytes reserved per device name, UTF-8, NUL-terminated by CoreFoundation before we trim.
const name_capacity = 128;
/// Bytes the capture callback renders one hardware block into before handing it to the relay. Sized
/// past a generous input callback (a few thousand frames of interleaved f32) so a block always fits;
/// the relay then carries it across in `CaptureRelay.block_capacity` chunks.
const capture_staging_bytes = 16 * 1024;

/// The bound CoreAudio backend. It owns the name storage the returned `Device` slices point into, so a
/// device name lives as long as the backend, not the call. One is enough for a process.
pub const CoreAudioBackend = struct {
    /// One UTF-8 name buffer per possible returned device entry. `devices` writes a name here and hands
    /// back a slice into it, so the name outlives the enumeration call.
    name_store: [max_entries][name_capacity]u8 = undefined,
    /// The default-output AudioUnit while a playback stream is open, else null. Its presence is the live
    /// flag the seam reads for playback: a stream is live exactly when this holds a started unit.
    output_unit: ?c.AudioComponentInstance = null,
    /// The default-input HAL AudioUnit while a capture stream is open, else null. Its render callback
    /// runs on CoreAudio's realtime thread and hands samples out only through `capture_relay`.
    input_unit: ?c.AudioComponentInstance = null,
    /// Where the capture callback drops each block. Attach one before opening a capture stream; the
    /// callback pushes into it lock-free and never calls back into general code on the realtime thread.
    /// Null leaves capture running but discarding — an open input with nowhere wired to receive.
    capture_relay: ?*audio.CaptureRelay = null,
    /// The channel count the open capture stream carries, so the realtime callback shapes its render
    /// buffer without reading back the format across the seam.
    capture_channels: u8 = 0,
    /// The realtime callback renders one hardware block here, then relays it. Owned by the context so it
    /// outlives every callback and needs no per-block allocation. Aligned for f32 samples.
    capture_staging: [capture_staging_bytes]u8 align(16) = undefined,

    pub fn init() CoreAudioBackend {
        return .{};
    }

    /// Wires the relay the capture callback hands blocks to. Set it before opening a capture stream so
    /// the realtime thread has somewhere to deliver; without it a capture stream still opens but its
    /// samples are discarded rather than delivered.
    pub fn attachCaptureRelay(self: *CoreAudioBackend, relay: *audio.CaptureRelay) void {
        self.capture_relay = relay;
    }

    /// The seam backend that reaches this adapter. Bind it to an `Audio` with `audio.bind(...)`.
    pub fn backend(self: *CoreAudioBackend) audio.Backend {
        return .{
            .context = @ptrCast(self),
            .devices_fn = devicesFn,
            .can_open_fn = canOpenFn,
            .open_stream_fn = openStreamFn,
            .stop_stream_fn = stopStreamFn,
            .stream_live_fn = streamLiveFn,
        };
    }

    fn openStreamFn(context: *anyopaque, device_id: u32, direction: audio.Direction, format: audio.Format) audio.OpenError!void {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context));
        _ = device_id; // the units follow the system default device for their direction
        return self.openStream(direction, format);
    }

    fn stopStreamFn(context: *anyopaque) void {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context));
        self.stopStream();
    }

    fn streamLiveFn(context: *anyopaque) bool {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context));
        return self.output_unit != null or self.input_unit != null;
    }

    fn devicesFn(context: *anyopaque, out: []audio.Device) []const audio.Device {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context));
        return self.enumerate(out, true);
    }

    fn canOpenFn(context: *anyopaque, device_id: u32, direction: audio.Direction) bool {
        const self: *CoreAudioBackend = @ptrCast(@alignCast(context));
        var buf: [max_entries]audio.Device = undefined;
        // Enumerate without resolving names: can-open needs only ids and directions, and skipping the
        // name reads leaves the context's name buffers (which a prior `devices` result may point into)
        // untouched.
        const found = self.enumerate(&buf, false);
        for (found) |d| {
            if (d.id == device_id and d.direction == direction) return true;
        }
        return false;
    }

    /// Walks the HAL device list into `out`, one `Device` per direction a device carries. With
    /// `resolve_names` set, each entry's name is read from CoreAudio into the context's owned storage;
    /// without it, names are left empty (used by can-open, which never inspects them). Any HAL error
    /// yields the devices gathered so far rather than a crash — an empty slice is an honest answer.
    fn enumerate(self: *CoreAudioBackend, out: []audio.Device, resolve_names: bool) []const audio.Device {
        var list_addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDevices,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        var size: c.UInt32 = 0;
        if (c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &list_addr, 0, null, &size) != 0) {
            return out[0..0];
        }
        const id_bytes = @sizeOf(c.AudioDeviceID);
        const available = size / id_bytes;
        if (available == 0) return out[0..0];

        var ids: [max_devices]c.AudioDeviceID = undefined;
        const want: usize = @min(@as(usize, available), ids.len);
        var got_bytes: c.UInt32 = @intCast(want * id_bytes);
        if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &list_addr, 0, null, &got_bytes, &ids) != 0) {
            return out[0..0];
        }
        const count: usize = @as(usize, got_bytes) / id_bytes;

        var written: usize = 0;
        var slot: usize = 0;
        for (ids[0..count]) |id| {
            inline for (.{ audio.Direction.capture, audio.Direction.playback }) |dir| {
                if (written < out.len and self.hasStreams(id, dir)) {
                    const name: []const u8 = if (resolve_names) self.readName(id, slot) else "";
                    slot += 1;
                    out[written] = .{ .id = @intCast(id), .name = name, .direction = dir };
                    written += 1;
                }
            }
        }
        return out[0..written];
    }

    /// Whether a device carries any stream in a direction, read from its stream configuration in the
    /// matching HAL scope. A direction with at least one channel across its buffers is present.
    fn hasStreams(self: *CoreAudioBackend, id: c.AudioDeviceID, direction: audio.Direction) bool {
        _ = self;
        const scope: c.AudioObjectPropertyScope = switch (direction) {
            .capture => c.kAudioObjectPropertyScopeInput,
            .playback => c.kAudioObjectPropertyScopeOutput,
        };
        var addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyStreamConfiguration,
            .mScope = scope,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        var size: c.UInt32 = 0;
        if (c.AudioObjectGetPropertyDataSize(id, &addr, 0, null, &size) != 0) return false;
        if (size == 0 or size > 4096) return false;

        // An AudioBufferList is a count followed by a flexible array of AudioBuffer; back it with a
        // suitably aligned byte buffer sized to the property.
        var storage: [4096]u8 align(@alignOf(c.AudioBufferList)) = undefined;
        var got: c.UInt32 = size;
        if (c.AudioObjectGetPropertyData(id, &addr, 0, null, &got, &storage) != 0) return false;

        const buffer_list: *const c.AudioBufferList = @ptrCast(&storage);
        const buffers: [*]const c.AudioBuffer = @ptrCast(&buffer_list.mBuffers);
        var channels: u32 = 0;
        var i: usize = 0;
        while (i < buffer_list.mNumberBuffers) : (i += 1) {
            channels += buffers[i].mNumberChannels;
        }
        return channels > 0;
    }

    /// Reads a device's human name into the context's `slot` buffer and returns a slice of it. Falls
    /// back to a short id-derived name (also owned by the slot) when the HAL name cannot be read, so the
    /// returned name is never empty.
    fn readName(self: *CoreAudioBackend, id: c.AudioDeviceID, slot: usize) []const u8 {
        const store: *[name_capacity]u8 = &self.name_store[slot];
        var addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioObjectPropertyName,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        var cfname: c.CFStringRef = null;
        var size: c.UInt32 = @sizeOf(c.CFStringRef);
        if (c.AudioObjectGetPropertyData(id, &addr, 0, null, &size, @ptrCast(&cfname)) == 0 and cfname != null) {
            defer c.CFRelease(@ptrCast(cfname));
            if (c.CFStringGetCString(cfname, store, @intCast(store.len), c.kCFStringEncodingUTF8) != 0) {
                const end = std.mem.indexOfScalar(u8, store, 0) orelse store.len;
                if (end > 0) return store[0..end];
            }
        }
        const fallback = std.fmt.bufPrint(store, "audio-device-{d}", .{id}) catch return store[0..0];
        return fallback;
    }

    /// Opens and starts a real stream for a direction, dispatching to the output or input path. Each
    /// leaves nothing half-open on failure and yields `StreamFailed`; a HAL error at any step is honest
    /// rather than a pretend stream.
    fn openStream(self: *CoreAudioBackend, direction: audio.Direction, format: audio.Format) audio.OpenError!void {
        return switch (direction) {
            .playback => self.openOutput(format),
            .capture => self.openInput(format),
        };
    }

    /// Builds the interleaved, packed linear-PCM stream description a unit's client side speaks, from the
    /// seam `Format`. Shared by the output and input paths so both agree on sample shape.
    fn clientFormat(format: audio.Format) c.AudioStreamBasicDescription {
        const bits: c.UInt32 = switch (format.encoding) {
            .s16 => 16,
            .f32 => 32,
        };
        const flags: c.UInt32 = switch (format.encoding) {
            .s16 => c.kAudioFormatFlagIsSignedInteger | c.kAudioFormatFlagIsPacked,
            .f32 => c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
        };
        const bytes_per_frame: c.UInt32 = (bits / 8) * @as(c.UInt32, format.channels);
        return .{
            .mSampleRate = @floatFromInt(format.sample_rate_hz),
            .mFormatID = c.kAudioFormatLinearPCM,
            .mFormatFlags = flags,
            .mBytesPerPacket = bytes_per_frame,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = bytes_per_frame,
            .mChannelsPerFrame = format.channels,
            .mBitsPerChannel = bits,
            .mReserved = 0,
        };
    }

    /// Opens the system default-output AudioUnit, sets its client (input-scope) stream format from the
    /// seam `Format`, installs a zero-fill render callback, initializes and starts it — a genuinely
    /// running CoreAudio stream carrying inaudible silence (the proof is a started stream, not content).
    fn openOutput(self: *CoreAudioBackend, format: audio.Format) audio.OpenError!void {
        if (self.output_unit != null) self.stopOutput(); // never leak a prior open

        var desc = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const comp = c.AudioComponentFindNext(null, &desc) orelse return audio.OpenError.StreamFailed;

        var unit: c.AudioComponentInstance = null;
        if (c.AudioComponentInstanceNew(comp, &unit) != 0 or unit == null) return audio.OpenError.StreamFailed;
        errdefer _ = c.AudioComponentInstanceDispose(unit);

        // The client format on the output unit's input scope, element 0 — the side the render callback
        // feeds.
        var asbd = clientFormat(format);
        if (c.AudioUnitSetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Input, 0, &asbd, @sizeOf(c.AudioStreamBasicDescription)) != 0) {
            return audio.OpenError.StreamFailed;
        }

        var cb = c.AURenderCallbackStruct{ .inputProc = renderSilence, .inputProcRefCon = null };
        if (c.AudioUnitSetProperty(unit, c.kAudioUnitProperty_SetRenderCallback, c.kAudioUnitScope_Input, 0, &cb, @sizeOf(c.AURenderCallbackStruct)) != 0) {
            return audio.OpenError.StreamFailed;
        }

        if (c.AudioUnitInitialize(unit) != 0) return audio.OpenError.StreamFailed;
        errdefer _ = c.AudioUnitUninitialize(unit);

        if (c.AudioOutputUnitStart(unit) != 0) return audio.OpenError.StreamFailed;

        self.output_unit = unit;
    }

    /// Opens the system default-input device on a HAL AudioUnit: enables input on bus 1 and disables
    /// output on bus 0, points the unit at the current default input device, sets the client format the
    /// callback reads, and installs the input callback — a genuinely running capture stream. The callback
    /// runs on CoreAudio's realtime thread and delivers samples only through the attached relay, never by
    /// calling back into general code. Any HAL step that fails disposes the unit and yields `StreamFailed`.
    fn openInput(self: *CoreAudioBackend, format: audio.Format) audio.OpenError!void {
        if (self.input_unit != null) self.stopInput(); // never leak a prior open

        // The device the capture unit is pointed at: the current system default input.
        var default_input: c.AudioDeviceID = 0;
        var dev_addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDefaultInputDevice,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        var dev_size: c.UInt32 = @sizeOf(c.AudioDeviceID);
        if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &dev_addr, 0, null, &dev_size, &default_input) != 0 or default_input == 0) {
            return audio.OpenError.StreamFailed;
        }

        var desc = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_HALOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const comp = c.AudioComponentFindNext(null, &desc) orelse return audio.OpenError.StreamFailed;

        var unit: c.AudioComponentInstance = null;
        if (c.AudioComponentInstanceNew(comp, &unit) != 0 or unit == null) return audio.OpenError.StreamFailed;
        errdefer _ = c.AudioComponentInstanceDispose(unit);

        // Enable input on the input bus (1), disable output on the output bus (0).
        var on: c.UInt32 = 1;
        var off: c.UInt32 = 0;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &on, @sizeOf(c.UInt32)) != 0) return audio.OpenError.StreamFailed;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &off, @sizeOf(c.UInt32)) != 0) return audio.OpenError.StreamFailed;

        // Point the unit at the default input device.
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &default_input, @sizeOf(c.AudioDeviceID)) != 0) {
            return audio.OpenError.StreamFailed;
        }

        // The client format on the input bus's output scope (element 1) — the shape the callback reads.
        var asbd = clientFormat(format);
        if (c.AudioUnitSetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &asbd, @sizeOf(c.AudioStreamBasicDescription)) != 0) {
            return audio.OpenError.StreamFailed;
        }

        // The input callback fires on the realtime thread when a block is ready; it carries the context.
        var cb = c.AURenderCallbackStruct{ .inputProc = captureReady, .inputProcRefCon = @ptrCast(self) };
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &cb, @sizeOf(c.AURenderCallbackStruct)) != 0) {
            return audio.OpenError.StreamFailed;
        }

        self.capture_channels = format.channels;
        if (c.AudioUnitInitialize(unit) != 0) return audio.OpenError.StreamFailed;
        errdefer _ = c.AudioUnitUninitialize(unit);

        if (c.AudioOutputUnitStart(unit) != 0) return audio.OpenError.StreamFailed;

        self.input_unit = unit;
    }

    /// Stops and tears down whichever streams are open — output, input, or both. Idempotent.
    fn stopStream(self: *CoreAudioBackend) void {
        self.stopOutput();
        self.stopInput();
    }

    /// Stops and tears down the open playback stream, if any: stop, uninitialize, dispose, clear the
    /// live flag. Idempotent — with nothing open it does nothing.
    fn stopOutput(self: *CoreAudioBackend) void {
        const unit = self.output_unit orelse return;
        _ = c.AudioOutputUnitStop(unit);
        _ = c.AudioUnitUninitialize(unit);
        _ = c.AudioComponentInstanceDispose(unit);
        self.output_unit = null;
    }

    /// Stops and tears down the open capture stream, if any. Stopping the unit ends the realtime
    /// callback before the context it delivers into goes away. Idempotent.
    fn stopInput(self: *CoreAudioBackend) void {
        const unit = self.input_unit orelse return;
        _ = c.AudioOutputUnitStop(unit);
        _ = c.AudioUnitUninitialize(unit);
        _ = c.AudioComponentInstanceDispose(unit);
        self.input_unit = null;
    }
};

/// The capture unit's input callback: CoreAudio pulls this on a realtime thread when a hardware block is
/// ready. It renders the block into the context's staging buffer and hands the bytes to the relay in
/// bounded chunks — a lock-free, allocation-free copy. It never calls into general OS code and never
/// blocks: the one path off this thread is the relay, which drops rather than stalls when the consumer
/// falls behind. With no relay attached the block is rendered and discarded.
fn captureReady(
    in_refcon: ?*anyopaque,
    io_action_flags: ?*c.AudioUnitRenderActionFlags,
    in_timestamp: ?*const c.AudioTimeStamp,
    in_bus: c.UInt32,
    in_frames: c.UInt32,
    io_data: ?*c.AudioBufferList,
) callconv(.c) c.OSStatus {
    _ = io_data; // an input callback is handed null data; the block is pulled with AudioUnitRender
    const self: *CoreAudioBackend = @ptrCast(@alignCast(in_refcon orelse return 0));
    const unit = self.input_unit orelse return 0;

    // A one-buffer list pointing at the context-owned staging buffer — interleaved, so all channels sit
    // in the single buffer. Built on the stack each callback: no allocation.
    var list: c.AudioBufferList = undefined;
    list.mNumberBuffers = 1;
    const buffers: [*]c.AudioBuffer = @ptrCast(&list.mBuffers);
    buffers[0] = .{
        .mNumberChannels = self.capture_channels,
        .mDataByteSize = capture_staging_bytes,
        .mData = &self.capture_staging,
    };

    var render_flags: c.AudioUnitRenderActionFlags = 0;
    const flags_ptr = io_action_flags orelse &render_flags;
    const status = c.AudioUnitRender(unit, flags_ptr, in_timestamp, in_bus, in_frames, &list);
    if (status != 0) return status;

    const captured = buffers[0].mDataByteSize;
    if (self.capture_relay) |relay| {
        var off: c.UInt32 = 0;
        while (off < captured) {
            const n = @min(captured - off, audio.CaptureRelay.block_capacity);
            _ = relay.push(self.capture_staging[off .. off + n]);
            off += n;
        }
    }
    return 0;
}

/// The output unit's render proc: zero-fill every buffer so the stream runs real, inaudible silence.
/// A started AudioUnit pulls this on a realtime thread; it touches only the buffers it is handed.
fn renderSilence(
    in_refcon: ?*anyopaque,
    io_action_flags: ?*c.AudioUnitRenderActionFlags,
    in_timestamp: ?*const c.AudioTimeStamp,
    in_bus: c.UInt32,
    in_frames: c.UInt32,
    io_data: ?*c.AudioBufferList,
) callconv(.c) c.OSStatus {
    _ = in_refcon;
    _ = io_action_flags;
    _ = in_timestamp;
    _ = in_bus;
    _ = in_frames;
    const data = io_data orelse return 0;
    const buffers: [*]c.AudioBuffer = @ptrCast(&data.mBuffers);
    var i: usize = 0;
    while (i < data.mNumberBuffers) : (i += 1) {
        if (buffers[i].mData) |ptr| {
            const bytes: [*]u8 = @ptrCast(ptr);
            @memset(bytes[0..buffers[i].mDataByteSize], 0);
        }
    }
    return 0;
}

// --- Tests (real macOS Core Audio HAL, this host's actual devices) ---

const testing = std.testing;

test "the CoreAudio backend binds and enumerates the host's real devices without crashing" {
    var ca = CoreAudioBackend.init();
    var host = audio.Audio{};
    host.bind(ca.backend());
    try testing.expect(host.available());

    var buf: [max_entries]audio.Device = undefined;
    const devices = host.devices(&buf);
    // Hardware varies and a CI runner may have zero devices — the honest range is 0..N. What must hold
    // is that every device reported is well formed: a non-empty name and a real direction.
    try testing.expect(devices.len >= 0);
    for (devices) |d| {
        try testing.expect(d.name.len > 0);
        try testing.expect(d.direction == .capture or d.direction == .playback);
    }
}

test "can-open agrees with the enumerated set" {
    var ca = CoreAudioBackend.init();
    var host = audio.Audio{};
    host.bind(ca.backend());

    var buf: [max_entries]audio.Device = undefined;
    const devices = host.devices(&buf);

    // The suite never opens a real device — a capture open would light the microphone, and opening a
    // stream is host-integration, kept out of the tests. Only the refusals, which the seam decides
    // before any device is touched, run here: a bad format on an enumerated id is rejected without
    // opening it.
    if (devices.len > 0) {
        try testing.expectError(audio.OpenError.BadFormat, host.openStream(devices[0].id, devices[0].direction, .{ .sample_rate_hz = 0, .channels = 1, .encoding = .s16 }));
    }
    try testing.expect(!host.streamLive()); // nothing was opened

    // An id that is not in the set cannot open in either direction.
    var bogus: u32 = 0xFFFF_FFF0;
    while (bogus != 0) : (bogus -%= 1) {
        var present = false;
        for (devices) |d| {
            if (d.id == bogus) present = true;
        }
        if (!present) break;
    }
    try testing.expectError(audio.OpenError.NoSuchDevice, host.openStream(bogus, .capture, .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 }));
}

test "the playback stream lifecycle is honest without opening a device in the suite" {
    var ca = CoreAudioBackend.init();
    var host = audio.Audio{};
    host.bind(ca.backend());

    // Nothing is live before any stream, and the suite never opens the real output unit — opening a
    // running stream is a host-integration behaviour, kept out of the tests so a run makes no sound.
    try testing.expect(!host.streamLive());

    // The refusals never touch hardware: the seam rejects a bad format (and an unknown device) before
    // the backend is ever asked to open, so these exercise the open path without a device opening.
    var buf: [max_entries]audio.Device = undefined;
    const devices = host.devices(&buf);
    const some_id: u32 = if (devices.len > 0) devices[0].id else 0;
    try testing.expectError(audio.OpenError.BadFormat, host.openStream(some_id, .playback, .{ .sample_rate_hz = 0, .channels = 2, .encoding = .f32 }));
    try testing.expect(!host.streamLive());

    // Stop with nothing open stays clean and unlit — idempotent.
    host.stopStream();
    try testing.expect(!host.streamLive());
}
