//! Decides whether a signed application package may be distributed through the store.
//!
//! A package a person installs must be the one a known developer built and the store reviewed —
//! nothing else. Two signatures establish that. The developer signs the package digest, which ties the
//! bytes to a registered developer identity; the store countersigns after review, which attests the
//! package passed the gate. A package is distributable only when both signatures are present and
//! verify over the same digest, and the developer is currently registered. Either signature missing or
//! failing, or a developer whose registration has lapsed, refuses distribution — a developer-signed but
//! un-countersigned package never went through review, and a countersignature over a different digest
//! than the developer signed is a mismatch that must not ship. This is the same floor the store applies
//! internally, exposed as a tool a developer runs before submitting, so the answer to "will this be
//! distributable" is known at build time rather than discovered at upload.
//!
//! Exit codes: 0 distributable, 1 refused, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;

/// A signed package presented for distribution.
pub const Package = struct {
    /// Whether the developer's signature over the package digest verifies.
    developer_signature_valid: bool,
    /// Whether the developer who signed is currently registered.
    developer_registered: bool,
    /// Whether the store's countersignature verifies.
    store_countersignature_valid: bool,
    /// Whether the countersignature covers the same digest the developer signed.
    countersignature_matches_digest: bool,
};

/// Why distribution was refused.
pub const Refusal = enum {
    /// The developer's signature does not verify.
    developer_signature_invalid,
    /// The signing developer is not currently registered.
    developer_not_registered,
    /// The store countersignature is missing or does not verify — the package did not pass review.
    not_countersigned,
    /// The countersignature covers a different digest than the developer signed.
    digest_mismatch,
};

/// The distribution decision.
pub const Decision = union(enum) {
    distributable,
    refuse: Refusal,

    pub fn isDistributable(decision: Decision) bool {
        return decision == .distributable;
    }
};

/// Decides whether a signed package may be distributed.
///
/// The developer signature must verify and the developer must be registered — this ties the package to
/// a known builder. The store countersignature must verify — this attests review — and it must cover
/// the digest the developer signed, so the reviewed bytes and the shipped bytes are the same. All four
/// hold or distribution is refused with the reason.
pub fn decide(package: Package) Decision {
    if (!package.developer_signature_valid) return .{ .refuse = .developer_signature_invalid };
    if (!package.developer_registered) return .{ .refuse = .developer_not_registered };
    if (!package.store_countersignature_valid) return .{ .refuse = .not_countersigned };
    if (!package.countersignature_matches_digest) return .{ .refuse = .digest_mismatch };
    return .distributable;
}

const Options = struct {
    developer_signature_valid: bool = true,
    developer_registered: bool = true,
    store_countersignature_valid: bool = true,
    countersignature_matches_digest: bool = true,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [8 * 1024]u8 = undefined;
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

    const package: Package = .{
        .developer_signature_valid = options.developer_signature_valid,
        .developer_registered = options.developer_registered,
        .store_countersignature_valid = options.store_countersignature_valid,
        .countersignature_matches_digest = options.countersignature_matches_digest,
    };

    switch (decide(package)) {
        .distributable => {
            try out.print("package-sign: distributable (developer-signed, registered, store-countersigned)\n", .{});
            try out.flush();
            return 0;
        },
        .refuse => |reason| {
            try out.print("package-sign: refused ({s})\n", .{describe(reason)});
            try out.flush();
            return 1;
        },
    }
}

fn describe(reason: Refusal) []const u8 {
    return switch (reason) {
        .developer_signature_invalid => "the developer signature does not verify",
        .developer_not_registered => "the signing developer is not registered",
        .not_countersigned => "no valid store countersignature; the package did not pass review",
        .digest_mismatch => "the countersignature covers a different digest than the developer signed",
    };
}

fn parseArguments(args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.print(
                \\usage: package-sign [--no-developer-signature] [--unregistered]
                \\                    [--no-countersignature] [--digest-mismatch]
                \\
                \\Decides whether a signed application package may be distributed: it must be
                \\developer-signed by a registered developer and store-countersigned over the same
                \\digest. By default all signals are valid; each flag negates one.
                \\
            , .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--no-developer-signature")) {
            options.developer_signature_valid = false;
        } else if (std.mem.eql(u8, arg, "--unregistered")) {
            options.developer_registered = false;
        } else if (std.mem.eql(u8, arg, "--no-countersignature")) {
            options.store_countersignature_valid = false;
        } else if (std.mem.eql(u8, arg, "--digest-mismatch")) {
            options.countersignature_matches_digest = false;
        } else {
            try err.print("package-sign: unknown argument '{s}'\n", .{arg});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn makePackage(dev_sig: bool, registered: bool, counter: bool, matches: bool) Package {
    return .{
        .developer_signature_valid = dev_sig,
        .developer_registered = registered,
        .store_countersignature_valid = counter,
        .countersignature_matches_digest = matches,
    };
}

test "a developer-signed, registered, countersigned package is distributable" {
    try std.testing.expect(decide(makePackage(true, true, true, true)).isDistributable());
}

test "an invalid developer signature is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .developer_signature_invalid }, decide(makePackage(false, true, true, true)));
}

test "an unregistered developer is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .developer_not_registered }, decide(makePackage(true, false, true, true)));
}

test "a package without a store countersignature is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .not_countersigned }, decide(makePackage(true, true, false, true)));
}

test "a countersignature over a different digest is refused" {
    try std.testing.expectEqual(Decision{ .refuse = .digest_mismatch }, decide(makePackage(true, true, true, false)));
}

test "a distributable package always has both signatures over one digest, swept" {
    // The distribution floor: a distributable package is developer-signed, registered, and
    // store-countersigned over the same digest.
    for ([_]bool{ false, true }) |dev_sig| {
        for ([_]bool{ false, true }) |registered| {
            for ([_]bool{ false, true }) |counter| {
                for ([_]bool{ false, true }) |matches| {
                    if (decide(makePackage(dev_sig, registered, counter, matches)).isDistributable()) {
                        try std.testing.expect(dev_sig and registered and counter and matches);
                    }
                }
            }
        }
    }
}
