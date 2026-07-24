# Tools

Command-line tools that support building, checking, signing, and releasing the
platform. Each implemented tool is a real, tested executable wired into the build
and, where it guards an invariant, into the gate suite. Following the platform's
honesty rule, a tool directory is filled only when its tool genuinely exists;
planned tools are listed but not stubbed.

## Implemented

| Tool | Purpose | Gate |
| --- | --- | --- |
| `doctor` | Report host, compiler, and pin health | yes |
| `version-lock` | Re-resolve the toolchain manifest from official sources | yes |
| `brand-check` | Verify no brand leak outside the brand resource layer | yes |
| `convention-check` | Verify authoring conventions: attribution, comments, naming | yes |
| `standin-check` | Verify no stand-in reaches production code | yes |
| `image-build` | Reduce a directory to a system image digest, deterministically | yes |
| `image-sign` | Sign an image digest, or check a signature against one | — |
| `source-repro` | Build the same source twice and compare the images | yes |
| `sbom` | Emit a software bill of materials for the source tree | — |
| `license` | Check third-party dependency license compliance | — |
| `rollback` | Decide whether a rollback to an earlier version is permitted | — |
| `package-sign` | Decide whether a signed application package may be distributed | — |
| `release` | Drive a release through the rollout rings, one promotion at a time | — |
| `crash-symbols` | Symbolicate a fault address against a build's symbols | — |

## Planned

These directories are prepared integration points, not stubs. Each will be
introduced when its first complete, tested implementation exists — never as an
empty imitation of the tree.

| Tool | Purpose |
| --- | --- |
| `certification` | Assemble certification evidence for a market |
| `accessibility-audit` | Check surfaces against the accessibility baseline |
| `localization` | Verify localization completeness and fallback |
| `performance` | Run and compare against the performance budgets |
| `power`, `test-vector`, `protocol-codegen`, `icon-build`, `audit-inspect`, `zig-version` | Development and diagnostic utilities |

The distinction between the two tables is the point: what is claimed as working is
working, and what is not is named as not-yet, never disguised.
