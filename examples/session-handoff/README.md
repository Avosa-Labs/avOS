# Session handoff example

Moving a live session from one endpoint to another — a phone to a laptop, a
laptop to a room display — with the work in flight intact and no effect
duplicated. This is the Personal Compute Instance made concrete: the environment
is not the device.

## What it demonstrates

- **The instance persists; the presenter changes.** Handing off moves the
  presenting role to the new endpoint; it does not change the principal, the task
  graph, or what has already happened (`session/host/presenter`).
- **Single presenter.** At every moment exactly one endpoint presents — never two
  at once, never dropped while an endpoint is available.
- **No duplicated effect.** A consequential action committed on the first
  endpoint is not repeated on the second; the effect was claimed against the
  instance and cannot be claimed again (`session/conflict/claim`,
  `session/instance`).
- **Trust-aware presentation.** When the session lands on a shared surface,
  sensitive content is masked; on the person's private device it is shown
  (`session/presentation/frame`).

## Sequence

1. Session runs on the phone; a task is mid-flight, one consequential action
   already committed.
2. The person hands off to the laptop. The laptop becomes the sole presenter; the
   task and history are intact.
3. The already-committed action is **not** re-run on the laptop.
4. Handing off further to a room display masks the sensitive fields.

## Expected behavior

The `session_continuity` acceptance criterion: identity and task graph move,
capabilities do not, exactly one presenter holds the session, and a consequential
effect performed on one endpoint is never repeated by another.
