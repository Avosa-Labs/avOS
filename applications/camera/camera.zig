//! Camera, agent-native: the capabilities the camera is used through, over the real
//! camera domain. Preview and review are silent reads; capture and share are held for the
//! person — an agent may request a capture, but every one is approved with a live frame
//! preview and fires only while the indicator is lit.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const Store = domain.Store;
pub const App = framework.App;
pub const mayCapture = domain.mayCapture;
pub const Mode = domain.Mode;
pub const Understanding = domain.Understanding;
pub const processingIsLocal = domain.processingIsLocal;

pub const tools = [_]framework.Tool{
    .{ .name = "camera.preview", .required_capability = "camera.preview", .effect = .read_only },
    .{ .name = "camera.review", .required_capability = "photos.read", .effect = .read_only },
    .{ .name = "camera.capture", .required_capability = "camera.capture", .effect = .external },
    .{ .name = "camera.share", .required_capability = "photos.share", .effect = .external },
};

pub fn open(store: *Store, ledger: *framework.Ledger) App {
    return .{ .name = "Camera", .domain = store.domain(), .tools = .{ .tools = &tools }, .ledger = ledger };
}

const testing = std.testing;
test "capture proceeds only while the indicator is lit and the app is foreground" {
    try testing.expect(mayCapture(true, true));
    try testing.expect(!mayCapture(true, false));
}
test "capture and share are held for the person; preview and review are silent" {
    for (tools) |tool| {
        const held = tool.effect.needsApproval();
        const consequential = std.mem.eql(u8, tool.name, "camera.capture") or std.mem.eql(u8, tool.name, "camera.share");
        try testing.expectEqual(consequential, held);
    }
}
