# Android capability example

An Android application running through the Android-compatible runtime and
exposing a capability to the rest of the platform — the bridge that lets existing
Android software participate as a first-class capability provider.

## What it demonstrates

- **Compatibility, honestly bounded.** Android applications run through an
  Android-compatible runtime. The example shows an Android app admitted through
  that runtime and reachable through a declared capability, without pretending it
  is native.
- **Bridge registry is closed.** A capability call from the platform reaches the
  Android app only through the closed bridge registry; a consequential call
  crosses the same approval gate as any other (`sdk/android/bridge`).
- **No authority leak.** The Android app gains only the capabilities it was
  granted through the bridge; the runtime does not hand it platform authority it
  did not declare.

## Manifest sketch

```
application: android
runtime: android-compat
exposes:
  - capability: share_target   (consequential → requires approval)
```

## Expected behavior

The platform invokes `share_target` through the bridge; because it is
consequential, it is held for approval before the Android app acts. A call to a
capability the app did not register is refused. This is the
`application capability call reaches the bridge` acceptance path.
