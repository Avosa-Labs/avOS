//! Zig-owned adapter over the pinned WebAssembly runtime.
//!
//! Everything the host needs from the runtime passes through here, and no type
//! belonging to the runtime crosses into the domain. That is what keeps the
//! runtime replaceable: the boundary is narrow enough to re-implement against a
//! different host without touching anything above it.
//!
//! The adapter owns the C resources it creates and releases them on every path,
//! including the failing ones. It converts the runtime's errors and traps into
//! this module's own outcomes at the boundary, so a caller never handles a
//! foreign error type or frees a foreign allocation.
//!
//! A component starts with nothing. No import is supplied, so a module that
//! declares one fails to instantiate rather than receiving a stub: the host
//! interface decides what exists, and a component cannot obtain a capability by
//! asking for it in its import section.

const std = @import("std");

const c = @cImport({
    @cInclude("wasmtime.h");
});

pub const Error = error{
    /// The runtime could not be created with the requested configuration.
    EngineUnavailable,
    /// The module is not valid WebAssembly, or its text form is malformed.
    InvalidModule,
    /// The module declares an import. Nothing is supplied, so it cannot run.
    ImportDenied,
    /// The named export is absent or is not a function.
    ExportMissing,
    /// The host could not allocate for the call.
    OutOfMemory,
};

/// How a guest call ended.
pub const Conclusion = enum {
    /// It returned normally.
    completed,
    /// It faulted: unreachable, out of bounds, division by zero, and so on.
    trapped,
    /// It exhausted its fuel.
    fuel_exhausted,
    /// It was interrupted by the epoch deadline, which a guest cannot decline.
    interrupted,
    /// It exceeded the memory it was allowed to grow into.
    memory_limited,

    pub fn isFailure(conclusion: Conclusion) bool {
        return conclusion != .completed;
    }
};

pub const Outcome = struct {
    conclusion: Conclusion,
    /// Fuel the call consumed, when fuel metering is enabled.
    fuel_consumed: u64,
    /// The single result value, when the call produced one.
    result: ?i64,

    pub fn succeeded(outcome: Outcome) bool {
        return outcome.conclusion == .completed;
    }
};

/// What a component is allowed for one call.
pub const Limits = struct {
    /// Fuel granted for the call.
    ///
    /// Metering is always armed, because a store whose fuel is never set begins
    /// with none and stops immediately. The default is large enough not to bind
    /// in practice, so a caller that does not want a fuel limit still gets a
    /// store that runs.
    fuel: u64 = 1 << 40,
    /// Epoch ticks the guest may run for before it is interrupted.
    ///
    /// Interruption is always armed, because a store whose deadline is never
    /// set begins already past it. The default is far enough away to be
    /// unreachable in practice but far enough below the representable maximum
    /// that adding it to an epoch already advanced cannot wrap; a wrapped
    /// deadline would sit in the past and interrupt the guest immediately.
    ///
    /// Unlike fuel, an epoch deadline stops a guest that never returns to the
    /// host, which is what makes cancellation enforceable rather than
    /// cooperative.
    epoch_deadline: u64 = 1 << 48,
    /// Maximum linear memory in bytes. Negative keeps the runtime default;
    /// this adapter always sets a positive ceiling.
    memory_bytes: i64 = 1 << 20,
};

/// The compiled-code cache and configuration shared by stores.
///
/// Ownership: the engine owns the underlying runtime engine and releases it in
/// `deinit`. Stores borrow it and must not outlive it.
pub const Engine = struct {
    handle: *c.wasm_engine_t,

    /// Creates an engine with metering and interruption enabled.
    ///
    /// Both are configured here rather than per call, because the runtime
    /// requires them at engine construction. Enabling them unconditionally
    /// means no caller can obtain an unmetered, uninterruptible engine by
    /// omitting a flag.
    pub fn init() Error!Engine {
        const config = c.wasm_config_new() orelse return error.EngineUnavailable;
        // Ownership of the configuration transfers to the engine below; it
        // must not be deleted separately once that succeeds.
        c.wasmtime_config_consume_fuel_set(config, true);
        c.wasmtime_config_epoch_interruption_set(config, true);

        const handle = c.wasm_engine_new_with_config(config) orelse
            return error.EngineUnavailable;
        return .{ .handle = handle };
    }

    pub fn deinit(engine: *Engine) void {
        c.wasm_engine_delete(engine.handle);
        engine.* = undefined;
    }

    /// Advances the epoch, interrupting any guest whose deadline has passed.
    ///
    /// This is how cancellation reaches a guest that does not yield: the host
    /// increments the epoch and the runtime traps the guest at its next
    /// instruction boundary.
    pub fn interrupt(engine: *Engine) void {
        c.wasmtime_engine_increment_epoch(engine.handle);
    }
};

/// Compiled guest code.
pub const Module = struct {
    handle: *c.wasmtime_module_t,
    /// Number of imports the module declares. A module declaring any import
    /// cannot be instantiated, because nothing is supplied.
    import_count: usize,

    /// Compiles a module from its binary form.
    pub fn compile(engine: *Engine, bytes: []const u8) Error!Module {
        var handle: ?*c.wasmtime_module_t = null;
        const failure = c.wasmtime_module_new(engine.handle, bytes.ptr, bytes.len, &handle);
        if (failure != null) {
            c.wasmtime_error_delete(failure);
            return error.InvalidModule;
        }
        const compiled = handle orelse return error.InvalidModule;

        var imports: c.wasm_importtype_vec_t = undefined;
        c.wasmtime_module_imports(compiled, &imports);
        const import_count = imports.size;
        c.wasm_importtype_vec_delete(&imports);

        return .{ .handle = compiled, .import_count = import_count };
    }

    /// Compiles a module from its text form. Used by tests so a fixture is
    /// readable rather than a byte array nobody can check.
    pub fn compileText(
        engine: *Engine,
        gpa: std.mem.Allocator,
        text: []const u8,
    ) Error!Module {
        var binary: c.wasm_byte_vec_t = undefined;
        const failure = c.wasmtime_wat2wasm(text.ptr, text.len, &binary);
        if (failure != null) {
            c.wasmtime_error_delete(failure);
            return error.InvalidModule;
        }
        defer c.wasm_byte_vec_delete(&binary);
        _ = gpa;
        return compile(engine, binary.data[0..binary.size]);
    }

    pub fn deinit(module: *Module) void {
        c.wasmtime_module_delete(module.handle);
        module.* = undefined;
    }
};

/// Converts guest text into its binary form.
///
/// Caller owns the returned slice. Used where a package must carry real
/// component bytes whose identity is derived from what the runtime compiles.
pub fn textToBinary(gpa: std.mem.Allocator, text: []const u8) Error![]u8 {
    var produced: c.wasm_byte_vec_t = undefined;
    const failure = c.wasmtime_wat2wasm(text.ptr, text.len, &produced);
    if (failure != null) {
        c.wasmtime_error_delete(failure);
        return error.InvalidModule;
    }
    defer c.wasm_byte_vec_delete(&produced);
    return gpa.dupe(u8, produced.data[0..produced.size]) catch error.OutOfMemory;
}

/// One guest instance and the limits it runs under.
///
/// Ownership: the instance owns its store and releases it in `deinit`. A store
/// is never shared between components, so one component's limits and memory can
/// never be observed or consumed by another.
pub const Instance = struct {
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    handle: c.wasmtime_instance_t,
    fuel_granted: u64,

    /// Instantiates a module with no imports supplied.
    pub fn init(engine: *Engine, module: *const Module, limits: Limits) Error!Instance {
        // A module asking for an import is refused before instantiation, so the
        // refusal is a decision rather than a link failure.
        if (module.import_count != 0) return error.ImportDenied;

        const store = c.wasmtime_store_new(engine.handle, null, null) orelse
            return error.EngineUnavailable;
        errdefer c.wasmtime_store_delete(store);

        // The ceiling is set before any guest code runs, so a guest cannot
        // observe an unlimited window at startup.
        c.wasmtime_store_limiter(store, limits.memory_bytes, -1, -1, -1, -1);

        const context = c.wasmtime_store_context(store) orelse return error.EngineUnavailable;

        const fuel_failure = c.wasmtime_context_set_fuel(context, limits.fuel);
        if (fuel_failure != null) {
            c.wasmtime_error_delete(fuel_failure);
            return error.EngineUnavailable;
        }
        c.wasmtime_context_set_epoch_deadline(context, limits.epoch_deadline);

        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_instance_new(context, module.handle, null, 0, &instance, &trap);
        if (trap) |raised| c.wasm_trap_delete(raised);
        if (failure != null) {
            c.wasmtime_error_delete(failure);
            return error.ImportDenied;
        }

        return .{
            .store = store,
            .context = context,
            .handle = instance,
            .fuel_granted = limits.fuel,
        };
    }

    pub fn deinit(instance: *Instance) void {
        c.wasmtime_store_delete(instance.store);
        instance.* = undefined;
    }

    /// Calls an exported function taking no arguments and returning at most one
    /// value.
    ///
    /// Every failure the guest can produce is converted into an outcome. A
    /// guest fault must never become the host's error path, or one hostile
    /// component would stop the host that is containing it.
    pub fn call(instance: *Instance, name: []const u8) Error!Outcome {
        var found: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(
            instance.context,
            &instance.handle,
            name.ptr,
            name.len,
            &found,
        )) {
            return error.ExportMissing;
        }
        defer c.wasmtime_extern_delete(&found);

        if (found.kind != c.WASMTIME_EXTERN_FUNC) return error.ExportMissing;

        var results: [1]c.wasmtime_val_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        const failure = c.wasmtime_func_call(
            instance.context,
            &found.of.func,
            null,
            0,
            &results,
            1,
            &trap,
        );

        const consumed = instance.consumedFuel();

        if (failure != null) {
            c.wasmtime_error_delete(failure);
            // A call that produced neither a result nor a trap failed for a
            // reason the guest did not cause; report it as a trap rather than
            // inventing a distinction the caller cannot act on.
            return .{ .conclusion = .trapped, .fuel_consumed = consumed, .result = null };
        }

        if (trap) |raised| {
            defer c.wasm_trap_delete(raised);
            var code: c.wasmtime_trap_code_t = undefined;
            const conclusion: Conclusion = if (c.wasmtime_trap_code(raised, &code))
                switch (code) {
                    c.WASMTIME_TRAP_CODE_OUT_OF_FUEL => .fuel_exhausted,
                    c.WASMTIME_TRAP_CODE_INTERRUPT => .interrupted,
                    else => .trapped,
                }
            else
                .trapped;
            return .{ .conclusion = conclusion, .fuel_consumed = consumed, .result = null };
        }

        const value: ?i64 = switch (results[0].kind) {
            c.WASMTIME_I32 => results[0].of.i32,
            c.WASMTIME_I64 => results[0].of.i64,
            else => null,
        };
        c.wasmtime_val_unroot(&results[0]);

        return .{ .conclusion = .completed, .fuel_consumed = consumed, .result = value };
    }

    fn consumedFuel(instance: *Instance) u64 {
        var remaining: u64 = 0;
        const failure = c.wasmtime_context_get_fuel(instance.context, &remaining);
        if (failure != null) {
            c.wasmtime_error_delete(failure);
            return 0;
        }
        return instance.fuel_granted -| remaining;
    }
};

const denies_everything =
    \\(module
    \\  (func (export "run") (result i32) i32.const 7))
;

const traps_on_unreachable =
    \\(module
    \\  (func (export "run") (result i32) unreachable))
;

const never_returns =
    \\(module
    \\  (func (export "run") (result i32)
    \\    (loop $spin (br $spin))
    \\    i32.const 0))
;

const grows_memory =
    \\(module
    \\  (memory 1)
    \\  (func (export "run") (result i32)
    \\    (drop (memory.grow (i32.const 1000)))
    \\    (memory.grow (i32.const 1000))))
;

const asks_for_an_import =
    \\(module
    \\  (import "host" "read_file" (func $read (result i32)))
    \\  (func (export "run") (result i32) (call $read)))
;

/// One module per resource class a runtime would otherwise supply ambiently.
/// Each reaches for its resource the only way a guest can: through an import.
const ambient_authority_probes = [_]struct {
    class: []const u8,
    text: []const u8,
}{
    .{
        .class = "filesystem",
        .text =
        \\(module
        \\  (import "wasi_snapshot_preview1" "path_open"
        \\    (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        \\  (func (export "run") (result i32) i32.const 0))
        ,
    },
    .{
        .class = "network",
        .text =
        \\(module
        \\  (import "wasi_snapshot_preview1" "sock_send"
        \\    (func $send (param i32 i32 i32 i32 i32) (result i32)))
        \\  (func (export "run") (result i32) i32.const 0))
        ,
    },
    .{
        .class = "clock",
        .text =
        \\(module
        \\  (import "wasi_snapshot_preview1" "clock_time_get"
        \\    (func $now (param i32 i64 i32) (result i32)))
        \\  (func (export "run") (result i32) i32.const 0))
        ,
    },
    .{
        .class = "random",
        .text =
        \\(module
        \\  (import "wasi_snapshot_preview1" "random_get"
        \\    (func $random (param i32 i32) (result i32)))
        \\  (func (export "run") (result i32) i32.const 0))
        ,
    },
    .{
        .class = "environment",
        .text =
        \\(module
        \\  (import "wasi_snapshot_preview1" "environ_get"
        \\    (func $environ (param i32 i32) (result i32)))
        \\  (func (export "run") (result i32) i32.const 0))
        ,
    },
};

test "a self-contained component runs and returns its result" {
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compileText(&engine, std.testing.allocator, denies_everything);
    defer module.deinit();

    var instance = try Instance.init(&engine, &module, .{ .fuel = 10_000 });
    defer instance.deinit();

    const outcome = try instance.call("run");
    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(?i64, 7), outcome.result);
}

test "a component declaring any import is refused" {
    // Nothing is supplied, so asking for a host function is not a link error to
    // be papered over with a stub; it is a denial.
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compileText(&engine, std.testing.allocator, asks_for_an_import);
    defer module.deinit();

    try std.testing.expect(module.import_count > 0);
    try std.testing.expectError(error.ImportDenied, Instance.init(&engine, &module, .{}));
}

test "every ambient resource class is denied, asserted one class at a time" {
    // A guest reaches a host resource only through an import. With none
    // supplied, each class is unavailable by construction rather than by a
    // policy check that could be misconfigured.
    var engine = try Engine.init();
    defer engine.deinit();

    for (ambient_authority_probes) |probe| {
        var module = try Module.compileText(&engine, std.testing.allocator, probe.text);
        defer module.deinit();

        try std.testing.expect(module.import_count > 0);
        try std.testing.expectError(
            error.ImportDenied,
            Instance.init(&engine, &module, .{}),
        );
    }
}

test "a trapping component is contained and the engine keeps working" {
    var engine = try Engine.init();
    defer engine.deinit();

    var trapping = try Module.compileText(&engine, std.testing.allocator, traps_on_unreachable);
    defer trapping.deinit();

    var instance = try Instance.init(&engine, &trapping, .{ .fuel = 10_000 });
    defer instance.deinit();

    const outcome = try instance.call("run");
    try std.testing.expectEqual(Conclusion.trapped, outcome.conclusion);

    // The engine survives and runs the next component normally.
    var healthy = try Module.compileText(&engine, std.testing.allocator, denies_everything);
    defer healthy.deinit();
    var next = try Instance.init(&engine, &healthy, .{ .fuel = 10_000 });
    defer next.deinit();
    try std.testing.expect((try next.call("run")).succeeded());
}

test "repeated traps do not degrade the engine" {
    var engine = try Engine.init();
    defer engine.deinit();

    var trapping = try Module.compileText(&engine, std.testing.allocator, traps_on_unreachable);
    defer trapping.deinit();

    for (0..32) |_| {
        var instance = try Instance.init(&engine, &trapping, .{ .fuel = 10_000 });
        defer instance.deinit();
        try std.testing.expectEqual(Conclusion.trapped, (try instance.call("run")).conclusion);
    }

    var healthy = try Module.compileText(&engine, std.testing.allocator, denies_everything);
    defer healthy.deinit();
    var next = try Instance.init(&engine, &healthy, .{ .fuel = 10_000 });
    defer next.deinit();
    try std.testing.expect((try next.call("run")).succeeded());
}

test "a component that never returns is stopped by its fuel" {
    var engine = try Engine.init();
    defer engine.deinit();

    var spinning = try Module.compileText(&engine, std.testing.allocator, never_returns);
    defer spinning.deinit();

    var instance = try Instance.init(&engine, &spinning, .{ .fuel = 50_000 });
    defer instance.deinit();

    const outcome = try instance.call("run");
    try std.testing.expectEqual(Conclusion.fuel_exhausted, outcome.conclusion);
    try std.testing.expect(outcome.fuel_consumed > 0);
}

test "a component that never returns is interrupted by the epoch deadline" {
    // This is the property cooperative cancellation cannot provide: the guest
    // never returns to the host, and is stopped anyway.
    var engine = try Engine.init();
    defer engine.deinit();

    var spinning = try Module.compileText(&engine, std.testing.allocator, never_returns);
    defer spinning.deinit();

    // Ample fuel, so what stops the guest is the deadline and nothing else.
    var instance = try Instance.init(&engine, &spinning, .{
        .fuel = 1 << 50,
        .epoch_deadline = 1,
    });
    defer instance.deinit();

    // The deadline has already passed by the time the guest starts.
    engine.interrupt();
    engine.interrupt();

    const outcome = try instance.call("run");
    try std.testing.expectEqual(Conclusion.interrupted, outcome.conclusion);
}

test "a component is stopped at its memory ceiling" {
    var engine = try Engine.init();
    defer engine.deinit();

    var hungry = try Module.compileText(&engine, std.testing.allocator, grows_memory);
    defer hungry.deinit();

    var instance = try Instance.init(&engine, &hungry, .{
        .fuel = 100_000,
        .memory_bytes = 2 << 20,
    });
    defer instance.deinit();

    // Growth beyond the ceiling fails rather than being granted; the guest
    // observes the failure as a negative result from memory.grow.
    const outcome = try instance.call("run");
    try std.testing.expect(outcome.succeeded());
    try std.testing.expectEqual(@as(?i64, -1), outcome.result);
}

test "one component's limits do not affect another" {
    var engine = try Engine.init();
    defer engine.deinit();

    var spinning = try Module.compileText(&engine, std.testing.allocator, never_returns);
    defer spinning.deinit();
    var healthy = try Module.compileText(&engine, std.testing.allocator, denies_everything);
    defer healthy.deinit();

    var exhausted = try Instance.init(&engine, &spinning, .{ .fuel = 1_000 });
    defer exhausted.deinit();
    try std.testing.expectEqual(Conclusion.fuel_exhausted, (try exhausted.call("run")).conclusion);

    var fresh = try Instance.init(&engine, &healthy, .{ .fuel = 1_000 });
    defer fresh.deinit();
    try std.testing.expect((try fresh.call("run")).succeeded());
}

test "invalid guest code is refused at compile time" {
    var engine = try Engine.init();
    defer engine.deinit();

    try std.testing.expectError(
        error.InvalidModule,
        Module.compile(&engine, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }),
    );
    try std.testing.expectError(
        error.InvalidModule,
        Module.compileText(&engine, std.testing.allocator, "(module (func (export"),
    );
}

test "a missing export is reported rather than called" {
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compileText(&engine, std.testing.allocator, denies_everything);
    defer module.deinit();

    var instance = try Instance.init(&engine, &module, .{ .fuel = 10_000 });
    defer instance.deinit();

    try std.testing.expectError(error.ExportMissing, instance.call("absent"));
}

test "every conclusion except completion is a failure" {
    for (std.enums.values(Conclusion)) |conclusion| {
        try std.testing.expectEqual(conclusion != .completed, conclusion.isFailure());
    }
}
