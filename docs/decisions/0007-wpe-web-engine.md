# ADR 0007: WPE WebKit is the web engine, behind a Zig adapter

- Status: accepted
- Date: 2026-07-27
- Affects: dependency, public API, security

## Context

The platform needs to render web content — a browser, and installable web apps — and it must do
so as a *tenant* of the platform's own compositor, not as a second window system. The compositor
owns the scene tree, the damage tracking, the effects, and the frame pacing; a web engine has to
hand it textures to place as layer nodes and take frame callbacks from it, never drive its own
swapchain or run its own GPU process alongside ours. It also has to run the network and each web
origin as untrusted child processes the platform can budget and revoke, because a page is the most
hostile input the device accepts.

Reproducing a web engine is not on the table: a conformant, secure engine is a multi-thousand-
person-year body of work, and the security floor depends on tracking upstream CVE fixes fast.

## Decision

The web engine is **WPE WebKit** — the WPE port of WebKit, with **libwpe** and the
**wpebackend-fdo** backend. It is pinned in `engines.lock.json` to exact released tags with each
archive's SHA-256 and SPDX licence recorded, fetched and digest-verified by `vendor-engines`, and
built minimally: the WPE port only, unneeded features disabled, no duplicate copies of dependencies
the platform already owns.

The adapter lives at `runtimes/web/engine`; WebKit's C types do not cross it. Through it, each web
view renders to a texture the platform owns (exported as a dmabuf / EGLImage and imported as an
external-texture layer node), so web content inherits the compositor's damage tracking, effects,
and zero-idle pacing and never touches the swapchain. The engine's UIProcess runs inside the web
runtime host; each WebProcess and the NetworkProcess are untrusted child principals with budgets,
and a WebProcess crash tears down its origin only. Every engine permission prompt becomes a host
capability request the capability service decides — deny by default, origin-scoped — rather than
the engine's own permission store, and the NetworkProcess routes through platform network policy
with no bypass sockets. Everything read out of a page is labelled untrusted before it reaches an
agent.

On the macOS development host only, WKWebView may sit behind the same adapter interface; it is
compiled out of product images and the CI lane is green when it is absent (the SDL2 discipline).

## Alternatives

**Chromium / CEF / Electron.** Rejected, and recorded here so it is not reopened: Chromium ships
its own compositor, GPU process, and scheduler, and cannot be a tenant under our compositor without
fighting it for the display, the GPU, and frame timing. Embedding it would mean two renderers and
two schedulers, which is exactly the architecture the single compositor exists to avoid.

**Gecko.** Rejected: not offered as an embeddable engine with a supported embedding API.

**Servo.** Rejected: not production-complete for the web content real sites serve.

**A proprietary engine.** Rejected: ineligible — it cannot be vendored, pinned, and audited from
source the way the security floor requires.

## Consequences

Gives the platform a conformant, actively-maintained web engine that composites as a layer node
and isolates by origin. It is the heaviest C++ dependency the platform carries; the content-
addressed build cache compiles it once per pinned digest rather than on every CI run, and the
minimal build scope keeps what is compiled to the WPE port. The adapter is the one surface that
hands the engine input or reads content out of it, so the prohibitions gate can reason about the
boundary.

## Security implications

A web engine parses the most untrusted input on the device. The containment is layered: origins are
the isolation unit with per-origin state under storage encryption and quota; the NetworkProcess and
each WebProcess are budgeted, revocable child principals; page permissions are host capability
requests decided deny-by-default and origin-scoped, not the engine's to grant; page content is
labelled untrusted before any agent sees it, with adversarial-page tests required; and secure
surfaces (payment and credential fields) respect capture rules at the composite boundary. WebKit
ships CVE fixes quickly, so the pin carries a named security-update path: a watcher tracks WebKit
security advisories, and a version bump is verified by re-resolving the pin's digest from the
upstream release before it lands.

## Resource implications

The pinned source is large — WebKit is among the biggest C++ codebases — so it is fetched and
digest-verified into the build cache when the adapter is built, never committed, and compiled once
per digest by the content-addressed cache rather than on every run. libwpe and wpebackend-fdo are
small by comparison. Correctness and conformance gates run against the software (lavapipe) lane;
the performance of web compositing is a hardware gate on the real-GPU runner.
