//! Deciding which agent runs next when several want the machine, and stopping
//! one that will not stop itself.
//!
//! A device runs several agents, and they compete for a bounded amount of
//! compute. Left to themselves they would not share it fairly: a speculative
//! agent doing proactive work would happily consume every cycle a person's
//! foreground agent needs, and an agent stuck in a loop would run forever. So an
//! agent does not get the machine because it asked; it gets a turn proportional
//! to its priority, and it is preempted when it has had its share or when it has
//! run past the deadline its budget allows. The scheduler is what makes many
//! agents on one device feel like a device that serves the person rather than
//! the agents.
//!
//! This module decides the next agent to run and whether a running one must
//! yield. It runs nothing itself; it answers, given what each agent has consumed
//! and what it is owed, which should run next, so fairness and preemption are one
//! decision rather than each executor's improvisation.

const std = @import("std");

/// How much of the machine an agent is entitled to, relative to its peers.
///
/// A foreground agent a person is waiting on outranks background ones, and among
/// equals the one that has had the least gets the next turn. Ordered so a
/// comparison decides precedence.
pub const Priority = enum(u8) {
    /// Proactive, speculative work with no one waiting. Runs only on leftover
    /// time.
    background = 0,
    /// Committed work the person requested but is not actively watching.
    committed = 1,
    /// The agent the person is interacting with right now. Served first.
    foreground = 2,

    pub fn outranks(priority: Priority, other: Priority) bool {
        return @intFromEnum(priority) > @intFromEnum(other);
    }
};

/// An agent competing for the machine.
pub const Agent = struct {
    id: u32,
    priority: Priority,
    /// Compute consumed so far in the current accounting window, in
    /// milliseconds. Reset when the window rolls over.
    consumed_ms: u64 = 0,
    /// The most compute this agent may consume before it is preempted, in
    /// milliseconds. A budget it cannot exceed, which is what stops a looping
    /// agent running forever.
    budget_ms: u64,
    /// Whether the agent currently has work ready to run.
    runnable: bool = true,

    /// Whether the agent has exhausted its budget and must be preempted.
    fn overBudget(agent: Agent) bool {
        return agent.consumed_ms >= agent.budget_ms;
    }
};

/// What the scheduler decided.
pub const Decision = union(enum) {
    /// Run this agent's id next.
    run: u32,
    /// Nothing is runnable.
    idle,

    pub fn hasWork(decision: Decision) bool {
        return decision == .run;
    }
};

/// Chooses the next agent to run.
///
/// Among runnable agents that have not exhausted their budget, the highest
/// priority runs; among equal priority, the one that has consumed the least, so
/// fairness within a tier is proportional to what each has already had. An agent
/// over its budget is not chosen even if it is the highest priority — its budget
/// is a hard ceiling, and being important does not exempt it from the limit that
/// stops a runaway. This is what keeps one agent from starving the rest and a
/// looping agent from holding the machine.
pub fn selectNext(agents: []const Agent) Decision {
    var best: ?Agent = null;
    for (agents) |agent| {
        if (!agent.runnable) continue;
        if (agent.overBudget()) continue;
        if (best == null or beats(agent, best.?)) best = agent;
    }
    if (best) |agent| return .{ .run = agent.id };
    return .idle;
}

/// Whether agent a should run before agent b: higher priority, or equal priority
/// with less consumed.
fn beats(a: Agent, b: Agent) bool {
    if (a.priority.outranks(b.priority)) return true;
    if (b.priority.outranks(a.priority)) return false;
    return a.consumed_ms < b.consumed_ms;
}

/// Whether a running agent must yield now, given how long it has run this turn.
///
/// It yields when running longer would carry it past its budget, so the budget
/// is enforced even mid-turn rather than only checked between turns. A looping
/// agent that never voluntarily yields is preempted here.
pub fn mustYield(agent: Agent, this_turn_ms: u64) bool {
    return agent.consumed_ms + this_turn_ms >= agent.budget_ms;
}

fn agentOf(id: u32, priority: Priority, consumed: u64, budget: u64) Agent {
    return .{ .id = id, .priority = priority, .consumed_ms = consumed, .budget_ms = budget };
}

test "the highest-priority runnable agent runs" {
    const agents = [_]Agent{
        agentOf(1, .background, 0, 1000),
        agentOf(2, .foreground, 0, 1000),
        agentOf(3, .committed, 0, 1000),
    };
    try std.testing.expectEqual(Decision{ .run = 2 }, selectNext(&agents));
}

test "among equal priority the least-consumed runs" {
    const agents = [_]Agent{
        agentOf(1, .committed, 500, 1000),
        agentOf(2, .committed, 100, 1000),
        agentOf(3, .committed, 300, 1000),
    };
    // Agent 2 has had the least, so it gets the next turn: fairness within a
    // tier.
    try std.testing.expectEqual(Decision{ .run = 2 }, selectNext(&agents));
}

test "an over-budget agent is not chosen, even at high priority" {
    const agents = [_]Agent{
        agentOf(1, .foreground, 1000, 1000), // exhausted
        agentOf(2, .committed, 0, 1000),
    };
    // The foreground agent is over budget; being important does not exempt it.
    try std.testing.expectEqual(Decision{ .run = 2 }, selectNext(&agents));
}

test "a non-runnable agent is skipped" {
    var agents = [_]Agent{
        agentOf(1, .foreground, 0, 1000),
        agentOf(2, .committed, 0, 1000),
    };
    agents[0].runnable = false;
    try std.testing.expectEqual(Decision{ .run = 2 }, selectNext(&agents));
}

test "nothing runnable is idle" {
    var agents = [_]Agent{agentOf(1, .foreground, 0, 1000)};
    agents[0].runnable = false;
    try std.testing.expectEqual(Decision.idle, selectNext(&agents));
    try std.testing.expectEqual(Decision.idle, selectNext(&.{}));
}

test "every agent over budget is idle" {
    const agents = [_]Agent{
        agentOf(1, .foreground, 1000, 1000),
        agentOf(2, .committed, 1000, 1000),
    };
    // All exhausted: the machine yields rather than running a runaway.
    try std.testing.expectEqual(Decision.idle, selectNext(&agents));
}

test "a running agent yields before exceeding its budget" {
    const agent = agentOf(1, .committed, 900, 1000);
    // 100 ms more reaches the budget: it must yield.
    try std.testing.expect(mustYield(agent, 100));
    // 50 ms more stays under: it may continue.
    try std.testing.expect(!mustYield(agent, 50));
}

test "a looping agent is preempted at its budget" {
    // An agent that never voluntarily yields hits the ceiling and is stopped.
    const agent = agentOf(1, .foreground, 0, 500);
    try std.testing.expect(mustYield(agent, 500));
    try std.testing.expect(mustYield(agent, 10_000));
}

test "priority beats consumption across tiers" {
    // A foreground agent that has consumed a lot still beats a fresh background
    // one: priority is the primary key, consumption only the tiebreaker.
    const agents = [_]Agent{
        agentOf(1, .foreground, 900, 1000),
        agentOf(2, .background, 0, 1000),
    };
    try std.testing.expectEqual(Decision{ .run = 1 }, selectNext(&agents));
}

test "the priority order runs background, committed, foreground" {
    try std.testing.expect(Priority.foreground.outranks(.committed));
    try std.testing.expect(Priority.committed.outranks(.background));
    try std.testing.expect(!Priority.background.outranks(.foreground));
}

test "no agent starves: least-consumed always advances within a tier" {
    // Simulate several rounds where the selected agent consumes a slice; the
    // consumption spreads across the tier rather than concentrating on one.
    var agents = [_]Agent{
        agentOf(1, .committed, 0, 100_000),
        agentOf(2, .committed, 0, 100_000),
        agentOf(3, .committed, 0, 100_000),
    };
    for (0..30) |_| {
        const decision = selectNext(&agents);
        const id = decision.run;
        agents[id - 1].consumed_ms += 10;
    }
    // After thirty equal slices across three equal agents, each has had about a
    // third: no one starved.
    for (agents) |agent| {
        try std.testing.expect(agent.consumed_ms >= 90 and agent.consumed_ms <= 110);
    }
}
