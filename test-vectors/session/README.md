# Session test vectors

Shared vectors for session virtualization: presenter handoff, endpoint attach,
protocol negotiation, state versioning, reconnect synchronization, revocation,
and cross-endpoint conflict. Any implementation of the session layer must
produce the stated outcome for every one of them.

| Vector | Scenario | Expected outcome |
| --- | --- | --- |
| `handoff-eligible` | hand presentation to a trusted, present-capable endpoint | it becomes the sole presenter |
| `handoff-ineligible` | hand presentation to an untrusted endpoint | presenter unchanged |
| `attach-owner` | endpoint credential for the instance owner | admitted at granted permissions |
| `attach-wrong-owner` | endpoint credential for a different human | refused |
| `attach-no-elevation` | endpoint granted present-only, admitted | never gains act authority |
| `negotiate-overlap` | ranges [2,4] and [3,6], floor 1 | agree on 4 |
| `negotiate-below-floor` | best shared version 2, floor 3 | incompatible |
| `state-current` | update built on the current version | accepted, version + 1 |
| `state-stale` | update built on an earlier version | stale, version unchanged |
| `sync-secret` | secret-category change on reconnect | never delivered to any endpoint |
| `sync-personal-untrusted` | durable-personal change to a presenting-only endpoint | withheld |
| `revoke-immediate` | revoked endpoint's next operation | refused |
| `conflict-second-claim` | second claim on an already-claimed consequential effect | refused |
| `handoff-single-presenter` | any handoff sequence | at most one presenter at all times |

Identity and task graphs move across endpoints; device capabilities do not, and
a consequential effect is claimed exactly once across the whole instance.
