# Developer quick start

From a clean clone to a running demonstration. Everything here works with no
prior setup and no tools installed system-wide.

## Requirements

A POSIX host — macOS on Apple Silicon or x86_64, or Linux on x86_64 or aarch64 —
with `curl` or `wget`, `tar`, `awk`, and a SHA-256 utility. Windows hosts use
`bootstrap.ps1` instead of `bootstrap.sh`; the rest is the same.

Nothing else. In particular, do not install Zig: the repository pins its own
compiler and installing a different one is how a build stops being reproducible.

## Set up

```sh
git clone <repository> avos
cd avos
tools/bootstrap/bootstrap.sh
```

Bootstrap reads `toolchain.lock.json`, downloads the pinned compiler and every
pinned component from their official sources, **verifies each against the digest
in the manifest before extracting**, and installs them into `.tools/`, which is
ignored by version control. A digest that does not match discards the archive
and installs nothing.

Put the compiler on `PATH` for the shell you are working in:

```sh
export PATH="$(tools/bootstrap/bootstrap.sh --print-path):$PATH"
zig version    # 0.16.0
```

Confirm the checkout is sound before doing anything else:

```sh
zig build doctor
```

It reports the host, whether the running compiler is the pinned one, whether the
manifest carries verified digests, whether any dependency floats, whether the
brand layer is complete, and whether the local specification exclusion is in
force.

## Run the demonstration

```sh
zig build simulator -- --scenario=canonical-demo
```

This runs the canonical sequence and prints what the system can account for:
the principals, the task graph, the activity ledger, and whether the run met its
acceptance criteria.

```text
principals
  c8feb31c  agent  calendar  1 capability(ies)
  0397f926  agent  documents  1 capability(ies)
  8a721265  agent  travel  1 capability(ies)

task graph
  6bdf9249  cancelled     prepare for the scheduled event
    f1079474  succeeded     inspect the calendar
    a2ed6d53  cancelled     retrieve local documents
    ad98d838  cancelled     plan the route
      b775b2bc  succeeded     confirm attendance with the venue

activity ledger
  ...
  010  0397f926  action_denied           denied              refused: not authorized
  013  8a721265  approval_requested      awaiting_approval
  014  315f516c  approval_decided        succeeded
  015  8a721265  capability_used         succeeded           [left device]
  016  8a721265  action_denied           denied              refused: budget exhausted

acceptance
  ok    unauthorized operation denied
  ok    consequential action held for approval
  ok    approved action executed exactly once
  ok    replay of the approval refused
  ok    root cancellation ended descendants
  ok    no unfinished tasks remain
  ok    memory returned to baseline
  ok    ledger sequence unbroken
```

Read the ledger rather than the summary. Event 010 is an agent being refused an
operation it was never granted. Events 013 and 014 are a consequential action
being held and then decided by a human. Event 015 is that action running once,
leaving the device. Event 016 is the *same* action attempted again and refused,
because the approval granted a single use.

The exit code is 0 only when every acceptance criterion holds, so this is
usable as a check rather than only as a demonstration.

Useful options:

```sh
zig build simulator -- --no-ledger          # omit the ledger
zig build simulator -- --format=json        # machine-readable
zig build simulator -- --seed=1234          # a different run; same seed replays exactly
```

The seed determines every identifier, so two runs with the same seed produce
identical output and can be compared byte for byte.

## Watch a boot fail

Reading a test that asserts a device refuses a tampered stage is not the same as
seeing the screen it would have shown. The boot scenario walks the real chain,
signs its own stages, injects one fault, and prints both what the device
concluded and the panel it would draw:

```sh
zig build simulator -- --scenario=boot --fault=tampered-control-plane
```

```text
boot (tampered_control_plane)

stages
  bootloader      version 7    measured 350ae70ed43ccb5e
  kernel          version 7    measured 7c2f712a5b31004c
  control_plane   version 7    REFUSED  SignatureRejected

attested summary  2b0d2a8d66bb43ef41d9186efbb29401
support code      2b0d2a8d

the device did not boot; it will boot_recovery_image

what the screen shows

    +----------------------------------------+
    |the installed system could not be       |
    |verified; starting recovery to repair it|
    |                                        |
    |this will take a few minutes and does   |
    |not erase your data                     |
    +----------------------------------------+
```

The four faults, and what each demonstrates:

```sh
# nothing goes wrong; three stages measured, the shell takes over
zig build simulator -- --scenario=boot --fault=none

# caught at the first stage, where nothing is yet trusted to find a recovery
# image, so the device falls back to the slot that last worked
zig build simulator -- --scenario=boot --fault=tampered-bootloader

# caught at the last stage, where a recovery image can be loaded
zig build simulator -- --scenario=boot --fault=tampered-control-plane

# a genuine but older kernel, refused by the anti-rollback floor
zig build simulator -- --scenario=boot --fault=downgraded-kernel
```

Take away what the device could fall back on and it stops rather than running
something unverified:

```sh
zig build simulator -- --scenario=boot --fault=tampered-bootloader \
  --no-previous-slot --no-recovery-image
```

```text
    +----------------------------------------+
    |the installed system could not be       |
    |verified and no trusted alternative is  |
    |available; this device needs servicing  |
    |                                        |
    |contact support and quote the code below|
    |                                        |
    |e3b0c442                                |
    +----------------------------------------+
```

Halting is worse for the owner than a working device and better than an
untrustworthy one. Notice what is not on any of these screens: there is no
option to continue anyway, because an option a person can press is an option an
attacker can arrange to have pressed.

The exit code reports whether the device *behaved correctly*, not whether it
booted — refusing a tampered stage is the right outcome, so it exits 0. Booting
past a fault, or stopping with nothing to show, is what fails.

`--format=json` gives the same run in machine-readable form.

## Watch an update fail and roll back

An update writes the new system to the spare slot, boots it, and keeps it only
once it starts correctly. If it hangs, the device returns to the version that
worked. The scenario drives the real updater through the same calls an install
path makes:

```sh
zig build simulator -- --scenario=rollback --outcome=hangs-on-start
```

```text
update (hangs_on_start)

steps
  before the update                   would boot primary     bootable
  staging into the spare slot         would boot primary     bootable
  spare slot written and verified     would boot primary     bootable
  spare slot selected for next boot   would boot secondary   bootable
  boot attempt 1 failed               would boot secondary   bootable
  boot attempt 2 failed               would boot secondary   bootable
  boot attempt 3 failed               would boot primary     bootable
  returned to the working slot        would boot primary     bootable

running version 2.0  (update not kept)
the device was bootable at every step: yes
```

The four outcomes:

```sh
zig build simulator -- --scenario=rollback --outcome=boots-cleanly   # commits
zig build simulator -- --scenario=rollback --outcome=hangs-on-start  # rolls back
zig build simulator -- --scenario=rollback --outcome=is-a-downgrade  # refused before writing
zig build simulator -- --scenario=rollback --outcome=is-corrupt      # refused before committing
```

Read the `would boot` column. Only three of the four outcomes keep the update,
and in every one of them some slot is bootable at every step — the property the
two-slot design exists to hold. The exit code reports that invariant, not
whether the update committed.

## Run the tests

```sh
zig build test
```

Around 550 tests across the domain model, the runtimes, the shell, storage, the
session layer, the tools, the decoders, and the acceptance suites. They need no
network, no device, and no fixtures on disk.

To see them by module:

```sh
zig build test --summary all
```

The acceptance suites are the ones worth reading first. Each holds a milestone
to what it must demonstrate, and each lives outside the modules it exercises so
it can only use the interfaces a real caller has:

| Suite | What it holds |
| --- | --- |
| `tests/acceptance/agent_shell.zig` | every state visible, no unapproved action, brand text, accessibility |
| `tests/acceptance/android_compatibility.zig` | mediation, denial, fault containment, honest dependency reporting |
| `tests/acceptance/session_continuity.zig` | continuation, exactly-once effects, endpoint revocation |
| `tests/acceptance/crash_recovery.zig` | six transitions, each from both sides of a crash |
| `tests/acceptance/integrated_demonstration.zig` | the twelve canonical steps, in order |

## Run every gate

```sh
infrastructure/ci/gates.sh
```

This is exactly what continuous integration runs — the definition of "green"
lives in the repository, not in a provider's configuration, so what passes here
passes there.

```sh
infrastructure/ci/gates.sh --list       # what it will run
infrastructure/ci/gates.sh --offline    # skip the gate that needs the network
```

Checks that need a reference device report by name as skipped on a host without
KVM. An absent gate that printed nothing would eventually be read as a passing
one.

## Individual checks

```sh
zig build format-check     # formatting, no writes
zig build format           # apply formatting
zig build convention-check # attribution, comment content, naming
zig build standin-check    # a stand-in on a path a device could execute
zig build brand-check      # product naming outside the brand layer
zig build source-repro     # two builds of this source produce one image
zig build version-lock -- --verify   # pins still match official sources
zig build fuzz             # deeper decoder exploration
```

## Build and sign an image

An image is what a device installs: a set of files, a version, and a device
class, reduced to one digest that a signature covers and the boot chain
measures.

```sh
zig build image-build -- --root=. --device-class=reference --version=1.2.3
```

```text
image 1.2.3 for reference
security generation 0
753 file(s), 2431009 byte(s)
digest 279fdae3d39ad45b5e31afa33527c162fc572e4db10810da726a0e4a6d13cb2a
```

The digest carries no timestamp, no builder identity, no host path, and no
ordering that depends on how a directory happened to be walked. That is what
`zig build source-repro` checks: two builds of the same source produce one
image, so a signature says *these bytes follow from this source* rather than
*a particular machine produced these bytes*.

Signing needs a key file holding a seed as hexadecimal. This tool never writes
one — a release key a build tool could mint is a release key anyone who can run
the build tool can mint.

```sh
zig build image-sign -- --public-key --key=release.seed > release.pub
zig build image-sign -- --sign --digest=<digest> --key=release.seed
zig build image-sign -- --verify --digest=<digest> --key=release.pub --signature=<sig>
```

Change one byte of one file and the digest changes, so the signature stops
covering it:

```text
image-sign: the signature does not cover this image
```

## Change the brand

The build reads the brand document at configure time, so replacing it rebrands
every surface with no source edit:

```sh
zig build simulator -Dbrand=brand/reference/brand.json
zig build test -Dbrand=brand/reference/brand.json
```

Both brands must pass every gate. That second build is what proves the product
name has not leaked out of the brand layer.

## Where to look next

- `docs/public/known-limitations.md` — **read this before drawing conclusions**;
  it states what is absent, what is narrower than its name suggests, and what
  has never been measured
- `docs/public/architecture-overview.md` — trust zones and how authority works
- `docs/architecture/boot.md` — the verified chain, measurement, and recovery
- `docs/security/secure-boot.md` — what a device can prove, and what it cannot
- `docs/operations/build.md` — compiler policy, pinning, and the gates
- `docs/security/threat-model.md` — adversaries, assets, boundaries
- `docs/decisions/` — why things are the way they are

## If something fails

`zig build doctor` first: most problems are a compiler that is not the pinned
one, or a checkout that has not been bootstrapped.

A `source-tracked` failure means a file exists locally but is not in version
control. A personal ignore file outside the repository can match a directory the
repository owns; `git check-ignore -v <path>` names the pattern responsible.

A `version-lock --verify` failure means the committed pins no longer match what
the official sources publish. That is a real finding, not noise: inspect the
difference before regenerating.
