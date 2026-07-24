# Update infrastructure

How a device moves from one system version to the next without ever being left
unbootable or running a half-applied build. The update path's contract is that
an interruption at any point leaves the device booting a single consistent
version.

## Two slots

A device holds two system slots: the one it runs and the one an update is
written into. An update never overwrites the running slot in place, so the
running system is intact throughout.

## Sequence

1. **Fetch and verify** — the image is fetched, its digest measured, and its
   manifest and signature checked (`packaging/manifests/manifest`). A mismatch
   refuses the update before anything is committed.
2. **Write** — the image is written to the inactive slot. The active slot is
   untouched.
3. **Commit point** — a single atomic switch marks the updated slot as the one
   to boot next. Before this point, an interruption boots the old slot; after it,
   the new slot. There is no in-between.
4. **Trial boot** — the updated slot boots on trial and must confirm a healthy
   boot within a bounded number of attempts (`packaging/recovery/fallback`). If
   it confirms, the update is committed. If it exhausts its attempts, the device
   falls back to the previous slot.

## Guarantees

- **Anti-rollback** — an update never installs a version older than the one
  installed, and never changes signer.
- **No partial state** — power loss at any moment boots one consistent version,
  never a mixture.
- **Recoverable** — a build that installs but does not boot sends the device back
  to a version that does.

## Invariant

After any update attempt — successful, interrupted, or failed — the device boots
a single, signed, consistent system version.
