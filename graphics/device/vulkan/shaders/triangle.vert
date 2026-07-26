#version 450

// A triangle centred in clip space: it covers the middle of the frame while the corners fall
// outside it, so a readback can tell rasterised geometry from the cleared background. Positions
// come from gl_VertexIndex, so no vertex buffer or input state is needed.
void main() {
    vec2 positions[3] = vec2[](
        vec2( 0.0, -0.8),
        vec2(-0.8,  0.8),
        vec2( 0.8,  0.8)
    );
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
