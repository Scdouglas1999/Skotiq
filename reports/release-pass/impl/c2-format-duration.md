# C2 — format-duration

Topic: the ~30 private `_formatDuration` copies (Wave A cross-cutting cluster 7,
"same shape, lower stakes"). Survivor:
`packages/skotiq_core/lib/src/utils/duration_format.dart`, whose own doc
already records the bug that motivated it ("0 minutes" vs "12s" for the same
run). It was extended, not forked.

Baseline: commit b17655239, tree green.

## The finding this closes

GUI finding **SEQ-20** (`reports/release-pass/gui/sequencing.md:349`) was never
picked up by the sequencing B-fix batch (its item list stops at SEQ-19), so this
topic owns it:

> the target card reads "4 planned exposures • **0m**" while the sequence
> estimate right beside it reads "~20s".

The cause was structural, not local: **nine** of the retired copies had no
seconds arm at all — their smallest unit was the minute, so every sub-minute
duration floored or rounded to `0m`. That is why fixing it one screen at a time
was never going to hold.

## What the canonical gained

The 30 copies were not one function. Sorting them by output shape gives five
distinct renderings, so `DurationFormat` is parameterised rather than picking a
winner and silently restyling half the app.

| `DurationStyle` | 1h 2m 3s | 1h 0m 0s | 2m 3s | 2m 0s | 3s |
| --- | --- | --- | --- | --- | --- |
| `hms` | `1h 2m 3s` | `1h 0m 0s` | `2m 3s` | `2m 0s` | `3s` |
| `hoursMinutes` | `1h 2m` | `1h 0m` | `2m 3s` | `2m 0s` | `3s` |
| `hoursMinutesTrimmed` | `1h 2m` | `1h` | `2m 3s` | `2m` | `3s` |
| `compact` | `1h 2m` | `1h 0m` | `2m` | `2m` | `3s` |
| `compactTrimmed` | `1h 2m` | `1h` | `2m` | `2m` | `3s` |

Two orthogonal knobs, each demanded by a real site:

* `DurationRounding {nearest, truncate}` — how a fractional-seconds input is
  reduced to whole seconds. `nearest` is the canonical's existing documented
  behaviour (59.6 s reads `1m 0s`, not `60s`); `truncate` reproduces the copies
  that floored, and the ones that went through `Duration` first.
* `roundToMinute` — for the `compact*` styles, whose smallest rendered unit
  above a minute *is* the minute: the leftover seconds round into the minutes
  field instead of being dropped. Three sites did this (the two budget readouts
  and the Quick Start estimate).

Entry points: `DurationFormat.seconds(num)` and `DurationFormat.of(Duration)`.
`formatIntegrationSeconds` / `formatIntegrationHours` keep their names, their
doc and their exact output; they are now one-line delegates.

**Naming note:** the canonical is a class, not a top-level `formatDuration`,
because `run_dashboard/run_dashboard_format.dart` already declares a top-level
`formatDuration` and `target_header_panel.dart` imports both it and
`skotiq_core`. A top-level name would have been an ambiguous-import error
there, not a shadow.

**Carry note:** `roundToMinute` quantizes the **total** at the minute before
decomposing. The retired copies rounded the hour's *remainder*, so 3599 s
rendered `60m` and 7195 s rendered `1h 60m`. Rounding after decomposing is not
the same function; the canonical carries into the hours field instead. This is
the one place a non-SEQ-20 string changes, and it only changes strings that were
already wrong.

## The deliberate behaviour change (SEQ-20)

Every style renders seconds below one minute, so `'0m'` is unreachable from any
of them. Above one minute the re-pointed sites are byte-identical — the parity
sweeps below assert exactly that, and skip only `total < 60`.

Two sites carried a hand-rolled dodge of the same symptom and lose it:

* `widgets/session_recovery_dialog.dart` returned `'<1m'` for a sub-minute
  session and `'0m'` for zero, with a comment explaining that "0m reads as
  didn't run". It now reports the real value (`12s`).
* `screens/sequencer/widgets/target_node_properties/budget_preview.dart` and
  `run_dashboard/target_header_panel.dart` returned a literal `'0m'` for
  `secs <= 0`; that is now `0s`.

## Call sites re-pointed (27 helpers, 3 packages, 60 call sites)

`skotiq_core` — 4 helpers
* `services/notes_service.dart` (top-level `_formatDuration`) → `of(hms)`
* `services/notification_service.dart` → `of(hms)`
* `services/session_report_service.dart` — **two** identical local
  `formatDuration` closures inside `renderMarkdown` / `renderText`, 8 call sites
  → `of(hms)`
* `services/session_optimizer_service.dart` → `of(compact)`

`skotiq_app` — 21 helpers
* `screens/dashboard/widgets/session_progress_card.dart` (3 calls) → `hoursMinutes`
* `screens/imaging/widgets/capture_panel.dart` (2 calls) → `formatIntegrationSeconds`
* `screens/sequencer/tabs/history_tab.dart` → `hoursMinutes`
* `screens/sequencer/tabs/sequence_library_tab/sequence_card.dart` → `compact`
  + `truncate` (its `'N/A'` guard for `<= 0` stays at the call site)
* `screens/sequencer/widgets/mobile_playback_bar.dart` → `compact` + `truncate`
* `screens/sequencer/widgets/node_timing_section.dart` (`formatDurationNice`,
  6 calls) → `hoursMinutesTrimmed`
* `screens/sequencer/widgets/preflight_validation_dialog.dart` → `compact`
* `screens/sequencer/widgets/preflight_validation_dialog/simulation_widgets.dart`
  → `compact` (a byte-identical twin of the one above, in the same library)
* `screens/sequencer/widgets/quick_start_wizard_dialog.dart` → `compact` +
  `roundToMinute`, `'~'` prefix kept at the helper
* `screens/sequencer/widgets/run_dashboard/target_header_panel.dart` (4 calls)
  → `compactTrimmed` + `roundToMinute`
* `screens/sequencer/widgets/sequence_progress_bar.dart` (2 calls) → `hms` +
  `truncate`
* `screens/sequencer/widgets/sequence_timeline/full_timeline.dart` → `compact` +
  `truncate`, `' total'` suffix kept at the helper
* `screens/sequencer/widgets/sequence_toolbar/actions_and_estimate.dart`
  (6 calls) → `compact` + `truncate`
* `screens/sequencer/widgets/session_report_dialog/header_overview.dart`
  (3 calls) → `hoursMinutes`
* `screens/sequencer/widgets/session_report_dialog/target_conditions.dart`
  (2 calls) → `hoursMinutes` + `truncate`
* `screens/sequencer/widgets/smart_night_dialog.dart` (3 calls) → `compact`
* `screens/sequencer/widgets/target_header_card.dart` (2 calls) → `compact`
* `screens/sequencer/widgets/target_node_properties/budget_preview.dart`
  (4 calls) → `compactTrimmed` + `roundToMinute`
* `services/observation_report_service.dart` → `of(compact)`
* `widgets/sequence_progress_card.dart` (2 calls) → `hoursMinutes`
* `widgets/session_recovery_dialog.dart` → `compact`

`apps/mobile` — 2 helpers
* `screens/replay/session_picker_screen.dart` → `hoursMinutes`
* `screens/replay/session_replay_screen.dart` → `hoursMinutes`

Where a helper had several call sites in one file it stays as a one-line
delegate (`_formatDuration(x) => DurationFormat.seconds(...)`) so the diff is the
body only; where it had one, the call site formats inline and the helper is gone.

### Zero-caller claim retracted

`quick_start_wizard_dialog.dart:1143` and `smart_night_dialog.dart:1067` looked
dead — `grep _formatDuration <file>` returns only the definition. They are not:
both classes are split across `part` files
(`quick_start_wizard_dialog/_review_step.dart:153`,
`smart_night_dialog/step_views.dart:216,856,864`) and the analyzer caught the
deletion. **A per-file grep is not a caller proof for a `part`-ed library.** Both
were restored as delegates.

## Not adopted (divergent by design — recorded, not unified)

Seven survivors render a genuinely different function. Parameterising the
canonical to reproduce them would have meant four more boolean axes for one
caller each, which is worse than the duplication:

* `screens/analytics/widgets/period_analysis_panel.dart:835` — takes **days**
  and renders science units with decimals (`12.3 min` / `1.75 hr`). Different
  input unit, different precision contract.
* `screens/sequencer/widgets/meridian_flip_progress_dialog.dart:499` — a
  countdown clock, `M:SS` with a zero-padded seconds field.
* `screens/sequencer/widgets/node_properties_panel_parts/_exposure_rich.dart:671`
  — single largest unit at one decimal (`12.5s` / `1.5m` / `2.0h`).
* `screens/sequencer/widgets/run_dashboard/run_dashboard_format.dart:19` — the
  dashboard's own shared helper, already one implementation for its surface. It
  renders `—` for null/negative and shows seconds only under five minutes
  (`s > 0 && m < 5`), a readability rule nothing else has.
* `screens/sequencer/widgets/session_report_dialog/recovery_insights.dart:122` —
  never promotes to hours (a two-hour value reads `120m`), which is arguably
  wrong but is not this topic's finding and has no test pinning it either way.
* `screens/imaging/widgets/capture_panel.dart:_formatSessionDuration` and
  `screens/analytics/analytics_screen/history_cards.dart:236` — a zero-padded
  `HH:MM:SS` clock and a decimal-hours badge (`1.8h`, `'0'` for nothing).
* `packages/skotiq_ui/.../phd2/guide_graph_advanced.dart:571`
  (`_formatElapsed`) — a chart axis label that mixes `45s` / `2m` / `2:30`.

One accepted rounding divergence, in the C1 `mad_sigma` spirit:

* `capture_panel.dart:398` floored hours and minutes but **rounded** the seconds
  field, so 59.6 s rendered `60s` and 3659.6 s rendered `1h 0m 60s` — a seconds
  field that reaches 60. It now uses `formatIntegrationSeconds`, which rounds the
  total first (`1m 0s`, `1h 1m 0s`). Whole-second inputs are unchanged; only
  fractional inputs in the last half-second of a minute differ, and only away
  from a string that could never be right.

## Parity tests

`packages/skotiq_core/test/utils/duration_format_parity_test.dart` — 23
tests. Every retired body is copied in **verbatim** as a `_ref*` function and the
canonical is asserted equal to it over a sweep of every whole second from 0 to
10 900 plus a 24 h / 25 h / 100 h tail:

* `hms` vs the `Duration` copies and the floor-based double copy — no exceptions.
* `hoursMinutes` vs the five `Duration` copies, the rounded-double copy and the
  millisecond-truncating copy — no exceptions.
* `hoursMinutesTrimmed` vs `formatDurationNice` — no exceptions.
* `compact` vs the `Duration` copies — no exceptions; vs the four minute-only
  double copies with `total < 60` skipped (that skip *is* SEQ-20, pinned
  separately).
* `compactTrimmed` + `roundToMinute` vs the two budget copies, with the
  minutes-rounded-to-60 cases asserted to differ and the count asserted non-zero
  so the exception cannot quietly become vacuous.
* SEQ-20 itself: every style × {1, 12, 20, 30, 45, 59} s renders `Ns`, including
  under `roundToMinute`; and the retired bodies are shown printing `0m` for the
  same inputs, including the exact 4 × 3 s repro.
* Edge cases: zero, `-0.0`, negative seconds, negative `Duration`, NaN, ±infinity
  (all `0s`); sub-second positives under both roundings; durations past 24 h keep
  counting hours rather than wrapping (`25h 1m 1s`, `48h 3m 0s`).

## Verification

- `skotiq_core`: `test/utils` + `test/services` — 2901 passed, 4 skipped.
  `test/providers` + `test/models` — 2372 passed.
- `skotiq_app`, **as the gate runs it** (`--exclude-tags golden`):
  `test/screens/analytics` + `test/screens/dashboard` — 407 passed;
  `test/screens/sequencer` + `test/screens/imaging` + `test/widgets` — 935
  passed; `test/services` — 34 passed. Zero failures.
- Without that exclusion the same directories report 11 failures, every one of
  them in a `captures_*.dart` render-capture file: pixel-diff goldens whose
  baselines are host-specific, `@Tags(['golden'])`, and therefore excluded from
  the gate (`melos.yaml:318` runs `flutter test --exclude-tags golden`; the
  capture PNGs are gitignored and the file header says "do not commit").
  **Independence proof:** the set includes both variants of
  `test/screens/analytics/captures_landscape_test.dart`, which renders a screen
  this topic does not touch, and the diffs are 9.44 % / 37 838 px — orders of
  magnitude larger than the handful of glyphs a duration string occupies.
- `apps/mobile`: full package — 239 passed.
- Harness note: running `test/widgets test/screens/*` in one invocation right
  after a killed run wedged at test 955 for minutes. The cause was two orphaned
  `flutter_tester` processes from the killed run holding the shared test
  database; killed by pattern, and the same suites then ran clean. `test/services`
  alone finishes in 2 s.
- Analyzer: `skotiq_core` lib+test clean (2 pre-existing `dispose`
  deprecation infos in a database test); `skotiq_app` lib 17 issues, all
  pre-existing `clampPanelWidth` deprecation infos + one doc-comment info, 0
  errors; `apps/mobile` lib clean.
- `dart format --set-exit-if-changed` over the 29 touched files only — clean.
- `placeholder_audit` gate: green (no new high-risk markers vs baseline).
- `behavioral_audit` gate: **red at this baseline and unchanged by this topic** —
  22 unregistered findings, all in files no C2 topic touched (`bridge/src/*.rs`,
  `imaging/src/stacking.rs`, `flat_wizard/mod.rs`, `capture_dir_step.dart`,
  `slew_to_target_dialog.dart`, `merged_sections.dart`,
  `constellation_client.dart`, `variable_star_catalog.dart`). Grepping the
  unregistered list against the 29 files touched here returns nothing. The one
  hit inside this diff — `observation_report_service.dart:252
  guessed_now_timestamp` — is registered, and is the *same* `?? DateTime.now()`
  that used to sit inside the deleted helper 690 lines further down; it moved to
  the call site, it is not new.

Existing string pins that constrain this change and still pass unchanged:
`target_header_card_plan_test.dart` (`10 planned exposures • 20m`,
`24 planned exposures • 24m`, `2m / 20m`), `sequence_timeline_test.dart`
(`1m total`), `sequence_library_preview_frames_test.dart` (`20 frames • 30m`,
`L: 20m`), `run_dashboard_target_progress_test.dart` (`2m / 20m`),
`session_handoff_dialog_test.dart` (asserts `0m` appears nowhere),
`quick_start_dialog_integration_format_test.dart`.
