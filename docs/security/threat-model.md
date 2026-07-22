# Threat model

Status: skeleton. The adversaries, assets, and boundaries below are settled and
binding. The per-boundary analysis is filled in as each subsystem lands, and no
subsystem is done until its section here is written and its mitigations are
covered by tests.

A security property without an automated or reviewable verification path is not
an implemented property. Every mitigation named here must eventually point at a
test.

## Assets

- Principal identity material and the authority derived from it
- Issued capabilities, their constraints, and their revocation state
- Secret memory: keys, tokens, authentication material
- Durable personal state and application-private state
- The audit ledger's integrity and completeness
- Task-graph integrity, including approval decisions
- Package and system-image integrity
- Endpoint trust relationships

## Adversaries

| Adversary | Assumed capability |
| --- | --- |
| Malicious application | Runs arbitrary code inside its runtime sandbox; requests any capability |
| Malicious agent package | Ships a manifest and tools; attempts to widen its own authority |
| Compromised model provider | Returns arbitrary, adversarially crafted output |
| Prompt injection | Controls retrieved content: mail, messages, documents, web pages, tool output |
| Confused deputy | Induces a more privileged component to act on its behalf |
| Capability theft | Obtains a handle it was never issued |
| Stale capability replay | Replays a valid-looking handle after expiry or revocation |
| Malicious remote endpoint | Authenticates, then attempts to exceed presentation rights |
| Hostile Android application | Uses framework privilege to reach host authority |
| Malformed IPC | Sends malformed, oversized, or reordered messages |
| Supply-chain compromise | Substitutes a dependency, package, or update artifact |
| Log and crash leakage | Harvests secrets from diagnostics |
| Resource exhaustion | Starves the system of memory, disk, CPU, or descriptors |
| Rollback attack | Forces a downgrade to a vulnerable prior version |
| Malicious update server | Serves a signed-looking but hostile image |
| Physical device theft | Has the powered-off or locked device |
| Session hijacking | Intercepts or replays session transport |

## Trust boundaries

Each boundary gets its own analysis section as the subsystem lands.

1. Host foundation to trusted control plane
2. Control plane to agent execution plane
3. Agent execution plane to model adapters
4. Retrieved content to agent reasoning
5. Control plane to each isolated runtime
6. Android framework to host capability layer
7. Web origin to host bridge
8. Session host to remote endpoint
9. Package publisher to installed package
10. Update server to installed image

## Standing assumptions

These hold across every boundary and are not restated per subsystem.

- Model output is data, never authority. It cannot issue a capability, change
  policy, execute a system call, write trusted durable state, send an external
  message, install software, authenticate a principal, or mark a task
  successful without validation.
- Retrieved content is labeled untrusted. Instructions found inside it never
  override system policy, human intent, capability limits, task scope, approval
  requirements, or data-sharing restrictions.
- A compatibility runtime is never a security authority. Its crash or
  compromise must not corrupt the trusted control plane.
- Revocation takes effect for new operations immediately after control-plane
  consensus on the local host. Each capability type declares whether revocation
  cancels in flight, prevents the next step, allows an atomic operation to
  finish, or requires compensation.
- Unsigned packages are disabled outside explicit development mode.
- Updates are signed, integrity-verified, atomic, rollback-capable, staged, and
  auditable, with anti-rollback protection where hardware permits.
- Secret memory is zeroed on release by a mechanism the compiler cannot remove,
  never serialized unnecessarily, never in crash dumps, and never crosses a
  process boundary unencrypted.
- Cryptographic primitives and protocols are never invented here.

## Required adversarial tests

Each becomes a test as its subsystem lands.

- Allocation failure at every injectable allocation site
- Capability expiry between lookup and use
- Revocation racing with use
- Cancellation during IPC and during model streaming
- Duplicate mutation request and duplicate external callback
- Service restart during a state transition
- Malformed and oversized IPC
- Hostile Android application requesting host capability
- Malicious WebAssembly component
- Prompt injection in retrieved content, including adversarial documents and
  messages that attempt to redirect an agent
- Remote endpoint revocation mid-session
- Disk-full behavior and corrupt durable state
- Clock movement, forward and backward
- Unavailable model and network partition
- Update failure and rollback
- Secret redaction in logs and crash output

## Out of scope

Not implemented, therefore not vulnerabilities in this repository: production
cellular and emergency services, carrier certification, Apple binary
compatibility, Google Mobile Services, production payments, and a commercial
application marketplace.

Reporting instructions are in `SECURITY.md`.
