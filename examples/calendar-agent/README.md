# Calendar agent example

A minimal agent that reads a person's calendar to answer "when am I free?" — the
smallest useful agent, and the first principal in the canonical demonstration.

## What it demonstrates

- **Least authority.** The agent declares one capability: read access to the
  calendar's free/busy view. It never requests event details, and the platform
  holds it to exactly what it declared (`sdk/agents/manifest`,
  `applications/calendar/availability`).
- **Free/busy, not detail.** Asked about a time window, the agent learns only
  that the window is busy — never the title, attendees, or location — because it
  was granted free/busy access, not detail access.
- **No consequential effect.** Reading availability changes nothing external, so
  the agent runs without an approval gate. It is the baseline against which
  agents that *do* act are measured.

## Manifest sketch

```
agent: calendar
capabilities:
  - calendar.free_busy: read
tools:
  - query_availability   (uses calendar.free_busy)
```

## Expected behavior

Given a busy window, `query_availability` returns `busy` and nothing more. A
request for event detail is refused before it reaches the calendar, because the
agent holds no detail capability.
