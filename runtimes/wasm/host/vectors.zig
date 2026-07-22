//! Runs the shared component test vectors against the host interface.
//!
//! The vectors live in `test-vectors/component/` so that any implementation of
//! this boundary is held to the same expected outcomes. Reading them from disk
//! rather than embedding copies means the file a reviewer reads is the file the
//! runtime is judged against; a divergence between the two is not possible.

const std = @import("std");
const engine_module = @import("engine.zig");

const Engine = engine_module.Engine;
const Module = engine_module.Module;
const Instance = engine_module.Instance;
const Conclusion = engine_module.Conclusion;

const vector_directory = "test-vectors/component";

/// What a vector must do at the boundary.
const Expectation = union(enum) {
    /// Compiles, instantiates, runs, and returns the stated value.
    completes: i64,
    /// Compiles and instantiates, but the guest faults.
    traps,
    /// Compiles and instantiates, and is stopped by its fuel.
    exhausts_fuel,
    /// Declares an import, so nothing supplies it and it cannot instantiate.
    refused_import,
    /// Is not valid guest code.
    refused_compile,
};

const Vector = struct {
    file: []const u8,
    expectation: Expectation,
};

const vectors = [_]Vector{
    .{ .file = "benign.wat", .expectation = .{ .completes = 7 } },
    .{ .file = "unreachable.wat", .expectation = .traps },
    .{ .file = "spin.wat", .expectation = .exhausts_fuel },
    .{ .file = "grow-memory.wat", .expectation = .{ .completes = -1 } },
    .{ .file = "import-filesystem.wat", .expectation = .refused_import },
    .{ .file = "import-network.wat", .expectation = .refused_import },
    .{ .file = "import-clock.wat", .expectation = .refused_import },
    .{ .file = "import-random.wat", .expectation = .refused_import },
    .{ .file = "import-environment.wat", .expectation = .refused_import },
    .{ .file = "malformed.wat", .expectation = .refused_compile },
    .{ .file = "stack-exhaustion.wat", .expectation = .traps },
    .{ .file = "divide-by-zero.wat", .expectation = .traps },
    .{ .file = "out-of-bounds.wat", .expectation = .traps },
};

fn readVector(gpa: std.mem.Allocator, file: []const u8) ![]u8 {
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, vector_directory, .{});
    defer directory.close(io);
    return directory.readFileAlloc(io, file, gpa, .limited(1 << 20));
}

test "every shared vector produces its stated outcome" {
    const gpa = std.testing.allocator;

    var engine = try Engine.init();
    defer engine.deinit();

    for (vectors) |vector| {
        const text = try readVector(gpa, vector.file);
        defer gpa.free(text);

        var module = Module.compileText(&engine, gpa, text) catch |failure| {
            try std.testing.expectEqual(Expectation.refused_compile, vector.expectation);
            try std.testing.expectEqual(engine_module.Error.InvalidModule, failure);
            continue;
        };
        defer module.deinit();

        var instance = Instance.init(&engine, &module, .{
            .fuel = 100_000,
            .memory_bytes = 2 << 20,
        }) catch |failure| {
            try std.testing.expectEqual(Expectation.refused_import, vector.expectation);
            try std.testing.expectEqual(engine_module.Error.ImportDenied, failure);
            continue;
        };
        defer instance.deinit();

        const outcome = try instance.call("run");

        switch (vector.expectation) {
            .completes => |value| {
                try std.testing.expectEqual(Conclusion.completed, outcome.conclusion);
                try std.testing.expectEqual(@as(?i64, value), outcome.result);
            },
            .traps => try std.testing.expectEqual(Conclusion.trapped, outcome.conclusion),
            .exhausts_fuel => try std.testing.expectEqual(
                Conclusion.fuel_exhausted,
                outcome.conclusion,
            ),
            .refused_import, .refused_compile => {
                // Reaching here means the boundary admitted something it should
                // have refused, which is the failure this vector exists to catch.
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "the vector set covers every conclusion the boundary can reach" {
    // A conclusion with no vector is a behavior nothing holds to a contract.
    var covered: std.EnumSet(Conclusion) = .initEmpty();
    for (vectors) |vector| {
        switch (vector.expectation) {
            .completes => covered.insert(.completed),
            .traps => covered.insert(.trapped),
            .exhausts_fuel => covered.insert(.fuel_exhausted),
            .refused_import, .refused_compile => {},
        }
    }
    try std.testing.expect(covered.contains(.completed));
    try std.testing.expect(covered.contains(.trapped));
    try std.testing.expect(covered.contains(.fuel_exhausted));
}

test "every declared vector file exists and is readable" {
    const gpa = std.testing.allocator;
    for (vectors) |vector| {
        const text = try readVector(gpa, vector.file);
        defer gpa.free(text);
        try std.testing.expect(text.len > 0);
    }
}
