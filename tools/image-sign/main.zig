//! Signs an image digest, and checks a signature against one.
//!
//! The signature covers the digest the format defines, which covers the
//! manifest, which covers every file. A device therefore checks one signature
//! and gets an answer about every byte it is about to install.
//!
//! The signing key is read from a file rather than generated here, and this tool
//! never writes one. A release key that a build tool could mint is a release key
//! anyone who can run the build tool can mint.
//!
//! Exit codes: 0 signed or verified, 1 verification failed, 2 usage error.

const std = @import("std");
const compat = @import("compat");
const io_adapters = compat.io;
const packaging = @import("packaging");

const image = packaging.image;
const Ed25519 = std.crypto.sign.Ed25519;

/// Everything a signature is computed over, beyond the digest itself.
///
/// A release signature must not be usable as any other signature the same key
/// produced, so the statement names what kind of statement it is.
const context = "system image v1";

const Mode = enum {
    sign,
    verify,
    /// Prints the public half of a signing key.
    ///
    /// Needed because a device is configured with a public key and nothing else
    /// derives one. Without this, the only way to obtain it would be to write
    /// a second tool or to copy it out of a running system.
    public_key,
};

const Options = struct {
    mode: Mode = .verify,
    digest: ?[]const u8 = null,
    key: ?[]const u8 = null,
    signature: ?[]const u8 = null,
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

    if (options.mode == .public_key) {
        const key_path = options.key orelse {
            try err.writeAll("image-sign: --key is required\n");
            try err.flush();
            return 2;
        };
        const key_text = io_adapters.cwd().readFileAlloc(
            io,
            key_path,
            arena,
            .limited(4096),
        ) catch {
            try err.print("image-sign: cannot read '{s}'\n", .{key_path});
            try err.flush();
            return 2;
        };
        const seed = parseSeed(key_text) catch {
            try err.writeAll("image-sign: signing key must be 64 hexadecimal characters\n");
            try err.flush();
            return 2;
        };
        const pair = Ed25519.KeyPair.generateDeterministic(seed) catch {
            try err.writeAll("image-sign: signing key is not usable\n");
            try err.flush();
            return 2;
        };
        try out.print("{x}\n", .{pair.public_key.toBytes()});
        try out.flush();
        return 0;
    }

    const digest_text = options.digest orelse {
        try err.writeAll("image-sign: --digest is required\n");
        try err.flush();
        return 2;
    };
    const digest = parseDigest(digest_text) catch {
        try err.writeAll("image-sign: digest must be 64 hexadecimal characters\n");
        try err.flush();
        return 2;
    };

    const key_path = options.key orelse {
        try err.writeAll("image-sign: --key is required\n");
        try err.flush();
        return 2;
    };
    const key_text = io_adapters.cwd().readFileAlloc(
        io,
        key_path,
        arena,
        .limited(4096),
    ) catch {
        try err.print("image-sign: cannot read '{s}'\n", .{key_path});
        try err.flush();
        return 2;
    };

    switch (options.mode) {
        .sign => {
            const seed = parseSeed(key_text) catch {
                try err.writeAll("image-sign: signing key must be 64 hexadecimal characters\n");
                try err.flush();
                return 2;
            };
            const pair = Ed25519.KeyPair.generateDeterministic(seed) catch {
                try err.writeAll("image-sign: signing key is not usable\n");
                try err.flush();
                return 2;
            };
            const signature = pair.sign(&statementFor(digest), null) catch {
                try err.writeAll("image-sign: signing failed\n");
                try err.flush();
                return 1;
            };
            try out.print("{x}\n", .{signature.toBytes()});
            try out.flush();
            return 0;
        },
        .verify => {
            const public = parsePublicKey(key_text) catch {
                try err.writeAll("image-sign: public key must be 64 hexadecimal characters\n");
                try err.flush();
                return 2;
            };
            const signature_text = options.signature orelse {
                try err.writeAll("image-sign: --signature is required to verify\n");
                try err.flush();
                return 2;
            };
            const signature_bytes = parseSignature(signature_text) catch {
                try err.writeAll("image-sign: signature must be 128 hexadecimal characters\n");
                try err.flush();
                return 2;
            };

            if (verify(digest, public, signature_bytes)) {
                try out.writeAll("image-sign: the signature covers this image\n");
                try out.flush();
                return 0;
            }
            try err.writeAll("image-sign: the signature does not cover this image\n");
            try err.flush();
            return 1;
        },
        // Handled before the digest is required, because printing a public key
        // needs a key and nothing else.
        .public_key => unreachable,
    }
}

/// What is actually signed.
fn statementFor(digest: [image.digest_bytes]u8) [context.len + image.digest_bytes]u8 {
    var statement: [context.len + image.digest_bytes]u8 = undefined;
    @memcpy(statement[0..context.len], context);
    @memcpy(statement[context.len..], &digest);
    return statement;
}

fn verify(
    digest: [image.digest_bytes]u8,
    public_key: [Ed25519.PublicKey.encoded_length]u8,
    signature_bytes: [Ed25519.Signature.encoded_length]u8,
) bool {
    const key = Ed25519.PublicKey.fromBytes(public_key) catch return false;
    const signature: Ed25519.Signature = .fromBytes(signature_bytes);
    signature.verify(&statementFor(digest), key) catch return false;
    return true;
}

fn parseHex(comptime length: usize, text: []const u8) ![length]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != length * 2) return error.Malformed;
    var bytes: [length]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, trimmed) catch return error.Malformed;
    return bytes;
}

fn parseDigest(text: []const u8) ![image.digest_bytes]u8 {
    return parseHex(image.digest_bytes, text);
}

fn parseSeed(text: []const u8) ![Ed25519.KeyPair.seed_length]u8 {
    return parseHex(Ed25519.KeyPair.seed_length, text);
}

fn parsePublicKey(text: []const u8) ![Ed25519.PublicKey.encoded_length]u8 {
    return parseHex(Ed25519.PublicKey.encoded_length, text);
}

fn parseSignature(text: []const u8) ![Ed25519.Signature.encoded_length]u8 {
    return parseHex(Ed25519.Signature.encoded_length, text);
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
        } else if (std.mem.eql(u8, argument, "--sign")) {
            options.mode = .sign;
        } else if (std.mem.eql(u8, argument, "--verify")) {
            options.mode = .verify;
        } else if (std.mem.eql(u8, argument, "--public-key")) {
            options.mode = .public_key;
        } else if (std.mem.startsWith(u8, argument, "--digest=")) {
            options.digest = argument["--digest=".len..];
        } else if (std.mem.startsWith(u8, argument, "--key=")) {
            options.key = argument["--key=".len..];
        } else if (std.mem.startsWith(u8, argument, "--signature=")) {
            options.signature = argument["--signature=".len..];
        } else {
            try err.print("image-sign: unexpected argument '{s}'\n", .{argument});
            return error.InvalidArguments;
        }
    }
    return options;
}

fn writeUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Usage: image-sign [--sign|--verify|--public-key] --key=<path> [--digest=<hex>] [--signature=<hex>]
        \\
        \\Signs the digest image-build produced, or checks a signature against
        \\one. The digest covers the manifest, which covers every file, so one
        \\signature answers for every byte a device installs.
        \\
        \\The key is read from a file and never written by this tool. A release
        \\key a build tool could mint is a release key anyone who can run the
        \\build tool can mint.
        \\
        \\Options:
        \\  --sign               Produce a signature (key file holds a seed)
        \\  --verify             Check one (key file holds a public key; default)
        \\  --public-key         Print the public half of a signing key
        \\  --digest=<hex>       The digest from image-build
        \\  --key=<path>         File holding the key, as hexadecimal
        \\  --signature=<hex>    The signature to check
        \\  -h, --help           Show this message
        \\
        \\Exit codes:
        \\  0  signed, or the signature covers the image
        \\  1  it does not
        \\  2  usage error
        \\
    );
}

const sample_digest: [image.digest_bytes]u8 = @splat(0x5a);

fn testPair() !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(0x21));
}

test "a signature over an image verifies" {
    const pair = try testPair();
    const signature = try pair.sign(&statementFor(sample_digest), null);
    try std.testing.expect(verify(
        sample_digest,
        pair.public_key.toBytes(),
        signature.toBytes(),
    ));
}

test "a signature does not carry to another image" {
    const pair = try testPair();
    const signature = try pair.sign(&statementFor(sample_digest), null);

    var other: [image.digest_bytes]u8 = sample_digest;
    other[0] ^= 0xff;

    // One changed file changes the digest, and the signature stops covering it.
    try std.testing.expect(!verify(other, pair.public_key.toBytes(), signature.toBytes()));
}

test "a signature by another key is refused" {
    const pair = try testPair();
    const impostor = try Ed25519.KeyPair.generateDeterministic(@splat(0x77));
    const signature = try impostor.sign(&statementFor(sample_digest), null);

    try std.testing.expect(!verify(
        sample_digest,
        pair.public_key.toBytes(),
        signature.toBytes(),
    ));
}

test "a signature over the bare digest does not count" {
    const pair = try testPair();
    // Signed without the statement that says what kind of statement it is. If
    // this passed, any signature the release key made over 32 bytes could be
    // presented as a release approval.
    const signature = try pair.sign(&sample_digest, null);
    try std.testing.expect(!verify(
        sample_digest,
        pair.public_key.toBytes(),
        signature.toBytes(),
    ));
}

test "a malformed key is refused rather than treated as absent" {
    const pair = try testPair();
    const signature = try pair.sign(&statementFor(sample_digest), null);
    const unusable: [Ed25519.PublicKey.encoded_length]u8 = @splat(0);

    // A key that cannot be read must not become "no verification required".
    try std.testing.expect(!verify(sample_digest, unusable, signature.toBytes()));
}

test "hexadecimal is parsed only at the exact length" {
    _ = try parseDigest("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a");

    // Surrounding whitespace is tolerated, because a key in a file ends with a
    // newline and refusing that would be refusing the normal case.
    _ = try parseDigest("  5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a\n");

    try std.testing.expect(std.meta.isError(parseDigest("5a5a")));
    try std.testing.expect(std.meta.isError(parseDigest("")));
    try std.testing.expect(std.meta.isError(
        parseDigest("zz5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"),
    ));
}

test "signing and verifying agree" {
    const pair = try testPair();
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(0x21);
    const from_seed = try Ed25519.KeyPair.generateDeterministic(seed);

    // The signing path derives the pair from the seed the key file holds; the
    // verifying path is given the public half directly. They must be the same
    // key or a release would be signed by something nothing accepts.
    const signature = try from_seed.sign(&statementFor(sample_digest), null);
    try std.testing.expect(verify(
        sample_digest,
        pair.public_key.toBytes(),
        signature.toBytes(),
    ));
}
