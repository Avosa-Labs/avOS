# ADR 0004: Vulkan is the primary GPU API, behind a Zig device adapter

- Status: accepted
- Date: 2026-07-26
- Affects: dependency, public API

## Context

ADR 0002 deferred the rendering toolkit and built only the renderer boundary.
The graphics rebuild now takes the decision that deferral left open: a retained
Zig compositor owns every frame, and the engines that put pixels on a GPU are
libraries behind Zig adapters, not the architecture. That requires naming the
GPU API the device layer targets.

The requirements are fixed by the rest of the system, not by preference. The
compositor already produces an ordered, culled layer list and presents through a
presentation interface with a mailbox present mode; the device must express that
directly. The frame budget is a 120 Hz surface, so the API must allow explicit
submission and synchronisation rather than a hidden driver heuristic. The colour
pipeline is linear-light with a wide-gamut target, so the swapchain must carry
half-float and a P3/HDR format. The platform ships to Linux and to reference
hardware without a vendor runtime baked into the image.

A dependency in this system is latest-stable and exactly pinned, resolved from
the project's official source, with its digest and licence recorded — the same
rule the toolchain follows.

## Decision

Vulkan is the primary GPU API. The device layer binds against the Khronos
Vulkan-Headers, pinned in `engines.lock.json` to a Vulkan-SDK-aligned tag with
the upstream archive's SHA-256 and its Apache-2.0 licence recorded. Vulkan is a
calling convention, not a library: the loader is the platform's own `libvulkan`,
resolved at runtime, so no binary is vendored — only the API definition is
pinned.

The binding lives behind a Zig adapter at `graphics/device/vulkan`. Vulkan C
types do not cross that boundary; the compositor and the rest of the system see
only the Zig device and the presentation interface. A host without a Vulkan
loader still builds and runs — the adapter is compiled and its device
initialises only where a loader is present, the same shape the WebAssembly
runtime uses for its native library (ADR 0001).

The `engine-lock` gate holds the manifest to this rule: every pinned engine
carries a source, a digest, a licence, an adapter, and an ADR, or the build
fails.

## Alternatives

**OpenGL / OpenGL ES.** Rejected on the frame budget: the driver owns
submission and synchronisation, so the explicit timeline the 120 Hz present path
needs cannot be expressed. It also does not carry a first-class wide-gamut HDR
swapchain across the target platforms.

**WebGPU (Dawn/wgpu).** A portability layer over Vulkan/Metal/D3D. Rejected as
the *primary* API because it adds a second translation the device does not
control, and its present and synchronisation surface is narrower than the
mailbox timeline the compositor already assumes. Metal is reached directly in a
later record, not through a portability layer.

**A vendored Vulkan loader binary.** Rejected because the loader is a system
component tied to the installed driver; vendoring one would ship a loader that
does not match the host's ICD. Only the API definition is pinned.

## Consequences

Makes explicit submission, timeline synchronisation, and a wide-gamut HDR
swapchain expressible, and keeps the vendor runtime out of the image. Makes the
device harder to bring up than a driver-managed API, and requires the adapter to
resolve the loader at runtime and degrade cleanly where it is absent. Forecloses
treating the GPU API as the architecture: it is an engine behind the adapter,
and the prohibitions gate keeps a second renderer from entering beside it.

Adds no code to the trusted computing base beyond the adapter: the loader runs in
the same process but the adapter is the only surface that speaks to it, and the
compositor's decisions are made before the device is called.

## Security implications

The adapter loads a system library by name at runtime. It resolves `libvulkan`
through the platform loader only — no caller-supplied path — so the boundary it
introduces is the trust already placed in the installed driver, not a new one. A
capture path's secure-layer rule is enforced in the compositor before the device
sees a frame, so the device cannot leak a protected layer.

## Resource implications

The pinned headers are a ~3 MB source archive, fetched and digest-verified into
a build cache when the device is built, not committed. At runtime the device
holds one logical device and a swapchain sized to the surface; submission is per
damaged frame, and an idle frame submits nothing (the scheduler's zero-idle-GPU
property). No persistence.

## Verification

`engine-lock` verifies the manifest: each engine has a source on its upstream
host, a 64-hex SHA-256, a 40-hex commit, an SPDX licence, an adapter path, and
an ADR file that exists. `version-lock` re-resolves pins from official sources on
demand. The device adapter's own tests run where a loader is present; the
presentation interface's `mayShip` test already proves a dev-host surface never
ships, and that policy covers the software fallback the device replaces.

## Migration

New pin, no shipped identifier changes. Raising the pinned Vulkan-SDK tag updates
`engines.lock.json` and is reviewed as a deliberate change; the API is
backward-compatible within a major version, so a device built against an older
header set runs against a newer loader.
