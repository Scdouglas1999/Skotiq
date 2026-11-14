# Refactor release readiness

The release candidate is being assembled on `codex/release-readiness`, starting
from `untangle/integ` at `e949e020b`. Existing release checkouts and unrelated
uncommitted work are preserved. Nothing has been published.

## Completion checks

| Work | State | Evidence / next check |
| --- | --- | --- |
| Core rules (`w4-core`) | Integrated; review and final validation pending | `fd8f6fa8d`; check guider state before mount moves and directional horizon consumers |
| FITS headers and master refusal (`w4-imgrs2`) | Integrated; combined validation pending | `cbd636be1`; targeted regression tests and frame/export checks |
| Wire and linking (`w4-compat`) | In progress on `codex/release-compat` | Complete same-release contract checks and linked-client disconnect |
| Sequencer and mosaic (`w5-seq`) | In progress on `codex/release-sequencer` | Disabled descendants, refused flips, flat progress, recovery access, schema v70 |
| Imaging (`w5-img`) | In progress on `codex/release-imaging` | Complete CFA migration, read modes, photometry reader, WCS projection |
| Review of recent work | Pending | Standards and intended behavior, with emphasis on data, hardware commands, events and ownership |
| Runtime audits and formatting | Pending | Reconcile reviewed moved/new sites; run required CI checks using the repository toolchain |
| Dart and native suites | Pending | Preserve full output and actual exit codes; resolve the five prior integration failures |
| Release builds and simulator workflows | Pending | Linux desktop, Android where supported, isolated local and linked workflows |
| Database migration and backup/restore | Pending | Final schema, existing fixture data and scratch copies; never mutate owner data |
| Version and release notes | Pending | New release identity required because the wire contract changes |
| Windows runtime | Unavailable | Owner confirmed 2026-11-13 that the Windows laptop is unavailable; cross-target compilation does not replace this check |
| Real rig validation | Unavailable | Owner confirmed 2026-11-13 that the rig is unavailable; no hardware commands are authorized by simulator checks |

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
