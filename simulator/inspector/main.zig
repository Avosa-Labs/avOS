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
const compat = @import("compat");
const io_adapters = compat.io;
const core = @import("core");
const simulator = @import("simulator");

const canonical = simulator.canonical;
const Host = simulator.host.Host;

const Options = struct {
    scenario: Scenario = .canonical_demo,
    seed: u64 = 20260722,
    format: Format = .text,
    show_ledger: bool = true,

    const Scenario = enum { canonical_demo };
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

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: simulator [options]
        \\
        \\Runs a scenario against the control plane and reports what the system
        \\can account for: principals, task graph, activity ledger, and whether
        \\the run met its acceptance criteria.
        \\
        \\Options:
        \\  --scenario=<name>  Scenario to run (default: canonical-demo)
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
