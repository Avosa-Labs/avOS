# Artifact infrastructure

How build outputs are named, stored, and traced back to their source. An
artifact is only trustworthy if it can be tied to the exact source that produced
it, so every artifact is content-addressed and reproducible.

## Content addressing

- An artifact is named by the digest of its content, not by a mutable label. Two
  builds that produce the same bytes produce the same name; a change of one byte
  is a change of name.
- A human-readable version and channel are metadata attached to the digest, never
  a substitute for it. The digest is the identity.

## Provenance

Each stored artifact records:

- the source commit it was built from,
- the toolchain version and pinned digest (`toolchain.lock.json`),
- the build inputs, so the build can be reproduced,
- the signature over its digest, if it is a release artifact.

## Reproducibility

A release artifact must build bit-for-bit identically from the same source and
toolchain. The `tools/source-repro` check builds twice and compares digests; a
non-reproducible artifact is not releasable, because an artifact that cannot be
reproduced cannot be audited.

## Retention

- Release artifacts and their provenance are retained for the supported lifetime
  of the versions they represent.
- Development artifacts are regenerable and expire on a fixed schedule; they are
  never a source of truth.

## Invariant

Every release artifact is content-addressed, reproducible from recorded source
and toolchain, and signed over its digest.
