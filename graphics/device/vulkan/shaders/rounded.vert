#version 450

// A quad per rounded rectangle, positioned in clip space from the push constant. The fragment
// stage cuts the corners and applies the vertical gradient; the vertex stage only places the quad.
layout(push_constant) uniform Push {
    vec4 clip_rect;    // xy = top-left in clip space, zw = width and height in clip units
    vec4 color_top;
    vec4 color_bottom;
    vec4 geom;         // xy = centre in pixels, zw = half-extent in pixels
    vec4 radius;       // x = corner radius in pixels
} push;

void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = push.clip_rect.xy + corner * push.clip_rect.zw;
    gl_Position = vec4(pos, 0.0, 1.0);
}
