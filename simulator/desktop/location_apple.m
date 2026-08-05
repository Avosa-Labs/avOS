// The device's real location on Apple platforms, from CoreLocation — GPS and Wi-Fi positioning,
// accurate to the place the device actually is, not the coarse city an IP address resolves to. This is
// the Apple backend of the cross-platform `device_current_location` entry point; other platforms
// implement the same signature in location_native.c.
//
// The weather app prefers this over the IP fallback so it reads the real locale. CoreLocation delivers
// a fix asynchronously through a delegate on a run loop; this bridges it to one synchronous call the
// Zig shell makes at start: it starts the manager, spins the run loop until a fix arrives or a short
// deadline passes, then reverse-geocodes the coordinate to a locality name. A denied authorization or a
// timeout returns a non-zero code, and the shell falls back to the IP lookup — never a fabricated place.
//
// Location Services must be enabled for the running application (System Settings → Privacy & Security →
// Location Services); until then this returns unavailable and the coarse fallback stands.

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

@interface DeviceLocationSink : NSObject <CLLocationManagerDelegate>
@property (nonatomic) BOOL settled;
@property (nonatomic) BOOL located;
@property (nonatomic) double latitude;
@property (nonatomic) double longitude;
@end

@implementation DeviceLocationSink
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *fix = locations.lastObject;
    if (fix != nil) {
        self.latitude = fix.coordinate.latitude;
        self.longitude = fix.coordinate.longitude;
        self.located = YES;
        self.settled = YES;
    }
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    self.settled = YES;
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.settled = YES;
    }
}
@end

// Spins the current run loop until `predicate` settles or the deadline passes.
static void pump_until(BOOL (^settled)(void), NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!settled() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}

// Writes the device's current coordinate to *out_lat/*out_lon and its locality name into city_buf
// (NUL-terminated). Returns 0 on success, non-zero when location is unavailable or unauthorized.
int device_current_location(double *out_lat, double *out_lon, char *city_buf, int city_cap) {
    @autoreleasepool {
        if (![CLLocationManager locationServicesEnabled]) return 1;

        DeviceLocationSink *sink = [[DeviceLocationSink alloc] init];
        CLLocationManager *manager = [[CLLocationManager alloc] init];
        manager.delegate = sink;
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        [manager requestWhenInUseAuthorization];
        [manager startUpdatingLocation];
        pump_until(^BOOL { return sink.settled; }, 8.0);
        [manager stopUpdatingLocation];
        if (!sink.located) return 2;

        *out_lat = sink.latitude;
        *out_lon = sink.longitude;
        if (city_cap > 0) city_buf[0] = '\0';

        // Reverse-geocode the coordinate to a locality name, best-effort.
        CLGeocoder *geocoder = [[CLGeocoder alloc] init];
        CLLocation *point = [[CLLocation alloc] initWithLatitude:sink.latitude longitude:sink.longitude];
        __block BOOL named = NO;
        [geocoder reverseGeocodeLocation:point completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
            CLPlacemark *place = placemarks.firstObject;
            NSString *name = place.locality ?: place.subAdministrativeArea ?: place.administrativeArea;
            if (name != nil && city_cap > 1) {
                const char *utf8 = name.UTF8String;
                strncpy(city_buf, utf8, (size_t)(city_cap - 1));
                city_buf[city_cap - 1] = '\0';
            }
            named = YES;
        }];
        pump_until(^BOOL { return named; }, 4.0);
        return 0;
    }
}
