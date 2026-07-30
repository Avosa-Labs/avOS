//! The on-device multimodal adapter: a Zig surface over the compiled libmtmd + llama.cpp engines,
//! the eye behind Camera Lens and Describe.
//!
//! A vision model is two files that load together: the language model (the same GGUF the text path
//! runs) and a projector — the small "mmproj" that embeds an image into the language model's token
//! space. This adapter loads both from disk, turns a frame's raw RGB pixels and a text prompt into a
//! bounded forward pass on the device's own CPU — no network, no key — and detokenizes the answer
//! into a caller's buffer. The image is preprocessed into tokens once (O(pixels)); generation is the
//! same hard-bounded greedy decode the text path uses. Every `mtmd_*`, `llama_*`, and `ggml_*` C type
//! stays inside this module and its `vision_bindings.zig` sibling; nothing in a public signature here
//! is a C type, so the seam above never sees the engine.
//!
//! The projector and clip layer are compiled from the vendored source; the llama + ggml objects
//! under them are reused from the text engine module rather than compiled twice. Built only where
//! that multimodal source is present; without it this module is not compiled and the vision mind
//! stays honestly unavailable (see `vision_backend.zig`). Honest on failure too: no weights, a bad
//! projector, or any engine error produces nothing — never a fabricated caption.

const std = @import("std");
const c = @import("vision_bindings.zig").c;

// Importing the text engine reuses its compiled llama + ggml objects (and its process backend), so
// the language runtime under the projector is linked once, not built a second time here.
const llama_engine = @import("llama_engine");

/// Everything that can go wrong loading the pair or running a pass, as a typed set — no C error
/// codes leak out.
pub const Error = error{
    ModelLoadFailed,
    ProjectorLoadFailed,
    ContextCreateFailed,
    SamplerCreateFailed,
    TokenizeFailed,
    DecodeFailed,
    BitmapInvalid,
};

/// The context window handed to the engine, in tokens. Bounded rather than taken from the model so a
/// large model cannot demand an unbounded KV cache; it matches the local router's window and holds
/// the image tokens, the prompt, and the reserved output together.
const context_tokens: u32 = 4096;

/// The batch size for seeding the KV cache. It must be at least as large as an image chunk's token
/// count so the projector's embeddings decode in one pass; a phone-sized frame is a few hundred
/// tokens, comfortably under this. Untyped so it fits both the context's `u32` fields and the
/// helper's `i32` batch argument without a cast.
const n_batch = 2048;

/// The bound on the built prompt (the media marker plus the caller's question), in bytes. A prompt
/// past this is refused rather than truncated silently.
const max_prompt_bytes: usize = 8192;

/// The process-wide engine backend — the same one the text runtime uses. `init` brings ggml's backend
/// registry up and `deinit` tears it down; a loaded model needs it live.
pub const Runtime = llama_engine.Runtime;

/// A bounded multimodal generation: the number of tokens produced and the decoded caption text. The
/// text borrows the caller's buffer, so no allocation crosses this surface.
pub const Generation = struct {
    tokens: u32,
    text: []const u8,
};

/// A loaded on-device vision model: the language model plus its projector, bound together. A pass
/// borrows both to build a short-lived context. The `Runtime` must be live for its whole lifetime.
pub const MultimodalModel = struct {
    model: *c.llama_model,
    mctx: *c.mtmd_context,

    /// Loads the language GGUF from `model_path` and its projector from `mmproj_path`, CPU-only. Both
    /// paths are copied into null-terminated buffers for the C calls. Fails typed if either file
    /// cannot be loaded — so an absent or wrong-size weight is honestly unavailable, never a crash.
    pub fn load(model_path: []const u8, mmproj_path: []const u8) Error!MultimodalModel {
        var model_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (model_path.len >= model_buf.len) return Error.ModelLoadFailed;
        @memcpy(model_buf[0..model_path.len], model_path);
        model_buf[model_path.len] = 0;

        const model_params = c.llama_model_default_params();
        const model = c.llama_model_load_from_file(&model_buf, model_params) orelse
            return Error.ModelLoadFailed;
        errdefer c.llama_model_free(model);

        var mmproj_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (mmproj_path.len >= mmproj_buf.len) return Error.ProjectorLoadFailed;
        @memcpy(mmproj_buf[0..mmproj_path.len], mmproj_path);
        mmproj_buf[mmproj_path.len] = 0;

        var ctx_params = c.mtmd_context_params_default();
        ctx_params.use_gpu = false; // on-device CPU pass, matching the text runtime
        ctx_params.print_timings = false;
        const mctx = c.mtmd_init_from_file(&mmproj_buf, model, ctx_params) orelse
            return Error.ProjectorLoadFailed;

        return .{ .model = model, .mctx = mctx };
    }

    pub fn deinit(self: MultimodalModel) void {
        c.mtmd_free(self.mctx);
        c.llama_model_free(self.model);
    }

    /// Runs a bounded multimodal pass. `pixels` is the frame as tightly packed RGB — `nx * ny * 3`
    /// bytes — and `prompt` is the question asked of it. The image and prompt are tokenized (the
    /// projector embeds the pixels once), the pair seeds the KV cache, then the model greedily samples
    /// at most `max_tokens` new tokens, each detokenized into `out` until the budget is spent, the
    /// model emits an end-of-generation token, or `out` fills. Returns the tokens produced and the
    /// caption written into `out`. A real pass — no fabrication — and hard-bounded so it cannot run
    /// away. Any engine failure is returned typed; the caller turns that into nothing, never a guess.
    pub fn describe(
        self: MultimodalModel,
        pixels: []const u8,
        nx: u32,
        ny: u32,
        prompt: []const u8,
        max_tokens: u32,
        out: []u8,
    ) Error!Generation {
        // The bitmap must be exactly the frame's RGB, or the projector would read past it.
        if (@as(u64, nx) * ny * 3 != pixels.len) return Error.BitmapInvalid;

        const vocab = c.llama_model_get_vocab(self.model) orelse return Error.TokenizeFailed;

        // Build the prompt the projector expects: the media marker (replaced by the image chunk) then
        // the question.
        var prompt_buf: [max_prompt_bytes]u8 = undefined;
        const built = buildPrompt(&prompt_buf, c.mtmd_default_marker(), prompt) orelse
            return Error.TokenizeFailed;

        const bitmap = c.mtmd_bitmap_init(nx, ny, pixels.ptr) orelse return Error.BitmapInvalid;
        defer c.mtmd_bitmap_free(bitmap);

        const chunks = c.mtmd_input_chunks_init() orelse return Error.TokenizeFailed;
        defer c.mtmd_input_chunks_free(chunks);

        var text_input = c.mtmd_input_text{
            .text = built.ptr,
            .text_len = built.len,
            .add_special = true,
            .parse_special = true,
        };
        var bitmaps = [_]?*const c.mtmd_bitmap{bitmap};
        if (c.mtmd_tokenize(self.mctx, chunks, &text_input, &bitmaps, bitmaps.len) != 0)
            return Error.TokenizeFailed;

        // A short-lived context with a fixed, bounded window and a batch wide enough for the image.
        var ctx_params = c.llama_context_default_params();
        ctx_params.n_ctx = context_tokens;
        ctx_params.n_batch = n_batch;
        ctx_params.n_ubatch = n_batch;
        const lctx = c.llama_init_from_model(self.model, ctx_params) orelse
            return Error.ContextCreateFailed;
        defer c.llama_free(lctx);

        // Encode the image chunk through the projector and decode it and the prompt into the KV cache
        // in one bounded helper pass; positions come back in `n_past`.
        var n_past: c.llama_pos = 0;
        if (c.mtmd_helper_eval_chunks(self.mctx, lctx, chunks, n_past, 0, n_batch, true, &n_past) != 0)
            return Error.DecodeFailed;

        // A greedy sampler chain: deterministic, bounded, no randomness to seed.
        const sampler = c.llama_sampler_init_greedy() orelse return Error.SamplerCreateFailed;
        defer c.llama_sampler_free(sampler);

        // Greedily sample new tokens, detokenizing each into `out` and feeding it back, until the
        // budget is spent, an end-of-generation token lands, or the caption buffer fills.
        var written: usize = 0;
        var generated: u32 = 0;
        var next: c.llama_token = c.llama_sampler_sample(sampler, lctx, -1);
        while (generated < max_tokens) : (generated += 1) {
            if (c.llama_vocab_is_eog(vocab, next)) break;
            const remaining = out[written..];
            if (remaining.len > 0) {
                const n = c.llama_token_to_piece(vocab, next, remaining.ptr, @intCast(remaining.len), 0, false);
                if (n > 0) written += @intCast(n);
            }
            var one = [_]c.llama_token{next};
            const step = c.llama_batch_get_one(&one, 1);
            if (c.llama_decode(lctx, step) != 0) return Error.DecodeFailed;
            next = c.llama_sampler_sample(sampler, lctx, -1);
        }
        return .{ .tokens = generated, .text = out[0..written] };
    }
};

/// Composes the media marker and the caller's question into `buf`: `<marker>\n<prompt>`. The marker
/// is where `mtmd_tokenize` splices the image chunk. Returns null if the pair does not fit `buf`, so
/// an over-long prompt is refused rather than silently cut.
fn buildPrompt(buf: []u8, marker: [*c]const u8, prompt: []const u8) ?[]u8 {
    const m = std.mem.sliceTo(marker, 0);
    const needed = m.len + 1 + prompt.len;
    if (needed > buf.len) return null;
    @memcpy(buf[0..m.len], m);
    buf[m.len] = '\n';
    @memcpy(buf[m.len + 1 ..][0..prompt.len], prompt);
    return buf[0..needed];
}

// --- Tests ---
//
// These exercise the Zig surface's shape and bounds without model files (none is vendored, and a pass
// needs weights). The engine linking and a real pass are covered by `zig build` on a checkout with
// the source and weights present; here we prove the adapter compiles against the real C API and that
// its honest-until-loaded and bounds behaviour is what the seam expects.

const testing = std.testing;

test "the runtime brings the backend up and down without a model" {
    const rt = Runtime.init();
    defer rt.deinit();
}

test "loading a non-existent model is a typed failure, not a crash" {
    const rt = Runtime.init();
    defer rt.deinit();
    try testing.expectError(
        Error.ModelLoadFailed,
        MultimodalModel.load("/nonexistent/model.gguf", "/nonexistent/mmproj.gguf"),
    );
}

test "an over-long model path is refused rather than overrunning the buffer" {
    const rt = Runtime.init();
    defer rt.deinit();
    var long: [std.fs.max_path_bytes + 16]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(Error.ModelLoadFailed, MultimodalModel.load(&long, "/nonexistent/mmproj.gguf"));
}

test "the context window the adapter hands the engine matches the local router" {
    // The window is bounded, not taken from the model, so no model can demand an unbounded cache.
    try testing.expectEqual(@as(u32, 4096), context_tokens);
}

test "the built prompt carries the media marker and refuses one that overruns the buffer" {
    var buf: [64]u8 = undefined;
    const marker = "<__media__>";
    const built = buildPrompt(&buf, marker, "what is this?") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, built, marker));
    try testing.expect(std.mem.endsWith(u8, built, "what is this?"));
    // A prompt that cannot fit alongside the marker and newline is refused, not cut.
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), buildPrompt(&tiny, marker, "way too long for eight bytes"));
}
