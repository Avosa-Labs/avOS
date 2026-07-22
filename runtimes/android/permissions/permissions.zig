//! Translates Android permissions into host capability requests.
//!
//! An Android permission is a statement inside the Android framework's own
//! authority model. It means nothing on this host until it is translated here,
//! and translation produces a *request* — the host decides whether to grant it,
//! exactly as it decides for any other principal.
//!
//! This is the whole point of the boundary. An application that holds a
//! permission inside its runtime has persuaded the Android framework, not this
//! system. Framework privilege does not become host privilege by crossing a
//! function call, and a permission with no host equivalent is refused rather
//! than approximated by the nearest capability that happens to exist.

const std = @import("std");
const core = @import("core");

const capability_model = core.capability;
const identity = core.identity;

pub const Error = error{
    /// The permission has no equivalent on this host.
    NoHostEquivalent,
    /// The permission is one this host will not translate at any privilege.
    RefusedByPolicy,
    /// The permission name is malformed or unbounded.
    InvalidPermission,
};

/// Longest permission name accepted. Names arrive from an application manifest,
/// which is outside this system, so the length is bounded before it is used.
pub const max_permission_bytes: usize = 128;

/// What a translated permission asks the host for.
pub const Request = struct {
    /// The host resource kind, in this system's vocabulary rather than
    /// Android's.
    resource_kind: []const u8,
    operations: capability_model.OperationSet,
    /// Constraints the translation itself imposes, before host policy adds any.
    constraints: capability_model.Constraints,
    /// Whether granting this is consequential enough to need a human.
    requires_human_decision: bool,
};

/// One entry in the translation table.
const Translation = struct {
    permission: []const u8,
    resource_kind: []const u8,
    operations: []const capability_model.Operation,
    requires_human_decision: bool,
    /// Data must not leave the device to satisfy the granted operation.
    local_only: bool = false,
};

/// The permissions this host knows how to translate.
///
/// Deliberately short. A permission absent from this table is refused, so the
/// set of Android authority this host can express is exactly what has been
/// considered rather than whatever an application happens to request.
const translations = [_]Translation{
    .{
        .permission = "android.permission.READ_CALENDAR",
        .resource_kind = "calendar",
        .operations = &.{ .read, .list },
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.WRITE_CALENDAR",
        .resource_kind = "calendar",
        .operations = &.{ .read, .write, .create },
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.READ_CONTACTS",
        .resource_kind = "contact",
        .operations = &.{ .read, .list },
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.ACCESS_COARSE_LOCATION",
        .resource_kind = "location",
        .operations = &.{.read},
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.ACCESS_FINE_LOCATION",
        .resource_kind = "location",
        .operations = &.{.read},
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.INTERNET",
        .resource_kind = "network",
        .operations = &.{.read},
        .requires_human_decision = true,
    },
    .{
        .permission = "android.permission.POST_NOTIFICATIONS",
        .resource_kind = "notification",
        .operations = &.{.create},
        // Placing content in front of a person is consequential, so the grant
        // is a decision they make rather than one inherited from the manifest.
        .requires_human_decision = true,
    },
    .{
        .permission = "android.permission.CAMERA",
        .resource_kind = "camera",
        .operations = &.{.read},
        .requires_human_decision = true,
        .local_only = true,
    },
    .{
        .permission = "android.permission.RECORD_AUDIO",
        .resource_kind = "microphone",
        .operations = &.{.read},
        .requires_human_decision = true,
        .local_only = true,
    },
};

/// Permissions this host refuses to translate at any privilege.
///
/// These do not lack a host equivalent — they are requests for authority over
/// the framework or the device itself, and honouring one would put an
/// application inside a boundary it is supposed to be outside of. The
/// distinction from `NoHostEquivalent` matters: one is unimplemented, the other
/// is refused.
const refused = [_][]const u8{
    "android.permission.INSTALL_PACKAGES",
    "android.permission.DELETE_PACKAGES",
    "android.permission.REQUEST_INSTALL_PACKAGES",
    "android.permission.WRITE_SECURE_SETTINGS",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
    "android.permission.SYSTEM_ALERT_WINDOW",
    "android.permission.BIND_ACCESSIBILITY_SERVICE",
    "android.permission.BIND_DEVICE_ADMIN",
    "android.permission.PACKAGE_USAGE_STATS",
    "android.permission.QUERY_ALL_PACKAGES",
};

/// Translates one permission into a host capability request.
///
/// Returns a request, never a grant. Whether the host issues anything is
/// decided by policy and, where the translation says so, by a human.
pub fn translate(permission: []const u8) Error!Request {
    if (permission.len == 0 or permission.len > max_permission_bytes) {
        return error.InvalidPermission;
    }

    for (refused) |name| {
        if (std.mem.eql(u8, permission, name)) return error.RefusedByPolicy;
    }

    for (translations) |entry| {
        if (!std.mem.eql(u8, permission, entry.permission)) continue;

        var operations: capability_model.OperationSet = .initEmpty();
        for (entry.operations) |operation| operations.insert(operation);

        return .{
            .resource_kind = entry.resource_kind,
            .operations = operations,
            .constraints = .{
                .local_processing_only = entry.local_only,
                // A translated permission never carries the right to hand its
                // authority on. An Android application delegating host
                // authority would put a principal the host never enrolled
                // inside the capability chain.
                .delegation_depth = 0,
                .requires_human_confirmation = entry.requires_human_decision,
            },
            .requires_human_decision = entry.requires_human_decision,
        };
    }

    return error.NoHostEquivalent;
}

/// Why a permission produced nothing, in words a person can act on.
pub fn describeRefusal(failure: Error) []const u8 {
    return switch (failure) {
        error.NoHostEquivalent => "this device has no equivalent of that permission",
        error.RefusedByPolicy => "that permission is not available to applications here",
        error.InvalidPermission => "that permission is not valid",
    };
}

/// The result of translating an application's whole manifest.
pub const ManifestTranslation = struct {
    /// Requests the host may consider.
    requests: []const Request,
    /// Permissions with no host equivalent, reported rather than hidden.
    unsupported: []const []const u8,
    /// Permissions this host refuses outright.
    refused: []const []const u8,

    /// Whether the application can function at all here.
    ///
    /// A manifest whose every permission was refused describes an application
    /// this host cannot honestly run, and saying so is better than launching it
    /// into failures the user cannot explain.
    pub fn hasAnyGrantableRequest(translation: ManifestTranslation) bool {
        return translation.requests.len > 0;
    }
};

/// Translates every permission an application declares.
///
/// Caller owns the three returned slices. Nothing is silently dropped:
/// a permission that produced no request appears in `unsupported` or `refused`,
/// so the launcher can tell a person what this device will not do.
pub fn translateManifest(
    gpa: std.mem.Allocator,
    permissions: []const []const u8,
) !ManifestTranslation {
    var requests: std.ArrayList(Request) = .empty;
    errdefer requests.deinit(gpa);
    var unsupported: std.ArrayList([]const u8) = .empty;
    errdefer unsupported.deinit(gpa);
    var refused_list: std.ArrayList([]const u8) = .empty;
    errdefer refused_list.deinit(gpa);

    for (permissions) |permission| {
        if (translate(permission)) |request| {
            try requests.append(gpa, request);
        } else |failure| switch (failure) {
            error.RefusedByPolicy => try refused_list.append(gpa, permission),
            error.NoHostEquivalent, error.InvalidPermission => {
                try unsupported.append(gpa, permission);
            },
        }
    }

    return .{
        .requests = try requests.toOwnedSlice(gpa),
        .unsupported = try unsupported.toOwnedSlice(gpa),
        .refused = try refused_list.toOwnedSlice(gpa),
    };
}

/// A dependency on a service this host does not provide.
///
/// Reported honestly rather than stubbed: an application that needs a service
/// which is absent will fail, and a person is better served by being told that
/// before launching it than by watching it break.
pub const ServiceDependency = struct {
    name: []const u8,
    available: bool,
    /// What the person is told when it is not available.
    explanation: []const u8,
};

/// Service dependencies this host cannot satisfy.
const unavailable_services = [_][]const u8{
    "com.google.android.gms",
    "com.google.android.gsf",
    "com.android.vending",
};

/// Reports whether a declared service dependency can be satisfied here.
pub fn checkServiceDependency(name: []const u8) ServiceDependency {
    for (unavailable_services) |unavailable| {
        if (std.mem.eql(u8, name, unavailable)) {
            return .{
                .name = name,
                .available = false,
                .explanation = "this application depends on services this device does not provide",
            };
        }
    }
    return .{ .name = name, .available = true, .explanation = "" };
}

test "a translated permission produces a request, never a grant" {
    const request = try translate("android.permission.READ_CALENDAR");

    try std.testing.expectEqualStrings("calendar", request.resource_kind);
    try std.testing.expect(request.operations.contains(.read));
    try std.testing.expect(!request.operations.contains(.delete));
    try std.testing.expect(request.requires_human_decision);

    // The result carries no field capable of holding a granted capability.
    inline for (@typeInfo(Request).@"struct".fields) |field| {
        try std.testing.expect(field.type != capability_model.Handle);
        try std.testing.expect(!std.mem.eql(u8, field.name, "granted"));
        try std.testing.expect(!std.mem.eql(u8, field.name, "capability"));
    }
}

test "a translated permission cannot be delegated onward" {
    // An Android application passing host authority to something else would put
    // a principal the host never enrolled into the capability chain.
    for (translations) |entry| {
        const request = try translate(entry.permission);
        try std.testing.expectEqual(@as(u8, 0), request.constraints.delegation_depth);
    }
}

test "a read permission does not translate into a write capability" {
    const read_only = try translate("android.permission.READ_CALENDAR");
    try std.testing.expect(!read_only.operations.contains(.write));
    try std.testing.expect(!read_only.operations.contains(.create));

    const writable = try translate("android.permission.WRITE_CALENDAR");
    try std.testing.expect(writable.operations.contains(.write));
}

test "a permission over private data is confined to the device" {
    const private = [_][]const u8{
        "android.permission.READ_CALENDAR",
        "android.permission.READ_CONTACTS",
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.CAMERA",
        "android.permission.RECORD_AUDIO",
    };
    for (private) |permission| {
        const request = try translate(permission);
        try std.testing.expect(request.constraints.local_processing_only);
    }
}

test "a permission granting authority over the framework or device is refused" {
    for (refused) |permission| {
        try std.testing.expectError(error.RefusedByPolicy, translate(permission));
    }
}

test "refusal is distinguished from absence" {
    // One is a decision, the other is unimplemented, and telling a person the
    // wrong one sends them looking for a setting that does not exist.
    try std.testing.expectError(
        error.RefusedByPolicy,
        translate("android.permission.INSTALL_PACKAGES"),
    );
    try std.testing.expectError(
        error.NoHostEquivalent,
        translate("android.permission.VIBRATE"),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        describeRefusal(error.RefusedByPolicy),
        describeRefusal(error.NoHostEquivalent),
    ));
}

test "an unknown permission is refused rather than approximated" {
    const unknown = [_][]const u8{
        "android.permission.SOMETHING_INVENTED",
        "com.example.custom.PERMISSION",
        "android.permission.READ_CALENDAR_EXTENDED",
    };
    for (unknown) |permission| {
        try std.testing.expectError(error.NoHostEquivalent, translate(permission));
    }
}

test "a malformed or unbounded permission name is refused before it is used" {
    try std.testing.expectError(error.InvalidPermission, translate(""));

    const overlong: [max_permission_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidPermission, translate(&overlong));
}

test "a manifest reports everything it could not translate" {
    const gpa = std.testing.allocator;

    const translation = try translateManifest(gpa, &.{
        "android.permission.READ_CALENDAR",
        "android.permission.INTERNET",
        "android.permission.INSTALL_PACKAGES",
        "android.permission.VIBRATE",
    });
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    try std.testing.expectEqual(@as(usize, 2), translation.requests.len);
    try std.testing.expectEqual(@as(usize, 1), translation.refused.len);
    try std.testing.expectEqual(@as(usize, 1), translation.unsupported.len);
    try std.testing.expectEqualStrings("android.permission.VIBRATE", translation.unsupported[0]);
    try std.testing.expect(translation.hasAnyGrantableRequest());
}

test "an application whose every permission is refused is reported as unrunnable" {
    const gpa = std.testing.allocator;

    const translation = try translateManifest(gpa, &.{
        "android.permission.INSTALL_PACKAGES",
        "android.permission.WRITE_SECURE_SETTINGS",
    });
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    try std.testing.expect(!translation.hasAnyGrantableRequest());
    try std.testing.expectEqual(@as(usize, 2), translation.refused.len);
}

test "an application declaring no permissions translates to no requests" {
    const gpa = std.testing.allocator;
    const translation = try translateManifest(gpa, &.{});
    defer gpa.free(translation.requests);
    defer gpa.free(translation.unsupported);
    defer gpa.free(translation.refused);

    try std.testing.expect(!translation.hasAnyGrantableRequest());
    try std.testing.expectEqual(@as(usize, 0), translation.unsupported.len);
}

test "an unavailable service dependency is reported rather than stubbed" {
    const unavailable = checkServiceDependency("com.google.android.gms");
    try std.testing.expect(!unavailable.available);
    try std.testing.expect(unavailable.explanation.len > 0);

    const ordinary = checkServiceDependency("com.example.application");
    try std.testing.expect(ordinary.available);
}

test "no translation quietly widens what the permission asked for" {
    // Every operation a translation produces must be one the table names, so a
    // permission cannot acquire an operation by editing a shared default.
    for (translations) |entry| {
        const request = try translate(entry.permission);
        var expected: capability_model.OperationSet = .initEmpty();
        for (entry.operations) |operation| expected.insert(operation);

        for (std.enums.values(capability_model.Operation)) |operation| {
            try std.testing.expectEqual(
                expected.contains(operation),
                request.operations.contains(operation),
            );
        }
    }
}

test "every consequential translation requires a human decision" {
    for (translations) |entry| {
        const request = try translate(entry.permission);
        var consequential = false;
        for (entry.operations) |operation| {
            if (operation.isConsequential()) consequential = true;
        }
        // A translation granting a consequential operation without asking would
        // let an application obtain, through the Android boundary, authority the
        // host would have held for a human decision.
        if (consequential) try std.testing.expect(request.requires_human_decision);
    }
}
