# ADR 0000: Title

- Status: proposed | accepted | superseded by ADR NNNN
- Date: YYYY-MM-DD
- Affects: trust boundary | persistence | protocol | dependency | compatibility | scheduling | cryptography | public API

Copy this file to `NNNN-short-title.md`, numbered sequentially. A decision
affecting any area listed under "Affects" requires a record before the change
lands.

An ADR records the final technical rationale. It contains no chat transcripts,
prompt text, model names, tool attribution, or implementation history. Write it
as the decision a reviewer needs to understand the system, not as a narrative of
how it was reached.

## Context

The forces that make a decision necessary: the requirement, the constraint, the
measurement, or the boundary under pressure. State what is true, not what was
tried.

## Decision

What is now the case, in the present tense. Name the concrete interfaces, types,
files, or protocol elements involved.

## Alternatives

Each alternative that was genuinely viable, and the specific reason it loses.
"Simpler" or "more popular" is not a reason. An alternative rejected on
measurement cites the measurement.

## Consequences

What this makes easy, what it makes hard, and what it forecloses.

Where the decision adds code to the trusted computing base, explain why
isolation cannot satisfy the requirement instead.

## Security implications

The threat-model boundaries this touches, the assumptions it introduces or
removes, and the adversaries it affects. If none, say so and why.

## Resource implications

Expected input size, time and space complexity, worst-case and adversarial
behavior, persistence cost, and concurrency effect for anything non-trivial.
Budgets affected, and the measurement backing any performance claim.

## Verification

The tests, vectors, and gates that hold this decision true. A property asserted
here without a verification path is not implemented.

## Migration

For a change to a shipped wire identifier, package identity, signing domain, or
disk format: the migration path, compatibility window, and rollback plan.
Stable technical identifiers are not rebrand levers — changing one is a
migration, never a cosmetic edit.
