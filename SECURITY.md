# Security

## Reporting

Report suspected vulnerabilities privately to the address published in the
brand resource layer under `support_uri`. Do not open a public issue for an
unfixed vulnerability.

Include the affected component, the compiler and host used, a reproduction, the
observed and expected authority behavior, and any capability, task, or audit
identifiers involved. Do not include real personal data, credentials, or secret
material in a report.

## Scope

The trusted computing base is the primary concern: the principal, capability,
task, resource, audit, secret, session, package, update, and policy services,
plus the IPC layer that authenticates and binds capabilities to them.

Findings are in scope when they let a principal act without authority, widen
authority beyond an issued capability, bypass approval for a consequential
action, evade the audit ledger, escape a runtime isolation boundary into the
control plane, or extract secret material.

The following are explicitly not implemented and therefore not in scope as
vulnerabilities: production cellular and emergency services, carrier
certification, Apple binary compatibility, Google Mobile Services, production
payments, and a commercial application marketplace.

## Security properties require tests

A security property without an automated or reviewable verification path is not
an implemented property. A report that identifies a claimed property with no
corresponding test is a valid finding.

## Threat model

`docs/threat-model.md` records the adversaries, assets, trust boundaries, and
assumptions this system defends. A change that alters a trust boundary requires
an architecture decision record in `docs/decisions/`.

## Cryptography

This project does not invent cryptographic primitives or protocols. Every
cryptographic choice requires a current security review, an official stable
implementation pinned by exact version and digest, a misuse-resistant API, test
vectors, documented key lifecycle, rotation and revocation strategy, defined
failure behavior, and a migration path.

## Disclosure

Vulnerability handling, advisory publication, and CVE intake are established in
Phase H of the platform roadmap. Until then, this repository is in a private
implementation stage and has no published response-time commitment.
