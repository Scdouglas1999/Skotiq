# w5-gates — CI Behavioral gate

Workstream `w5-gates`, branch `agent/w5-gates`, base `2bd11fda3`.

Goal: make the CI **Behavioral gate** pass on this branch, honestly — every
unregistered finding either adjudicated in
`docs/production-readiness/behavioral-audit-register.md` with a file-specific
reason, or fixed in code where the pattern hid a real defect.

## Scope correction

The brief quoted 34 unregistered findings from
`logs/gate-behavioral.log`. Run in this worktree the gate reported **61**
unregistered findings across **33** files (the log was captured against a
different tree). All 61 were adjudicated.

## Outcome

- **29 files registered** as `accepted_modeled_approximation`, each with a
  reason naming the actual expression and why it is correct. No boilerplate
  reuse: every row was written after opening the file at the reported line.
- **4 code changes** (3 defects + 1 false comment). These removed 3 findings
  outright; the remaining hits in those files are registered.
- 1 stale register row deleted (its pattern no longer exists — see below).

## Code changes

Each line: the change, and the defect it removes.

1. `packages/skotiq_app/lib/widgets/mount/mount_site_reconciliation_card.dart`
   — `_formatClock` did `offsetHours ?? 0`, printing a confident `UTC+00:00`
   for a mount that reported its UTC instant but **not** its offset
   (`MountSiteReconciliation.mountUtcOffsetHours` is nullable independently of
   `mountUtcSeconds`; `hasMountTime` only checks the seconds). This row renders
   only `if (_c.timeDiffers)` — i.e. in the one place whose whole job is to
   expose a clock disagreement — so a fabricated zero offset was the card
   asserting an agreement nothing had measured. Now an unreported offset renders
   the instant in UTC and says `(offset not reported)`.

2. `packages/skotiq_app/lib/screens/dashboard/widgets/tonight/tonight_side_panels.dart`
   — `MoonPainter(illumination: night?.moonIlluminationPercent ?? 0)` painted a
   fully dark disc, which reads as a confident **new moon**, whenever the night
   data was missing — while the Illuminated / Moonset / Moonrise readouts
   beside it were correctly rendering `—` for the same missing night.
   `moonIlluminationPercent` is `double?` even when `night != null` (it is
   `moon?.illumination`), so the gate is on the value, not on `night`. The disc
   is now omitted when illumination is unknown; the 56 px box keeps the layout.

3. `packages/skotiq_app/lib/screens/dashboard/widgets/cockpit_now_imaging.dart`
   — `settingsAsync.valueOrNull?.hasObserverLocation ?? false` made the altitude
   chip tell the operator to **"set location"** while the settings read was
   still in flight, i.e. it stated the site was unset before anything had said
   so. Now only a resolved `hasObserverLocation == false` produces that
   instruction; unresolved renders `—` (unknown). This is the same reasoning the
   codebase already applies at `equipment_stats.dart:75` and
   `tonight_checklist_panel.dart:51` ("a still-loading check is NOT evidence").

4. `packages/skotiq_app/lib/screens/sequencer/widgets/sequence_tree/ledger_columns.dart`
   — **comment only, no behaviour change.** The comment justifying
   `ledgerClockProvider.valueOrNull ?? DateTime.now()` claimed "an empty
   (run-active) clock stream has no value; `now` is only read when the run is
   idle". Both halves are false: the provider yields `DateTime.now()`
   synchronously as its first event and is not run-gated, and `now` **is** read
   while a run is active (the `pendingShift` catch-up that pushes the pending
   tail when a node overruns). The fallback itself is correct — it reads the
   same wall clock the stream reads — so the code stands and the false
   justification was replaced with an accurate one. Flagged because a register
   row resting on a false comment is exactly what this gate exists to stop.

## Findings given real scrutiny and NOT changed

- **`imaging_chain.dart`, all five `empty_catch` sites** — none swallows
  anything. Three (mount / focuser / filter-wheel *disconnect*) run a genuine
  rollback in the catch body (clear the user-initiated-disconnect mark, restart
  the heartbeat) and then `rethrow`; the binding is `_` only because the
  rollback does not read the error. Two (focuser / filter-wheel *connect*) wrap
  a cleanup `disconnectDevice` inside an outer `catch (e)` that rethrows the
  original connect failure — discarding the cleanup error is what preserves the
  useful one, since the connect may have failed before the backend registered
  the device at all. Registered, not changed.

- **`mount_site_reconciler.dart:44` `guessed_now_timestamp`** —
  `final clock = now ?? DateTime.now();` where `now` is the method's own
  injected `DateTime?` test seam. The computer's current time is the exact
  quantity being reconciled against the mount's clock, so this read *is* the
  measurement, not a substitute for one. Registered, not changed.

- **`ledger_columns.dart:156` `(plan.filterIndex ?? 0) + 1`** — renders `#1` for
  a smart-exposure plan with neither name nor index. Left as is deliberately:
  it is character-for-character what `node_summary.dart:432`/`:443` prints for
  the same field, and those are already registered. Changing only the ledger
  copy would make the Filter column and the summary line disagree about the same
  plan — a worse defect than the one it would fix. Flagged here as a shared
  item: if it is to change, both sites must change together.

- **`tonight_side_panels.dart:118` `settings?.weatherSafetyEnabled ?? false`** —
  unloaded weather settings show the neutral "Not monitored" chip. Left as is:
  it understates protection rather than overstating it (the opposite of the
  fail-closed direction that has previously parked this rig), and a third
  "unknown" arm would need a new shared l10n key that other agents are editing.

## Register hygiene

Deleted one stale row:
`packages/skotiq_app/lib/screens/dashboard/widgets/cockpit_now_imaging.dart:76:literal_null_coalesce`.
It was already stale on the base commit (the pattern sat on line 73, not 76,
which is why the finding showed as unregistered), and code change 3 removed the
pattern from the file entirely. Its own recorded reason — "settings not yet
loaded read as 'no site', so the altitude chip prints 'set location'" —
described the cry-wolf as accepted; that behaviour is now fixed.

## Verification (unpiped exit codes)

| command | exit |
| --- | --- |
| `dart run tools/production/behavioral_audit.dart --register docs/production-readiness/behavioral-audit-register.md --fail-on-unregistered --fail-on-open --report .behavioral_audit_hits.txt --min-files 796` | **0** (3165 files scanned, 0 unregistered, 0 open) |
| `dart run tools/production/placeholder_audit.dart --fail-on-new-highrisk --compare-highrisk-baseline docs/production-readiness/highrisk-baseline.txt --min-files 797` | **0** (3166 files, no new high-risk markers) |
| `dart run tools/production/analyzer_rollup.dart --policy docs/production-readiness/analyzer-policy.yaml --critical-codes docs/production-readiness/critical-warning-codes.txt` | **0** (production: errors=0, warnings=0; **critical warnings: 0**) |
| `dart format --output=none --set-exit-if-changed <4 edited dart files>` | **0** (0 changed) |
| `flutter test test/screens/sequencer --concurrency=3` (skotiq_app) | **0** — **+711**, unchanged from base |
| `flutter test test/screens/dashboard --concurrency=3` (skotiq_app) | **0** — +182 |
| `flutter test test/widgets --concurrency=3` (skotiq_app) | **0** — **+303**, green after the follow-up below |

`analyzer_rollup.dart` writes `docs/production-readiness/analyzer-rollup.json`.
That file is untracked and was absent on this branch, so the artifact it
produced was deleted after the run; it is not in the diff.

Only `skotiq_app` production code changed, so no `skotiq_core` or
`skotiq_ui` test directories were in scope.

## Follow-up: the four pre-existing failures, now fixed

`packages/skotiq_app/test/widgets/capture_settings_panel_filter_test.dart`
failed 4 tests on arrival. The cause was stale-test debt, not a regression: the
test drove a Material `DropdownButton<String>`, while
`packages/skotiq_app/lib/widgets/capture_settings_panel.dart` had been
migrated to the design system's `SkotiqDropdown`. On the coordinator's
instruction (owner rule: zero failing tests before a final build) the TEST was
updated to the current product, which is the side that is right.

The three `DropdownButton<String>` references were repointed at
`SkotiqDropdown` using the interaction pattern already established in
`test/screens/settings/settings_dropdown_test.dart` (tap the trigger,
`pumpAndSettle`, tap `find.text(value).last`). No Material dropdown was added
back. Every assertion's intent is unchanged — which filter is selected, that
selecting G dispatches wheel position 2, that a pending move nulls `onChanged`
and the Capture button, that metadata flips to G only after the move completes,
and that a failed move retains L. Two supporting changes:

- the dropdown lookup was lifted into a `_filterDropdown(currentLabel)` finder,
  since the same scoping (the Filter control is the only dropdown whose closed
  trigger shows a slot label) is now needed in two places;
- the post-selection drain went from 3x20 ms to 8x50 ms, because
  `SkotiqDropdown` returns its choice by popping a route and the pop
  animation has to run. It is still a hand-drained pump loop rather than
  `pumpAndSettle`, because the gated-move test leaves work pending on purpose.

`package:flutter/material.dart` became an unused import once the last
`DropdownButton` reference went, and was removed; `dart analyze` on the file
reports no issues.

Result: `flutter test test/widgets --concurrency=3` -> **EXIT 0, +303**, fully
green. No production code was touched for this follow-up, so the behavioral,
placeholder and analyzer gates are unaffected (the audit tools exclude `test/`
directories from their scan roots).
