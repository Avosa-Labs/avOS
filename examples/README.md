# Examples

Reference examples that show how the platform's SDK surfaces compose. Each is
stated in text so a reviewer can read what it demonstrates and trace it to the
modules that enforce it; each references the concrete decision modules and
test-vectors that back the behavior it describes.

They are organized by what they teach:

## Agents

| Example | Demonstrates |
| --- | --- |
| [`calendar-agent`](calendar-agent/) | Least authority; free/busy, not detail; no consequential effect |
| [`document-agent`](document-agent/) | Scoped file access; untrusted content; read-only attenuation |
| [`travel-agent`](travel-agent/) | A consequential action held for approval, executed once, replay refused |
| [`approval-flow`](approval-flow/) | The human-in-the-loop lifecycle, digest-bound, in isolation |

## Runtimes

| Example | Demonstrates |
| --- | --- |
| [`native-application`](native-application/) | C ABI exact match; capability handles, not pointers |
| [`wasm-component`](wasm-component/) | Deny-by-default imports; bounded execution; contained traps |
| [`android-capability`](android-capability/) | Compatibility through the closed bridge registry |
| [`web-application`](web-application/) | The manifest as the permission ceiling |

## Endpoints and continuity

| Example | Demonstrates |
| --- | --- |
| [`autonomous-device`](autonomous-device/) | Movement without messages; capabilities are the device's |
| [`session-handoff`](session-handoff/) | The Personal Compute Instance; one presenter; no duplicated effect |

Together they cover the moat: human and agent principals, capability-native
authority, structured execution with approval, application-capability
interoperability across four runtimes, persistent portable compute, and the
autonomous-device platform.
