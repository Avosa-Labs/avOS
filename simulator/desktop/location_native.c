// The device's real location on non-Apple platforms.
//
// Accurate device location comes from each operating system's own location service — there is no
// portable, keyless GPS call that works everywhere. Apple hosts use CoreLocation (location_apple.m);
// this file provides the same entry point for every other platform, so the shell links and runs the
// identical way on all of them and never gates the feature to one OS.
//
// A platform whose native service is wired reports an accurate fix here; a platform without one reports
// "unavailable", and the shell falls back to the cross-platform IP lookup — which works everywhere but
// is only city-accurate. Linux (GeoClue over D-Bus) and Windows (the Geolocation API) slot in behind
// the guards below; until a host wires one, the portable IP path covers it. Nothing is ever fabricated:
// a non-zero return means "no accurate fix", not a guessed place.

// Writes the device's current coordinate to *out_lat/*out_lon and its locality name into city_buf
// (NUL-terminated). Returns 0 on success, non-zero when no native fix is available on this platform.
int device_current_location(double *out_lat, double *out_lon, char *city_buf, int city_cap) {
    (void)out_lat;
    (void)out_lon;
    if (city_cap > 0) city_buf[0] = '\0';

#if defined(__linux__)
    // A Linux desktop's accurate location is GeoClue2 over D-Bus. It is added here behind this guard
    // when the D-Bus client is available; until then the shell uses the portable IP fallback.
    return 2;
#elif defined(_WIN32)
    // A Windows host's accurate location is the Windows.Devices.Geolocation API. It is added here behind
    // this guard; until then the shell uses the portable IP fallback.
    return 2;
#else
    return 2;
#endif
}
