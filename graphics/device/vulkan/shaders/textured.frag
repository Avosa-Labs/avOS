#version 450

layout(push_constant) uniform Push {
    vec4 clip_rect;
    vec4 color;
} push;
layout(set = 0, binding = 0) uniform sampler2D atlas;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;

void main() {
    // The atlas holds coverage in its red channel; the colour is the ink.
    float coverage = texture(atlas, uv).r;
    out_color = vec4(push.color.rgb, push.color.a * coverage);
}
