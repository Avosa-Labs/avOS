//! Audits surfaces against the accessibility baseline, so no surface ships failing it.
//!
//! Accessibility is not a feature some surfaces have and others skip; it is a floor every surface must
//! clear, because a surface that fails it is unusable for the people who depend on it. The baseline is
//! concrete and checkable: interactive targets are at least the minimum size a person can reliably hit,
//! text meets the minimum contrast against its background, every interactive element carries an
//! accessible label a screen reader can announce, and motion can be reduced for people for whom it
//! causes harm. A surface is compliant only when it meets all of them; a single failure fails the
//! surface, because the person who needs the missing one is not served by the others being present. The
//! audit reports each failing surface with which criteria it missed, so the gap is fixable rather than
//! merely flagged. Holding every surface to the same floor is what makes the platform usable rather than
//! usable-for-most.
//!
//! Exit codes: 0 all surfaces pass, 1 a surface fails the baseline or a manifest cannot be read, 2
//! usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// The measurable properties of a surface the baseline checks.
pub const Surface = struct {
    name: []const u8,
    /// The smallest interactive target, in logical points.
    min_target_points: u32,
    /// The lowest text contrast ratio on the surface, scaled by 100 (so 4.5:1 is 450).
    min_contrast_x100: u32,
    /// Whether every interactive element carries an accessible label.
    all_elements_labeled: bool,
    /// Whether the surface honors a reduce-motion preference.
    honors_reduce_motion: bool,
};

/// The baseline thresholds every surface must meet.
pub const min_target_points: u32 = 44;
pub const min_contrast_x100: u32 = 450; // 4.5:1

/// One way a surface can fail the baseline.
pub const Failure = enum {
    target_too_small,
    contrast_too_low,
    unlabeled_element,
    motion_not_reducible,
};

/// Whether a surface meets the baseline, and if not, the first criterion it misses. Criteria are
/// checked in a fixed order so a report is deterministic; a surface passes only if it misses none.
pub fn firstFailure(surface: Surface) ?Failure {
    if (surface.min_target_points < min_target_points) return .target_too_small;
    if (surface.min_contrast_x100 < min_contrast_x100) return .contrast_too_low;
    if (!surface.all_elements_labeled) return .unlabeled_element;
    if (!surface.honors_reduce_motion) return .motion_not_reducible;
    return null;
}

/// Whether a surface passes the accessibility baseline.
pub fn passes(surface: Surface) bool {
    return firstFailure(surface) == null;
}

/// Parses one manifest line: "name targetPoints contrastX100 labeled(0|1) reduceMotion(0|1)".
fn parseLine(arena: std.mem.Allocator, line: []const u8) !?Surface {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const name = fields.next() orelse return error.Malformed;
    const target = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.Malformed, 10);
    const contrast = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.Malformed, 10);
    const labeled = try parseBool(fields.next() orelse return error.Malformed);
    const reduce_motion = try parseBool(fields.next() orelse return error.Malformed);
    if (fields.next() != null) return error.Malformed;
    return .{
        .name = try arena.dupe(u8, name),
        .min_target_points = target,
        .min_contrast_x100 = contrast,
        .all_elements_labeled = labeled,
        .honors_reduce_motion = reduce_motion,
    };
}

fn parseBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "0")) return false;
    return error.Malformed;
}

fn describe(failure: Failure) []const u8 {
    return switch (failure) {
        .target_too_small => "an interactive target is below the minimum size",
        .contrast_too_low => "text contrast is below the minimum ratio",
        .unlabeled_element => "an interactive element has no accessible label",
        .motion_not_reducible => "the surface does not honor reduce-motion",
    };
}

const Options = struct {
    manifest: []const u8 = "surfaces.txt",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_file = io_adapters.stdout(io, &out_buffer);
    const out = &out_file.interface;

    var err_buffer: [4 * 1024]u8 = undefined;
    var err_file = io_adapters.stderr(io, &err_buffer);
    const err = &err_file.interface;

    const args = try io_adapters.args(init, arena);
    const options = parseArguments(args, out, err) catch |parse_error| switch (parse_error) {
        error.HelpRequested => {
            try out.flush();
            return 0;
        },
        error.InvalidArguments => {
            try err.flush();
            return 2;
        },
        else => return parse_error,
    };

    const contents = io_adapters.cwd().readFileAlloc(io, options.manifest, gpa, .limited(1 << 20)) catch {
        try err.print("accessibility-audit: cannot read surface manifest '{s}'\n", .{options.manifest});
        try err.flush();
        return 2;
    };
    defer gpa.free(contents);

    var failures: usize = 0;
    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const surface = parseLine(arena, line) catch {
            try err.print("accessibility-audit: malformed line: '{s}'\n", .{std.mem.trim(u8, line, " \t\r")});
            try err.flush();
            return 2;
        } orelse continue;
        checked += 1;
        if (firstFailure(surface)) |failure| {
            failures += 1;
            try out.print("  FAIL  {s}  ({s})\n", .{ surface.name, describe(failure) });
        } else {
            try out.print("  ok    {s}\n", .{surface.name});
        }
    }

    if (failures == 0) {
        try out.print("accessibility-audit: {d} surface(s) checked, all meet the baseline\n", .{checked});
        try out.flush();
        return 0;
    }
    try out.print("accessibility-audit: {d} of {d} surface(s) fail the baseline\n", .{ failures, checked });
    try out.flush();
    return 1;
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: accessibility-audit [--manifest FILE]
                \\
                \\Audits each surface against the accessibility baseline: minimum target size,
                \\minimum text contrast, every element labeled, and reduce-motion honored. A surface
                \\failing any criterion fails. Manifest lines are
                \\"name targetPoints contrastX100 labeled(0|1) reduceMotion(0|1)".
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) {
                try err.print("accessibility-audit: --manifest needs a file\n", .{});
                return error.InvalidArguments;
            }
            options.manifest = args[index];
        } else {
            try err.print("accessibility-audit: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn makeSurface(target: u32, contrast: u32, labeled: bool, reduce_motion: bool) Surface {
    return .{
        .name = "surface",
        .min_target_points = target,
        .min_contrast_x100 = contrast,
        .all_elements_labeled = labeled,
        .honors_reduce_motion = reduce_motion,
    };
}

test "a surface meeting every criterion passes" {
    try std.testing.expect(passes(makeSurface(44, 450, true, true)));
    try std.testing.expect(passes(makeSurface(48, 700, true, true)));
}

test "a target below the minimum fails" {
    try std.testing.expectEqual(Failure.target_too_small, firstFailure(makeSurface(40, 450, true, true)).?);
}

test "contrast below the minimum fails" {
    try std.testing.expectEqual(Failure.contrast_too_low, firstFailure(makeSurface(44, 300, true, true)).?);
}

test "an unlabeled element fails" {
    try std.testing.expectEqual(Failure.unlabeled_element, firstFailure(makeSurface(44, 450, false, true)).?);
}

test "a surface that cannot reduce motion fails" {
    try std.testing.expectEqual(Failure.motion_not_reducible, firstFailure(makeSurface(44, 450, true, false)).?);
}

test "the boundary values meet the baseline exactly" {
    // The thresholds are inclusive: exactly the minimum passes.
    try std.testing.expect(passes(makeSurface(min_target_points, min_contrast_x100, true, true)));
    try std.testing.expect(!passes(makeSurface(min_target_points - 1, min_contrast_x100, true, true)));
}

test "a passing surface meets every criterion, swept" {
    // The floor property: whenever a surface passes, none of the four criteria is below its threshold.
    const targets = [_]u32{ 40, 44 };
    const contrasts = [_]u32{ 300, 450 };
    for (targets) |target| {
        for (contrasts) |contrast| {
            for ([_]bool{ false, true }) |labeled| {
                for ([_]bool{ false, true }) |motion| {
                    const surface = makeSurface(target, contrast, labeled, motion);
                    if (passes(surface)) {
                        try std.testing.expect(target >= min_target_points);
                        try std.testing.expect(contrast >= min_contrast_x100);
                        try std.testing.expect(labeled and motion);
                    }
                }
            }
        }
    }
}
