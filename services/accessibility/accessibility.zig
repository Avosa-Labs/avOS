//! Deciding whether an accessibility service may observe the screen or act on a
//! person's behalf, because that power is exactly what malware wants, so it is
//! granted narrowly and never assumed.
//!
//! Accessibility services are among the most powerful things a device can run: to
//! read a screen aloud or drive it for someone who cannot, they see everything
//! displayed and can inject the taps and text a person would. That is indispensable
//! for the people who rely on it and catastrophic in the wrong hands — the same
//! reach that voices an interface can scrape a password field and authorise a
//! transfer. So the power is not ambient. A service does nothing until the person
//! explicitly enables it, the observe and act capabilities are separate so a
//! screen-reader that only needs to see is not also handed the ability to click, and
//! a service that was granted its power cannot quietly keep it after the person turns
//! it off. The result is that accessibility works fully for those who choose it and
//! is inert for everything the person did not choose.
//!
//! This module observes and acts on nothing. It decides whether a given
//! accessibility capability may be exercised, from the service's enabled state and
//! its granted capabilities, as a pure function so the gate is one place.

const std = @import("std");

/// A capability an accessibility service may hold. Separated so a service is granted
/// only what it needs.
pub const Capability = enum {
    /// Read the content of the screen: text, structure, focus. What a screen reader
    /// needs.
    observe,
    /// Perform actions on the person's behalf: tap, scroll, enter text. What a
    /// switch-control or voice-driven navigator needs.
    act,
};

/// An accessibility service's state as the person configured it.
pub const Service = struct {
    /// Whether the person has enabled this service at all. A disabled service does
    /// nothing, whatever it was once granted.
    enabled: bool,
    /// The capabilities the person granted it. Empty until granted, and consulted
    /// only while enabled.
    granted: std.EnumSet(Capability),
};

/// Whether a service may exercise a capability.
///
/// A disabled service may do nothing, so turning a service off is complete — it does
/// not retain a capability it was once given. An enabled service may exercise only
/// the capabilities the person granted it, so a screen reader granted observe cannot
/// also act. Both conditions are required, which is what keeps this power to exactly
/// what the person chose.
pub fn permits(service: Service, capability: Capability) bool {
    if (!service.enabled) return false;
    return service.granted.contains(capability);
}

fn withGrants(enabled: bool, grants: []const Capability) Service {
    var granted: std.EnumSet(Capability) = .initEmpty();
    for (grants) |grant| granted.insert(grant);
    return .{ .enabled = enabled, .granted = granted };
}

test "an enabled service exercises its granted capabilities" {
    const reader = withGrants(true, &.{.observe});
    try std.testing.expect(permits(reader, .observe));
}

test "a service does not get capabilities it was not granted" {
    // A screen reader granted only observe cannot act.
    const reader = withGrants(true, &.{.observe});
    try std.testing.expect(!permits(reader, .act));
}

test "a disabled service does nothing, whatever it was granted" {
    // Both capabilities granted, but disabled: it exercises neither.
    const disabled = withGrants(false, &.{ .observe, .act });
    try std.testing.expect(!permits(disabled, .observe));
    try std.testing.expect(!permits(disabled, .act));
}

test "a fully granted enabled service may observe and act" {
    const navigator = withGrants(true, &.{ .observe, .act });
    try std.testing.expect(permits(navigator, .observe));
    try std.testing.expect(permits(navigator, .act));
}

test "a service with no grants does nothing even when enabled" {
    const empty = withGrants(true, &.{});
    try std.testing.expect(!permits(empty, .observe));
    try std.testing.expect(!permits(empty, .act));
}

test "nothing is permitted while disabled, swept" {
    // The off-is-complete property: across every grant combination, a disabled
    // service permits nothing.
    const grant_sets = [_][]const Capability{ &.{}, &.{.observe}, &.{.act}, &.{ .observe, .act } };
    for (grant_sets) |grants| {
        const service = withGrants(false, grants);
        try std.testing.expect(!permits(service, .observe));
        try std.testing.expect(!permits(service, .act));
    }
}

test "a permitted capability is always both enabled and granted, swept" {
    const grant_sets = [_][]const Capability{ &.{}, &.{.observe}, &.{.act}, &.{ .observe, .act } };
    for ([_]bool{ false, true }) |enabled| {
        for (grant_sets) |grants| {
            const service = withGrants(enabled, grants);
            for ([_]Capability{ .observe, .act }) |capability| {
                if (permits(service, capability)) {
                    try std.testing.expect(enabled and service.granted.contains(capability));
                }
            }
        }
    }
}
