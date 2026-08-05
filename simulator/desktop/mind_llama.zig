//! The assistant mind provider backed by the vendored llama.cpp engine.
//!
//! The windowed shell calls `tryLoad` once at start, with the GGUF weights path read from the
//! LOCAL_MODEL_PATH environment variable. It loads the model on the device's own CPU and binds it to
//! the interaction's assistant mind, so a question on the home command bar runs an on-device
//! generation. With an empty path, or a file that cannot be loaded, it binds nothing and the mind
//! stays offline — the command bar says so rather than answering. The runtime, model, and backend
//! live for the process, held here, because the bound mind borrows the backend for as long as the
//! shell runs.

const std = @import("std");
const llama = @import("llama_engine");
const llama_backend = @import("local_llama_backend");
const live = @import("live_render");

var runtime: ?llama.Runtime = null;
var model: ?llama.Model = null;
var backend_storage: llama_backend.LocalBackend = undefined;

const seed_prompt = "You are the on-device assistant. In one short line, help the person plan their day.";

/// Loads the model at `model_path` and binds it to the assistant mind, or leaves it offline when the
/// path is empty or the file cannot be loaded.
pub fn tryLoad(inter: *live.Interaction, model_path: []const u8) void {
    if (model_path.len == 0) return;
    runtime = llama.Runtime.init();
    const loaded = llama.Model.load(model_path) catch {
        if (runtime) |rt| rt.deinit();
        runtime = null;
        return;
    };
    model = loaded;
    backend_storage = llama_backend.LocalBackend.init(loaded, seed_prompt);
    inter.loadMind(backend_storage.backend());
}

/// Asks the assistant the person's current command-bar question through the loaded model, storing the
/// reply. With no model loaded it produces nothing — offline, not a fabricated answer.
pub fn ask(inter: *live.Interaction) void {
    if (model != null) backend_storage.prompt = inter.assistantPrompt();
    inter.assistantAsk();
}
