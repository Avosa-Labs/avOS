# Offscreen triangle shaders

The `.spv` files are the pre-compiled SPIR-V the pipeline renderer embeds, so no shader
compiler is in the build. They are generated from the `.glsl` sources beside them, committed
as the pinned artifact (the same way fonts and the brand mark are committed, not built).

Regenerate after editing a source:

    glslc -O -fshader-stage=vert triangle.vert -o triangle.vert.spv
    glslc -O -fshader-stage=frag triangle.frag -o triangle.frag.spv

`glslc` is shaderc's compiler; any version that emits the same SPIR-V is fine, since the
committed `.spv` is what ships.
