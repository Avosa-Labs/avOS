const std = @import("std");
const line = @import("compat/zig/line.zig");

/// Files and directories the formatter owns. Generated output and the local
/// tool directory are excluded because they are not authored source.
const formatted_paths = [_][]const u8{
    "build.zig",
    "brand",
    "compat",
    "core",
    "design",
    "ipc",
    "runtimes",
    "services",
    "session",
    "shell",
    "simulator",
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
    runtime_android_module.addImport("core", core_module);
    services_module.addImport("core", core_module);
    session_module.addImport("core", core_module);
    shell_module.addImport("core", core_module);
    shell_module.addImport("design", design_module);
    simulator_module.addImport("core", core_module);

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
            .name = "convention-check",
            .root = "tools/convention-check/main.zig",
            .description = "Verify authoring conventions: attribution, comments, and naming",
        },
        .{
            .name = "doctor",
            .root = "tools/doctor/main.zig",
            .description = "Report host, compiler, and pin health",
        },
    };

    const test_step = b.step("test", "Run unit tests");

    addModuleTests(b, test_step, "brand", brand_module);
    addModuleTests(b, test_step, "compat", compat_module);
    addModuleTests(b, test_step, "core", core_module);
    addModuleTests(b, test_step, "ipc", ipc_module);
    addModuleTests(b, test_step, "runtime-native", runtime_native_module);
    addModuleTests(b, test_step, "runtime-android", runtime_android_module);
    addModuleTests(b, test_step, "services", services_module);
    addModuleTests(b, test_step, "session", session_module);
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
    addModuleTests(b, test_step, "simulator", simulator_module);

    for (tools) |tool| {
        const module = b.createModule(.{
            .root_source_file = b.path(tool.root),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_module },
                .{ .name = "core", .module = core_module },
                .{ .name = "brand", .module = brand_module },
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

    const inspector_module = b.createModule(.{
        .root_source_file = b.path("simulator/inspector/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_module },
            .{ .name = "core", .module = core_module },
            .{ .name = "simulator", .module = simulator_module },
        },
    });
    const inspector = b.addExecutable(.{ .name = "simulator", .root_module = inspector_module });
    b.installArtifact(inspector);

    const run_simulator = b.addRunArtifact(inspector);
    run_simulator.step.dependOn(b.getInstallStep());
    if (b.args) |forwarded| run_simulator.addArgs(forwarded);
    b.step("simulator", "Run a scenario against the control plane").dependOn(&run_simulator.step);

    addModuleTests(b, test_step, "inspector", inspector_module);

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
        },
    });
    addModuleTests(b, test_step, "acceptance", acceptance_module);

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
