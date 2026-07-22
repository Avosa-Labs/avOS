# Architecture overview

The system is an agent-native personal operating system. Humans, autonomous
agents, applications, services, organizations, devices, and virtual sessions
are all first-class computing principals: each has identity, authority,
resources, state, provenance, and an auditable lifecycle.

Agents are not hidden application features and never impersonate humans.
Delegation lets an agent act within constraints on a human's behalf; it does
not merge the two identities.

## Trust zones

The system is layered into five zones. Code does not cross a zone boundary
except through a typed, authenticated interface.

### Hardware and host foundation

Boot, process isolation, virtual memory, device access, display, input, audio,
network, storage, hardware-backed keys, verified image loading, and atomic
update support. The proof of concept uses a Linux/AOSP foundation. Everything
platform-specific is isolated behind host interfaces so the zone is
replaceable.

This zone is not being rewritten. The project does not begin by replacing
Linux, recreating production phone drivers, or claiming handset readiness.

### Trusted control plane

Small, privileged, and written in Zig. It owns the principal, capability, task,
resource, audit, secret, session, package, update, and policy services.

It deliberately contains no model prompts, no application business logic, no
broad network clients, and no compatibility framework code. Adding anything to
this zone requires an architecture decision record explaining why isolation
cannot satisfy the requirement instead.

### Agent execution plane

Intent interpretation, planning, task-graph compilation, model routing, the
tool registry, context retrieval, agent lifecycle hosting, approval
orchestration, result provenance, and prompt-injection boundary enforcement.

Models are untrusted computation. Model output is data: it cannot issue a
capability, change policy, execute a system call, write trusted durable state,
send an external message, install software, authenticate a principal, or mark a
task successful. Plans, tool arguments, and structured results are validated
against typed schemas and policy before they become anything.

### Application and compatibility plane

Separately isolated native, WebAssembly, Android, and web runtimes, plus a
prepared boundary for future Apple portability work.

A compatibility runtime never becomes the security authority of the host.
Android permissions are translated into host capability requests at the
boundary; Android framework privilege does not become host privilege.

### Session plane

Local shell, remote presentation client, encrypted session synchronization,
input routing, display streaming or state replication, endpoint authentication,
and endpoint revocation.

A remote endpoint does not receive capabilities merely because it can render a
session.

## Authority

Access is represented by capabilities — explicit, unforgeable grants — not by
ambient process privilege or hidden global trust. Every capability names its
issuer, holder, resource, operations, constraints, expiry, delegation depth,
and generation.

The system denies by default. Missing, expired, revoked, malformed,
over-budget, or context-incompatible authority is rejected. A task receives only
the capabilities its declared work requires. Every delegation declares whether
it may be delegated further and to what depth.

Agents and applications hold opaque handles, never privileged pointers. Every
use revalidates holder, issuer trust, integrity, generation, revocation state,
expiry, operation, resource selector, task binding, contextual constraints,
remaining invocations, and budget.

## Execution

Every agent operation belongs to a structured task graph. A task carries an
owning and requesting principal, purpose, parent, children, dependencies,
deadline, budget, capability set, state, cancellation token, provenance, retry
policy, and approval state.

Cancellation is transitive: cancelling a parent cancels unfinished descendants
unless a descendant was deliberately detached under new authority, which
requires its own owner, purpose, budget, expiration, and capability set. No
background task exists without an owner, purpose, budget, expiration, and
cancellation path.

Consequential actions — sending a message, publishing, deleting durable data,
installing software, changing security settings, transferring value, sharing
private information, granting authority — carry an approval policy and default
to explicit human approval.

## Visibility

Privileged activity is observable while it happens and reconstructable
afterward. The audit ledger records authentication, principal and capability
lifecycle, task transitions, model and tool invocation metadata, denials,
approval decisions, package and policy changes, endpoint activity, updates,
integrity failures, and resource-limit breaches.

The ledger is not a shadow copy of private data. It stores action types,
resource identifiers, authority, outcomes, hashes, and bounded summaries — not
message bodies, prompts, files, model context, or credentials.

A user can ask what acted, for whom, why, under which capability, on which
data, whether data left the device, what model or tool was used, what changed,
and whether it can be reversed. Answers come from records, never from generated
guesses.

## Resource discipline

Every principal and task runs under explicit CPU, memory, storage, network,
energy, and model-compute budgets. Concurrency is structured, bounded,
observable, cancellable, and justified by measured benefit.

Scheduling classes run from critical real-time through human-interactive,
committed task work, maintenance, and speculative work. A lower class never
degrades a higher one beyond its defined budget.

Untrusted principals and agent tasks allocate through budgeted boundaries that
track current and peak bytes, enforce a hard ceiling, attribute allocations to
principal and task, and support fault injection. Allocation failure is a normal
recoverable condition.

## Current state

Milestone 0 is complete: repository structure, exact toolchain pinning, the
brand resource layer, the compiler compatibility boundary, and the formatting,
test, brand, and health gates.

None of the zones above are implemented yet. The simulator is the first
implementation target and runs the control plane on macOS and Linux without
AOSP.
