#version 450

// The triangle is a solid, exact colour so the readback is unambiguous.
layout(location = 0) out vec4 color;
void main() {
    color = vec4(0.0, 1.0, 0.0, 1.0); // green
}
