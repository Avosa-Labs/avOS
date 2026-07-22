//! What a device does when it is interrupted or its storage is damaged.
//!
//! Held separately from the modules it exercises so it can only use the
//! interfaces a real caller has, and swept exhaustively rather than sampled: a
//! sampled corruption test finds the corruptions someone thought of.

pub const restart_and_corruption = @import("restart_and_corruption.zig");

test {
    _ = restart_and_corruption;
}
