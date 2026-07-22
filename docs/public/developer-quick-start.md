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
zig build brand-check      # product naming outside the brand layer
zig build version-lock -- --verify   # pins still match official sources
zig build fuzz             # deeper decoder exploration
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
