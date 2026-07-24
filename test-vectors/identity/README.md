# Identity test vectors

Shared vectors for principal identity: humans, agents, applications, services,
devices, and sessions as distinct principals, and the endpoint credential
checks that bind an endpoint to a human. Any implementation must produce the
stated outcome for every one of them.

| Vector | Scenario | Expected outcome |
| --- | --- | --- |
| `distinct-kinds` | a human id and an agent id with the same numeric value | distinct principals |
| `stable-id` | the same principal referenced twice | equal identity |
| `endpoint-owner-match` | endpoint credential for human H, instance owned by H | attach admitted |
| `endpoint-wrong-owner` | endpoint credential for human H, instance owned by H' | attach refused |
| `endpoint-present-only` | endpoint granted present, attempts to act | refused |
| `agent-not-human` | agent principal attempts a present-human authorization | refused |
| `unauthenticated` | no credential presented | refused |

The load-bearing property: an endpoint attaches at exactly the authority its
grant carries, never inheriting the authority of the identity it manifests.
