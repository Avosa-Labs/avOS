# avOS — Delivery Roadmap

This is the authoritative, ordered plan to grow the repository from its current
vertical-slice skeleton into the fully-fledged agent-native operating system:
a real trusted core, real component isolation, real agent execution where
**agents coordinate with one another and a human watches and talks to them in
real time**, a complete phone shell, a full first-party app suite, persistent
personal compute, and — post-POC — device bring-up, connectivity, media, and a
production launch.

It is derived from the build specification and organized so each subsystem is
built out **completely** (many real modules per directory — types, logic, error
sets, invariants, recovery, and colocated tests), never one placeholder file per
folder.

---

## 0. How to read this

**Tracks are large branches.** Each track below is one substantial, self-contained
branch (e.g. "the core control plane", "the agent execution plane"). Related
subtasks stay on that branch until it is complete, then it is squash-merged. This
is the "one large kernel branch" model — we move faster by finishing a whole
subsystem before opening the next.

**Order is dependency order.** Tracks are numbered in the sequence they should be
built. A later track never blocks on an earlier track it doesn't depend on, but
the trusted core comes first because everything rests on it. Within the POC,
tracks 1–10 correspond to build Milestones 1–6; tracks 11+ correspond to
post-POC Phases A–H.

**The north star.** The POC is "done" when the canonical demonstration runs from
a clean reproducible build: one human and three agents, differing authority, a
denied action, a narrow approval executed exactly once, structured cancellation,
a reconstructable audit ledger — all visible in the shell as **live agents
interacting while the human approves, denies, and converses with them.** Every
track is in service of making that real and then production-grade.

**Every module's definition of done** (applied to each folder, not just each track):
scope defined; public contract typed and documented; ownership explicit;
cancellation behavior explicit; resource budgets enforced; security assumptions
documented; tests cover success, denial, failure, cancellation, and recovery;
dependencies pinned; required builds pass; benchmarks pass; audit behavior
implemented; brand neutrality preserved; no attribution; no unrelated capability.

**Standard module shape.** Unless noted, each domain folder contains, as separate
files: the domain type(s) and their invariants; the state machine / decision
logic (pure where possible); a domain error set; serialization / wire form where
it crosses a boundary; and colocated unit + property tests. Cross-boundary
protocols additionally own shared vectors under `test-vectors/` and adversarial
malformed cases.

**Layering (enforced by a dependency-boundary test).** `core` → std only;
`services` → `core` + IPC contracts; `shell` → services via typed clients only;
`agents` → capabilities via services, never privileged internals; `runtimes` are
untrusted adapters, never authorities; `applications` → public SDK; `design` →
assets/tokens only; `brand` overrides brand resources only.

---

## Part I — Current state vs target

The skeleton exists (repo, toolchain, brand, CI, a working canonical simulator,
a native renderer, a windowed shell). But most subsystem directories hold a
single module where the spec requires a full implementation. The work below
converts each into a real subsystem.

Legend: **[skeleton]** exists as ~1 file, needs building out · **[partial]** has
real content, needs completion · **[absent]** post-POC directory, not yet created.

---

## Part II — Tracks (in build order)

### Track 1 — Core control plane (the trusted kernel)   ⟵ START HERE

**Goal.** The small trusted core every other layer depends on. Pure, allocator-
explicit, deterministic, exhaustively tested. This is the "kernel" of the
agent-native OS: identity, authority, execution, accounting, and provenance.
Milestone 1. Layer: `core` (std only).

**Directories & responsibilities** (`core/`):
- `base/` — result/error scaffolding, bounded integers, units, ID newtypes, span/slice guards, overflow-checked arithmetic over sizes/times/counters/generations.
- `collections/` — arena-friendly maps, stable-index slabs, ring buffers, bounded queues (no unbounded growth), intrusive lists.
- `encoding/` — canonical byte encodings, varints, hashing, constant-time compare, hex/base32, deterministic serialization.
- `time/` — monotonic vs wall clocks, deadlines, durations, clock-movement handling, expiry math.
- `identity/` — principal identifiers, key identifiers, name binding, equality/derivation, stable serialization.
- `principal/` — the principal model: human, agent, application, service, organization, device, session; authority classes; lifecycle; registry.
- `capability/` — capability tokens; scopes; delegation; attenuation; generations; revocation; use-time revalidation; task-binding; replay rejection.
- `task/` — task graph; nodes/edges; split/merge; states (created→running→completed/cancelled/failed/awaiting-approval); structured cancellation of descendants; idempotency keys; `outcome_unknown`.
- `resource/` — budgeted allocator; per-principal/per-task budgets; metering; pressure signals; "idle agent consumes no CPU"; "completed task releases memory"; accounting-overhead bound.
- `policy/` — decision inputs → allow/deny/require-approval; deterministic, side-effect-free; explainable denials.
- `audit/` — append-only ledger; hash-chained entries; actor/action/target/outcome/capability; tamper-evidence; reconstruction; redaction of secrets.
- `provenance/` — chain of who-authorized-what across delegation and model/tool use.
- `package/` — package identity, manifest, signature verification types (verification lives here; signing tooling is separate).
- `update/`, `recovery/`, `diagnostics/`, `localization/`, `accessibility/` — the post-POC core services widen here; POC delivers the first six above plus policy/audit/provenance/package.

**Exhaustive functionality checklist:**
- Principal registry with per-kind authority; lookup by id; enumeration.
- Capability issue → delegate → attenuate → use → expire → revoke, with use-time generation revalidation and replay rejection from sibling/descendant tasks.
- Task graph create/split/merge/advance/complete/cancel; root cancellation ends all descendants; no unfinished tasks leak.
- Budgeted allocator with injectable allocation-failure at every site; memory returns to baseline within tolerance.
- Policy engine: unauthorized op denied; consequential op requires approval; approval executes exactly once; replay of approval refused.
- Audit ledger append + verify + reconstruct; sequence unbroken; hash chain intact.
- Property tests for all arithmetic; malformed/duplicate/reordered/stale/replayed inputs; clock movement.

**Acceptance (Milestone 1 core):** one human + three agents execute with differing
authority; unauthorized denied; one op awaits approval; approval once; root
cancellation ends descendants; memory to baseline; ledger reconstructs execution.

---

### Track 2 — IPC and component contracts

**Goal.** The authenticated, typed message layer between the trusted core, the
services, and untrusted runtimes. Milestone 2 foundation. Post-POC this becomes
the standalone top-level `ipc/` tree.

**Directories** (`core/ipc/` in POC → `ipc/` post-POC): `schema/`, `transport/`,
`authentication/`, `capability-binding/`, `cancellation/`, `routing/`,
`codegen/`, `test-vectors/`.

**Functionality:**
- Typed message schema with a canonical wire form and versioned envelopes (`PlainEnvelope` etc. by shape, never by history).
- Authenticated channels; each message carries the sender principal and the capability it is exercised under.
- Capability-binding: a message cannot invoke authority the sender doesn't hold.
- Cancellation propagation across a call; cancel-during-IPC is correct.
- Routing to the owning service; backpressure; oversized/malformed rejection.
- Deterministic protocol codegen from schema; shared cross-runtime test vectors incl. malformed/adversarial.
- Old-reader/new-writer compatibility rules where declared.

**Acceptance:** malformed and oversized IPC rejected without crash; cancellation
interrupts an in-flight call; a component cannot exceed its bound authority.

---

### Track 3 — Services (component isolation & trusted daemons)

**Goal.** Put the core behind real process boundaries: each trusted concern is a
supervised service reached only through typed IPC. Milestone 2/3. Layer:
`services` (depends on `core` + IPC).

**Directories** (`services/`): `supervisor/`, `principal/`, `capability/`,
`task/`, `resource/`, `policy/`, `audit/`, `provenance/`, `secret/`, `package/`,
`session/`, plus post-POC: `update/`, `recovery/`, `account/`, `application/`,
`scene/`, `window/`, `notification/`, `background-work/`, `clipboard/`, `search/`,
`index/`, `share/`, `file/`, `media/`, `text/`, `voice/`, `accessibility/`,
`localization/`, `backup/`, `restore/`, `diagnostics/`, `device/`,
`connectivity/`, `telephony/`, `emergency/`, `location/`, `sensor/`, `power/`.

**Functionality (POC set):**
- `supervisor/` — process lifecycle, restart-on-fault, health, crash isolation (a service trap never takes down the control plane).
- Each of principal/capability/task/resource/policy/audit/provenance — a typed service front end over the corresponding core module, with authenticated IPC, resource metering, and restart-during-transition correctness.
- `secret/` — sealed secret storage; never logged; redaction at boundaries.
- `package/` — signature verification service; refuse unsigned/tampered.
- `session/` — session principals, ephemeral isolation.

**Acceptance:** malicious component trap does not crash control plane; component
cannot touch undeclared fs/network; cancellation interrupts a component; memory
budget enforced; service restart during a state transition recovers cleanly.

---

### Track 4 — Runtimes (native, WebAssembly, Android, web)

**Goal.** Untrusted/semi-trusted execution adapters with hard resource ceilings.
Never authorization authorities. Milestone 2 (native+wasm), Milestone 4 (android),
Phase E (web). Layer: `runtimes`.

**Directories** (`runtimes/`): `native/{host,lifecycle,sandbox}`,
`wasm/{host,wit,metering,interruption}`, `android/{image,bridge,permissions,
lifecycle,storage,notifications,capabilities,compatibility}`,
`web/{engine,origins,permissions,downloads,bridge}`, `apple-portability/*`.

**Functionality:**
- Native component host: load, sandbox, lifecycle, cancellation, resource ceiling.
- Wasmtime component host: WIT bindings, fuel/memory metering, interruption, trap containment.
- Android (Milestone 4): AOSP/Cuttlefish image, isolated runtime, APK install/launch, permission→capability mediation, one capability bridge, crash containment, accurate unsupported-dependency reporting.
- Web engine seam with origin isolation and permission mediation.

**Acceptance:** malicious wasm contained; APK launches; unauthorized host
capability request denied at the boundary; runtime crash does not crash shell.

---

### Track 5 — Agent execution plane   ⟵ the north star lives here

**Goal.** Where **agents plan, call models and tools, coordinate with each other,
request approvals, and record provenance** — with a human able to watch, approve,
deny, and talk to them live. Milestone 1 (host/model/tool adapters) → Milestone 3
(full). Layer: `agents` (requests capabilities via services).

**Directories** (`agents/`): `host/`, `lifecycle/`, `planner/`, `graph-compiler/`,
`scheduler/`, `router/`, `model/{interface,local,remote}`, `tool-registry/`,
`context/`, `retrieval/`, `approvals/`, `policy/`, `provenance/`,
`injection-defense/`, `knowledge/`, `memory/`, `device-control/`.

**Functionality:**
- `host/` — the agent execution host: spawns agents as task-bound principals with scoped capabilities.
- `lifecycle/` — agent create/suspend/resume/retire; idle agents consume no scheduled CPU.
- `planner/` + `graph-compiler/` — intent → task graph; compile to schedulable nodes with dependencies, splits, merges.
- `scheduler/` — committed work preempts speculative; background yields to human interaction; fair budgets.
- `router/` — model routing across providers; provider neutrality; fallback; unavailable-model handling (manual usability preserved).
- `model/{interface,local,remote}` — a provider-neutral model interface; local model process (unloadable under memory pressure); remote adapters; deterministic model outputs in the simulator.
- `tool-registry/` — typed tool contracts; capability-gated invocation; idempotency and `outcome_unknown` on uncertain external results.
- `context/` + `retrieval/` + `knowledge/` + `memory/` — the context broker and personal-knowledge retrieval; bounded context; no secret leakage in logs.
- `approvals/` — approval requests raised to the human; exactly-once execution on approval; refuse replay.
- `injection-defense/` — treat retrieved content as untrusted; prompt-injection containment.
- `provenance/` — every model/tool call and inter-agent message recorded to the ledger.
- **Inter-agent coordination** — agents exchange work through the task graph and typed messages under capabilities, so one agent handing a subtask to another is a real, audited, capability-checked event the shell can render live.

**Acceptance:** three agents with differing authority run in parallel; one is
denied; one raises an approval executed exactly once; cancellation stops model
streaming; every agent action is attributable in provenance; system remains
usable when a model is unavailable.

---

### Track 6 — Graphics & design system

**Goal.** The real rendering foundation and the original design language: an
actual compositor path, an original icon set, real typography, and a continuous
motion system — the visual layer the shell and apps consume. Milestone 3;
industrial-design standard §34. Layers: `graphics`, `design`.

**Directories:** `graphics/{compositor,renderer,scene,surfaces,color,materials,
effects,animation,text,images,video,capture,privacy}`;
`design/{tokens,icons,typography,motion,materials,color,sound,haptics,components,
layouts,accessibility}`.

**Functionality:**
- Compositor + scene graph + surfaces; the display-list renderer (already present) becomes the renderer under a compositor.
- **Original icon language** (`design/icons/`): documented grid, optical stroke rules, filled/outlined states, RTL mirroring, high-contrast/reduced-transparency, accessible names, vector sources, deterministic generation, snapshot tests that reject out-of-grid paths, inconsistent view boxes, missing labels, clipping, and any resemblance to proprietary glyphs. **(Fixes the "icons don't match the design".)**
- Real typography with dynamic type, bidi, tabular numbers, global scripts; no essential control depends on truncation.
- **Continuous motion system** (`design/motion` + `graphics/animation`): navigation, task split/merge, blocking, completion, failure, cancellation, capability grant/revoke, handoff, launch, notifications; interruptible, reduced-motion-safe, frame-budgeted. **(Fixes "no animations".)**
- Materials with opaque/high-contrast/low-power fallbacks; independently tuned dark mode.
- Semantic token system (§34.2) consumed by all components; brand overrides accent/decoration only.
- Capture/privacy: unbypassable privacy indicators for screen/camera/mic.

**Acceptance:** icon test suite passes with zero grid/label/mirroring defects;
motion meets frame budget and respects reduced-motion; tokens drive every
component; accessibility contrast floor holds in light and dark.

---

### Track 7 — Shell (the agent-native UI)

**Goal.** The complete phone shell where the human sees and directs agents in real
time. Milestone 3 → Phase B. Consumes services via typed clients only.

**Directories** (`shell/`): `boot/`, `onboarding/`, `lock/`, `home/`, `command/`,
`task-graph/`, `approvals/`, `activity/`, `notifications/`, `quick-controls/`,
`launcher/`, `library/`, `multitasking/`, `search/`, `files/`, `settings/`,
`privacy/`, `resources/`, `endpoints/`, `update/`, `recovery/`, `developer/`,
`emergency/`, `offline/`, plus form-factor profiles `phone/ tablet/ desktop/
wearable/ spatial/ vehicle/ room/ robot/ screenless/`.

**Functionality:**
- Boot, lock/authentication, onboarding.
- Home dashboard (greeting, command bar, in-motion tasks, active-task flow graph, dock).
- Universal command surface (natural intent → planner).
- **Live task-graph view** — agents and their subtasks animating as they coordinate.
- Approval center — narrow, explicit consent; nothing consequential without it.
- Activity ledger UI — the audit ledger, human-readable.
- Principal & capability inspectors; resource/privacy dashboards.
- Notifications, quick controls, app library, multitasking, search, files, settings.
- Every surface has empty, loading, partial, offline, failure, restricted, accessibility, and localized states (§34.5).

**Acceptance:** every canonical demonstration state is visible; no consequential
action without approval; all product text from brand resources; accessibility
baseline passes; agent activity is legible as it happens.

---

### Track 8 — Default application suite

**Goal.** The first-party apps that ship on the device, each a real app that
integrates with the agent plane. Phase B/D/E. Consume the public SDK.

**Directories** (`applications/`): `phone/`, `messages/`, `contacts/`, `camera/`,
`photos/`, `browser/`, `files/`, `settings/`, `clock/`, `calculator/`,
`calendar/`, `notes/`, `mail/`, `maps/`, `store/`, `support/`, `locator/`,
`credentials/` (passkeys), plus the **new first-party `agents/` app**.

**Per-app functionality (representative):**
- **Agents (new default app)** — a first-class view of every agent: who they are, their scoped capabilities, running tasks, live inter-agent messages, provenance, and controls to pause/revoke/talk-to an agent. This is the human's window into the agent society.
- **Settings** — with full sub-panes: General, Accessibility, Battery, Wi-Fi, Bluetooth, Notifications, Privacy & Security, Display, Sound & Haptics, Focus, Storage, Software Update, Developer, About — each a real settings surface bound to the relevant service.
- **Phone/Contacts** — dialer, call history, contacts, voicemail (telephony seam).
- **Messages** — conversations, compose, agent-drafted replies with approval.
- **Calendar** — events, agent scheduling with approval.
- **Camera/Photos** — capture, library, agent description with privacy indicators.
- **Files** — browse, agent file actions under capabilities.
- **Store** — real install decisions (reviewed/signed/sandbox vs sideload/blocked).
- Mail, Notes, Clock, Calculator, Maps seam, Browser seam, Support, Locator, Credentials.

**Acceptance:** each app launches from the library/dock; integrates at least one
agent capability with correct approval; works manually when agents/models are
unavailable; matches the design language.

---

### Track 9 — Session virtualization & continuity (Personal Compute Instance)

**Goal.** The user's environment persists independent of any one device; tasks
continue across endpoints exactly-once; endpoints are revocable. Milestone 5 →
Phase F. Layer: `session`.

**Directories** (`session/`): `instance/`, `host/`, `client/`, `protocol/`,
`presentation/`, `state/`, `synchronization/`, `conflict/`, `transport/`,
`endpoint/`, `revocation/`.

**Functionality:**
- Personal Compute Instance that exists while every physical endpoint is offline.
- Encrypted transport; second endpoint client; authenticated endpoints.
- Task continuation across endpoints with no duplicate external action (exactly-once across handoff).
- Endpoint revocation; conflict resolution without silent data loss; offline reconciliation.
- Audit identifies both endpoint principals.

**Acceptance:** canonical task continues across endpoints; no duplicate external
action; revoked endpoint loses access; audit names both endpoints.

---

### Track 10 — SDK, developer platform, emulator, examples

**Goal.** Third parties can build, test, sign, distribute, update, and debug apps
and agents. Milestone 4 → Phase E. Layer: `sdk` (no dependency on private app/shell code).

**Directories:** `sdk/{zig,c,wit,web,android,agents,design,testing,examples,
templates,documentation}`; `emulator/*`; `examples/*` (calendar-agent,
document-agent, travel-agent, approval-flow, native/wasm/android/web app,
autonomous-device, session-handoff); `store/*` backend (catalog, review, signing,
distribution, entitlements, policy, appeal, commerce).

**Functionality:** stable SDKs per runtime; agent SDK; design SDK; testing
harness; templates; docs/samples; device emulator with snapshots; the example
agents that drive the canonical demo; store review/signing/entitlement pipeline;
debugger/profiler/diagnostics.

**Acceptance:** a third party independently builds, signs, distributes, updates,
and debugs an app and an agent from published SDKs.

---

### Track 11 — Security architecture (Phase A)

**Goal.** Remove POC bypasses; make the platform defensible. Layer: `security/`.

**Directories:** `crypto/`, `keystore/`, `attestation/`, `authentication/`,
`authorization/`, `sandbox/`, `secret-memory/`, `integrity/`,
`exploit-mitigation/`, `privacy-indicators/`, `redaction/`, `incident/`.

**Functionality:** cryptographic primitives behind a Zig-owned adapter; hardware
keystore; attestation; sandbox hardening; secret memory that never pages/logs;
integrity fail-closed; exploit mitigations; unbypassable privacy indicators;
redaction; incident response hooks; threat models per subsystem; fuzzing.

**Acceptance:** POC bypasses removed; integrity failures fail closed; independent
security assessment path defined; fuzz corpus green.

---

### Track 12 — Storage, persistence & recovery (Phase A)

**Goal.** Durable, encrypted, recoverable state. Layer: `storage/`, `core/{update,recovery}`.

**Directories:** `storage/{block,filesystem,database,object,encryption,integrity,
migration,backup,restore,synchronization,quota}`.

**Functionality:** encrypted at rest; integrity-checked; atomic updates; rollback;
corrupt-state recovery; disk-full behavior; backup/restore; quota; migration;
local-first replication seam for session continuity.

**Acceptance:** restart and corruption recovery pass; signed reproducible images;
rollback works; disk-full and corrupt-durable-state handled.

---

### Track 13 — Boot, kernel & hardware bring-up (Phase A/H)

**Goal.** The literal OS layer: verified boot, kernel adapters/policies, and the
hardware abstraction for a reference device. Layer: `boot/`, `kernel/`, `hardware/`.

**Directories:** `boot/{chain,verified,measurements,recovery,early-ui}`;
`kernel/{adapters,scheduler-policy,memory-policy,device-policy,security-hooks}`;
`hardware/{abstraction,boards/{emulator,reference},display,input,audio,camera,
modem,sim,wifi,bluetooth,nfc,gnss,usb,battery,charging,thermal,sensors,haptics,
biometrics,secure-element,accessories}`.

**Functionality:** measured/verified boot chain; recovery; early UI; kernel
scheduler/memory/device policy and security hooks over the host kernel adapter;
a hardware abstraction layer with an emulator board and a reference board; per-
peripheral drivers/adapters.

**Acceptance:** device boots from the pinned build through verified boot; HAL
drives the emulator board; secure boot measurements verify.

---

### Track 14 — Networking, connectivity & communications (Phase C)

**Goal.** Radios and comms. Layers: `networking/`, `communications/`, relevant `services/`.

**Directories:** `networking/{stack,dns,http,websocket,quic,vpn,firewall,
captive-portal,hotspot,reachability,policy}`;
`communications/{telephony,messaging,contacts,call-history,voicemail,emergency,
carrier}`.

**Functionality:** network stack; DNS/HTTP/WebSocket/QUIC; firewall/VPN; hotspot;
reachability; Wi-Fi/BT/NFC/SIM-eSIM via HAL; telephony, SMS/RCS where supported,
emergency calling, carrier settings, regulatory controls, airplane mode.

**Acceptance:** selected-market carrier/emergency/regional requirements pass.

---

### Track 15 — Media, sensors & input (Phase D)

**Goal.** Camera, audio, sensors, biometrics, and full input. Layers: `media/`, `input/`.

**Directories:** `media/{audio,video,camera,photo,playback,recording,routing,
sessions,codecs}`; `input/{touch,keyboard,pointer,handwriting,voice,gaze,gesture,
switch-control,text-services}`.

**Functionality:** camera/photos pipeline; microphone/audio routing; media
sessions; playback/recording; screen capture; sensors; biometrics behind the
secure-element boundary; health/motion permission classes; full input incl.
keyboard, voice, handwriting, gaze, gesture, switch-control; text services.

**Acceptance:** privacy indicators unbypassable; interruptions correct; input
accessibility (switch-control, voice) works.

---

### Track 16 — Operations & release (Phase A/H)

**Goal.** Build, sign, ship, observe. Layers: `infrastructure/`, `packaging/`, `tools/`.

**Directories:** `infrastructure/{build,ci,artifact,signing,update,rollout,
telemetry,support,security,development}`; `packaging/{manifests,policies,images,
recovery,emulator,release}`; the full `tools/` set (image-build/sign, release,
rollback, sbom, license, source-repro, certification, crash-symbols, etc.).

**Functionality:** reproducible image build + signing; staged rollout; rollback;
consented telemetry; fleet health; advisories/CVE intake; SBOM; licensing;
regional config; support diagnostics.

**Acceptance:** signed reproducible images; rollback works; SBOM + license clean;
reproducibility check green on a fresh machine.

---

### Track 17 — Form-factor profiles (Phase B+)

**Goal.** The shell adapts beyond the phone without encoding the phone as center.

**Functionality:** presentation profiles for handheld, tablet, desktop, wearable,
spatial, vehicle, room, robot, appliance, screenless voice, and remote virtual
session — each defining input, output, attention, privacy, motion, distance,
latency, safety, connectivity, and energy constraints. Identity and task graphs
move; device capabilities do not (glasses may approve without install authority;
a screenless endpoint gives reversible audio confirmation).

**Acceptance:** the canonical task presents correctly on at least two additional
profiles with capability-appropriate restrictions.

---

### Track 18 — Autonomous-device platform (Phase G)

**Goal.** The same principal/capability/task/audit model safely controls physical
devices. Layer: `agents/device-control`, device SDKs.

**Functionality:** device capabilities; real-time control classes; robotics and
appliance adapters; spatial/vehicle profiles; sensor boundaries; autonomy policy;
operator takeover; safety envelopes; device simulation; partner SDKs — **without**
delegating latency-critical control to remote language models.

**Acceptance:** a simulated device is controlled through the same authority model
with operator takeover and a safety envelope.

---

### Track 19 — Production launch (Phase H)

**Goal.** Ship. Reference hardware, certification, support.

**Functionality:** reference hardware; manufacturing test; secure provisioning;
supply-chain controls; repair; certification; privacy docs; security response;
bug bounty; support; updates; LTS; developer relations; launch apps.

**Acceptance:** selected-market certification; recovery/update targets;
accessibility; independent security assessment; support readiness.

---

## Part III — Immediate sequence

The visual foundation (light phone frame, standard proportions, design-matched
home) is shipping now. The next branches, in order:

1. **Track 1 — Core control plane**, built out completely (the trusted kernel). This is the starting point and everything depends on it.
2. **Track 2 — IPC contracts.**
3. **Track 3 — Services** behind real boundaries.
4. **Track 4 — Runtimes** (native + wasm first).
5. **Track 5 — Agent execution plane** — the north star: agents coordinating live, human watching and approving.
6. **Track 6 — Graphics & design** — real icons, real motion (also closes the fidelity gaps).
7. **Track 7 — Shell** — the live human↔agent surface.
8. **Track 8 — Default apps**, incl. the new **Agents** app and full **Settings**.
9. **Track 9 — Session continuity**, then Tracks 10+.

Each track is one large branch, finished and merged before the next opens, with
every module meeting the definition of done above. Progress is tracked in the
live task list and crossed off only after verification.

---

## Part IV — Graphics-rebuild infrastructure decisions

The graphics rebuild (retained Zig compositor owning every frame; Skia, HarfBuzz,
FreeType, and the GPU APIs as engines behind Zig adapters) fixed two CI
infrastructure decisions so the engine and GPU work is verified, not deferred.

### Engine build cache

Vendored C/C++ engines are compiled from source (built-when-present), but CI
builds each **once per pin, not once per run**. Zig content-addresses every
object by its source bytes, flags, target, and compiler, so an engine whose pin
is unchanged resolves to the same cache entry and is not rebuilt. The gates
workflow caches `.zig-cache` keyed on the pin manifests (`engines.lock.json`,
`toolchain.lock.json`) plus the build files, so the built objects persist across
runs and a pin bump rebuilds exactly once — on the upgrade branch, where full
verification already runs. The `engine-cache` gate asserts the property: after a
warm build, a rebuild recompiles no vendored engine source. "HarfBuzz costs a
long compile" is therefore true once per pin, not once per run.

### Correctness on lavapipe, performance on hardware

The GPU pipeline is verified headless against **Mesa lavapipe** (a conformant,
CPU-only Vulkan implementation), so the swapchain, render passes, pipelines,
command buffers, the Skia-on-Vulkan adapter, and every pixel-conformance and
cross-backend test run in CI deterministically — with no vendor variance, which
is better for pixel-diff gates than a real GPU. The device layer is developed and
tested live against lavapipe; nothing is built blind.

Gates split accordingly:

- **Correctness and conformance** gates run on lavapipe in CI.
- **Performance** gates (frame-time p99, 120 Hz, thermal) are **hardware** gates.
  They run on a real-GPU runner, provisioned separately, and until then are
  reported as pending — visibly skipped by name, never silently green (the same
  rule as the design-extract skip). The performance lane blocks only Checkpoint
  G3's timing assertions; every checkpoint before it is fully verified on
  lavapipe.
