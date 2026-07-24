# UI reference

The authoritative description of how the shell looks and the render layer that
produces it. The visual language here is normative: a rendered frame is checked
against these values, and the render pipeline exists to reproduce them exactly.

The concrete values live in `design/theme/theme.zig`; this document explains them
and records the screen inventory the shell must present.

## Principle

The interface makes agent activity legible. Anything an agent did, is doing, or
may do is marked with the agent accent, so a person can always see where autonomy
touched their world. Humans and agents co-inhabit every surface as first-class
principals; the design never hides one behind the other.

## Palette

A dark theme built on a near-black base with a small set of meaningful accents.

| Role | Value | Use |
| --- | --- | --- |
| base | `#0b0a11` | the deepest background; boot and rest fade to it |
| panel | `#241f30` | the primary raised surface |
| surface | `#2a2833` | cards and list rows |
| surface raised | `#322c40` | the focused or active card |
| text primary | `#f4f5f7` | body and headings |
| text secondary | `#948fa2` | supporting text |
| **agent** | `#9a6cff` | the signature accent — marks agent activity |
| human | `#5aa8ff` | a person's own actions |
| teal | `#37c2a6` | calm confirmation |
| coral | `#ff8f6b` | warm attention |
| amber | `#ffb15c` | awaiting a decision |
| denied | `#e46a6a` | a refusal |

Status colours and the contrast the accessibility layer guarantees are fixed; a
brand may restyle only the accent and decorative hues.

## Geometry and motion

- **Spacing** steps in multiples of 8 pt.
- **Corner radii** run 8, 12, 16, 20, 22 pt for surfaces.
- **Icon tiles** are squircles — a superellipse (exponent 4), corner radius ≈ 23%
  of the tile side — filled with a per-app vertical gradient.
- **Elevation** is a soft shadow (blur 16, y-offset 6, tint `#4b3a66` at 60%).
- **Motion** uses a gentle spring, `cubic-bezier(.2, .9, .25, 1.1)`, overshooting
  slightly so surfaces settle rather than snap.
- **Type** is set in Sora.

## Screen inventory

The shell presents these surfaces; each is agent-aware.

- **Boot / Rest** — a calm fade in from and out to the base.
- **Home** — the day arranged by agents: a status bar, an app grid whose tiles
  carry agent-written taglines, and a dock.
- **Command** — a person says what they want in plain words; agents are
  dispatched and their work begins in the open.
- **Approval** — nothing consequential happens silently; a spend or a
  consequential action is held for the person.
- **Activity ledger** — who acted, under which capability, over what data, with
  what outcome; filterable by principal and capability, with denied actions
  shown and a signed export.
- **Principals** — humans, agents, applications, services, organizations,
  devices, and virtual sessions as first-class citizens, each with an inspector.
- **Continuity** — the environment follows the person to any screen.
- **Settings** — identity, privacy and data, capabilities and grants, endpoints,
  apps and compatibility, appearance, accessibility, software and updates,
  security, storage, sound and haptics, focus, battery and compute, backup,
  language and region, payments, agent policy, sharing, compute location, and the
  developer surface.
- **Apps** — phone (agent-screened calls), messages (agent-triaged, human threads
  kept human), calendar (agent-arranged focus blocks), camera (on-device
  recognition, per-intent lenses), files (organized by principal, provenance on
  each), photos (agent-curated, on device), and the rest.

## Render layer

The pipeline that produces a frame:

1. A **display list** (`graphics/paint/paint.zig`) — an ordered list of paint
   commands (solid, vertical gradient, rounded and squircle fills).
2. A **framebuffer** (`graphics/paint/framebuffer.zig`) — a straight-alpha RGBA
   surface with source-over blending and a self-contained PNG encoder, so a frame
   is a real image on any host with no GPU and no image library.
3. The **painter** executes the list in one bounded pass; only rounded corners
   pay for antialiasing.

`zig build frame -- out.png` renders a demonstration frame — the wallpaper, a
panel, and the app icon tiles — to prove the pipeline end to end. Later scenes
replace the demonstration content; the path from display list to image is the
same. A GPU backend plugs in beneath the display list without changing it.
