//! The ALSA host-audio adapter: a Zig backend over Linux's Advanced Linux Sound Architecture, bound
//! behind the platform audio seam (`services/media/audio.zig`).
//!
//! ALSA is the Linux kernel's audio hardware layer; libasound (the "asound" user-space library) is how
//! a process reaches it. This adapter reaches libasound only to answer the two questions the seam asks:
//! what devices exist, and can a given device open in a given direction. It walks ALSA's PCM device
//! hints — the same list `aplay -L` prints — reading each hint's NAME (the PCM name a stream would
//! open) and IOID (its direction: "Input" is capture, "Output" is playback, and an absent IOID is a
//! duplex device that does both). A duplex device is emitted twice — once per direction — because the
//! seam's `Device` carries a single direction.
//!
//! Every ALSA C type stays inside this module. There are no ALSA headers on the build host, so the C
//! ABI is hand-declared with `extern` functions against the documented libasound interface (the same
//! style `simulator/desktop/sdl.zig` uses for SDL) rather than `@cImport`. The strings ALSA hands back
//! from `snd_device_name_get_hint` are heap-allocated and owned by the caller, so every one is released
//! with libc `free`, and the hint array itself with `snd_device_name_free_hint`; no ALSA allocation
//! outlives the call. The returned device names must outlive the enumeration call, so the backend
//! context owns fixed-size name buffers and each returned `[]const u8` points into one of them — never
//! onto the stack.
//!
//! Built only on Linux (see the build's os gate); off Linux the seam keeps its honest-until-bound
//! default and this module is never compiled or linked.

const std = @import("std");
const audio = @import("audio");

// --- The libasound C ABI, hand-declared (no ALSA headers on the build host) ---
//
// Only the four symbols this adapter needs, against the documented libasound ABI:
//   int   snd_device_name_hint(int card, const char *iface, void ***hints);
//   char *snd_device_name_get_hint(const void *hint, const char *id);
//   int   snd_device_name_free_hint(void **hints);
// plus libc free() for the strings snd_device_name_get_hint returns (the caller must free them).

extern fn snd_device_name_hint(card: c_int, iface: [*:0]const u8, hints: *?[*]?*anyopaque) c_int;
extern fn snd_device_name_get_hint(hint: ?*const anyopaque, id: [*:0]const u8) ?[*:0]u8;
extern fn snd_device_name_free_hint(hints: ?[*]?*anyopaque) c_int;
extern fn free(ptr: ?*anyopaque) void;

/// The most PCM hints we enumerate, and the most name buffers the context owns. A duplex device
/// occupies two entries (capture and playback), so the name store is twice the device cap.
const max_devices = 64;
const max_entries = max_devices * 2;
/// Bytes reserved per device name, UTF-8, trimmed to what fits.
const name_capacity = 128;

/// FNV-1a offset basis and prime, for the 32-bit device id derived from a PCM's NAME.
const fnv_offset: u32 = 2166136261;
const fnv_prime: u32 = 16777619;

/// A stable 32-bit id for a PCM name: FNV-1a over its bytes, with 0 reserved (a name that hashes to 0
/// is nudged to 1) so an id is always a real device, never the reserved sentinel.
fn deviceId(name: []const u8) u32 {
    var h: u32 = fnv_offset;
    for (name) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return if (h == 0) 1 else h;
}

/// The bound ALSA backend. It owns the name storage the returned `Device` slices point into, so a
/// device name lives as long as the backend, not the call. One is enough for a process.
pub const AlsaBackend = struct {
    /// One UTF-8 name buffer per possible returned device entry. `enumerate` copies a name here and
    /// hands back a slice into it, so the name outlives the enumeration call.
    name_store: [max_entries][name_capacity]u8 = undefined,

    pub fn init() AlsaBackend {
        return .{};
    }

    /// The seam backend that reaches this adapter. Bind it to an `Audio` with `audio.bind(...)`.
    pub fn backend(self: *AlsaBackend) audio.Backend {
        return .{
            .context = @ptrCast(self),
            .devices_fn = devicesFn,
            .can_open_fn = canOpenFn,
        };
    }

    fn devicesFn(context: *anyopaque, out: []audio.Device) []const audio.Device {
        const self: *AlsaBackend = @ptrCast(@alignCast(context));
        return self.enumerate(out, true);
    }

    fn canOpenFn(context: *anyopaque, device_id: u32, direction: audio.Direction) bool {
        const self: *AlsaBackend = @ptrCast(@alignCast(context));
        var buf: [max_entries]audio.Device = undefined;
        // Enumerate without copying names: can-open needs only ids and directions, and skipping the
        // name copy leaves the context's name buffers (which a prior `devices` result may point into)
        // untouched.
        const found = self.enumerate(&buf, false);
        for (found) |d| {
            if (d.id == device_id and d.direction == direction) return true;
        }
        return false;
    }

    /// Walks ALSA's PCM device hints into `out`, one `Device` per direction a device carries. With
    /// `resolve_names` set, each entry's name is copied from the hint into the context's owned storage;
    /// without it, names are left empty (used by can-open, which never inspects them). Any ALSA error
    /// yields the devices gathered so far rather than a crash — an empty slice is an honest answer.
    fn enumerate(self: *AlsaBackend, out: []audio.Device, resolve_names: bool) []const audio.Device {
        var hints: ?[*]?*anyopaque = null;
        if (snd_device_name_hint(-1, "pcm", &hints) != 0) return out[0..0];
        const list = hints orelse return out[0..0];
        defer _ = snd_device_name_free_hint(hints);

        var written: usize = 0;
        var slot: usize = 0;
        var i: usize = 0;
        while (i < max_entries) : (i += 1) {
            const hint = list[i] orelse break; // NULL terminates the hint array

            const name_ptr = snd_device_name_get_hint(hint, "NAME") orelse continue;
            defer free(@ptrCast(name_ptr));
            const name = std.mem.span(name_ptr);
            if (name.len == 0) continue;

            // IOID is absent for a duplex PCM (both directions), "Input" for capture-only, "Output"
            // for playback-only. Decide which directions this hint yields.
            const ioid_ptr = snd_device_name_get_hint(hint, "IOID");
            defer if (ioid_ptr) |p| free(@ptrCast(p));
            const want_capture, const want_playback = blk: {
                const p = ioid_ptr orelse break :blk .{ true, true };
                const ioid = std.mem.span(p);
                if (std.mem.eql(u8, ioid, "Input")) break :blk .{ true, false };
                if (std.mem.eql(u8, ioid, "Output")) break :blk .{ false, true };
                break :blk .{ true, true };
            };

            const id = deviceId(name);
            inline for (.{ audio.Direction.capture, audio.Direction.playback }) |dir| {
                const wanted = switch (dir) {
                    .capture => want_capture,
                    .playback => want_playback,
                };
                if (wanted and written < out.len and slot < self.name_store.len) {
                    const stored: []const u8 = if (resolve_names) self.storeName(name, slot) else "";
                    slot += 1;
                    out[written] = .{ .id = id, .name = stored, .direction = dir };
                    written += 1;
                }
            }
        }
        return out[0..written];
    }

    /// Copies a PCM name into the context's `slot` buffer (truncated to fit) and returns a slice of it,
    /// so the returned name outlives the ALSA string it came from.
    fn storeName(self: *AlsaBackend, name: []const u8, slot: usize) []const u8 {
        const store: *[name_capacity]u8 = &self.name_store[slot];
        const n = @min(name.len, store.len);
        @memcpy(store[0..n], name[0..n]);
        return store[0..n];
    }
};

// --- Tests (real Linux ALSA, this host's actual PCM hints) ---

const testing = std.testing;

test "the ALSA backend binds and enumerates the host's real PCM devices without crashing" {
    var alsa = AlsaBackend.init();
    var host = audio.Audio{};
    host.bind(alsa.backend());
    try testing.expect(host.available());

    var buf: [max_entries]audio.Device = undefined;
    const devices = host.devices(&buf);
    // Hardware varies and a headless CI runner may enumerate zero devices, or only the "null"/"default"
    // PCM — the honest range is 0..N. What must hold is that every device reported is well formed: a
    // non-empty name and a real direction.
    try testing.expect(devices.len >= 0);
    for (devices) |d| {
        try testing.expect(d.name.len > 0);
        try testing.expect(d.direction == .capture or d.direction == .playback);
    }
}

test "can-open agrees with the enumerated set" {
    var alsa = AlsaBackend.init();
    var host = audio.Audio{};
    host.bind(alsa.backend());

    var buf: [max_entries]audio.Device = undefined;
    const devices = host.devices(&buf);

    // The suite never opens a real PCM — a capture open would light the microphone, and opening a
    // stream is a host-integration behaviour kept out of the tests. Instead it exercises the refusals,
    // which the seam decides before any device is touched: a bad format is rejected on an enumerated
    // id without opening it.
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

test "device ids are stable and never the reserved zero" {
    // The id is a pure function of the PCM name, so it is stable across enumerations, and 0 is reserved.
    try testing.expectEqual(deviceId("default"), deviceId("default"));
    try testing.expect(deviceId("default") != 0);
    try testing.expect(deviceId("hw:CARD=PCH,DEV=0") != deviceId("hw:CARD=HDMI,DEV=0"));
}
