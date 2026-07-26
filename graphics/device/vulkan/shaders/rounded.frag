#version 450

layout(push_constant) uniform Push {
    vec4 clip_rect;
    vec4 color;
    vec4 geom;
    vec4 radius;
} push;
layout(location = 0) out vec4 out_color;

// Signed distance to a rounded box centred at the origin, half-extent b, corner radius r.
float sd_round_box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 p = gl_FragCoord.xy - push.geom.xy;
    float d = sd_round_box(p, push.geom.zw, push.radius.x);
    // One-pixel antialiased coverage: fully inside below -0.5, fully outside above 0.5.
    float coverage = clamp(0.5 - d, 0.0, 1.0);
    out_color = vec4(push.color.rgb, push.color.a * coverage);
}
