//! The llama.cpp C API, imported once. The vendored engine is compiled into this module by the
//! build; the rest of the adapter speaks Zig over these types, and no `llama_*`/`ggml_*` C type
//! ever crosses out of this module's siblings.

pub const c = @cImport({
    @cInclude("llama.h");
});
