#version 450

// One axis-aligned rectangle per draw, its clip-space position and colour supplied as a push
// constant. The four vertices of a triangle strip come from gl_VertexIndex, so no vertex
// buffer is needed: this is the compositor's layer quad, drawn on the GPU.
layout(push_constant) uniform Push {
    vec4 rect;  // xy = top-left in clip space, zw = width and height in clip units
    vec4 color;
} push;

void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 pos = push.rect.xy + corner * push.rect.zw;
    gl_Position = vec4(pos, 0.0, 1.0);
}
