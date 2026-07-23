//! Assembling the context a model sees, within a token budget, without letting
//! untrusted text pose as instructions.
//!
//! A model is given a context — its instructions, the person's request, and
//! whatever retrieved material bears on the task — and two things about how that
//! context is built decide whether the agent is safe and useful. First, the
//! window is finite, so material must be selected to fit a token budget rather
//! than truncated arbitrarily mid-thought, which is how a model loses the
//! instruction that was about to constrain it. Second, retrieved material is
//! untrusted content the model reads, not instructions the model obeys, and if
//! the two are concatenated indistinguishably then text in a document saying
//! "ignore your instructions" is read as an instruction — the injection the
//! provenance model exists to stop, reaching the model because the context
//! builder blurred the boundary.
//!
//! This module assembles the context. It selects segments to fit the budget by
//! priority, keeps trusted instructions and untrusted content in separate
//! regions the model is told to treat differently, and never lets an untrusted
//! segment displace a trusted one. It renders no prompt string; it decides what
//! goes in and how it is framed.

const std = @import("std");
const core = @import("core");

/// What role a segment plays in the context, which fixes both its priority and
/// how it is framed to the model.
pub const Role = enum(u8) {
    /// The agent's own instructions. Highest priority: never dropped, always
    /// framed as authority.
    system_instruction = 0,
    /// The person's request. Second: the reason the agent is running.
    user_request = 1,
    /// Prior turns of the conversation, trusted because they are the person's
    /// and the agent's own words.
    conversation = 2,
    /// Retrieved material: documents, search results, tool output. Untrusted
    /// content the model reads. Framed as data, never as instruction, and the
    /// first to be dropped when the budget is tight.
    retrieved = 3,

    /// Whether a segment of this role is trusted, or untrusted content the model
    /// must not obey.
    pub fn isTrusted(role: Role) bool {
        return role != .retrieved;
    }
};

/// A candidate segment for the context.
pub const Segment = struct {
    role: Role,
    /// The segment's size in tokens, precomputed by the caller.
    tokens: u32,
    /// A handle to the content. The builder decides inclusion; it does not hold
    /// the bytes.
    content_id: u64,
};

/// A segment as placed in the assembled context.
pub const Placed = struct {
    segment: Segment,
    /// Which region it goes in: trusted material the model treats as authority,
    /// or untrusted material it treats as data.
    region: Region,

    pub const Region = enum { trusted, untrusted };
};

/// The result of assembling a context.
pub const Assembly = struct {
    placed: []const Placed,
    /// Tokens used, always within the budget.
    tokens_used: u32,
    /// How many untrusted segments were dropped to fit. Reported so a caller can
    /// tell the model, and the person, that retrieval was truncated rather than
    /// silently losing material.
    dropped_untrusted: u32,

    pub fn regionOf(assembly: Assembly, index: usize) Placed.Region {
        return assembly.placed[index].region;
    }
};

/// The most segments an assembly holds.
pub const max_segments: usize = 64;

/// Assembles a context from candidate segments within a token budget.
///
/// Segments are admitted in priority order — system instructions, then the
/// request, then conversation, then retrieved material — so that when the budget
/// runs out it is the lowest-priority, untrusted retrieved material that is
/// dropped, never the instructions that constrain the agent. Trusted segments go
/// in a trusted region and untrusted ones in a separate region the model is told
/// to treat as data, so retrieved text can never pose as an instruction however
/// it is worded. A trusted segment is never displaced by an untrusted one: the
/// selection admits all trusted material that fits before any retrieved material
/// is considered.
pub fn assemble(
    candidates: []const Segment,
    budget_tokens: u32,
    into: []Placed,
) Assembly {
    var used: u32 = 0;
    var count: usize = 0;
    var dropped: u32 = 0;

    // Two passes over the roles in priority order. Trusted roles first, all of
    // them, so no untrusted segment can take a slot a trusted one needed.
    const order = [_]Role{ .system_instruction, .user_request, .conversation, .retrieved };
    for (order) |role| {
        for (candidates) |candidate| {
            if (candidate.role != role) continue;
            if (count >= into.len) {
                if (!role.isTrusted()) dropped += 1;
                continue;
            }
            if (used + candidate.tokens > budget_tokens) {
                // Over budget. A trusted segment that does not fit is a
                // misconfiguration the caller must resize; an untrusted one is
                // simply dropped, which is the expected pressure valve.
                if (!role.isTrusted()) dropped += 1;
                continue;
            }
            into[count] = .{
                .segment = candidate,
                .region = if (role.isTrusted()) .trusted else .untrusted,
            };
            used += candidate.tokens;
            count += 1;
        }
    }

    return .{ .placed = into[0..count], .tokens_used = used, .dropped_untrusted = dropped };
}

fn segment(role: Role, tokens: u32, id: u64) Segment {
    return .{ .role = role, .tokens = tokens, .content_id = id };
}

test "a context that fits includes everything in priority order" {
    const candidates = [_]Segment{
        segment(.retrieved, 100, 1),
        segment(.system_instruction, 50, 2),
        segment(.user_request, 30, 3),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 1000, &buffer);

    try std.testing.expectEqual(@as(usize, 3), assembly.placed.len);
    // System instruction first regardless of input order.
    try std.testing.expectEqual(Role.system_instruction, assembly.placed[0].segment.role);
    try std.testing.expectEqual(Role.user_request, assembly.placed[1].segment.role);
    try std.testing.expectEqual(Role.retrieved, assembly.placed[2].segment.role);
}

test "retrieved material is dropped first when the budget is tight" {
    const candidates = [_]Segment{
        segment(.system_instruction, 50, 1),
        segment(.user_request, 30, 2),
        segment(.retrieved, 100, 3),
        segment(.retrieved, 100, 4),
    };
    // Budget fits the instructions and request but only leaves room for nothing
    // more.
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 90, &buffer);

    // Both trusted segments made it; both retrieved were dropped.
    try std.testing.expectEqual(@as(usize, 2), assembly.placed.len);
    try std.testing.expectEqual(@as(u32, 2), assembly.dropped_untrusted);
    for (assembly.placed) |placed| try std.testing.expect(placed.segment.role.isTrusted());
}

test "a trusted segment is never displaced by an untrusted one" {
    // A large retrieved segment appears before the instruction in the input, but
    // the instruction must still be admitted first and the retrieved dropped.
    const candidates = [_]Segment{
        segment(.retrieved, 80, 1),
        segment(.system_instruction, 50, 2),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 100, &buffer);

    // Only room for one of them after priority: the instruction wins.
    try std.testing.expectEqual(@as(usize, 1), assembly.placed.len);
    try std.testing.expectEqual(Role.system_instruction, assembly.placed[0].segment.role);
    try std.testing.expectEqual(@as(u32, 1), assembly.dropped_untrusted);
}

test "trusted and untrusted segments land in separate regions" {
    const candidates = [_]Segment{
        segment(.system_instruction, 10, 1),
        segment(.retrieved, 10, 2),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 1000, &buffer);

    for (assembly.placed) |placed| {
        if (placed.segment.role.isTrusted()) {
            try std.testing.expectEqual(Placed.Region.trusted, placed.region);
        } else {
            try std.testing.expectEqual(Placed.Region.untrusted, placed.region);
        }
    }
}

test "no retrieved segment is ever placed in the trusted region" {
    // The property that stops injection: retrieved text is always framed as data,
    // never as instruction, whatever it contains.
    const candidates = [_]Segment{
        segment(.retrieved, 10, 1),
        segment(.retrieved, 10, 2),
        segment(.system_instruction, 10, 3),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 1000, &buffer);
    for (assembly.placed) |placed| {
        if (placed.segment.role == .retrieved) {
            try std.testing.expectEqual(Placed.Region.untrusted, placed.region);
        }
    }
}

test "the assembly never exceeds its budget" {
    const candidates = [_]Segment{
        segment(.system_instruction, 400, 1),
        segment(.user_request, 400, 2),
        segment(.retrieved, 400, 3),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 900, &buffer);
    try std.testing.expect(assembly.tokens_used <= 900);
}

test "dropped material is counted, not silently lost" {
    const candidates = [_]Segment{
        segment(.retrieved, 100, 1),
        segment(.retrieved, 100, 2),
        segment(.retrieved, 100, 3),
    };
    var buffer: [max_segments]Placed = undefined;
    // Room for one retrieved segment.
    const assembly = assemble(&candidates, 100, &buffer);
    try std.testing.expectEqual(@as(usize, 1), assembly.placed.len);
    try std.testing.expectEqual(@as(u32, 2), assembly.dropped_untrusted);
}

test "an oversized trusted segment does not silently drop untrusted count" {
    // A system instruction larger than the whole budget: it is not placed, and
    // this is a caller misconfiguration, but it must not be miscounted as a
    // dropped untrusted segment.
    const candidates = [_]Segment{segment(.system_instruction, 1000, 1)};
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 100, &buffer);
    try std.testing.expectEqual(@as(usize, 0), assembly.placed.len);
    try std.testing.expectEqual(@as(u32, 0), assembly.dropped_untrusted);
}

test "conversation ranks above retrieval" {
    // The person's own prior words are trusted and kept before untrusted
    // retrieved material.
    const candidates = [_]Segment{
        segment(.retrieved, 60, 1),
        segment(.conversation, 60, 2),
    };
    var buffer: [max_segments]Placed = undefined;
    const assembly = assemble(&candidates, 60, &buffer);
    try std.testing.expectEqual(@as(usize, 1), assembly.placed.len);
    try std.testing.expectEqual(Role.conversation, assembly.placed[0].segment.role);
}

test "only retrieved material is untrusted" {
    try std.testing.expect(Role.system_instruction.isTrusted());
    try std.testing.expect(Role.user_request.isTrusted());
    try std.testing.expect(Role.conversation.isTrusted());
    try std.testing.expect(!Role.retrieved.isTrusted());
}
