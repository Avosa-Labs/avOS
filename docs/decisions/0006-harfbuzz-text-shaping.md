# ADR 0006: HarfBuzz is the text shaper, behind a Zig adapter

- Status: accepted
- Date: 2026-07-26
- Affects: dependency, public API

## Context

Rendering text is two steps. Shaping turns a run of Unicode text and a font into positioned
glyph ids — applying kerning, ligatures, mark placement, and the rules of each script;
rasterising turns each glyph id into coverage (ADR 0005, FreeType). The command surface
accepts arbitrary text, so the shaper must handle the scripts and directions real input
carries, not just left-to-right Latin. Reproducing HarfBuzz — the shaper the browsers, the
toolkits, and the other engines already rely on — is a multi-year effort with a less-tested
result.

Shaping is an engine below the text layout, not the architecture, and it is pinned exactly and
licensed cleanly like every other dependency.

## Decision

HarfBuzz is the text shaper. It is pinned in `engines.lock.json` to `14.2.1` with the upstream
archive's SHA-256 and its MIT licence recorded. Like FreeType it is a library, not a calling
convention: `vendor-engines` fetches and verifies the source, and the adapter compiles it — from
the single-file amalgamation `src/harfbuzz.cc`, so the build is one C++ translation unit, no
generated configuration and no build system of its own.

The adapter lives at `graphics/text/harfbuzz`. HarfBuzz's C types do not cross it; the layout
sees a Zig shaping interface that takes text and a font and returns positioned glyph ids. It is
built only where the source is vendored (built-when-present), so a checkout without it still
builds and the layout falls back to unshaped advances.

## Alternatives

**Unshaped advance-width layout.** Rejected for anything but the simplest Latin: it cannot
kern, cannot form ligatures, and cannot lay out complex or right-to-left scripts, which the
command surface must accept. It stays the fallback where the shaper is absent.

**A hand-written shaper.** Rejected: correct shaping across scripts is exactly the body of
knowledge HarfBuzz encodes; a reimplementation is larger and less tested.

## Consequences

Makes correct shaping available to the text path and keeps it an engine behind an adapter the
prohibitions gate can reason about. Adds a C++ translation unit to the build where the source is
vendored, and its code to the process — confined to the adapter, driven only by the layout, and
absent from a checkout that has not vendored it. Pairs with FreeType: HarfBuzz says which glyph
goes where, FreeType says what each glyph looks like.

## Security implications

HarfBuzz parses untrusted font tables, a historical source of memory-safety bugs. Confining it
to the adapter, pinning the version, and rebuilding from verified source is the containment: the
version is known and auditable, and the adapter is the only surface that hands it font bytes or
text. Text read out of an untrusted document stays labelled untrusted regardless of shaping.

## Resource implications

The pinned source is a ~37 MB archive, fetched and digest-verified into the build cache when the
adapter is built, not committed; the content-addressed build cache compiles the amalgamation once
per pin. At runtime HarfBuzz holds a face and font per loaded font and a buffer per shaped run;
the layout caches shaped runs above the adapter. No persistence.

## Verification

`engine-lock` verifies the pin is complete (source on the project host, 64-hex digest, 40-hex
commit, SPDX licence, adapter, and this ADR). `vendor-engines` re-verifies the digest before
extraction. The adapter's tests shape a known run and assert the glyph count and advances; they
run where the source is vendored.

## Migration

New pin, no shipped identifier changes. Raising the pinned HarfBuzz version updates
`engines.lock.json` and is reviewed deliberately; the adapter interface is Zig and independent of
the HarfBuzz version behind it.
