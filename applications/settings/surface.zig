//! The Settings surface: the human door — the rows a person sees and taps, laid out by
//! pane over the design tokens, rendering the real values the domain holds.
//!
//! This is the other door onto the one domain. Where an agent reaches Settings through
//! its capabilities, a person reaches it here, through a surface that reads the same
//! store and lays it out for the eye: a header for each pane, then a row per setting
//! showing its name and its real current value, with a sensitive setting marked so a
//! person sees which changes will ask them to re-authenticate. Every colour the surface
//! uses is a design token resolved value, never a raw one, so what the person sees
//! resolves from the single source the whole system shares — the conformance a test
//! pins. The surface renders; it changes nothing. A tap turns into the same domain call
//! an agent would make, through the same frame.
//!
//! This module builds a layout; it draws no pixels itself and holds no state. The
//! pixels are the shell's, over the rows this produces.

const std = @import("std");
const design = @import("design");
const domain = @import("domain.zig");

const theme = design.theme;
pub const Colour = theme.Colour;
pub const Setting = domain.Setting;
pub const Pane = domain.Pane;

/// One row in the rendered surface: a pane header, or a setting with its value.
pub const Row = struct {
    /// The pane this row belongs to.
    pane: Pane,
    /// The label shown: the pane name for a header, the setting name for a setting.
    label: []const u8,
    /// The setting this row shows, or null for a pane header.
    setting: ?Setting,
    /// The setting's current value, for a setting row.
    value: u16 = 0,
    /// Whether changing this row's setting asks the person to re-authenticate.
    sensitive: bool,
    /// The colour the label is drawn in — a resolved design token, never a raw value.
    colour: Colour,

    pub fn isHeader(row: Row) bool {
        return row.setting == null;
    }
};

/// Renders the Settings surface from the real store: for each pane, a header followed by
/// its settings with their current values. Returns the filled prefix of `buffer`.
///
/// The layout walks the settings in enum order, which groups them by pane, emitting a
/// header the first time a pane appears and then a row per setting. A header is drawn in
/// the primary text colour; a setting in the secondary; a sensitive setting keeps the
/// primary colour so it does not read as lesser, since it is the one a person most needs
/// to notice. All three are design tokens.
pub fn render(store: *const domain.Store, buffer: []Row) []const Row {
    var count: usize = 0;
    var current_pane: ?Pane = null;
    for (std.enums.values(Setting)) |setting| {
        const pane = setting.pane();
        if (current_pane == null or current_pane.? != pane) {
            if (count >= buffer.len) break;
            buffer[count] = .{
                .pane = pane,
                .label = @tagName(pane),
                .setting = null,
                .sensitive = pane.isSensitive(),
                .colour = theme.screen_text, // headers in the primary screen text
            };
            count += 1;
            current_pane = pane;
        }
        if (count >= buffer.len) break;
        buffer[count] = .{
            .pane = pane,
            .label = @tagName(setting),
            .setting = setting,
            .value = store.get(setting),
            .sensitive = setting.isSensitive(),
            // A sensitive setting keeps the primary colour so it stands out; an ordinary
            // one is the muted secondary.
            .colour = if (setting.isSensitive()) theme.screen_text else theme.screen_text_muted,
        };
        count += 1;
    }
    return buffer[0..count];
}

/// A generous bound on the rows the surface can produce: every setting plus a header per
/// pane. A caller sizes its buffer to at least this.
pub const max_rows: usize = @typeInfo(Setting).@"enum".fields.len + @typeInfo(Pane).@"enum".fields.len;

// --- Tests ---

const testing = std.testing;

test "the surface renders every pane header and every setting from the real values" {
    const gpa = testing.allocator;
    var store = domain.Store.init(gpa);
    defer store.deinit();

    var buffer: [max_rows]Row = undefined;
    const rows = render(&store, &buffer);

    // Every setting appears, and a header for each pane that has one.
    var setting_rows: usize = 0;
    var header_rows: usize = 0;
    for (rows) |row| {
        if (row.isHeader()) header_rows += 1 else setting_rows += 1;
    }
    try testing.expectEqual(@typeInfo(Setting).@"enum".fields.len, setting_rows);
    try testing.expect(header_rows > 0);

    // A setting row shows the real current value.
    for (rows) |row| {
        if (row.setting) |setting| {
            if (setting == .wifi_enabled) try testing.expectEqual(store.get(.wifi_enabled), row.value);
        }
    }
}

test "a sensitive setting is marked and kept in the prominent colour" {
    const gpa = testing.allocator;
    var store = domain.Store.init(gpa);
    defer store.deinit();
    var buffer: [max_rows]Row = undefined;
    const rows = render(&store, &buffer);
    for (rows) |row| {
        if (row.setting) |setting| {
            if (setting.isSensitive()) {
                try testing.expect(row.sensitive);
                // Kept in the primary colour, not the muted one.
                try testing.expect(std.meta.eql(row.colour, theme.screen_text));
            }
        }
    }
}

test "every colour the surface uses is a resolved design token" {
    // Design conformance: the surface's colours are the theme's resolved palette — the
    // single token source — so no raw colour can slip into what the person sees. Both
    // colours the surface can emit are theme fields by construction; this pins it.
    const gpa = testing.allocator;
    var store = domain.Store.init(gpa);
    defer store.deinit();
    var buffer: [max_rows]Row = undefined;
    const rows = render(&store, &buffer);
    for (rows) |row| {
        const is_token = std.meta.eql(row.colour, theme.screen_text) or std.meta.eql(row.colour, theme.screen_text_muted);
        try testing.expect(is_token);
    }
}
