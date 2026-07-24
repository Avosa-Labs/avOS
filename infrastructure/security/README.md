# Security response infrastructure

How a reported vulnerability moves from disclosure to a shipped fix. Security
response is a launch-readiness requirement: a consumer platform must be able to
receive, triage, fix, and disclose vulnerabilities on a predictable clock.

## Intake

- A single, published disclosure channel receives reports, with an acknowledged
  receipt and a coordinated-disclosure policy.
- A bug bounty covers the in-scope surface and states what qualifies.
- Reports are treated as confidential until a fix ships or the disclosure
  deadline passes.

## Triage

Each report is assigned a severity from its impact and exploitability:

| Severity | Meaning | Target fix window |
| --- | --- | --- |
| Critical | Remote or unauthenticated compromise of a principal's data or authority | Emergency out-of-band release |
| High | Local privilege escalation or capability escape | Next scheduled release, expedited |
| Medium | Information disclosure within a bounded scope | Next scheduled release |
| Low | Hardening, defense-in-depth | Backlog, batched |

## Fix and release

- A fix lands with a regression test that reproduces the issue, so it cannot
  silently return. Where a shared contract was wrong, a `test-vectors/` entry is
  added or corrected.
- Critical fixes ship out of band through the rollout rings on an expedited soak.
- Anti-rollback ensures a vulnerable build cannot be reintroduced after the fix.

## Disclosure

After a fix is broadly available, an advisory is published: the affected
versions, the impact, the fixed version, and credit to the reporter. The
disclosure clock runs from the report, not from the fix, so a fix is not delayed
indefinitely.

## Invariant

Every accepted report reaches a tested fix within its severity window, and a
fixed vulnerability cannot recur through a downgrade.
