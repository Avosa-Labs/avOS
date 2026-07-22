//! Measuring against stated budgets.
//!
//! Each budget comes from `docs/performance/budgets.md`, which states why it is
//! that number. Measurements report the median and the 99th percentile and are
//! checked against the tail: a median inside budget with a tail far outside it
//! is a system that feels unreliable.

pub const benchmark = @import("benchmark.zig");

test {
    _ = benchmark;
}
