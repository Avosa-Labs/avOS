//! The Settings panels, derived from the policy registry.
//!
//! The Settings app owns no settings state. Every setting is a policy key in the registry, owned by
//! a domain service, with a schema, a default, and a sensitivity class; the app is one viewer over
//! them. This derives the app's panels from that registry: a panel per owning service, each row a
//! key with its current value and its class. A setting appears in the app by being registered, not
//! by hand-built UI, so the app and the registry can never drift — the property that makes Settings
//! the single surface over policy rather than a second copy of it.

const std = @import("std");
const settings = @import("../framework/agent_app.zig").settings;

pub const Class = settings.Class;
pub const Value = settings.Value;
pub const Store = settings.Store;

/// One row in a panel: the setting's key, its current value, and its sensitivity class — which
/// decides what an agent may do with it, read from the registry, not the app.
pub const Row = struct {
    key: []const u8,
    value: Value,
    class: Class,

    /// Whether an agent holding the capability may ever write this row's setting.
    pub fn agentWritable(row: Row) bool {
        return row.class.agentWritable();
    }
};

/// A panel: the settings owned by one service, in registry order.
pub const Panel = struct {
    owner: []const u8,
    rows: []const Row,
};

/// The buffers a caller supplies, both sized to the registry so the derivation never allocates.
pub const row_capacity = settings.registry.len;
pub const panel_capacity = settings.registry.len;

/// Derives the panels from the registry, reading current values from `store`. A panel is a
/// contiguous run of keys sharing an owner (the registry keeps a service's keys together), so each
/// service is one panel and each key one row. Rows are written into `row_buffer`, panels into
/// `panel_buffer`; both must be at least the registry's length.
pub fn derive(store: *const Store, row_buffer: []Row, panel_buffer: []Panel) []const Panel {
    for (settings.registry, 0..) |entry, i| {
        row_buffer[i] = .{ .key = entry.key, .value = store.get(entry.key).?, .class = entry.class };
    }

    var panel_count: usize = 0;
    var start: usize = 0;
    var i: usize = 1;
    while (i <= settings.registry.len) : (i += 1) {
        const at_end = i == settings.registry.len;
        const owner_changed = !at_end and !std.mem.eql(u8, settings.registry[i].owner, settings.registry[start].owner);
        if (at_end or owner_changed) {
            panel_buffer[panel_count] = .{ .owner = settings.registry[start].owner, .rows = row_buffer[start..i] };
            panel_count += 1;
            start = i;
        }
    }
    return panel_buffer[0..panel_count];
}

// --- Tests ---

const testing = std.testing;

fn deriveInto(store: *const Store, rows: *[row_capacity]Row, panels: *[panel_capacity]Panel) []const Panel {
    return derive(store, rows, panels);
}

test "every registered setting is one row in exactly one panel, carrying its class and value" {
    var store = Store.init();
    var rows: [row_capacity]Row = undefined;
    var panels: [panel_capacity]Panel = undefined;
    const derived = deriveInto(&store, &rows, &panels);

    // The rows across all panels account for every registry key, exactly once.
    var total: usize = 0;
    for (derived) |panel| total += panel.rows.len;
    try testing.expectEqual(@as(usize, settings.registry.len), total);

    for (settings.registry) |entry| {
        var seen: usize = 0;
        for (derived) |panel| {
            for (panel.rows) |row| {
                if (std.mem.eql(u8, row.key, entry.key)) seen += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), seen); // present once, nowhere twice
    }
}

test "a panel groups one service, and a human_only row is never agent-writable" {
    var store = Store.init();
    var rows: [row_capacity]Row = undefined;
    var panels: [panel_capacity]Panel = undefined;
    const derived = deriveInto(&store, &rows, &panels);

    for (derived) |panel| {
        try testing.expect(panel.rows.len > 0);
        for (panel.rows) |row| {
            const entry = settings.find(row.key).?;
            try testing.expectEqualStrings(panel.owner, entry.owner); // every row is its panel's owner
            try testing.expectEqual(entry.class.agentWritable(), row.agentWritable());
        }
    }

    // The lock method surfaces as human_only and is never agent-writable — read straight from the
    // registry, not decided by the app.
    var checked = false;
    for (derived) |panel| for (panel.rows) |row| {
        if (std.mem.eql(u8, row.key, "security.lock_method")) {
            try testing.expectEqual(Class.human_only, row.class);
            try testing.expect(!row.agentWritable());
            checked = true;
        }
    };
    try testing.expect(checked);
}

test "a value written through the policy store shows in the derived panels" {
    var store = Store.init();
    _ = store.propose("display.text_size", .{ .integer = 130 }, .human);
    var rows: [row_capacity]Row = undefined;
    var panels: [panel_capacity]Panel = undefined;
    const derived = deriveInto(&store, &rows, &panels);

    var found = false;
    for (derived) |panel| for (panel.rows) |row| {
        if (std.mem.eql(u8, row.key, "display.text_size")) {
            try testing.expectEqual(@as(i64, 130), row.value.integer);
            found = true;
        }
    };
    try testing.expect(found);
}
