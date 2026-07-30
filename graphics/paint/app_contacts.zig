//! The Contacts screen, rendered bespoke and driven by real data.
//!
//! Contacts' own layout: a search field, then a list of people and the non-human principals a person
//! shares their world with, each a row with a tinted initial avatar, the name, and a kind label. Every
//! string, tint, and kind is a field of the `ContactsView` the shell fills from the real domain, which
//! surfaces applications, services, and devices as principals alongside people. Graphics stays
//! app-agnostic.
//!
//! Rendered portrait at a phone's proportions. Bounded: one row per contact - O(contacts).

const std = @import("std");
const fb = @import("framebuffer.zig");
const paint = @import("paint.zig");
const vector = @import("vector.zig");
const text = @import("text.zig");
const theme = @import("design").theme;

const Framebuffer = fb.Framebuffer;
const Rect = paint.Rect;

pub const width: u32 = 390;
pub const height: u32 = 844;

/// One contact row: the name, a short kind label (Person, Service, Device), and the avatar tint.
pub const Contact = struct {
    name: []const u8,
    kind: []const u8,
    tint: theme.Colour,
};

/// Everything the Contacts screen draws, filled by the shell from the real domain.
pub const ContactsView = struct {
    contacts: []const Contact,
};

fn s(colour: theme.Colour) fb.Rgba {
    return paint.sample(colour);
}

/// Renders the Contacts screen for `view` into `target`.
pub fn render(target: *Framebuffer, view: ContactsView) void {
    paint.paint(target, &.{.{ .vgradient = .{
        .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        .top = s(theme.base),
        .bottom = s(theme.panel),
    } }});
    _ = text.draw(target, 24, 44, "9:41", 15, s(theme.screen_text_soft));
    _ = text.draw(target, 24, 100, "Contacts", 30, s(theme.screen_text));

    // A search field.
    const search: Rect = .{ .x = 20, .y = 120, .w = width - 40, .h = 40 };
    paint.paint(target, &.{.{ .rounded = .{ .rect = search, .radius = theme.radius_pill, .colour = s(theme.surface) } }});
    _ = text.draw(target, @floatFromInt(search.x + 18), @floatFromInt(search.y + 26), "Search", 15, s(theme.screen_text_faint));

    // The people-and-principals list.
    var y: i32 = 190;
    const row_h: i32 = 64;
    for (view.contacts) |contact| {
        const cy: f32 = @floatFromInt(y + 22);
        const avatar_cx: f32 = 46;
        vector.fillDisc(target, avatar_cx, cy, 22, s(contact.tint));
        if (contact.name.len > 0) {
            text.drawCentred(target, avatar_cx, cy + 6, contact.name[0..1], 17, s(theme.screen_text));
        }
        _ = text.draw(target, 80, @floatFromInt(y + 20), contact.name, 17, s(theme.screen_text));
        _ = text.draw(target, 80, @floatFromInt(y + 40), contact.kind, 12, s(theme.screen_text_muted));
        y += row_h;
    }
}

// --- Tests ---

const testing = std.testing;

fn sampleView() ContactsView {
    return .{ .contacts = &.{
        .{ .name = "Ana Silva", .kind = "Person", .tint = theme.agent },
        .{ .name = "Marco Dias", .kind = "Person", .tint = theme.amber },
        .{ .name = "Weather", .kind = "Service", .tint = theme.surface_raised },
        .{ .name = "Living Room Display", .kind = "Device", .tint = theme.agent_soft },
    } };
}

test "the contacts screen paints a search field and the people list" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    const before = target.digest();
    render(&target, sampleView());
    try testing.expect(target.digest() != before);
    try testing.expect(target.get(2, 2).a == 255);
    try testing.expect(target.get(46, 212).r != target.get(2, 400).r); // first avatar has ink
}

test "no contacts renders the header and search without a row or crash" {
    var target = try Framebuffer.init(testing.allocator, width, height, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer target.deinit();
    render(&target, .{ .contacts = &.{} });
    try testing.expect(target.get(2, 2).a == 255);
}
