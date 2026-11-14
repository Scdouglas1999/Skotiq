# Skotiq 9.0.0 validation

This records preparation of the unpublished 9.0.0 / build 37 stable candidate.
Physical hardware remains unavailable. Windows CI runtime and signed package
verification now pass as recorded below; earlier sections retain their tested
revisions and original limitations. Commands, complete logs,
exit codes, and tested revisions are under
`~/.cache/ns-untangle/notes/codex-release*-tools/`.

## Stable distribution verification — 2026-11-14 UTC

Final build-only CI run [43620240119](https://github.com/Scdouglas1999/Skotiq/actions/runs/43620240119)
passed at application source `4736791e42ae073dc2ff9874323035051a350206`:
Linux x64, Windows x64, all three Android ABIs, and the assembled artifact
verifier. It uploaded `verified-release-assets` without creating a tag or
publishing a release. After download, the source marker and all six archive/APK
checksums matched, and all three production APK signatures passed independent
verification. All five signed OTA manifests passed independent verification
using the app's production update public key. This supersedes the successful earlier runs `43616247197`
(`370ab7139`) and `43619483396` (`3bfbfe9ba`). The subsequent documentation-only
commit does not change this application source or require another binary build.

The Windows CI smoke executed the release binary in a fresh profile. It checked
authentication, HTTP, a real WebSocket pong, explicit simulator connection,
128 × 96 exposure, and the saved 16-bit FITS header and payload. It disconnected
the simulator afterward. This is native Windows execution, but does not replace
interactive Windows use or physical-driver testing. Windows executables have no
Authenticode signature; OTA manifests are signed using the existing identity.

The first portable Linux CI package failed on Debian Bookworm because its
Jammy-built LibRaw required `libjpeg.so.8`. Packaging now follows the bridge's
actual LibRaw SONAME, includes the required JPEG dependency and exact license
notices, and checks every bundled ELF. The CI archive passed a fresh Bookworm
container with networking disabled, dependency checks, API startup, a real
simulator exposure, FITS save/readback, and disconnect. The original archive
failed that same gate before correction.

The Linux job at final application source `4736791e4` passed the same appliance
gate; its archives match the final assembled downloads byte for byte. Both
downloaded archive checksums matched, and all 73 extracted files matched
between tar.gz and zip. The actual packaged launcher then ran on the
owner's normal desktop with networking and seven simulators. A GUI Snapshot
produced a 1920 × 1080 image with 45 detected stars; an explicit API save of
that capture produced a verified 16-bit FITS header and nonempty pixel payload.
The weather page displayed NWS attribution and its current valid time. The
original unsaved editor plan remained unchanged and the sequencer idle.
Profiling and synthetic replay were disabled. This GUI check is separate from
the host-built 26 MP performance workload.

Android now builds each ABI sequentially on Ubuntu 24.04 with a dedicated
bounded Gradle environment. Two earlier Ubuntu 26.04 runners shut down during
compilation without a compiler diagnostic; their logs do not prove an OOM.
The final run completed all ABIs and verified their production APK signatures.
All five OTA manifests passed against the app's update key. The earlier
`370ab7139` signed x86_64 APK installed successfully in an isolated Android 15 /
API 35 emulator. That app launched through its supported voice-action link and paired
through the normal code dialog without admin scope. Tonight displayed the
host's unchanged NGC1245 plan as ready but not started. Keyboard and scroll
automation were unavailable; the check used on-screen keyboard clicks.

That first-launch check exposed a repeated notification prompt after denial
and a voice-action URI incorrectly entering Flutter's page router. Commit
`3bfbfe9ba` requests notification permission once, disables Flutter page routing
for the native voice-action handler, and queues cold-start actions before
FlutterActivity configures its engine. The routing choice follows
[Flutter's custom-link guidance](https://docs.flutter.dev/ui/navigation/deep-linking).
The 227-test mobile suite and analyzer pass. The production-signed `3bfbfe9ba`
APK then passed a fresh API 35 install: one notification prompt, denial followed
by the disabled-notifications warning, and cold-link startup to normal pairing
without an invalid route. Pairing without admin scope displayed the unchanged
host plan and its captured image. The UI Reconnect action transitioned through
reconnecting and returned to Connected. There were no fatal Android or Dart
exceptions in the captured app log. Its Android source is identical to final
application source `4736791e4`; the only intervening source change removes a
duplicate desktop exposure log. The final `4736791e4` APK then installed as an
update, launched through the same link, and reconnected with its existing
pairing without another code. Tonight showed the captured image and unchanged
plan. Each tested launch displayed one notification prompt and continued after
denial with the warning visible; this removes the duplicate within a launch,
not the existing permission request on subsequent launches. No fatal exception
was present in the final app log. This checks Android 15 x86_64 in an emulator,
not a physical phone or the ARM builds' runtime behavior.

Evidence: `~/.cache/ns-untangle/notes/codex-stable-release-20261114/` and
`~/.cache/ns-untangle/notes/codex-stable-artifacts/` under
`candidate-370ab71`, `candidate-3bfbfe9`, and `final-4736791`.
No signing identity was generated or replaced. The temporary emulator and
local link server were stopped; the final packaged Linux desktop remains
running with seven simulators, normal networking, no profiling or replay, and
the original unsaved plan unchanged. Physical rig testing remains unavailable,
and these results do not establish on-sky reliability.

## Test evidence

| Check | Result | Code / evidence |
| --- | --- | --- |
| Full core suite | 8,100 passed, 14 skipped; one changed contract fixture failed | `79a21857a`; `gates/test-core.log`. The native-node fixture now records the effective 30° site floor; it was regenerated and verified in the focused run below. |
| Core release regressions | 71 passed | `ed84eac3a`; DSLR capability failure, site floors, wire-node contracts, and guider ownership/centering; `gates/core-release-regressions.log` |
| Full app suite | 5,436 passed, 1 skipped | `8ac2c699a`; `gates/test-app.log` |
| Desktop / mobile | 1,445 / 227 passed | `8ac2c699a` / `10c0e91d5`; `gates/test-{desktop,mobile}.log` |
| UI / planetarium / remote protocol | 717 / 319 / 249 passed | `10c0e91d5`; matching `gates/test-*.log` |
| Updater / plugins / Dart bridge / design / astro | 175 / 60 / 44 / 1 / 500 passed | `10c0e91d5`; matching `gates/test-*.log` |
| Hub | 207 passed; analyzer clean | `ed84eac3a`; pinned dependencies resolved into a fresh cache because the existing cache returned I/O errors. No dependency versions changed. |
| Relay | 39 passed | `10c0e91d5` plus the test committed as `ed84eac3a`; checks private file permissions and that a failed permission change cannot replace the old secret. |
| Mobile real-socket transport | 3 passed, explicitly enabled | `bc1f7a156`, integrated in `805774b5`; corrected the stale 8.2.0 test host and require actual authentication rejection for the bad-token case. Real HTTP/WebSocket event delivery runs in a private loopback namespace. |
| Full native workspace | Passed; strict clippy passed | `d21e0afda`; `native-ci/{clippy,tests}.log`, exact CI commands with all features and all targets for clippy. Subsequent narrow driver/recovery corrections require their own checks. |
| Old-profile migration | Passed, schema 51 → 70 | Authentic v4.3.0 fixture; matching source/copy SHA256, no missing tables or required settings; `gates/migration-probe.log` |
| Rust license policy | Passed | `ed84eac3a`; `cargo deny --all-features check licenses` |

The core fixture failure was the expected wire representation change, not a
pixel-golden update. Host-specific image goldens were excluded as CI requires;
none were re-baselined. Changed production paths are checked again after merge;
these earlier suite results alone do not certify later source changes.

## Built-app evidence

- Disabled Center instructions and disabled groups each completed two simulator
  exposures. A refused meridian flip then allowed six more frames in 50 seconds.
  The nonconvergent Flat Wizard reported monotonic progress, ended at 85%, and
  emitted one advisory without claiming completion.
- A copied schema-68 mosaic upgraded to schema 70 with all eight panel rows
  unchanged. Desktop, 420-pixel-wide, and red-night views retained the disabled
  panel gap and serpentine order. A new project kept its order after save/reopen.
- A linked companion disconnected while the host continued captures, then
  reconnected to the same running session. The older dashboard was refused
  with HTTP 426.
- Native-backed linked photometry matched all 20 fixture stars with off-center
  CRPIX, skewed/parity-changing CD, and SIP terms. Calibration used catalog V
  magnitudes and exposure-normalized flux. GUI read-mode selection reached the
  real simulated driver's second read mode.
- A dim simulator frame completed and was saved with a warning. Severe-frame
  retention is covered by native regressions; the attempted live severe-frame
  run did not yield valid evidence and is not counted as a pass.

The final combined native sources at `805774b5` pass CI-exact workspace clippy,
Windows workspace/all-target type checking, and the Linux release build. Fifteen
merged recovery/retention tests also pass, including the explicitly enabled
libgphoto2 Directory Browse download/decode/cleanup/retry contract. Original RAW
bytes survive, and no USB camera is opened.

The host-built combined GUI was then driven against scripted PHD2 and simulator
devices. Before the fix, a centering request left external LostLock guiding
active; afterward the recorded RPC stream contains `stop_capture` and the guider
becomes idle. No plate solver is configured, so this proves the pre-move guard,
not a solved-and-centered target. A separate two-frame sequence completed and
saved both FITS files; the GUI showed Completed and 2/2 accepted frames.

An existing-profile backup round trip restored a deliberately changed gain
setting from 137 to 100 and preserved two mosaics, 16 panels, two saved-frame
records and two imaging sessions. A separate import into an empty profile
restored 8,159 items. Re-export comparison matched all 62 backed-up tables after
normalizing only `weather_settings.updated_at`, which correctly records the
restore time. SQLite integrity and foreign-key checks passed at schema 70.
Evidence: `rt/fresh-restore-result.json` and `rt/restored-clean/integrity.json`.
Backups preserve database metadata and image references; they do not embed the
image files themselves.

The original release audit drives above used isolated profiles, loopback-only
network namespaces, simulated/scripted devices, and separate Xvfb displays.
That GUI smoke used the host-built bundle. The later packaging correction and
real-desktop package check are recorded in the stable distribution section;
they supersede the original host JPEG-dependency limitation.

## Desktop location and weather follow-up — 2026-11-14 UTC

Source commits `bb445811d` and `b3c9cce8d` add bounded location detection,
automatic initialization of an unset host site, edit/host-switch cancellation,
forecast attribution, and separate infrared-map labeling. A fresh host with no
saved coordinates acquired and persisted its approximate internet location
1.62 seconds after process start. This was measured on the built `b3c9cce8d`
binary with normal networking and scratch storage; database integrity passed.
It does not establish GPS accuracy. Saved sites and incomplete manual edits
are protected by the startup and transaction regressions.

Location checks passed: 30 core and 25 app startup/settings regressions,
54 location UI tests, and the default 332-test planetarium suite. The optional
host pixel golden was not re-baselined. Evidence is under
`~/.cache/ns-untangle/notes/codex-location-startup/`, `codex-location-ui/`, and
`codex-release-compat-tools/location-fix/`.

Live weather comparison then exposed a numerical source problem beyond the
labeling correction: the default Open-Meteo/HRRR series returned 8% at a US site
where the same-time local NWS grid returned 87% and MET Norway returned 96.1%.
The requests used the same coordinates and UTC hour. No percentage or timezone
conversion explained the disagreement. A nearby official overcast observation
corroborated the reported conditions without being converted to a percentage.

Commit `5da277a840548fb619f8a2193f86f75ec906cdea` uses the NWS point/grid forecast
where covered, retaining Open-Meteo and MET Norway as global fallbacks. Current
weather, planning, and the current-cloud API use the same source-selection
policy. NWS values are selected from their actual UTC validity intervals;
missing, malformed, expired, or out-of-range data never becomes zero cloud.
Existing hardware precedence, safety thresholds, and action policy are unchanged.

Verification for that commit:

- 18 NWS tests, 7 shared-source tests, and 30 provider/planning/weather-trust
  tests passed. The 8%-instead-of-87% provider regression was observed failing
  before the integration, then passed. An expired-NWS fallback regression was
  also observed failing before its correction.
- 22 desktop weather-handler tests and 39 protocol wire tests passed. Current
  API tests reject stale weekly samples and preserve the actual source/time.
- Architecture, bridge-boundary, behavioral, placeholder, fail-closed, API
  contract, and route-policy gates passed. Production analysis reported zero
  errors and warnings, with 658 existing informational findings.
- The Linux desktop build passed in 87.4 seconds at the exact commit above.
  The normal desktop instance was relaunched with host networking and desktop
  services, using its separate simulator profile. All seven simulator devices
  reconnected. Its window was confirmed present through desktop inventory.
- After applying the user's supplied town as an approximate town-center site,
  the live current-cloud API returned 85%, matching that point's NWS grid. The
  hourly endpoint identified NWS and returned 170 future hourly samples. The
  user's exact observatory coordinates were not established. The GUI's numerical
  rendering was covered by provider/widget checks; no new desktop screenshot
  verification is claimed because accessibility access was unavailable.

Source comparisons, red/green logs, gates, build metadata, and the live API
result are in `~/.cache/ns-untangle/notes/codex-weather-accuracy/`,
`codex-weather-diagnosis/recheck/`, and `codex-weather-endpoint/`. Raw network
captures contain private site coordinates and remain local evidence.

At this stage, the follow-ups produced a new host-built desktop bundle only;
the older portable Linux archive and Android APK listed below predated them.
The stable distribution section above records the subsequent package rebuilds
and native Windows runtime checks. Physical-rig verification remains unavailable.

## Linux desktop performance follow-up — 2026-11-14 UTC

The actual Wayland/NVIDIA desktop was measured at 1600 × 900 and 5120 × 1440
with normal networking, simulator equipment and verified 26 MP FITS captures.
The first accepted performance source `a6ca40442` retains the exact asynchronous histogram fix and
instantaneous weather tiles. Preview downscaling and blur removal were rejected
after actual GUI checks exposed latency and readability regressions.

The final app suite passed 5,482 tests with one skipped. The unchanged tested
core/desktop sources passed 8,141/1,458 tests; final architecture, bridge-boundary
and production-analysis checks passed. The host Linux release build passed.
The normal release is left running with seven simulator devices, networking,
the original editor plan, and profiling/replay disabled.

**The 240 Hz performance target is not met.** Stock Linux Flutter schedules at
approximately 60 Hz. The repeated 41–44 ms histogram builds are eliminated, but
maximized weather and occasional cold-frame work still exceed frame budgets.
A separate 413 ms pipeline delay occurred during an explicit large-image save.
Subsequent syscall tracing found synchronous request-log stalls; final source
`4736791e4` passes the corrected capture repeat with 16 verified 26 MP saves,
2,664 unique recorded frames, a 16.435 ms maximum pipeline span, and no traced
main-thread syscall over 1 ms. The original untraced event has no proven cause;
low build/raster percentiles alone do not establish stall-free operation. See the
[performance assessment](performance-v9.0.0-linux.md) for source revisions,
method, raw evidence, worst cases, rejected experiments and remaining scope.
The final distribution run rebuilds Linux, Windows, and Android from that
application source; the stable distribution section records its acceptance.

## Audit and artifact gates

The remaining behavioral markers were reviewed individually, and concrete
faults were corrected before registration. The final 476 accepted findings have
125 file-specific verdicts; every one of the 47 new high-risk placeholder
markers has a closed behavioral verdict. Deleted and moved rows were reconciled
by the repository tools, without reducing scan coverage or changing gate rules.
Per-site reviews and exact registration commands remain in the evidence folder.

The final 20-gate run at `65a2452a3` passed architecture, API contracts and route
policy, bridge boundaries, behavioral/placeholder/fail-closed audits, version
consistency, migration regression, Dart formatting, production analysis,
dependency hygiene, UI tokens, and their configured self-tests. Rust formatting
found one QHY diagnostic expression requiring reflow. Commit `46517373f` changes
only that formatting; Rust formatting and both source-sensitive behavioral and
placeholder gates then passed. Commands, revisions and exit codes are recorded
in `gates/results.jsonl`. No gate was relaxed.

Android 9.0.0+37 built successfully. The APK signature verifies but uses the
Android Debug certificate: this is a local validation/sideload candidate, not a
production-signed artifact. Its actual source revision is `ed84eac3a`; APK
production inputs are unchanged at `805774b5`, and the APK contains no Skotiq
Rust library. Later audit-register, appliance-packaging and formatting commits
do not change Android production inputs. No Android device runtime result is
claimed. The APK, checksum, signature and package metadata are in
`codex-release-tools/final-candidate/android/`.

The Debian Bookworm build passes the glibc <=2.36 guard. Minimal-runtime testing
identified missing GL/EGL/GLES libraries, archive-layout incompatibility, and a
healthcheck that called an authenticated endpoint. All three were corrected.
Actual appliance images built from the amended Dockerfile booted with both
flat and versioned-directory archives, initialized the native bridge, reported
9.0.0/build 37 and passed healthchecks. Seven archive-layout acceptance/refusal
cases also passed. These images used the canonical package list, actual
entrypoint and unprivileged user, no network or hardware, and fresh storage.
Evidence: `codex-portable-linux-tools/PACKAGING-FIX.md` and
`appliance-results.json`.

The final archive was assembled from `65a2452a3d63c0bd0a2240c2d9a11399481f494f`
and embeds that exact `SOURCE-COMMIT`. Its isolated Bookworm runtime check
passed: 9.0.0/build 37, native initialization, updater linkage/help, and
45-second liveness. The application, Dart AOT, native bridge and updater
binaries are byte-identical to the `805774b5` binaries tested in both actual
appliance images. The only subsequent native delta, `46517373f`, is diagnostic
expression formatting. The archive and metadata are in
`codex-release-tools/final-candidate/linux/`.

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| `skotiq-9.0.0-linux-x64.tar.gz` | 54,657,256 | `7a0cdc0126dfa5732efba0a9917bbfdbc48ae61f797268d493b110d615ffd6a3` |
| `Skotiq-9.0.0+37-android.apk` | 211,053,317 | `ad667e336a092e9cf2edb0594d13e67226d427750c33d1214de5bd203dcc2f81` |

The Linux package targets Debian Bookworm-compatible x64 systems; LibRaw needs
the documented system JPEG/LCMS/OpenMP runtimes. It is not a universal Linux
binary. No production-signed Android artifact or signed OTA manifest was
produced. Windows execution and a physical rig night remain required before
claiming validation on those platforms.

## Standards

Reviewed the bounded diff `e949e020b...c60742273435f365dc1c6dc13252dec41e7ff01c`, the final imaging delta `b3d133da9`, and the subsequent narrow native audit correction `4fa471acbfebd08e616e0a2ceb8ce9f0ac9ed907`. Applied repository `AGENTS.md`, `.claude/skills/skotiq-dev/SKILL.md`, and the code-review skill's standards/smell rubric. Mechanical formatting was excluded from substantive findings. This was a targeted standards and runtime review, not a claim that every changed line or physical device was exercised.

One hard standards violation was found in `packages/skotiq_app/lib/services/mount_command_service.dart:192`: the `GuidingDidNotStopException` refusal exposed raw exception interpolation instead of the shared `userFacingError` formatter required by skotiq-dev's error-text ownership rule. Commit `8ac2c699af7702f8f951469500ac69f9e4f8225a` fixes the branch to use `userFacingError(e)`.

No additional concrete standards defect was found in the reviewed guider ownership/LostLock handling, horizon propagation, shared CFA origin/serialization, photometry and science helpers, image-header WCS, sequencer device snapshots/refused-flip handling, or mosaic order migration. Speculative cleanup and tooling-enforced style were not reported as blockers.

The native audit reviewed all 237 assigned bridge/sequencer sites. It accepted 213 with source-specific reasons and identified 24 faulty hardware-read defaults. Commit `4fa471acb` preserves failed binning/geometry reads, rotator orientation and live settings, switch state/range, brightness limits, motion state, and COM capability queries. Explicit unsupported-member semantics remain intact. Eight new fault-injection tests passed; the full bridge release suite passed 787 tests with 18 intentionally ignored. Bridge clippy/all-targets and Windows workspace/all-targets type checks exited 0. Logs and per-site evidence are in `native-audit-review.json` and `native-audit-{tests,clippy,windows}.log` beside this report.

Final scanner reconciliation explicitly reviewed 32 additional markers; accepted original rows remain unchanged. Registers remain parent-owned. No Windows COM runtime, Android/iOS credential-store, or physical-rig validation is claimed.

Subsequent bounded correction `87fcc5cd7` preserves healthy devices during run
recovery and rechecks queued background attempts. Retained-camera protection is
enforced before native handle replacement, covering Dart's automatic connect
route as well as native recovery; explicit retrieve→disconnect→connect remains
available. Recording regressions passed across 64 sequencer scenarios, 9
reconnect-state tests and 9 heartbeat tests. Strict bridge/sequencer clippy and
Windows workspace type checks passed. See
`codex-release-compat-tools/automatic-recovery-review.md` and the final combined
15-test retention run for evidence after integration with the sensor fixes.

## Spec

Spec review: e949e020b...c60742273435f365dc1c6dc13252dec41e7ff01c, plus b3d133da9. Read-only; no review edits.

No actionable spec mismatch found in the inspected changes. This is a bounded review, not certification of every changed path.

- “A viewing companion can disconnect while its host continues imaging” (docs/release/v9.0.0.md): BackendNotifier's leavingRemoteHost exception only permits remote->no-host, retains the launch and host-switch guards, and disposes transport without stopping the host. Checked backend_provider.dart:315-364 and network_backend/connection_lifecycle.dart:823+.
- “Every companion must run the same Skotiq release”: LinkVersion checks the whole release string; HTTP/WS middleware rejects stale release or old API markers while permitting unversioned automation under the existing authentication chain. Checked remote_protocol/link_version.dart and desktop headless_api_server/http_middleware.dart:229+.
- “Failed status check or failed stop leaves the move refused” and learned site obstructions: stopGuidingForMove probes connected-but-idle-looking guiders, treats LostLock/Paused/unknown as active, propagates failed probes/stops, and checks authority after awaits. Serializer samples AltitudeFloor, which retains the flat floor plus learned obstructions and supplies native scheduler and altitude loops. Imported sample-only horizons are no longer classified flat.
- “Physical pixel units” and “CD/SIP and its reference pixel”: native frame_cutouts.rs uses FitsReader read_region or decoded native samples; Dart separates unreadable files from edge-star nulls. Science handler uses saved/file WCS and independent catalog magnitudes; b3d133da9 also makes default calibration catalog matching use the file WCS/reference pixel and image-centered search cone.
- “Panel IDs, coordinates, and captured-frame counts are preserved”: v70 only adds/writes order fields; legacy order inference and sparse panel rendering are covered by migration, service, geometry, and layout tests. The shared CFA type retains stored-data decoding while live release matching remains strict.

No claim of Windows runtime or real-rig validation: the release notes correctly leave those outstanding. Final combined gates and runtime results remain the integrator's acceptance evidence.
