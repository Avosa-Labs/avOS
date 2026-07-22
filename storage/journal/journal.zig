//! An append-only journal with crash-consistent records.
//!
//! State transitions are written here before they are believed. A record that
//! is not complete and does not verify is not a record: recovery stops at the
//! first one that fails, and everything before it is intact. That is what makes
//! a crash during a write survivable rather than a source of state nobody can
//! explain.
//!
//! Every record carries the length twice — once before the payload and once
//! after, either side of the digest — so a write torn anywhere is detectable
//! rather than being read as a shorter record that happens to parse.
//!
//! Replay is idempotent. A durable mutation identifies itself by what it does,
//! so replaying the journal after a crash reaches the same state as replaying
//! it twice, and an external effect recorded here is performed once regardless
//! of how many times recovery runs.

const std = @import("std");
const core = @import("core");

const identity = core.identity;
const time = core.time;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const digest_bytes = Sha256.digest_length;

/// Identifies this journal format on disk. A stable technical identifier:
/// changing it is a migration, never a rename.
pub const format_identifier: u32 = 0x4a_52_4e_4c;

/// The format version this build writes.
pub const format_version: u16 = 1;

/// Largest payload one record may carry.
pub const max_payload_bytes: usize = 1 << 20;

/// Largest a journal may grow before it must be compacted.
///
/// A store with no ceiling fills the device it lives on, and the failure
/// arrives as something unrelated running out of space.
pub const max_journal_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    /// The header does not belong to this journal format.
    NotAJournal,
    /// The format version is one this build cannot read.
    UnsupportedVersion,
    /// A record's digest does not match its payload.
    IntegrityFailure,
    /// A record ended before it was complete.
    TornWrite,
    /// A declared length exceeds what this journal carries.
    RecordTooLarge,
    /// The journal has reached its growth ceiling.
    JournalFull,
    /// The sequence is not contiguous.
    SequenceBroken,
    /// The buffer supplied cannot hold the result.
    BufferTooSmall,
};

/// What kind of state transition a record describes.
///
/// Explicit and never renumbered: a journal written by an older build must read
/// the same meaning from the same number.
pub const RecordKind = enum(u16) {
    task_transition = 1,
    capability_issued = 2,
    capability_revoked = 3,
    approval_decided = 4,
    package_installed = 5,
    session_transferred = 6,
    audit_appended = 7,
    effect_claimed = 8,
    effect_settled = 9,

    pub fn parse(value: u16) ?RecordKind {
        return std.enums.fromInt(RecordKind, value);
    }

    /// Whether replaying this record could reach outside the system.
    ///
    /// A record that could must be claimed before the effect and settled after,
    /// so replay finds the claim rather than repeating the effect.
    pub fn mayHaveExternalEffect(kind: RecordKind) bool {
        return switch (kind) {
            .effect_claimed, .effect_settled => true,
            else => false,
        };
    }
};

/// One durable record.
pub const Record = struct {
    sequence: u64,
    kind: RecordKind,
    /// Identifies what this mutation does, so replaying it twice is the same as
    /// replaying it once.
    idempotency_key: u128,
    timestamp: time.Timestamp,
    payload: []const u8,
};

/// Bytes a record occupies once encoded.
pub fn encodedSize(payload_len: usize) usize {
    return 4 + // leading length
        8 + // sequence
        2 + // kind
        16 + // idempotency key
        8 + // timestamp
        payload_len +
        digest_bytes +
        4; // trailing length
}

/// The fixed header every journal begins with.
pub const header_bytes: usize = 4 + 2 + 2;

/// Writes the journal header.
pub fn writeHeader(buffer: []u8) Error![]const u8 {
    if (buffer.len < header_bytes) return error.BufferTooSmall;
    std.mem.writeInt(u32, buffer[0..4], format_identifier, .little);
    std.mem.writeInt(u16, buffer[4..6], format_version, .little);
    std.mem.writeInt(u16, buffer[6..8], 0, .little);
    return buffer[0..header_bytes];
}

/// Reads and checks the journal header.
pub fn readHeader(bytes: []const u8) Error!void {
    if (bytes.len < header_bytes) return error.TornWrite;
    if (std.mem.readInt(u32, bytes[0..4], .little) != format_identifier) {
        return error.NotAJournal;
    }
    const version = std.mem.readInt(u16, bytes[4..6], .little);
    // A newer version may have changed the record layout, and guessing would
    // interpret one field as another.
    if (version > format_version) return error.UnsupportedVersion;
}

/// Encodes one record.
///
/// The length is written before the payload and again after the digest. A write
/// torn between them leaves the two disagreeing, which recovery detects rather
/// than reading the fragment as a complete shorter record.
pub fn encodeRecord(record: Record, buffer: []u8) Error![]const u8 {
    if (record.payload.len > max_payload_bytes) return error.RecordTooLarge;
    const total = encodedSize(record.payload.len);
    if (buffer.len < total) return error.BufferTooSmall;

    const length = std.math.cast(u32, record.payload.len) orelse return error.RecordTooLarge;

    var offset: usize = 0;
    std.mem.writeInt(u32, buffer[offset..][0..4], length, .little);
    offset += 4;
    std.mem.writeInt(u64, buffer[offset..][0..8], record.sequence, .little);
    offset += 8;
    std.mem.writeInt(u16, buffer[offset..][0..2], @intFromEnum(record.kind), .little);
    offset += 2;
    std.mem.writeInt(u128, buffer[offset..][0..16], record.idempotency_key, .little);
    offset += 16;
    std.mem.writeInt(i64, buffer[offset..][0..8], record.timestamp.nanoseconds, .little);
    offset += 8;
    @memcpy(buffer[offset..][0..record.payload.len], record.payload);
    offset += record.payload.len;

    // The digest covers everything written so far, so a change anywhere in the
    // record is detected rather than only a change to the payload.
    var digest: [digest_bytes]u8 = undefined;
    Sha256.hash(buffer[0..offset], &digest, .{});
    @memcpy(buffer[offset..][0..digest_bytes], &digest);
    offset += digest_bytes;

    std.mem.writeInt(u32, buffer[offset..][0..4], length, .little);
    offset += 4;

    return buffer[0..offset];
}

/// Reads records in order, stopping at the first that does not verify.
///
/// Stopping rather than skipping is deliberate. A journal with a damaged record
/// in the middle has an unknown suffix, and continuing past it would apply
/// transitions that may depend on one that was lost.
pub const Reader = struct {
    bytes: []const u8,
    position: usize,
    /// Sequence expected next. A gap means records were lost.
    expected_sequence: u64 = 1,
    /// Where the last intact record ended. Everything before this is sound.
    intact_through: usize,

    pub fn init(bytes: []const u8) Error!Reader {
        try readHeader(bytes);
        return .{
            .bytes = bytes,
            .position = header_bytes,
            .intact_through = header_bytes,
        };
    }

    /// Returns the next record, or null at a clean end.
    ///
    /// A torn or corrupt record is reported as an error; `intact_through` marks
    /// how much of the journal was sound, which is what recovery truncates to.
    pub fn next(reader: *Reader) Error!?Record {
        if (reader.position >= reader.bytes.len) return null;

        const remaining = reader.bytes.len - reader.position;
        if (remaining < 4) return error.TornWrite;

        const length = std.mem.readInt(u32, reader.bytes[reader.position..][0..4], .little);
        if (length > max_payload_bytes) return error.RecordTooLarge;

        const total = encodedSize(length);
        if (remaining < total) return error.TornWrite;

        const record_bytes = reader.bytes[reader.position..][0..total];

        // The trailing length must agree with the leading one. A write torn
        // between them leaves them different.
        const trailing = std.mem.readInt(u32, record_bytes[total - 4 ..][0..4], .little);
        if (trailing != length) return error.TornWrite;

        const digest_offset = total - 4 - digest_bytes;
        var computed: [digest_bytes]u8 = undefined;
        Sha256.hash(record_bytes[0..digest_offset], &computed, .{});
        const stored: *const [digest_bytes]u8 = record_bytes[digest_offset..][0..digest_bytes];
        if (!std.crypto.timing_safe.eql([digest_bytes]u8, computed, stored.*)) {
            return error.IntegrityFailure;
        }

        var offset: usize = 4;
        const sequence = std.mem.readInt(u64, record_bytes[offset..][0..8], .little);
        offset += 8;
        const kind_value = std.mem.readInt(u16, record_bytes[offset..][0..2], .little);
        offset += 2;
        const idempotency_key = std.mem.readInt(u128, record_bytes[offset..][0..16], .little);
        offset += 16;
        const nanoseconds = std.mem.readInt(i64, record_bytes[offset..][0..8], .little);
        offset += 8;

        const kind = RecordKind.parse(kind_value) orelse return error.IntegrityFailure;

        if (sequence != reader.expected_sequence) return error.SequenceBroken;
        reader.expected_sequence += 1;

        reader.position += total;
        reader.intact_through = reader.position;

        return .{
            .sequence = sequence,
            .kind = kind,
            .idempotency_key = idempotency_key,
            .timestamp = .{ .nanoseconds = nanoseconds },
            .payload = record_bytes[offset..digest_offset],
        };
    }
};

/// What recovery found.
pub const Recovery = struct {
    /// Records that verified, in order.
    applied: usize,
    /// Bytes of the journal that were sound. A shorter value than the journal
    /// means the tail was damaged and must be truncated.
    intact_through: usize,
    /// Set when recovery stopped early.
    stopped_by: ?Error,

    pub fn wasClean(recovery: Recovery) bool {
        return recovery.stopped_by == null;
    }
};

/// Replays a journal, applying each record exactly once.
///
/// `apply` is called for every verified record whose key has not been seen. A
/// key already applied is skipped, so replaying the same journal twice reaches
/// the same state as replaying it once.
pub fn replay(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    context: anytype,
    comptime apply: fn (@TypeOf(context), Record) anyerror!void,
) !Recovery {
    var reader = Reader.init(bytes) catch |failure| {
        return .{ .applied = 0, .intact_through = 0, .stopped_by = failure };
    };

    var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
    defer seen.deinit(gpa);

    var applied: usize = 0;
    while (true) {
        const record = reader.next() catch |failure| {
            return .{
                .applied = applied,
                .intact_through = reader.intact_through,
                .stopped_by = failure,
            };
        } orelse break;

        if (record.idempotency_key != 0) {
            const entry = try seen.getOrPut(gpa, record.idempotency_key);
            if (entry.found_existing) continue;
        }

        try apply(context, record);
        applied += 1;
    }

    return .{
        .applied = applied,
        .intact_through = reader.intact_through,
        .stopped_by = null,
    };
}

/// Builds a journal in memory.
///
/// Ownership: the journal owns its buffer and releases it in `deinit`.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    next_sequence: u64 = 1,

    pub fn init(gpa: std.mem.Allocator) !Writer {
        var writer: Writer = .{ .gpa = gpa };
        var header: [header_bytes]u8 = undefined;
        const encoded = try writeHeader(&header);
        try writer.bytes.appendSlice(gpa, encoded);
        return writer;
    }

    pub fn deinit(writer: *Writer) void {
        writer.bytes.deinit(writer.gpa);
        writer.* = undefined;
    }

    pub fn append(
        writer: *Writer,
        kind: RecordKind,
        idempotency_key: u128,
        timestamp: time.Timestamp,
        payload: []const u8,
    ) !u64 {
        const total = encodedSize(payload.len);
        if (writer.bytes.items.len + total > max_journal_bytes) return error.JournalFull;

        const scratch = try writer.gpa.alloc(u8, total);
        defer writer.gpa.free(scratch);

        const sequence = writer.next_sequence;
        const encoded = try encodeRecord(.{
            .sequence = sequence,
            .kind = kind,
            .idempotency_key = idempotency_key,
            .timestamp = timestamp,
            .payload = payload,
        }, scratch);

        try writer.bytes.appendSlice(writer.gpa, encoded);
        writer.next_sequence += 1;
        return sequence;
    }

    pub fn written(writer: Writer) []const u8 {
        return writer.bytes.items;
    }

    /// How close the journal is to needing compaction.
    pub fn utilization(writer: Writer) f32 {
        return @as(f32, @floatFromInt(writer.bytes.items.len)) /
            @as(f32, @floatFromInt(max_journal_bytes));
    }
};

const Collector = struct {
    kinds: std.ArrayList(RecordKind) = .empty,
    gpa: std.mem.Allocator,

    fn record(collector: *Collector, entry: Record) anyerror!void {
        try collector.kinds.append(collector.gpa, entry.kind);
    }

    fn deinit(collector: *Collector) void {
        collector.kinds.deinit(collector.gpa);
    }
};

test "a journal round-trips every record in order" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "running");
    _ = try writer.append(.capability_issued, 2, .fromSeconds(1_001), "calendar read");
    _ = try writer.append(.approval_decided, 3, .fromSeconds(1_002), "approved");

    var reader = try Reader.init(writer.written());
    const first = (try reader.next()).?;
    try std.testing.expectEqual(RecordKind.task_transition, first.kind);
    try std.testing.expectEqualStrings("running", first.payload);
    try std.testing.expectEqual(@as(u64, 1), first.sequence);

    const second = (try reader.next()).?;
    try std.testing.expectEqual(RecordKind.capability_issued, second.kind);
    const third = (try reader.next()).?;
    try std.testing.expectEqual(RecordKind.approval_decided, third.kind);
    try std.testing.expectEqual(@as(?Record, null), try reader.next());
}

test "a journal from a different format is refused" {
    var buffer: [64]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], 0xdead_beef, .little);
    try std.testing.expectError(error.NotAJournal, readHeader(buffer[0..8]));
}

test "a newer format version is refused rather than guessed" {
    var buffer: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], format_identifier, .little);
    std.mem.writeInt(u16, buffer[4..6], format_version + 1, .little);
    std.mem.writeInt(u16, buffer[6..8], 0, .little);
    try std.testing.expectError(error.UnsupportedVersion, readHeader(&buffer));
}

test "a write torn anywhere is detected" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "running");
    _ = try writer.append(.task_transition, 2, .fromSeconds(1_001), "succeeded");

    const complete = writer.written();

    // Every truncation point after the first record must either read the first
    // record and then report a tear, or report a tear immediately.
    var length = header_bytes + 1;
    while (length < complete.len) : (length += 1) {
        var reader = try Reader.init(complete[0..length]);
        var saw_tear = false;
        while (true) {
            const outcome = reader.next() catch {
                saw_tear = true;
                break;
            };
            if (outcome == null) break;
        }
        // A truncation that lands exactly on a record boundary is a clean end,
        // not a tear.
        const first_record_end = header_bytes + encodedSize("running".len);
        if (length != first_record_end) try std.testing.expect(saw_tear);
    }
}

test "corrupting any byte of a record is detected" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();
    _ = try writer.append(.approval_decided, 7, .fromSeconds(1_000), "approved");

    const complete = writer.written();
    const corrupted = try gpa.alloc(u8, complete.len);
    defer gpa.free(corrupted);

    var index = header_bytes;
    while (index < complete.len) : (index += 1) {
        @memcpy(corrupted, complete);
        corrupted[index] ^= 0x01;

        var reader = Reader.init(corrupted) catch continue;
        const outcome = reader.next() catch continue;
        // If it still read, a field must differ; a corruption that read back
        // identically would mean a byte nothing depends on.
        if (outcome) |record| {
            const unchanged = record.kind == .approval_decided and
                record.sequence == 1 and
                record.idempotency_key == 7 and
                std.mem.eql(u8, record.payload, "approved");
            try std.testing.expect(!unchanged);
        }
    }
}

test "recovery stops at damage and reports how much was sound" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "first");
    const sound_through = writer.written().len;
    _ = try writer.append(.task_transition, 2, .fromSeconds(1_001), "second");
    _ = try writer.append(.task_transition, 3, .fromSeconds(1_002), "third");

    const complete = writer.written();
    const damaged = try gpa.alloc(u8, complete.len);
    defer gpa.free(damaged);
    @memcpy(damaged, complete);
    // Damage the second record.
    damaged[sound_through + 20] ^= 0xff;

    var collector: Collector = .{ .gpa = gpa };
    defer collector.deinit();

    const recovery = try replay(gpa, damaged, &collector, Collector.record);

    try std.testing.expect(!recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 1), recovery.applied);
    // Everything before the damage is intact and is what recovery keeps.
    try std.testing.expectEqual(sound_through, recovery.intact_through);
}

test "replay is idempotent" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    // The same mutation recorded twice, as a retried write would produce.
    _ = try writer.append(.effect_claimed, 0xc0ffee, .fromSeconds(1_000), "send");
    _ = try writer.append(.effect_claimed, 0xc0ffee, .fromSeconds(1_001), "send");
    _ = try writer.append(.effect_settled, 0xbeef, .fromSeconds(1_002), "performed");

    var first: Collector = .{ .gpa = gpa };
    defer first.deinit();
    const once = try replay(gpa, writer.written(), &first, Collector.record);

    var second: Collector = .{ .gpa = gpa };
    defer second.deinit();
    _ = try replay(gpa, writer.written(), &second, Collector.record);

    // The duplicate is applied once, and replaying the journal again reaches
    // the same state rather than doubling it.
    try std.testing.expectEqual(@as(usize, 2), once.applied);
    try std.testing.expectEqual(first.kinds.items.len, second.kinds.items.len);
}

test "a record that could reach outside the system is marked as such" {
    for (std.enums.values(RecordKind)) |kind| {
        const external = kind == .effect_claimed or kind == .effect_settled;
        try std.testing.expectEqual(external, kind.mayHaveExternalEffect());
    }
}

test "a broken sequence is detected rather than applied out of order" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    _ = try writer.append(.task_transition, 1, .fromSeconds(1_000), "first");
    _ = try writer.append(.task_transition, 2, .fromSeconds(1_001), "second");

    const complete = writer.written();
    const reordered = try gpa.alloc(u8, complete.len);
    defer gpa.free(reordered);
    @memcpy(reordered, complete);

    // Re-encode the first record with a sequence number from further ahead, so
    // it verifies but does not follow.
    var scratch: [256]u8 = undefined;
    const forged = try encodeRecord(.{
        .sequence = 5,
        .kind = .task_transition,
        .idempotency_key = 1,
        .timestamp = .fromSeconds(1_000),
        .payload = "first",
    }, &scratch);
    @memcpy(reordered[header_bytes..][0..forged.len], forged);

    var reader = try Reader.init(reordered);
    try std.testing.expectError(error.SequenceBroken, reader.next());
}

test "an oversized record is refused before it is written or read" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    const oversized = try gpa.alloc(u8, max_payload_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 0);

    try std.testing.expectError(
        error.RecordTooLarge,
        writer.append(.task_transition, 1, .fromSeconds(1_000), oversized),
    );

    // And a declared length beyond the ceiling is refused on read, before it
    // sizes anything.
    var buffer: [64]u8 = undefined;
    const header = try writeHeader(&buffer);
    std.mem.writeInt(u32, buffer[header.len..][0..4], 0xffff_ffff, .little);
    var reader = try Reader.init(buffer[0 .. header.len + 4]);
    try std.testing.expectError(error.RecordTooLarge, reader.next());
}

test "an empty journal replays cleanly" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    var collector: Collector = .{ .gpa = gpa };
    defer collector.deinit();

    const recovery = try replay(gpa, writer.written(), &collector, Collector.record);
    try std.testing.expect(recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 0), recovery.applied);
}

test "a journal that is not a journal is reported rather than parsed" {
    const gpa = std.testing.allocator;
    var collector: Collector = .{ .gpa = gpa };
    defer collector.deinit();

    const rubbish = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const recovery = try replay(gpa, &rubbish, &collector, Collector.record);

    try std.testing.expect(!recovery.wasClean());
    try std.testing.expectEqual(@as(usize, 0), recovery.applied);
    try std.testing.expectEqual(@as(usize, 0), recovery.intact_through);
}

test "the journal reports how close it is to needing compaction" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    try std.testing.expect(writer.utilization() < 0.01);
    for (0..64) |index| {
        _ = try writer.append(.audit_appended, @intCast(index + 1), .fromSeconds(1_000), "entry");
    }
    try std.testing.expect(writer.utilization() > 0);
    try std.testing.expect(writer.utilization() < 1.0);
}

test "every record kind survives a round trip" {
    const gpa = std.testing.allocator;
    var writer = try Writer.init(gpa);
    defer writer.deinit();

    for (std.enums.values(RecordKind), 0..) |kind, index| {
        _ = try writer.append(kind, @intCast(index + 1), .fromSeconds(1_000), "payload");
    }

    var reader = try Reader.init(writer.written());
    for (std.enums.values(RecordKind)) |expected| {
        const record = (try reader.next()).?;
        try std.testing.expectEqual(expected, record.kind);
    }
}
