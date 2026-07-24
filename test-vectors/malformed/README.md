# Malformed input test vectors

Shared vectors of deliberately malformed input across the platform's parsing
boundaries. Every one must be refused cleanly — rejected with a reason, never
crashing, hanging, or partially applying. Any implementation must produce the
stated outcome for every one of them.

| Vector | Input | Expected outcome |
| --- | --- | --- |
| `truncated-manifest` | a manifest cut off mid-field | refused, no partial state |
| `trailing-garbage` | a valid record followed by extra bytes | refused |
| `integer-overflow-length` | a length field near the type maximum | refused, no wide-arithmetic overflow |
| `negative-count` | a count that underflows when decremented | refused |
| `duplicate-keys` | a record declaring the same key twice | refused |
| `unterminated-string` | a string with no terminator | refused |
| `deeply-nested` | nesting past the depth ceiling | refused, bounded work |
| `cyclic-reference` | a reference that points back to itself | refused, no unbounded loop |
| `wrong-magic` | a header with the wrong magic bytes | refused |

The contract is fail-closed and bounded: a malformed input never produces a
partial commit and never causes unbounded work.
