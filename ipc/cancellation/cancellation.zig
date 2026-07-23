//! Deciding whether a cancel takes effect on an in-flight request, and telling a
//! worker when to stop, so cancellation is cooperative, authorized, and safe to
//! repeat.
//!
//! A request in flight can outlive the reason it was made: the person navigated
//! away, the deadline passed, the task it belonged to was abandoned. Cancellation
//! is how that request is stopped, and it has to be done carefully. It is
//! cooperative, not violent — a worker is asked to stop at a safe point rather than
//! killed mid-mutation, because tearing down work partway is how state is left
//! half-written. It is authorized — a caller may cancel only a request made on the
//! same authority, or anyone could stop anyone's work by naming a correlation. And
//! it is idempotent — a cancel for a request that already finished, or a second
//! cancel for one already cancelling, is a no-op, because cancels race with
//! completion and a duplicate must not be an error.
//!
//! This module stops nothing itself. It records in-flight requests, decides whether
//! a given cancel may act on one, and answers whether a worker should stop — either
//! because it was cancelled or because its deadline has passed — as pure decisions
//! over the request set.

const std = @import("std");

/// Distinguishes one request from another. Matches the envelope's correlation.
pub const Correlation = u64;

/// The state of an in-flight request as far as cancellation is concerned.
pub const State = enum {
    /// Running normally.
    active,
    /// Marked to stop at its next safe point; the worker has not yet acknowledged.
    cancelling,
    /// Finished, whether it completed or stopped. A terminal state.
    done,

    fn isTerminal(state: State) bool {
        return state == .done;
    }
};

/// An in-flight request the canceller tracks.
pub const Request = struct {
    correlation: Correlation,
    /// The principal the request acts on behalf of. A cancel must come from the
    /// same principal to take effect.
    principal: u128,
    /// When the request stops being worth doing, in nanoseconds since the epoch.
    /// Zero means no deadline.
    deadline_nanoseconds: i64 = 0,
    state: State = .active,

    fn hasDeadline(request: Request) bool {
        return request.deadline_nanoseconds != 0;
    }

    /// Whether the worker for this request should stop now.
    ///
    /// It stops if it has been marked cancelling, or if it has a deadline that has
    /// passed. A worker calls this at its safe points, which is what makes
    /// cancellation cooperative: the request is asked to stop, and stops itself,
    /// rather than being torn down from outside mid-operation.
    pub fn shouldStop(request: Request, now_nanoseconds: i64) bool {
        if (request.state == .cancelling) return true;
        if (request.hasDeadline() and now_nanoseconds >= request.deadline_nanoseconds) return true;
        return false;
    }
};

/// Why a cancel did not act.
pub const Outcome = enum {
    /// The request was active and is now marked to stop.
    marked,
    /// No such request, or it had already finished. A no-op, not an error, because
    /// a cancel races with completion.
    not_found,
    /// The request exists but was already cancelling. A no-op; cancellation is
    /// idempotent.
    already_cancelling,
    /// The cancel came from a different principal than the request. Refused, so
    /// one caller cannot stop another's work.
    not_authorized,
};

/// A cancel message: which request, on whose authority.
pub const Cancel = struct {
    correlation: Correlation,
    principal: u128,
};

/// A bounded set of in-flight requests that cancels act against.
pub const Registry = struct {
    requests: []Request,

    fn find(registry: Registry, correlation: Correlation) ?*Request {
        for (registry.requests) |*request| {
            if (request.correlation == correlation and !request.state.isTerminal()) {
                return request;
            }
        }
        return null;
    }

    /// Applies a cancel, returning what it did.
    ///
    /// A cancel for an unknown or already-finished correlation is a no-op. A cancel
    /// from a principal other than the request's owner is refused before it can
    /// act. A cancel for a request already cancelling is a no-op, so a duplicate is
    /// harmless. Only an active request owned by the caller is marked to stop.
    pub fn cancel(registry: Registry, message: Cancel) Outcome {
        const request = registry.find(message.correlation) orelse return .not_found;
        if (request.principal != message.principal) return .not_authorized;
        if (request.state == .cancelling) return .already_cancelling;
        request.state = .cancelling;
        return .marked;
    }

    /// Marks a request finished, whether it completed or stopped. After this a
    /// cancel for it is a no-op.
    pub fn complete(registry: Registry, correlation: Correlation) void {
        if (registry.find(correlation)) |request| request.state = .done;
    }

    /// Whether a request should stop now, by correlation. Unknown or finished
    /// requests do not stop — there is nothing to stop.
    pub fn shouldStop(registry: Registry, correlation: Correlation, now_nanoseconds: i64) bool {
        const request = registry.find(correlation) orelse return false;
        return request.shouldStop(now_nanoseconds);
    }
};

const owner: u128 = 0xA11CE;
const stranger: u128 = 0xB0B;

fn oneRequest() [1]Request {
    return .{.{ .correlation = 1, .principal = owner }};
}

test "cancelling an active request marks it to stop" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    try std.testing.expectEqual(Outcome.marked, registry.cancel(.{ .correlation = 1, .principal = owner }));
    try std.testing.expectEqual(State.cancelling, requests[0].state);
    try std.testing.expect(registry.shouldStop(1, 0));
}

test "a cancel from another principal is refused" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    try std.testing.expectEqual(
        Outcome.not_authorized,
        registry.cancel(.{ .correlation = 1, .principal = stranger }),
    );
    // The request is untouched.
    try std.testing.expectEqual(State.active, requests[0].state);
}

test "a cancel for an unknown correlation is a no-op" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    try std.testing.expectEqual(
        Outcome.not_found,
        registry.cancel(.{ .correlation = 999, .principal = owner }),
    );
}

test "a cancel for a finished request is a no-op" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    registry.complete(1);
    try std.testing.expectEqual(
        Outcome.not_found,
        registry.cancel(.{ .correlation = 1, .principal = owner }),
    );
}

test "cancellation is idempotent" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    try std.testing.expectEqual(Outcome.marked, registry.cancel(.{ .correlation = 1, .principal = owner }));
    // A second cancel is harmless, not an error.
    try std.testing.expectEqual(
        Outcome.already_cancelling,
        registry.cancel(.{ .correlation = 1, .principal = owner }),
    );
}

test "a worker stops when marked" {
    const request: Request = .{ .correlation = 1, .principal = owner, .state = .cancelling };
    try std.testing.expect(request.shouldStop(0));
}

test "a worker stops when its deadline passes, without an explicit cancel" {
    const request: Request = .{
        .correlation = 1,
        .principal = owner,
        .deadline_nanoseconds = 1000,
    };
    try std.testing.expect(!request.shouldStop(999));
    try std.testing.expect(request.shouldStop(1000));
    try std.testing.expect(request.shouldStop(1001));
}

test "a request with no deadline and no cancel keeps running" {
    const request: Request = .{ .correlation = 1, .principal = owner };
    try std.testing.expect(!request.shouldStop(std.math.maxInt(i64)));
}

test "authorization is checked before the idempotency shortcut, swept" {
    // Even for a request already cancelling, a stranger's cancel is refused rather
    // than reported as a harmless duplicate: a stranger learns nothing about the
    // request's state.
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    _ = registry.cancel(.{ .correlation = 1, .principal = owner });
    try std.testing.expectEqual(
        Outcome.not_authorized,
        registry.cancel(.{ .correlation = 1, .principal = stranger }),
    );
}

test "completing a request stops its worker from being cancellable but not from having stopped" {
    var requests = oneRequest();
    const registry: Registry = .{ .requests = &requests };
    registry.complete(1);
    // A finished request is not asked to stop again; there is nothing to stop.
    try std.testing.expect(!registry.shouldStop(1, std.math.maxInt(i64)));
}

test "cancels across several requests act only on the named one" {
    var requests = [_]Request{
        .{ .correlation = 1, .principal = owner },
        .{ .correlation = 2, .principal = owner },
        .{ .correlation = 3, .principal = stranger },
    };
    const registry: Registry = .{ .requests = &requests };
    try std.testing.expectEqual(Outcome.marked, registry.cancel(.{ .correlation = 2, .principal = owner }));
    // Only request 2 is affected.
    try std.testing.expectEqual(State.active, requests[0].state);
    try std.testing.expectEqual(State.cancelling, requests[1].state);
    try std.testing.expectEqual(State.active, requests[2].state);
}
