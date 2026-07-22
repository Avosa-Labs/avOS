//! Resolves the toolchain to exact, verifiable pins and writes the manifest.
//!
//! "Latest stable" is a selection rule, not a dependency declaration. This tool
//! performs the selection against official release sources only, rejects every
//! prerelease, resolves an exact version, records the publisher's digests and
//! licenses, and emits a deterministic document. It fails rather than falling
//! back, so a resolution failure never silently degrades into a looser pin.
//!
//! It does not upgrade anything on its own. It produces a manifest for human
//! review; committing the result is a deliberate act.
//!
//! Exit codes: 0 success, 1 drift or resolution failure, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// Official release index. No mirror, no redirect to a package aggregator.
const release_index_url = "https://ziglang.org/download/index.json";

const manifest_path = "toolchain.lock.json";

/// SPDX identifier for the compiler distribution.
const compiler_license = "MIT";

/// A component resolved from its project's official release feed.
///
/// Each entry names the feed to query and the artifacts to pin. Adding one is a
/// deliberate act that follows an architecture decision record, not a
/// convenience for whatever a build happens to need.
const RequestedComponent = struct {
    name: []const u8,
    /// Release feed. Only an official project source is ever consulted.
    release_feed: []const u8,
    /// Artifact name pattern per target, with the resolved tag substituted for
    /// the placeholder.
    artifact_pattern: []const u8,
    targets: []const TargetArtifact,
    license: []const u8,
    /// The decision record authorizing this component.
    decision_record: []const u8,
};

const TargetArtifact = struct {
    target: []const u8,
    /// Name fragment identifying this target's artifact within the release.
    fragment: []const u8,
};

const requested_components = [_]RequestedComponent{
    .{
        .name = "wasmtime",
        .release_feed = "https://api.github.com/repos/bytecodealliance/wasmtime/releases/latest",
        .artifact_pattern = "c-api",
        .targets = &.{
            .{ .target = "aarch64-macos", .fragment = "aarch64-macos-c-api.tar.xz" },
            .{ .target = "x86_64-macos", .fragment = "x86_64-macos-c-api.tar.xz" },
            .{ .target = "aarch64-linux", .fragment = "aarch64-linux-c-api.tar.xz" },
            .{ .target = "x86_64-linux", .fragment = "x86_64-linux-c-api.tar.xz" },
            .{ .target = "x86_64-windows", .fragment = "x86_64-windows-c-api.zip" },
        },
        .license = "Apache-2.0 WITH LLVM-exception",
        .decision_record = "docs/decisions/0001-webassembly-component-runtime.md",
    },
};

const PinnedComponent = struct {
    name: []const u8,
    version: []const u8,
    license: []const u8,
    decision_record: []const u8,
    archives: []const Archive,
};

/// Development hosts the bootstrap must serve. A pin missing any of these would
/// leave a supported host unable to reproduce the build from the manifest.
const required_targets = [_][]const u8{
    "aarch64-macos",
    "x86_64-macos",
    "aarch64-linux",
    "x86_64-linux",
    "x86_64-windows",
};

const Role = enum {
    /// Development and release baseline.
    canonical,
    /// Supported window member retained for the compatibility matrix.
    compatibility,
};

const RequestedLine = struct {
    version: []const u8,
    role: Role,
};

/// The exact releases this repository pins. Changing this list is a deliberate
/// migration accompanied by the review that the version policy requires.
const requested_lines = [_]RequestedLine{
    .{ .version = "0.16.0", .role = .canonical },
    .{ .version = "0.15.2", .role = .compatibility },
    .{ .version = "0.14.1", .role = .compatibility },
};

const Archive = struct {
    target: []const u8,
    source: []const u8,
    sha256: []const u8,
    size_bytes: u64,
};

const Compiler = struct {
    version: []const u8,
    role: Role,
    source: []const u8,
    sha256: []const u8,
    archives: []const Archive,
};

const Options = struct {
    mode: Mode = .write,
    index_path: ?[]const u8 = null,

    const Mode = enum {
        /// Resolve and write the manifest for review.
        write,
        /// Resolve and compare against the committed manifest without writing.
        verify,
    };
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
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

    const index_text = if (options.index_path) |path|
        try io_adapters.readFile(io_adapters.cwd(), io, path, arena, .limited(8 * 1024 * 1024))
    else
        fetchReleaseIndex(io, arena) catch |fetch_error| {
            try err.print(
                "version-lock: unable to reach the official release index: {t}\n" ++
                    "The manifest is not modified. Resolve connectivity and retry; " ++
                    "no fallback source is consulted by design.\n",
                .{fetch_error},
            );
            try err.flush();
            return 1;
        };

    const compilers = resolveCompilers(arena, index_text, err) catch |resolve_error| {
        try err.print("version-lock: resolution failed: {t}\n", .{resolve_error});
        try err.flush();
        return 1;
    };

    // Components are resolved from their own official feeds, which the offline
    // path cannot reach; an offline run pins the compiler only.
    const components: []const PinnedComponent = if (options.index_path != null)
        &.{}
    else
        resolveComponents(io, arena, err) catch |resolve_error| {
            try err.print("version-lock: component resolution failed: {t}\n", .{resolve_error});
            try err.flush();
            return 1;
        };

    var rendered: std.Io.Writer.Allocating = .init(arena);
    defer rendered.deinit();
    try renderManifest(&rendered.writer, compilers, components, timestamp(io));

    switch (options.mode) {
        .write => {
            try io_adapters.writeFile(io_adapters.cwd(), io, manifest_path, rendered.written());
            try out.print(
                "version-lock: wrote {s} with {d} pinned compiler release(s) and {d} component(s)\n",
                .{ manifest_path, compilers.len, components.len },
            );
            try out.writeAll("Review the diff before committing; an upgrade is a migration.\n");
            try out.flush();
            return 0;
        },
        .verify => {
            const committed = io_adapters.readFile(io_adapters.cwd(), io, manifest_path, arena, .limited(8 * 1024 * 1024)) catch |read_error| {
                try err.print("version-lock: cannot read {s}: {t}\n", .{ manifest_path, read_error });
                try err.flush();
                return 1;
            };
            if (equalIgnoringTimestamp(committed, rendered.written())) {
                try out.print("version-lock: {s} matches the official release sources\n", .{manifest_path});
                try out.flush();
                return 0;
            }
            try err.print(
                "version-lock: {s} does not match the resolved pins\n" ++
                    "Run 'zig build version-lock' and review the diff.\n",
                .{manifest_path},
            );
            try err.flush();
            return 1;
        },
    }
}

fn fetchReleaseIndex(io: std.Io, arena: std.mem.Allocator) ![]u8 {
    return fetchJson(io, arena, release_index_url);
}

/// Retrieves a document from an official release source.
///
/// Only ever called with a location declared in this file, so the set of hosts
/// this tool will talk to is fixed at compile time rather than derived from
/// anything it downloads.
fn fetchJson(io: std.Io, arena: std.mem.Allocator, location: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = location },
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "platform-version-lock" },
        },
    });
    if (result.status != .ok) return error.ReleaseIndexUnavailable;
    return body.written();
}

/// Resolves each requested line against the index.
///
/// Every rejection is fatal. A missing target, a missing digest, or a
/// prerelease-looking key stops the run rather than producing a manifest that
/// is weaker than it appears.
fn resolveCompilers(
    arena: std.mem.Allocator,
    index_text: []const u8,
    err: *std.Io.Writer,
) ![]const Compiler {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, index_text, .{});
    const index = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedReleaseIndex,
    };

    var compilers: std.ArrayList(Compiler) = .empty;

    for (requested_lines) |requested| {
        if (!isStableVersion(requested.version)) {
            try err.print("version-lock: '{s}' is not a stable version\n", .{requested.version});
            return error.PrereleaseRejected;
        }

        const entry = index.get(requested.version) orelse {
            try err.print("version-lock: release {s} is absent from the official index\n", .{requested.version});
            return error.ReleaseNotPublished;
        };
        const release = switch (entry) {
            .object => |object| object,
            else => return error.MalformedReleaseIndex,
        };

        const source = try readArchive(arena, release, "src", requested.version, err);

        var archives: std.ArrayList(Archive) = .empty;
        for (required_targets) |target| {
            const archive = try readArchive(arena, release, target, requested.version, err);
            try archives.append(arena, .{
                .target = target,
                .source = archive.source,
                .sha256 = archive.sha256,
                .size_bytes = archive.size_bytes,
            });
        }

        try compilers.append(arena, .{
            .version = requested.version,
            .role = requested.role,
            .source = source.source,
            .sha256 = source.sha256,
            .archives = try archives.toOwnedSlice(arena),
        });
    }

    return compilers.toOwnedSlice(arena);
}

/// Resolves each declared component from its project's official release feed.
///
/// Applies the same rules as the compiler path: the tag must denote a stable
/// release, every artifact must carry a digest published by the project, and
/// every artifact must be served over a secure location. A component missing
/// any of these stops the run rather than being pinned weakly.
fn resolveComponents(
    io: std.Io,
    arena: std.mem.Allocator,
    err: *std.Io.Writer,
) ![]const PinnedComponent {
    var pinned: std.ArrayList(PinnedComponent) = .empty;

    for (requested_components) |requested| {
        const feed = try fetchJson(io, arena, requested.release_feed);
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, feed, .{
            .ignore_unknown_fields = true,
        });
        const release = switch (parsed.value) {
            .object => |object| object,
            else => return error.MalformedReleaseIndex,
        };

        // A project marking its own release a prerelease is decisive. A feed
        // that omits the field is refused rather than assumed stable.
        const prerelease_field = release.get("prerelease") orelse {
            try err.print("version-lock: {s} feed does not state release status\n", .{requested.name});
            return error.PrereleaseRejected;
        };
        switch (prerelease_field) {
            .bool => |is_prerelease| if (is_prerelease) {
                try err.print("version-lock: {s} latest release is a prerelease\n", .{requested.name});
                return error.PrereleaseRejected;
            },
            else => return error.MalformedReleaseIndex,
        }

        const tag = switch (release.get("tag_name") orelse return error.MalformedReleaseIndex) {
            .string => |value| value,
            else => return error.MalformedReleaseIndex,
        };
        const version = std.mem.trimStart(u8, tag, "v");
        if (!isStableVersion(version)) {
            try err.print("version-lock: {s} tag '{s}' is not a stable version\n", .{ requested.name, tag });
            return error.PrereleaseRejected;
        }

        const assets = switch (release.get("assets") orelse return error.MalformedReleaseIndex) {
            .array => |array| array,
            else => return error.MalformedReleaseIndex,
        };

        var archives: std.ArrayList(Archive) = .empty;
        for (requested.targets) |target| {
            const archive = findAsset(arena, assets.items, target.fragment) catch |failure| {
                try err.print(
                    "version-lock: {s} has no artifact for '{s}': {t}\n",
                    .{ requested.name, target.target, failure },
                );
                return failure;
            };
            try archives.append(arena, .{
                .target = target.target,
                .source = archive.source,
                .sha256 = archive.sha256,
                .size_bytes = archive.size_bytes,
            });
        }

        try pinned.append(arena, .{
            .name = requested.name,
            .version = try arena.dupe(u8, version),
            .license = requested.license,
            .decision_record = requested.decision_record,
            .archives = try archives.toOwnedSlice(arena),
        });
    }

    return pinned.toOwnedSlice(arena);
}

/// Locates one release asset by the fragment identifying its target.
fn findAsset(
    arena: std.mem.Allocator,
    assets: []const std.json.Value,
    fragment: []const u8,
) !RawArchive {
    for (assets) |entry| {
        const asset = switch (entry) {
            .object => |object| object,
            else => continue,
        };
        const name = switch (asset.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.endsWith(u8, name, fragment)) continue;

        const location = switch (asset.get("browser_download_url") orelse
            return error.MissingArtifactLocation) {
            .string => |value| value,
            else => return error.MalformedReleaseIndex,
        };
        if (!std.mem.startsWith(u8, location, "https://")) return error.InsecureArtifactLocation;

        // The project publishes the digest alongside the artifact. An artifact
        // without one cannot be pinned, however convenient it would be.
        const digest_text = switch (asset.get("digest") orelse return error.MissingIntegrityMetadata) {
            .string => |value| value,
            else => return error.MissingIntegrityMetadata,
        };
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, digest_text, prefix)) return error.MissingIntegrityMetadata;
        const digest = digest_text[prefix.len..];
        if (!isHexDigest(digest)) return error.MissingIntegrityMetadata;

        const size = switch (asset.get("size") orelse return error.MissingArtifactSize) {
            .integer => |value| std.math.cast(u64, value) orelse return error.MalformedReleaseIndex,
            .string => |value| try std.fmt.parseInt(u64, value, 10),
            else => return error.MalformedReleaseIndex,
        };

        return .{
            .source = try arena.dupe(u8, location),
            .sha256 = try arena.dupe(u8, digest),
            .size_bytes = size,
        };
    }
    return error.TargetNotPublished;
}

const RawArchive = struct {
    source: []const u8,
    sha256: []const u8,
    size_bytes: u64,
};

fn readArchive(
    arena: std.mem.Allocator,
    release: std.json.ObjectMap,
    key: []const u8,
    version: []const u8,
    err: *std.Io.Writer,
) !RawArchive {
    const entry = release.get(key) orelse {
        try err.print("version-lock: release {s} has no artifact for '{s}'\n", .{ version, key });
        return error.TargetNotPublished;
    };
    const object = switch (entry) {
        .object => |value| value,
        else => return error.MalformedReleaseIndex,
    };

    const tarball = switch (object.get("tarball") orelse return error.MissingArtifactLocation) {
        .string => |value| value,
        else => return error.MalformedReleaseIndex,
    };
    const shasum = switch (object.get("shasum") orelse {
        try err.print("version-lock: artifact {s}/{s} has no digest\n", .{ version, key });
        return error.MissingIntegrityMetadata;
    }) {
        .string => |value| value,
        else => return error.MalformedReleaseIndex,
    };
    const size = switch (object.get("size") orelse return error.MissingArtifactSize) {
        .string => |value| try std.fmt.parseInt(u64, value, 10),
        .integer => |value| std.math.cast(u64, value) orelse return error.MalformedReleaseIndex,
        else => return error.MalformedReleaseIndex,
    };

    if (!isHexDigest(shasum)) return error.MissingIntegrityMetadata;
    if (!std.mem.startsWith(u8, tarball, "https://")) return error.InsecureArtifactLocation;

    return .{
        .source = try arena.dupe(u8, tarball),
        .sha256 = try arena.dupe(u8, shasum),
        .size_bytes = size,
    };
}

/// A version is stable only when the publisher marks it a final release.
/// Anything carrying prerelease or build metadata, or a moving channel name, is
/// rejected before it can reach the manifest.
fn isStableVersion(text: []const u8) bool {
    const moving_channels = [_][]const u8{
        "master", "main",     "nightly",   "dev",    "latest",
        "alpha",  "beta",     "preview",   "canary", "milestone",
        "rc",     "snapshot", "candidate",
    };
    for (moving_channels) |channel| {
        if (std.ascii.eqlIgnoreCase(text, channel)) return false;
    }
    const version = std.SemanticVersion.parse(text) catch return false;
    return version.pre == null and version.build == null;
}

fn isHexDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

fn timestamp(io: std.Io) i64 {
    const now = std.Io.Clock.now(.real, io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
}

/// Renders the manifest with a fixed field and element order so that two runs
/// against an unchanged index produce a byte-identical document and the diff
/// shows only genuine pin changes.
fn renderManifest(
    writer: *std.Io.Writer,
    compilers: []const Compiler,
    components: []const PinnedComponent,
    generated_at: i64,
) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try stringify.beginObject();

    try stringify.objectField("generated_at");
    var time_buffer: [64]u8 = undefined;
    try stringify.write(try formatRfc3339(&time_buffer, generated_at));

    try stringify.objectField("selection_rule");
    try stringify.write("latest stable release, resolved from official sources, pinned exactly");

    const canonical = for (compilers) |compiler| {
        if (compiler.role == .canonical) break compiler;
    } else return error.NoCanonicalCompiler;

    try stringify.objectField("zig");
    try stringify.beginObject();
    try stringify.objectField("version");
    try stringify.write(canonical.version);
    try stringify.objectField("source");
    try stringify.write(canonical.source);
    try stringify.objectField("sha256");
    try stringify.write(canonical.sha256);
    try stringify.objectField("license");
    try stringify.write(compiler_license);
    try stringify.endObject();

    try stringify.objectField("compilers");
    try stringify.beginArray();
    for (compilers) |compiler| {
        try stringify.beginObject();
        try stringify.objectField("version");
        try stringify.write(compiler.version);
        try stringify.objectField("role");
        try stringify.write(@tagName(compiler.role));
        try stringify.objectField("source");
        try stringify.write(compiler.source);
        try stringify.objectField("sha256");
        try stringify.write(compiler.sha256);
        try stringify.objectField("license");
        try stringify.write(compiler_license);
        try stringify.objectField("archives");
        try stringify.beginArray();
        for (compiler.archives) |archive| {
            try stringify.beginObject();
            try stringify.objectField("target");
            try stringify.write(archive.target);
            try stringify.objectField("source");
            try stringify.write(archive.source);
            try stringify.objectField("sha256");
            try stringify.write(archive.sha256);
            try stringify.objectField("size_bytes");
            try stringify.write(archive.size_bytes);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.objectField("components");
    try stringify.beginArray();
    for (components) |component| {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write(component.name);
        try stringify.objectField("version");
        try stringify.write(component.version);
        try stringify.objectField("license");
        try stringify.write(component.license);
        try stringify.objectField("decision_record");
        try stringify.write(component.decision_record);
        try stringify.objectField("archives");
        try stringify.beginArray();
        for (component.archives) |archive| {
            try stringify.beginObject();
            try stringify.objectField("target");
            try stringify.write(archive.target);
            try stringify.objectField("source");
            try stringify.write(archive.source);
            try stringify.objectField("sha256");
            try stringify.write(archive.sha256);
            try stringify.objectField("size_bytes");
            try stringify.write(archive.size_bytes);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();

    try stringify.endObject();
    try writer.writeByte('\n');
}

fn formatRfc3339(buffer: []u8, seconds: i64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

/// Compares two manifests while ignoring the generation timestamp, so that
/// re-resolving an unchanged index does not report drift.
fn equalIgnoringTimestamp(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, stripTimestampLine(left), stripTimestampLine(right));
}

fn stripTimestampLine(text: []const u8) []const u8 {
    const marker = "\"generated_at\"";
    const start = std.mem.indexOf(u8, text, marker) orelse return text;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text[0..start];
    // The timestamp occupies one whole line; removing it leaves the remainder
    // contiguous so the comparison still covers every pinned value.
    return text[end..];
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
        } else if (std.mem.eql(u8, argument, "--verify")) {
            options.mode = .verify;
        } else if (std.mem.startsWith(u8, argument, "--index=")) {
            options.index_path = argument["--index=".len..];
        } else {
            try err.print("version-lock: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: version-lock [options]
        \\
        \\Resolves the toolchain against official release sources and writes an
        \\exactly pinned manifest for human review.
        \\
        \\Options:
        \\  --verify        Compare the committed manifest against the sources; do not write
        \\  --index=<path>  Read a previously captured release index instead of fetching
        \\  -h, --help      Show this message
        \\
        \\Exit codes:
        \\  0  manifest written, or verification matched
        \\  1  drift, unreachable source, or resolution failure
        \\  2  usage error
        \\
    );
}

test "moving channels are never stable" {
    const rejected = [_][]const u8{
        "master", "main",     "nightly",   "dev",    "latest",
        "alpha",  "beta",     "preview",   "canary", "milestone",
        "rc",     "snapshot", "candidate",
    };
    for (rejected) |text| try std.testing.expect(!isStableVersion(text));
}

test "prereleases and build metadata are never stable" {
    const rejected = [_][]const u8{
        "0.17.0-dev.1+abcdef",
        "0.16.0-rc.1",
        "0.15.2-beta",
        "0.14.1+build.5",
        "not-a-version",
        "",
    };
    for (rejected) |text| try std.testing.expect(!isStableVersion(text));
}

test "final releases are stable" {
    const accepted = [_][]const u8{ "0.14.1", "0.15.2", "0.16.0", "1.0.0" };
    for (accepted) |text| try std.testing.expect(isStableVersion(text));
}

test "a digest must be a full-length hexadecimal string" {
    try std.testing.expect(isHexDigest("d1f9b0e0c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920a3b4"));
    try std.testing.expect(!isHexDigest("tooshort"));
    try std.testing.expect(!isHexDigest("g1f9b0e0c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920a3b4"));
    try std.testing.expect(!isHexDigest(""));
}

test "verification ignores only the generation timestamp" {
    const first =
        \\{
        \\  "generated_at": "2026-01-01T00:00:00Z",
        \\  "zig": { "version": "0.16.0" }
        \\}
    ;
    const second =
        \\{
        \\  "generated_at": "2026-07-22T09:30:00Z",
        \\  "zig": { "version": "0.16.0" }
        \\}
    ;
    const changed_pin =
        \\{
        \\  "generated_at": "2026-07-22T09:30:00Z",
        \\  "zig": { "version": "0.15.2" }
        \\}
    ;
    try std.testing.expect(equalIgnoringTimestamp(first, second));
    try std.testing.expect(!equalIgnoringTimestamp(first, changed_pin));
}

test "the requested lines contain exactly one canonical release" {
    var canonical_count: usize = 0;
    for (requested_lines) |requested| {
        try std.testing.expect(isStableVersion(requested.version));
        if (requested.role == .canonical) canonical_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), canonical_count);
}

test "an artifact without a digest is rejected" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const index_text =
        \\{"0.16.0":{"src":{"tarball":"https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz","size":"1"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, index_text, .{});
    const release = parsed.value.object.get("0.16.0").?.object;

    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(
        error.MissingIntegrityMetadata,
        readArchive(arena, release, "src", "0.16.0", &discard.writer),
    );
}

test "an artifact served over an insecure location is rejected" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const index_text =
        \\{"0.16.0":{"src":{"tarball":"http://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz","size":"1","shasum":"d1f9b0e0c1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081920a3b4"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, index_text, .{});
    const release = parsed.value.object.get("0.16.0").?.object;

    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(
        error.InsecureArtifactLocation,
        readArchive(arena, release, "src", "0.16.0", &discard.writer),
    );
}
