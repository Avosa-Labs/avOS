# Crypto test vectors

Shared vectors for the cryptographic primitives the platform relies on:
SHA-256 digests, Ed25519 signatures, and constant-time comparison. Any
implementation must produce the stated outcome for every one of them. These are
known-answer and behavioural vectors; a divergence is a broken primitive, not a
policy difference.

| Vector | Input | Expected outcome |
| --- | --- | --- |
| `sha256-empty` | empty message | `e3b0c442…852b855` |
| `sha256-abc` | `abc` | `ba7816bf…f20015ad` |
| `ed25519-valid` | message M, signature by key K over M | verifies |
| `ed25519-wrong-message` | message M', signature by K over M | rejected |
| `ed25519-wrong-key` | message M, signature by K over M, checked against K' | rejected |
| `ed25519-mutated-signature` | signature with one bit flipped | rejected |
| `digest-equal` | two identical digests | equal (constant-time) |
| `digest-first-byte-differs` | digests differing in byte 0 | not equal |
| `digest-last-byte-differs` | digests differing in byte 31 | not equal |
| `digest-length-mismatch` | inputs of differing length | not equal |

Constant-time comparison must not short-circuit: the `first-byte-differs` and
`last-byte-differs` vectors exist to assert the decision does not leak the
position of a mismatch through timing.
