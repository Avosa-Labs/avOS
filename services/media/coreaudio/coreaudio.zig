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
//! into them — never onto the stack. This adapter enumerates and answers can-open; actually starting a
//! realtime stream is a follow-up behind the same seam.
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

/// The bound CoreAudio backend. It owns the name storage the returned `Device` slices point into, so a
/// device name lives as long as the backend, not the call. One is enough for a process.
pub const CoreAudioBackend = struct {
    /// One UTF-8 name buffer per possible returned device entry. `devices` writes a name here and hands
    /// back a slice into it, so the name outlives the enumeration call.
    name_store: [max_entries][name_capacity]u8 = undefined,

    pub fn init() CoreAudioBackend {
        return .{};
    }

    /// The seam backend that reaches this adapter. Bind it to an `Audio` with `audio.bind(...)`.
    pub fn backend(self: *CoreAudioBackend) audio.Backend {
        return .{
            .context = @ptrCast(self),
            .devices_fn = devicesFn,
            .can_open_fn = canOpenFn,
        };
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
};

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

    // Every enumerated device opens in the direction it was reported for, and its opposite direction is
    // rejected unless that opposite was itself enumerated (a duplex device).
    for (devices) |d| {
        try host.openStream(d.id, d.direction, .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 });

        const opposite: audio.Direction = if (d.direction == .capture) .playback else .capture;
        var opposite_enumerated = false;
        for (devices) |other| {
            if (other.id == d.id and other.direction == opposite) opposite_enumerated = true;
        }
        if (!opposite_enumerated) {
            try testing.expectError(audio.OpenError.NoSuchDevice, host.openStream(d.id, opposite, .{ .sample_rate_hz = 48_000, .channels = 1, .encoding = .s16 }));
        }
    }

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
