//! Deciding whether a device on a release channel may install a build, so a device tracking the stable
//! channel is never handed a build that has not earned stable, and no device moves backward.
//!
//! Devices subscribe to a release channel — development, beta, or stable — that expresses how much
//! risk the person accepts. A build carries the maturity it has reached, and the channel is a promise
//! about the minimum maturity a device on it will be offered: a stable device receives only builds that
//! reached stable, a beta device receives beta or stable builds, a development device receives anything.
//! A build too immature for a device's channel is not offered, because the whole reason a person chose
//! stable is to not receive unproven builds. Independently, no channel offers a build older than the one
//! already installed: a version that would move the device backward is refused regardless of channel, so
//! switching or tracking a channel never downgrades. A build is offered exactly when it meets the
//! channel's maturity floor and advances the device's version — which keeps a channel an honest promise
//! rather than a label a device can be talked past.
//!
//! This module installs nothing. It decides whether a build is offered to a device, from the build's
//! maturity and version against the device's channel and installed version, as a pure function.

const std = @import("std");

/// A release channel, ordered by how much maturity it requires.
pub const Channel = enum(u2) {
    development = 0,
    beta = 1,
    stable = 2,
};

/// The maturity a build has reached, on the same scale as the channels.
pub const Maturity = enum(u2) {
    development = 0,
    beta = 1,
    stable = 2,
};

/// A build presented to a device.
pub const Build = struct {
    maturity: Maturity,
    version: u32,
};

/// Whether a build meets a channel's maturity floor.
fn meetsChannel(maturity: Maturity, channel: Channel) bool {
    return @intFromEnum(maturity) >= @intFromEnum(channel);
}

/// Whether a build is offered to a device on a channel with a given installed version.
///
/// The build must meet the channel's maturity floor — a stable device is offered only stable builds —
/// and it must advance the installed version. Either failing withholds the build, so a channel never
/// delivers an under-matured build and no offer ever moves a device backward.
pub fn mayOffer(build: Build, channel: Channel, installed_version: u32) bool {
    return meetsChannel(build.maturity, channel) and build.version > installed_version;
}

test "a stable device is offered a newer stable build" {
    try std.testing.expect(mayOffer(.{ .maturity = .stable, .version = 5 }, .stable, 4));
}

test "a stable device is not offered a beta build" {
    try std.testing.expect(!mayOffer(.{ .maturity = .beta, .version = 5 }, .stable, 4));
}

test "a beta device accepts beta and stable builds" {
    try std.testing.expect(mayOffer(.{ .maturity = .beta, .version = 5 }, .beta, 4));
    try std.testing.expect(mayOffer(.{ .maturity = .stable, .version = 5 }, .beta, 4));
}

test "no channel offers a downgrade" {
    try std.testing.expect(!mayOffer(.{ .maturity = .stable, .version = 3 }, .stable, 4));
    try std.testing.expect(!mayOffer(.{ .maturity = .development, .version = 3 }, .development, 4));
}

test "an offered build always meets the channel and advances the version, swept" {
    // The honest-channel property: an offered build meets the maturity floor and moves forward.
    const maturities = [_]Maturity{ .development, .beta, .stable };
    const channels = [_]Channel{ .development, .beta, .stable };
    for (maturities) |maturity| {
        for (channels) |channel| {
            var version: u32 = 3;
            while (version <= 6) : (version += 1) {
                if (mayOffer(.{ .maturity = maturity, .version = version }, channel, 4)) {
                    try std.testing.expect(meetsChannel(maturity, channel));
                    try std.testing.expect(version > 4);
                }
            }
        }
    }
}
