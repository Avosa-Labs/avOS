#version 450

layout(push_constant) uniform Push {
    vec4 clip_rect;
    vec4 color_top;
    vec4 color_bottom;
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
    vec2 centre = push.geom.xy;
    vec2 half_extent = push.geom.zw;
    float d = sd_round_box(gl_FragCoord.xy - centre, half_extent, push.radius.x);
    // One-pixel antialiased coverage: fully inside below -0.5, fully outside above 0.5.
    float coverage = clamp(0.5 - d, 0.0, 1.0);

    // Vertical gradient: 0 at the box top, 1 at the box bottom.
    float t = clamp((gl_FragCoord.y - (centre.y - half_extent.y)) / (2.0 * half_extent.y), 0.0, 1.0);
    vec4 fill = mix(push.color_top, push.color_bottom, t);

    out_color = vec4(fill.rgb, fill.a * coverage);
}
