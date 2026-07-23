//! Verifying that a large object was not altered, and finding where if it was.
//!
//! A system image, a stored database, a backup — each is too large to re-hash in
//! full every time a device wants to know it is intact, and hashing the whole
//! thing tells you only that something changed, not what. So an object is
//! divided into chunks, each chunk is hashed, and the chunk hashes are combined
//! into a single root that a signature covers. Checking one chunk means hashing
//! that chunk and its path to the root, not the whole object; and a mismatch
//! names the chunk, so a repair can fetch just that piece rather than the entire
//! object.
//!
//! This is the Merkle tree that makes both true. It reads no file; it takes chunk
//! hashes and builds the tree, produces a proof that a chunk belongs under a
//! root, and verifies such a proof. The root is what the boot chain and the
//! update path already sign — this is how a signature over one small value comes
//! to vouch for gigabytes.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;
pub const Digest = [digest_bytes]u8;

/// Domain separators, so a leaf hash can never be mistaken for an interior hash.
///
/// Without them, an attacker could present an interior node's two children as a
/// leaf's contents and forge a tree of a different shape that hashes the same.
/// Prefixing leaf and node hashes with distinct bytes makes the two spaces
/// disjoint.
const leaf_prefix: u8 = 0x00;
const node_prefix: u8 = 0x01;
const empty_prefix: u8 = 0x02;

/// Hashes a chunk's contents into a leaf digest.
pub fn hashLeaf(contents: []const u8) Digest {
    var hash: Sha256 = .init(.{});
    hash.update(&.{leaf_prefix});
    hash.update(contents);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Combines two child digests into a parent, left then right.
///
/// Order matters and is fixed: a node commits to its children in position, so a
/// proof that swapped siblings would not verify.
fn hashNode(left: Digest, right: Digest) Digest {
    var hash: Sha256 = .init(.{});
    hash.update(&.{node_prefix});
    hash.update(&left);
    hash.update(&right);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Computes the root of a tree over a list of leaf digests.
///
/// A level with an odd count carries its last node up unchanged rather than
/// duplicating it, because duplicating a node is the classic Merkle malleability
/// that lets two different leaf lists share a root. Carrying it up keeps every
/// leaf list mapping to a distinct root.
pub fn computeRoot(leaves: []const Digest, scratch: []Digest) Digest {
    std.debug.assert(scratch.len >= leaves.len);
    if (leaves.len == 0) {
        // An empty object still has a root a signature can cover, so it can be
        // distinguished from a one-chunk object and cannot be silently emptied.
        // Its own domain prefix keeps it distinct from a single empty chunk,
        // whose root is a leaf hash.
        var hash: Sha256 = .init(.{});
        hash.update(&.{empty_prefix});
        var digest: Digest = undefined;
        hash.final(&digest);
        return digest;
    }

    var level = scratch[0..leaves.len];
    @memcpy(level, leaves);

    while (level.len > 1) {
        var written: usize = 0;
        var index: usize = 0;
        while (index + 1 < level.len) : (index += 2) {
            level[written] = hashNode(level[index], level[index + 1]);
            written += 1;
        }
        if (level.len % 2 == 1) {
            // Carry the odd node up unchanged rather than duplicating it.
            level[written] = level[level.len - 1];
            written += 1;
        }
        level = level[0..written];
    }
    return level[0];
}

/// One step in a proof: a sibling digest and which side it is on.
pub const ProofStep = struct {
    sibling: Digest,
    /// True if the sibling is the left child at this level, so the verifier
    /// combines in the right order.
    sibling_is_left: bool,
};

/// The maximum tree height a proof may carry.
///
/// Bounds a proof so a malformed one cannot ask a verifier to loop far. Two to
/// the thirty-second chunks is more than any object this platform stores.
pub const max_proof_steps: usize = 32;

/// A proof that a leaf belongs under a root.
pub const Proof = struct {
    steps: [max_proof_steps]ProofStep = undefined,
    len: usize = 0,

    fn push(proof: *Proof, step: ProofStep) void {
        std.debug.assert(proof.len < max_proof_steps);
        proof.steps[proof.len] = step;
        proof.len += 1;
    }
};

/// Builds a proof that the leaf at an index belongs under the tree's root.
///
/// Returns null if the tree is too tall for a bounded proof, which a caller must
/// handle rather than producing an unverifiable object.
pub fn proveLeaf(
    leaves: []const Digest,
    index: usize,
    scratch: []Digest,
) ?Proof {
    if (index >= leaves.len) return null;
    var proof: Proof = .{};

    var level = scratch[0..leaves.len];
    @memcpy(level, leaves);
    var position = index;

    while (level.len > 1) {
        if (proof.len >= max_proof_steps) return null;
        if (position % 2 == 1) {
            // The node's sibling is to its left.
            proof.push(.{ .sibling = level[position - 1], .sibling_is_left = true });
        } else if (position + 1 < level.len) {
            // Sibling to the right.
            proof.push(.{ .sibling = level[position + 1], .sibling_is_left = false });
        }
        // else: an odd node with no sibling; it carries up, no step recorded.

        var written: usize = 0;
        var scan: usize = 0;
        while (scan + 1 < level.len) : (scan += 2) {
            level[written] = hashNode(level[scan], level[scan + 1]);
            written += 1;
        }
        if (level.len % 2 == 1) {
            level[written] = level[level.len - 1];
            written += 1;
        }
        level = level[0..written];
        position /= 2;
    }
    return proof;
}

/// Verifies that a leaf digest belongs under a root, given a proof.
///
/// Recomputes the path from the leaf to a root using the proof's siblings and
/// checks it equals the expected root. A single altered chunk changes its leaf
/// digest, which changes every node up to the root, so this fails — and the
/// caller knows exactly which chunk it asked about.
pub fn verifyLeaf(leaf: Digest, proof: Proof, root: Digest) bool {
    var current = leaf;
    for (proof.steps[0..proof.len]) |step| {
        current = if (step.sibling_is_left)
            hashNode(step.sibling, current)
        else
            hashNode(current, step.sibling);
    }
    return std.crypto.timing_safe.eql(Digest, current, root);
}

fn leavesFrom(comptime n: usize, gpa: std.mem.Allocator, contents: [n][]const u8) ![]Digest {
    const leaves = try gpa.alloc(Digest, n);
    for (contents, 0..) |chunk, index| leaves[index] = hashLeaf(chunk);
    return leaves;
}

test "the same chunks always produce the same root" {
    const gpa = std.testing.allocator;
    const chunks = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const leaves = try leavesFrom(4, gpa, chunks);
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 4);
    defer gpa.free(scratch);

    const first = computeRoot(leaves, scratch);
    const second = computeRoot(leaves, scratch);
    try std.testing.expectEqualSlices(u8, &first, &second);
}

test "changing any chunk changes the root" {
    const gpa = std.testing.allocator;
    const before = try leavesFrom(4, gpa, .{ "alpha", "beta", "gamma", "delta" });
    defer gpa.free(before);
    const after = try leavesFrom(4, gpa, .{ "alpha", "beta", "GAMMA", "delta" });
    defer gpa.free(after);
    const scratch = try gpa.alloc(Digest, 4);
    defer gpa.free(scratch);

    try std.testing.expect(!std.mem.eql(
        u8,
        &computeRoot(before, scratch),
        &computeRoot(after, scratch),
    ));
}

test "a proof verifies a chunk against the root" {
    const gpa = std.testing.allocator;
    const chunks = [_][]const u8{ "one", "two", "three", "four", "five" };
    const leaves = try leavesFrom(5, gpa, chunks);
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 5);
    defer gpa.free(scratch);
    const proof_scratch = try gpa.alloc(Digest, 5);
    defer gpa.free(proof_scratch);

    const root = computeRoot(leaves, scratch);

    // Every chunk proves against the root, not just the first.
    for (0..5) |index| {
        const proof = proveLeaf(leaves, index, proof_scratch).?;
        try std.testing.expect(verifyLeaf(leaves[index], proof, root));
    }
}

test "a proof for one chunk does not verify a different chunk" {
    const gpa = std.testing.allocator;
    const chunks = [_][]const u8{ "one", "two", "three", "four" };
    const leaves = try leavesFrom(4, gpa, chunks);
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 4);
    defer gpa.free(scratch);

    const root = computeRoot(leaves, scratch);
    const proof = proveLeaf(leaves, 1, scratch).?;

    // The proof is for chunk 1; chunk 2's leaf must not verify against it.
    try std.testing.expect(verifyLeaf(leaves[1], proof, root));
    try std.testing.expect(!verifyLeaf(leaves[2], proof, root));
}

test "an altered chunk fails verification and names itself" {
    const gpa = std.testing.allocator;
    const chunks = [_][]const u8{ "one", "two", "three", "four" };
    const leaves = try leavesFrom(4, gpa, chunks);
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 4);
    defer gpa.free(scratch);

    const root = computeRoot(leaves, scratch);
    const proof = proveLeaf(leaves, 2, scratch).?;

    // Chunk 2's contents were tampered with in storage: its recomputed leaf no
    // longer verifies, and the caller knows it was chunk 2 it checked.
    const tampered = hashLeaf("THREE");
    try std.testing.expect(!verifyLeaf(tampered, proof, root));
    // The genuine chunk still verifies, confirming the proof itself is sound.
    try std.testing.expect(verifyLeaf(leaves[2], proof, root));
}

test "an odd number of chunks still builds a consistent tree" {
    const gpa = std.testing.allocator;
    // Three chunks: the odd one carries up rather than being duplicated.
    const chunks = [_][]const u8{ "a", "b", "c" };
    const leaves = try leavesFrom(3, gpa, chunks);
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 3);
    defer gpa.free(scratch);

    const root = computeRoot(leaves, scratch);
    for (0..3) |index| {
        const proof = proveLeaf(leaves, index, scratch).?;
        try std.testing.expect(verifyLeaf(leaves[index], proof, root));
    }
}

test "a single chunk is its own tree" {
    const gpa = std.testing.allocator;
    const leaves = try leavesFrom(1, gpa, .{"only"});
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 1);
    defer gpa.free(scratch);

    const root = computeRoot(leaves, scratch);
    const proof = proveLeaf(leaves, 0, scratch).?;
    try std.testing.expect(verifyLeaf(leaves[0], proof, root));
    // A one-leaf proof has no steps.
    try std.testing.expectEqual(@as(usize, 0), proof.len);
}

test "an empty object has a distinct root" {
    var scratch: [1]Digest = undefined;
    const empty = computeRoot(&.{}, &scratch);

    const gpa = std.testing.allocator;
    const one = try leavesFrom(1, gpa, .{""});
    defer gpa.free(one);
    // An empty object must not share a root with a single empty chunk, or an
    // object could be silently emptied without changing its root.
    try std.testing.expect(!std.mem.eql(u8, &empty, &computeRoot(one, &scratch)));
}

test "leaf and node hashing are domain-separated" {
    // A leaf's hash of two concatenated digests must not equal the node hash of
    // those digests, or a tree of a different shape could forge the same root.
    var left: Digest = undefined;
    var right: Digest = undefined;
    @memset(&left, 0xaa);
    @memset(&right, 0xbb);

    var concatenated: [digest_bytes * 2]u8 = undefined;
    @memcpy(concatenated[0..digest_bytes], &left);
    @memcpy(concatenated[digest_bytes..], &right);

    try std.testing.expect(!std.mem.eql(u8, &hashLeaf(&concatenated), &hashNode(left, right)));
}

test "proving an out-of-range leaf returns null" {
    const gpa = std.testing.allocator;
    const leaves = try leavesFrom(2, gpa, .{ "a", "b" });
    defer gpa.free(leaves);
    var scratch: [2]Digest = undefined;
    try std.testing.expectEqual(@as(?Proof, null), proveLeaf(leaves, 5, &scratch));
}

test "swapping siblings in a proof breaks it" {
    const gpa = std.testing.allocator;
    const leaves = try leavesFrom(4, gpa, .{ "a", "b", "c", "d" });
    defer gpa.free(leaves);
    const scratch = try gpa.alloc(Digest, 4);
    defer gpa.free(scratch);

    const root = computeRoot(leaves, scratch);
    var proof = proveLeaf(leaves, 0, scratch).?;
    // Flip which side the first sibling is on: the order the tree committed to
    // is part of the proof, so this no longer verifies.
    proof.steps[0].sibling_is_left = !proof.steps[0].sibling_is_left;
    try std.testing.expect(!verifyLeaf(leaves[0], proof, root));
}
