# ADR 0002: Shell rendering toolkit

- Status: proposed
- Date: 2026-07-22
- Affects: dependency, public API

## Context

The shell surfaces exist as state projections with an accessibility contract
attached. Nothing renders them yet. Choosing what does is the last structural
decision in the agent shell, and it is the one most likely to be made by
accident: a toolkit adopted for a demonstration becomes the toolkit the design
system is built against.

The requirements are set by the surfaces already written, not by taste.

Accessibility is not negotiable and not addable later. The surfaces already
carry accessible names, focus order, live regions, dynamic type, and reduced
motion. A toolkit that cannot express these to the platform's assistive
technology cannot present these surfaces, however good it looks.

Rendering must be GPU-capable and hold a frame budget. Motion in this system
explains state — a task splitting, an approval arriving, work being cancelled —
and motion that drops frames explains nothing.

The toolkit must be separable from control-plane logic. Surfaces read state and
return structure; the renderer must not become a place where authority
decisions are made or where state is cached.

Text must handle global scripts, bidirectional text, and dynamic type across the
full accessibility range, because the command surface accepts arbitrary text and
the shell must render what it accepted.

It must be latest stable and exactly pinned, like every other dependency.

## Decision

Defer the choice. Build the renderer boundary now and select the toolkit after a
measured spike.

The boundary is the deliverable of this record: surfaces already produce a
structure describing what to present and how it must be reachable. A renderer
consumes that structure. Nothing above the renderer knows which toolkit is in
use, and the renderer holds no state of its own.

This is deliberate rather than indecisive. Every candidate below fails at least
one requirement in a way that cannot be assessed from documentation, and
adopting one now would mean discovering that during Phase B, when the design
system is already built against it.

## Alternatives

**A platform-native toolkit per target.** Best accessibility and text handling,
because the platform's assistive technology and text stack are the ones it was
built for. Rejected as the primary choice because it is one implementation per
form factor, and §37 requires the architecture not to encode the phone as its
permanent centre. Remains the likely answer for the reference mobile
environment specifically.

**An immediate-mode GPU toolkit.** Excellent frame control and a small
dependency surface. Rejected on accessibility: immediate-mode interfaces have no
retained element tree, so exposing accessible names, focus order, and live
regions to platform assistive technology ranges from awkward to impossible. The
surfaces here are built around exactly that tree.

**A retained-mode cross-platform toolkit.** Matches the surface model closely
and gives one implementation across form factors. Not rejected — it is the
leading candidate — but which one, and whether its accessibility bridge is real
on every target, cannot be established without measuring it.

**A web engine as the shell renderer.** Mature accessibility, text, and layout.
Rejected as the shell renderer: it would put a large untrusted-content engine
inside the session plane, and the web runtime already exists in the application
and compatibility plane where it belongs. Using it for the shell would blur a
trust boundary the architecture deliberately draws.

## Consequences

Makes possible: the surfaces are testable now, and the renderer can be chosen
against measurements rather than impressions.

Makes harder: there is no visual shell until this is settled. That cost is
accepted, because the alternative is a visual shell whose accessibility cannot
be fixed without replacing it.

Forecloses nothing. The boundary is narrow enough that more than one renderer
can exist at once, which is what makes a per-form-factor renderer viable later.

## Security implications

Boundary touched: session plane to presentation.

The renderer receives structure to present. It is never given a capability, and
it never decides whether an action may proceed — the approval surface asks the
policy and shows the answer. A renderer that could decide would be a second
place authority comes from.

A toolkit is a large dependency reached by content the user did not write, since
surfaces display retrieved text. Whatever is selected must be pinned by exact
version and digest and tracked for advisories, on the same terms as the
component runtime.

## Resource implications

Frame budget and memory per surface are the figures that will decide this, and
neither is known. `docs/performance/budgets.md` must state them before the
spike, so the spike measures against a target rather than producing numbers
someone later declares acceptable.

No performance claim is made here.

## Verification

Required before this record moves to accepted, for each candidate, on each
supported form factor:

- accessible names, focus order, live regions, and roles reaching the
  platform's assistive technology, verified with that technology rather than
  with the toolkit's own inspector
- dynamic type across the full accessibility range with no essential control
  depending on truncation
- reduced motion, reduced transparency, and increased contrast honoured
- bidirectional and complex-script text rendered correctly
- the frame budget held while a task graph updates incrementally
- the toolkit pinned by exact version and digest, with a security-advisory path

A candidate that cannot demonstrate the first item is rejected regardless of how
it performs on the rest.

## Migration

None. No wire identifier, package identity, signing domain, or disk format is
affected: the renderer sits above all of them.
