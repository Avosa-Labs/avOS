# Contributing

Project truth lives in the repository, not in one contributor's memory or one
assistant's context. Anything a future contributor must know belongs in
`docs/`, an architecture decision record, or a test.

## Before changing code

Inspect the relevant code and documentation first. Identify the invariants and
acceptance criteria the change must preserve. Make the smallest complete
architectural change that satisfies them.

## Branch discipline

Cut one branch per task from the latest `main`. Related subtasks stay on that
branch. Pull and verify `main` before branching. Do not begin another task
while the current one is incomplete.

## Gates

A red gate is never committed. Run every gate that applies to the change:

```sh
zig fmt --check .
zig build
zig build test
zig build brand-check
```

Further gates arrive with the milestones that introduce them: integration,
security, adversarial, recovery, compatibility, simulator, and image.

A task is complete only when formatting passes, compilation passes for the
required targets, the relevant tests pass, behavior is confirmed, documentation
and test vectors are synchronized, and the diff contains no brand leak, secret,
or unrelated change.

"Zero errors" means every required command exits zero, expected denials are
asserted rather than suppressed, and no crash, leak, race, corruption, timeout,
or unbounded retry is observed. It never means weakening an assertion or
disabling a test.

## Naming

Name every function, variable, type, field, file, service, and protocol for
what it is in the domain. A name must not encode patch history — no `new`,
`old`, `legacy`, `fixed`, `proper`, `real`, `temp`, `V2`, or `Ex`. Avoid filler
names such as `Helper`, `Util`, `Wrapper`, `Manager`, and `Common`.

Describe alternate data shapes by what they are: `PlainEnvelope`, not
`LegacyEnvelope`. When replacing an incorrect implementation, give the result
its true name and remove the incorrect one. The code must read as if it were
designed correctly from the beginning.

## Comments

Comments explain the code as it exists — non-obvious behavior, why a constraint
exists, what invariant must hold, why a simpler implementation is incorrect, or
what ownership and concurrency rule applies. They must stand alone.

Comments must not cite section numbers, task numbers, issue history, prompts,
tools, or implementation history. Do not narrate obvious syntax.

## Brand neutrality

Product and company names live only in the brand resource layer. They must not
appear in module names, namespaces, service names, wire identifiers, disk
formats, environment variables, capability kinds, system paths, log fields, or
comments. `zig build brand-check` enforces this and runs in CI.

## Dependencies

Every dependency uses the latest stable release available at the time it is
selected or deliberately upgraded, then is pinned exactly by version and
verified digest in `toolchain.lock.json`. Prereleases, snapshots, branch
references, and floating ranges are rejected. Automated update tools may open
branches; they must not merge them.

## Architecture decision records

A decision affecting trust boundaries, persistence, protocols, dependencies,
compatibility, scheduling, cryptography, or public APIs requires an ADR. Copy
`docs/decisions/0000-template.md`. An ADR records the final technical
rationale — no transcripts, prompts, or tool attribution.

## Commits

Subject: lowercase, imperative, concise, no period, no emoji. Body: blank line
after the subject, `-`-prefixed bullets stating what changed and why, and any
migration or security implication.

```text
enforce task-bound capability use

- bind delegated handles to the task that requested them
- reject replay from sibling and descendant tasks
- cover revocation and cancellation races with integration tests
```

No co-author or tool trailer is permitted in any commit.
