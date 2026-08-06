//! A real, keyless weather provider: the open-meteo request URLs and response parsers that turn a
//! place name into a live reading, with no API key and nothing to sign up for.
//!
//! The Weather domain reads through a provider-neutral connector; this is one real provider behind
//! that seam. Open-meteo is a free, keyless service, which is exactly why it is the one wired live:
//! there is no account to hold, so the connector can be live on a fresh device with no setup. A live
//! read is two steps — geocode the place name to coordinates, then fetch the current reading at those
//! coordinates — and each step is a URL built here and a JSON body parsed here. Both halves are pure:
//! the socket that carries the bytes between them is a transport injected by the composition, so this
//! module can be exercised end to end offline against real response payloads, and CI never depends on
//! the network. When the transport is present and reachable the connector is live; when it is not, the
//! domain falls back to its honestly-aged cache, so a live provider going offline degrades rather than
//! hangs.
//!
//! Parsing is a single pass over the body (std.json), and the code-to-condition map is a constant-time
//! switch, so turning a response into a reading is linear in the body and nothing more.

const std = @import("std");
const domain = @import("domain.zig");

pub const Reading = domain.Reading;
pub const Condition = domain.Condition;

/// A geographic coordinate open-meteo reads a forecast at.
pub const Coord = struct { latitude: f64, longitude: f64 };

pub const Error = error{ NoResults, MalformedResponse };

/// The open-meteo geocoding host and the forecast host. Named once so a URL is built from a single
/// source and a test asserts against the same string a request uses.
pub const geocoding_host = "https://geocoding-api.open-meteo.com/v1/search";
pub const forecast_host = "https://api.open-meteo.com/v1/forecast";

/// Builds the geocoding request URL for a place name into `buf`, percent-encoding the name so a space
/// or an accent cannot break the query. Returns the written URL, or an error if the buffer is too
/// small.
pub fn geocodeUrl(name: []const u8, buf: []u8) ![]const u8 {
    var encoded: [256]u8 = undefined;
    const escaped = try percentEncode(name, &encoded);
    return std.fmt.bufPrint(buf, "{s}?name={s}&count=1&format=json", .{ geocoding_host, escaped });
}

/// Builds the current-weather request URL for a coordinate into `buf`. Asks only for the two fields
/// the reading needs, so the response is small.
pub fn currentUrl(coord: Coord, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}?latitude={d}&longitude={d}&current=temperature_2m,weather_code",
        .{ forecast_host, coord.latitude, coord.longitude },
    );
}

/// Parses a geocoding response body to the first result's coordinate. An empty result set is a
/// typed error (an unknown place), not a fabricated location.
pub fn parseGeocode(gpa: std.mem.Allocator, body: []const u8) Error!Coord {
    const Shape = struct {
        results: ?[]const struct { latitude: f64, longitude: f64 } = null,
    };
    const parsed = std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true }) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const results = parsed.value.results orelse return Error.NoResults;
    if (results.len == 0) return Error.NoResults;
    return .{ .latitude = results[0].latitude, .longitude = results[0].longitude };
}

/// Parses a current-weather response body to a reading: the temperature rounded to whole degrees and
/// the WMO weather code mapped to a sky condition.
pub fn parseCurrent(gpa: std.mem.Allocator, body: []const u8) Error!Reading {
    const Shape = struct {
        current: struct { temperature_2m: f64, weather_code: u16 },
    };
    const parsed = std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true }) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const c = parsed.value.current;
    return .{ .temp_c = @intFromFloat(@round(c.temperature_2m)), .condition = conditionFromWmo(c.weather_code) };
}

/// Maps a WMO weather-interpretation code (what open-meteo reports) to the domain's sky condition.
/// A constant-time classification: clear skies, cloud and fog, any rain or drizzle, any snow, and
/// thunderstorms. An unrecognised code reads as cloudy — a neutral default, never a fabricated storm.
pub fn conditionFromWmo(code: u16) Condition {
    return switch (code) {
        0, 1 => .clear, // clear sky, mainly clear
        2, 3, 45, 48 => .cloudy, // partly cloudy, overcast, fog
        51...67, 80...82 => .rain, // drizzle, rain, rain showers
        71...77, 85, 86 => .snow, // snow fall and snow showers
        95, 96, 99 => .storm, // thunderstorm
        else => .cloudy,
    };
}

/// Percent-encodes `text` into `out`, leaving the unreserved URL characters untouched and escaping
/// everything else as %HH. A single pass over the input.
fn percentEncode(text: []const u8, out: []u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (text) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (unreserved) {
            if (n + 1 > out.len) return error.NoSpaceLeft;
            out[n] = byte;
            n += 1;
        } else {
            if (n + 3 > out.len) return error.NoSpaceLeft;
            out[n] = '%';
            out[n + 1] = hex[byte >> 4];
            out[n + 2] = hex[byte & 0x0F];
            n += 3;
        }
    }
    return out[0..n];
}

/// Builds the hourly-forecast request URL for a coordinate into `buf`, asking for `hours` hours of
/// temperature and weather code — the series the app draws as its forecast strip.
pub fn hourlyUrl(coord: Coord, hours: u16, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}?latitude={d}&longitude={d}&hourly=temperature_2m,weather_code&forecast_hours={d}",
        .{ forecast_host, coord.latitude, coord.longitude, hours },
    );
}

/// Parses an hourly response body into `out`, one reading per hour, pairing each temperature with its
/// weather code. Returns the written slice, capped at `out.len`.
pub fn parseHourly(gpa: std.mem.Allocator, body: []const u8, out: []Reading) Error![]const Reading {
    const Shape = struct {
        hourly: struct { temperature_2m: []const f64, weather_code: []const u16 },
    };
    const parsed = std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true }) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const h = parsed.value.hourly;
    const n = @min(@min(h.temperature_2m.len, h.weather_code.len), out.len);
    for (0..n) |i| out[i] = .{ .temp_c = @intFromFloat(@round(h.temperature_2m[i])), .condition = conditionFromWmo(h.weather_code[i]) };
    return out[0..n];
}

/// A transport that carries a GET to a URL and returns the response body — a seam, so this module is
/// pure and exercised offline against recorded bodies, while the running OS injects a real socket.
pub const Transport = struct {
    context: *anyopaque,
    get_fn: *const fn (context: *anyopaque, url: []const u8, out: []u8) anyerror![]const u8,

    pub fn get(transport: Transport, url: []const u8, out: []u8) ![]const u8 {
        return transport.get_fn(transport.context, url, out);
    }
};

/// Fetches the live current reading at a coordinate through `transport`.
pub fn fetchCurrent(gpa: std.mem.Allocator, transport: Transport, coord: Coord) !Reading {
    var url_buf: [256]u8 = undefined;
    var body_buf: [8192]u8 = undefined;
    const url = try currentUrl(coord, &url_buf);
    const body = try transport.get(url, &body_buf);
    return parseCurrent(gpa, body);
}

/// Fetches the live hourly forecast at a coordinate through `transport`, into `out`.
pub fn fetchHourly(gpa: std.mem.Allocator, transport: Transport, coord: Coord, out: []Reading) ![]const Reading {
    var url_buf: [256]u8 = undefined;
    var body_buf: [16384]u8 = undefined;
    const url = try hourlyUrl(coord, @intCast(out.len), &url_buf);
    const body = try transport.get(url, &body_buf);
    return parseHourly(gpa, body, out);
}

// --- Tests ---

const testing = std.testing;

test "the geocoding URL carries the place name, percent-encoded" {
    var buf: [256]u8 = undefined;
    const url = try geocodeUrl("São Paulo", &buf);
    // The host and the count are fixed; the space and the accented byte are escaped, never raw.
    try testing.expect(std.mem.startsWith(u8, url, geocoding_host ++ "?name="));
    try testing.expect(std.mem.indexOf(u8, url, "%20") != null); // the space
    try testing.expect(std.mem.indexOfScalar(u8, url, ' ') == null); // no raw space survives
    try testing.expect(std.mem.endsWith(u8, url, "&count=1&format=json"));
}

test "the current-weather URL asks for exactly the two fields a reading needs" {
    var buf: [256]u8 = undefined;
    const url = try currentUrl(.{ .latitude = 38.72, .longitude = -9.13 }, &buf);
    try testing.expect(std.mem.startsWith(u8, url, forecast_host ++ "?latitude="));
    try testing.expect(std.mem.indexOf(u8, url, "current=temperature_2m,weather_code") != null);
    try testing.expect(std.mem.indexOf(u8, url, "longitude=-9.13") != null);
}

test "a geocoding response parses to its first coordinate; an empty one is a typed miss" {
    const gpa = testing.allocator;
    const body =
        \\{"results":[{"latitude":38.7167,"longitude":-9.1333,"name":"Lisbon"},{"latitude":1,"longitude":2}]}
    ;
    const coord = try parseGeocode(gpa, body);
    try testing.expectApproxEqAbs(@as(f64, 38.7167), coord.latitude, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -9.1333), coord.longitude, 1e-6);
    // No results — an unknown place — is a typed error, not a fabricated (0,0).
    try testing.expectError(Error.NoResults, parseGeocode(gpa, "{\"results\":[]}"));
    try testing.expectError(Error.NoResults, parseGeocode(gpa, "{}"));
}

test "a current-weather response parses to a rounded reading with the mapped condition" {
    const gpa = testing.allocator;
    const body =
        \\{"latitude":38.75,"current":{"time":"2026-07-30T00:00","temperature_2m":19.4,"weather_code":3}}
    ;
    const reading = try parseCurrent(gpa, body);
    try testing.expectEqual(@as(i16, 19), reading.temp_c); // 19.4 rounds to 19
    try testing.expectEqual(Condition.cloudy, reading.condition); // code 3 is overcast
    // A malformed body is refused, not read as zero.
    try testing.expectError(Error.MalformedResponse, parseCurrent(gpa, "not json"));
}

test "WMO codes map to the domain's five conditions, with a neutral default" {
    try testing.expectEqual(Condition.clear, conditionFromWmo(0));
    try testing.expectEqual(Condition.cloudy, conditionFromWmo(45)); // fog
    try testing.expectEqual(Condition.rain, conditionFromWmo(61)); // rain
    try testing.expectEqual(Condition.rain, conditionFromWmo(81)); // rain showers
    try testing.expectEqual(Condition.snow, conditionFromWmo(73)); // snow
    try testing.expectEqual(Condition.snow, conditionFromWmo(86)); // snow showers
    try testing.expectEqual(Condition.storm, conditionFromWmo(95)); // thunderstorm
    try testing.expectEqual(Condition.cloudy, conditionFromWmo(999)); // unknown → neutral, not a storm
}

test "the round trip: a geocode body then a current body yields a live reading" {
    const gpa = testing.allocator;
    // What a real pair of open-meteo responses looks like, parsed end to end offline.
    const geo =
        \\{"results":[{"latitude":40.7128,"longitude":-74.006,"name":"New York"}]}
    ;
    const coord = try parseGeocode(gpa, geo);
    var buf: [256]u8 = undefined;
    const url = try currentUrl(coord, &buf);
    try testing.expect(std.mem.indexOf(u8, url, "latitude=40.7128") != null);
    const cur =
        \\{"current":{"temperature_2m":-2.6,"weather_code":71}}
    ;
    const reading = try parseCurrent(gpa, cur);
    try testing.expectEqual(@as(i16, -3), reading.temp_c); // -2.6 rounds to -3
    try testing.expectEqual(Condition.snow, reading.condition);
}

test "the hourly URL asks for the temperature and code series over a bounded window" {
    var buf: [256]u8 = undefined;
    const url = try hourlyUrl(.{ .latitude = 47.61, .longitude = -122.33 }, 6, &buf);
    try testing.expect(std.mem.indexOf(u8, url, "hourly=temperature_2m,weather_code") != null);
    try testing.expect(std.mem.indexOf(u8, url, "forecast_hours=6") != null);
}

test "an hourly body parses to a series pairing each temperature with its code" {
    const gpa = testing.allocator;
    const body =
        \\{"hourly":{"time":["a","b","c"],"temperature_2m":[11.7,12.4,13.6],"weather_code":[0,3,61]}}
    ;
    var out: [6]Reading = undefined;
    const series = try parseHourly(gpa, body, &out);
    try testing.expectEqual(@as(usize, 3), series.len);
    try testing.expectEqual(@as(i16, 12), series[0].temp_c); // 11.7 rounds to 12
    try testing.expectEqual(Condition.clear, series[0].condition); // code 0
    try testing.expectEqual(Condition.cloudy, series[1].condition); // code 3
    try testing.expectEqual(Condition.rain, series[2].condition); // code 61
}

// A fake transport that replies with a fixed body, so fetch is exercised end to end offline.
const FakeTransport = struct {
    body: []const u8,
    fn get(context: *anyopaque, url: []const u8, out: []u8) anyerror![]const u8 {
        _ = url;
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        @memcpy(out[0..self.body.len], self.body);
        return out[0..self.body.len];
    }
    fn transport(self: *FakeTransport) Transport {
        return .{ .context = self, .get_fn = get };
    }
};

test "fetchCurrent carries a coordinate through the transport and parses the reply" {
    var fake = FakeTransport{ .body = "{\"current\":{\"temperature_2m\":18.2,\"weather_code\":2}}" };
    const reading = try fetchCurrent(testing.allocator, fake.transport(), .{ .latitude = 47.6, .longitude = -122.3 });
    try testing.expectEqual(@as(i16, 18), reading.temp_c);
    try testing.expectEqual(Condition.cloudy, reading.condition);
}
