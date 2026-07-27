//! A minimal SDL2 binding, declared directly rather than translated from the header.
//!
//! Translating SDL's header pulls in the platform's system headers, and Zig's C translator chokes on
//! the ARM NEON intrinsics macOS ships. Only a handful of SDL calls are needed to open a window,
//! present a texture, and read input, so they are declared here as extern functions against the linked
//! SDL2 library, with the constants and the slice of the event union the shell reads. No header is
//! parsed, so the binding builds cleanly on every host; the symbols resolve at link time.

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};

pub const Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };

// Subsystems and flags.
pub const SDL_INIT_VIDEO: u32 = 0x00000020;
pub const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF0000;
pub const SDL_WINDOW_SHOWN: u32 = 0x00000004;
pub const SDL_WINDOW_ALLOW_HIGHDPI: u32 = 0x00002000;
pub const SDL_RENDERER_ACCELERATED: u32 = 0x00000002;
pub const SDL_RENDERER_PRESENTVSYNC: u32 = 0x00000004;
pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;

// ABGR8888 stores bytes as R, G, B, A on a little-endian host — the framebuffer's own byte order.
pub const SDL_PIXELFORMAT_ABGR8888: u32 = 0x16762004;

// Event types the loop handles.
pub const SDL_QUIT: u32 = 0x100;
pub const SDL_KEYDOWN: u32 = 0x300;
pub const SDL_MOUSEBUTTONDOWN: u32 = 0x401;

pub const SDLK_ESCAPE: i32 = 27;
pub const SDLK_RETURN: i32 = 13;
pub const SDLK_SPACE: i32 = 32;
// Arrow keys carry the scancode mask (0x40000000) over their scancode; Up is scancode 82.
pub const SDLK_UP: i32 = 0x40000000 | 82;

pub const Keysym = extern struct {
    scancode: c_int,
    sym: i32,
    mod: u16,
    unused: u32,
};

pub const KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    padding2: u8,
    padding3: u8,
    keysym: Keysym,
};

pub const MouseButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding1: u8,
    x: i32,
    y: i32,
};

/// The event union. SDL's real `SDL_Event` is 56 bytes; the padding keeps this the same size so
/// `SDL_PollEvent` writes within bounds. Only `type`, `button`, and `key` are read.
pub const Event = extern union {
    type: u32,
    key: KeyboardEvent,
    button: MouseButtonEvent,
    padding: [56]u8,
};

/// The SDL_-prefixed name, matching how the loop refers to it.
pub const SDL_Event = Event;

pub extern fn SDL_Init(flags: u32) c_int;
pub extern fn SDL_Quit() void;
pub extern fn SDL_GetError() [*c]const u8;
pub extern fn SDL_CreateWindow(title: [*c]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*Window;
pub extern fn SDL_GetDisplayUsableBounds(displayIndex: c_int, rect: ?*Rect) c_int;
pub extern fn SDL_DestroyWindow(window: ?*Window) void;
pub extern fn SDL_CreateRenderer(window: ?*Window, index: c_int, flags: u32) ?*Renderer;
pub extern fn SDL_DestroyRenderer(renderer: ?*Renderer) void;
pub extern fn SDL_CreateTexture(renderer: ?*Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
pub extern fn SDL_DestroyTexture(texture: ?*Texture) void;
pub extern fn SDL_UpdateTexture(texture: ?*Texture, rect: ?*const Rect, pixels: ?*const anyopaque, pitch: c_int) c_int;
pub extern fn SDL_RenderClear(renderer: ?*Renderer) c_int;
pub extern fn SDL_RenderCopy(renderer: ?*Renderer, texture: ?*Texture, srcrect: ?*const Rect, dstrect: ?*const Rect) c_int;
pub extern fn SDL_RenderPresent(renderer: ?*Renderer) void;
pub extern fn SDL_PollEvent(event: ?*Event) c_int;
pub extern fn SDL_Delay(ms: u32) void;
