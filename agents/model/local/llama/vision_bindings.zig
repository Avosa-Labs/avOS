//! The multimodal C API, imported once. `mtmd.h` (libmtmd, the projector-and-clip layer) pulls in
//! `llama.h` and `ggml.h` under it, so this single translation unit surfaces every `mtmd_*`,
//! `llama_*`, and `ggml_*` type the vision adapter speaks over. The engine's C sources are compiled
//! into this module by the build; no C type crosses out of this module's siblings.

pub const c = @cImport({
    @cInclude("mtmd.h");
    @cInclude("mtmd-helper.h");
});
