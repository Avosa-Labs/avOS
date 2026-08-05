//! The device's current location, from a keyless network lookup — so the weather app opens on where
//! the device actually is, never a hardcoded city.
//!
//! Resolving the location is one request to a keyless geolocation service and one parse of its JSON,
//! both here. The request goes over the same injected transport the forecast uses, so this is pure and
//! exercised offline against a recorded body while the running OS carries a real socket. A failed or
//! empty lookup is a typed error, not a fabricated coordinate — with no location the weather app says
//! so rather than showing a made-up place.

const std = @import("std");
const open_meteo = @import("open_meteo.zig");

pub const Transport = open_meteo.Transport;
pub const Coord = open_meteo.Coord;

pub const Error = error{ Unavailable, MalformedResponse };

/// The keyless geolocation host. Named once so the request and a test assert against one string.
pub const host = "http://ip-api.com/json/?fields=status,city,lat,lon";

/// A resolved location: the coordinate to forecast at, and the city name to show and to hold the
/// reading under. The city bytes are copied into the caller's `city_buf`.
pub const Located = struct { coord: Coord, city: []const u8 };

/// Parses a geolocation response body into a coordinate and a city name copied into `city_buf`. A
/// non-success status is a typed error, never a guessed place.
pub fn parse(gpa: std.mem.Allocator, body: []const u8, city_buf: []u8) Error!Located {
    const Shape = struct {
        status: []const u8 = "",
        city: []const u8 = "",
        lat: f64 = 0,
        lon: f64 = 0,
    };
    const parsed = std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true }) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const v = parsed.value;
    if (!std.mem.eql(u8, v.status, "success") or v.city.len == 0) return Error.Unavailable;
    const n = @min(v.city.len, city_buf.len);
    @memcpy(city_buf[0..n], v.city[0..n]);
    return .{ .coord = .{ .latitude = v.lat, .longitude = v.lon }, .city = city_buf[0..n] };
}

/// Resolves the device's current location through `transport`, copying the city into `city_buf`.
pub fn fetch(gpa: std.mem.Allocator, transport: Transport, city_buf: []u8) !Located {
    var body_buf: [4096]u8 = undefined;
    const body = try transport.get(host, &body_buf);
    return parse(gpa, body, city_buf);
}

const testing = std.testing;

test "a successful geolocation body parses to a coordinate and the real city name" {
    var city: [64]u8 = undefined;
    const body =
        \\{"status":"success","city":"Seattle","lat":47.6062,"lon":-122.332}
    ;
    const located = try parse(testing.allocator, body, &city);
    try testing.expectEqualStrings("Seattle", located.city);
    try testing.expectApproxEqAbs(@as(f64, 47.6062), located.coord.latitude, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -122.332), located.coord.longitude, 1e-6);
}

test "a failed lookup is a typed error, not a fabricated location" {
    var city: [64]u8 = undefined;
    try testing.expectError(Error.Unavailable, parse(testing.allocator, "{\"status\":\"fail\"}", &city));
    try testing.expectError(Error.Unavailable, parse(testing.allocator, "{\"status\":\"success\",\"city\":\"\"}", &city));
    try testing.expectError(Error.MalformedResponse, parse(testing.allocator, "not json", &city));
}
