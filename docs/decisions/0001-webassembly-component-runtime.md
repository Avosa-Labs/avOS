# ADR 0001: WebAssembly component runtime

- Status: proposed
- Date: 2026-07-22
- Affects: trust boundary, dependency, public API

## Context

The platform needs a runtime for portable third-party components that is
sandboxed by construction rather than by convention. Three properties are
required and are not negotiable:

The runtime must deny ambient authority. A component gets no filesystem, no
network, no clock, no randomness, and no environment unless the host supplies
it through an explicit interface. Anything less means the sandbox is a policy
the component can be tricked into escaping rather than a boundary it cannot
address.

The runtime must meter memory and execution, and must interrupt a component
that does not yield. The native host already bounds a component with a budget
and a step meter, but a cooperative meter only bounds code the host compiled.
Third-party code needs interruption the component cannot decline.

The runtime must contain a trap. A component that faults must not corrupt the
host, and the host must continue to run other components afterwards.

The native component host in `runtimes/native/` provides failure containment
within one address space. It does not provide memory-safety isolation: a
component that corrupts memory is outside what a function-call boundary can
defend. That gap is the reason this decision exists.

## Decision

Adopt Wasmtime as the WebAssembly Component Model host, consumed through a
Zig-owned adapter in `runtimes/wasm/host/`, with host capabilities exposed only
through narrow interfaces defined in `runtimes/wasm/wit/`.

The adapter owns the boundary. It defines allocation ownership, thread
requirements, initialization and shutdown, error translation, callback
lifetime, cancellation, the ABI pin, the version pin, and the security update
path. No Wasmtime type crosses into `core`, and no core type is defined in
terms of one.

The host interface decides what resources exist. A component declares what it
wants in its package manifest; the manifest is a request, and the grant is a
separate policy decision already modelled in `core/package/` and
`core/capability/`. The runtime therefore starts every component with an empty
resource set and adds only what policy granted.

Execution is bound to a task cancellation token through epoch interruption, so
a component that never yields is still interrupted. Memory is bounded by the
store's own limits in addition to the budget the host accounts against, because
a limit the guest cannot observe is the only kind it cannot plan around.

## Alternatives

**A Zig-implemented WebAssembly interpreter.** Removes a large C dependency and
keeps the trusted computing base in one language. Rejected on effort and risk:
a correct, secure, and adequately fast implementation of the Component Model is
a multi-year project whose defects would be ours alone, and the platform's
scarce review capacity is better spent on the authority model than on
re-implementing a specification that has mature hosts.

**WAMR or wasm3.** Smaller and simpler to embed. Rejected because Component
Model support and resource-limit maturity are behind what the interface design
depends on; the component model is not an optional convenience here, it is how
capabilities are expressed at the boundary.

**Extending the native host to a process boundary and skipping WebAssembly.**
Genuine isolation using facilities the operating system already provides.
Rejected as insufficient rather than wrong: it gives isolation but not
portability, and third-party components must run unchanged across the
architectures the platform targets. This remains the right mechanism for
first-party native components and is already the direction of
`runtimes/native/`.

## Consequences

Makes possible: portable third-party components with per-component resource
denial, interruption that does not depend on the component cooperating, and
trap containment that survives a hostile guest.

Makes harder: the build acquires a C toolchain dependency and a large external
component that must be pinned by exact version and digest, tracked for security
advisories, and upgraded as a deliberate migration. Cross-compilation for every
supported target becomes a build concern rather than a Zig-only concern.

Forecloses: nothing structural. The adapter boundary is narrow enough that
replacing the host later is a contained change, which is the reason for
insisting on it.

This adds no code to the trusted computing base. The runtime sits in the
application and compatibility plane, and it is never an authorization
authority: it asks the control plane, and the control plane decides.

## Security implications

Boundaries touched: control plane to isolated runtime, and package publisher to
installed package.

Introduced: a large external attack surface written in another language,
reached by untrusted guest bytecode. This is accepted because the alternative —
our own interpreter — has a worse expected defect rate, and because the
component is widely deployed and actively reviewed.

Removed: the assumption that a component stops when asked. Epoch interruption
makes that enforceable rather than cooperative.

Assumption added: Wasmtime's sandbox holds for a hostile guest. That assumption
must be tracked as a dependency risk with a security-advisory watch, not
treated as settled.

## Resource implications

Expected input size: component modules in the low tens of megabytes. Startup is
dominated by compilation, so ahead-of-time compilation with a cached artifact
keyed by the package identity is required before this reaches an interactive
surface. Per-instance memory is bounded by the store limit; the host accounts
the same allocation against the component's budget so one accounting is
authoritative.

No performance claim is made here. The startup and per-call figures belong in
`docs/performance/benchmarks.md` once measured, and this decision must not be
cited as evidence for any number.

## Verification

Required before this moves from proposed to accepted:

- a component denied filesystem, network, clock, randomness, and environment
  access it did not declare, asserted per resource class
- a component that never yields, interrupted by epoch and reported as
  interrupted rather than as completed
- a trapping component leaving the host operable, with a following component
  running normally
- a component exceeding its memory limit stopped at the limit
- cancellation of the owning task interrupting the component
- an unsigned or untrusted component package refused under policy
- shared test vectors covering the host interface, including malformed and
  adversarial components

Until every one of these passes, the WebAssembly runtime is not implemented and
must not be described as available.

## Migration

Not applicable: no wire identifier, package identity, signing domain, or disk
format is affected. The pin itself is recorded in `toolchain.lock.json` and
changing it follows the ordinary upgrade discipline.
