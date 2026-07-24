# Signing infrastructure

How release signing keys are held, used, and rotated. Signing is the root of the
platform's trust: a device accepts an image because it is signed by a key the
device trusts, so the handling of that key is the handling of everything.

## Key custody

- Production signing keys live only in a hardware security module. They are never
  exported, never copied to a build host, and never present in an emulator
  bundle or any developer-facing artifact.
- A build host requests a signature over a digest; it never receives the key.
  The module signs the digest it is given and returns the signature.
- Access to request a production signature is limited to the release role and is
  logged with the digest signed, the requester, and the time.

## The signing decision

A signature is produced over an image **digest**, not the image bytes, so the
thing signed is small, verifiable, and reproducible from source. The device
verifies the signature against the digest and verifies the digest against the
image it measured. Both must hold; either failing refuses the boot.

## Rotation

- Keys rotate on a fixed schedule and immediately on any suspected compromise.
- A new key is trusted by devices through a signed trust update carrying the new
  public key before any image is signed with it, so no device is ever asked to
  trust a key it has not already been told about.
- The retired key is revoked; images signed by it after the revocation point are
  refused. Anti-rollback ensures a revoked-key image cannot be reintroduced.

## Invariant

A distributed image is always signed by a currently-trusted production key held
only in the module, and the key never leaves it. Development and emulator
artifacts carry no production key material at all.
