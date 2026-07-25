//! The SDK's worked examples.
//!
//! Each example here is a real program on the same frame a shipped app runs on — a real
//! domain, gated through the tool registry, recorded to the audit ledger the live feed
//! reads — not a description of one. They are the smallest honest demonstrations of the
//! platform's load-bearing claims: least authority (`hello-agent`), one domain behind
//! two doors with a ledger-derived feed (`todo-app`), and a consequential action held for
//! a person and run exactly once (`camera-capture`). Together they are the canonical
//! demonstration in miniature, and because each reads its result back from the ledger it
//! wrote, running them is proof the real path ran rather than a narration that matched.
//!
//! The set here is the one the SDK example registry publishes; a name a developer follows
//! from the docs resolves to one of these, and the example-check gate holds that
//! correspondence — every registered name is a real, building example, and every built
//! example is registered.

pub const harness = @import("harness.zig");
pub const hello_agent = @import("hello-agent/hello_agent.zig");
pub const todo_app = @import("todo-app/todo_app.zig");
pub const camera_capture = @import("camera-capture/camera_capture.zig");

test {
    _ = harness;
    _ = hello_agent;
    _ = todo_app;
    _ = camera_capture;
    _ = @import("tests/conformance.zig");
}
