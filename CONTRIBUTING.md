# Contributing to idlescreen

Bug fixes, focused features, tests, and documentation improvements are welcome.
Use an issue first for changes to product topology, signing identities, camera
lifecycle, screen-saver hosting, or release format.

## Development setup

1. Fork the repository and create a branch from `main`.
2. Install Xcode 26 and XcodeGen 2.46.0.
3. Run `xcodegen generate`.
4. Make the smallest complete change and add coverage for non-trivial behavior.
5. Run the deterministic gates in [docs/BUILDING.md](docs/BUILDING.md).

Physical workflows are consent-gated because they can install applications,
register background services, open a camera, start a screen saver, lock the
session, or change system state. Do not weaken those guards for local testing.

## Commits

Use Conventional Commits without emoji:

```text
<type>(<optional scope>): <description>
```

Allowed types are `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`.

## Pull requests

- Target `main` and keep the change focused.
- Explain user-visible behavior and verification.
- Keep generated `IdleScreen.xcodeproj` synchronized with `project.yml`.
- Update `CHANGELOG.md` for user-visible changes.
- Never include raw camera frames, private configuration, credentials, personal
  filesystem paths, design exports, or local planning artifacts.
- Wait for CI and required review before merge.

Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
