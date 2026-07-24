//! The application store.
//!
//! The store is the gate between a developer's submission and a person's device, and its whole
//! promise is that installing from it is safe. The modules decide rather than distribute: whether
//! an app passes review, is signed by a registered developer and countersigned by the store,
//! justifies the entitlements it requests, clears an account's content restriction, is offerable
//! to a device, and may be updated. The security floor runs through it — a distributed build is
//! always the reviewed one from a known developer, an update never changes signer or downgrades,
//! and a purchase is charged exactly once — testable without a storefront.

pub const review = @import("review/review.zig");
pub const signing = @import("signing/signing.zig");
pub const entitlements = @import("entitlements/entitlements.zig");
pub const rating = @import("policy/rating.zig");
pub const distribution = @import("distribution/distribution.zig");
pub const commerce = @import("commerce/commerce.zig");
pub const appeal = @import("appeal/appeal.zig");
pub const catalog = @import("catalog/catalog.zig");
pub const update = @import("update/update.zig");

test {
    _ = review;
    _ = signing;
    _ = entitlements;
    _ = rating;
    _ = distribution;
    _ = commerce;
    _ = appeal;
    _ = catalog;
    _ = update;
}
