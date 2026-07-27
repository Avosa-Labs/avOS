//! The calculator's expression domain: parse and evaluate an arithmetic expression.
//!
//! A calculator is more than one binary operation — a person types "2 + 3 * 4" and expects 14, with
//! multiplication bound tighter than addition and parentheses overriding both. This is that: a
//! small recursive-descent evaluator over `+ - * /`, unary sign, and parentheses on real numbers.
//! It is the app's whole logic, reached identically by the person's keypad and by an agent's
//! `calc.evaluate`, and it is pure — it reads nothing, touches nothing, reaches nowhere — which is
//! why the calculator is the smallest complete app. A division by zero and a malformed expression
//! are refused with an error rather than trapping, because a calculator that crashes on bad input
//! is worse than one that says it cannot.

const std = @import("std");

pub const Error = error{ DivideByZero, SyntaxError };

/// Evaluates an arithmetic expression to a number, or refuses it. Whitespace is ignored; the whole
/// input must be consumed, so trailing characters are a syntax error.
pub fn evaluate(expression: []const u8) Error!f64 {
    var parser = Parser{ .src = expression };
    const value = try parser.expression();
    if (parser.peek() != null) return error.SyntaxError; // trailing input the grammar did not consume
    return value;
}

/// A recursive-descent parser. The grammar, tightest binding last:
///   expression = term (('+' | '-') term)*
///   term       = factor (('*' | '/') factor)*
///   factor     = ('+' | '-') factor | '(' expression ')' | number
const Parser = struct {
    src: []const u8,
    pos: usize = 0,

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
        var value = try parser.factor();
        while (parser.peek()) |c| {
            if (c == '*') {
                _ = parser.eat('*');
                value *= try parser.factor();
            } else if (c == '/') {
                _ = parser.eat('/');
                const divisor = try parser.factor();
                if (divisor == 0) return error.DivideByZero;
                value /= divisor;
            } else break;
        }
        return value;
    }

    fn factor(parser: *Parser) Error!f64 {
        const c = parser.peek() orelse return error.SyntaxError;
        if (c == '+') {
            _ = parser.eat('+');
            return parser.factor();
        }
        if (c == '-') {
            _ = parser.eat('-');
            return -(try parser.factor());
        }
        if (c == '(') {
            _ = parser.eat('(');
            const value = try parser.expression();
            if (!parser.eat(')')) return error.SyntaxError; // unbalanced parenthesis
            return value;
        }
        return parser.number();
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
