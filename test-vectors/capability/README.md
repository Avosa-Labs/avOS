# Capability test vectors

Shared vectors for capability authority decisions. Any implementation of the
capability model must produce the stated outcome for every one of them. A change
to an expected outcome is a change to the authority contract and needs the
decision record updated with it.

Each vector states a capability held, an operation attempted, and the required
decision. The floor is fail-closed: absence of authority denies.

| Vector | Held authority | Attempt | Expected outcome |
| --- | --- | --- | --- |
| `exact-match` | read on object A | read A | granted |
| `wrong-object` | read on object A | read B | denied |
| `wrong-operation` | read on object A | write A | denied |
| `no-authority` | none | read A | denied |
| `revoked` | read on A, then revoked | read A | denied |
| `attenuated` | read on A delegated as read-only | write A | denied |
| `consequential-unapproved` | act on A | consequential act A | held for approval |
| `consequential-approved` | act on A, approval bound to digest D | act A with digest D | granted, once |
| `approval-replay` | approval bound to digest D, already spent | act A with digest D | denied |
| `approval-wrong-digest` | approval bound to digest D | act A with digest E | denied |
| `untrusted-provenance` | read on A, tainted source | act A | denied (taint cannot launder) |
