# Support infrastructure

How a person gets help without surrendering their privacy to get it. Support is a
launch-readiness requirement, and its central tension is that diagnosing a
problem wants data while protecting the person wants none — resolved by
collecting the least that explains the fault.

## Diagnostic bundles

- A support bundle carries technical diagnostics — versions, error codes, traces,
  timings — by default, and **redacts personal data** unless the person
  explicitly includes it (`applications/support/bundle`).
- The person sees what a bundle contains before it leaves the device and chooses
  whether to include any personal category a diagnosis genuinely needs.
- A bundle leaves the device only on the person's action; support never pulls one
  silently.

## Channels and escalation

- A published support channel with acknowledged intake, tied to the same severity
  scale as security response for issues that turn out to be vulnerabilities.
- Escalation from support to engineering carries the diagnostic bundle, not the
  person's identity, unless the person asked for account-specific help.

## Self-service and recovery

- The most common recovery paths — restart, reset settings, reinstall, restore
  from backup, recover a lost device — are available to the person directly,
  without a support interaction.
- Device recovery honors owner authentication (`applications/locator/command`): a
  support agent cannot locate, lock, or erase a device; only the authenticated
  owner can.

## Invariant

A person can be helped, and can recover their device, without personal data
leaving the device unless they chose to include it — and support holds none of
the authority to act on a device that only the owner holds.
