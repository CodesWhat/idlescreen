# Contributing to idlescreen

Bug fixes, focused features, tests, and documentation improvements are welcome.
Use an issue first for changes to product topology, signing identities, camera
lifecycle, screen-saver hosting, or release format.

## Development setup

1. Fork the repository and create a branch from the active `dev/v0.1` branch.
2. Install Xcode 26 and XcodeGen 2.46.0.
3. Run `xcodegen generate`.
4. Make the smallest complete change and add coverage for non-trivial behavior.
5. Run the deterministic gates in [docs/BUILDING.md](docs/BUILDING.md).

Install the repository hooks with `lefthook install`. They enforce plain
Conventional Commits, changed-file Swift formatting, Qlty, workflow security,
the complete Xcode test matrix, release fixtures, and an unsigned Release
build before push.

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

- Target `dev/v0.1` and keep the change focused. Only a release promotion pull
  request targets `main`.
- Explain user-visible behavior and verification.
- Keep generated `IdleScreen.xcodeproj` synchronized with `project.yml`.
- Update `CHANGELOG.md` for user-visible changes.
- Never include raw camera frames, private configuration, credentials, personal
  filesystem paths, design exports, or local planning artifacts.
- Wait for CI and required review before merge.
- Never weaken branch or tag protection to merge or release.

Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
