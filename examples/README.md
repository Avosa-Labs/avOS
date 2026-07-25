# Examples

These are real programs, not descriptions of programs. Each one builds on the same
frame a shipped app builds on — a real domain, gated through the tool registry, recorded
to the audit ledger the live activity feed reads — so running it exercises the real path,
not a mock of it. Each reads its result back from the ledger it wrote, so a passing
example is evidence the real thing happened rather than a narration that matched.

They are the closed set the SDK example registry publishes ([`sdk/examples/registry.zon`](../sdk/examples/registry.zon)).
The `example-check` gate holds the registry and this directory to the same set: every
registered example is a real, building example, and every real example is registered — so
a name a developer follows from the docs always resolves to something that exists.

## The examples

| Example | What it demonstrates | Real path it drives |
| --- | --- | --- |
| [`hello-agent`](hello-agent/) | Least authority: it learns free/busy, never detail, and is refused the detail it never asked for. | `App.invoke` → registry denial → ledger |
| [`todo-app`](todo-app/) | One domain, two doors: a person and an agent act through the identical code; the feed is read from the ledger, not the agent's mouth; a retry lands one item. | both doors → one `Store.execute` → ledger-derived feed |
| [`camera-capture`](camera-capture/) | A consequential act held for a person, approved, and run exactly once; never taken while the use indicator is dark. | `App.invoke` (held) → `App.approve` → exactly-once domain |

Together, run against one ledger, they are the canonical demonstration in miniature —
least authority, human-and-agent on one domain, and an approval executed exactly once.
[`tests/acceptance/example_walkthrough.zig`](../tests/acceptance/example_walkthrough.zig)
runs all three in sequence and asserts the demonstration against the ledger they wrote.

## Running them

Each example is exercised by its own colocated tests and by the acceptance walkthrough,
so they run as part of the suite:

```
zig build test           # runs every example end to end, against a real ledger
zig build example-check  # holds the registry and this directory to one set
```

Every example ships a [`manifest.zon`](hello-agent/manifest.zon) declaring the
capabilities it requests and the tools it exposes. The conformance test validates each
manifest with the SDK's own `agent_manifest.validate` and pins it to the tools the
example actually registers, so a manifest can never drift from the code.

## Adding an example

An example is added by building it for real and listing it — the gate refuses either half
alone:

1. Create `examples/<name>/` with a source file, a `manifest.zon`, and colocated tests.
2. Wire it into [`examples.zig`](examples.zig) and its manifest into the conformance test.
3. Add `{ .name = "<name>", .path = "examples/<name>" }` to
   [`sdk/examples/registry.zon`](../sdk/examples/registry.zon).

## Not yet built

The roadmap calls for further examples — runtime bindings (native/C-ABI, WebAssembly,
Android, web), session handoff across endpoints, and an autonomous device. They are
**not** in this directory, because a directory of prose that does not build is the broken
link this set exists to avoid. They will be added the same way the three above were: as
real programs, registered and enforced. Until then they live in the roadmap, not here.
