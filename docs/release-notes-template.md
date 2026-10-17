# Skotiq Release Notes Template

Use this template for every public release candidate. Replace bracketed values
with release-specific evidence before publishing.

## Release

- Version: `[version]`
- Release candidate commit: `[commit SHA]`
- Build date: `[YYYY-MM-DD]`
- Reviewer: `[name]`
- Decision: `[ship / no-ship]`

## Release Summary

State what is shipping in one short paragraph. Include only features that have
passed code review, automated checks, and manual QA for this release candidate.

## Supported Platforms

| Platform | Status | Build artifact | Verification |
| --- | --- | --- | --- |
| Windows | `[supported / limited / not shipped]` | `[installer/path]` | `[test evidence]` |
| Linux | `[supported / limited / not shipped]` | `[bundle/path]` | `[test evidence]` |
| macOS | `[supported / limited / not shipped]` | `[bundle/path]` | `[test evidence]` |

Unsupported or limited platform claims must match:

- `docs/supported-hardware-by-platform.md`
- `docs/production-readiness/feature-parity-matrix.md`
- in-app Platform Capabilities
- `/api/info.platformCapabilities`

## Supported Hardware And Drivers

List only hardware classes and driver backends verified for this release.

| Backend | Device classes verified | Platform(s) | Evidence |
| --- | --- | --- | --- |
| ASCOM COM | `[camera, mount, ...]` | Windows | `[hardware/simulator notes]` |
| ASCOM Alpaca | `[camera, mount, ...]` | `[platforms]` | `[hardware/simulator notes]` |
| INDI | `[camera, mount, ...]` | `[platforms]` | `[hardware/simulator notes]` |
| Native SDK | `[vendor/device]` | `[platforms]` | `[hardware/simulator notes]` |
| Simulator | `[workflows]` | `[platforms]` | `[test notes]` |

## New Or Changed Features

- `[feature]`: `[what changed, user impact, verification]`
- `[feature]`: `[what changed, user impact, verification]`

## Security And Remote Access

- Headless authentication mode verified: `[yes/no + evidence]`
- Headless token scopes verified: `[view/control/admin evidence]`
- LAN exposure verified: `[loopback/authenticated LAN/other]`
- `/api/self-test` result: `[summary]`
- `/api/openapi.json` route contract result: `[summary]`
- WebSocket heartbeat/reconnect result: `[summary]`
- High-risk audit logging checked for: `[slew, park, backup restore, file browse, etc.]`

## Migration And Compatibility

- Upgrade source version/profile: `[version/path]`
- Migration result: `[pass/fail]`
- Backup/restore result: `[pass/fail]`
- Remote API compatibility range: `[range]`
- Known incompatible versions: `[versions]`

## Known Limitations

Copy the release-scoped entries from `docs/known-limitations.md`. Include the
user impact, workaround, and whether the item blocks unattended operation.

| Limitation | Impact | Workaround | Release blocker? |
| --- | --- | --- | --- |
| `[limitation]` | `[impact]` | `[workaround]` | `[yes/no]` |

## Fixed Issues

- `[issue id or summary]`: `[fix summary]`

## Verification Summary

| Gate | Command or flow | Result | Evidence |
| --- | --- | --- | --- |
| Production analysis | `dart run melos run analyze:production` | `[pass/fail]` | `[log/path]` |
| Fail-closed audit | `dart run melos run audit:fail-closed` | `[pass/fail]` | `[log/path]` |
| Placeholder audit | `dart run melos run audit:placeholders` | `[pass/fail]` | `[log/path]` |
| Native bridge | `cargo check --manifest-path native/skotiq_native/bridge/Cargo.toml` | `[pass/fail]` | `[log/path]` |
| Desktop tests | `[command]` | `[pass/fail]` | `[log/path]` |
| Core tests | `[command]` | `[pass/fail]` | `[log/path]` |
| Linux build | `[command/environment]` | `[pass/fail]` | `[log/path]` |
| Linux runtime smoke | `docs/production-readiness/linux-release-ci-recipe.md` | `[pass/fail]` | `docs/production-readiness/linux-release-package-metadata.json` with `runtimeSmokeChecks` |
| Hardware smoke | `[devices/simulators]` | `[pass/fail]` | `[notes/path]` |

External release evidence must be validated by:

- `docs/production-readiness/public-release-external-evidence.json`
- `docs/production-readiness/linux-release-build-evidence.json`
- `docs/production-readiness/linux-release-ci-recipe.md`
- `docs/production-readiness/linux-release-package-metadata.json`
- `docs/production-readiness/full-hardware-control-smoke-evidence.json`
- `docs/production-readiness/second-device-lan-firewall-smoke-evidence.json`
- `docs/production-readiness/real-remote-control-actions-evidence.json`
- `docs/production-readiness/final-release-signoff-evidence.json`

Linux release notes must record the structured `runtimeSmokeChecks` generated
by the Linux package metadata tool, including `headless_process_started`,
`api_info_ok`, `openapi_ok`, and `dashboard_asset_ok`.

## Upgrade Notes

Describe required user action before or after upgrade:

- `[backup requirement]`
- `[driver/package requirement]`
- `[settings migration note]`

## Rollback Plan

- Backup location: `[path]`
- Restore command or UI flow: `[steps]`
- Known rollback limitation: `[limitation]`
