# WebAssembly component example

A portable component that runs in the WebAssembly runtime — the sandboxed,
architecture-independent way to extend the platform, with the strongest
containment.

## What it demonstrates

- **Deny-by-default imports.** The component declares the host interfaces it
  needs. An import the host does not supply is refused, so a component that asks
  for the filesystem, network, clock, or randomness without it being granted is
  denied — the `test-vectors/component` vectors pin this exactly.
- **Bounded execution.** The runtime meters the component: unbounded work is
  interrupted (fuel exhausted or a deadline), and a trap — unreachable, out of
  bounds, divide by zero, stack exhaustion — is contained, not propagated.
- **Append-only interface evolution.** The component's interface version is
  checked for compatibility; the interface may grow but never break existing
  callers (`sdk/wit/interface`).

## Manifest sketch

```
component: wasm
interface: 3
imports:
  - clock            (must be supplied by host)
entry: run
```

## Expected behavior

A component importing only supplied interfaces runs, metered and contained. One
importing an unsupplied interface is refused. A trap is contained and the rest of
the system is unaffected — the `runtime fault leaves the shell unaffected`
acceptance criterion.
