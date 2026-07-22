# Secure boot and attestation

What a device can prove about itself, to whom, and what that proof does not
cover.

For how the chain works mechanically, see
[../architecture/boot.md](../architecture/boot.md). This document is about the
security properties and, more importantly, their limits.

## What is claimed

**A stage that fails verification does not run.** Not "runs with a warning", not
"runs in a degraded mode". A boot that proceeds past a failed verification has
verified nothing, because the check was advisory. The chain returns an error
rather than a verdict a caller could ignore, and there is no path in
`boot/recovery/` that selects the stage that failed.

**A downgrade is refused even when correctly signed.** The anti-rollback floor
is checked before the signature, so a genuine older image with a known flaw is
refused on the same terms as a forged one.

**What ran is recorded, not what was supposed to run.** Measurement precedes the
transfer of control, so the log survives the stage it describes failing.

**A remote party can tell which stages ran.** Two devices that both booted three
correctly signed stages produce different measurement summaries if the stages
differed. A verifier that only checked signatures could not tell them apart.

## What is not claimed

**An attestation does not say the device is safe.** It says what ran. Whether
that is acceptable is a judgement, and a verifier that reads "signature valid"
as "device trustworthy" has skipped the only part that required judgement. This
is why `attestation.verify` returns the measurement summary rather than a
boolean: a caller has to look at what booted in order to use the result at all.

**Measurement does not detect what happens after boot.** A stage that verifies,
measures, runs, and is then compromised at runtime measures exactly the same. The
chain covers load time and nothing else.

**Nothing here defends against an attacker who can rewrite the root of trust or
the fused keys.** That is the assumption the whole structure rests on, and it is
a hardware property this repository does not implement.

## Freshness and replay

A quote answers a challenge the verifier chose. The device does not supply its
own nonce, because a device that did would be attesting to its own timeliness,
which is the thing in question.

Two mechanisms, covering two different replays:

| Attack | Refused by |
| --- | --- |
| a quote captured from another exchange | the nonce, which is inside the signature |
| a quote from an earlier boot of the same device | the boot counter, which the verifier remembers |

Presenting the same quote twice against the same challenge is also refused: the
boot it describes has already been accounted for.

Every field of the statement is fixed-width and covered by the signature, so no
two distinct statements produce the same signed bytes by moving a boundary
between fields. The signature is over a domain-separated statement, so a quote
can never be presented as some other signature the same key produced.

## Where the key lives

The attestation signer is an **interface**, not a key. The whole value of an
attestation rests on the signing key being somewhere the software making the
statement cannot read, so substituting a key in memory must be a visible change
rather than an invisible one.

`hardware/secure-element/` defines that interface. Three properties are
structural rather than conventional:

- **There is no operation that returns key material.** Not a restricted one, not
  a privileged one, not one for backup. An interface with an export function is
  an interface that can be talked into exporting. A test enumerates the vtable
  and fails if such a function is ever added.
- **Conditions are enforced inside the element.** A condition the caller checks
  is a condition an attacker who controls the caller does not have. Device
  unlock, recent authentication, and use limits are all checked against what the
  element observes, not what the caller reports.
- **A key declares its purpose when created and is checked again at every use.**
  A single key that signs both attestations and user data lets anyone who can
  obtain one obtain the other.

Substituting a stand-in is also a *gate* rather than a matter of care. The
software element, the hand-advanced clock, and the seeded generator may not be
named on any path a device could execute — `zig build standin-check` computes
which lines those are, treating a private declaration that only tests refer to
as test support, so a helper cannot be moved onto a production path by renaming
it.

`Backing` is reported, never assumed. The software element says it is software
and always will: a stand-in that claimed to be hardware would let every layer
above it be tested against a guarantee it was not getting. A remote verifier
deciding how much a signature is worth needs to know which it is.

## Who may use a key

`security/keystore/` answers a question the element cannot: who is asking. Both
checks apply and neither substitutes for the other.

- An element that trusted the caller's word about identity would protect nothing
  from a compromised caller.
- A keystore over an element that handed out key material would protect nothing
  from anyone.

A key belongs to exactly one principal. A principal asking for another's key is
told the key is unknown, because saying "not yours" would confirm it exists.
Removing a principal destroys its keys: a key that outlives its owner is a key
nobody is accountable for.

Sharing is delegation of the *operation*, never of the key. An
`AttestationDelegate` fixes the owner and the key name when it is made, so what
gets passed around is permission to ask for one signature under one key for one
purpose, and the holder cannot widen it.

## Current gaps

Stated plainly because a security document that omits them is worse than none.

| Gap | Consequence |
| --- | --- |
| No hardware root of trust | Stage keys are supplied, not fused. Nothing prevents supplying different ones. |
| Software secure element only | Keys are readable by anything with process memory access. The interface is right; the backing is not. |
| Rollback floors and boot counter are values, not durable state | A caller that forgets them loses anti-rollback and freshness. |
| No recovery image | `boot_recovery_image` is a decision reached, not an image loaded and verified. |
| No runtime integrity measurement | Post-boot compromise is invisible to the attestation. |

Every one of these is a Phase A exit criterion. Until they close, an attestation
from this system proves that the *logic* is right, not that a device is.
