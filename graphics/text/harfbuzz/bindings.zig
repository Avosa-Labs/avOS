//! The HarfBuzz C API, imported once. The amalgamation is compiled into this module by the
//! build; the rest of the adapter speaks Zig over these types.

pub const c = @cImport({
    @cInclude("hb.h");
});
