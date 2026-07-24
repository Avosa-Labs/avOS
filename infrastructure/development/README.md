# Development infrastructure

How a contributor's local environment mirrors what continuous integration
enforces, so a change that will pass CI is knowable before it is pushed.

## Git hooks

`hooks/install.sh` installs the repository's hooks into a local checkout:

- **pre-commit** — runs the fast gates (formatting, authoring conventions, brand
  neutrality, stand-in absence) before a commit is recorded, so a violation is
  caught at commit time rather than in CI.
- **commit-msg** — enforces the commit-message conventions: a subject under the
  length limit and the required trailers, with no disallowed content.

The hooks are the same checks CI runs, run earlier. They fail closed: a hook that
cannot run blocks the commit rather than passing it silently.

## Local gate parity

The full gate suite (`infrastructure/ci/gates.sh`) runs locally exactly as it
runs in CI, against the pinned toolchain fetched by the bootstrap. "It passed
locally" and "it passed in CI" are the same statement because they run the same
script on the same toolchain.

## Invariant

Every check that can block a change in CI can be run locally first, so a
contributor is never surprised by a gate they could not have seen.
