# Known limitations

What this system does not do, stated plainly. A capability absent from this
repository is absent from this list only if it was never claimed anywhere.

The rule this document exists to enforce: a property without an automated or
reviewable verification path is not an implemented property, and nothing here
may be described as working on the strength of code existing.

## Not implemented

**Apple binary compatibility.** Unavailable, and displayed as unavailable. No
part of this system executes application binaries built for Apple platforms, and
none is planned until lawful execution is genuinely available. The repository
contains a neutral boundary for future portability work and no compatibility
layer, fake or otherwise.

**Android binary execution.** The permission mediation and the application
capability bridge are implemented and tested. Executing real application
binaries is not: it needs a reference device, which needs KVM on Linux, and the
checks that depend on it report as skipped by name rather than passing silently.
See `docs/decisions/0003-reference-device-image.md` for the eight items that must
pass before this changes.

**A rendering shell.** The shell's surfaces exist as state projections with an
accessibility contract, and a renderer boundary defines what a toolkit must
satisfy. No toolkit has been selected and nothing draws pixels. See
`docs/decisions/0002-shell-rendering-toolkit.md`.

**Google Mobile Services.** Not licensed, not integrated, not emulated. An
application depending on them is reported as unrunnable rather than started and
left to fail.

**A commercial application marketplace.** Package identity, signing,
verification, and downgrade refusal exist. Distribution, review, entitlements,
and commerce do not.

**Production cellular, emergency services, and carrier certification.** None of
these exist in any form. This system must not be relied on to place an emergency
call.

**Production payments.** The capability model expresses monetary limits and
time-boxed approval for value transfer. No payment integration exists.

**A hardware root of trust.** The verified boot chain exists and is exercised —
see `docs/architecture/boot.md` — but the keys each stage is verified against
are supplied to it rather than fused into hardware. Nothing stops a caller
supplying different ones, so the chain demonstrates that the logic is right, not
that a device is.

**A recovery image.** `boot_recovery_image` is a decision the chain reaches. No
image is loaded, verified, or run.

**Durable anti-rollback and boot counter state.** Both are values the caller
carries between boots rather than state held where the running system cannot
rewrite it. A caller that forgets them loses rollback protection and attestation
freshness together.

**Encrypted durable storage.** State lives in memory within a process. Nothing
is persisted, so nothing is encrypted at rest.

**A real secure element.** The interface exists and is the shape a hardware one
would take: no export operation, conditions enforced inside, purpose bound at
creation. The only implementation is in software, and it says so — keys are
readable by anything with access to process memory.

**Runtime integrity measurement.** Measurement covers load time. A stage that
verifies, runs, and is then compromised measures identically to one that was
not, so an attestation says nothing about what happened after boot.

**Measured energy and thermal figures.** The thermal *policy* exists and is
tested — the response ladder, hysteresis, per-zone thresholds, and the rule that
the device follows its hottest zone all live in `hardware/thermal/`. The
*numbers* do not: a power reading needs a rail sensor and a temperature reading
needs a real die, and this project has neither. No implementation reports a
plausible temperature on a host without a sensor, so nothing here can be
mistaken for a measurement that was never taken. See `docs/performance/budgets.md`.

**Persistence and crash recovery.** The task state machine is designed to
recover from durable state, and there is no durable state yet. A restart loses
everything.

## Implemented with a narrower scope than the words suggest

**Component isolation.** The native component host contains *failures* — a
trap, a budget overrun, a meter overrun, a denied resource — and leaves the host
running. It does not contain memory corruption, which needs a process or virtual
machine boundary. The WebAssembly runtime does provide that boundary for guest
code, and services run as separate operating-system processes.

**Concurrency.** Agent branches are independent and separately budgeted, and the
task graph models concurrent execution. Nothing runs on more than one thread. No
scheduler exists, and the scheduling classes are described but not enforced.

**The model adapter.** Deterministic and local, returning prepared answers. No
inference runs. The routing policy is expressed in types and is not exercised
against real providers.

**Connectors.** Fixed responses standing in for external services. Nothing
reaches a real calendar, mailbox, or routing service.

**Session transport.** The record layer is implemented and tested — end-to-end
encryption, per-direction keys, replay and reorder rejection. There is no
network: no sockets are opened, and no session has crossed a machine boundary.

**Compiler support.** Zig 0.16.0 is the canonical line and its lane is green.
0.15.2 and 0.14.1 are pinned and inside the supported window, but their
compatibility adapters do not exist, so the build fails closed on them. They are
not supported and are not described as such.

## Not measured

No performance claim is made anywhere in this repository. Cold boot, session
unlock, command latency, capability validation latency, IPC throughput, audit
append latency, memory per principal, cancellation latency, component startup,
and session handoff are all unmeasured. `docs/performance/budgets.md` does not
yet state thresholds, so nothing has been compared against one.

Where a figure appears in a test — peak memory in the simulator, for instance —
it is an assertion about that run on that machine, not a budget and not a claim.

## Not audited

No independent security assessment has been performed. The threat model
enumerates adversaries and boundaries, and the tests cover the mitigations that
exist, but neither is a substitute for review by someone who did not write the
code.

The weakest link in the dependency chain is the reference device image, whose
integrity would rest on trust on first use rather than on a publisher's
signature. It is recorded in ADR 0003 rather than left implicit.

## What is demonstrated

The canonical sequence runs end to end and is asserted step by step: a human
authenticates, a request becomes a visible task graph, four agents work
independent branches with different authority, an unauthorized action is denied
and recorded, a consequential action is held for a human, approval yields a
one-time task-bound capability, the approved action executes exactly once, the
session moves to a second endpoint without repeating it, cancelling the root
stops what remains and returns memory to baseline, and the whole execution
reconstructs from the ledger.

That is the claim. It is smaller than "an operating system", and it is the one
the tests support.
