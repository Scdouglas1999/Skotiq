# Refactor release readiness

The 9.0.0+37 stable candidate is prepared on `codex/release-readiness`, starting
from `untangle/integ` at `e949e020b`. Final application source is `4736791e4`.
Signed distribution builds, native Windows/Linux runtime checks, the bounded
capture repeat, and Android update verification pass. Existing release
checkouts and unrelated uncommitted work are preserved. Nothing is published.

## Completion checks

| Work | State | Evidence / remaining check |
| --- | --- | --- |
| Core rules | Complete | Active guider ownership/LostLock guard, learned horizon serialization, and failed camera-capability preservation; 71 focused merged regressions pass |
| FITS and calibration-master refusal | Complete | Integrated `cbd636be1`; native suites and builds passed on the recorded validation revisions |
| Wire and linking | Complete | Same-release contract, structured errors, actual linked-client disconnect/reconnect while host keeps capturing |
| Sequencer and mosaic | Complete | Disabled descendants, refused flips, bounded flat progress, sparse panel layout, create/save/reopen, schema v70 preservation |
| Imaging | Complete | Shared CFA, camera read modes, native photometry, CD/SIP/reference-pixel projection; 20/20 linked calibration fixture matches |
| Native read/retention audit | Complete | Failed device values remain errors/unknown; real libgphoto2 disk-camera retention and all automatic-reconnect paths tested |
| Standards and spec review | Complete, bounded | Both axes recorded in [validation-v9.0.0.md](validation-v9.0.0.md); concrete findings corrected |
| Runtime audit reconciliation | Complete | 476 final findings have 125 file-specific reviewed verdicts; 47 placeholder markers match closed behavioral entries |
| Formatting, analysis, CI gates | Passed | Architecture, bridge boundary, API contracts/policy, behavioral, placeholder, fail-closed, version, production analysis, Dart and Rust format gates passed with the request-log correction. Final Windows, Linux, and Android CI builds passed |
| Dart and native suites | Accepted regression evidence recorded | App: 5,482 passed, one skipped at `a6ca40442`; core/desktop: 8,146/1,459 passed with the request-log correction; mobile/protocol: 227/249 passed. Native and other package revisions are recorded in the validation report; all three opt-in mobile socket tests passed |
| Version and release notes | Complete | 9.0.0+37 stable; host and companion upgrade together; final evidence is reconciled and the release remains unpublished |
| Combined app smoke | Complete | LostLock stop command verified; two-frame simulator sequence completed and wrote both files |
| Database migration and backup/restore | Complete | Authentic v4.3.0 fixture 51→70; existing-profile and empty-profile restores pass; 8,159 items restored and database integrity/FK checks clean |
| Release builds | Passed | Final run `43620240119` at `4736791e4` passed all platforms and assembled signed-manifest verification. Downloaded assets retain the exact source marker and all six checksums match |
| Windows runtime | Native CI smoke passed; manual host unavailable | Release binary passed authentication, HTTP, real WebSocket pong, simulator exposure, 128 × 96 16-bit FITS readback, and disconnect on Windows |
| Android runtime | Passed in API 35 x86_64 emulator | Fresh signed install, one notification request per launch, native-link routing, pairing without admin scope, captured-image display, and reconnect pass. Final signed APK update retained pairing and reconnected. Physical phones and ARM runtime remain untested |
| Real rig validation | Unavailable | Owner confirmed 2026-11-13 that the rig is unavailable; simulator results do not certify physical behavior |
| Distribution signing | Passed | All three production-signed APKs and five signed OTA manifests passed CI and independent downloaded-artifact verification. Downloaded checksums and source marker match. Stable guards refuse missing identities and debug/unsigned distribution. Windows binaries have no Authenticode signature; no replacement keys were generated |
| Linux performance | Bounded capture check passed; 240 Hz target unmet | Final source completed 16 verified 26 MP FITS saves: 2,664 recorded frames, maximum pipeline 16.435 ms, no traced main-thread syscall over 1 ms. Histogram and identified logging stalls are corrected. Engine scheduling near 60 Hz, full-buffer UI copies, weather and cold-navigation costs remain; see the performance assessment |

The signing and publication guards at `8f9695911` passed 17 policy/workflow/
signature tests and seven existing manifest-verifier tests, including refusal
of the actual older debug-signed APK. Build-only CI does not publish or attach
assets; `f4abde60a` retains its verified packages and source provenance for
review. The final full build-only run at `4736791e4` passed the positive signing
and artifact checks with the existing production identities.

The [validation record](validation-v9.0.0.md) and
[performance assessment](performance-v9.0.0-linux.md) retain exact source
revisions, commands, limitations, and measured results. Application artifacts
are built from `4736791e42ae073dc2ff9874323035051a350206`; later documentation
changes do not alter the tested binaries. No tag, main-branch merge, or release
publication was performed.

## Scope

Finish the interrupted packages and reproducible defects, review the result,
and satisfy the release gates. Broader changes to focus-model storage,
target-ranking policy, and manual/native operation ownership require their own
design and data-migration work; they are not grounds for silently extending
this release into another architecture campaign. Any concrete defect found in
those paths remains subject to release review.

Detailed command logs and handover snapshots are kept under
`~/.cache/ns-untangle/notes/codex-release*-tools/`. Each test result must identify
the code tested. Earlier branch results do not certify later merged code.
