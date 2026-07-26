# Performance & conformance budget

Concrete thresholds the graphics rebuild's gates check. Set at each checkpoint; not
inherited-vague. When a checkpoint proposes new numbers, they land here first.

## Motion conformance (CP3(b))

The animation interpolator must match the design's extracted motion curves in *shape*,
not just at the endpoints. `graphics/animation/conformance.zig` samples the interpolator
and the design curve across the unit interval and requires agreement within tolerance.

| Parameter | Value | Rationale |
| --- | --- | --- |
| Sample points (N) | 33 | Dense enough to catch a wrong middle on a curve that overshoots; 32 intervals across [0,1]. |
| Per-sample tolerance | 1.0e-3 | Below one part in a thousand of the eased value — tighter than any visible difference at 120 Hz. |

The signature spring's reviewed binding is the design's `.2,.9,.25,1.1`
(`test-vectors/design/motion.zon`), asserted against the token spring as a drift catcher.

## Frame-time & idle (CI.1) — set at Checkpoint 3

| Parameter | Value |
| --- | --- |
| p99 frame time under synthetic agent load | < 8.3 ms (120 Hz) |
| GPU submissions on an idle screen | 0 (asserted at the presentation surface) |

## Pixel conformance (CP1) — per-channel linear-light tolerance

To be proposed at Checkpoint 1 (static frame, GPU-rendered) and recorded here before the
gate is activated. Placeholder until the GPU path exists; not yet enforced.
