//! Kernel policy.
//!
//! This tree is policy, not mechanism. It holds no threads, maps no memory, and
//! touches no device. It decides — what should run next, which allocator domain
//! work belongs to, which principal may reach which device, and where the
//! system must stop to check authority — and it decides as pure functions, so a
//! decision is testable without an operating system beneath it.
//!
//! Mechanism lives below, in adapters that carry these decisions out. Keeping
//! the two apart is what lets the rules that matter be verified in isolation
//! from the platform they eventually run on.

pub const scheduler_policy = @import("scheduler-policy/scheduler_policy.zig");
pub const memory_policy = @import("memory-policy/memory_policy.zig");

test {
    _ = scheduler_policy;
    _ = memory_policy;
}
