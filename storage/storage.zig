//! Durable state.
//!
//! Every persistent store defines its owner, schema, format version, integrity,
//! growth ceiling, and how it recovers from damage. State transitions are
//! written before they are believed, and a record that does not verify is not a
//! record: recovery stops at the first failure with everything before it
//! intact.
//!
//! Durable mutations identify what they do rather than when they happened, so
//! replaying a journal after a crash reaches the same state as replaying it
//! twice and an external effect is performed once.

pub const journal = @import("journal/journal.zig");
pub const object = @import("object/object.zig");
pub const quota = @import("quota/quota.zig");
pub const encryption = @import("encryption/encryption.zig");
pub const block = @import("block/block.zig");
pub const integrity = @import("integrity/integrity.zig");
pub const path = @import("filesystem/path.zig");
pub const concurrency = @import("database/concurrency.zig");

test {
    _ = journal;
    _ = object;
    _ = quota;
    _ = encryption;
    _ = block;
    _ = integrity;
    _ = path;
    _ = concurrency;
}
