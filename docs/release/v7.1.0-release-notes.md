# Skotiq 7.1.0 Release Notes

## Release

- Version: `7.1.0` (build 28)
- Build date: 2026-09-19
- Channel: `alpha` (see `version.yaml`)
- Previous release: `7.0.0` (build 27)

## Summary

Most of the user interface has been rewritten on one shared set of components,
there are three new features, and a batch of problems found while using the app
on a telescope in September are fixed.

The user-facing notes are in `docs/release/v7.1.0.md`. This document covers the
operational detail: what is supported, what changed at the wire and the
database, and what was and was not tested.

## Supported platforms

| Platform | Status | Build artifact | Tested? |
| --- | --- | --- | --- |
| Linux x64 | supported | `skotiq-7.1.0-linux-x64.tar.gz` | Yes. The test suites and all the project's checks were run on Linux against this tree, and the release bundle was built from it. |
| Windows x64 | supported, not tested for this release | `skotiq-7.1.0-windows-x64.zip` | No. Built by CI on a Windows runner, but not installed or run. No bundle audit, no golden re-capture. The ASCOM COM worker change here compiles and was reviewed, but has not been run. |
| Android | supported, not tested for this release | `skotiq-7.1.0-*.apk` | No. Built and signed by CI, not installed. |
| macOS | unsupported | — | Builds in CI, not tested. |

## Supported hardware

Unchanged from 7.0.0 — see `docs/supported-hardware-by-platform.md`. One vendor
fix here: the LX200 code now accepts `+05:00` as well as `+05` from the NYX when
it asks for the timezone.

## What changed

See `docs/release/v7.1.0.md` for the full list. In brief:

- Every screen rebuilt on one component library, with a new navigation rail and
  a page header on each screen.
- Sequencer: three display densities, repeated steps collapsed into one row,
  the running branch pinned while scrolling, Settings/Activity/Notes tabs on
  step details, Queue tab renamed Targets.
- DepthLock: measure a marked region of a target across nights and report how
  much more integration it needs, or that more will not help.
- Focuser backlash measured by two sweeps rather than typed in by hand.
- Wi-Fi positioning with per-level permission and a stated accuracy radius.
- Four defects found on the telescope, fixed: the slew arrival check comparing
  mismatched coordinate epochs, the polar alignment axis fit picking the wrong
  pole, the freeze from reading a large catalogue on the UI thread, and
  exposures continuing through a guider failure before the mount was parked.

## Security and remote access

Unchanged from 7.0.0. Two things specific to this release:

- The recovery endpoint has a new `parkAndCloseWhenRecoveryGivesUp` field. It is
  optional and defaults to off, so a client that does not send it cannot turn
  parking on by accident. The other six fields are still required, so a partial
  write is rejected rather than silently resetting anything.
- The DepthLock endpoints sit behind the same authentication as the rest of the
  headless API. Unauthenticated requests get a 401.

## Migration and compatibility

- No database migration in this release.
- Master frames and sidecars written by 6.2.0 are still rejected. That version
  had a normalisation bug that erased stars, and the files are refused at
  `MASTER_STATE_VERSION 2`. Re-stack from your subframes; the subframes are
  fine.
- The default focuser backlash changed from 350 to 0. If a user was relying on
  the old default, they should run the calibration rather than re-entering 350.
- Desktop, mobile and the update manifest are all at 7.1.0 build 28. The release
  build fails if they ever disagree.

## What was tested

- 6,732 Dart tests across 11 packages, no failures (4 skipped)
- 3,039 Rust tests, no failures (24 ignored)
- `cargo clippy` across the workspace and all targets, with the same denied
  lints CI uses, no warnings
- Static analysis: no errors, no warnings
- The project's own checks: placeholder detection, fail-closed policy,
  behavioural audit, dependency hygiene, version consistency, bridge boundary,
  platform capability, UI consistency, oversized files, headless API contract
  and route policy — all pass, including their self-tests
- `cargo deny check licenses` passes; the cargo duplicate-versions list matches
  the committed baseline exactly
- The constellation hub's own analysis and tests pass
- `dart format` and `cargo fmt --check` clean
- The Linux release bundle builds from this tree and contains
  `libskotiq_bridge.so`

Not done for this release: Windows runtime, Android runtime, and any use on a
telescope.

## What has not been tested

> These fixes were made on the rig, not at a desk. The imaging chain in this release was worked
> out live on real hardware — a Pegasus NYX-101 mount, a ZWO camera, a ZWO EAF focuser and
> guiding, on Windows — with new builds going onto the machine while it was imaging and the code
> iterated until the behaviour was right under the sky. The slew-frame check, the polar-alignment
> fit, the freeze on the first plate solve and the guider arbitration were all settled that way.
>
> Also measured on those nights: plate solving is accurate to 0.17 arcseconds, checked
> independently, and that EAF has about 105 steps of backlash. One thing is still unexplained —
> the mount moved 12.1 degrees when it was told to move 10.
>
> Not covered: a full unattended night from dusk to dawn. The Windows and Android downloads are
> built by CI and were not separately installed and exercised for this release, macOS and iOS are
> not built at all, and switches, domes, covers and the remaining camera SDKs are in the app but
> have not been checked against hardware.

Other limitations carried into this release:

- SFTP has no password authentication, pending a decision about a dependency.
  Key authentication works.
- The curves operation in the Darkroom renders but cannot be edited.
- Denoise on very large colour masters has a high peak memory use.
- With no observing site set, the default altitude trigger skips targets. The
  run outcome says so.
- Weather safety fails closed by default: with no weather device and an API that
  has never been reached, an unattended rig will park. `fail_open` changes this.

## Rollback

The previous release is `v7.0.0` (build 27) and its artifacts are still on the
GitHub releases page. No database migration runs in 7.1.0, so rolling back needs
no database restore — install the 7.0.0 bundle over the top.
