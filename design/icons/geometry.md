# Icon geometry rules

## Family 1 — UI glyphs (`source/glyphs/`)
- Canvas: 24x24 viewBox; live area 2..22 (2px safety margin all sides).
- Stroke: 2px, `stroke-linecap="round"`, `stroke-linejoin="round"`.
- Colour: `currentColor` ONLY. No baked fills or strokes. Solid dots use
  `fill="currentColor" stroke="none"`. Any literal colour value in a glyph
  source is a build-failing defect.
- Fill style: outline-first; filled micro-elements (dots, indicator cores)
  are permitted where legibility at 16px requires them.
- Optical sizes: designed for 16/20/24 rendering; the renderer scales the
  24-grid. A per-mode stroke-weight token is RESERVED (may later differ for
  dark-on-light) — resolved at build, never drawn into sources.
- RTL: directional glyphs (back, forward, send, undo, share) mirror in RTL;
  non-directional glyphs do not. The build's mirroring list is authoritative.
- Semantics: glyphs are geometry; meaning-colour (approve-green, deny-red,
  agent-violet) comes from the token role of the consuming component.

## Family 2 — app tiles (`source/app-tiles/`)
- Canvas: 512x512; shared squircle clip path — the clip path bytes MUST be
  identical across every tile (snapshot-tested); forking the tile shape is a
  defect.
- Layers, in order, with these exact gradient ids:
  `body` (linearGradient, vertical, two stops), `spec` (radialGradient
  highlight from top), `shade` (linearGradient bottom darkening), then the
  white glyph group.
- Glyph: white (#fff/#ffffff) strokes/fills only; stroke weights within
  20-28 at 512 scale.
- Variant generation (dark/light/tinted tiles) retargets `body` stops in
  `tools/icon-build/`; hand-made variant files are prohibited.

## Family 3 — brand logos (`brand/current/logos/`)
- Brand-owned; exempt from brand-neutrality naming (this is the one place
  the product name may appear in a filename).
- SVG masters; raster sizes are generated artifacts.
