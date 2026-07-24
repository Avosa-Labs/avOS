# Development phases

The platform is built in phases, each with an explicit exit condition. A phase is
not "done" until its exit condition is met; a directory is introduced only when
its first complete, tested owner module exists. This document records the phase
structure and the current state.

## Phases

### Phase A — foundation and control plane

Establish the constitutional core: identity, capabilities, the task graph,
resources, audit, and policy, exercised by a deterministic simulator with no
device. **Exit:** the canonical demonstration runs against the control plane and
every acceptance criterion passes.

### Phase B — the shell

The phone shell surfaces that project control-plane state: lock, home, command,
task graph, approvals, activity, notifications, launcher, settings, and the
rest. **Exit:** the shell presents the canonical demonstration with every state
visible and no action shown complete before it is.

### Phase C — communications

Messaging, calling, and presence as capability-secured surfaces. **Exit:**
authenticated, provenance-labeled communication between principals.

### Phase D — media

Audio, video, camera, photo, playback, recording, routing, and codecs as
decision layers. **Exit:** media capture and playback under the capability and
privacy floor.

### Phase E — the developer platform

Store, SDK (native, WASM, web, Android, Swift 6), and first-party applications.
**Exit:** third parties can build, test, sign, distribute, update, and debug
applications against stable SDKs.

### Phase F — session virtualization

The Personal Compute Instance: an environment independent of any device, with
endpoints as authenticated manifestations. **Exit:** a session moves across
endpoints with work intact and no duplicated consequential effect.

### Phase G — the autonomous-device platform

Form-factor adaptations across phone, tablet, desktop, wearable, spatial,
vehicle, room, robot, and screenless, plus the emulator and deterministic
simulator core. **Exit:** the platform is a general authority layer across
physical and virtual endpoints, each holding its own capabilities.

### Phase H — production launch

Reference hardware, manufacturing and provisioning, supply-chain controls,
repair, certification, security response, support, updates, long-term support,
and launch applications. **Exit:** only after selected-market certification,
recovery and update targets, accessibility, an independent security assessment,
and support readiness all pass.

## Ordering principle

Correctness is established where a run is reproducible and a failure observable —
the simulator — before anything reaches hardware. Compatibility is layered and
honest: a boundary is never represented as implemented until it genuinely is.
Security is the top priority throughout, not a phase.
