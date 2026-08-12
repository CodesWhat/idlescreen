# Security Policy

## Supported versions

Security fixes are shipped on the latest public release line only.

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |
| Older release lines | No |

## Reporting a vulnerability

Do not open a public issue for a vulnerability.

Use [GitHub private vulnerability reporting](https://github.com/CodesWhat/idlescreen/security/advisories/new)
or email <security@codeswhat.com>. Include the affected version and build,
macOS version, architecture, install method, minimal reproduction, observed
behavior, expected behavior, and impact. Redact camera content, usernames,
paths, credentials, hook payloads, prompts, and transcripts.

You can expect acknowledgement within 48 hours and a status update within seven
days. Fix and disclosure timing depends on severity and release safety.

## Scope

The following are in scope:

- the companion app and embedded screen-saver extension;
- the camera agent, XPC admission, leases, and App Group frame transport;
- configuration, display topology, saved looks, and AgentSignal storage;
- `idlescreenctl` and Codex or Claude hook installation;
- signing, notarization, DMG packaging, and published Homebrew casks; and
- the exact binaries attached to a CodesWhat GitHub release.

Apple's private screen-saver extension declarations are a compatibility risk,
not a security vulnerability by themselves. Third-party macOS, camera-driver,
Homebrew, Codex, or Claude defects should be reported to their owners unless
idlescreen introduces or amplifies the impact.
