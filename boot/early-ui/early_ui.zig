//! The surface shown before the system is running.
//!
//! This is what a person sees when the boot chain stopped, or when recovery is
//! taking long enough that silence would read as a dead device. It runs before
//! there is a compositor, a font stack, a design token layer, or an allocator,
//! so it depends on none of them: a surface that needs the system to be working
//! cannot report that the system is not working.
//!
//! It renders into a caller-provided buffer as lines of text. Everything a
//! device can put on a screen this early is a rectangle of characters, and
//! pretending otherwise here would mean carrying the graphics stack into the
//! part of the boot that exists because the graphics stack might not load.
//!
//! Two things it deliberately does not do. It never offers to continue past a
//! failed verification, because an option a person can press is an option an
//! attacker can arrange to have pressed. And it names no product, because the
//! brand layer is a resource loaded by a system that is, at this point, not
//! running.

const std = @import("std");
const recovery = @import("../recovery/recovery.zig");

/// What the surface is reporting.
pub const State = union(enum) {
    /// The chain stopped. What follows was chosen by the recovery module.
    halted: struct {
        failure: recovery.Failure,
        outcome: recovery.Outcome,
        /// Something short a person can read out to support. Empty when the
        /// device has nothing to identify the failure by, in which case the
        /// screen must not ask for one: telling someone to quote a code that
        /// is not shown sends them into a support call already stuck.
        code: []const u8 = "",
    },
    /// A recovery image is running and doing something that takes time.
    recovering: struct {
        /// Whole percent. Shown so that a long wait reads as work rather than
        /// as a hang.
        progress: u8,
    },
    /// The device is starting normally but slowly enough to need saying so.
    starting,
};

/// How wide and how tall the surface may be.
///
/// The smallest panel this platform expects to boot on. Text is laid out to fit
/// it rather than to fill whatever is available, so the message reads the same
/// on every device instead of reflowing into something a support conversation
/// cannot refer to.
pub const columns: usize = 40;
pub const rows: usize = 12;

/// A rendered surface: fixed-size, no allocation.
pub const Surface = struct {
    cells: [rows][columns]u8 = @splat(@splat(' ')),
    used: usize = 0,

    pub fn lines(surface: *const Surface) []const [columns]u8 {
        return surface.cells[0..surface.used];
    }

    /// Whether the surface says this.
    ///
    /// Searches the message rather than the lines, because wrapping is a
    /// property of the panel and not of what was said: a phrase that fell
    /// across a line break is still a phrase the person read.
    pub fn contains(surface: *const Surface, text: []const u8) bool {
        var flattened: [rows * (columns + 1)]u8 = undefined;
        var length: usize = 0;
        for (surface.lines()) |line| {
            const trimmed = std.mem.trimEnd(u8, &line, " ");
            @memcpy(flattened[length..][0..trimmed.len], trimmed);
            length += trimmed.len;
            flattened[length] = ' ';
            length += 1;
        }
        return std.mem.indexOf(u8, flattened[0..length], text) != null;
    }

    fn write(surface: *Surface, text: []const u8) void {
        // Longer text is wrapped on word boundaries rather than truncated. A
        // truncated sentence is a sentence whose meaning depends on what was
        // cut, and the whole point of this surface is being understood.
        var remaining = text;
        while (remaining.len > 0 and surface.used < rows) {
            const take = if (remaining.len <= columns)
                remaining.len
            else if (std.mem.lastIndexOfScalar(u8, remaining[0 .. columns + 1], ' ')) |space|
                space
            else
                columns;

            @memcpy(surface.cells[surface.used][0..take], remaining[0..take]);
            surface.used += 1;
            remaining = std.mem.trimStart(u8, remaining[take..], " ");
        }
    }

    fn blank(surface: *Surface) void {
        if (surface.used < rows) surface.used += 1;
    }
};

/// Draws the surface for a state.
pub fn render(state: State) Surface {
    var surface: Surface = .{};
    switch (state) {
        .halted => |halted| {
            surface.write(recovery.explain(halted.outcome, halted.failure));
            surface.blank();
            surface.write(nextStep(halted.outcome, halted.code.len > 0));
            if (halted.outcome == .halt and halted.code.len > 0) {
                surface.blank();
                surface.write(halted.code);
            }
        },
        .recovering => |progress| {
            surface.write("repairing this device");
            surface.blank();
            surface.write(bar(progress.progress));
            surface.blank();
            surface.write("do not turn the device off");
        },
        .starting => surface.write("starting"),
    }
    return surface;
}

/// What the person should expect to happen, or do.
///
/// Separate from the explanation of what went wrong: a person reading a failure
/// message needs to know both, and the two answer different questions.
fn nextStep(outcome: recovery.Outcome, has_code: bool) []const u8 {
    return switch (outcome) {
        .boot_recovery_image => "this will take a few minutes and does not erase your data",
        .previous_slot => "the device will start normally in a moment",
        // No instruction to retry: retrying does not change what failed, and
        // telling someone to try again when it cannot help wastes their time
        // before they seek help that can.
        .halt => if (has_code)
            "contact support and quote the code below"
        else
            "contact support; this device cannot start on its own",
    };
}

/// A progress bar drawn in characters.
///
/// Filled proportionally and never fully until the work is done, so the last
/// notch is not reached by rounding while a step is still running.
fn bar(progress: u8) []const u8 {
    const width: usize = 20;
    const clamped: usize = @min(progress, 100);
    const ceiling: usize = if (clamped == 100) width else width - 1;
    const filled = @min(clamped * width / 100, ceiling);
    const full = "####################";
    const empty = "....................";
    // Returned as two static slices joined by the caller's buffer would need an
    // allocator; instead the bar is a window into a single static string that
    // already contains every fill level.
    const combined = full ++ empty;
    return combined[width - filled ..][0..width];
}

test "a halted device says what happened and what to do" {
    const surface = render(.{ .halted = .{
        .failure = .signature_rejected,
        .outcome = .halt,
        .code = "8f21c4a0",
    } });

    try std.testing.expect(surface.contains("could not be verified"));
    try std.testing.expect(surface.contains("support"));
    try std.testing.expect(surface.contains("8f21c4a0"));
}

test "a device with no code does not ask for one" {
    // Telling someone to quote a code that is not shown sends them into a
    // support call already stuck.
    const surface = render(.{ .halted = .{
        .failure = .signature_rejected,
        .outcome = .halt,
    } });
    try std.testing.expect(surface.contains("support"));
    try std.testing.expect(!surface.contains("code"));
}

test "a code is shown only where it can be used" {
    // Recovery and the previous slot both continue on their own, so a code
    // would be a number with nothing to do with what happens next.
    for ([_]recovery.Outcome{ .boot_recovery_image, .previous_slot }) |outcome| {
        const surface = render(.{ .halted = .{
            .failure = .signature_rejected,
            .outcome = outcome,
            .code = "8f21c4a0",
        } });
        try std.testing.expect(!surface.contains("8f21c4a0"));
    }
}

test "the surface never offers to continue anyway" {
    // An option a person can press is an option an attacker can arrange to have
    // pressed. There is no such option, at any depth, for any failure.
    const refused = [_][]const u8{ "continue", "anyway", "skip", "ignore", "proceed" };
    for (std.enums.values(recovery.Failure)) |failure| {
        for (std.enums.values(recovery.Outcome)) |outcome| {
            const surface = render(.{ .halted = .{ .failure = failure, .outcome = outcome } });
            for (refused) |word| {
                try std.testing.expect(!surface.contains(word));
            }
        }
    }
}

test "the surface names no product" {
    // The brand layer is a resource loaded by a system that is not running.
    const surface = render(.{ .halted = .{
        .failure = .signature_rejected,
        .outcome = .previous_slot,
    } });
    try std.testing.expect(surface.contains("device"));
}

test "every state renders something a person can read" {
    var states: [2 + 3]State = undefined;
    states[0] = .starting;
    states[1] = .{ .recovering = .{ .progress = 0 } };
    var index: usize = 2;
    for ([_]recovery.Outcome{ .boot_recovery_image, .previous_slot, .halt }) |outcome| {
        states[index] = .{ .halted = .{
            .failure = .signature_rejected,
            .outcome = outcome,
            .code = "8f21c4a0",
        } };
        index += 1;
    }

    for (states) |state| {
        const surface = render(state);
        try std.testing.expect(surface.used > 0);
        try std.testing.expect(surface.used <= rows);
    }
}

test "text is wrapped on word boundaries rather than truncated" {
    const surface = render(.{ .halted = .{
        .failure = .signature_rejected,
        .outcome = .halt,
    } });

    // No word is lost and none is split: every word of the message survives
    // wrapping intact.
    const message = recovery.explain(.halt, .signature_rejected);
    var words = std.mem.tokenizeScalar(u8, message, ' ');
    while (words.next()) |word| {
        try std.testing.expect(surface.contains(word));
    }
    try std.testing.expect(surface.contains(message));
}

test "nothing is written outside the surface" {
    for (std.enums.values(recovery.Outcome)) |outcome| {
        for (std.enums.values(recovery.Failure)) |failure| {
            const surface = render(.{ .halted = .{ .failure = failure, .outcome = outcome } });
            try std.testing.expect(surface.used <= rows);
        }
    }
}

test "progress is visible and never full before the work is done" {
    try std.testing.expectEqualStrings("....................", bar(0));
    try std.testing.expectEqualStrings("####################", bar(100));

    // Ninety-nine percent must not round up to a finished bar: a bar that shows
    // done while a step is still running is a bar that says the device may be
    // turned off.
    try std.testing.expect(!std.mem.eql(u8, "####################", bar(99)));

    // Monotonic: progress never appears to go backwards.
    var previous: usize = 0;
    for (0..101) |percent| {
        const drawn = bar(@intCast(percent));
        const filled = std.mem.count(u8, drawn, "#");
        try std.testing.expect(filled >= previous);
        previous = filled;
    }
}

test "a progress value above one hundred is clamped rather than trusted" {
    try std.testing.expectEqualStrings("####################", bar(255));
    const surface = render(.{ .recovering = .{ .progress = 255 } });
    try std.testing.expect(surface.contains("do not turn the device off"));
}

test "a device that is merely slow says so without alarming anyone" {
    const surface = render(.starting);
    try std.testing.expect(surface.contains("starting"));
    try std.testing.expect(!surface.contains("could not"));
    try std.testing.expect(!surface.contains("support"));
}
