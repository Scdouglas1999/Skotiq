# Refactor release readiness

The release candidate is prepared on `codex/release-readiness`, starting
from `untangle/integ` at `e949e020b`. Existing release checkouts and unrelated
uncommitted work are preserved. Nothing has been published.

## Completion checks

| Work | State | Evidence / remaining check |
| --- | --- | --- |
| Core rules | Complete | Active guider ownership/LostLock guard, learned horizon serialization, and failed camera-capability preservation; 71 focused merged regressions pass |
| FITS and calibration-master refusal | Complete | Integrated `cbd636be1`; native suites and final builds pass |
| Wire and linking | Complete | Same-release contract, structured errors, actual linked-client disconnect/reconnect while host keeps capturing |
| Sequencer and mosaic | Complete | Disabled descendants, refused flips, bounded flat progress, sparse panel layout, create/save/reopen, schema v70 preservation |
| Imaging | Complete | Shared CFA, camera read modes, native photometry, CD/SIP/reference-pixel projection; 20/20 linked calibration fixture matches |
| Native read/retention audit | Complete | Failed device values remain errors/unknown; real libgphoto2 disk-camera retention and all automatic-reconnect paths tested |
| Standards and spec review | Complete, bounded | Both axes recorded in [validation-v9.0.0.md](validation-v9.0.0.md); concrete findings corrected |
| Runtime audit reconciliation | Complete | 476 final findings have 125 file-specific reviewed verdicts; 47 placeholder markers match closed behavioral entries |
| Formatting, analysis, CI gates | Complete | All 20 final gates pass, including the corrected QHY formatting recheck; native strict clippy and Windows type check pass |
| Dart and native suites | Complete with focused post-change checks | Full suites plus changed-path regressions; expected node contract fixture updated; all three opt-in mobile socket tests now execute and pass |
| Version and release notes | Complete | 9.0.0+37 beta; host and companion upgrade together |
| Combined app smoke | Complete | LostLock stop command verified; two-frame simulator sequence completed and wrote both files |
| Database migration and backup/restore | Complete | Authentic v4.3.0 fixture 51→70; existing-profile and empty-profile restores pass; 8,159 items restored and database integrity/FK checks clean |
| Release builds | Linux and Android built | Debian appliance graphics/archive/healthcheck fixes verified in actual images; APK is debug-signed validation build |
| Windows runtime | Unavailable | Owner confirmed 2026-11-13 that the Windows laptop is unavailable; cross-target compilation does not replace this check |
| Real rig validation | Unavailable | Owner confirmed 2026-11-13 that the rig is unavailable; simulator results do not certify physical behavior |
| Distribution signing | Outstanding | Android candidate uses the Debug certificate; no signed OTA manifest was produced |

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
