# ADR 0008: llama.cpp is the on-device language-model runtime, behind a Zig adapter

- Status: accepted
- Date: 2026-07-28
- Affects: dependency, agent runtime

## Context

An agent on this platform acts through a mind — the seam in `agents/model` that
either proposes a next step or reports itself unavailable, and an agent bound to
an unavailable mind is inert. For the substrate-neutrality promise to be real,
the default mind has to run on the device: a person's private world is answered
without a request leaving it, and the same governance applies whether the mind is
local or hosted. That needs a real inference runtime that loads quantized weights
and generates tokens within a bounded context, on commodity CPUs and the GPUs the
device already exposes.

The runtime is the engine below the mind seam, not the architecture. The mind
contract turns a request into a proposal; this turns a prompt and a set of weights
into tokens. It is a library the seam drives, and it must be pinned exactly and
licensed cleanly like every other dependency — never a hosted account, which would
make the default agent gated on a third party.

## Decision

llama.cpp is the on-device language-model runtime. It is pinned in
`engines.lock.json` to `b10173` with the upstream archive's SHA-256 and its MIT
licence recorded, and `engine-lock` holds that pin complete. Like FreeType and
HarfBuzz it is a library, not a calling convention: `vendor-engines` fetches and
verifies its source, and the adapter compiles it from that source — no prebuilt
binary is trusted.

The adapter lives at `agents/model/local/llama`. llama.cpp's C types do not cross
it; the mind seam sees a Zig interface that loads a model and generates a bounded
number of tokens. It is built only where the source has been vendored
(built-when-present, like the FreeType and Vulkan adapters), so a checkout without
it still builds — and an agent whose local runtime is absent simply reports its
mind unavailable, the existing fallback, rather than failing to compile.

## Alternatives

**A hosted model as the default mind.** Rejected: it makes the default agent
depend on a third-party account and sends the person's private world off the
device to do ordinary work. A hosted mind stays available as a deliberate,
additive choice — never the floor.

**Write an inference runtime in Zig.** Rejected on the same grounds as rewriting
FreeType: matching llama.cpp's quantization formats, sampler set, and GPU
back-ends is a multi-year effort whose only outcome is a less-tested copy of a
library the field already depends on.

**A prebuilt llama.cpp binary.** Rejected: a binary is a trust root the pin cannot
verify against source. Compiling from the vendored, digest-verified source keeps
the trust boundary at the digest.

## Consequences

Makes a real on-device mind available to the agent seam, so the default agent
answers locally under the same governance as any other, and substrate neutrality
is demonstrated rather than asserted. Adds a C/C++ library to the build where its
source is vendored, and its code to the process — but confined to the adapter,
driven only by the mind seam above it, and absent entirely from a checkout that
has not vendored it.

## Security implications

llama.cpp loads GGUF weight files and runs a large C/C++ codebase over them. A
weight file from an untrusted source is untrusted input, historically a source of
memory-safety bugs in model loaders. Confining the runtime to the adapter,
pinning the version, and rebuilding from verified source is the containment: the
version is known and auditable, and the adapter is the only surface that hands it
bytes. The tokens it produces cross the seam tagged untrusted, the same as any
model output, so nothing downstream trusts a generation because it was produced
locally.

## Resource implications

The pinned source is a several-megabyte archive, fetched and digest-verified into
the build cache when the adapter is built, not committed. The weights themselves
are not vendored — a model is provisioned separately and loaded by the adapter. At
runtime the runtime holds one loaded model and a context sized to the bounded
window the seam enforces; there is no persistence beyond the model file the person
provides.

## Verification

`engine-lock` verifies the pin is complete (source on the project host, 64-hex
digest, 40-hex commit, SPDX licence, adapter, and this ADR). `vendor-engines`
fetches and re-verifies the digest before extraction. The adapter's own tests —
loading a small model and generating a bounded, deterministic completion — run
where the source is vendored; the mind seam's tests cover the unavailable
fallback where it is not.

## Migration

New pin, no shipped identifier changes. Raising the pinned llama.cpp version
updates `engines.lock.json` and is reviewed deliberately; the adapter interface is
Zig and independent of the llama.cpp version behind it.
