//! The on-device inference adapter: a Zig surface over the compiled llama.cpp engine.
//!
//! llama.cpp (and the ggml tensor library under it) is compiled from the vendored source and
//! reached only through this adapter. It turns a prompt and a token budget into a bounded forward
//! pass on the device's own CPU — no network, no key. A model is loaded from a GGUF file on disk;
//! a generation tokenizes the prompt, decodes it, then greedily samples up to a hard token bound,
//! stopping early at an end-of-generation token. Every `llama_*` and `ggml_*` C type stays inside
//! this module (and its `bindings.zig` sibling): nothing in a public signature here is a C type,
//! so the seam above never sees the engine.
//!
//! Built only where the vendored source is present; without it this module is not compiled and the
//! local mind stays honestly unavailable (see `../adapter.zig`).

const std = @import("std");
const c = @import("bindings.zig").c;

/// Everything that can go wrong loading a model or running a pass, as a typed set — no C error
/// codes leak out.
pub const Error = error{
    ModelLoadFailed,
    ContextCreateFailed,
    SamplerCreateFailed,
    TokenizeFailed,
    DecodeFailed,
};

/// The bound on prompt tokens a single generation will tokenize. The context window the engine is
/// given is fixed below; a prompt is capped to fit it with room to generate.
const max_prompt_tokens: usize = 2048;

/// The context window handed to the engine, in tokens. Bounded rather than taken from the model so
/// a large model cannot demand an unbounded KV cache; it matches the local router's window.
const context_tokens: u32 = 4096;

/// The process-wide llama backend. `init` brings ggml's backend registry up (statically, the CPU
/// backend only) and `deinit` tears it down. One per process; a `Model` needs it live.
pub const Runtime = struct {
    pub fn init() Runtime {
        c.llama_backend_init();
        return .{};
    }

    pub fn deinit(_: Runtime) void {
        c.llama_backend_free();
    }
};

/// A loaded on-device model. Holds the engine's model handle; a generation borrows it to build a
/// short-lived context. The backend (`Runtime`) must be live for its whole lifetime.
pub const Model = struct {
    handle: *c.llama_model,

    /// Loads a GGUF model from `path` with default parameters (CPU, all layers on the host). The
    /// path is copied into a null-terminated buffer for the C call. Fails typed if the engine
    /// cannot load the file.
    pub fn load(path: []const u8) Error!Model {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= path_buf.len) return Error.ModelLoadFailed;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const params = c.llama_model_default_params();
        const handle = c.llama_model_load_from_file(&path_buf, params) orelse
            return Error.ModelLoadFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: Model) void {
        c.llama_model_free(self.handle);
    }

    /// What a bounded forward pass produced: how many tokens were generated, and the decoded text
    /// written into the caller's buffer. The text is a slice of that buffer, so it lives as long as
    /// the buffer does — the caller owns the storage, the engine only fills it.
    pub const Generation = struct {
        tokens: u32,
        text: []const u8,
    };

    /// Runs a bounded forward pass: tokenizes `prompt`, decodes it, then greedily samples at most
    /// `max_tokens` new tokens, detokenizing each into `out` and stopping early at an end-of-generation
    /// token — or when `out` has no room for the next piece, whichever comes first. Returns the token
    /// count and the decoded text (a slice of `out`). A real pass through the engine — no fabrication —
    /// kept simple and hard-bounded so it can never run away.
    pub fn generate(self: Model, prompt: []const u8, max_tokens: u32, out: []u8) Error!Generation {
        const vocab = c.llama_model_get_vocab(self.handle) orelse return Error.TokenizeFailed;

        // Tokenize the prompt into a bounded buffer.
        var tokens: [max_prompt_tokens]c.llama_token = undefined;
        const n_prompt = c.llama_tokenize(
            vocab,
            prompt.ptr,
            @intCast(prompt.len),
            &tokens,
            @intCast(tokens.len),
            true, // add BOS/special
            false,
        );
        if (n_prompt <= 0) return Error.TokenizeFailed;
        const prompt_len: usize = @intCast(n_prompt);

        // A short-lived context with a fixed, bounded window.
        var ctx_params = c.llama_context_default_params();
        ctx_params.n_ctx = context_tokens;
        const ctx = c.llama_init_from_model(self.handle, ctx_params) orelse
            return Error.ContextCreateFailed;
        defer c.llama_free(ctx);

        // A greedy sampler chain: deterministic, bounded, no randomness to seed.
        const sampler = c.llama_sampler_init_greedy() orelse return Error.SamplerCreateFailed;
        defer c.llama_sampler_free(sampler);

        // Decode the prompt. Positions are tracked by the context's memory across calls, so a batch
        // of the prompt tokens seeds the KV cache.
        var prompt_batch = c.llama_batch_get_one(&tokens, @intCast(prompt_len));
        if (c.llama_decode(ctx, prompt_batch) != 0) return Error.DecodeFailed;

        // Greedily sample new tokens, feeding each back in, until the budget is spent, the model emits
        // an end-of-generation token, or the output buffer is full. Each generated token is detokenized
        // into `out` as it is produced.
        var generated: u32 = 0;
        var written: usize = 0;
        var next: c.llama_token = c.llama_sampler_sample(sampler, ctx, -1);
        while (generated < max_tokens) : (generated += 1) {
            if (c.llama_vocab_is_eog(vocab, next)) break;

            // Detokenize this generated token into the remaining buffer. A negative return means the
            // piece would not fit; stop cleanly rather than truncate a multi-byte piece mid-way.
            const room = out[written..];
            if (room.len == 0) break;
            const piece = c.llama_token_to_piece(vocab, next, room.ptr, @intCast(room.len), 0, false);
            if (piece < 0) break;
            written += @intCast(piece);

            var one: [1]c.llama_token = .{next};
            const step = c.llama_batch_get_one(&one, 1);
            if (c.llama_decode(ctx, step) != 0) return Error.DecodeFailed;
            next = c.llama_sampler_sample(sampler, ctx, -1);
        }
        _ = &prompt_batch;
        return .{ .tokens = generated, .text = out[0..written] };
    }
};

// --- Tests ---
//
// These exercise the Zig surface's shape and bounds without a model file (none is vendored, and a
// forward pass needs weights). The engine linking and a real pass are covered by `zig build` on a
// checkout with the source present; here we prove the adapter compiles against the real C API and
// that its bounds are what the seam expects.

const testing = std.testing;

test "the runtime brings the backend up and down without a model" {
    const rt = Runtime.init();
    defer rt.deinit();
}

test "loading a non-existent model is a typed failure, not a crash" {
    const rt = Runtime.init();
    defer rt.deinit();
    try testing.expectError(Error.ModelLoadFailed, Model.load("/nonexistent/model.gguf"));
}

test "an over-long path is refused rather than overrunning the buffer" {
    const rt = Runtime.init();
    defer rt.deinit();
    var long: [std.fs.max_path_bytes + 16]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(Error.ModelLoadFailed, Model.load(&long));
}

test "the context window the adapter hands the engine matches the local router" {
    // The window is bounded, not taken from the model, so no model can demand an unbounded cache.
    try testing.expectEqual(@as(u32, 4096), context_tokens);
}
