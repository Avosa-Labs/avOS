# ADR 0009: Two on-device model tiers, one adapter, selected by device memory

- Status: accepted
- Date: 2026-07-29
- Affects: agent runtime, provisioning

## Context

The default mind is local, keyless, and offline (ADR 0008 pins the llama.cpp
runtime). But one fixed weight size cannot serve every device. A model small
enough for a memory-tight phone plans poorly, and an agent that plans poorly is
the one thing a demo cannot afford; a model large enough to plan well does not
fit a phone's RAM beside the compositor and apps. The runtime is one adapter; the
weights are data. So the choice is not one model — it is a tier selected per
device, both behind the same adapter.

Which open-weights families to run is, per the standing instruction, an owner
preference among real options; absent a stated preference the choice is proposed
here and taken, not deferred.

## Decision

Two tiers, both loaded through the existing `agents/model/local/llama` adapter,
selected at provision time from the device's memory:

- **Pitch/dev tier** — Qwen2.5-7B-Instruct, 4-bit (`q4_k_m`), roughly 4–5 GB of
  weights. Strong enough to plan a trip, screen a call, and reason over a real
  inbox — the quality the pitch rests on.
- **Constrained tier** — Qwen2.5-1.5B-Instruct, 4-bit, for memory-tight devices.
  The same adapter and seam; only the weight file differs.

The Qwen2.5-Instruct family is the choice because it is **Apache-2.0** —
permissive to ship in the image with no per-user account, key, or click-through —
and it spans both tiers from one family, so behaviour is consistent across
devices. `agents/model/local/tier.zig` makes the selection: a device with at
least 8 GiB runs the pitch tier, otherwise the constrained tier — one comparison,
decided once at provision, never re-probed per request. `model.describe`
validates the chosen weight file before the adapter binds it.

Weights are provisioned into the image or fetched once from a pinned,
digest-verified source and cached — never re-fetched, never a network dependency
at inference time. No API key, no account.

## Alternatives

**Pin a single arbitrary size.** Rejected: one size either underserves roomy
devices (dumb agents) or overshoots tight ones (thrash). A tier per device is the
honest fit.

**Llama-3.x or Gemma families.** Rejected as the default *only* on licence
grounds: their community/Gemma licences carry conditions that complicate shipping
weights in an image freely. They remain swappable-in through the same adapter for
anyone who prefers them — that is the point of the seam — but the keyless default
should be unencumbered, which Apache-2.0 Qwen2.5 is.

**Select by a runtime benchmark instead of RAM.** Rejected: a provision-time
probe is slower and non-deterministic; memory is the binding constraint for
whether a model fits, and it is known at provision.

## Consequences

Every device gets the strongest local mind it can actually hold, from one family
behind one adapter, so nothing above the seam knows which tier ran. The pitch
demo shows a genuinely capable offline agent; a phone still gets a real one. The
image carries one of two weight files by tier rather than a single fixed blob.

## Security implications

The weights are untrusted input parsed by the runtime (ADR 0008 covers that
containment). Tier selection reads only the device's own memory figure — no
network, no external input — so it adds no surface. A permissive licence removes
the risk of shipping weights under terms the image cannot satisfy.

## Resource implications

Pitch tier: ~4–5 GB resident for weights plus a bounded KV cache; requires the
8 GiB floor to coexist with the compositor and apps under the memory budgets.
Constrained tier: roughly 1–1.5 GB resident, sized for phones. Selection itself
is O(1) and allocates nothing.

## Verification

`tier.zig` tests pin the selection at and around the 8 GiB floor and that each
tier names a distinct weight file. The runtime and a real forward pass are
covered by ADR 0008's adapter tests. Licence compliance is checked the usual way
against the shipped weight artifact's SPDX metadata.

## Migration

New selection, no shipped identifier changes. Raising the floor or changing a
tier's family updates `tier.zig` and this ADR and is reviewed deliberately; the
adapter interface is independent of which weights a tier names.
