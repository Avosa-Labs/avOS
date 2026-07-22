# AvOS

An agent-native personal operating system in which humans, autonomous agents,
applications, services, organizations, devices, and virtual sessions are
first-class computing principals.

## Status

Milestone 0 — repository and toolchain. The trusted control plane, agent
execution plane, runtimes, shell, and session continuity are not implemented
yet. Nothing here is production software, and no compatibility or handset
readiness claim is made.

Qualified compiler lanes:

| Zig line | Role | Lane |
| --- | --- | --- |
| 0.16.0 | canonical | green |
| 0.15.2 | compatibility | not yet qualified |
| 0.14.1 | compatibility floor | not yet qualified |

A compiler line is claimed as supported only when its complete CI lane is
green. See `docs/operations/build.md`.

## Setup

The repository builds from a clean checkout with no private machine state.

```sh
tools/bootstrap/bootstrap.sh     # POSIX hosts
tools/bootstrap/bootstrap.ps1    # Windows hosts
```

Bootstrap installs nothing system-wide. It resolves the exact compiler pinned
in `toolchain.lock.json`, verifies its digest, and places it in a project-local
ignored tool directory.

## Commands

```sh
zig build doctor          # report host, compiler, and pin health
zig build format          # apply canonical formatting
zig build format-check    # verify formatting without writing
zig build test            # unit tests
zig build brand-check     # verify no brand leak outside the brand layer
zig build version-lock    # re-resolve the toolchain manifest for review
```

Every command accepts `--help`, returns meaningful exit codes, and runs
noninteractively.

## Navigation

| Path | Contents |
| --- | --- |
| `brand/` | brand resource layer; the only place product naming lives |
| `compat/` | compiler and host compatibility boundary |
| `core/` | domain model; depends only on the standard library |
| `services/` | trusted control-plane services |
| `agents/` | agent execution plane |
| `runtimes/` | native, WebAssembly, Android, and web runtimes |
| `shell/` | session shell surfaces |
| `session/` | personal compute instance and endpoint continuity |
| `sdk/` | developer platform |
| `simulator/` | first implementation target; runs without AOSP |
| `tools/` | bootstrap, locking, signing, and inspection tools |
| `docs/` | architecture, security, design, and operations documentation |

## What is demonstrated

The canonical sequence runs end to end, asserted step by step: a human
authenticates, a request becomes a visible task graph, four agents work
independent branches with different authority, an unauthorized action is denied
and recorded, a consequential action is held for a human, approval yields a
one-time task-bound capability, the approved action executes exactly once, the
session moves to a second endpoint without repeating it, cancelling the root
stops what remains and returns memory to baseline, and the execution
reconstructs from the ledger.

```sh
zig build simulator -- --scenario=canonical-demo
```

Read `docs/public/known-limitations.md` before drawing any wider conclusion. It
states plainly what is not implemented, what is narrower than its name suggests,
and what has never been measured.

## Documentation

- `docs/public/architecture-overview.md` — system topology and trust zones
- `docs/operations/build.md` — compiler support, pinning, and gates
- `docs/security/threat-model.md` — adversaries, assets, and boundaries
- `docs/public/known-limitations.md` — what this does not do
- `docs/decisions/` — architecture decision records
