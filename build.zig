const std = @import("std");
const line = @import("compat/zig/line.zig");

/// Files and directories the formatter owns. Generated output and the local
/// tool directory are excluded because they are not authored source.
const formatted_paths = [_][]const u8{
    "build.zig",
    "boot",
    "brand",
    "compat",
    "core",
    "design",
    "emulator",
    "ipc",
    "runtimes",
    "services",
    "session",
    "shell",
    "simulator",
    "storage",
    "tests",
    "tools",
};

pub fn build(b: *std.Build) void {
    rejectUnqualifiedCompiler(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const brand_path = b.option(
        []const u8,
        "brand",
        "Brand document to build against (default brand/current/brand.json)",
    ) orelse "brand/current/brand.json";

    const compat_module = b.createModule(.{
        .root_source_file = b.path("compat/zig/compat.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_module = b.createModule(.{
        .root_source_file = b.path("ipc/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const runtime_native_module = b.createModule(.{
        .root_source_file = b.path("runtimes/native/native.zig"),
        .target = target,
        .optimize = optimize,
    });

    const runtime_bridge_module = b.createModule(.{
        .root_source_file = b.path("runtimes/bridge/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });

    const design_module = b.createModule(.{
        .root_source_file = b.path("design/design.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shell_module = b.createModule(.{
        .root_source_file = b.path("shell/shell.zig"),
        .target = target,
        .optimize = optimize,
    });

    const runtime_android_module = b.createModule(.{
        .root_source_file = b.path("runtimes/android/android.zig"),
        .target = target,
        .optimize = optimize,
    });

    const boot_module = b.createModule(.{
        .root_source_file = b.path("boot/boot.zig"),
        .target = target,
        .optimize = optimize,
    });

    const storage_module = b.createModule(.{
        .root_source_file = b.path("storage/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    const session_module = b.createModule(.{
        .root_source_file = b.path("session/session.zig"),
        .target = target,
        .optimize = optimize,
    });

    const services_module = b.createModule(.{
        .root_source_file = b.path("services/services.zig"),
        .target = target,
        .optimize = optimize,
    });

    const simulator_module = b.createModule(.{
        .root_source_file = b.path("simulator/simulator.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_module = b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    runtime_native_module.addImport("core", core_module);
    runtime_native_module.addImport("host_bridge", runtime_bridge_module);
    runtime_android_module.addImport("core", core_module);
    runtime_android_module.addImport("host_bridge", runtime_bridge_module);
    runtime_bridge_module.addImport("core", core_module);
    services_module.addImport("core", core_module);
    services_module.addImport("ipc", ipc_module);
    session_module.addImport("core", core_module);
    storage_module.addImport("core", core_module);
    shell_module.addImport("core", core_module);
    shell_module.addImport("design", design_module);
    simulator_module.addImport("core", core_module);
    simulator_module.addImport("boot", boot_module);

    const emulator_module = b.createModule(.{
        .root_source_file = b.path("emulator/emulator.zig"),
        .target = target,
        .optimize = optimize,
    });

    const brand_module = b.createModule(.{
        .root_source_file = b.path("brand/brand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "brand_config", .module = configModule(b, brand_path) },
        },
    });

    const tools = [_]Tool{
        .{
            .name = "version-lock",
            .root = "tools/version-lock/main.zig",
            .description = "Re-resolve the toolchain manifest from official release sources for review",
        },
        .{
            .name = "brand-check",
            .root = "tools/brand-check/main.zig",
            .description = "Verify no brand leak outside the brand resource layer",
        },
        .{
            .name = "palette-check",
            .root = "tools/palette-check/main.zig",
            .description = "Verify raw colour is constructed only in the design token layer",
        },
        .{
            .name = "boundary-check",
            .root = "tools/boundary-check/main.zig",
            .description = "Verify a default app reaches the system only through its framework",
        },
        .{
            .name = "convention-check",
            .root = "tools/convention-check/main.zig",
            .description = "Verify authoring conventions: attribution, comments, and naming",
        },
        .{
            .name = "standin-check",
            .root = "tools/standin-check/main.zig",
            .description = "Verify no stand-in reaches production code",
        },
        .{
            .name = "engine-lock",
            .root = "tools/engine-lock/main.zig",
            .description = "Verify every pinned C engine has a source, digest, licence, adapter, and ADR",
        },
        .{
            .name = "vendor-engines",
            .root = "tools/vendor-engines/main.zig",
            .description = "Fetch each pinned engine, verify its digest, and unpack it into the local cache",
        },
        .{
            .name = "example-check",
            .root = "tools/example-check/main.zig",
            .description = "Verify the SDK example registry and the examples on disk are the same set",
        },
        .{
            .name = "image-build",
            .root = "tools/image-build/main.zig",
            .description = "Reduce a directory to a system image digest, deterministically",
        },
        .{
            .name = "image-sign",
            .root = "tools/image-sign/main.zig",
            .description = "Sign an image digest, or check a signature against one",
        },
        .{
            .name = "source-repro",
            .root = "tools/source-repro/main.zig",
            .description = "Build the same source twice and compare the images",
        },
        .{
            .name = "doctor",
            .root = "tools/doctor/main.zig",
            .description = "Report host, compiler, and pin health",
        },
        .{
            .name = "sbom",
            .root = "tools/sbom/main.zig",
            .description = "Emit a software bill of materials for the source tree",
        },
        .{
            .name = "license",
            .root = "tools/license/main.zig",
            .description = "Check third-party dependency license compliance",
        },
        .{
            .name = "rollback",
            .root = "tools/rollback/main.zig",
            .description = "Decide whether a rollback to an earlier version is permitted",
        },
        .{
            .name = "package-sign",
            .root = "tools/package-sign/main.zig",
            .description = "Decide whether a signed application package may be distributed",
        },
        .{
            .name = "release",
            .root = "tools/release/main.zig",
            .description = "Drive a release through the rollout rings, one promotion at a time",
        },
        .{
            .name = "crash-symbols",
            .root = "tools/crash-symbols/main.zig",
            .description = "Symbolicate a fault address against a build's symbols",
        },
        .{
            .name = "accessibility-audit",
            .root = "tools/accessibility-audit/main.zig",
            .description = "Audit surfaces against the accessibility baseline",
        },
        .{
            .name = "localization",
            .root = "tools/localization/main.zig",
            .description = "Verify localization completeness and fallback coverage",
        },
        .{
            .name = "performance-check",
            .root = "tools/performance/main.zig",
            .description = "Check performance measurements against their budgets",
        },
        .{
            .name = "certification",
            .root = "tools/certification/main.zig",
            .description = "Assemble launch-readiness criteria into a go/no-go decision",
        },
        .{
            .name = "zig-version",
            .root = "tools/zig-version/main.zig",
            .description = "Decide whether a compiler version is the pinned canonical one",
        },
        .{
            .name = "power",
            .root = "tools/power/main.zig",
            .description = "Check power-draw measurements against their budgets",
        },
        .{
            .name = "test-vector",
            .root = "tools/test-vector/main.zig",
            .description = "Validate a test-vector manifest for uniqueness and known outcomes",
        },
        .{
            .name = "audit-inspect",
            .root = "tools/audit-inspect/main.zig",
            .description = "Inspect an audit ledger for an unbroken sequence and intact hash chain",
        },
        .{
            .name = "icon-build",
            .root = "tools/icon-build/main.zig",
            .description = "Reduce an icon set to a single deterministic digest",
        },
        .{
            .name = "icon-lint",
            .root = "tools/icon-lint/main.zig",
            .description = "Verify UI glyphs are currentColor only and 24x24",
        },
        .{
            .name = "protocol-codegen",
            .root = "tools/protocol-codegen/main.zig",
            .description = "Validate a protocol definition and emit a deterministic binding signature",
        },
    };

    const test_step = b.step("test", "Run unit tests");

    // Compiles the vendored-engine modules without running their tests, so the engine-cache
    // gate can confirm a warm build recompiles nothing without paying for the whole test suite.
    const engine_compile_step = b.step("engine-compile", "Compile the vendored-engine modules, do not run their tests");

    addModuleTests(b, test_step, "brand", brand_module);
    addModuleTests(b, test_step, "compat", compat_module);
    addModuleTests(b, test_step, "core", core_module);
    addModuleTests(b, test_step, "ipc", ipc_module);
    addModuleTests(b, test_step, "runtime-native", runtime_native_module);
    addModuleTests(b, test_step, "runtime-android", runtime_android_module);
    addModuleTests(b, test_step, "runtime-bridge", runtime_bridge_module);

    const runtime_web_module = b.createModule(.{
        .root_source_file = b.path("runtimes/web/web.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_web_module.addImport("core", core_module);
    runtime_web_module.addImport("host_bridge", runtime_bridge_module);
    addModuleTests(b, test_step, "runtime-web", runtime_web_module);

    const runtime_apple_module = b.createModule(.{
        .root_source_file = b.path("runtimes/apple-portability/apple_portability.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "runtime-apple-portability", runtime_apple_module);

    const graphics_module = b.createModule(.{
        .root_source_file = b.path("graphics/graphics.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_module.addImport("design", design_module);
    addModuleTests(b, test_step, "graphics", graphics_module);

    const input_module = b.createModule(.{
        .root_source_file = b.path("input/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "input", input_module);

    const communications_module = b.createModule(.{
        .root_source_file = b.path("communications/communications.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "communications", communications_module);

    const media_module = b.createModule(.{
        .root_source_file = b.path("media/media.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "media", media_module);

    const store_module = b.createModule(.{
        .root_source_file = b.path("store/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "store", store_module);

    const sdk_module = b.createModule(.{
        .root_source_file = b.path("sdk/sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "sdk", sdk_module);

    // The simulator's device profile drives a simulated embodied device through the SDK's agent
    // contract, so the embodied path is exercised for real.
    simulator_module.addImport("sdk", sdk_module);

    const applications_module = b.createModule(.{
        .root_source_file = b.path("applications/applications.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "applications", applications_module);
    addModuleTests(b, test_step, "services", services_module);
    addModuleTests(b, test_step, "session", session_module);
    addModuleTests(b, test_step, "storage", storage_module);
    boot_module.addImport("core", core_module);
    addModuleTests(b, test_step, "boot", boot_module);

    const hardware_module = b.createModule(.{
        .root_source_file = b.path("hardware/hardware.zig"),
        .target = target,
        .optimize = optimize,
    });
    hardware_module.addImport("core", core_module);
    addModuleTests(b, test_step, "hardware", hardware_module);

    const agents_module = b.createModule(.{
        .root_source_file = b.path("agents/agents.zig"),
        .target = target,
        .optimize = optimize,
    });
    agents_module.addImport("core", core_module);
    agents_module.addImport("ipc", ipc_module);
    addModuleTests(b, test_step, "agents", agents_module);

    applications_module.addImport("core", core_module);
    applications_module.addImport("agents", agents_module);
    applications_module.addImport("design", design_module);

    // The SDK's worked examples are real programs on the application frame: they import
    // the same core and the same framework a shipped app does, so a passing example is
    // proof the real path runs, not that a mock did.
    const examples_module = b.createModule(.{
        .root_source_file = b.path("examples/examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    examples_module.addImport("core", core_module);
    examples_module.addImport("applications", applications_module);
    examples_module.addImport("sdk", sdk_module);
    addModuleTests(b, test_step, "examples", examples_module);

    const networking_module = b.createModule(.{
        .root_source_file = b.path("networking/networking.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "networking", networking_module);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_module.addImport("core", core_module);
    addModuleTests(b, test_step, "kernel", kernel_module);

    const packaging_module = b.createModule(.{
        .root_source_file = b.path("packaging/packaging.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleTests(b, test_step, "packaging", packaging_module);

    const security_module = b.createModule(.{
        .root_source_file = b.path("security/security.zig"),
        .target = target,
        .optimize = optimize,
    });
    security_module.addImport("core", core_module);
    security_module.addImport("boot", boot_module);
    security_module.addImport("hardware", hardware_module);
    addModuleTests(b, test_step, "security", security_module);
    addModuleTests(b, test_step, "design", design_module);
    addModuleTests(b, test_step, "shell", shell_module);

    // The component runtime links a pinned native library. It is built only
    // when that library is present, so a checkout that has not bootstrapped it
    // still builds and tests everything else rather than failing wholesale.
    const wasm_runtime_root = wasmRuntimeRoot(b);
    if (wasm_runtime_root) |root| {
        const wasm_module = b.createModule(.{
            .root_source_file = b.path("runtimes/wasm/wasm.zig"),
            .target = target,
            .optimize = optimize,
        });
        wasm_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{root}) });
        wasm_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{root}) });
        wasm_module.linkSystemLibrary("wasmtime", .{});
        wasm_module.link_libc = true;
        wasm_module.addImport("core", core_module);
        addModuleTests(b, test_step, "runtime-wasm", wasm_module);
    }

    // The Vulkan device adapter (ADR 0004) is built only where the pinned Vulkan headers have
    // been vendored (`zig build vendor-engines`). Absent, the checkout still builds everything
    // else and falls back to the software path; present, the adapter compiles against the
    // pinned headers and its loader and instance tests run.
    var vulkan_module: ?*std.Build.Module = null;
    if (vulkanHeadersRoot(b)) |include| {
        const module = b.createModule(.{
            .root_source_file = b.path("graphics/device/vulkan/vulkan.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addIncludePath(.{ .cwd_relative = include });
        module.link_libc = true;
        addModuleTests(b, test_step, "device-vulkan", module);
        addCompileCheck(b, engine_compile_step, "device-vulkan", module);
        vulkan_module = module;
    }

    // The FreeType glyph rasterizer (ADR 0005) is compiled from the vendored source where it is
    // present, and its tests rasterize real glyphs. Absent, the shell falls back to the
    // pure-Zig rasterizer. The module list is narrowed to what the text path needs (see
    // graphics/text/freetype/ftmodules.h), selected with FT_CONFIG_MODULES_H.
    var freetype_module: ?*std.Build.Module = null;
    if (freetypeRoot(b)) |root| {
        const module = b.createModule(.{
            .root_source_file = b.path("graphics/text/freetype/freetype.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("design", design_module);
        module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{root}) });
        module.addIncludePath(b.path("graphics/text/freetype")); // the custom ftmodules.h
        module.link_libc = true;
        const ft_flags = [_][]const u8{ "-DFT2_BUILD_LIBRARY", "-DFT_CONFIG_MODULES_H=<ftmodules.h>" };
        module.addCSourceFiles(.{
            .root = .{ .cwd_relative = root },
            .files = &.{
                "src/base/ftbase.c",       "src/base/ftinit.c",   "src/base/ftsystem.c",
                "src/base/ftdebug.c",      "src/base/ftbbox.c",   "src/base/ftbitmap.c",
                "src/base/ftglyph.c",      "src/base/ftmm.c",     "src/truetype/truetype.c",
                "src/sfnt/sfnt.c",         "src/smooth/smooth.c", "src/autofit/autofit.c",
                "src/psnames/psnames.c",   "src/raster/raster.c", "src/cff/cff.c",
                "src/pshinter/pshinter.c", "src/psaux/psaux.c",   "src/gzip/ftgzip.c",
            },
            .flags = &ft_flags,
        });
        addModuleTests(b, test_step, "text-freetype", module);
        addCompileCheck(b, engine_compile_step, "text-freetype", module);
        freetype_module = module;
    }

    // The text-on-GPU bridge: rasterise a glyph with FreeType, upload it as coverage, and draw it
    // with the Vulkan device. Built only where both engines are vendored, so it composes the two
    // adapters — real shaped-glyph coverage becoming pixels on the device.
    if (vulkan_module != null and freetype_module != null) {
        const bridge = b.createModule(.{
            .root_source_file = b.path("graphics/text/gpu_glyph.zig"),
            .target = target,
            .optimize = optimize,
        });
        bridge.addImport("vulkan", vulkan_module.?);
        bridge.addImport("freetype", freetype_module.?);
        bridge.addImport("design", design_module);
        addModuleTests(b, test_step, "text-gpu-glyph", bridge);
    }

    // The compositor-on-GPU bridge: encode a retained tree's display lists to quads and draw the
    // whole frame in one pass on the Vulkan device. Built where the Vulkan engine is vendored, so
    // it stands the software compositor's primitives up on the real device.
    if (vulkan_module != null) {
        const scene_bridge = b.createModule(.{
            .root_source_file = b.path("graphics/device/gpu_composite.zig"),
            .target = target,
            .optimize = optimize,
        });
        scene_bridge.addImport("vulkan", vulkan_module.?);
        scene_bridge.addImport("graphics", graphics_module);
        addModuleTests(b, test_step, "device-gpu-composite", scene_bridge);
    }

    // The HarfBuzz shaper (ADR 0006), compiled from its single-file amalgamation where the source
    // is vendored. Absent, the layout falls back to unshaped advances.
    var harfbuzz_module: ?*std.Build.Module = null;
    if (harfbuzzRoot(b)) |root| {
        const module = b.createModule(.{
            .root_source_file = b.path("graphics/text/harfbuzz/harfbuzz.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("design", design_module);
        module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{root}) });
        module.link_libcpp = true; // the amalgamation is C++
        module.addCSourceFile(.{
            .file = .{ .cwd_relative = b.fmt("{s}/src/harfbuzz.cc", .{root}) },
            .flags = &.{"-DHB_NO_MT"},
        });
        addModuleTests(b, test_step, "text-harfbuzz", module);
        addCompileCheck(b, engine_compile_step, "text-harfbuzz", module);
        harfbuzz_module = module;
    }

    // The text-run path: shape a string with HarfBuzz, rasterize each shaped glyph with FreeType,
    // assemble the run's coverage, and draw it through the Vulkan device. Built only where all
    // three engines are vendored, so it stands on the whole text pipeline at once.
    if (vulkan_module != null and freetype_module != null and harfbuzz_module != null) {
        const run_module = b.createModule(.{
            .root_source_file = b.path("graphics/text/gpu_text.zig"),
            .target = target,
            .optimize = optimize,
        });
        run_module.addImport("vulkan", vulkan_module.?);
        run_module.addImport("freetype", freetype_module.?);
        run_module.addImport("harfbuzz", harfbuzz_module.?);
        run_module.addImport("design", design_module);
        addModuleTests(b, test_step, "text-gpu-run", run_module);
    }

    addModuleTests(b, test_step, "simulator", simulator_module);
    addModuleTests(b, test_step, "emulator", emulator_module);

    for (tools) |tool| {
        const module = b.createModule(.{
            .root_source_file = b.path(tool.root),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "brand", .module = brand_module },
                .{ .name = "packaging", .module = packaging_module },
            },
        });

        const exe = b.addExecutable(.{ .name = tool.name, .root_module = module });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |forwarded| run.addArgs(forwarded);
        b.step(tool.name, tool.description).dependOn(&run.step);

        addModuleTests(b, test_step, tool.name, module);
    }

    // The design extractor is a generator, not a no-arg gate: it reads the developer-
    // local reference design, whose path is supplied out of source (env
    // DESIGN_REFERENCE_PATH or .local/design.zon) and never hardcoded. Configured → it
    // runs and writes the committable conformance vectors; absent → a visible skip that
    // still succeeds, so a machine without the design is never silently green.
    {
        const de_module = b.createModule(.{
            .root_source_file = b.path("tools/design-extract/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compat", .module = compat_module }},
        });
        const de_exe = b.addExecutable(.{ .name = "design-extract", .root_module = de_module });
        b.installArtifact(de_exe);
        addModuleTests(b, test_step, "design-extract", de_module);

        const de_step = b.step("design-extract", "Extract the reference design into conformance vectors (needs a configured design reference)");
        if (designReferencePath(b)) |ref_path| {
            const run = b.addRunArtifact(de_exe);
            run.step.dependOn(b.getInstallStep());
            run.addArgs(&.{ ref_path, "test-vectors/design" });
            de_step.dependOn(&run.step);
        } else {
            const notice = b.addSystemCommand(&.{ "sh", "-c", "echo 'design-extract: no design reference configured (set DESIGN_REFERENCE_PATH or write .local/design.zon); skipping extraction — vectors unchanged' >&2" });
            de_step.dependOn(&notice.step);
        }
    }

    // The map-or-justify gate reads the committed vectors (not the design), so it is a
    // real no-arg gate that runs everywhere. It needs the design tokens to know what is
    // mapped, so it carries the design module.
    {
        const dc_module = b.createModule(.{
            .root_source_file = b.path("tools/design-conformance/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_module },
                .{ .name = "design", .module = design_module },
            },
        });
        const dc_exe = b.addExecutable(.{ .name = "design-conformance", .root_module = dc_module });
        b.installArtifact(dc_exe);
        const dc_run = b.addRunArtifact(dc_exe);
        dc_run.step.dependOn(b.getInstallStep());
        b.step("design-conformance", "Verify every significant design colour is mapped to a token or justified").dependOn(&dc_run.step);
        addModuleTests(b, test_step, "design-conformance", dc_module);
    }

    const inspector_module = b.createModule(.{
        .root_source_file = b.path("simulator/inspector/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "core", .module = core_module },
            .{ .name = "simulator", .module = simulator_module },
            .{ .name = "boot", .module = boot_module },
        },
    });
    const inspector = b.addExecutable(.{ .name = "simulator", .root_module = inspector_module });
    b.installArtifact(inspector);

    const run_simulator = b.addRunArtifact(inspector);
    run_simulator.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_simulator.addArgs(forwarded);
    b.step("simulator", "Run a scenario against the control plane").dependOn(&run_simulator.step);

    addModuleTests(b, test_step, "inspector", inspector_module);

    // The frame renderer: paints a demonstration display list to a PNG, the render pipeline's first
    // viewable output.
    const frame_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/frame_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const frame_exe = b.addExecutable(.{ .name = "frame", .root_module = frame_module });
    b.installArtifact(frame_exe);
    const run_frame = b.addRunArtifact(frame_exe);
    run_frame.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_frame.addArgs(forwarded);
    b.step("frame", "Render a demonstration frame to a PNG").dependOn(&run_frame.step);

    // The icon sheet: every app tile with its glyph, rendered to a PNG.
    const icons_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/icons_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const icons_exe = b.addExecutable(.{ .name = "icons", .root_module = icons_module });
    b.installArtifact(icons_exe);
    const run_icons = b.addRunArtifact(icons_exe);
    run_icons.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_icons.addArgs(forwarded);
    b.step("icons", "Render the app icon sheet to a PNG").dependOn(&run_icons.step);

    // The home screen rendered to a PNG.
    const home_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/home_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const home_exe = b.addExecutable(.{ .name = "home", .root_module = home_module });
    b.installArtifact(home_exe);
    const run_home = b.addRunArtifact(home_exe);
    run_home.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_home.addArgs(forwarded);
    b.step("home", "Render the home screen to a PNG").dependOn(&run_home.step);

    // The motion demo: the agent-card entrance as a sequence of animation frames.
    const motion_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/motion_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const motion_exe = b.addExecutable(.{ .name = "motion", .root_module = motion_module });
    b.installArtifact(motion_exe);
    const run_motion = b.addRunArtifact(motion_exe);
    run_motion.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_motion.addArgs(forwarded);
    b.step("motion", "Render the agent-card entrance as animation frames").dependOn(&run_motion.step);

    // A named shell screen rendered to a PNG.
    const screen_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/screen_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const screen_exe = b.addExecutable(.{ .name = "screen", .root_module = screen_module });
    b.installArtifact(screen_exe);
    const run_screen = b.addRunArtifact(screen_exe);
    run_screen.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_screen.addArgs(forwarded);
    b.step("screen", "Render a named shell screen to a PNG").dependOn(&run_screen.step);

    // A named app screen rendered to a PNG.
    const app_module = b.createModule(.{
        .root_source_file = b.path("graphics/paint/app_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const app_exe = b.addExecutable(.{ .name = "app", .root_module = app_module });
    b.installArtifact(app_exe);
    const run_app = b.addRunArtifact(app_exe);
    run_app.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_app.addArgs(forwarded);
    b.step("app", "Render a named app screen to a PNG").dependOn(&run_app.step);

    // The shared render bridge: turns a real control-plane run into the designed surfaces. Both the
    // headless frame writer and the windowed desktop shell render through it.
    const live_render_module = b.createModule(.{
        .root_source_file = b.path("simulator/shell/live_render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "simulator", .module = simulator_module },
            .{ .name = "graphics", .module = graphics_module },
            .{ .name = "design", .module = design_module },
            .{ .name = "applications", .module = applications_module },
        },
    });
    // The live surfaces carry a per-screen pixel gate (P6.3): its tests render each designed
    // surface and sample the framebuffer at the layout engine's rectangles, so they run here.
    addModuleTests(b, test_step, "live_render", live_render_module);

    // The headless shell: renders the live surfaces to PNG files, for hosts without a display.
    const live_module = b.createModule(.{
        .root_source_file = b.path("simulator/shell/live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "live_render", .module = live_render_module },
            .{ .name = "graphics", .module = graphics_module },
            .{ .name = "design", .module = design_module },
        },
    });
    const live_exe = b.addExecutable(.{ .name = "shell", .root_module = live_module });
    b.installArtifact(live_exe);
    const run_live = b.addRunArtifact(live_exe);
    run_live.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_live.addArgs(forwarded);
    b.step("shell", "Render a live designed surface from the real run to a PNG").dependOn(&run_live.step);

    // The windowed desktop shell: the OS in a real window, on the GPU, with input — built only when a
    // display library (SDL2) is present, so headless CI stays green while a desktop gets the real thing.
    // SDL is backed by Metal/AppKit on macOS and Vulkan/Wayland on Linux.
    const run_step = b.step("run", "Run the OS in a window (needs SDL2); falls back to rendering frames");
    if (sdlPrefix(b)) |prefix| {
        const desktop_module = b.createModule(.{
            .root_source_file = b.path("simulator/desktop/desktop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "live_render", .module = live_render_module },
                .{ .name = "graphics", .module = graphics_module },
                .{ .name = "design", .module = design_module },
            },
        });
        // The binding is declared directly (simulator/desktop/sdl.zig), so no header include is
        // needed; only the SDL2 library is linked, from the detected prefix. pkg-config is disabled so
        // SDL2main is not pulled in, since the shell provides its own entry point.
        desktop_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        desktop_module.linkSystemLibrary("SDL2", .{ .use_pkg_config = .no });
        desktop_module.link_libc = true;
        const desktop_exe = b.addExecutable(.{ .name = "desktop", .root_module = desktop_module });
        b.installArtifact(desktop_exe);
        const run_desktop = b.addRunArtifact(desktop_exe);
        run_desktop.step.dependOn(b.getInstallStep());
        if (b.args) |forwarded| run_desktop.addArgs(forwarded);
        run_step.dependOn(&run_desktop.step);
    } else {
        // No display library: play the whole session to image frames instead.
        const run_session = b.addRunArtifact(live_exe);
        run_session.step.dependOn(b.getInstallStep());
        run_session.addArg("session");
        if (b.args) |forwarded| run_session.addArgs(forwarded);
        run_step.dependOn(&run_session.step);
    }

    // Acceptance tests hold a milestone to what it must demonstrate. They sit
    // outside the modules they exercise, so they can only use the interfaces a
    // real caller has.
    const acceptance_module = b.createModule(.{
        .root_source_file = b.path("tests/acceptance/acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "design", .module = design_module },
            .{ .name = "shell", .module = shell_module },
            .{ .name = "brand", .module = brand_module },
            .{ .name = "runtime_android", .module = runtime_android_module },
            .{ .name = "session", .module = session_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "examples", .module = examples_module },
        },
    });
    addModuleTests(b, test_step, "acceptance", acceptance_module);

    // Adversarial and property suites exercise the pure decision modules from outside, phrasing each
    // security invariant as an attack that must fail or a property that must hold across its input space.
    const adversarial_module = b.createModule(.{
        .root_source_file = b.path("tests/adversarial/adversarial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "applications", .module = applications_module },
            .{ .name = "agents", .module = agents_module },
            .{ .name = "session", .module = session_module },
            .{ .name = "emulator", .module = emulator_module },
            .{ .name = "shell", .module = shell_module },
        },
    });
    addModuleTests(b, test_step, "adversarial", adversarial_module);

    const property_module = b.createModule(.{
        .root_source_file = b.path("tests/property/property.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "applications", .module = applications_module },
            .{ .name = "session", .module = session_module },
            .{ .name = "emulator", .module = emulator_module },
            .{ .name = "shell", .module = shell_module },
        },
    });
    addModuleTests(b, test_step, "property", property_module);

    // The security floor, contract-vector conformance, and integration flows compose several modules
    // per test, so they import the packaging modules as well.
    const security_floor_module = b.createModule(.{
        .root_source_file = b.path("tests/security/floor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "applications", .module = applications_module },
            .{ .name = "session", .module = session_module },
            .{ .name = "emulator", .module = emulator_module },
            .{ .name = "shell", .module = shell_module },
            .{ .name = "packaging", .module = packaging_module },
        },
    });
    addModuleTests(b, test_step, "security-floor", security_floor_module);

    const contract_module = b.createModule(.{
        .root_source_file = b.path("tests/contract/vectors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "session", .module = session_module },
            .{ .name = "packaging", .module = packaging_module },
            .{ .name = "emulator", .module = emulator_module },
        },
    });
    addModuleTests(b, test_step, "contract", contract_module);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/flows.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "applications", .module = applications_module },
            .{ .name = "session", .module = session_module },
            .{ .name = "shell", .module = shell_module },
            .{ .name = "packaging", .module = packaging_module },
        },
    });
    addModuleTests(b, test_step, "integration", integration_module);

    // Recovery is held apart from the acceptance suites because it asks a
    // different question: not whether a component behaves when the medium
    // beneath it is sound, but what happens when it is not.
    const recovery_module = b.createModule(.{
        .root_source_file = b.path("tests/recovery/recovery.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "storage", .module = storage_module },
        },
    });
    addModuleTests(b, test_step, "recovery", recovery_module);

    // Randomized decoder testing. Runs on every build with a fixed seed so a
    // failure reproduces; the deeper exploratory runs use the compiler's own
    // fuzzer through the `fuzz` step.
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "ipc", .module = ipc_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "session", .module = session_module },
        },
    });
    addModuleTests(b, test_step, "fuzz", fuzz_module);

    const fuzz_tests = b.addTest(.{ .name = "fuzz-explore", .root_module = fuzz_module });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    if (b.args) |forwarded| run_fuzz.addArgs(forwarded);
    b.step("fuzz", "Explore the decoders with the compiler's fuzzer").dependOn(&run_fuzz.step);

    // Measurements against the budgets in docs/performance/budgets.md. Part of
    // the ordinary test run, so a regression is caught by the change that
    // introduces it rather than by whoever next remembers to benchmark.
    //
    // The measurements always run and their budget and correctness assertions
    // always hold; printing the human-readable figures is opt-in. Off by default
    // because the figures go to stderr, and under the build's test runner that
    // races the progress rendering and is reported as a failed command even though
    // every test passes. A developer who wants the numbers builds with
    // -Dbench-report=true.
    const bench_report = b.option(
        bool,
        "bench-report",
        "Print benchmark measurements to stderr (off by default; see docs/operations/build.md)",
    ) orelse false;
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "report", bench_report);

    const performance_module = b.createModule(.{
        .root_source_file = b.path("tests/performance/performance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "ipc", .module = ipc_module },
            .{ .name = "storage", .module = storage_module },
            .{ .name = "bench_options", .module = bench_options.createModule() },
        },
    });
    addModuleTests(b, test_step, "performance", performance_module);

    const format = b.addFmt(.{ .paths = &formatted_paths });
    b.step("format", "Apply canonical formatting").dependOn(&format.step);

    const format_check = b.addFmt(.{ .paths = &formatted_paths, .check = true });
    b.step("format-check", "Verify formatting without writing").dependOn(&format_check.step);
}

/// Locates the pinned component runtime, if it has been bootstrapped.
///
/// The version comes from the manifest rather than from a constant here, so the
/// build always links the release the manifest pins and never a stale copy left
/// in the tool directory.
/// The install prefix under which SDL2's header lives, or null if SDL2 is not installed. Checks the
/// common Homebrew and system locations so a desktop host is detected without any configuration, while
/// a headless host (no SDL) falls back to rendering frames.
fn sdlPrefix(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const candidates = [_][]const u8{ "/opt/homebrew", "/usr/local", "/usr" };
    for (candidates) |prefix| {
        const include = b.fmt("{s}/include/SDL2", .{prefix});
        var directory = b.build_root.handle.openDir(io, include, .{}) catch continue;
        directory.close(io);
        return prefix;
    }
    return null;
}

fn wasmRuntimeRoot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const gpa = b.allocator;

    const manifest = b.build_root.handle.readFileAlloc(io, "toolchain.lock.json", gpa, .limited(8 * 1024 * 1024)) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, manifest, .{}) catch return null;

    const components = switch (parsed.value.object.get("components") orelse return null) {
        .array => |array| array,
        else => return null,
    };
    for (components.items) |entry| {
        const component = switch (entry) {
            .object => |object| object,
            else => continue,
        };
        const name = switch (component.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, name, "wasmtime")) continue;
        const version = switch (component.get("version") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const root = b.fmt(".tools/wasmtime-{s}", .{version});
        var directory = b.build_root.handle.openDir(io, root, .{}) catch return null;
        directory.close(io);
        return root;
    }
    return null;
}

/// The include path of the vendored Vulkan headers, or null if they are not present. The
/// device adapter (ADR 0004) builds only when this returns a path; `zig build vendor-engines`
/// fetches and verifies the pinned headers into the cache this looks for.
fn vulkanHeadersRoot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const include = ".engines/vulkan-headers/include";
    const marker = include ++ "/vulkan/vulkan_core.h";
    b.build_root.handle.access(io, marker, .{}) catch return null;
    return include;
}

/// The root of the vendored FreeType source, or null if it is not present. The glyph adapter
/// (ADR 0005) compiles from this source only when it is vendored; `zig build vendor-engines`
/// fetches and verifies it into the cache this looks for.
fn freetypeRoot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const root = ".engines/freetype";
    b.build_root.handle.access(io, root ++ "/src/base/ftbase.c", .{}) catch return null;
    return root;
}

/// The root of the vendored HarfBuzz source, or null if absent. The shaper (ADR 0006) is built
/// only when the amalgamation is present; `zig build vendor-engines` fetches it.
fn harfbuzzRoot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const root = ".engines/harfbuzz";
    b.build_root.handle.access(io, root ++ "/src/harfbuzz.cc", .{}) catch return null;
    return root;
}

/// The developer-local reference-design path, from the environment or a git-ignored local
/// config (`.local/design.zon`: `.{ .reference = "<path>" }`), or null if neither is set.
/// Never a hardcoded absolute path — the reference stays out of source, so extraction is
/// configured per machine and skips visibly where it is not.
fn designReferencePath(b: *std.Build) ?[]const u8 {
    const gpa = b.allocator;
    if (b.graph.environ_map.get("DESIGN_REFERENCE_PATH")) |value| {
        if (value.len > 0) return value;
    }
    const io = b.graph.io;
    const bytes = b.build_root.handle.readFileAlloc(io, ".local/design.zon", gpa, .limited(64 * 1024)) catch return null;
    const q1 = std.mem.indexOfScalar(u8, bytes, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, bytes, q1 + 1, '"') orelse return null;
    if (q2 <= q1 + 1) return null;
    return bytes[q1 + 1 .. q2];
}

const Tool = struct {
    name: []const u8,
    root: []const u8,
    description: []const u8,
};

fn addModuleTests(b: *std.Build, test_step: *std.Build.Step, name: []const u8, module: *std.Build.Module) void {
    const unit_tests = b.addTest(.{
        .name = b.fmt("{s}-tests", .{name}),
        .root_module = module,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

/// Registers a module to be compiled (its test binary built) but not run, so a gate can check
/// that compiling it is a cache hit without executing the whole test suite.
fn addCompileCheck(b: *std.Build, compile_step: *std.Build.Step, name: []const u8, module: *std.Build.Module) void {
    const unit_tests = b.addTest(.{
        .name = b.fmt("{s}-compile", .{name}),
        .root_module = module,
    });
    compile_step.dependOn(&unit_tests.step); // the compile step, not a run artifact
}

/// The build refuses to configure on a compiler line whose lane is not green,
/// so an unsupported release fails immediately with an actionable message
/// instead of part-way through compilation with a standard-library error.
fn rejectUnqualifiedCompiler(b: *std.Build) void {
    const current = line.current_line orelse std.debug.panic(
        \\unsupported Zig release {f}
        \\
        \\Supported window: {f} through the canonical release {f}.
        \\Prereleases and development snapshots are never supported.
        \\Install the canonical release with tools/bootstrap, or see docs/operations/build.md.
    , .{ line.current_version, line.floor, line.canonical });

    switch (line.qualificationOf(current)) {
        .canonical => {},
        .unqualified => std.debug.panic(
            \\Zig release {f} is inside the supported window but its lane is not green.
            \\
            \\Build with the canonical release {f} recorded in toolchain.lock.json.
            \\See docs/operations/build.md for the qualification status of each line.
        , .{ line.current_version, line.canonical }),
    }

    _ = b;
}

/// Reads the brand document at configure time and exposes its fields as an
/// importable module, so replacing the document rebrands every surface without
/// a source edit. A malformed or incomplete document fails the build here
/// rather than rendering blank product text at runtime.
fn configModule(b: *std.Build, brand_path: []const u8) *std.Build.Module {
    const io = b.graph.io;
    const gpa = b.allocator;

    const text = b.build_root.handle.readFileAlloc(io, brand_path, gpa, .limited(64 * 1024)) catch |err|
        std.debug.panic("unable to read brand document '{s}': {t}", .{ brand_path, err });

    const Document = struct {
        schema_version: u32,
        name: []const u8,
        short_name: []const u8,
        domain: []const u8,
        support_uri: []const u8,
        legal_name: []const u8,
    };

    const parsed = std.json.parseFromSlice(Document, gpa, text, .{}) catch |err|
        std.debug.panic("brand document '{s}' does not match brand/schema.json: {t}", .{ brand_path, err });

    const document = parsed.value;
    if (document.schema_version != 1) {
        std.debug.panic(
            "brand document '{s}' declares schema version {d}; this build understands version 1",
            .{ brand_path, document.schema_version },
        );
    }

    const options = b.addOptions();
    options.addOption(u32, "schema_version", document.schema_version);
    options.addOption([]const u8, "name", document.name);
    options.addOption([]const u8, "short_name", document.short_name);
    options.addOption([]const u8, "domain", document.domain);
    options.addOption([]const u8, "support_uri", document.support_uri);
    options.addOption([]const u8, "legal_name", document.legal_name);
    return options.createModule();
}
