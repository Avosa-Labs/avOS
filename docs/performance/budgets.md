# Performance budgets

A budget is a threshold set before the measurement, not a number recorded after
one. A figure produced first and declared acceptable afterwards is a
description, and a description cannot fail.

Every budget here was chosen from what the operation must feel like or must not
cost, and each says why. The `Status` column says whether it has been measured;
most have not, and saying so is the only honest thing it can say until the
benchmark exists.

## How to read this

**Budget** is the ceiling. Exceeding it fails the gate.

**Basis** is why that number and not another. A budget with no basis is a number
someone liked.

**Status** is one of:

- `not measured` — no benchmark exists yet
- `measured` — a benchmark exists and reports against the budget
- `provisional` — measured, but the budget itself is still a guess awaiting
  evidence from real use

Nothing may be described as meeting its budget while its status is
`not measured`. That is the whole point of separating the two columns.

## Interaction

These are the ones a person feels. The basis is human perception, not what the
implementation happens to achieve.

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| Command surface accepts a keystroke | 16 ms | One frame at 60 Hz. Slower than this and typing feels detached from the screen. | not measured |
| Command to first visible feedback | 100 ms | The threshold below which a response reads as instantaneous. | not measured |
| Task graph updates after a state change | 100 ms | Same threshold: agent activity must appear to happen as it happens. | not measured |
| Approval surface appears | 150 ms | A decision prompt that lags invites approving before reading. | not measured |
| Cancellation is visible | 100 ms | Cancellation must feel like it took, or a person cancels twice. | not measured |
| Session unlock to usable shell | 500 ms | Longer and unlocking feels like waiting rather than opening. | not measured |
| Surface renders at the largest text scale | 16 ms | Accessibility settings must not cost frames. | not measured |

## Control plane

These sit on the path of every privileged operation, so their cost multiplies by
everything the system does.

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| Capability validation | 10 µs | Twelve checks on every use. At 10 µs a thousand operations cost 10 ms; at 100 µs they cost 100 ms and the budget above is gone. | **measured** — p99 167 ns |
| Principal lookup | 5 µs | Expected constant time, on the same path. | **measured** — p99 83 ns |
| Task state transition | 20 µs | Includes the durable write that must precede belief. | **measured** — p99 83 ns |
| Audit append | 50 µs | Bounded, not merely amortized. Every privileged operation writes one. | **measured** — p99 416 ns |
| Task graph cancellation | 5 ms | Proportional to the subtree, never to unrelated tasks. | **measured** — unaffected by 2 000 unrelated tasks |
| Journal replay | 200 ms | Recovery happens at startup, where it competes with cold boot. | **measured** — linear in records replayed |

## Isolation and runtimes

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| IPC round trip, same host | 100 µs | Services talk constantly; this is the cost of the boundary being real. | not measured |
| IPC throughput, 64 KiB messages | 200 MiB/s | Enough that the boundary is not the limit for state synchronization. | not measured |
| Native component start | 1 ms | Cheap enough to start one per task rather than pooling. | not measured |
| WebAssembly component start, cached | 50 ms | Compilation dominates; this assumes an ahead-of-time artifact keyed by package identity. Without that cache the figure is seconds and the budget is unmeetable. | not measured |
| WebAssembly component start, cold | 2 s | The first run of a package, before its artifact is cached. | not measured |
| Epoch interruption reaches a guest | 10 ms | Cancellation must not depend on a component's cooperation, and must not take visibly long. | not measured |
| Service process spawn | 50 ms | Bounds how long a supervised restart takes to become useful. | not measured |

## Memory

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| Idle principal | 4 KiB | A device holds many. At 4 KiB a thousand principals cost 4 MiB. | not measured |
| Active agent task | 64 KiB | The default agent budget. Enough for retrieval and planning, small enough that a dozen agents fit comfortably. | not measured |
| Control plane at rest | 16 MiB | The trusted computing base must be small in memory as well as in code. | not measured |
| Task memory after cancellation | 0 bytes above baseline | Not a performance budget but a correctness one. Already asserted by the simulator and the acceptance tests. | **measured** |

## Session and continuity

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| Session handoff between endpoints | 2 s | Long enough to move state, short enough that continuity feels like continuity. | not measured |
| Transport record seal and open, 64 KiB | 1 ms | Session state moves in bulk; this must not become the limit. | not measured |
| Endpoint revocation takes effect | next operation | Not a duration. A revoked endpoint stops now, which is a correctness property. | **measured** |

## Startup and update

| Measurement | Budget | Basis | Status |
| --- | --- | --- | --- |
| Cold boot to lock surface | 3 s | Set against what a person tolerates from a device that was off, not against what the implementation manages. | not measured |
| Update staging, 1 GiB image | 60 s | Runs in the background; the ceiling exists so it cannot run indefinitely. | not measured |
| Update commitment | 100 ms | The atomic point. It must be short because a crash inside it is the hardest case to reason about. | not measured |
| Rollback to the previous slot | 5 s | Recovery must be faster than the failure it recovers from is annoying. | not measured |

## Energy and thermal

No budgets. Measuring energy needs hardware instrumentation this project does
not have, and a figure produced without it would be a guess wearing a number.

These are Phase A exit criteria and must be filled in before that exit is
claimed. Stating them as absent is more useful than stating them as unknown.

## What measuring changed

Three defects were found by the first measurement rather than by review, all on
the recording path every privileged operation takes.

**The ledger grew by reallocating one array**, so an append occasionally copied
every event already recorded. The median was acceptable and the tail was not:
p99 556 µs against a 50 µs budget, and getting worse the longer the system ran.
It now grows by adding segments, so an append never touches what is already
there.

**Identity was drawn from the generator once per identifier**, putting a cipher
invocation on the path of every issue. Identifiers are now drawn a block at a
time — same generator, same entropy, fewer calls.

**Target kinds were copied per event**, storing the same short string thousands
of times and allocating on the recording path. They are now stored once each.

Together: audit append went from a median of 8 833 ns and a p99 of 190 250 ns to
a median of 41 ns and a p99 of 416 ns.

None of this was visible without a stated budget to fail against. That is the
argument for writing the budget first.

## Method

Recorded here so a measurement means the same thing twice.

Benchmarks run with a deterministic clock and a fixed identifier seed, so a run
is comparable to the run before it.

**Budgets are checked only in a release build.** Timing unoptimized code against
a budget meant for a shipped system measures the compiler's debug output, so a
debug run reports its figures and states that it did not check them:

```sh
zig build test -Doptimize=ReleaseSafe    # measures and enforces
zig build test                           # reports, does not enforce
```

Safety checks stay on. Measuring with them off would measure something the
platform never runs. Each reports the
median and the 99th percentile: a median within budget and a tail far outside it
is a system that feels unreliable, and reporting only the median hides exactly
that.

A budget is checked against the 99th percentile unless the row says otherwise.
The interaction budgets in particular are about the worst case a person
encounters, not the average one.

Comparisons are against the previous commit on the same host. A regression is a
change that moves a figure outside its budget, or that moves it by more than
20% while remaining inside — the second is a warning rather than a failure,
because a large move within budget is usually the start of a trend.

Nothing in this document may be cited as evidence of performance until the
`Status` column says `measured`.
