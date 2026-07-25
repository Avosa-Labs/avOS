//! Whether the Android runtime image is present and usable on this device, reported
//! honestly, so a feature that needs it is refused up front rather than half-started.
//!
//! Running Android applications needs a runtime image — an AOSP system built for a
//! virtual device, provisioned onto the host. That image is large, optional, and not
//! present on every device or in every build. The temptation is to assume it is there
//! and discover otherwise deep inside a launch; the cost is a half-provisioned
//! application and an error that does not name the real problem. This module makes the
//! image's state a first-class question answered before anything depends on it: the
//! image is absent, present but not yet provisioned, or ready — and only a ready image
//! admits a launch. An honest "not available" here is worth more than an optimistic
//! attempt that fails later, because a caller can offer the person a real choice —
//! provision it, or do without — instead of a stack of failures.
//!
//! This module tracks the image's state and gates readiness; it provisions nothing
//! itself. Fetching and installing the image is the host's, driven by the transitions
//! this module defines.

const std = @import("std");

/// The state of the Android runtime image on this device.
pub const State = enum {
    /// No image is present. Android applications cannot run until one is provisioned.
    absent,
    /// An image is present but not yet provisioned into a runnable device.
    present,
    /// The image is provisioned and a device can boot from it.
    ready,

    /// Whether a launch may proceed against an image in this state.
    pub fn admitsLaunch(state: State) bool {
        return state == .ready;
    }
};

/// Why an image operation was refused.
pub const Error = error{
    /// No image is present to provision or boot.
    ImageAbsent,
    /// The image is present but not provisioned into a runnable device.
    NotProvisioned,
    /// The transition is not valid from the image's current state.
    InvalidTransition,
};

/// The image seam: the image's state and the transitions over it.
pub const Image = struct {
    state: State = .absent,
    /// A stable tag for the image build, e.g. an architecture-and-version string.
    /// Empty until an image is present.
    build_tag: []const u8 = "",

    pub fn init() Image {
        return .{};
    }

    /// Records that an image build is now present, ready to be provisioned.
    pub fn markPresent(image: *Image, build_tag: []const u8) void {
        image.state = .present;
        image.build_tag = build_tag;
    }

    /// Provisions a present image into a runnable device. Refused if no image is
    /// present: there is nothing to provision.
    pub fn provision(image: *Image) Error!void {
        if (image.state == .absent) return error.ImageAbsent;
        image.state = .ready;
    }

    /// Removes the image, returning to absent. A device that needs to reclaim the
    /// space, or replace the image, passes through here.
    pub fn evict(image: *Image) void {
        image.state = .absent;
        image.build_tag = "";
    }

    /// Confirms the image is ready to boot a device, naming the specific gap when it
    /// is not, so a caller can act on the real reason.
    pub fn requireReady(image: Image) Error!void {
        return switch (image.state) {
            .absent => error.ImageAbsent,
            .present => error.NotProvisioned,
            .ready => {},
        };
    }
};

// --- Tests ---

const testing = std.testing;

test "an absent image admits no launch and names the gap" {
    const image = Image.init();
    try testing.expect(!image.state.admitsLaunch());
    try testing.expectError(error.ImageAbsent, image.requireReady());
}

test "a present but unprovisioned image is not ready to boot" {
    var image = Image.init();
    image.markPresent("arm64-v14");
    try testing.expect(!image.state.admitsLaunch());
    try testing.expectError(error.NotProvisioned, image.requireReady());
}

test "provisioning a present image makes it ready" {
    var image = Image.init();
    image.markPresent("arm64-v14");
    try image.provision();
    try testing.expect(image.state.admitsLaunch());
    try image.requireReady();
    try testing.expectEqualStrings("arm64-v14", image.build_tag);
}

test "provisioning with no image present is refused" {
    var image = Image.init();
    try testing.expectError(error.ImageAbsent, image.provision());
}

test "evicting an image returns it to absent" {
    var image = Image.init();
    image.markPresent("arm64-v14");
    try image.provision();
    image.evict();
    try testing.expectEqual(State.absent, image.state);
    try testing.expectError(error.ImageAbsent, image.requireReady());
}
