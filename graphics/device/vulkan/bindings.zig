//! The Vulkan C API, imported once with prototypes suppressed.
//!
//! `VK_NO_PROTOTYPES` is defined so the header declares the types and function-pointer
//! typedefs but no linkable symbols: nothing here binds to a `libvulkan` at link time. Every
//! command is resolved at runtime through the loader, so the adapter builds against the pinned
//! headers alone and needs no Vulkan library present to compile. This is the only place the C
//! header is imported; the rest of the adapter speaks Zig over these types.

pub const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vulkan/vulkan_core.h");
});
