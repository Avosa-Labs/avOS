//! Identifiers for every kind of entity the control plane tracks.
//!
//! Identifiers are opaque, fixed-width, and distinctly typed. Distinct types
//! matter: a capability identifier and a task identifier are both 128-bit
//! values, and only the type system stops one being passed where the other is
//! expected at an authorization boundary.
//!
//! An identifier carries no meaning. It embeds no brand, no display name, no
//! model name, no kind tag, and no ordering that would let a holder infer other
//! identifiers. Display names are metadata and are never authorization
//! identity.

const std = @import("std");

/// Distinctly typed 128-bit identifier.
///
/// The domain parameter exists only to make two identifier types
/// non-interchangeable; it is never serialized and never inspected.
fn Identifier(comptime domain: []const u8) type {
    return struct {
        const Self = @This();

        /// Opaque value. Callers must not derive meaning from its bits.
        value: u128,

        /// Reserved value meaning "no identifier". Never issued.
        pub const none: Self = .{ .value = 0 };

        pub fn isNone(self: Self) bool {
            return self.value == 0;
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.value == other.value;
        }

        /// Renders as fixed-width lowercase hexadecimal so that log and ledger
        /// output aligns and never varies in length with the value.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{x:0>32}", .{self.value});
        }

        /// Short prefix for dense interface surfaces. Never use a short form to
        /// compare or look up an identifier.
        pub fn shortForm(self: Self, buffer: *[8]u8) []const u8 {
            return std.fmt.bufPrint(buffer, "{x:0>8}", .{
                @as(u32, @truncate(self.value >> 96)),
            }) catch unreachable;
        }

        pub const domain_name = domain;
    };
}

pub const PrincipalId = Identifier("principal");
pub const CapabilityId = Identifier("capability");
pub const TaskId = Identifier("task");
pub const AuditEventId = Identifier("audit_event");
pub const ResourceId = Identifier("resource");
pub const SessionId = Identifier("session");
pub const ApprovalId = Identifier("approval");

/// Issues identifiers.
///
/// The simulator requires deterministic identifiers so a scenario replays
/// exactly, while a real host requires unpredictable ones so a holder cannot
/// guess an identifier it was never given. Both are the same type with
/// different seeding, so no domain code branches on which is in use.
/// Identifiers drawn from the generator per refill.
const buffer_length: usize = 64;

pub const Source = struct {
    state: std.Random.DefaultCsprng,
    /// Identifiers drawn in advance.
    ///
    /// The generator is asked for a block at a time rather than once per
    /// identifier. Identity is issued on the path of every privileged
    /// operation, and a cipher invocation per issue makes that path cost more
    /// than the operation it identifies. The generator, the entropy, and the
    /// unpredictability are unchanged; only the number of calls is.
    buffered: [buffer_length]u128 = undefined,
    remaining: usize = 0,

    /// Deterministic source. Two sources created with the same seed issue the
    /// same sequence, which is what makes a replayed scenario comparable.
    pub fn initDeterministic(seed: u64) Source {
        var expanded: [32]u8 = @splat(0);
        std.mem.writeInt(u64, expanded[0..8], seed, .little);
        return .{ .state = .init(expanded) };
    }

    /// Unpredictable source seeded from the host. Used outside the simulator so
    /// identifiers cannot be guessed or enumerated.
    pub fn initFromEntropy() Source {
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        return .{ .state = .init(seed) };
    }

    /// Issues the next identifier of the requested type.
    ///
    /// Never returns `none`: the reserved zero value would otherwise compare
    /// equal to an uninitialized field.
    pub fn next(source: *Source, comptime Id: type) Id {
        while (true) {
            if (source.remaining == 0) source.refill();
            source.remaining -= 1;
            const value = source.buffered[source.remaining];
            if (value != 0) return .{ .value = value };
        }
    }

    fn refill(source: *Source) void {
        var random = source.state.random();
        random.bytes(std.mem.sliceAsBytes(source.buffered[0..]));
        source.remaining = buffer_length;
    }
};

test "identifiers of different domains are distinct types" {
    // A capability identifier must not be usable where a task identifier is
    // expected; if these were the same type this would compile.
    try std.testing.expect(PrincipalId != TaskId);
    try std.testing.expect(CapabilityId != TaskId);
    try std.testing.expect(AuditEventId != ResourceId);
}

test "the reserved value is recognized and never issued" {
    try std.testing.expect(PrincipalId.none.isNone());
    try std.testing.expect(!(PrincipalId{ .value = 1 }).isNone());

    var source: Source = .initDeterministic(0);
    for (0..512) |_| {
        try std.testing.expect(!source.next(PrincipalId).isNone());
    }
}

test "a deterministic source replays exactly" {
    var first: Source = .initDeterministic(20260722);
    var second: Source = .initDeterministic(20260722);
    for (0..128) |_| {
        try std.testing.expect(first.next(TaskId).eql(second.next(TaskId)));
    }
}

test "different seeds diverge" {
    var first: Source = .initDeterministic(1);
    var second: Source = .initDeterministic(2);
    try std.testing.expect(!first.next(TaskId).eql(second.next(TaskId)));
}

test "issued identifiers do not repeat" {
    const gpa = std.testing.allocator;
    var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
    defer seen.deinit(gpa);

    var source: Source = .initDeterministic(7);
    for (0..4096) |_| {
        const issued = source.next(CapabilityId);
        const entry = try seen.getOrPut(gpa, issued.value);
        try std.testing.expect(!entry.found_existing);
    }
}

test "identifiers render at a fixed width regardless of value" {
    const gpa = std.testing.allocator;
    const samples = [_]u128{ 1, 0xffff, std.math.maxInt(u128) };
    for (samples) |value| {
        const rendered = try std.fmt.allocPrint(gpa, "{f}", .{TaskId{ .value = value }});
        defer gpa.free(rendered);
        try std.testing.expectEqual(@as(usize, 32), rendered.len);
    }
}

test "the short form is fixed width and never used for comparison" {
    var buffer: [8]u8 = undefined;
    const low = (TaskId{ .value = 1 }).shortForm(&buffer);
    try std.testing.expectEqual(@as(usize, 8), low.len);

    var other: [8]u8 = undefined;
    const high = (TaskId{ .value = std.math.maxInt(u128) }).shortForm(&other);
    try std.testing.expectEqual(@as(usize, 8), high.len);

    // Two distinct identifiers may share a short form; equality must use the
    // full value.
    const first: TaskId = .{ .value = 1 };
    const second: TaskId = .{ .value = 2 };
    var buffer_first: [8]u8 = undefined;
    var buffer_second: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        first.shortForm(&buffer_first),
        second.shortForm(&buffer_second),
    );
    try std.testing.expect(!first.eql(second));
}
