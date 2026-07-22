//! Which work runs first, and which work must never displace which.
//!
//! This is policy, not a scheduler. It holds no threads and dispatches nothing.
//! It answers one question — given work waiting in several classes, and budgets
//! that bound how much lower-priority work may cost higher-priority work, what
//! should run next — and it answers it as a pure function so the answer can be
//! checked without an operating system underneath.
//!
//! The rule the whole thing exists to enforce is from the platform's concurrency
//! model: a lower class must not degrade a higher class beyond a defined budget.
//! An agent's speculative preparation may run, but never at the cost of an audio
//! deadline or a person's keystroke. That is not achieved by hoping the higher
//! class is usually ready; it is achieved by refusing to admit lower-class work
//! whose cost would eat into a higher class's guarantee.

const std = @import("std");

/// The scheduling classes, most urgent first.
///
/// The order is the priority order, and the numeric values encode it, so a
/// comparison is a class comparison. Renumbering them would reorder the whole
/// system, which is why the values are explicit rather than positional.
pub const Class = enum(u8) {
    /// Audio, input, display deadlines, safety-related host operations. Missing
    /// one of these is a glitch a person sees or hears, or a safety property
    /// lost.
    critical_real_time = 0,
    /// Typing, scrolling, direct command response, approval interaction. The
    /// work a person is actively waiting on.
    human_interactive = 1,
    /// Work explicitly requested and still useful. An agent doing what it was
    /// told to do.
    committed_task = 2,
    /// Indexing, cleanup, updates, backups. Necessary, but not now.
    maintenance = 3,
    /// Predictions and proactive preparation with no committed output. The
    /// first thing to give up when anything else needs the machine.
    speculative = 4,

    pub const count = std.enums.values(Class).len;

    /// Whether this class outranks another. Lower ordinal is more urgent.
    pub fn outranks(class: Class, other: Class) bool {
        return @intFromEnum(class) < @intFromEnum(other);
    }

    /// Whether work in this class may be dropped to protect a higher class.
    ///
    /// The two interactive classes are never dropped: a dropped keystroke or a
    /// missed audio deadline is a failure a person experiences directly. The
    /// lower three shed instead, which is the whole point of their being lower.
    pub fn isSheddable(class: Class) bool {
        return @intFromEnum(class) > @intFromEnum(Class.human_interactive);
    }
};

/// How much of a higher class's time a lower class is allowed to consume.
///
/// Expressed as a share of a scheduling window in parts per thousand, so the
/// comparison is integer and identical on every host. A budget of 0 means the
/// lower class yields entirely whenever the higher class has work.
pub const Budget = struct {
    /// The share, out of one thousand, that sheddable work may take while
    /// higher-class work is waiting.
    permitted_per_mille: u16,

    pub const none: Budget = .{ .permitted_per_mille = 0 };

    pub fn isWithin(budget: Budget, spent_per_mille: u16) bool {
        return spent_per_mille <= budget.permitted_per_mille;
    }
};

/// Work waiting to run.
pub const Demand = struct {
    class: Class,
    /// How much of this class is ready. Zero means the class is idle.
    ready: u32,
    /// How much of the current window this class has already consumed, in parts
    /// per thousand. Used to hold a lower class to its budget.
    spent_per_mille: u16 = 0,
};

/// The budgets the policy enforces.
///
/// One per class, saying how much of the window that class may take while any
/// more-urgent class has work waiting. The two interactive classes have no
/// budget cap because they are never held back; their entries are ignored.
pub const Budgets = struct {
    per_class: [Class.count]Budget,

    /// A reference set: interactive work is never throttled, committed work may
    /// take most of a window, maintenance a little, speculation almost nothing.
    pub const reference: Budgets = .{
        .per_class = .{
            .none, // critical_real_time — never throttled
            .none, // human_interactive — never throttled
            .{ .permitted_per_mille = 800 }, // committed_task
            .{ .permitted_per_mille = 150 }, // maintenance
            .{ .permitted_per_mille = 50 }, // speculative
        },
    };

    pub fn forClass(budgets: Budgets, class: Class) Budget {
        return budgets.per_class[@intFromEnum(class)];
    }
};

/// What the policy decided to run, and why nothing more urgent did.
pub const Decision = union(enum) {
    /// This class should run next.
    run: Class,
    /// Nothing is ready.
    idle,
};

/// Chooses what runs next.
///
/// The urgent classes win whenever they have work, unconditionally. Among the
/// sheddable classes, a class runs only if it is the most urgent ready one whose
/// budget is not yet spent — so a maintenance job that has used its slice steps
/// aside for speculation rather than starving it, but neither ever runs while a
/// keystroke is waiting.
pub fn selectNext(demands: []const Demand, budgets: Budgets) Decision {
    // A more-urgent class with work always wins. This is the guarantee: nothing
    // below can be arranged to run ahead of it.
    var most_urgent_ready: ?Class = null;
    for (demands) |waiting| {
        if (waiting.ready == 0) continue;
        if (most_urgent_ready == null or waiting.class.outranks(most_urgent_ready.?)) {
            most_urgent_ready = waiting.class;
        }
    }

    const ready = most_urgent_ready orelse return .idle;

    // An interactive class runs immediately; it is never held to a budget.
    if (!ready.isSheddable()) return .{ .run = ready };

    // A sheddable class runs only within its budget. If it is over, the next
    // sheddable class down gets the chance, which is what stops a greedy
    // maintenance job from starving speculation while both are below the
    // interactive classes.
    var candidate: ?Class = null;
    for (demands) |waiting| {
        if (waiting.ready == 0) continue;
        if (!waiting.class.isSheddable()) continue;
        if (!budgets.forClass(waiting.class).isWithin(waiting.spent_per_mille)) continue;
        if (candidate == null or waiting.class.outranks(candidate.?)) {
            candidate = waiting.class;
        }
    }

    if (candidate) |class| return .{ .run = class };

    // Every ready class is a sheddable one that has spent its budget. The window
    // yields rather than overspending: the guarantee is a ceiling on lower-class
    // work, and honoring it sometimes means running nothing.
    return .idle;
}

/// Whether admitting new work of a class would breach a higher class's budget.
///
/// Called before work is queued, not after. A budget checked only at dispatch
/// is a budget already overspent by the time it is noticed; refusing admission
/// is how the guarantee holds under load rather than in the average case.
pub fn admits(
    class: Class,
    projected_spend_per_mille: u16,
    budgets: Budgets,
) bool {
    // Interactive and real-time work is always admitted: refusing a keystroke
    // to preserve a maintenance budget would be the priority inversion this
    // whole mechanism exists to prevent.
    if (!class.isSheddable()) return true;
    return budgets.forClass(class).isWithin(projected_spend_per_mille);
}

fn demand(class: Class, ready: u32, spent: u16) Demand {
    return .{ .class = class, .ready = ready, .spent_per_mille = spent };
}

test "the class order is the priority order" {
    try std.testing.expect(Class.critical_real_time.outranks(.human_interactive));
    try std.testing.expect(Class.human_interactive.outranks(.committed_task));
    try std.testing.expect(Class.committed_task.outranks(.maintenance));
    try std.testing.expect(Class.maintenance.outranks(.speculative));

    // Strict: a class does not outrank itself, and the relation is a total
    // order the whole way down.
    for (std.enums.values(Class)) |class| {
        try std.testing.expect(!class.outranks(class));
    }
}

test "a ready urgent class always wins" {
    // A keystroke waiting is a keystroke that runs, whatever else is ready.
    const decision = selectNext(&.{
        demand(.speculative, 100, 0),
        demand(.human_interactive, 1, 0),
        demand(.maintenance, 100, 0),
    }, .reference);
    try std.testing.expectEqual(Decision{ .run = .human_interactive }, decision);
}

test "real time beats even human-interactive" {
    const decision = selectNext(&.{
        demand(.human_interactive, 5, 0),
        demand(.critical_real_time, 1, 0),
    }, .reference);
    try std.testing.expectEqual(Decision{ .run = .critical_real_time }, decision);
}

test "an interactive class runs even with its budget field set" {
    // Interactive classes are never held to a budget; a stray spend value must
    // not throttle a person's input.
    const decision = selectNext(&.{
        demand(.human_interactive, 1, 65_535),
    }, .reference);
    try std.testing.expectEqual(Decision{ .run = .human_interactive }, decision);
}

test "a sheddable class runs within its budget" {
    const decision = selectNext(&.{
        demand(.maintenance, 10, 100),
    }, .reference);
    try std.testing.expectEqual(Decision{ .run = .maintenance }, decision);
}

test "a sheddable class that has spent its budget yields to the next one down" {
    // Maintenance is over budget; speculation is not. Speculation runs rather
    // than maintenance overspending, and neither runs ahead of anything urgent.
    const decision = selectNext(&.{
        demand(.maintenance, 10, 200), // over its 150 budget
        demand(.speculative, 10, 10), // under its 50 budget
    }, .reference);
    try std.testing.expectEqual(Decision{ .run = .speculative }, decision);
}

test "when every ready class is over budget the window yields" {
    // The guarantee is a ceiling. Honoring it sometimes means running nothing
    // rather than letting lower-class work eat a higher class's share.
    const decision = selectNext(&.{
        demand(.maintenance, 10, 900),
        demand(.speculative, 10, 900),
    }, .reference);
    try std.testing.expectEqual(Decision.idle, decision);
}

test "nothing ready is idle" {
    try std.testing.expectEqual(Decision.idle, selectNext(&.{
        demand(.committed_task, 0, 0),
        demand(.maintenance, 0, 0),
    }, .reference));
    try std.testing.expectEqual(Decision.idle, selectNext(&.{}, .reference));
}

test "a lower class never displaces a higher one, across every pairing" {
    // The property swept: for every pair of classes both ready, the one that
    // runs is never the lower of the two unless the higher is interactive-
    // exempt and... no — the higher always runs when it is urgent, and when
    // both are sheddable the more urgent within budget runs.
    const classes = std.enums.values(Class);
    for (classes) |higher| {
        for (classes) |lower| {
            if (!higher.outranks(lower)) continue;
            const decision = selectNext(&.{
                demand(higher, 1, 0),
                demand(lower, 1, 0),
            }, .reference);
            // With both fresh (nothing spent), the more urgent class runs.
            try std.testing.expectEqual(Decision{ .run = higher }, decision);
        }
    }
}

test "admission refuses lower-class work that would breach its budget" {
    // Checked before queueing: a budget noticed only at dispatch is already
    // overspent.
    try std.testing.expect(!admits(.speculative, 60, .reference)); // over 50
    try std.testing.expect(admits(.speculative, 40, .reference));
    try std.testing.expect(!admits(.maintenance, 200, .reference)); // over 150
    try std.testing.expect(admits(.maintenance, 100, .reference));
}

test "admission never refuses interactive or real-time work" {
    // Refusing a keystroke to preserve a maintenance budget is the inversion
    // this mechanism exists to prevent.
    try std.testing.expect(admits(.critical_real_time, 65_535, .reference));
    try std.testing.expect(admits(.human_interactive, 65_535, .reference));
}

test "the interactive classes are never sheddable and the rest always are" {
    try std.testing.expect(!Class.critical_real_time.isSheddable());
    try std.testing.expect(!Class.human_interactive.isSheddable());
    try std.testing.expect(Class.committed_task.isSheddable());
    try std.testing.expect(Class.maintenance.isSheddable());
    try std.testing.expect(Class.speculative.isSheddable());
}

test "a budget of zero yields entirely to any waiting higher class" {
    // The strictest budget: the class runs only when nothing above it is ready.
    const budgets: Budgets = .{ .per_class = @splat(.none) };

    // Nothing above it ready: it may run, because at spend 0 it is within a
    // zero budget.
    try std.testing.expectEqual(Decision{ .run = .maintenance }, selectNext(&.{
        demand(.maintenance, 1, 0),
    }, budgets));

    // The moment it has spent anything, a zero budget stops it.
    try std.testing.expectEqual(Decision.idle, selectNext(&.{
        demand(.maintenance, 1, 1),
    }, budgets));
}
