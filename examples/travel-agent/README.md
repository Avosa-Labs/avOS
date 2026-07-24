# Travel agent example

An agent that plans a route and confirms attendance with a venue — the third
principal in the canonical demonstration, and the one that takes a
*consequential* action, so it shows the approval gate end to end.

## What it demonstrates

- **Consequential actions are held for approval.** Confirming attendance with a
  venue reaches an external system and cannot be undone, so it does not run on
  the agent's say-so. It is held until the person approves it
  (`agents/` approval flow, `sdk/agents/manifest`).
- **Approval is bound to a digest.** The approval the person grants covers a
  specific action with a specific digest. It authorizes that action once.
- **Exactly once, no replay.** After the confirmation runs, replaying the same
  approval is refused, so the venue is confirmed once even if the task is
  retried or resumed on another endpoint (`session/conflict/claim`).

## Manifest sketch

```
agent: travel
capabilities:
  - network.venue_api: act
tools:
  - plan_route          (no external effect)
  - confirm_attendance  (consequential; requires approval)
```

## Expected behavior

`plan_route` runs freely. `confirm_attendance` is held for approval; once
approved it executes exactly once; a replayed approval is refused. This is the
full unauthorized→held→approved→once→replay-refused sequence the platform's
acceptance criteria assert.
