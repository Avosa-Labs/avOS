//! Calculator, agent-native: a default app that computes, with operations an agent may
//! run freely because they are pure arithmetic that touches nothing and holds no
//! authority.
//!
//! The calculator is the clearest case of an app whose whole surface is safe for an
//! agent: computing a result reads no private data, changes no device state, and
//! reaches nowhere outside. So its capabilities are read-only, the agent's to run
//! without approval, and the app holds no capability of its own beyond the arithmetic.
//! Evaluation is here as pure functions; a division by zero is refused rather than
//! trapping, because a calculator that crashes on a bad input is worse than one that
//! says it cannot.
//!
//! This module defines the app's capabilities and its arithmetic; the shared frame
//! gates and records.

const std = @import("std");
const framework = @import("../framework/agent_app.zig");
const domain = @import("domain.zig");

pub const tools = [_]framework.Tool{
    .{ .name = "calc.evaluate", .required_capability = "calculator.use", .effect = .read_only },
};

/// `calc.evaluate` — evaluate a full arithmetic expression, the app's expression domain. Both the
/// person's keypad and an agent reach this one function; it is read-only and needs no approval.
pub const evaluateExpression = domain.evaluate;
pub const ExpressionError = domain.Error;

pub const Op = enum { add, subtract, multiply, divide };

pub const Error = error{DivideByZero};

/// Evaluates a binary operation, refusing a division by zero rather than trapping.
pub fn evaluate(op: Op, a: f64, b: f64) Error!f64 {
    return switch (op) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => if (b == 0) error.DivideByZero else a / b,
    };
}

const testing = std.testing;

test "arithmetic evaluates and division by zero is refused" {
    try testing.expectEqual(@as(f64, 7), try evaluate(.add, 3, 4));
    try testing.expectEqual(@as(f64, 12), try evaluate(.multiply, 3, 4));
    try testing.expectError(error.DivideByZero, evaluate(.divide, 1, 0));
}

test "evaluating is read-only and needs no approval" {
    try testing.expect(!tools[0].effect.needsApproval());
}
