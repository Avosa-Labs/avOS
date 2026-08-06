//! The assistant mind provider when no on-device engine is compiled in: it binds nothing.
//!
//! The windowed shell always calls `tryLoad`; without the llama.cpp engine there is no runtime to
//! bind, so the assistant stays offline. The build swaps in `mind_llama.zig` instead when the engine
//! source is present.

const live = @import("live_render");

/// Binds nothing: with no engine there is no runtime to load, so the mind stays offline.
pub fn tryLoad(inter: *live.Interaction, model_path: []const u8) void {
    _ = inter;
    _ = model_path;
}

/// Asks the assistant: offline in this build, so it produces nothing.
pub fn ask(inter: *live.Interaction) void {
    inter.assistantAsk();
}
