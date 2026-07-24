//! Validates a protocol definition and emits a deterministic binding signature, the decidable core of
//! binding generation.
//!
//! Generating bindings for a protocol — the stubs a caller and a callee share — begins with a question
//! that must be answered before a single line is emitted: is the protocol definition one that bindings
//! can faithfully represent? Two things make it not. A duplicate method name is ambiguous — a caller
//! naming that method cannot be resolved to one signature. A parameter or return type outside the type
//! system the bindings target is unrepresentable — there is no stub shape for a type the target does not
//! have. This tool decides both, and for a valid definition emits a signature: a digest over the
//! normalized method set that is stable across reorderings, so two definitions that describe the same
//! protocol produce the same signature and any change to a method's name or types changes it. The
//! signature is what lets a caller and a callee confirm they were generated from the same protocol
//! without shipping the generator's output around. Deciding representability and pinning the shape is the
//! part of codegen that determines correctness; the language-specific emission that follows is
//! mechanical.
//!
//! Exit codes: 0 the protocol is valid (signature emitted), 1 it is not representable (duplicate method
//! or unknown type), 2 usage error or an unreadable definition.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The types a binding can represent. A parameter or return type outside this set is unrepresentable.
pub const known_types = [_][]const u8{ "void", "bool", "u32", "u64", "string", "bytes" };

/// Whether a type is one the bindings can represent.
pub fn isKnownType(type_name: []const u8) bool {
    for (known_types) |known| {
        if (std.mem.eql(u8, known, type_name)) return true;
    }
    return false;
}

/// One protocol method: a name, a parameter type, and a return type.
pub const Method = struct {
    name: []const u8,
    param: []const u8,
    returns: []const u8,
};

/// A reason a protocol definition cannot be turned into bindings.
pub const Problem = union(enum) {
    /// Two methods share a name. Carries the name.
    duplicate_method: []const u8,
    /// A method uses a type outside the representable set. Carries the method and the bad type.
    unknown_type: struct { method: []const u8, type_name: []const u8 },
};

/// Finds the first problem preventing binding generation, or null if the protocol is representable.
/// Methods are checked in order; each method's types are checked before duplicates so an unrepresentable
/// type is reported at its method.
pub fn firstProblem(methods: []const Method) ?Problem {
    for (methods, 0..) |method, index| {
        if (!isKnownType(method.param)) {
            return .{ .unknown_type = .{ .method = method.name, .type_name = method.param } };
        }
        if (!isKnownType(method.returns)) {
            return .{ .unknown_type = .{ .method = method.name, .type_name = method.returns } };
        }
        for (methods[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, method.name)) {
                return .{ .duplicate_method = method.name };
            }
        }
    }
    return null;
}

fn lessThanByName(_: void, a: Method, b: Method) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The binding signature: a digest over the normalized method set, in name order, so it is stable
/// across reorderings and changes when any method's name, parameter, or return type changes.
///
/// The caller must sort the methods by name first. Each method contributes its name and both types,
/// separated so that moving a type between fields cannot produce a collision.
pub fn signatureOf(sorted_methods: []const Method) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (sorted_methods) |method| {
        hasher.update(method.name);
        hasher.update(&.{0});
        hasher.update(method.param);
        hasher.update(&.{0});
        hasher.update(method.returns);
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// Parses one definition line: "methodName paramType returnType".
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Method {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = fields.next() orelse return error.Malformed;
    const param = fields.next() orelse return error.Malformed;
    const returns = fields.next() orelse return error.Malformed;
    if (fields.next() != null) return error.Malformed;
    return .{
        .name = try arena.dupe(u8, name),
        .param = try arena.dupe(u8, param),
        .returns = try arena.dupe(u8, returns),
    };
}

const Options = struct {
    definition: []const u8 = "protocol.txt",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const options = parseArguments(args, out, err) catch |parse_error| switch (parse_error) {
        error.HelpRequested => {
            try out.flush();
            return 0;
        },
        error.InvalidArguments => {
            try err.flush();
            return 2;
        },
        else => return parse_error,
    };

    const contents = io_adapters.cwd().readFileAlloc(io, options.definition, gpa, .limited(4 << 20)) catch {
        try err.print("protocol-codegen: cannot read definition '{s}'\n", .{options.definition});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var methods: std.ArrayList(Method) = .empty;
    defer methods.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const method = parseLine(arena, line) catch {
            try err.print("protocol-codegen: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        try methods.append(gpa, method);
    }

    if (firstProblem(methods.items)) |problem| {
        switch (problem) {
            .duplicate_method => |name| try out.print("protocol-codegen: duplicate method '{s}'\n", .{name}),
            .unknown_type => |bad| try out.print("protocol-codegen: method '{s}' uses unrepresentable type '{s}'\n", .{ bad.method, bad.type_name }),
        }
        try out.flush();
        return 1;
    }

    std.mem.sort(Method, methods.items, {}, lessThanByName);
    try out.print("protocol-codegen: {d} method(s) representable, signature {x}\n", .{ methods.items.len, signatureOf(methods.items) });
    try out.flush();
    return 0;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: protocol-codegen [--definition FILE]
                \\
                \\Validates a protocol definition and emits a deterministic binding signature. A
                \\duplicate method or a type outside the representable set (void, bool, u32, u64,
                \\string, bytes) fails. Definition lines are "method paramType returnType".
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--definition")) {
            index += 1;
            if (index >= args.len) {
                try err.print("protocol-codegen: --definition needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.definition = args[index];
        } else {
            try err.print("protocol-codegen: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn m(name: []const u8, param: []const u8, returns: []const u8) Method {
    return .{ .name = name, .param = param, .returns = returns };
}

fn sortedSignature(methods: []Method) u64 {
    std.mem.sort(Method, methods, {}, lessThanByName);
    return signatureOf(methods);
}

test "a representable protocol has no problem" {
    const methods = [_]Method{ m("read", "u64", "bytes"), m("write", "bytes", "bool") };
    try std.testing.expectEqual(@as(?Problem, null), firstProblem(&methods));
}

test "a duplicate method is caught" {
    const methods = [_]Method{ m("read", "u64", "bytes"), m("read", "void", "bool") };
    switch (firstProblem(&methods).?) {
        .duplicate_method => |name| try std.testing.expectEqualStrings("read", name),
        else => try std.testing.expect(false),
    }
}

test "an unrepresentable parameter type is caught" {
    const methods = [_]Method{m("read", "widget", "bytes")};
    switch (firstProblem(&methods).?) {
        .unknown_type => |bad| {
            try std.testing.expectEqualStrings("read", bad.method);
            try std.testing.expectEqualStrings("widget", bad.type_name);
        },
        else => try std.testing.expect(false),
    }
}

test "an unrepresentable return type is caught" {
    const methods = [_]Method{m("read", "u64", "widget")};
    try std.testing.expect(firstProblem(&methods).? == .unknown_type);
}

test "the signature is independent of method order" {
    var a = [_]Method{ m("read", "u64", "bytes"), m("write", "bytes", "bool") };
    var b = [_]Method{ m("write", "bytes", "bool"), m("read", "u64", "bytes") };
    try std.testing.expectEqual(sortedSignature(&a), sortedSignature(&b));
}

test "a changed type changes the signature" {
    var base = [_]Method{m("read", "u64", "bytes")};
    var changed = [_]Method{m("read", "u32", "bytes")};
    try std.testing.expect(sortedSignature(&base) != sortedSignature(&changed));
}

test "adding a method changes the signature" {
    var one = [_]Method{m("read", "u64", "bytes")};
    var two = [_]Method{ m("read", "u64", "bytes"), m("write", "bytes", "bool") };
    try std.testing.expect(sortedSignature(&one) != sortedSignature(&two));
}
