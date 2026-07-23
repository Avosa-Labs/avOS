# Kernel policy

The kernel tree is policy, not mechanism. It holds no threads, maps no memory,
and touches no device. It decides — and it decides as pure functions, so every
decision is testable without an operating system beneath it. Mechanism lives
below, in per-board bindings that carry these decisions out.

Implemented in `kernel/`. The separation is the point: the rules that matter are
verified in isolation from the platform they eventually run on, and the seam
between the two is shaped so a binding cannot smuggle a decision back across it.

## The five pieces

| Piece | Decides | Module |
| --- | --- | --- |
| Scheduler policy | what runs next, and what must never displace what | `scheduler-policy/` |
| Memory policy | which allocator domain a request belongs to | `memory-policy/` |
| Device policy | which principal may reach which device, right now | `device-policy/` |
| Security hooks | the order a privileged operation runs its checks | `security-hooks/` |
| Adapters | how a decision is translated into host terms | `adapters/` |

## Scheduler policy

Five classes, most urgent first: critical real-time, human-interactive,
committed task, maintenance, speculative. The rule the whole thing enforces is
that a lower class must not degrade a higher class beyond a defined budget.

An urgent class with work always wins, unconditionally — nothing can be arranged
to run ahead of an audio deadline or a keystroke. Among the sheddable classes, a
class runs only within its budget; when every ready class has spent its share the
window yields rather than overspending, because the guarantee is a *ceiling* and
honouring it sometimes means running nothing. Admission refuses lower-class work
before it is queued, since a budget noticed only at dispatch is already
overspent.

## Memory policy

Zig's allocator model is a platform feature, so the system has domains rather
than one heap: boot, trusted service, per-request, per-task, per-agent,
real-time, secret, shared transport, compatibility runtime, diagnostics. Each has
a lifetime and a discipline, and work belongs to exactly one.

The bugs this prevents are category errors invisible at the call site — a secret
in a swappable heap, a per-request buffer kept in a long-lived arena, a
real-time path on a growable allocator. A request states what it needs and the
policy confirms the domain is suitable. There is exactly one home for a secret,
named by a function so a key cannot be placed elsewhere by a stray configuration
value, and work that outlives its scope is refused a domain that frees when the
scope ends.

## Device policy

Access is never ambient. The most privileged software still presents a
capability, and an empty grant reaches nothing. Device classes are grouped by
what reaching them means to a person: camera, microphone, location, radio,
biometric, actuator, sensor, display.

Two rules beyond authority:

- **Presence.** The classes whose harm is silent use — camera, microphone,
  biometric, location — additionally require someone present to have allowed it.
- **Physical state.** An actuator obeys the device's safety state even with a
  valid capability and a person present. A capability is permission, not an
  override of a safety hold.

Authority is checked before presence, so "you hold no capability for this" wins
over "and also nobody is here". A permitted camera use carries whether it must
light the capture indicator, so a caller cannot forget to.

## Security hooks

Every privileged operation passes a fixed sequence: authenticate, authorize,
check state, perform, audit. The order is not a preference — you cannot decide
what an unknown caller may do, so authentication precedes authorization; there is
no point checking a device's state for an operation the caller may not perform;
the effect comes last; and audit is last of all because it records an outcome
that does not exist until the effect has been attempted or refused.

The dangerous mediation bug is not a check with the wrong answer. It is a check
never reached — an operation that performed before it authorized, or performed
without recording. Scattered across call sites that is invisible; as one ordered
pipeline that refuses to advance past a failed stage it is impossible. Audit runs
whichever way it went, and its verdict cannot change the outcome, because a
refusal nobody recorded is the attempt worth seeing.

## Adapters

An adapter is the thin seam where a decision is handed to the host: a scheduling
class mapped to a host priority, a memory domain mapped to a host arena. It
carries out decisions; it never makes them. The boundary is shaped so that an
adapter has nowhere to put a policy of its own — every method takes a decision
the policy already produced, never the inputs a decision is made from, so an
adapter is never in a position to make one. A structural test asserts the
interface holds only translations.

The one property an adapter must not get wrong is order: if the policy ranks one
class above another, the host priorities it maps them to must rank the same way.
That is checked — `preservesOrdering` — without dictating the numbers, so a host
that counts priorities either direction passes as long as it does not invert the
ranking.

There is no host binding in this tree. Binding to a real operating system is a
per-board concern that lives with the board it targets. This is the boundary that
binding must fit through, and a binding that tried to decide rather than
translate would not typecheck.
