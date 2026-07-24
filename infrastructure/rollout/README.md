# Rollout infrastructure

How a release advances from the build host to devices. Rollout exists so that a
fault reaches as few devices as possible before it is caught: exposure widens
only behind evidence that the smaller populations ahead are healthy.

## Rings

A release advances through rings of increasing exposure:

1. **Internal** — the platform's own devices.
2. **Canary** — a small opt-in population.
3. **Staged** — a growing fraction of general devices.
4. **General** — all devices on the channel.

## Promotion gate

Advancing from one ring to the next is earned, not scheduled. Each ring must:

- **Soak** — observe the build for at least the ring's minimum duration.
- **Stay healthy** — no regression in the crash rate or the critical signals the
  ring watches, against the prior release as baseline.

A ring that has not soaked long enough **holds**. A ring that regresses
**rolls back** — a bad build does not earn wider exposure by waiting. The
promotion decision is the `packaging/policies/rollout` module.

## Rollback

Rollback is always available and always to a known-good version. A device that
receives a rollback instruction reverts to the previously installed build, which
is known-good because the device was running it before the update. The update
path's trial-boot fallback (`packaging/recovery/fallback`) handles the device
that cannot boot the new build at all.

## Invariant

No build reaches a wider ring than one it has cleanly survived, and every device
can always return to a version that boots.
