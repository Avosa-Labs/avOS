# AvOS

An agent-native personal operating system in which humans, autonomous agents,
applications, services, organizations, devices, and virtual sessions are
first-class computing principals.

## Status

The trusted control plane, agent execution plane, runtimes, session continuity,
first-party applications, the store, the developer SDK, and the shell — including
a native, GPU-ready renderer that draws the designed interface — are implemented
and run. Every surface can be rendered from real control-plane state (see **See
the interface** below). What remains is on-device work: binding the render layer
to a real GPU driver (Vulkan/Metal) and a windowed input loop, and hardware
bring-up. Nothing here is production software, and no handset readiness claim is
made; read `docs/public/known-limitations.md` before drawing any conclusion.

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
tools/bootstrap/bootstrap.sh                              # POSIX hosts
export PATH="$(tools/bootstrap/bootstrap.sh --print-path):$PATH"
zig build doctor                                          # confirm the checkout
zig build simulator -- --scenario=canonical-demo          # run the demonstration
zig build test                                            # run the tests
infrastructure/ci/gates.sh                                # run every gate
```

Three scenarios run against real code, not mocks, and print what a person would
see:

```sh
zig build simulator -- --scenario=canonical-demo                     # the agent control plane
zig build simulator -- --scenario=boot --fault=tampered-control-plane  # a boot refused, with the recovery screen
zig build simulator -- --scenario=rollback --outcome=hangs-on-start    # a bad update rolled back
```

Bootstrap installs nothing system-wide. It resolves the exact compiler and
components pinned in `toolchain.lock.json`, verifies each digest before
extracting, and places them in a project-local ignored tool directory.

`docs/public/developer-quick-start.md` walks through all of this, including how
to read the demonstration's output.

## See the interface

The shell renders the designed interface to PNG images with no GPU and no image
library — the same display list a GPU backend consumes drives a software
rasterizer here, so a frame is a real, viewable artifact on any host. Open the
output with any image viewer (`open frame.png` on macOS).

The headline command plays the **live** session: it runs the canonical scenario
and renders each surface from that run's real audit ledger, registry, and store
decisions — the actual agents doing the actual work.

```sh
zig build run -- /tmp/avos_        # the whole live session, boot to rest, as frames:
                                   #   00_boot 01_home 02_activity 03_approval
                                   #   04_principals 05_store 06_rest
open /tmp/avos_01_home.png
```

Render one surface, live from the real run, or standalone from demonstration data:

```sh
zig build shell  -- home out.png          # a live surface: home|activity|approval|
                                          #   principals|store|boot|rest
zig build home   out.png                  # the home screen
zig build screen -- store out.png         # a shell screen: ledger|approval|
                                          #   principals|settings|store
zig build app    -- phone out.png         # an app screen: phone|messages|
                                          #   calendar|camera
zig build icons  out.png                  # the app icon sheet
zig build motion -- /tmp/m_ 10            # the agent-card entrance, as 10 animation frames
```

The design language, colours, and screen inventory are recorded in
`docs/design/ui-reference.md`; the concrete tokens live in `design/theme/`.

## Commands

```sh
zig build doctor          # report host, compiler, and pin health
zig build format          # apply canonical formatting
zig build format-check    # verify formatting without writing
zig build test            # unit tests
zig build brand-check     # verify no brand leak outside the brand layer
zig build standin-check   # verify no test stand-in reaches production code
zig build source-repro    # build twice and confirm one identical image
zig build image-build     # reduce a directory to a signed-ready image digest
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
| `graphics/` | the render layer: display list, software rasterizer, GPU instance encoder, icons, type, and the screens |
| `design/` | design tokens, the concrete theme, and accessibility rules |
| `shell/` | session shell surfaces and form-factor adaptations |
| `applications/` | first-party applications |
| `store/` | the application store |
| `session/` | personal compute instance and endpoint continuity |
| `sdk/` | developer platform (native, WASM, web, Android, Swift 6) |
| `emulator/` | the virtual device |
| `simulator/` | first implementation target; runs without AOSP; hosts the live shell renderer |
| `packaging/`, `infrastructure/` | release formats and operational runbooks |
| `tools/` | bootstrap, locking, signing, supply-chain, and inspection tools |
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

- `docs/public/developer-quick-start.md` — set up, run the demo, run the tests
- `docs/public/architecture-overview.md` — system topology and trust zones
- `docs/operations/build.md` — compiler support, pinning, and gates
- `docs/security/threat-model.md` — adversaries, assets, and boundaries
- `docs/public/known-limitations.md` — what this does not do
- `docs/decisions/` — architecture decision records
