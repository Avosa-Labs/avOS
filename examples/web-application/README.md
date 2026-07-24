# Web application example

An installable web application running through the web runtime — the most
portable way to ship to the platform, and the one whose permissions are bounded
by its manifest.

## What it demonstrates

- **Manifest is the ceiling.** The web app declares its permissions in its
  manifest. At runtime it can request only what it declared; a request for an
  undeclared permission is refused before the person is even asked
  (`sdk/web/permissions`).
- **The person still decides.** A request within the declared set proceeds to the
  person for their decision — the manifest bounds what *can* be asked, and the
  person bounds what is *granted*.
- **Installable for the POC.** The platform supports installable web applications,
  so the app has an identity and a persistent place rather than being a transient
  page.

## Manifest sketch

```
application: web
permissions:
  - geolocation
  - notifications
```

## Expected behavior

The app may request geolocation or notifications, each subject to the person's
approval. A request for the camera — not declared — is refused outright, so the
manifest stays an honest, complete statement of what the app can ask for.
