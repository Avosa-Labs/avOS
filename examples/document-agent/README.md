# Document agent example

An agent that retrieves local documents to gather context for a task — the
second principal in the canonical demonstration, and the one that shows
provenance and taint.

## What it demonstrates

- **Scoped file access.** The agent is granted a specific folder and reaches
  nothing outside it. A path that tries to climb out with `..` is refused
  (`applications/files/scope`).
- **Untrusted content.** Text retrieved from a document is labeled untrusted the
  moment it enters the agent. It can be summarized and reasoned over, but it
  cannot silently become an instruction or launder into authority the agent did
  not already hold — untrusted content never elevates a capability.
- **Read, not write.** The agent's grant is read-only; an attempt to modify a
  document is denied, because the capability was attenuated to reading.

## Manifest sketch

```
agent: documents
capabilities:
  - files.folder("~/work"): read
tools:
  - retrieve_documents   (uses files.folder read)
```

## Expected behavior

`retrieve_documents` returns the contents of files within the granted folder,
each tagged untrusted. A path outside the folder, or a write, is refused. The
retrieved text influences the agent's output but never its authority.
