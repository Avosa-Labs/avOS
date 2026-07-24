//! Translating a web permission request into a host capability request, so a page's
//! Permissions-API ask means nothing until the host decides it, exactly as for any
//! other principal.
//!
//! A web page asks for things — the camera, the microphone, location, notifications —
//! through the browser's Permissions API. On an ordinary browser that prompt is the
//! whole authority story. Here it is only the beginning: a web permission is a
//! statement inside the web platform's model, and it confers nothing on this host until
//! it is translated into a host capability request that the host grants or denies like
//! any other. The translation is deliberate and closed. A permission with a host
//! equivalent becomes a request for that host resource, marked consequential where the
//! host would want a person in the loop; a permission this host does not express is
//! refused rather than approximated by the nearest capability that happens to exist,
//! because approximating "record audio" with some adjacent grant is how a page ends up
//! with authority nobody meant to give it.
//!
//! This module grants nothing. It maps a web permission name to the host request it
//! becomes, or refuses it, as a pure function over a closed translation table.

const std = @import("std");

/// The host resource a web permission maps to, in this system's vocabulary. A
/// translated request still faces host policy; this only says what is being asked for.
pub const Request = struct {
    /// The host resource kind.
    resource_kind: []const u8,
    /// Whether granting it is consequential enough that the host wants a person to
    /// decide.
    requires_human_decision: bool,
    /// Whether the granted operation must keep data on the device.
    local_only: bool,
};

/// Why a web permission was not translated.
pub const Refusal = enum {
    /// The permission has no equivalent on this host, so it is refused rather than
    /// approximated.
    no_host_equivalent,
    /// The permission name is empty or over the bound.
    invalid_name,
};

/// The largest permission name accepted. Names come from page content, outside this
/// system, so their length is bounded before use.
pub const max_name_bytes: usize = 64;

/// The outcome of translating a web permission.
pub const Translation = union(enum) {
    /// The permission becomes this host request.
    request: Request,
    /// The permission is refused.
    refuse: Refusal,

    pub fn translated(translation: Translation) bool {
        return translation == .request;
    }
};

const Entry = struct {
    name: []const u8,
    request: Request,
};

/// The closed set of web permissions this host knows how to translate. A permission
/// absent from this table is refused, so the web authority this host expresses is
/// exactly what has been considered.
const table = [_]Entry{
    .{ .name = "camera", .request = .{ .resource_kind = "camera", .requires_human_decision = true, .local_only = false } },
    .{ .name = "microphone", .request = .{ .resource_kind = "microphone", .requires_human_decision = true, .local_only = false } },
    .{ .name = "geolocation", .request = .{ .resource_kind = "location", .requires_human_decision = true, .local_only = false } },
    .{ .name = "notifications", .request = .{ .resource_kind = "notification", .requires_human_decision = false, .local_only = true } },
    .{ .name = "clipboard-read", .request = .{ .resource_kind = "clipboard", .requires_human_decision = true, .local_only = true } },
};

/// Translates a web permission name into a host request, or refuses it.
///
/// An empty or over-long name is invalid. A name in the closed table becomes the host
/// request it maps to; anything else is refused as having no host equivalent, never
/// approximated by a nearby capability. The host still decides the resulting request;
/// translation only fixes what is being asked for.
pub fn translate(name: []const u8) Translation {
    if (name.len == 0 or name.len > max_name_bytes) return .{ .refuse = .invalid_name };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return .{ .request = entry.request };
    }
    return .{ .refuse = .no_host_equivalent };
}

test "a known permission translates to its host request" {
    switch (translate("camera")) {
        .request => |request| {
            try std.testing.expectEqualStrings("camera", request.resource_kind);
            try std.testing.expect(request.requires_human_decision);
        },
        .refuse => return error.TestUnexpectedResult,
    }
}

test "notifications translate as non-consequential and local-only" {
    switch (translate("notifications")) {
        .request => |request| {
            try std.testing.expect(!request.requires_human_decision);
            try std.testing.expect(request.local_only);
        },
        .refuse => return error.TestUnexpectedResult,
    }
}

test "an unknown permission is refused, not approximated" {
    try std.testing.expectEqual(Translation{ .refuse = .no_host_equivalent }, translate("read-all-files"));
}

test "an empty or over-long name is invalid" {
    try std.testing.expectEqual(Translation{ .refuse = .invalid_name }, translate(""));
    const long: [max_name_bytes + 1]u8 = @splat('a');
    try std.testing.expectEqual(Translation{ .refuse = .invalid_name }, translate(&long));
}

test "a sensitive permission always requires a human decision, swept" {
    // Camera, microphone, location, and clipboard read are consequential; a
    // translation that returns one of these always marks it for a human.
    const sensitive = [_][]const u8{ "camera", "microphone", "geolocation", "clipboard-read" };
    for (sensitive) |name| {
        switch (translate(name)) {
            .request => |request| try std.testing.expect(request.requires_human_decision),
            .refuse => return error.TestUnexpectedResult,
        }
    }
}

test "only names in the closed table ever translate, swept" {
    const candidates = [_][]const u8{ "camera", "geolocation", "usb", "bluetooth", "notifications" };
    for (candidates) |name| {
        var in_table = false;
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, name)) in_table = true;
        }
        try std.testing.expectEqual(in_table, translate(name).translated());
    }
}
