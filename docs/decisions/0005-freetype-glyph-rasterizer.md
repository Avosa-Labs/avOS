# ADR 0005: FreeType is the glyph rasterizer, behind a Zig adapter

- Status: accepted
- Date: 2026-07-26
- Affects: dependency, public API

## Context

A pure-Zig TrueType rasterizer got the shell rendering real type, and it stays
the boot and recovery path. But a production text stack has to rasterize more
than one font format at more than one hinting level, correctly, across the
scripts the command surface accepts: TrueType and CFF/Type-2 outlines, embedded
bitmaps, the autohinter for fonts without instructions, and the byte-code
interpreter for those with them. Reproducing that in Zig is a multi-year effort
whose only outcome is a less-tested copy of a library the industry already
depends on.

The rasterizer is the engine below the text layout, not the architecture. Shaping
(HarfBuzz) turns text into positioned glyph ids; this turns a glyph id into
coverage. Both are libraries the layout drives, and both must be pinned exactly
and licensed cleanly like every other dependency.

## Decision

FreeType is the glyph rasterizer. It is pinned in `engines.lock.json` to
`VER-2-14-3` with the upstream archive's SHA-256 and its FreeType-License (FTL)
recorded, and `engine-lock` holds that pin complete. Unlike the Vulkan headers,
FreeType is a library, not a calling convention: `vendor-engines` fetches and
verifies its source, and the adapter compiles it from that source — no prebuilt
binary is trusted.

The adapter lives at `graphics/text/freetype`. FreeType's C types do not cross
it; the text layout sees a Zig glyph-raster interface. It is built only where the
source has been vendored (built-when-present, like the Vulkan adapter and the
WebAssembly runtime), so a checkout without it still builds and falls back to the
pure-Zig rasterizer.

## Alternatives

**Keep the pure-Zig rasterizer as the only path.** Rejected on coverage and
correctness: it handles a TrueType subset without CFF outlines, real hinting, or
the autohinter, and extending it to parity is rebuilding FreeType with less
testing. It remains the fallback, where simplicity beats coverage.

**stb_truetype.** Rejected: a single-file TrueType rasterizer with no CFF, no
byte-code hinting, and no autohinter — a smaller version of the same gap.

**A prebuilt FreeType binary.** Rejected: a binary is a trust root that the pin
cannot verify against source. Compiling from the vendored, digest-verified source
keeps the trust boundary at the digest.

## Consequences

Makes correct, hinted, multi-format glyph rasterization available to the text
path, and keeps it an engine behind an adapter the prohibitions gate can reason
about. Adds a C library to the build where its source is vendored, and its code
to the process — but confined to the adapter, driven only by the layout above it,
and absent entirely from a checkout that has not vendored it.

## Security implications

FreeType parses untrusted font files, historically a source of memory-safety
bugs. Confining it to the adapter, pinning the version, and rebuilding from
verified source is the containment: the version is known and auditable, and the
adapter is the only surface that hands it bytes. A font from an untrusted source
is still parsed by C code, so the adapter treats it as a boundary, not a trusted
input.

## Resource implications

The pinned source is a ~2.5 MB archive, fetched and digest-verified into the
build cache when the adapter is built, not committed. At runtime FreeType holds a
face per loaded font and a rasterization buffer per glyph; the layout caches
rendered glyphs above the adapter. No persistence.

## Verification

`engine-lock` verifies the pin is complete (source on the project host, 64-hex
digest, 40-hex commit, SPDX licence, adapter, and this ADR). `vendor-engines`
fetches and re-verifies the digest before extraction. The adapter's own tests —
loading a face and rasterizing a known glyph to expected coverage — run where the
source is vendored; the pure-Zig rasterizer's tests cover the fallback.

## Migration

New pin, no shipped identifier changes. Raising the pinned FreeType version
updates `engines.lock.json` and is reviewed deliberately; the adapter interface
is Zig and independent of the FreeType version behind it.
