# Component test vectors

Guest modules used to verify the component runtime's boundary. Each is stated
in text form so a reviewer can read what it does; the runtime compiles the
binary form derived from it.

The vectors are shared: any implementation of the host interface must produce
the stated outcome for every one of them. A change to the expected outcome is a
change to the boundary's contract and needs the decision record updated with it.

| Vector | Expected outcome |
| --- | --- |
| `benign.wat` | completes, returns 7 |
| `unreachable.wat` | traps, contained |
| `spin.wat` | fuel exhausted, or interrupted when a deadline is armed |
| `grow-memory.wat` | growth beyond the ceiling fails, guest observes -1 |
| `import-filesystem.wat` | refused: declares an import, none supplied |
| `import-network.wat` | refused: declares an import, none supplied |
| `import-clock.wat` | refused: declares an import, none supplied |
| `import-random.wat` | refused: declares an import, none supplied |
| `import-environment.wat` | refused: declares an import, none supplied |
| `malformed.wat` | refused at compile time |
| `stack-exhaustion.wat` | traps, contained |
| `divide-by-zero.wat` | traps, contained |
| `out-of-bounds.wat` | traps, contained |
