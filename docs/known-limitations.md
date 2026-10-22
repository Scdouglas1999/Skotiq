# Known Limitations

This page is the public-release holding area for limitations that are accepted
for a release candidate. Do not use it to hide blockers. An accepted limitation
must be documented, understandable to users, paired with a workaround when one
exists, and reflected in release notes.

## 7.1.0 — what has actually been tested

> These fixes were made on the rig, not at a desk. The imaging chain in this
> release was worked out live on real hardware — a Pegasus NYX-101 mount, a ZWO
> camera, a ZWO EAF focuser and guiding, on Windows — with new builds going onto
> the machine while it was imaging and the code iterated until the behaviour was
> right under the sky. The slew-frame check, the polar-alignment fit, the freeze
> on the first plate solve and the guider arbitration were all settled that way.
>
> Also measured on those nights: plate solving is accurate to 0.17 arcseconds,
> checked independently, and that EAF has about 105 steps of backlash. One thing
> is still unexplained — the mount moved 12.1 degrees when it was told to move
> 10.
>
> Not covered: a full unattended night from dusk to dawn. The Windows and
> Android downloads are built by CI and were not separately installed and
> exercised for this release, macOS and iOS are not built at all, and switches,
> domes, covers and the remaining camera SDKs are in the app but have not been
> checked against hardware.

Evidence: the telescope sections of [`release/v7.1.0.md`](release/v7.1.0.md)
and the rig reports under `reports/live-rig/`.

## 6.1.0 Verified Scope (previous release)

> **6.1.0 adds no new hardware validation.** The most recent real-hardware evidence remains the 6.0.0 Windows bench run between 22 and 26 July 2026 against an ASCOM Pegasus NYX-101 mount, a native ZWO ASI1600MM-Cool camera, and a ZWO EFW filter wheel, alongside a simulator instance. Camera connect, cooling, exposure, and image download are exercised on that hardware. **The mount was never commanded to move**, so slew, sync, park, unpark, homing, and meridian flip are unexercised on real equipment. **No frame was taken under a real sky** — the acquisition path is validated, the sky is not. 6.1.0 changes guiding correction behaviour and native target scoring; both are unit-tested only and **neither has been run on sky**. The web dashboard and the Android companion were driven against a running host, but a second physical device on a real LAN with a firewall in the path was not tested for either release. Fully-unattended **headless** acquisition and a full-night soak are **not** verified and must be supervised. **Linux** is early testing; **macOS** and **iOS** are unbuilt, untested, and ship no artifact. Every other device path — switches, domes, covers, and the remaining vendor SDKs — is **capability-gated**: present in the app, but not a support guarantee until it is verified on your rig.

## 6.0.0 Verified Scope (previous release)

This is the scoped capability statement for the current release. It must match
the README "What is actually verified" section and the `## What's verified`
section of [`release/v6.0.0.md`](release/v6.0.0.md) word for word:

> Real-hardware validation for 6.0.0 was a Windows bench run between 22 and 26 July 2026 against an ASCOM Pegasus NYX-101 mount, a native ZWO ASI1600MM-Cool camera, and a ZWO EFW filter wheel, alongside a simulator instance. Camera connect, cooling, exposure, and image download are exercised on that hardware. **The mount was never commanded to move**, so slew, sync, park, unpark, homing, and meridian flip are unexercised on real equipment. **No frame was taken under a real sky** — the acquisition path is validated, the sky is not. The web dashboard and the Android companion were driven against a running host, but a second physical device on a real LAN with a firewall in the path was not tested. Fully-unattended **headless** acquisition and a full-night soak are **not** verified and must be supervised. **Linux** is early testing; **macOS** and **iOS** are unbuilt, untested, and ship no artifact. Every other device path — switches, domes, covers, and the remaining vendor SDKs — is **capability-gated**: present in the app, but not a support guarantee until it is verified on your rig.

Evidence: the *Hardware validation* section of
[`release/v6.0.0.md`](release/v6.0.0.md). A dedicated
`release-evidence/6.0.0.md` has not been cut yet.

## 5.0.0 Verified Scope (previous release)

This is the scoped capability statement that matched the 5.0.0 README callout,
the 5.0.0 release notes, and `supported-hardware-by-platform.md` word for word.
It is retained as the historical record for 5.0.0 and is superseded by the
6.0.0 statement above:

> Skotiq is verified on **Windows**, where the desktop app drives ASCOM/Alpaca
> cameras, focuser, filter wheel, and PHD2, with plate-solving and planning. Remote
> **monitoring and planning** over the LAN — from the web dashboard and the Android
> companion — are verified. Fully-unattended **headless** acquisition on real ASCOM
> hardware is **still being hardened** and should be supervised. **Linux** is in
> early testing; **macOS** builds in CI with no hardware soak. Every other device
> path is **capability-gated** — present in the app but not a support guarantee
> until verified per rig. The 5.0 Living Sky, automation-unification, and
> desktop master/slave paths are automated/local-stack verified but still need
> a supervised physical-rig and real second-machine LAN validation.

Evidence: [`release-evidence/5.0.0.md`](release-evidence/5.0.0.md).

## Acceptance Rules

A limitation can be accepted only when all of these are true:

- the behavior is intentional for the release scope
- the user impact is documented plainly
- unsupported controls are disabled or fail with an explicit reason
- safety-critical workflows fail closed
- the limitation is included in release notes
- a future owner or tracking issue exists when follow-up is expected

If any item affects mount safety, unattended imaging safety, data loss,
credential exposure, or package install/upgrade integrity, treat it as a
release blocker unless the release explicitly removes that workflow from scope.

## Current Release Candidate Limitations

These are the accepted limitations for the 5.0.0 release candidate.

| Area | Limitation | Impact | Workaround | Release blocker? | Owner/issue |
| --- | --- | --- | --- | --- | --- |
| Hardware/platform | Official archives do not redistribute vendor SDK libraries; native paths are capability-gated by user-installed libraries and OS driver availability. | Some vendor devices require ASCOM, Alpaca, or INDI instead of native mode. | Install a compatible vendor library/driver or use a verified backend listed in `docs/supported-hardware-by-platform.md`. | No; packaging and release notes state the boundary. | Track vendor-specific verification in the support matrix. |
| Hardware/platform | ASCOM COM is Windows-only. | Linux and macOS users cannot use local ASCOM COM drivers directly. | Use ASCOM Alpaca/ASCOM Remote, INDI, or another supported backend. | No. | Track in `docs/production-readiness/feature-parity-matrix.md` and platform-capability verification. |
| Hardware/platform | Native DSLR control for Canon/Nikon is not a public-release guarantee. | DSLR users may need an external driver/backend. | Use supported ASCOM, INDI, or Alpaca workflows where available. | No, if docs and release notes do not advertise native DSLR support. | Track in `docs/supported-hardware-by-platform.md` and release notes scope review. |
| Hardware/platform | INDI weather and switch parity is not fully verified for release-critical safety. | Linux/macOS observatory safety may require another backend. | Use a verified Alpaca or ASCOM safety/weather path for unattended operation. | Yes for unattended safety claims unless verified. | Track in hardware smoke evidence and `docs/production-readiness/feature-parity-matrix.md`. |
| Remote/headless | Fully-unattended **headless** acquisition on real ASCOM hardware is still being hardened: headless COM-session issues affect mount connect, filter-wheel set, mid-session camera stability, and the sequence start-gate (B1–B6, B18, B19). | Unattended *headless* nights on a Windows ASCOM rig may stall or mis-capture; the desktop GUI path performs the same operations correctly. | Use the desktop app for unattended runs, or supervise headless nights. Remote monitoring and planning over the LAN are reliable. | Yes for an *unattended-headless* acquisition claim; No for monitoring/planning and the desktop scope. | Tracked in `docs/release-evidence/5.0.0.md` and GitHub issues [#1–#6](https://github.com/Scdouglas1999/Nightshade/issues?q=label%3Abeta-gap). |
| Remote/headless | Scoped tokens are coarse-grained (`view`, `control`, `admin`) rather than custom per-route roles. | Operators cannot yet define custom roles for a specific device or workflow. | Issue separate view/control/admin tokens and keep admin tokens limited to trusted operators. | No, if coarse scopes meet the release security model. | Track in Remote Access and Security sections of `docs/production-readiness/public-release-master-checklist.md`. |
| Living Sky | Constellation is self-hosted; Skotiq operates no public/default hub in 5.0. | Users cannot join a global swarm without choosing an operator they trust. | Run `server/skotiq_hub` or use a trusted club/operator hub and enter its URL. | No; this is the explicit 5.0 deployment model. | Hub README and dedicated CI job. |
| Living Sky | New Living Sky native processing and automation paths have automated coverage but no final physical-rig/on-sky soak. | Timing, device, or data-quality behavior may differ on a real rig. | Run a supervised complete night before relying on it unattended. | Yes for unattended claims; no for supervised beta scope. | 5.0 release evidence and hardware campaign. |
| Desktop mirroring | Master/slave mirroring is contract- and local-stack tested, not yet soaked across two physical machines on a real LAN. | Network/firewall and long-session behavior may reveal gaps. | Validate host discovery/manual URL, reconnect, monitoring, and one control cycle on your LAN before depending on it. | No for beta; yes for a fully verified mirroring claim. | 5.0 release evidence. |
| Updates | Windows, Linux and Android builds read this project's GitHub releases and can install an update themselves, but no trusted update key is provisioned, so every download is refused. No release has yet been produced or installed through this path. | The app tells you a newer release exists and then declines to install it; updating stays manual. | Back up, download/verify the next GitHub release, and replace the portable bundle. | Yes for any automatic-update claim, until a signed release has been installed end to end. | Release workflow and `docs/OTA_UPDATE_TESTING.md`. |
| Distribution | Windows is unsigned and Android is debug-signed. | SmartScreen/Android install warnings appear; no managed/store update path exists. | Verify SHA-256/GitHub source and follow the installation guide. | No for public beta; yes for a production/store distribution claim. | Release notes and installation guide. |
| Cloud backup | S3-compatible backup is tested against an in-process object store, not every live S3/MinIO/B2 variant. | Endpoint-specific signing or policy differences may fail. | Test connection and perform a disposable backup/restore before relying on it. | No for beta with this warning. | S3 tests and 5.0 release evidence. |

## Unsupported By Platform

Platform-specific unsupported items must match the Platform Capabilities UI,
`/api/info.platformCapabilities`, and
`docs/production-readiness/feature-parity-matrix.md`.

| Feature/backend | Windows | Linux | macOS | User-facing reason |
| --- | --- | --- | --- | --- |
| ASCOM COM | Available | Unsupported | Unsupported | Requires Windows COM and locally installed ASCOM drivers. |
| ASCOM Alpaca | Available | Available | Available | Network backend; device-specific capability gaps are reported by the Alpaca server. |
| INDI | Available | Available | Available | Requires a reachable INDI server and driver support for the device capability. |
| Native SDK | Capability-gated | Capability-gated | Capability-gated | Requires user-installed vendor SDK libraries and supported OS drivers; official archives do not redistribute them. |
| Simulator | Capability-gated | Capability-gated | Capability-gated | Workflow-specific; use ASCOM, Alpaca, or INDI simulator drivers for hardware-like smoke tests unless an in-app simulator path is explicitly enabled. |

## Release Notes Checklist

Before publishing release notes, verify that each accepted limitation has:

- matching wording in release notes
- a support-matrix entry if hardware/platform related
- an in-app disabled state or explicit error path where applicable
- a troubleshooting or setup doc link when users can self-correct
- a tracking issue or owner for follow-up
