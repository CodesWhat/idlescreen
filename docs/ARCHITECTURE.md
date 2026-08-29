# Architecture

idlescreen ships one companion app with an embedded screen-saver extension,
camera agent, renderer framework, and local command tool. The active project is
generated from `project.yml`.

## Repository layout

- `Products/` contains the app, screen saver, helper, and command-line entry
  points that ship inside `IdleScreen.app`.
- `Sources/` contains shared production frameworks and modules.
- `Tests/` contains unit-test targets and test-only support executables.
- `Support/` contains performance and synthetic-gate executables that do not
  ship in the distributed application.

## Product boundary

```text
IdleScreen.app
├── Contents/MacOS/IdleScreen
├── Contents/Frameworks/IdleScreenRenderer.framework
├── Contents/PlugIns/IdleScreenScreenSaver.appex
├── Contents/Helpers/IdleScreenCameraAgent.app
├── Contents/Helpers/idlescreenctl
└── Contents/Library/LaunchAgents/
```

- `IdleScreenApp` owns the Studio, onboarding, diagnostics, and user actions.
- `IdleScreenScreenSaver` hosts the shared renderer in ScreenSaverEngine.
- `IdleScreenCameraAgent` is the only process allowed to open AVFoundation.
- `IdleScreenRenderer` owns Metal resources and all glyph presentation.
- `IdleScreenDisplay` publishes display topology and deterministic scene plans.
- `IdleScreenCore` owns versioned configuration and cross-process data models.
- `IdleScreenSystem` owns app-only registration and System Settings integration.
- `IdleScreenAgent` and `idlescreenctl` implement optional local agent signals.

The `IdleScreenSyntheticGate` targets are test apparatus. They are never
embedded in the distributed application.

## Camera lifecycle

The camera agent is a signed per-user LaunchAgent registered with
`SMAppService`. Clients authenticate the XPC peer, acquire connection-bound
leases, and read generation-fenced frames from a fixed-size App Group mailbox.
Raw frames do not queue through XPC.

Capture starts when the first valid consumer lease arrives and stops after the
last lease expires or its XPC connection closes. Stream generations prevent a
frame produced before a restart or device change from being presented as
current. The renderer falls back to a procedural source when a camera frame is
unavailable or stale.

## Display scenes

One coordinator per process converts the current display topology into an
immutable generation-fenced plan:

- Panorama shares one scene and normalized viewport across displays.
- Per Display assigns an independent deterministic scene to each display.
- Focus Display gives one display the active scene and applies the configured
  quiet treatment elsewhere.

The companion preview and screen saver consume the same planner output. Pixel
Materials uses the same topology boundary so shared terrain and world edges stay
stable across view recreation and display changes.

Procedural modes generate their visible glyph instances through a bounded Metal
compute pass. The CPU procedural implementation remains the deterministic
reference and fallback. Parity tests cover every pattern, viewport, seed,
brightness, contrast, and glyph choice.

## Local agent signals

Codex and Claude integrations are opt-in. Their hook adapters accept bounded
JSON, reduce it to a provider-neutral `AgentSignal`, and pass it to the bundled
`idlescreenctl` process over standard input. The command writes an atomic,
private App Group snapshot with a bounded TTL.

There is no network listener. Prompt text, transcripts, commands, tool payloads,
assistant responses, credentials, and raw hook payloads are outside the signal
schema. The companion and screen saver apply the same expiration, quiet-hours,
priority, and display-destination rules.

## Security invariants

- The responsible companion and camera agent carry the camera entitlement, but
  only the camera agent links AVFoundation or invokes camera APIs.
- The screen saver can request camera demand only after the checked-in generated
  activation decision and shipping policy accept the observed host surface.
- The camera agent admits only expected Team ID and bundle identities.
- Release builds reject `get-task-allow` and require hardened runtime.
- App Group files are validated without following attacker-controlled symlinks.
- Shared snapshots are private from creation and published atomically.
- No camera pixels or private agent content enter diagnostics or retained
  evidence.
- Distribution verification covers every nested signature, entitlement,
  provisioning profile, code directory hash, and the mounted DMG contents.

The active private screen-saver declarations are isolated under
`Products/IdleScreenScreenSaver/Private`. Their upstream attribution is recorded
in `THIRD_PARTY_NOTICES.md`.
