# Approval flow example

The human-in-the-loop approval mechanism on its own, isolated from any one agent,
so the shape of a consequential action's lifecycle is legible.

## What it demonstrates

The lifecycle every consequential action follows:

1. **Proposed.** An agent proposes an action. The action carries a digest over
   what it will do — the recipient, the amount, the effect.
2. **Held.** Because it is consequential, it does not execute. It is held and
   surfaced to the person with what it will do, drawn from the digest so the
   person approves the exact action, not a description of it.
3. **Approved.** The person approves. The approval is bound to the digest — it
   authorizes *this* action, not a class of actions.
4. **Executed once.** The action runs a single time.
5. **Replay refused.** The spent approval cannot authorize a second execution.
   A digest that does not match the approval is refused outright.

## Why the digest binding matters

Binding the approval to a digest is what stops a proposed action from being
swapped for a different one between approval and execution. The person approved a
specific effect; only that effect can run under that approval.

## Expected behavior

Approve action A (digest D): A runs once. Re-submit approval D: refused. Submit
action B under approval D (digest E): refused. This mirrors the capability
test-vectors `consequential-approved`, `approval-replay`, and
`approval-wrong-digest`.
