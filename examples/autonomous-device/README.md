# Autonomous device example

A session running on an autonomous device — a robot — that contributes its
physical capabilities while holding none of the person's private authority. This
is the platform as a general authority layer for the next generation of devices,
not just phones.

## What it demonstrates

- **Capabilities are the device's, not the identity's.** The person's identity
  and task graph move onto the robot, but what the robot can do is the robot's:
  it exposes movement, actuation, and sensing, and never the person's messages or
  mail (`shell/robot/adaptation`, `test-vectors/session`).
- **Movement without messages.** A task can drive the robot to a location; the
  same session cannot read the person's inbox through the robot, because the
  robot holds no personal-data capability.
- **Autonomy under authority.** The robot acts autonomously within granted
  authority, and any consequential physical action still crosses the approval
  gate — autonomy is bounded execution, not unbounded background work.

## Manifest sketch

```
endpoint: robot
exposes:
  - movement
  - sensing
denied:
  - messages
  - mail
```

## Expected behavior

A movement task runs on the robot. A request to read messages through the robot
is refused. The robot participates fully in the session as a physical principal
while remaining a place the person's private data never travels to.
