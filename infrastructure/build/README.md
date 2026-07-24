# Build infrastructure

How the platform is built reproducibly on any host and in continuous
integration. The build's promise is that a clean checkout, on any supported
host, produces the same result — no private machine state, no floating
dependency.

## Hermetic toolchain

- The compiler is pinned to an exact version and digest in
  `toolchain.lock.json`, fetched and verified by the bootstrap rather than taken
  from whatever the host happens to have.
- An unqualified or mismatched compiler is rejected by construction; the build
  fails closed with an actionable message rather than proceeding on an unpinned
  toolchain.
- Dependencies are pinned in `build.zig.zon`; nothing floats.

## Gates

Continuous integration runs the full gate suite (`infrastructure/ci/gates.sh`)
on every pull request across the supported hosts. The gates cover formatting,
build, tests, source-tracking, authoring conventions, brand neutrality, stand-in
absence, image reproducibility, performance budgets, and toolchain lock
verification. A gate that fails blocks the change.

## Cost discipline

CI is triggered on pull requests only and uses a content-addressed cache, so the
public-repository lane stays within its free allowance. A run reuses the cached
result of any input that did not change.

## Reproducibility

The build is deterministic: `tools/source-repro` builds the same source twice and
compares the resulting image digests. A difference is a reproducibility bug and
is treated as a release blocker.

## Invariant

A clean checkout on any supported host, with the pinned toolchain, produces a
bit-for-bit identical image, and no change merges without a green gate suite.
