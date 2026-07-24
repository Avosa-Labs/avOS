# Package test vectors

Shared vectors for application package validation: signing, digest integrity,
and the entitlements a package declares. Any implementation of the package
boundary must produce the stated outcome for every one of them.

| Vector | Package | Expected outcome |
| --- | --- | --- |
| `signed-intact` | signed by a registered developer, digest matches | accepted |
| `unsigned` | no developer signature | refused |
| `wrong-signer` | signed by a key not registered to the developer | refused |
| `tampered-payload` | valid signature, payload digest altered | refused |
| `countersigned` | developer-signed and store-countersigned | accepted for distribution |
| `missing-countersignature` | developer-signed only, offered for store distribution | refused |
| `entitlement-declared` | requests a capability it declares and justifies | eligible for review |
| `entitlement-undeclared` | requests a capability absent from its manifest | refused |
| `downgrade` | update whose version precedes the installed one | refused |
| `signer-change` | update signed by a different signer than the installed build | refused |

A distributed build is always the reviewed one from a known developer; an update
never changes signer or downgrades.
