# Compatibility

Compatibility is layered and **honest**. A boundary here is represented as
implemented only when it genuinely is; everything else is a prepared integration
point stated as such, never claimed as working. This is a hard rule: a
compatibility surface that fails closed with an actionable message is correct,
and one that pretends to support what it cannot is a defect.

## State of each boundary

| Boundary | Purpose | State |
| --- | --- | --- |
| `zig/0_16` | The canonical compiler line adapter | Implemented |
| `zig/0_15` | Compatibility compiler line | Pinned in `toolchain.lock.json`; adapter not implemented; build fails closed |
| `zig/0_14` | Compatibility floor compiler line | Pinned; adapter not implemented; build fails closed |
| `zig/candidate` | A new stable release under evaluation | Enters here before being claimed as supported |
| `zig/tests` | Cross-line adapter conformance | Runs against implemented lines only |
| `libc` | C standard library surface for native components | Prepared integration point |
| `linux` | Linux syscall/ABI surface | Prepared integration point |
| `aosp` | Android compatibility runtime surface | Runtime exists; this boundary tracks AOSP-side integration |
| `hardware` | Hardware abstraction conformance | Prepared integration point |

## The rule for compiler lines

A compiler line is claimed as supported only when its complete lane is green:
formatting, build, tests, fuzz, and the gates. `0_15` and `0_14` sit inside the
supported window and are pinned, but their adapters do not exist yet, so the
build fails closed on them rather than claiming support it cannot demonstrate.
Prereleases never enter the matrix; a development snapshot is rejected by
construction.

## Apple compatibility

Apple application compatibility remains a prepared integration boundary and MUST
NOT be represented as implemented until lawful binary execution is genuinely
available. The `runtimes/apple-portability` layer prepares for it without
claiming it.
