# Native application example

A native component built against the native SDK — the highest-performance way to
extend the platform, and the one held to the strictest ABI discipline.

## What it demonstrates

- **C ABI exact match.** A native component loads only when its declared ABI
  matches the runtime's exactly; a mismatch is refused rather than loaded into an
  incompatible interface (`sdk/c/abi`).
- **Capability handles, not pointers.** The component receives opaque capability
  handles across the boundary, never privileged object pointers, so it can act
  only through authority it was granted (`ipc/` boundary, `test-vectors/ipc`).
- **Declared capabilities.** The component declares the capabilities it uses; the
  platform holds it to that declaration.

## Manifest sketch

```
component: native
abi: platform-1
capabilities:
  - display.surface: present
entry: component_main
```

## Expected behavior

The component loads when its ABI matches and its manifest is coherent; it renders
through the granted surface handle. An ABI mismatch, or an attempt to use a
capability it did not declare, is refused at the boundary.
