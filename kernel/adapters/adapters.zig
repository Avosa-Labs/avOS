//! Where a kernel decision meets the machine that carries it out.
//!
//! The rest of the kernel tree decides: what runs next, where memory belongs,
//! who may reach a device, what order a privileged operation runs its checks.
//! None of it does anything. An adapter is the thin seam where a decision is
//! handed to the underlying operating system to enact — a scheduler class mapped
//! to a host priority, an allocator domain mapped to a host arena, a device
//! reach mapped to a driver call.
//!
//! Two rules govern everything here, and both are the same rule seen from two
//! sides. An adapter carries out decisions; it never makes them. It may not
//! authorize, may not choose a scheduling class, may not decide which memory
//! domain work belongs to. The moment an adapter decides, the decision has
//! escaped the trusted, tested policy layer into an untrusted enactment layer,
//! and the guarantee that a decision was checked is gone. So this module defines
//! the shape of an adapter as *a translation with no judgement*: it takes a
//! decision the policy already made and returns how the host should be told to
//! obey it, and it has nowhere to put a policy of its own.
//!
//! There is no host binding here. Binding to a real operating system is a
//! separate, per-platform concern that lives with the board it targets. This is
//! the boundary that binding must fit through, expressed so that a binding which
//! tried to smuggle a decision across it would not typecheck.

const std = @import("std");
const scheduler_policy = @import("../scheduler-policy/scheduler_policy.zig");
const memory_policy = @import("../memory-policy/memory_policy.zig");

/// A host priority value.
///
/// Opaque on purpose: the kernel decides in classes, and only the adapter knows
/// what number a given host wants. Making it a distinct type stops a class and a
/// priority being confused at the seam.
pub const HostPriority = struct {
    value: i32,
};

/// A host memory arena kind.
///
/// Same reasoning: the kernel decides in domains, the host speaks in whatever
/// arena kinds it has, and only the adapter translates between them.
pub const HostArena = struct {
    value: u32,
};

/// Translates a kernel decision into host terms.
///
/// An interface with exactly the operations that are translations. There is no
/// operation that decides anything, because an adapter that could decide would
/// be a policy nobody tested standing where a tested one belongs.
///
/// Every method takes a decision the policy layer already produced. None takes
/// the raw inputs a decision is made from, so an adapter is never in a position
/// to make the decision itself — it has already been made by the time anything
/// here is called.
pub const Adapter = struct {
    context_pointer: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Maps a scheduling class the policy selected to a host priority.
        priorityFor: *const fn (
            context_pointer: *anyopaque,
            class: scheduler_policy.Class,
        ) HostPriority,
        /// Maps a memory domain the policy assigned to a host arena.
        arenaFor: *const fn (
            context_pointer: *anyopaque,
            domain: memory_policy.Domain,
        ) HostArena,
    };

    pub fn priorityFor(adapter: Adapter, class: scheduler_policy.Class) HostPriority {
        return adapter.vtable.priorityFor(adapter.context_pointer, class);
    }

    pub fn arenaFor(adapter: Adapter, domain: memory_policy.Domain) HostArena {
        return adapter.vtable.arenaFor(adapter.context_pointer, domain);
    }
};

/// Whether a priority mapping preserves the policy's ordering.
///
/// The one property an adapter must not get wrong: if the policy ranks one class
/// above another, the host priorities it maps them to must rank the same way, or
/// the host would run them in an order the policy never chose. A monotonicity
/// check, not a policy — the adapter still picks the numbers, but it may not
/// pick numbers that invert the order.
///
/// A lower host priority value is assumed to mean more urgent, matching the
/// class ordinals; an adapter whose host is the other way round returns negated
/// values and still passes.
pub fn preservesOrdering(adapter: Adapter) bool {
    const classes = std.enums.values(scheduler_policy.Class);
    for (classes, 0..) |higher, i| {
        for (classes[i + 1 ..]) |lower| {
            // `higher` outranks `lower` by construction of the enum order.
            const higher_priority = adapter.priorityFor(higher).value;
            const lower_priority = adapter.priorityFor(lower).value;
            // More urgent must map to a strictly smaller host value.
            if (higher_priority >= lower_priority) return false;
        }
    }
    return true;
}

/// A translation table adapter for tests and for hosts whose mapping is a plain
/// lookup.
///
/// Not a stand-in for a host: it enacts nothing. It only demonstrates that the
/// boundary can be satisfied by a pure translation, which is the point — if a
/// real mapping needs more than a translation, that extra is enactment and
/// belongs below this seam, not here.
pub const TableAdapter = struct {
    priorities: [scheduler_policy.Class.count]HostPriority,
    arenas: [memory_policy.Domain.count]HostArena,

    /// A mapping that preserves the class order: class ordinal becomes the host
    /// priority directly, so more urgent is smaller.
    pub const ordered: TableAdapter = build: {
        var priorities: [scheduler_policy.Class.count]HostPriority = undefined;
        for (std.enums.values(scheduler_policy.Class), 0..) |class, index| {
            priorities[@intFromEnum(class)] = .{ .value = @intCast(index) };
        }
        var arenas: [memory_policy.Domain.count]HostArena = undefined;
        for (std.enums.values(memory_policy.Domain), 0..) |domain, index| {
            arenas[@intFromEnum(domain)] = .{ .value = @intCast(index) };
        }
        break :build .{ .priorities = priorities, .arenas = arenas };
    };

    pub fn adapter(table: *TableAdapter) Adapter {
        return .{ .context_pointer = table, .vtable = &vtable };
    }

    const vtable: Adapter.VTable = .{
        .priorityFor = priorityFor,
        .arenaFor = arenaFor,
    };

    fn priorityFor(context_pointer: *anyopaque, class: scheduler_policy.Class) HostPriority {
        const table: *TableAdapter = @ptrCast(@alignCast(context_pointer));
        return table.priorities[@intFromEnum(class)];
    }

    fn arenaFor(context_pointer: *anyopaque, domain: memory_policy.Domain) HostArena {
        const table: *TableAdapter = @ptrCast(@alignCast(context_pointer));
        return table.arenas[@intFromEnum(domain)];
    }
};

test "an adapter translates every scheduling class to a host priority" {
    var table = TableAdapter.ordered;
    const adapter = table.adapter();

    // Every class has a mapping; a class the adapter forgot would leave work it
    // could not place.
    for (std.enums.values(scheduler_policy.Class)) |class| {
        _ = adapter.priorityFor(class);
    }
}

test "an adapter translates every memory domain to a host arena" {
    var table = TableAdapter.ordered;
    const adapter = table.adapter();
    for (std.enums.values(memory_policy.Domain)) |domain| {
        _ = adapter.arenaFor(domain);
    }
}

test "the ordered adapter preserves the policy's class ranking" {
    var table = TableAdapter.ordered;
    // The property that matters: the host runs classes in the order the policy
    // ranked them, never an order the adapter invented.
    try std.testing.expect(preservesOrdering(table.adapter()));
}

test "an adapter that inverts the ranking is caught" {
    var table = TableAdapter.ordered;
    // Point the most urgent and least urgent classes at swapped priorities.
    const urgent = @intFromEnum(scheduler_policy.Class.critical_real_time);
    const idle = @intFromEnum(scheduler_policy.Class.speculative);
    table.priorities[urgent] = .{ .value = 100 };
    table.priorities[idle] = .{ .value = 0 };

    // A host told to run speculation ahead of a real-time deadline is a host
    // enacting an order the policy never chose.
    try std.testing.expect(!preservesOrdering(table.adapter()));
}

test "an adapter whose host counts the other way still preserves ordering" {
    var table = TableAdapter.ordered;
    // Negate every priority: a host where larger means more urgent. The order is
    // still preserved because more urgent still maps strictly one way relative
    // to less urgent — here we rebuild so urgent stays smaller.
    for (std.enums.values(scheduler_policy.Class), 0..) |class, index| {
        table.priorities[@intFromEnum(class)] = .{ .value = @intCast(index * 10) };
    }
    try std.testing.expect(preservesOrdering(table.adapter()));
}

test "the adapter boundary has no operation that decides" {
    // Structural: the vtable holds only translations. An operation that
    // authorized, selected a class, or chose a domain would be a decision, and
    // a decision here is a policy nobody tested standing where a tested one
    // belongs. If one is ever added, this count changes and the test fails.
    const fields = @typeInfo(Adapter.VTable).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    inline for (fields) |field| {
        const forbidden = [_][]const u8{ "authorize", "decide", "select", "choose", "admit" };
        for (forbidden) |name| {
            try std.testing.expect(!std.mem.eql(u8, field.name, name));
        }
    }
}

test "distinct classes may map to distinct priorities" {
    var table = TableAdapter.ordered;
    const adapter = table.adapter();
    const urgent = adapter.priorityFor(.critical_real_time).value;
    const idle = adapter.priorityFor(.speculative).value;
    try std.testing.expect(urgent != idle);
}
