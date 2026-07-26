#version 450

// A quad per textured draw (a glyph or an image), positioned in clip space from the push
// constant, with the corner as the texture coordinate.
layout(push_constant) uniform Push {
    vec4 clip_rect; // xy = top-left in clip space, zw = width and height in clip units
    vec4 color;
} push;
layout(location = 0) out vec2 uv;

void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    uv = corner; // (0,0) top-left .. (1,1) bottom-right
    vec2 pos = push.clip_rect.xy + corner * push.clip_rect.zw;
    gl_Position = vec4(pos, 0.0, 1.0);
}
