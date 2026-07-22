# Build, toolchain, and version policy

The repository builds from a clean checkout with no private machine state.

## Compiler policy

Zig is the constitutional implementation language. The canonical development
and release baseline is **0.16.0**.

| Line | Role | Adapters | Lane | Claimed as supported |
| --- | --- | --- | --- | --- |
| 0.16.0 | canonical | implemented | green | yes |
| 0.15.2 | compatibility | not implemented | not run | no |
| 0.14.1 | compatibility floor | not implemented | not run | no |

A compiler line is claimed as supported only when its complete lane is green.
0.15.2 and 0.14.1 are pinned in `toolchain.lock.json` and sit inside the
supported window, but their adapters do not exist yet, so the build fails
closed on them with an actionable message rather than claiming support it
cannot demonstrate. Support below 0.14.1 is out of scope.

Prereleases never enter the matrix. A development snapshot such as
`0.17.0-dev.*` carries prerelease metadata and is rejected by construction, not
by convention. When a new stable release appears it enters candidate support
first and becomes supported only after the formatting, build, test, fuzz,
compatibility, recovery, performance, and image gates pass on it.

### Where compiler differences live

```text
compat/zig/
├── line.zig      # which line is running; is it qualified
├── selected/     # resolves adapters for the running line
├── 0_14/         # per-line adapters
├── 0_15/
└── 0_16/
```

The domain model and runtime behavior stay compiler-neutral. The compatibility
boundary may hold build-system adapters, standard-library adapters, I/O
adapters, target-query adapters, and feature probes. It must never fork
business logic, security logic, capability semantics, task state machines,
protocol schemas, or tests by compiler version.

Qualifying a line means implementing its adapters, adding its lane, and
changing `qualificationOf` in `compat/zig/line.zig` — in that order, never the
reverse.

### Upgrades are migrations

Every upgrade branch includes release-note review, security-advisory review, a
compatibility assessment, format and API migration, full build and test
execution, benchmark comparison, a rollback plan, and updated pins and hashes.
Automated update tools may open branches; they must not merge them.

## Dependency policy

Every dependency, tool, image, runtime, and generator uses the latest stable
release available when it is selected or deliberately upgraded. A version is
stable only when its project marks it a final release — nightly, master, dev,
alpha, beta, preview, canary, milestone, release candidate, untagged commits,
floating branches, and floating ranges are all excluded.

"Latest stable" is a selection rule, not a declaration. After selection every
item is pinned exactly by version and verified digest. No declaration may carry
an unconstrained `latest`, wildcard, caret range, branch name, or moving URL.

### The manifest

`toolchain.lock.json` records the resolution: the canonical compiler with its
source and digest, every pinned line with per-target archives and digests, and
an SPDX license per component.

```sh
zig build version-lock              # re-resolve and write for review
zig build version-lock -- --verify  # compare against official sources; write nothing
```

The resolver queries only official release sources, rejects prereleases,
resolves exact versions, requires a digest on every artifact, rejects insecure
artifact locations, records licenses, produces a deterministic diff, and fails
rather than falling back. It never upgrades on its own — committing the result
is a deliberate act with human review.

## Gates

```sh
zig build format-check   # formatting, no writes
zig build                # compile every target
zig build test           # unit tests
zig build brand-check    # no product naming outside the brand layer
zig build doctor         # host, compiler, pin, brand, and policy health
```

A red gate is never committed. Further gates arrive with the milestones that
introduce them: integration, security, adversarial, recovery, compatibility,
simulator, and image.

### Brand independence

The build reads the brand document at configure time, so replacing the document
rebrands every surface with no source edit. Both brands must pass every gate:

```sh
zig build test
zig build test -Dbrand=brand/reference/brand.json
zig build brand-check
zig build brand-check -Dbrand=brand/reference/brand.json
```

The synthetic brand in `brand/reference/` is deliberately a distinctive
non-word. A synthetic brand made of ordinary English words would collide with
legitimate prose and identifiers and make the leak check unusable.

A malformed or incomplete brand document fails the build at configure time
rather than rendering blank product text at runtime.

## Bootstrap

```sh
tools/bootstrap/bootstrap.sh     # POSIX hosts
tools/bootstrap/bootstrap.ps1    # Windows hosts
```

Bootstrap detects host and architecture, installs nothing system-wide, uses
official sources only, rejects prereleases, verifies the digest recorded in the
manifest before extracting, uses a git-ignored project-local tool directory,
works with spaces and non-ASCII characters in paths, supports offline cached
execution, and fails closed on a lock mismatch. It never overwrites a global
Zig installation.

Supported development hosts: macOS on Apple Silicon and x86_64, Linux on x86_64
and aarch64, and Windows 10 or later for the host tools available there.
Production image building may later require Linux; the simulator must not.

## Local working policy

`docs/PLATFORM_SPEC.md` is local-only during the private implementation stage.
It is excluded through `.git/info/exclude`, never through the shared
`.gitignore`, and is never force-added. `zig build doctor` reports whether the
exclusion is in force; the bootstrap launcher performs the repository-level
check:

```sh
git check-ignore -q docs/PLATFORM_SPEC.md   # must succeed
git ls-files --error-unmatch docs/PLATFORM_SPEC.md   # must fail
```

The second command failing is the expected success condition.
