# Boot

How a device gets from powered-off to a running control plane, and what it can
say afterwards about what it ran.

Implemented in `boot/`. To watch it happen, see
[developer-quick-start.md](../public/developer-quick-start.md#watch-a-boot-fail).

## The chain

Four stages, in a fixed order. Each verifies the next before handing control to
it, and measures it before it does.

| Stage | Verified by | Can load a recovery image |
| --- | --- | --- |
| `root_of_trust` | nothing — fixed in hardware | no |
| `bootloader` | the root of trust | no |
| `kernel` | the bootloader | yes |
| `control_plane` | the kernel | yes |

The order is fixed rather than discovered, so a stage cannot be skipped by
arranging for it to be reached out of turn. Offering the kernel first is refused
as `OutOfOrder`, not accepted as a shortcut.

The root of trust is taken as given. It is whatever the hardware provides, and
`boot/` never verifies or replaces it: a chain that could establish its own root
would be a chain an attacker could re-root.

## Verification and measurement are different questions

**Verification** asks whether a stage is one this device accepts. It is a
decision with no side effects, which is why it lives in `boot/verified/` and
returns a value rather than mutating anything. A stage is acceptable when all
three hold:

1. it is signed by the key its position accepts,
2. the signature covers the digest of exactly the bytes that will run, and
3. its version is no older than one this device has already booted.

All three matter. A signature alone lets an attacker reinstall a genuine image
with a known flaw. A version alone permits anything.

**Measurement** records which stage actually ran. It lives in
`boot/measurements/` and happens *before* control is handed over, so the log
describes what ran even when what ran then fails. A log written afterwards would
be written by the stage it is supposed to describe.

A device that only verifies can say it booted something acceptable. One that
measures can say *which*. That difference is the entire value of an attestation.

## The summary

The measurement log folds into a single value by extending a hash with each
entry's stage, digest, and version in order. Two boots that loaded the same
stages in a different order produce different summaries, and a boot that measured
nothing does not summarize to the same value as one that completed.

`security/attestation/` quotes this value. See
[../security/secure-boot.md](../security/secure-boot.md).

## Anti-rollback

Each stage carries a floor: the highest version this device has seen for it. The
floor never falls, and it lives in storage the running system cannot rewrite
freely — a floor a compromised system could lower would not be a floor.

The floor is checked *before* the signature. An image the device must not run is
refused whether or not it is correctly signed, so a valid signature never buys a
downgrade.

## When it stops

`boot/recovery/` chooses what happens, and the choice depends on how far the
chain got. The earlier the failure, the *fewer* options exist, because less of
the device can be trusted to carry out the recovery.

| Failure | Before the kernel | From the kernel onward |
| --- | --- | --- |
| signature rejected | previous slot, else halt | recovery image, else previous slot, else halt |
| rollback refused | halt | recovery image, else halt |
| out of order | halt | halt |
| unmeasurable | halt | halt |

Three things worth noting:

- **A refused downgrade never falls back to the previous slot.** That slot is
  older still and would be refused for the same reason; offering it would be a
  loop rather than a recovery.
- **An unverified recovery image is not a recovery path.** It is another
  unverified stage.
- **A stage that could not be measured does not run**, however verifiable it is.
  A measurement that is missing and one that is absent look identical to a
  verifier afterwards.

Halting is a real outcome, not a bug. It is worse for the owner than a working
device and better than an untrustworthy one.

## The screen

`boot/early-ui/` draws what a person sees. It runs before there is a compositor,
a font stack, a design token layer, or an allocator, and depends on none of
them: a surface that needs the system to be working cannot report that the
system is not working.

It renders text into a fixed buffer sized to the smallest panel this platform
expects to boot on, so the message reads the same on every device and a support
conversation can refer to it.

Two deliberate absences:

- **No option to continue anyway.** An option a person can press is an option an
  attacker can arrange to have pressed. This is asserted by a test that sweeps
  every failure and every outcome looking for the words.
- **No product name.** The brand layer is a resource loaded by a system that is,
  at this point, not running.

A halted device shows a support code and says to quote it. Where no code exists
it does not ask for one — telling someone to quote a code that is not shown
sends them into a support call already stuck.

## What is not here yet

- No real hardware root of trust. The stage keys are supplied to the chain
  rather than fused, because there is no board yet.
- No recovery image. `boot_recovery_image` is a decision the chain reaches, not
  an image it loads.
- The persistent state — the rollback floors and the boot counter — is a value
  the caller carries, not something written to storage the running system cannot
  reach.

These are Phase A exit items and are also listed in
[../public/known-limitations.md](../public/known-limitations.md).
