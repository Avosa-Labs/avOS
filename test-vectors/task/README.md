# Task test vectors

Shared vectors for the task graph: structured execution, approval gating,
cancellation propagation, and exactly-once effects. Any implementation of the
task model must produce the stated outcome for every one of them.

| Vector | Scenario | Expected outcome |
| --- | --- | --- |
| `linear-success` | a chain of tasks each succeeding | all succeed in order |
| `unauthorized-op` | a task attempts an operation it lacks authority for | denied |
| `consequential-held` | a consequential task with no approval | held for approval |
| `approved-once` | an approved consequential task | executed exactly once |
| `approval-replay` | the same approval reused | refused |
| `root-cancel` | cancelling a root task with descendants | all descendants cancelled |
| `descendant-of-cancelled` | a child scheduled after its parent was cancelled | not started |
| `no-orphan` | run completes | no unfinished task remains |
| `memory-baseline` | run completes | peak memory returns to baseline, zero residual |
| `ledger-unbroken` | run completes | audit ledger sequence has no gap |

These mirror the acceptance criteria the canonical simulator scenario asserts:
unauthorized denied, consequential held, approved executed once, replay refused,
cancellation ends descendants, no orphans, memory returns to baseline, ledger
unbroken.
