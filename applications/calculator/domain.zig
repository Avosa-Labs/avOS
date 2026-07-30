//! The calculator's expression domain: parse and evaluate an arithmetic expression, from a plain
//! sum to a scientific one.
//!
//! A calculator is more than one binary operation — a person types "2 + 3 * 4" and expects 14, with
//! multiplication bound tighter than addition and parentheses overriding both. The scientific mode is
//! more still: a power, a percentage, the named functions and constants a person reaches for when the
//! four operations are not enough. This is that: a small recursive-descent evaluator over `+ - * /`,
//! a right-associative `^`, a postfix `%`, unary sign, parentheses, the functions sqrt/sin/cos/tan/
//! ln/log/exp/abs, and the constants pi and e, on real numbers. Trigonometry reads its argument in
//! whichever angle mode the person has set, degrees or radians, so `sin(90)` in degrees is 1 and the
//! basic and scientific keypads answer the same expression identically.
//!
//! It is the app's whole logic, reached identically by the person's keypad and by an agent's
//! `calc.evaluate`, and it is pure — it reads nothing, touches nothing, reaches nowhere — which is why
//! the calculator is the smallest complete app. It runs in a single left-to-right pass, each byte
//! consumed once, so evaluating an expression is O(n) in its length. A division by zero, a function
//! outside its domain (a negative square root, a non-positive logarithm), an unknown name, and a
//! malformed expression are all refused with an error rather than trapping or returning a silent NaN,
//! because a calculator that crashes or lies on bad input is worse than one that says it cannot.

const std = @import("std");

pub const Error = error{ DivideByZero, SyntaxError, UnknownName, Domain };

/// The angle unit trigonometric functions read their argument in. A person toggles it on the
/// scientific keypad; the default is radians, the mathematical convention.
pub const Angle = enum { radians, degrees };

/// Evaluates an arithmetic expression to a number in radians mode, or refuses it. The plain keypad's
/// entry point, and the one an agent reaches through `calc.evaluate`.
pub fn evaluate(expression: []const u8) Error!f64 {
    return evaluateIn(expression, .radians);
}

/// Evaluates an expression with trigonometry read in `angle`. Whitespace is ignored; the whole input
/// must be consumed, so trailing characters are a syntax error.
pub fn evaluateIn(expression: []const u8, angle: Angle) Error!f64 {
    var parser = Parser{ .src = expression, .angle = angle };
    const value = try parser.expression();
    if (parser.peek() != null) return error.SyntaxError; // trailing input the grammar did not consume
    return value;
}

/// A recursive-descent parser. The grammar, tightest binding last:
///   expression = term (('+' | '-') term)*
///   term       = unary (('*' | '/') unary)*
///   unary      = ('+' | '-') unary | power
///   power      = postfix ('^' unary)?        // right-associative; the exponent may carry its own sign
///   postfix    = primary ('%')*              // a percentage is a postfix divide-by-100
///   primary    = '(' expression ')' | name ['(' expression ')'] | number
/// A `name` with a following '(' is a function call; a bare name is a constant.
const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    angle: Angle,

    fn skipSpaces(parser: *Parser) void {
        while (parser.pos < parser.src.len and (parser.src[parser.pos] == ' ' or parser.src[parser.pos] == '\t')) {
            parser.pos += 1;
        }
    }

    /// The next non-space byte without consuming it, or null at the end.
    fn peek(parser: *Parser) ?u8 {
        parser.skipSpaces();
        if (parser.pos >= parser.src.len) return null;
        return parser.src[parser.pos];
    }

    /// Consumes the next non-space byte if it is `wanted`.
    fn eat(parser: *Parser, wanted: u8) bool {
        if (parser.peek() == wanted) {
            parser.pos += 1;
            return true;
        }
        return false;
    }

    fn expression(parser: *Parser) Error!f64 {
        var value = try parser.term();
        while (parser.peek()) |c| {
            if (c == '+') {
                _ = parser.eat('+');
                value += try parser.term();
            } else if (c == '-') {
                _ = parser.eat('-');
                value -= try parser.term();
            } else break;
        }
        return value;
    }

    fn term(parser: *Parser) Error!f64 {
        var value = try parser.unary();
        while (parser.peek()) |c| {
            if (c == '*') {
                _ = parser.eat('*');
                value *= try parser.unary();
            } else if (c == '/') {
                _ = parser.eat('/');
                const divisor = try parser.unary();
                if (divisor == 0) return error.DivideByZero;
                value /= divisor;
            } else break;
        }
        return value;
    }

    fn unary(parser: *Parser) Error!f64 {
        const c = parser.peek() orelse return error.SyntaxError;
        if (c == '+') {
            _ = parser.eat('+');
            return parser.unary();
        }
        if (c == '-') {
            _ = parser.eat('-');
            return -(try parser.unary());
        }
        return parser.power();
    }

    fn power(parser: *Parser) Error!f64 {
        const base = try parser.postfix();
        if (parser.peek() == '^') {
            _ = parser.eat('^');
            // Right-associative, and the exponent may carry a sign: `2^-1` and `2^3^2` both parse as
            // a person reads them.
            const exponent = try parser.unary();
            const result = std.math.pow(f64, base, exponent);
            if (std.math.isNan(result)) return error.Domain; // e.g. a negative base to a fractional power
            return result;
        }
        return base;
    }

    fn postfix(parser: *Parser) Error!f64 {
        var value = try parser.primary();
        while (parser.peek() == '%') {
            _ = parser.eat('%');
            value /= 100; // a percentage is the number over a hundred
        }
        return value;
    }

    fn primary(parser: *Parser) Error!f64 {
        const c = parser.peek() orelse return error.SyntaxError;
        if (c == '(') {
            _ = parser.eat('(');
            const value = try parser.expression();
            if (!parser.eat(')')) return error.SyntaxError; // unbalanced parenthesis
            return value;
        }
        if (std.ascii.isAlphabetic(c)) return parser.name();
        return parser.number();
    }

    /// A run of letters: a function applied to a parenthesised argument, or a bare constant.
    fn name(parser: *Parser) Error!f64 {
        parser.skipSpaces();
        const start = parser.pos;
        while (parser.pos < parser.src.len and std.ascii.isAlphabetic(parser.src[parser.pos])) {
            parser.pos += 1;
        }
        const ident = parser.src[start..parser.pos];
        if (parser.peek() == '(') {
            _ = parser.eat('(');
            const arg = try parser.expression();
            if (!parser.eat(')')) return error.SyntaxError;
            return applyFunction(ident, arg, parser.angle);
        }
        return constant(ident);
    }

    fn number(parser: *Parser) Error!f64 {
        parser.skipSpaces();
        const start = parser.pos;
        while (parser.pos < parser.src.len and (std.ascii.isDigit(parser.src[parser.pos]) or parser.src[parser.pos] == '.')) {
            parser.pos += 1;
        }
        if (parser.pos == start) return error.SyntaxError; // expected a number, found something else
        return std.fmt.parseFloat(f64, parser.src[start..parser.pos]) catch error.SyntaxError;
    }
};

/// Resolves a named constant. An unknown name is refused rather than read as zero.
fn constant(ident: []const u8) Error!f64 {
    if (std.mem.eql(u8, ident, "pi")) return std.math.pi;
    if (std.mem.eql(u8, ident, "e")) return std.math.e;
    return error.UnknownName;
}

/// Applies a named function to its argument, reading a trigonometric argument in `angle`. A function
/// called outside its domain — a negative square root, a non-positive logarithm, a tangent at its
/// asymptote — is refused rather than returning a silent NaN or infinity.
fn applyFunction(ident: []const u8, arg: f64, angle: Angle) Error!f64 {
    if (std.mem.eql(u8, ident, "sqrt")) return if (arg < 0) error.Domain else @sqrt(arg);
    if (std.mem.eql(u8, ident, "abs")) return @abs(arg);
    if (std.mem.eql(u8, ident, "exp")) return @exp(arg);
    if (std.mem.eql(u8, ident, "ln")) return if (arg <= 0) error.Domain else @log(arg);
    if (std.mem.eql(u8, ident, "log")) return if (arg <= 0) error.Domain else @log10(arg);
    if (std.mem.eql(u8, ident, "sin")) return @sin(radiansOf(arg, angle));
    if (std.mem.eql(u8, ident, "cos")) return @cos(radiansOf(arg, angle));
    if (std.mem.eql(u8, ident, "tan")) {
        // Tangent as sine over cosine, so its asymptote is a refused domain error rather than a
        // meaningless huge number. The cosine never lands exactly on zero in floating point at an
        // odd multiple of a right angle, so refuse once it is within a hair of the asymptote.
        const asymptote_cos = 1e-12;
        const r = radiansOf(arg, angle);
        const c = @cos(r);
        if (@abs(c) < asymptote_cos) return error.Domain;
        return @sin(r) / c;
    }
    return error.UnknownName;
}

/// The argument in radians: converted from degrees when the angle mode calls for it, so the trig
/// functions always compute in the radians they are defined over.
fn radiansOf(arg: f64, angle: Angle) f64 {
    return switch (angle) {
        .radians => arg,
        .degrees => arg * std.math.pi / 180.0,
    };
}

// --- Tests ---

const testing = std.testing;

test "multiplication binds tighter than addition" {
    try testing.expectEqual(@as(f64, 14), try evaluate("2+3*4"));
    try testing.expectEqual(@as(f64, 20), try evaluate("(2+3)*4"));
}

test "subtraction, division, and decimals evaluate left to right within a precedence" {
    try testing.expectEqual(@as(f64, 4), try evaluate("10/2-1"));
    try testing.expectEqual(@as(f64, 7), try evaluate("3.5*2"));
    try testing.expectEqual(@as(f64, 1), try evaluate("10 - 3 - 3 - 3"));
}

test "a unary sign is honoured, including inside parentheses" {
    try testing.expectEqual(@as(f64, 2), try evaluate("-3 + 5"));
    try testing.expectEqual(@as(f64, -8), try evaluate("-(3 + 5)"));
    try testing.expectEqual(@as(f64, 6), try evaluate("2 * -(-3)"));
}

test "a division by zero is refused, not trapped" {
    try testing.expectError(error.DivideByZero, evaluate("1/0"));
    try testing.expectError(error.DivideByZero, evaluate("5/(3-3)"));
}

test "a malformed expression is a syntax error" {
    try testing.expectError(error.SyntaxError, evaluate("2+"));
    try testing.expectError(error.SyntaxError, evaluate("2 3"));
    try testing.expectError(error.SyntaxError, evaluate("(2+3"));
    try testing.expectError(error.SyntaxError, evaluate(""));
    try testing.expectError(error.SyntaxError, evaluate("+"));
}

test "power binds tighter than multiply, is right-associative, and takes a signed exponent" {
    try testing.expectEqual(@as(f64, 18), try evaluate("2*3^2")); // 2 * (3^2)
    try testing.expectEqual(@as(f64, 512), try evaluate("2^3^2")); // 2^(3^2), not (2^3)^2 = 64
    try testing.expectEqual(@as(f64, 0.5), try evaluate("2^-1"));
    try testing.expectEqual(@as(f64, -9), try evaluate("-3^2")); // -(3^2), the usual reading
}

test "a percentage is a postfix divide-by-100" {
    try testing.expectEqual(@as(f64, 0.5), try evaluate("50%"));
    try testing.expectEqual(@as(f64, 6), try evaluate("200%*3"));
    try testing.expectEqual(@as(f64, 150), try evaluate("100+50%*100")); // 100 + (0.5 * 100)
}

test "functions and constants evaluate" {
    try testing.expectEqual(@as(f64, 3), try evaluate("sqrt(9)"));
    try testing.expectEqual(@as(f64, 5), try evaluate("abs(-5)"));
    try testing.expectEqual(@as(f64, 2), try evaluate("log(100)"));
    try testing.expectEqual(@as(f64, 1), try evaluate("ln(e)"));
    try testing.expect(@abs((try evaluate("pi")) - std.math.pi) < 1e-12);
    // Composition: functions nest and mix with the operators.
    try testing.expectEqual(@as(f64, 7), try evaluate("sqrt(9)+abs(-4)"));
}

test "trigonometry reads its argument in the chosen angle mode" {
    // 90 degrees is a right angle: its sine is 1, its cosine 0.
    try testing.expect(@abs((try evaluateIn("sin(90)", .degrees)) - 1) < 1e-9);
    try testing.expect(@abs(try evaluateIn("cos(90)", .degrees)) < 1e-9);
    // The same literal in radians is a different, correct answer — not 1.
    try testing.expect(@abs((try evaluateIn("sin(90)", .radians)) - 1) > 0.1);
    // pi radians is a straight angle: its sine is ~0.
    try testing.expect(@abs(try evaluateIn("sin(pi)", .radians)) < 1e-9);
}

test "a function outside its domain or an unknown name is refused, not a silent NaN" {
    try testing.expectError(error.Domain, evaluate("sqrt(-1)"));
    try testing.expectError(error.Domain, evaluate("ln(0)"));
    try testing.expectError(error.Domain, evaluate("log(-5)"));
    try testing.expectError(error.Domain, evaluateIn("tan(90)", .degrees)); // the asymptote
    try testing.expectError(error.Domain, evaluate("(-2)^0.5")); // a negative base to a fractional power
    try testing.expectError(error.UnknownName, evaluate("frobnicate(2)"));
    try testing.expectError(error.UnknownName, evaluate("x"));
}
