//! Evaluating an access request against a set of rules, deny-overrides and
//! fail-closed, so a request is permitted only when a rule says so and nothing
//! forbids it.
//!
//! A control plane needs one place that answers "may this subject do this action
//! to this resource?", because scattering that decision across every service is
//! how the same request comes out permitted in one place and denied in another.
//! The answer is computed from rules, and two properties make it safe. It is
//! deny-overrides: if any rule forbids the request it is denied, whatever else
//! permits it, because a prohibition is a stronger statement than a permission and
//! an attacker who can add a permit must not thereby erase a deny. And it is
//! fail-closed: a request that no rule addresses is denied, not allowed, because a
//! gap in the rules is not a grant — silent permission is exactly the mistake that
//! turns a missing rule into an open door.
//!
//! This module holds no rules of its own and performs no action. It evaluates a
//! request against a rule set and returns permit, deny, or not-applicable, and a
//! fail-closed authorize that collapses not-applicable to deny — as a pure function
//! so the same request always yields the same decision wherever it is asked.

const std = @import("std");

/// What a rule does when it matches.
pub const Effect = enum { permit, deny };

/// A wildcard that matches any value in a rule field.
pub const any = "*";

/// One rule: an effect and the subject, action, and resource it applies to. A
/// field of `any` matches anything; otherwise the match is exact.
pub const Rule = struct {
    effect: Effect,
    subject: []const u8,
    action: []const u8,
    resource: []const u8,

    fn field_matches(pattern: []const u8, value: []const u8) bool {
        return std.mem.eql(u8, pattern, any) or std.mem.eql(u8, pattern, value);
    }

    fn matches(rule: Rule, request: Request) bool {
        return field_matches(rule.subject, request.subject) and
            field_matches(rule.action, request.action) and
            field_matches(rule.resource, request.resource);
    }
};

/// An access request: who wants to do what to what.
pub const Request = struct {
    subject: []const u8,
    action: []const u8,
    resource: []const u8,
};

/// The result of evaluating a request.
pub const Decision = enum {
    /// A permit rule matched and no deny rule did.
    permit,
    /// A deny rule matched; the request is forbidden.
    deny,
    /// No rule addressed the request at all. Distinguished from deny so a caller
    /// can tell "forbidden" from "unspoken", but treated as deny by authorize.
    not_applicable,

    pub fn isPermit(decision: Decision) bool {
        return decision == .permit;
    }
};

/// Evaluates a request against a rule set, deny-overrides.
///
/// Every rule is considered. A single matching deny forbids the request outright,
/// regardless of any permit, because a prohibition cannot be overridden by adding
/// a permission. If no deny matches but at least one permit does, the request is
/// permitted. If nothing matches, the request is not applicable — no rule spoke to
/// it. The deny check spans the whole rule set before any permit is honoured, so
/// a deny placed anywhere wins.
pub fn evaluate(rules: []const Rule, request: Request) Decision {
    var permitted = false;
    for (rules) |rule| {
        if (!rule.matches(request)) continue;
        if (rule.effect == .deny) return .deny; // deny-overrides: a single deny is final
        permitted = true;
    }
    return if (permitted) .permit else .not_applicable;
}

/// The fail-closed decision: whether a request is authorized.
///
/// Only an explicit permit authorizes. A deny and a not-applicable both refuse,
/// because an unaddressed request is not a granted one — a gap in the rules must
/// never read as permission.
pub fn authorize(rules: []const Rule, request: Request) bool {
    return evaluate(rules, request).isPermit();
}

const sample_rules = [_]Rule{
    .{ .effect = .permit, .subject = "calendar-agent", .action = "read", .resource = "calendar" },
    .{ .effect = .permit, .subject = any, .action = "read", .resource = "clock" },
    .{ .effect = .deny, .subject = "calendar-agent", .action = "delete", .resource = any },
};

fn makeRequest(subject: []const u8, action: []const u8, resource: []const u8) Request {
    return .{ .subject = subject, .action = action, .resource = resource };
}

test "a matching permit with no deny permits" {
    try std.testing.expectEqual(Decision.permit, evaluate(&sample_rules, makeRequest("calendar-agent", "read", "calendar")));
    try std.testing.expect(authorize(&sample_rules, makeRequest("calendar-agent", "read", "calendar")));
}

test "a wildcard subject permits any subject" {
    try std.testing.expect(authorize(&sample_rules, makeRequest("anyone", "read", "clock")));
}

test "an unaddressed request is not applicable and unauthorized" {
    // No rule mentions writing the calendar.
    try std.testing.expectEqual(Decision.not_applicable, evaluate(&sample_rules, makeRequest("calendar-agent", "write", "calendar")));
    try std.testing.expect(!authorize(&sample_rules, makeRequest("calendar-agent", "write", "calendar")));
}

test "a matching deny forbids the request" {
    try std.testing.expectEqual(Decision.deny, evaluate(&sample_rules, makeRequest("calendar-agent", "delete", "calendar")));
    try std.testing.expect(!authorize(&sample_rules, makeRequest("calendar-agent", "delete", "calendar")));
}

test "deny overrides permit whatever the order" {
    // A permit and a deny both match; the deny wins regardless of position.
    const permit_first = [_]Rule{
        .{ .effect = .permit, .subject = "a", .action = "x", .resource = "r" },
        .{ .effect = .deny, .subject = "a", .action = "x", .resource = "r" },
    };
    const deny_first = [_]Rule{
        .{ .effect = .deny, .subject = "a", .action = "x", .resource = "r" },
        .{ .effect = .permit, .subject = "a", .action = "x", .resource = "r" },
    };
    try std.testing.expectEqual(Decision.deny, evaluate(&permit_first, makeRequest("a", "x", "r")));
    try std.testing.expectEqual(Decision.deny, evaluate(&deny_first, makeRequest("a", "x", "r")));
}

test "an empty rule set permits nothing" {
    try std.testing.expectEqual(Decision.not_applicable, evaluate(&.{}, makeRequest("a", "x", "r")));
    try std.testing.expect(!authorize(&.{}, makeRequest("a", "x", "r")));
}

test "a wildcard deny forbids across resources" {
    // calendar-agent may not delete anything: the deny's resource is any.
    try std.testing.expect(!authorize(&sample_rules, makeRequest("calendar-agent", "delete", "documents")));
    try std.testing.expect(!authorize(&sample_rules, makeRequest("calendar-agent", "delete", "photos")));
}

test "authorize is never true without an explicit permit, swept" {
    // The fail-closed property: across a range of requests, authorize is true only
    // when evaluate is permit; deny and not-applicable both refuse.
    const subjects = [_][]const u8{ "calendar-agent", "other", "anyone" };
    const actions = [_][]const u8{ "read", "write", "delete" };
    const resources = [_][]const u8{ "calendar", "clock", "documents" };
    for (subjects) |s| {
        for (actions) |a| {
            for (resources) |r| {
                const req = makeRequest(s, a, r);
                const decision = evaluate(&sample_rules, req);
                try std.testing.expectEqual(decision == .permit, authorize(&sample_rules, req));
            }
        }
    }
}
