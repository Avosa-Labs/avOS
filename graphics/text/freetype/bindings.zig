//! The FreeType C API, imported once.
//!
//! FreeType is compiled from the vendored source (see the build's built-when-present guard),
//! and this is the single place its header is imported. The rest of the adapter speaks Zig
//! over these types; nothing above the adapter sees a FreeType type.

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});
