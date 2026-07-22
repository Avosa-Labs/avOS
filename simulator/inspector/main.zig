//! Command-line inspector for a simulated run.
//!
//! Runs a scenario and renders what happened: the task graph, the authority
//! each principal held, and the activity ledger. The rendering is derived
//! entirely from recorded state, so what it shows is what the system can
//! actually account for rather than a narration written alongside it.
//!
//! Exit codes: 0 the run met its acceptance criteria, 1 it did not, 2 usage
//! error.

const std = @import("std");
const boot = @import("boot");
const compat = @import("compat");
const io_adapters = compat.io;
const core = @import("core");
const simulator = @import("simulator");

const canonical = simulator.canonical;
const boot_scenario = simulator.boot_scenario;
const rollback_scenario = simulator.rollback_scenario;
const Host = simulator.host.Host;

const Options = struct {
    scenario: Scenario = .canonical_demo,
    seed: u64 = 20260722,
    format: Format = .text,
    show_ledger: bool = true,
    /// Which fault the boot scenario injects.
    fault: boot_scenario.Fault = .none,
    /// What the device has to fall back on when a boot stops.
    available: boot_scenario.Available = .{},
    /// What the new image does, for the rollback scenario.
    outcome: rollback_scenario.Outcome = .hangs_on_start,

    const Scenario = enum { canonical_demo, boot, rollback };
    const Format = enum { text, json };
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buffer: [64 * 1024]u8 = undefined;
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

    if (options.scenario == .boot) {
        const report = try boot_scenario.run(options.fault, options.available);
        switch (options.format) {
            .text => try renderBootText(out, report),
            .json => try renderBootJson(out, report),
        }
        try out.flush();
        // A device that stopped on a tampered stage did the right thing, so
        // the exit code reports whether the device behaved correctly rather
        // than whether it booted. Exiting non-zero on a demonstrated refusal
        // would call the correct outcome a failure.
        return if (bootBehavedCorrectly(report)) 0 else 1;
    }

    if (options.scenario == .rollback) {
        const report = try rollback_scenario.run(options.outcome);
        switch (options.format) {
            .text => try renderRollbackText(out, report),
            .json => try renderRollbackJson(out, report),
        }
        try out.flush();
        // The device must be bootable at every step, whatever the outcome. That
        // is the property, not whether the update committed.
        return if (report.never_unbootable) 0 else 1;
    }

    var host: Host = undefined;
    Host.init(&host, gpa, .{ .seed = options.seed });
    defer host.deinit();

    const report = try canonical.run(&host);

    switch (options.format) {
        .text => try renderText(out, &host, report, options.show_ledger),
        .json => try renderJson(out, &host, report),
    }
    try out.flush();

    return if (meetsAcceptance(report)) 0 else 1;
}

/// The criteria a run must satisfy to be considered a passing demonstration.
///
/// Checked here rather than assumed, so running the inspector is itself a test
/// of the properties the system claims.
fn meetsAcceptance(report: canonical.Report) bool {
    if (report.denials < 1) return false;
    if (report.approvals_requested < 1) return false;
    if (report.approved_executions != 1) return false;
    if (report.replay_refusals < 1) return false;
    if (report.tasks_cancelled < 1) return false;
    if (report.unfinished_tasks != 0) return false;
    if (report.residual_bytes != report.baseline_bytes) return false;
    return true;
}

fn renderText(
    out: *std.Io.Writer,
    host: *Host,
    report: canonical.Report,
    show_ledger: bool,
) !void {
    try out.writeAll("principals\n");
    for (host.agents.items) |agent| {
        const record = host.registry.lookup(agent.id).?;
        var short: [8]u8 = undefined;
        try out.print("  {s}  {s}  {s}  {d} capability(ies)\n", .{
            agent.id.shortForm(&short),
            @tagName(record.kind),
            agent.name,
            agent.handles.items.len,
        });
    }

    try out.writeAll("\ntask graph\n");
    for (host.graph.roots.items) |root| {
        try renderTask(out, host, root, 1);
    }

    if (show_ledger) {
        try out.writeAll("\nactivity ledger\n");
        for (0..host.ledger.count()) |index| {
            const event = host.ledger.at(index).?;
            var actor_short: [8]u8 = undefined;
            try out.print("  {d:0>3}  {s}  {s: <22}  {s: <18}", .{
                event.sequence,
                event.actor.shortForm(&actor_short),
                @tagName(event.action),
                @tagName(event.outcome),
            });
            if (event.refusal) |refusal| {
                try out.print("  refused: {s}", .{core.outcome.describe(refusal)});
            }
            if (event.data_movement == .left_device) {
                try out.writeAll("  [left device]");
            }
            try out.writeByte('\n');
        }
    }

    try out.writeAll("\nacceptance\n");
    try writeCriterion(out, "unauthorized operation denied", report.denials >= 1);
    try writeCriterion(out, "consequential action held for approval", report.approvals_requested >= 1);
    try writeCriterion(out, "approved action executed exactly once", report.approved_executions == 1);
    try writeCriterion(out, "replay of the approval refused", report.replay_refusals >= 1);
    try writeCriterion(out, "root cancellation ended descendants", report.tasks_cancelled >= 1);
    try writeCriterion(out, "no unfinished tasks remain", report.unfinished_tasks == 0);
    try writeCriterion(
        out,
        "memory returned to baseline",
        report.residual_bytes == report.baseline_bytes,
    );
    try writeCriterion(out, "ledger sequence unbroken", host.ledger.verifySequence());

    try out.print("\npeak agent memory: {d} bytes; baseline: {d}; residual: {d}\n", .{
        report.peak_bytes,
        report.baseline_bytes,
        report.residual_bytes,
    });

    if (meetsAcceptance(report)) {
        try out.writeAll("\nsimulator: the run met every acceptance criterion\n");
    } else {
        try out.writeAll("\nsimulator: the run did not meet its acceptance criteria\n");
    }
}

/// Renders an update the way an owner lives through it: what the device would
/// boot at each step, and where it ends up.
fn renderRollbackText(out: *std.Io.Writer, report: rollback_scenario.Report) !void {
    try out.print("update ({s})\n\n", .{@tagName(report.outcome)});

    try out.writeAll("steps\n");
    for (report.steps[0..report.taken]) |step| {
        try out.print("  {s: <34}  would boot {s: <10}  {s}\n", .{
            step.label,
            @tagName(step.boot_slot),
            if (step.bootable) "bootable" else "UNBOOTABLE",
        });
    }

    if (report.refused) |reason| {
        try out.print("\ninstall refused: {s}\n", .{reason});
    }

    try out.print("\nrunning version {d}.{d}  ({s})\n", .{
        report.running_major,
        report.running_minor,
        if (report.committed) "update kept" else "update not kept",
    });
    try out.print("the device was bootable at every step: {s}\n", .{
        if (report.never_unbootable) "yes" else "NO",
    });
}

fn renderRollbackJson(out: *std.Io.Writer, report: rollback_scenario.Report) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("outcome");
    try stringify.write(@tagName(report.outcome));
    try stringify.objectField("committed");
    try stringify.write(report.committed);
    try stringify.objectField("never_unbootable");
    try stringify.write(report.never_unbootable);
    try stringify.objectField("running_version");
    var version_buffer: [32]u8 = undefined;
    try stringify.write(try std.fmt.bufPrint(&version_buffer, "{d}.{d}", .{
        report.running_major,
        report.running_minor,
    }));
    if (report.refused) |reason| {
        try stringify.objectField("refused");
        try stringify.write(reason);
    }
    try stringify.objectField("steps");
    try stringify.beginArray();
    for (report.steps[0..report.taken]) |step| {
        try stringify.beginObject();
        try stringify.objectField("label");
        try stringify.write(step.label);
        try stringify.objectField("boot_slot");
        try stringify.write(@tagName(step.boot_slot));
        try stringify.objectField("bootable");
        try stringify.write(step.bootable);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    try out.writeByte('\n');
}

/// Whether the device did what it must, whatever the fault was.
///
/// Booting with no fault, and refusing with one, are both correct. What is not
/// correct is booting past a fault, or stopping with nothing to show.
fn bootBehavedCorrectly(report: boot_scenario.Report) bool {
    if (report.fault == .none) return report.completed and report.recovery == null;
    if (report.completed) return false;
    if (report.recovery == null) return false;
    return report.screen.lines().len > 0;
}

/// Renders a boot the way a person would experience it: what each stage did,
/// then the screen the device would actually show.
fn renderBootText(out: *std.Io.Writer, report: boot_scenario.Report) !void {
    try out.print("boot ({s})\n\n", .{@tagName(report.fault)});

    try out.writeAll("stages\n");
    for (report.steps[0..report.taken]) |step| {
        try out.print("  {s: <14}  version {d: <3}  ", .{ @tagName(step.stage), step.version });
        if (step.digest) |digest| {
            try out.print("measured {x}\n", .{digest[0..8]});
        } else {
            try out.print("REFUSED  {s}\n", .{step.refusal.?});
        }
    }

    try out.print("\nattested summary  {x}\n", .{report.summary[0..16]});
    if (report.code().len > 0) {
        try out.print("support code      {s}\n", .{report.code()});
    }

    if (report.recovery) |outcome| {
        try out.print("\nthe device did not boot; it will {s}\n", .{@tagName(outcome)});
        try out.writeAll("\nwhat the screen shows\n\n");
        try writeScreen(out, report.screen);
    } else {
        try out.writeAll("\nthe device booted; the shell takes over from here\n");
    }
}

/// Draws the surface inside a frame the width of the panel it was laid out for,
/// so what a person sees on a device is what is printed here.
fn writeScreen(out: *std.Io.Writer, screen: boot.early_ui.Surface) !void {
    try out.writeAll("    +");
    for (0..boot.early_ui.columns) |_| try out.writeByte('-');
    try out.writeAll("+\n");
    for (screen.lines()) |line| {
        try out.print("    |{s}|\n", .{line});
    }
    try out.writeAll("    +");
    for (0..boot.early_ui.columns) |_| try out.writeByte('-');
    try out.writeAll("+\n");
}

fn renderBootJson(out: *std.Io.Writer, report: boot_scenario.Report) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("fault");
    try stringify.write(@tagName(report.fault));
    try stringify.objectField("completed");
    try stringify.write(report.completed);
    try stringify.objectField("stages");
    try stringify.beginArray();
    for (report.steps[0..report.taken]) |step| {
        try stringify.beginObject();
        try stringify.objectField("stage");
        try stringify.write(@tagName(step.stage));
        try stringify.objectField("version");
        try stringify.write(step.version);
        try stringify.objectField("measured");
        try stringify.write(step.digest != null);
        if (step.refusal) |refusal| {
            try stringify.objectField("refused");
            try stringify.write(refusal);
        }
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("recovery");
    if (report.recovery) |outcome| {
        try stringify.write(@tagName(outcome));
    } else {
        try stringify.write(null);
    }
    try stringify.endObject();
    try out.writeByte('\n');
}

fn renderTask(out: *std.Io.Writer, host: *Host, id: core.identity.TaskId, depth: usize) !void {
    const task = host.graph.get(id) orelse return;
    for (0..depth) |_| try out.writeAll("  ");
    var short: [8]u8 = undefined;
    try out.print("{s}  {s: <12}  {s}\n", .{
        id.shortForm(&short),
        @tagName(task.state),
        task.purpose,
    });
    for (task.children.items) |child| {
        try renderTask(out, host, child, depth + 1);
    }
}

fn writeCriterion(out: *std.Io.Writer, name: []const u8, satisfied: bool) !void {
    try out.print("  {s}  {s}\n", .{ if (satisfied) "ok  " else "FAIL", name });
}

fn renderJson(out: *std.Io.Writer, host: *Host, report: canonical.Report) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try stringify.beginObject();
    try stringify.objectField("accepted");
    try stringify.write(meetsAcceptance(report));
    try stringify.objectField("denials");
    try stringify.write(report.denials);
    try stringify.objectField("approvals_requested");
    try stringify.write(report.approvals_requested);
    try stringify.objectField("approved_executions");
    try stringify.write(report.approved_executions);
    try stringify.objectField("replay_refusals");
    try stringify.write(report.replay_refusals);
    try stringify.objectField("tasks_cancelled");
    try stringify.write(report.tasks_cancelled);
    try stringify.objectField("unfinished_tasks");
    try stringify.write(report.unfinished_tasks);
    try stringify.objectField("baseline_bytes");
    try stringify.write(report.baseline_bytes);
    try stringify.objectField("peak_bytes");
    try stringify.write(report.peak_bytes);
    try stringify.objectField("residual_bytes");
    try stringify.write(report.residual_bytes);
    try stringify.objectField("ledger_events");
    try stringify.write(report.ledger_events);
    try stringify.objectField("ledger_sequence_intact");
    try stringify.write(host.ledger.verifySequence());
    try stringify.objectField("data_left_device");
    try stringify.write(report.data_left_device);
    try stringify.endObject();
    try out.writeByte('\n');
}

fn parseArguments(
    args: []const [:0]const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            try writeUsage(out);
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, argument, "--scenario=")) {
            const value = argument["--scenario=".len..];
            options.scenario = parseScenario(value) orelse {
                try err.print("simulator: unknown scenario '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--seed=")) {
            options.seed = std.fmt.parseInt(u64, argument["--seed=".len..], 10) catch {
                try err.writeAll("simulator: seed must be a number\n");
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--format=")) {
            const value = argument["--format=".len..];
            options.format = std.meta.stringToEnum(Options.Format, value) orelse {
                try err.print("simulator: unknown format '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--fault=")) {
            const value = argument["--fault=".len..];
            options.fault = parseFault(value) orelse {
                try err.print("simulator: unknown fault '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else if (std.mem.startsWith(u8, argument, "--outcome=")) {
            const value = argument["--outcome=".len..];
            options.outcome = parseOutcome(value) orelse {
                try err.print("simulator: unknown outcome '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, argument, "--no-recovery-image")) {
            options.available.recovery_image_verified = false;
        } else if (std.mem.eql(u8, argument, "--no-previous-slot")) {
            options.available.previous_slot_bootable = false;
        } else if (std.mem.eql(u8, argument, "--no-ledger")) {
            options.show_ledger = false;
        } else {
            try err.print("simulator: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

/// Accepts the scenario name in the form the build step passes it.
fn parseScenario(value: []const u8) ?Options.Scenario {
    if (std.mem.eql(u8, value, "canonical-demo")) return .canonical_demo;
    return std.meta.stringToEnum(Options.Scenario, value);
}

/// Accepts an outcome name with either hyphens or underscores.
fn parseOutcome(value: []const u8) ?rollback_scenario.Outcome {
    var normalized: [32]u8 = undefined;
    if (value.len > normalized.len) return null;
    for (value, 0..) |character, index| {
        normalized[index] = if (character == '-') '_' else character;
    }
    return std.meta.stringToEnum(rollback_scenario.Outcome, normalized[0..value.len]);
}

/// Accepts a fault name with either hyphens or underscores, because a person
/// typing it should not have to remember which the source used.
fn parseFault(value: []const u8) ?boot_scenario.Fault {
    var normalized: [32]u8 = undefined;
    if (value.len > normalized.len) return null;
    for (value, 0..) |character, index| {
        normalized[index] = if (character == '-') '_' else character;
    }
    return std.meta.stringToEnum(boot_scenario.Fault, normalized[0..value.len]);
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: simulator [options]
        \\
        \\Runs a scenario against the control plane and reports what the system
        \\can account for: principals, task graph, activity ledger, and whether
        \\the run met its acceptance criteria.
        \\
        \\Options:
        \\  --scenario=<name>  canonical-demo, boot, or rollback
        \\                     (default: canonical-demo)
        \\
        \\Boot scenario options:
        \\  --fault=<name>       none, tampered-bootloader, tampered-control-plane,
        \\                       or downgraded-kernel (default: none)
        \\  --no-recovery-image  the recovery image does not verify
        \\  --no-previous-slot   there is no slot to fall back to
        \\
        \\Rollback scenario options:
        \\  --outcome=<name>     boots-cleanly, hangs-on-start,
        \\                       is-a-downgrade, or is-corrupt
        \\                       (default: hangs-on-start)
        \\
        \\  --seed=<number>    Identifier seed; the same seed replays exactly
        \\  --format=text|json Output format (default: text)
        \\  --no-ledger        Omit the ledger from text output
        \\  -h, --help         Show this message
        \\
        \\Exit codes:
        \\  0  the run met every acceptance criterion
        \\  1  the run did not
        \\  2  usage error
        \\
    );
}

test "the scenario name accepted on the command line resolves" {
    try std.testing.expectEqual(Options.Scenario.canonical_demo, parseScenario("canonical-demo").?);
    try std.testing.expectEqual(Options.Scenario.canonical_demo, parseScenario("canonical_demo").?);
    try std.testing.expectEqual(@as(?Options.Scenario, null), parseScenario("unknown"));
}

test "acceptance requires every criterion, not a majority" {
    const passing: canonical.Report = .{
        .root_task = .{ .value = 1 },
        .baseline_bytes = 0,
        .peak_bytes = 4096,
        .residual_bytes = 0,
        .denials = 1,
        .approvals_requested = 1,
        .approved_executions = 1,
        .replay_refusals = 2,
        .tasks_cancelled = 3,
        .unfinished_tasks = 0,
        .ledger_events = 20,
        .data_left_device = true,
    };
    try std.testing.expect(meetsAcceptance(passing));

    // Each criterion alone is sufficient to fail the run.
    var no_denial = passing;
    no_denial.denials = 0;
    try std.testing.expect(!meetsAcceptance(no_denial));

    var executed_twice = passing;
    executed_twice.approved_executions = 2;
    try std.testing.expect(!meetsAcceptance(executed_twice));

    var leaked = passing;
    leaked.residual_bytes = 4096;
    try std.testing.expect(!meetsAcceptance(leaked));

    var still_running = passing;
    still_running.unfinished_tasks = 1;
    try std.testing.expect(!meetsAcceptance(still_running));
}

test "a fault name is accepted with hyphens or underscores" {
    try std.testing.expectEqual(
        boot_scenario.Fault.tampered_bootloader,
        parseFault("tampered-bootloader").?,
    );
    try std.testing.expectEqual(
        boot_scenario.Fault.tampered_bootloader,
        parseFault("tampered_bootloader").?,
    );
    try std.testing.expectEqual(@as(?boot_scenario.Fault, null), parseFault("nonsense"));
    // A name longer than any fault must be refused rather than truncated into
    // one that happens to match.
    try std.testing.expectEqual(@as(?boot_scenario.Fault, null), parseFault("n" ** 64));
}

test "a refusal is a correct outcome, not a failed run" {
    // Every fault must be refused, and the absence of one must boot. Reporting
    // a demonstrated refusal as a failure would train a reader to ignore the
    // exit code.
    for (std.enums.values(boot_scenario.Fault)) |fault| {
        const report = try boot_scenario.run(fault, .{});
        try std.testing.expect(bootBehavedCorrectly(report));
    }

    // Booting past a fault is what must fail.
    var wrong = try boot_scenario.run(.tampered_bootloader, .{});
    wrong.completed = true;
    try std.testing.expect(!bootBehavedCorrectly(wrong));

    // So is stopping with nothing to show a person.
    var silent = try boot_scenario.run(.tampered_bootloader, .{});
    silent.recovery = null;
    try std.testing.expect(!bootBehavedCorrectly(silent));
}

test "the boot scenario is reachable by name" {
    try std.testing.expectEqual(Options.Scenario.boot, parseScenario("boot").?);
}

test "an outcome name is accepted with hyphens or underscores" {
    try std.testing.expectEqual(
        rollback_scenario.Outcome.hangs_on_start,
        parseOutcome("hangs-on-start").?,
    );
    try std.testing.expectEqual(
        rollback_scenario.Outcome.is_a_downgrade,
        parseOutcome("is_a_downgrade").?,
    );
    try std.testing.expectEqual(@as(?rollback_scenario.Outcome, null), parseOutcome("nonsense"));
}

test "the rollback scenario is reachable by name" {
    try std.testing.expectEqual(Options.Scenario.rollback, parseScenario("rollback").?);
}
