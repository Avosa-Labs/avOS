//! Randomized testing of the decoders that read untrusted bytes.
//!
//! Every decoder here reads input it did not produce. The only permitted
//! outcomes are a correct value or a typed error: never a crash, never a read
//! past the input, never a hang.
//!
//! Seeds are fixed so a failure reproduces exactly. A finding nobody can
//! reproduce is a finding nobody fixes.

pub const decoders = @import("decoders.zig");

test {
    _ = decoders;
}
