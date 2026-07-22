const std = @import("std");
const line = @import("compat/zig/line.zig");

/// Files and directories the formatter owns. Generated output and the local
/// tool directory are excluded because they are not authored source.
const formatted_paths = [_][]const u8{
    "build.zig",
    "brand",
    "compat",
    "core",
    "ipc",
    "simulator",
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

    const format = b.addFmt(.{ .paths = &formatted_paths });
    b.step("format", "Apply canonical formatting").dependOn(&format.step);

    const format_check = b.addFmt(.{ .paths = &formatted_paths, .check = true });
    b.step("format-check", "Verify formatting without writing").dependOn(&format_check.step);
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
