//! Deciding whether a declarative-UI element from a ported app maps to a host component,
//! so an unmappable view is reported rather than silently dropped from the screen.
//!
//! A declarative UI describes a screen as a tree of view elements — a stack, a list, a
//! button, an image — and porting one means mapping each element to the host's component
//! for it. Most map cleanly, because the vocabulary of layout is shared. Some map with a
//! documented substitution, where the host's nearest component stands in and the
//! difference is known. And some have no host component at all — a platform-specific
//! control, a private view — and the only honest thing to do with those is report them,
//! not drop them, because an element silently omitted is a control that vanishes from
//! the interface: a button the user needed, gone, with nothing to say why. Reporting the
//! unmappable elements up front lets a developer decide what to do about each, rather
//! than discovering a hole in the UI after it ships.
//!
//! This module renders nothing. It maps a declarative element to its host component, a
//! substitute, or reports it unmappable, as a pure function over a closed table.

const std = @import("std");

/// How a declarative-UI element maps to the host.
pub const Mapping = union(enum) {
    /// Maps directly to this host component.
    direct: []const u8,
    /// Maps to this host component as a documented substitute, with known differences.
    substitute: []const u8,
    /// No host component; reported rather than dropped.
    unmappable,

    pub fn renders(mapping: Mapping) bool {
        return mapping != .unmappable;
    }
};

const Entry = struct {
    element: []const u8,
    mapping: Mapping,
};

/// The closed element table. An element absent from it is unmappable, so no element is
/// ever silently dropped: it either has a known mapping or is reported.
const table = [_]Entry{
    .{ .element = "VStack", .mapping = .{ .direct = "host.ui.Column" } },
    .{ .element = "HStack", .mapping = .{ .direct = "host.ui.Row" } },
    .{ .element = "Text", .mapping = .{ .direct = "host.ui.Label" } },
    .{ .element = "Button", .mapping = .{ .direct = "host.ui.Button" } },
    .{ .element = "List", .mapping = .{ .direct = "host.ui.List" } },
    .{ .element = "Image", .mapping = .{ .direct = "host.ui.Image" } },
    // A platform control with a near-equivalent maps as a documented substitute.
    .{ .element = "NavigationSplitView", .mapping = .{ .substitute = "host.ui.SplitLayout" } },
    // A platform-specific control with no host counterpart.
    .{ .element = "Map", .mapping = .unmappable },
};

/// Maps a declarative-UI element to the host.
///
/// A known element returns its mapping — direct or substitute. An element not in the
/// table is unmappable, reported rather than dropped, so a developer sees exactly which
/// parts of the interface do not carry over instead of finding controls missing from the
/// rendered screen.
pub fn map(element: []const u8) Mapping {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.element, element)) return entry.mapping;
    }
    return .unmappable;
}

test "a common element maps directly to a host component" {
    switch (map("VStack")) {
        .direct => |component| try std.testing.expectEqualStrings("host.ui.Column", component),
        else => return error.TestUnexpectedResult,
    }
}

test "a near-equivalent element maps as a documented substitute" {
    switch (map("NavigationSplitView")) {
        .substitute => |component| try std.testing.expectEqualStrings("host.ui.SplitLayout", component),
        else => return error.TestUnexpectedResult,
    }
}

test "a platform-specific element is unmappable, not dropped" {
    try std.testing.expectEqual(Mapping.unmappable, map("Map"));
}

test "an unknown element is unmappable" {
    try std.testing.expectEqual(Mapping.unmappable, map("SomeCustomView"));
}

test "a mapped element renders; an unmappable one is reported" {
    try std.testing.expect(map("Button").renders());
    try std.testing.expect(!map("Map").renders());
}

test "only elements in the table ever render, swept" {
    // The no-silent-drop property: any element that renders is one the table maps.
    const elements = [_][]const u8{ "VStack", "Button", "Map", "Unknown", "List" };
    for (elements) |element| {
        if (map(element).renders()) {
            var found = false;
            for (table) |entry| {
                if (std.mem.eql(u8, entry.element, element)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}
