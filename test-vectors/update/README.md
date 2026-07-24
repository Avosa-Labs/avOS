# Update test vectors

Shared vectors for system and application updates: signature continuity,
anti-rollback, digest verification, and recovery from an interrupted update. Any
implementation of the update path must produce the stated outcome for every one
of them.

| Vector | Scenario | Expected outcome |
| --- | --- | --- |
| `forward-signed` | update to a higher version, same signer, digest verified | applied |
| `downgrade` | update to a lower version than installed | refused |
| `same-version-different-digest` | same version, altered digest | refused |
| `signer-change` | higher version signed by a different signer | refused |
| `digest-mismatch` | signature valid, payload digest does not match | refused |
| `interrupted-before-commit` | power lost before the commit point | boots the prior version intact |
| `interrupted-after-commit` | power lost after the commit point | boots the new version intact |
| `no-partial-state` | any interruption | never boots a half-applied mixture |
| `rollback-on-failed-boot` | new version fails its health check | reverts to the prior version |

An update never changes signer or downgrades, and an interruption at any point
leaves the device booting a single consistent version — never a partial mix.
