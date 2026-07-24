# IPC test vectors

Shared vectors for the inter-process message boundary: framing, capability
handle passing, and the refusal of malformed or oversized frames. Any
implementation of the IPC boundary must produce the stated outcome for every
one of them.

| Vector | Frame | Expected outcome |
| --- | --- | --- |
| `well-formed` | valid header, declared length matches payload | accepted |
| `length-underrun` | declared length exceeds payload | refused |
| `length-overrun` | payload exceeds declared length | refused |
| `oversized` | declared length beyond the frame ceiling | refused |
| `zero-length` | header with empty payload | accepted |
| `truncated-header` | header shorter than the minimum | refused |
| `handle-passed` | frame carrying an opaque capability handle | handle delivered, no pointer exposed |
| `handle-forged` | frame referencing a handle the sender does not hold | refused |
| `unknown-opcode` | header with an unrecognized operation | refused |

Agents and applications receive opaque capability handles across this boundary,
never privileged object pointers; the `handle-passed` and `handle-forged`
vectors pin that guarantee.
