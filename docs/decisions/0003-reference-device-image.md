# ADR 0003: Reference device image

- Status: proposed
- Date: 2026-07-22
- Affects: dependency, compatibility, trust boundary

## Context

The Android compatibility runtime needs a device to run on. The permission
mediation and the application bridge are implemented and tested, but neither has
executed a real application binary, because nothing has provided an Android
system to execute it in.

Two facts constrain the choice, and both were established by inspection rather
than assumed.

**The reference tooling does not publish verifiable artifacts.** The
`android-cuttlefish` project's latest release is `v1.55.0`, marked stable, and
carries **zero release assets**. System images come from the Android continuous
integration service, which serves build artifacts identified by build number
rather than by a release feed with digests. The pinning discipline that worked
for the compiler and the component runtime — resolve the latest stable release,
take the publisher's own digest, verify before use — has nothing to attach to
here.

**The reference device requires a host this project does not currently have.**
Cuttlefish requires KVM on Linux. Development is on macOS on Apple Silicon,
where `/dev/kvm` does not exist. Nothing about the reference device can be
verified on the machine the rest of the system is developed on.

Neither fact is a reason to skip the milestone. Both are reasons to record what
the milestone actually costs before committing to an approach that hides it.

## Decision

Adopt AOSP with Cuttlefish as the reference device, and pin it by **build
identifier plus a locally computed digest** rather than by a publisher-supplied
one.

The version policy permits this: it lists "Android build identifier" among the
acceptable pinning forms alongside semantic version and content digest. The
manifest records the build identifier, the artifact location, and a digest
computed when the artifact is first fetched and reviewed. Subsequent fetches
verify against that recorded digest.

This is weaker than the compiler and component-runtime pins, and the difference
must be stated rather than smoothed over. Those digests are published by the
project that built the artifact. This one attests that the artifact has not
changed since a human first fetched and reviewed it — trust on first use, and no
more than that.

The image runs on a Linux host with KVM. Continuous integration for anything
requiring a booted device runs there and nowhere else, and the developer
workflow on macOS keeps working without it: the simulator, every unit test, and
every acceptance test that does not need a booted device continue to run
locally.

## Alternatives

**Wait for a release feed with digests.** Cleanest, and not available. The
artifacts are produced by a continuous integration service, and no timeline
suggests that changing. Waiting would mean the compatibility milestone never
starts.

**Vendor the image into the repository.** Would give a content digest under our
own control. Rejected: a multi-gigabyte binary in version control makes every
clone expensive forever, and it moves a distribution problem into history where
it cannot be removed.

**Build AOSP from source.** Gives a genuine content chain from source to image.
Rejected for the proof of concept as disproportionate: a full AOSP build is
hours of compute and a large amount of infrastructure to reproduce, and it does
not change what the compatibility runtime demonstrates. It becomes the right
answer in Phase A, when reproducible images stop being optional.

**Use an Android emulator image instead of Cuttlefish.** Simpler to obtain and
runs on more hosts. Rejected because the emulator's system image diverges from
the AOSP platform the runtime targets, and a compatibility claim made against a
different image is not a claim about the platform this system integrates.

## Consequences

Makes possible: executing real application binaries against the mediation that
is already built, which is the only way the compatibility claim becomes real.

Makes harder: the reference device cannot be exercised on macOS, so part of the
verification lives on Linux. That split has to be visible in the gate output
rather than silently skipped, or an absent gate will eventually read as a
passing one.

Accepts: a weaker integrity property for this artifact than for every other
pinned dependency. Recorded here so it appears in a security review rather than
being discovered during one.

Forecloses nothing. Building from source in Phase A supersedes this pin without
changing anything above the runtime boundary.

## Security implications

Boundaries touched: host foundation, and control plane to isolated runtime.

Introduced: an artifact whose integrity rests on trust on first use rather than
on a publisher's signature. Until it is replaced by a source-built image, a
compromise of the artifact service between the first fetch and a later one is
detected, but a compromise before the first fetch is not.

This is the weakest link in the dependency chain, and it should be named as such
in the threat model rather than left implicit. `docs/security/threat-model.md`
already lists package supply-chain compromise; this record is the concrete
instance of it.

Unchanged: the runtime remains outside the trusted computing base and is never
an authorization authority. A compromised image can lie to the applications
inside it; it cannot grant host capabilities, because the host issues those and
checks them against its own store.

## Resource implications

Multi-gigabyte artifact, cached in the ignored project-local tool directory and
never committed. Boot time and per-application launch time are unmeasured and no
claim is made about either; both belong in `docs/performance/benchmarks.md` once
a device has actually booted.

## Verification

Required before this record moves to accepted:

- the reference device booting on a Linux host with KVM, from the pinned build
  identifier
- a digest computed at first fetch, recorded in the manifest, and verified on
  every subsequent fetch, with a mismatch discarding the artifact
- a supported application installing and launching
- an application capability call reaching the bridge and being checked against
  the host capability store
- an unauthorized host capability request denied at the boundary
- the runtime faulting without the shell or control plane being affected
- an application declaring an unsatisfiable service dependency reported rather
  than launched
- the gate reporting the device-dependent checks as skipped, by name, on a host
  that cannot run them

Until every one of these passes, Android binary execution is not implemented and
must not be described as available. The permission mediation and the application
bridge are implemented and tested and may be described as such; they are a
different claim.

## Migration

None yet. When Phase A replaces this with a source-built image, the manifest
entry changes and the runtime boundary does not: nothing above the runtime
depends on where the image came from.
