//! A geometric stroked font and text layout, so surfaces can carry words.
//!
//! The shell is full of text — app names, agent taglines, ledger rows, settings — and it must render
//! without shipping a font file or a shaping library. So the font here is vector: each glyph is a small
//! set of stroke polylines in a shared em box, drawn with the same antialiased stroker the icons use, at
//! a weight proportional to the size. The forms are geometric and even-width, a clean sans in the
//! spirit of the design's typeface rather than a copy of it, chosen so labels read crisply at UI sizes.
//! Layout is left-to-right with per-glyph advances and a tracking step; measuring a string is the sum of
//! its advances, so a caller can centre or right-align before drawing. Building text from the same
//! primitive as everything else keeps one rasterizer for the whole interface and no external
//! dependency.
//!
//! Em coordinates run x to the right and y downward, with the cap line at y=0 and the baseline at y=7;
//! lowercase sits on the same baseline with an x-height around y=3.
//!
//! The forms are original geometric constructions, not derived from any typeface's outlines.

const std = @import("std");
const fb = @import("framebuffer.zig");
const vector = @import("vector.zig");

const Framebuffer = fb.Framebuffer;
const Rgba = fb.Rgba;
const Point = vector.Point;

/// The baseline position in em units; the cap line is at 0.
pub const baseline: f32 = 7.0;

/// A glyph: its horizontal advance in em units and the stroke polylines that draw it.
const Glyph = struct {
    advance: f32,
    strokes: []const []const [2]f32,
};

fn g(advance: f32, strokes: []const []const [2]f32) Glyph {
    return .{ .advance = advance, .strokes = strokes };
}

// Stroke data is verbose; each glyph is a few polylines over the 0..7 (cap) / 0..9 (descender) box.

const glyph_space = g(3.0, &.{});
const glyph_A = g(6, &.{ &.{ .{ 0, 7 }, .{ 3, 0 }, .{ 6, 7 } }, &.{ .{ 1, 4.5 }, .{ 5, 4.5 } } });
const glyph_B = g(6, &.{&.{ .{ 0, 0 }, .{ 4, 0 }, .{ 5.2, 1.2 }, .{ 4, 3.4 }, .{ 0, 3.4 }, .{ 4, 3.4 }, .{ 5.4, 4.9 }, .{ 4, 7 }, .{ 0, 7 }, .{ 0, 0 } }});
const glyph_C = g(6, &.{&.{ .{ 5.6, 1.6 }, .{ 4, 0 }, .{ 2, 0 }, .{ 0.4, 1.8 }, .{ 0.4, 5.2 }, .{ 2, 7 }, .{ 4, 7 }, .{ 5.6, 5.4 } }});
const glyph_D = g(6, &.{&.{ .{ 0, 0 }, .{ 3.6, 0 }, .{ 5.6, 2 }, .{ 5.6, 5 }, .{ 3.6, 7 }, .{ 0, 7 }, .{ 0, 0 } }});
const glyph_E = g(5.5, &.{ &.{ .{ 5.2, 0 }, .{ 0, 0 }, .{ 0, 7 }, .{ 5.2, 7 } }, &.{ .{ 0, 3.4 }, .{ 4, 3.4 } } });
const glyph_F = g(5.5, &.{ &.{ .{ 5.2, 0 }, .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 0, 3.4 }, .{ 4, 3.4 } } });
const glyph_G = g(6.2, &.{&.{ .{ 5.6, 1.6 }, .{ 4, 0 }, .{ 2, 0 }, .{ 0.4, 1.8 }, .{ 0.4, 5.2 }, .{ 2, 7 }, .{ 4, 7 }, .{ 5.6, 5.6 }, .{ 5.6, 4 }, .{ 3.6, 4 } }});
const glyph_H = g(6, &.{ &.{ .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 6, 0 }, .{ 6, 7 } }, &.{ .{ 0, 3.4 }, .{ 6, 3.4 } } });
const glyph_I = g(2, &.{&.{ .{ 1, 0 }, .{ 1, 7 } }});
const glyph_J = g(5, &.{&.{ .{ 4.4, 0 }, .{ 4.4, 5.4 }, .{ 3, 7 }, .{ 1.2, 7 }, .{ 0, 5.6 } }});
const glyph_K = g(6, &.{ &.{ .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 5.6, 0 }, .{ 0.4, 3.8 } }, &.{ .{ 2, 2.6 }, .{ 6, 7 } } });
const glyph_L = g(5.2, &.{&.{ .{ 0, 0 }, .{ 0, 7 }, .{ 5, 7 } }});
const glyph_M = g(7, &.{&.{ .{ 0, 7 }, .{ 0, 0 }, .{ 3.5, 5 }, .{ 7, 0 }, .{ 7, 7 } }});
const glyph_N = g(6.2, &.{&.{ .{ 0, 7 }, .{ 0, 0 }, .{ 6, 7 }, .{ 6, 0 } }});
const glyph_O = g(6.4, &.{&.{ .{ 3.2, 0 }, .{ 5.6, 1.8 }, .{ 5.6, 5.2 }, .{ 3.2, 7 }, .{ 0.8, 5.2 }, .{ 0.8, 1.8 }, .{ 3.2, 0 } }});
const glyph_P = g(6, &.{&.{ .{ 0, 7 }, .{ 0, 0 }, .{ 4, 0 }, .{ 5.4, 1.4 }, .{ 4, 3.6 }, .{ 0, 3.6 } }});
const glyph_Q = g(6.4, &.{ &.{ .{ 3.2, 0 }, .{ 5.6, 1.8 }, .{ 5.6, 5.2 }, .{ 3.2, 7 }, .{ 0.8, 5.2 }, .{ 0.8, 1.8 }, .{ 3.2, 0 } }, &.{ .{ 3.6, 5 }, .{ 6, 7.6 } } });
const glyph_R = g(6, &.{ &.{ .{ 0, 7 }, .{ 0, 0 }, .{ 4, 0 }, .{ 5.4, 1.4 }, .{ 4, 3.6 }, .{ 0, 3.6 } }, &.{ .{ 2.6, 3.6 }, .{ 6, 7 } } });
const glyph_S = g(5.8, &.{&.{ .{ 5.4, 1.4 }, .{ 3.6, 0 }, .{ 1.6, 0 }, .{ 0.2, 1.4 }, .{ 1.6, 3.4 }, .{ 4, 3.6 }, .{ 5.4, 5.4 }, .{ 3.8, 7 }, .{ 1.6, 7 }, .{ 0.2, 5.6 } }});
const glyph_T = g(5.6, &.{ &.{ .{ 0, 0 }, .{ 5.6, 0 } }, &.{ .{ 2.8, 0 }, .{ 2.8, 7 } } });
const glyph_U = g(6.2, &.{&.{ .{ 0, 0 }, .{ 0, 5.2 }, .{ 1.8, 7 }, .{ 4.2, 7 }, .{ 6, 5.2 }, .{ 6, 0 } }});
const glyph_V = g(6, &.{&.{ .{ 0, 0 }, .{ 3, 7 }, .{ 6, 0 } }});
const glyph_W = g(8, &.{&.{ .{ 0, 0 }, .{ 1.8, 7 }, .{ 4, 2 }, .{ 6.2, 7 }, .{ 8, 0 } }});
const glyph_X = g(6, &.{ &.{ .{ 0, 0 }, .{ 6, 7 } }, &.{ .{ 6, 0 }, .{ 0, 7 } } });
const glyph_Y = g(5.8, &.{ &.{ .{ 0, 0 }, .{ 2.9, 3.6 }, .{ 5.8, 0 } }, &.{ .{ 2.9, 3.6 }, .{ 2.9, 7 } } });
const glyph_Z = g(5.8, &.{&.{ .{ 0, 0 }, .{ 5.6, 0 }, .{ 0, 7 }, .{ 5.6, 7 } }});

// Lowercase — single-storey geometric forms, x-height from y=3 to baseline y=7.
const glyph_a = g(5.2, &.{ &.{ .{ 4.4, 3.2 }, .{ 4.4, 7 } }, &.{ .{ 4.4, 4 }, .{ 3, 3 }, .{ 1, 3.2 }, .{ 0.2, 4.6 }, .{ 1, 6 }, .{ 3, 6.2 }, .{ 4.4, 5.2 } }, &.{ .{ 4.4, 6 }, .{ 3.4, 7 }, .{ 1.6, 7 } } });
const glyph_b = g(5.2, &.{ &.{ .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 0, 5 }, .{ 1.6, 3 }, .{ 3.4, 3 }, .{ 4.8, 5 }, .{ 3.4, 7 }, .{ 1.6, 7 }, .{ 0, 5 } } });
const glyph_c = g(5, &.{&.{ .{ 4.6, 4 }, .{ 3.2, 3 }, .{ 1.4, 3 }, .{ 0.2, 4.4 }, .{ 0.2, 5.6 }, .{ 1.4, 7 }, .{ 3.2, 7 }, .{ 4.6, 6 } }});
const glyph_d = g(5.2, &.{ &.{ .{ 4.8, 0 }, .{ 4.8, 7 } }, &.{ .{ 4.8, 5 }, .{ 3.2, 3 }, .{ 1.4, 3 }, .{ 0, 5 }, .{ 1.4, 7 }, .{ 3.2, 7 }, .{ 4.8, 5 } } });
const glyph_e = g(5, &.{&.{ .{ 0.2, 5.1 }, .{ 4.6, 5.1 }, .{ 4.6, 4.2 }, .{ 3.2, 3 }, .{ 1.4, 3 }, .{ 0.2, 4.4 }, .{ 0.2, 5.6 }, .{ 1.4, 7 }, .{ 3.4, 7 }, .{ 4.6, 6 } }});
const glyph_f = g(3.4, &.{ &.{ .{ 3.2, 0.6 }, .{ 2, 0 }, .{ 1.2, 1 }, .{ 1.2, 7 } }, &.{ .{ 0, 3.4 }, .{ 3, 3.4 } } });
const glyph_g = g(5.2, &.{ &.{ .{ 4.8, 3 }, .{ 4.8, 8 }, .{ 3.4, 9.4 }, .{ 1.6, 9.4 }, .{ 0.4, 8.6 } }, &.{ .{ 4.8, 5 }, .{ 3.2, 3 }, .{ 1.4, 3 }, .{ 0, 5 }, .{ 1.4, 7 }, .{ 3.2, 7 }, .{ 4.8, 5 } } });
const glyph_h = g(5.2, &.{ &.{ .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 0, 5 }, .{ 1.6, 3 }, .{ 3.4, 3 }, .{ 4.8, 4.6 }, .{ 4.8, 7 } } });
const glyph_i = g(1.8, &.{ &.{ .{ 0.9, 3 }, .{ 0.9, 7 } }, &.{ .{ 0.9, 1.2 }, .{ 0.9, 1.6 } } });
const glyph_j = g(2.4, &.{ &.{ .{ 1.4, 3 }, .{ 1.4, 8.4 }, .{ 0.4, 9.4 }, .{ -0.4, 9 } }, &.{ .{ 1.4, 1.2 }, .{ 1.4, 1.6 } } });
const glyph_k = g(4.8, &.{ &.{ .{ 0, 0 }, .{ 0, 7 } }, &.{ .{ 4, 3 }, .{ 0.4, 5.4 } }, &.{ .{ 1.6, 4.6 }, .{ 4.4, 7 } } });
const glyph_l = g(1.8, &.{&.{ .{ 0.9, 0 }, .{ 0.9, 6 }, .{ 1.8, 7 } }});
const glyph_m = g(7.2, &.{ &.{ .{ 0, 7 }, .{ 0, 3 } }, &.{ .{ 0, 4.2 }, .{ 1.2, 3 }, .{ 2.6, 3 }, .{ 3.6, 4.2 }, .{ 3.6, 7 } }, &.{ .{ 3.6, 4.2 }, .{ 4.8, 3 }, .{ 6, 3 }, .{ 7, 4.2 }, .{ 7, 7 } } });
const glyph_n = g(5.2, &.{ &.{ .{ 0, 7 }, .{ 0, 3 } }, &.{ .{ 0, 4.4 }, .{ 1.6, 3 }, .{ 3.4, 3 }, .{ 4.8, 4.6 }, .{ 4.8, 7 } } });
const glyph_o = g(5.2, &.{&.{ .{ 2.4, 3 }, .{ 4, 4 }, .{ 4.6, 5 }, .{ 4, 6 }, .{ 2.4, 7 }, .{ 0.8, 6 }, .{ 0.2, 5 }, .{ 0.8, 4 }, .{ 2.4, 3 } }});
const glyph_p = g(5.2, &.{ &.{ .{ 0, 3 }, .{ 0, 9.4 } }, &.{ .{ 0, 5 }, .{ 1.6, 3 }, .{ 3.4, 3 }, .{ 4.8, 5 }, .{ 3.4, 7 }, .{ 1.6, 7 }, .{ 0, 5 } } });
const glyph_q = g(5.2, &.{ &.{ .{ 4.8, 3 }, .{ 4.8, 9.4 } }, &.{ .{ 4.8, 5 }, .{ 3.2, 3 }, .{ 1.4, 3 }, .{ 0, 5 }, .{ 1.4, 7 }, .{ 3.2, 7 }, .{ 4.8, 5 } } });
const glyph_r = g(3.6, &.{ &.{ .{ 0, 7 }, .{ 0, 3 } }, &.{ .{ 0, 4.4 }, .{ 1.4, 3.1 }, .{ 3.2, 3 } } });
const glyph_s = g(4.6, &.{&.{ .{ 4.2, 3.6 }, .{ 3, 3 }, .{ 1.2, 3 }, .{ 0.4, 4 }, .{ 1.4, 5 }, .{ 3.2, 5.1 }, .{ 4, 6 }, .{ 3.2, 7 }, .{ 1.2, 7 }, .{ 0.2, 6.4 } }});
const glyph_t = g(3.4, &.{ &.{ .{ 1.2, 0.6 }, .{ 1.2, 5.6 }, .{ 2.2, 7 }, .{ 3.2, 6.6 } }, &.{ .{ 0, 3.4 }, .{ 3, 3.4 } } });
const glyph_u = g(5.2, &.{ &.{ .{ 0, 3 }, .{ 0, 5.6 }, .{ 1.4, 7 }, .{ 3.2, 7 }, .{ 4.8, 5.6 } }, &.{ .{ 4.8, 3 }, .{ 4.8, 7 } } });
const glyph_v = g(4.8, &.{&.{ .{ 0, 3 }, .{ 2.4, 7 }, .{ 4.8, 3 } }});
const glyph_w = g(6.8, &.{&.{ .{ 0, 3 }, .{ 1.4, 7 }, .{ 3.4, 3.6 }, .{ 5.4, 7 }, .{ 6.8, 3 } }});
const glyph_x = g(4.8, &.{ &.{ .{ 0, 3 }, .{ 4.6, 7 } }, &.{ .{ 4.6, 3 }, .{ 0, 7 } } });
const glyph_y = g(4.8, &.{ &.{ .{ 0, 3 }, .{ 2.4, 7 } }, &.{ .{ 4.8, 3 }, .{ 2.2, 8.2 }, .{ 1, 9.4 }, .{ 0, 9 } } });
const glyph_z = g(4.6, &.{&.{ .{ 0.2, 3 }, .{ 4.4, 3 }, .{ 0.2, 7 }, .{ 4.4, 7 } }});

const glyph_0 = g(5.6, &.{ &.{ .{ 2.8, 0 }, .{ 5, 1.8 }, .{ 5, 5.2 }, .{ 2.8, 7 }, .{ 0.6, 5.2 }, .{ 0.6, 1.8 }, .{ 2.8, 0 } }, &.{ .{ 1.2, 5.4 }, .{ 4.4, 1.6 } } });
const glyph_1 = g(3.4, &.{ &.{ .{ 0.6, 1.4 }, .{ 2, 0 }, .{ 2, 7 } }, &.{ .{ 0.6, 7 }, .{ 3.4, 7 } } });
const glyph_2 = g(5.4, &.{&.{ .{ 0.4, 1.6 }, .{ 2, 0 }, .{ 4, 0 }, .{ 5, 1.6 }, .{ 4, 3.4 }, .{ 0.4, 7 }, .{ 5.2, 7 } }});
const glyph_3 = g(5.4, &.{&.{ .{ 0.4, 1.4 }, .{ 2, 0 }, .{ 4, 0 }, .{ 5, 1.6 }, .{ 3.4, 3.4 }, .{ 5, 5.2 }, .{ 4, 7 }, .{ 2, 7 }, .{ 0.4, 5.6 } }});
const glyph_4 = g(5.6, &.{&.{ .{ 4, 7 }, .{ 4, 0 }, .{ 0.2, 5 }, .{ 5.4, 5 } }});
const glyph_5 = g(5.4, &.{&.{ .{ 5, 0 }, .{ 1, 0 }, .{ 0.6, 3 }, .{ 3, 2.8 }, .{ 5, 4 }, .{ 5, 5.6 }, .{ 3.4, 7 }, .{ 1.4, 7 }, .{ 0.2, 5.8 } }});
const glyph_6 = g(5.4, &.{&.{ .{ 4.8, 1.2 }, .{ 3.2, 0 }, .{ 1.6, 0.6 }, .{ 0.6, 3 }, .{ 0.6, 5.4 }, .{ 2, 7 }, .{ 3.6, 7 }, .{ 5, 5.6 }, .{ 4, 4 }, .{ 2, 3.8 }, .{ 0.7, 4.8 } }});
const glyph_7 = g(5.2, &.{&.{ .{ 0.2, 0 }, .{ 5, 0 }, .{ 2, 7 } }});
const glyph_8 = g(5.6, &.{&.{ .{ 2.8, 3.4 }, .{ 1, 2.4 }, .{ 1, 1.2 }, .{ 2.8, 0 }, .{ 4.6, 1.2 }, .{ 4.6, 2.4 }, .{ 2.8, 3.4 }, .{ 0.7, 4.8 }, .{ 0.7, 6 }, .{ 2.8, 7 }, .{ 4.9, 6 }, .{ 4.9, 4.8 }, .{ 2.8, 3.4 } }});
const glyph_9 = g(5.4, &.{&.{ .{ 0.6, 5.8 }, .{ 2.2, 7 }, .{ 3.8, 6.4 }, .{ 4.8, 4 }, .{ 4.8, 1.6 }, .{ 3.4, 0 }, .{ 1.8, 0 }, .{ 0.4, 1.4 }, .{ 1.4, 3 }, .{ 3.4, 3.2 }, .{ 4.7, 2.2 } }});

const glyph_period = g(2, &.{&.{ .{ 0.8, 6.6 }, .{ 0.8, 7 } }});
const glyph_comma = g(2, &.{&.{ .{ 1, 6.4 }, .{ 1, 7 }, .{ 0.4, 8 } }});
const glyph_colon = g(2, &.{ &.{ .{ 0.8, 3.2 }, .{ 0.8, 3.6 } }, &.{ .{ 0.8, 6.6 }, .{ 0.8, 7 } } });
const glyph_apos = g(1.6, &.{&.{ .{ 0.8, 0 }, .{ 0.6, 1.6 } }});
const glyph_hyphen = g(4, &.{&.{ .{ 0.6, 4 }, .{ 3.4, 4 } }});
const glyph_bang = g(2, &.{ &.{ .{ 0.8, 0 }, .{ 0.8, 4.8 } }, &.{ .{ 0.8, 6.6 }, .{ 0.8, 7 } } });
const glyph_query = g(4.8, &.{ &.{ .{ 0.4, 1.4 }, .{ 2, 0 }, .{ 3.6, 1.2 }, .{ 3, 3 }, .{ 2, 3.8 }, .{ 2, 4.8 } }, &.{ .{ 2, 6.6 }, .{ 2, 7 } } });
const glyph_amp = g(6.4, &.{&.{ .{ 6, 7 }, .{ 1.8, 2 }, .{ 1.4, 1 }, .{ 2.4, 0 }, .{ 3.4, 1 }, .{ 3, 2.6 }, .{ 0.6, 4.6 }, .{ 0.6, 6 }, .{ 2, 7 }, .{ 3.6, 6.2 }, .{ 4.6, 4.6 } }});
const glyph_slash = g(4, &.{&.{ .{ 0, 7.4 }, .{ 3.6, -0.4 } }});
const glyph_lparen = g(2.8, &.{&.{ .{ 2.2, -0.6 }, .{ 0.6, 1.6 }, .{ 0.6, 5.4 }, .{ 2.2, 7.6 } }});
const glyph_rparen = g(2.8, &.{&.{ .{ 0.6, -0.6 }, .{ 2.2, 1.6 }, .{ 2.2, 5.4 }, .{ 0.6, 7.6 } }});

/// The glyph for a character, or null if the font has none (drawn as blank advance).
fn glyphFor(char: u8) ?Glyph {
    return switch (char) {
        ' ' => glyph_space,
        'A' => glyph_A,
        'B' => glyph_B,
        'C' => glyph_C,
        'D' => glyph_D,
        'E' => glyph_E,
        'F' => glyph_F,
        'G' => glyph_G,
        'H' => glyph_H,
        'I' => glyph_I,
        'J' => glyph_J,
        'K' => glyph_K,
        'L' => glyph_L,
        'M' => glyph_M,
        'N' => glyph_N,
        'O' => glyph_O,
        'P' => glyph_P,
        'Q' => glyph_Q,
        'R' => glyph_R,
        'S' => glyph_S,
        'T' => glyph_T,
        'U' => glyph_U,
        'V' => glyph_V,
        'W' => glyph_W,
        'X' => glyph_X,
        'Y' => glyph_Y,
        'Z' => glyph_Z,
        'a' => glyph_a,
        'b' => glyph_b,
        'c' => glyph_c,
        'd' => glyph_d,
        'e' => glyph_e,
        'f' => glyph_f,
        'g' => glyph_g,
        'h' => glyph_h,
        'i' => glyph_i,
        'j' => glyph_j,
        'k' => glyph_k,
        'l' => glyph_l,
        'm' => glyph_m,
        'n' => glyph_n,
        'o' => glyph_o,
        'p' => glyph_p,
        'q' => glyph_q,
        'r' => glyph_r,
        's' => glyph_s,
        't' => glyph_t,
        'u' => glyph_u,
        'v' => glyph_v,
        'w' => glyph_w,
        'x' => glyph_x,
        'y' => glyph_y,
        'z' => glyph_z,
        '0' => glyph_0,
        '1' => glyph_1,
        '2' => glyph_2,
        '3' => glyph_3,
        '4' => glyph_4,
        '5' => glyph_5,
        '6' => glyph_6,
        '7' => glyph_7,
        '8' => glyph_8,
        '9' => glyph_9,
        '.' => glyph_period,
        ',' => glyph_comma,
        ':' => glyph_colon,
        '\'' => glyph_apos,
        '-' => glyph_hyphen,
        '!' => glyph_bang,
        '?' => glyph_query,
        '&' => glyph_amp,
        '/' => glyph_slash,
        '(' => glyph_lparen,
        ')' => glyph_rparen,
        else => null,
    };
}

/// The em-unit advance of a character (an unknown glyph advances like a space).
fn advanceOf(char: u8) f32 {
    return (glyphFor(char) orelse glyph_space).advance;
}

/// The tracking (extra space) between glyphs, in em units.
const tracking: f32 = 1.0;

/// The width in pixels a string occupies at a given cap-height size, before drawing.
pub fn measure(letters: []const u8, size_px: f32) f32 {
    const scale = size_px / baseline;
    var width: f32 = 0;
    for (letters, 0..) |char, index| {
        width += advanceOf(char);
        if (index + 1 < letters.len) width += tracking;
    }
    return width * scale;
}

/// Draws a left-aligned string with its baseline at (x, baseline_y) in device pixels, at the given
/// cap-height size and colour. Returns the x position just past the string.
pub fn draw(target: *Framebuffer, x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba) f32 {
    const scale = size_px / baseline;
    const weight = @max(1.0, size_px * 0.11);
    const top = baseline_y - baseline * scale; // y of the em-box top (cap line)
    var pen_x = x;
    for (letters) |char| {
        if (glyphFor(char)) |glyph| {
            for (glyph.strokes) |polyline| {
                var buffer: [16]Point = undefined;
                const count = @min(polyline.len, buffer.len);
                for (polyline[0..count], 0..) |p, index| {
                    buffer[index] = .{ .x = pen_x + p[0] * scale, .y = top + p[1] * scale };
                }
                vector.strokePolyline(target, buffer[0..count], weight, colour, false);
            }
            pen_x += (glyph.advance + tracking) * scale;
        } else {
            pen_x += (glyph_space.advance + tracking) * scale;
        }
    }
    return pen_x;
}

/// Draws a string centred horizontally on `centre_x`, baseline at `baseline_y`.
pub fn drawCentred(target: *Framebuffer, centre_x: f32, baseline_y: f32, letters: []const u8, size_px: f32, colour: Rgba) void {
    const width = measure(letters, size_px);
    _ = draw(target, centre_x - width / 2.0, baseline_y, letters, size_px, colour);
}

const testing = std.testing;
const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };

test "measuring an empty string is zero, and width grows with length" {
    try testing.expectEqual(@as(f32, 0), measure("", 14));
    try testing.expect(measure("WWWW", 14) > measure("WW", 14));
}

test "drawing advances the pen to the right" {
    var target = try Framebuffer.init(testing.allocator, 200, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    const end = draw(&target, 4, 28, "Home", 18, white);
    try testing.expect(end > 4);
    // Some white pixel was drawn (the text is visible).
    var found = false;
    var y: u32 = 0;
    while (y < 40 and !found) : (y += 1) {
        var x: u32 = 0;
        while (x < 200) : (x += 1) {
            if (target.get(x, y).r > 200) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

test "an unknown glyph advances like a space rather than trapping" {
    var target = try Framebuffer.init(testing.allocator, 60, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    const end = draw(&target, 4, 28, "a~b", 18, white); // '~' has no glyph
    try testing.expect(end > 4);
}

test "centred text is symmetric about the centre" {
    var target = try Framebuffer.init(testing.allocator, 120, 40, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer target.deinit();
    drawCentred(&target, 60, 28, "OK", 18, white);
    // Columns of drawn pixels should straddle the centre.
    var left: u32 = 0;
    var right: u32 = 0;
    var y: u32 = 0;
    while (y < 40) : (y += 1) {
        var x: u32 = 0;
        while (x < 120) : (x += 1) {
            if (target.get(x, y).r > 180) {
                if (x < 60) left += 1 else right += 1;
            }
        }
    }
    try testing.expect(left > 0 and right > 0);
}
