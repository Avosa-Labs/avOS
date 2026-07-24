# Launch readiness

The exit criteria for Phase H. The platform ships to a market only when every
item here passes. This is a gate, not a wish list: an unmet item blocks launch
rather than being waived.

## Security

- [ ] Independent security assessment completed, findings triaged and resolved to
      the severity windows in `infrastructure/security`.
- [ ] Bug bounty live with a published scope and disclosure policy.
- [ ] The security floor suite (`tests/security/floor`) and the adversarial suite
      pass on every supported host.
- [ ] Secure boot, verified images, and anti-rollback demonstrated end to end on
      reference hardware.
- [ ] Signing keys held only in the hardware security module; no production key in
      any developer or emulator artifact.

## Update and recovery

- [ ] Two-slot atomic update with trial boot and known-good fallback demonstrated
      through a forced-failure test on hardware (`packaging/recovery`).
- [ ] Rollout rings and the promotion gate operating with real health signals
      (`infrastructure/rollout`, `packaging/policies/rollout`).
- [ ] Recovery and update time targets met and measured.

## Accessibility and localization

- [ ] Accessibility baseline passes across every shipping form factor.
- [ ] Localization complete for the launch markets, with fallback verified.

## Certification and compliance

- [ ] Selected-market certification obtained.
- [ ] Privacy documentation published and accurate to what the platform does.
- [ ] Supply-chain controls in place: reproducible builds, artifact provenance,
      and an emitted software bill of materials.

## Support and operations

- [ ] Support channels staffed with the diagnostic-bundle privacy floor enforced
      (`applications/support/bundle`, `infrastructure/support`).
- [ ] Long-term support commitment published with its window.
- [ ] Telemetry opt-in, aggregate-only, and demonstrated to work fully when off.

## Hardware

- [ ] Reference hardware manufacturable with secure provisioning.
- [ ] Repair path defined and documented.

## Product

- [ ] Launch applications complete and passing acceptance.
- [ ] The canonical demonstration runs on shipping hardware with every acceptance
      criterion green.

## Exit

Launch proceeds only after every box above is checked. Security, update, and
recovery are non-negotiable; the others are gates, not aspirations. Nothing here
is marked done from recall — each is verified by the check or test named beside
it.
