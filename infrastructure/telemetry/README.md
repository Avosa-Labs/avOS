# Telemetry infrastructure

How the platform learns whether a release is healthy without learning what a
person is doing. Telemetry is necessary — a rollout gate needs a crash rate to
read — and it is a privacy hazard by nature, so its whole design is about
collecting the signal and not the person.

## What is collected

- **Aggregate health signals** — crash counts, boot success, update outcomes,
  performance-budget adherence — reported as counts, not events tied to a person.
- **No content** — never message text, files, locations, contacts, or anything
  retrieved from a person's data. Those are labeled untrusted content and never
  enter a telemetry path.

## Consent and control

- Telemetry is opt-in and separately toggleable from the rest of the system.
- A person can see what categories are reported and turn any of them off.
- Turning telemetry off degrades the platform's insight, never the person's
  device — no feature is gated on being measured.

## Minimization

- Reports are aggregated on the device before they leave it, so the platform
  receives sums, not the samples behind them.
- Identifiers are not attached; a report says "a device on version N crashed in
  subsystem S", not which device.
- Retention is bounded; raw signals age out on a fixed schedule.

## Use

Telemetry feeds exactly one loop: the rollout gate and the health baselines it
compares against. It is not used to profile, target, or advertise, because those
uses are the reason people distrust telemetry and the platform does not do them.

## Invariant

Telemetry carries aggregate health and never a person's content or identity, and
the platform works fully with it switched off.
