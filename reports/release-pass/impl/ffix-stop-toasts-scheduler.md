# F-fix — batch `stop-toasts-scheduler`

Charter: WF-N4 + WF-STOP-N3, WF-STOP-N5, WF-N1, WF-N5.
Evidence: `reports/release-pass/waveF-result.json` (new_findings), the
`waveF-autopilot-night.md` / `waveF-stop-pipeline.md` narratives, the WD-EQ-3
recipe in `waveF-equipment-chrome.md`, and the Wave F verdict in
`RELEASE-PASS-2026-08-11.md`.

Orientation: one `graphify query "notification router dedupe toast emission
scheduler engine logging"`.

---

## WF-N4 / WF-STOP-N3 — one Stop, three identical toasts and three feed rows

**Root cause (two compounding halves).** Three producers reclassify an operator
Stop into `NotificationCategory.sequenceStopped` and each one reaches the
router: the sequencer `Error` carrying the "Sequence cancelled" notice, the
`Stopped` lifecycle event that follows it, and the dashboard bridge re-entering
with the same stop. The router deduped **only** `systemPush`, by explicit
comment ("Other transports … are not deduped here"), so every in-app toast and
RECENT EVENTS row went out three times.

Even had in-app been deduped, the key could not have matched: the body
interpolated `${time.local}`, which each producer resolved to **its own
microsecond** — `.963572 / .963635 / .963658`. Three different strings for one
happening. This is why WF-STOP-N5 and this item are one fix.

**Fix** — `services/notification/notification_router.dart`:

* `_recentPushSignatures` → `_recentSignatures`, keyed **per transport kind**,
  applied in `_dispatch` for **every** transport. Per-kind, never global: an
  at-idle webhook/e-mail alert must not be swallowed because the UI already
  said it (that was the original comment's real concern, and it survives).
* Windows: `systemPush` keeps its 15 s; everything else gets 5 s. The
  converging producers fire in the same millisecond; a repeat the operator can
  read as new information still gets through (pinned by a clock-driven test at
  +5 min).
* **The WD-EQ-3 recipe:** the key is normalized before comparison —
  `trim` → collapse internal whitespace runs → strip trailing
  `[\s.,;:!…]` → lowercase. `?` is deliberately **not** stripped (a question
  and a statement are different notifications). The exact-string key that
  shipped in E-fix was defeated by one character on the one case it was written
  for; this cannot be.
* Injectable `clock` on the router (also used by debounce/rate-limit) so the
  windows are testable rather than wall-clock-dependent.

**"the producer that appends the stray full stop":** in THIS pipeline there is
no stray-full-stop producer — the three stop bodies differ by microseconds, not
punctuation, and the fix for that is WF-STOP-N5 below. The stray full stop in
the *charter text* belongs to WD-EQ-3's guider refusal, whose producer is
`native/skotiq_native/bridge/src/builtin_guider/loop_runner.rs` +
the Dart connect path — outside this batch's scope and assigned to
equipment-chrome. What this batch owed was the **recipe**, and the normalized
key is applied here at the router with WD-EQ-3's exact counter-input pinned as
a test (`router_content_dedupe_test.dart`, second case).

**Tests** — `test/services/notification/router_content_dedupe_test.dart`:
three producers → one in-app send; the trailing-`.` counter-input; distinct
notifications never merged; per-transport independence; a genuine repeat five
minutes later still fires.

**Failing-first proof** (recorded, then reverted): with the gate restored to
`if (transport.kind == systemPush)` and `${time.clock}` reverted to
`${time.local}`, the suite reported `Expected: an object with length of <1>` on
three cases and
`Actual: 'Sequence stopped by request at 2026-08-14T00:13:25.206940.'` — the
live evidence string, character for character.

**Collateral fixed:** `notification_router_test.dart`'s "rate limit caps fires
per window" routed five `frameCaptured` with an EMPTY context, so all five
rendered identical bodies and the new collapse reduced them to one. The test's
subject is the rate limiter, so it now routes distinct frame numbers. (Five
character-for-character identical notifications ARE one statement said five
times; collapsing them is the new contract, not a regression.)

---

## WF-STOP-N5 (timestamp half) — a wire format in operator copy

`${time.local}` is a **Rust-canonical catalog variable** — its description in
`interpolation_catalog.dart` promises "ISO-8601 with offset" and a CI drift test
pins the Dart list against `expressions/catalog.rs::variable_catalog`. So it was
not redefined.

Instead `NotificationContext.withDefaults()` now also populates `time.clock`
(`formatOperatorClock` → 24-hour `HH:mm`, matching
`sequence_time_estimator/node_durations.dart` and `pre_session_simulator.dart`;
an imaging session runs through midnight, so AM/PM is the wrong vocabulary), and
all **ten** built-in default bodies that named a time switched to it. A
user-authored template asking for `${time.local}` still gets ISO — pinned by a
test.

`renderNotificationTemplate` / `withDefaults` take the same injectable clock so
the rendering is deterministic under test.

Toast body now: `Sequence stopped by request at 00:13.`

**Test** — `test/services/notification/operator_clock_copy_test.dart`: the exact
stop body; **every** category's default body asserted free of
`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}`; and the `${time.local}` contract guard.

**NOT fixed (out of scope, do not double-file):** the other half of WF-STOP-N5 —
RECENT EVENTS' `Decision logged — system_event #14: Sequence cancelled`. That
string is produced by `packages/skotiq_bridge/lib/src/event_display.dart:423`
(`SequencerEvent_DecisionLogged() => 'Decision logged'`) plus the row id and raw
notice appended by its caller. `skotiq_bridge` is outside this batch's
declared scope and belongs with the stop-pipeline copy owner.

---

## WF-N1 — the scheduler's diagnostics were unreadable in a shipping build

Two independent causes; both fixed.

### (a) SchedulerEngine wrote only to `dart:developer`

In a release Flutter build that has no destination anyone can reach: the rolling
`skotiq.log.<date>` is written by the **Rust** tracing appender (0 Dart
lines, ever), and Settings ▸ Advanced ▸ Logs reads `LoggingService`'s in-memory
ring, which `dart:developer` never feeds.

* New `services/scheduler/scheduler_log.dart`: `SchedulerLogLevel`,
  `SchedulerLogSink`, `kSchedulerLogSource = 'SchedulerEngine'`, and
  `schedulerLogSinkFor(LoggingService)`.
* `SchedulerEngine` takes an optional `logSink` and routes **every** diagnostic
  through one `_log(level, message, {error})` that writes to BOTH destinations.
  All four bare `developer.log` sites (two reconcile arms, the dawn-park
  decline, the teardown trace) now go through it; a bare `developer.log` in this
  engine is now the thing to flag in review.
* `providers/scheduler/scheduler_engine_providers.dart` binds
  `logSink: schedulerLogSinkFor(ref.read(loggingServiceProvider))`.

Reach after the fix: the in-app Logs viewer (and its source dropdown, which now
offers `SchedulerEngine`), `/api/logs/recent` + `/api/logs/tail`, and the
**on-disk** diagnostic export — `LoggingService.exportLogs` already appends the
in-memory Dart entries after the native files.

**Honest caveat:** the *rolling* `skotiq.log.<date>` is still Rust-only.
Writing Dart lines into that exact file needs either a new FRB bridge fn into
the Rust `tracing` appender (Rust + codegen, both barred for this batch) or a
second Dart-owned sink in `logging_service.dart` (outside the declared scope).
The repro's grep over the exported log now finds `Scheduler`; the grep over the
raw rolling file does not. Recorded rather than claimed.

### (b) one line consumed the whole 1000-entry ring

`SequenceExecutor._handleSequencerEvent` traced EVERY backend event at debug
level. At ~5 lines/s that fills the ring in ~3 minutes, which is why the source
dropdown offered **only** `SequenceExecutor` — nothing else survived long
enough to appear.

* New `providers/sequence/log_rate_limiter.dart`. Rate-limited **per event
  type**, so a chatty type (`InstructionProgress`) collapses while a rare one
  (`Stopped`, `Error`) is traced the instant it arrives — a limiter that could
  hide the event you are looking for would be a worse bug than the spam.
* Nothing is dropped silently: the next admitted line for a key carries
  `(+N suppressed in the last 5s)`.
* Keys are pruned after 5 minutes so a long night cannot grow the map.

**Tests** — `test/providers/sequence/log_rate_limiter_test.dart` (six unit
cases including "a rare event type is never hidden behind a chatty one" and the
bounded-map case) plus a structural guard that the executor traces **through**
the limiter, against someone restoring the unconditional `_logger.debug`.
`test/services/scheduler/scheduler_diagnostics_sink_test.dart` drives a real
engine to the reconcile line and asserts a real `LoggingService` ring entry
under source `SchedulerEngine` at the right level.

---

## WF-N5 — a modal Session Report per autopilot run

* New `providers/sequence/session_report_presentation.dart`:
  `sessionReportPresentationFor({schedulerState, planOwner})` — a pure function
  of the two facts that answer "is anybody watching this run?". Queued when the
  autopilot is `running` **or** `paused` (a paused autopilot still holds the rig
  and resumes itself) **or** when the editor slot is owned by
  `ActivePlanOwner.autopilot` (still true just after the engine disengages,
  which is exactly when the last dispatched run finishes). Both signals are the
  ones `AutopilotArmedRule` already trusts.
* `PendingSessionReportsNotifier` / `pendingSessionReportsProvider`: a queue
  that de-dupes **on run identity**, not on list position, and caps at 20
  keeping the NEWEST.
* `sequencer_screen.dart`'s terminal-run listener consults the gate before
  `SessionReportDialog.show`. When queued it enqueues and raises ONE non-modal
  in-app info notice — and no notes prompt.
* `PendingSessionReportsCard` renders the queue at the top of Sequencer ▸
  History (nothing at all when empty), each row opening the real
  `SessionReportDialog` and retiring itself as it opens.

The card is not decoration: without it the toast's "open it from Sequencer ▸
History" would have been a **false claim** — the History tab opens
`PostSessionStatsDialog`, not `SessionReportDialog`; the only existing
`SessionReportDialog` entry points are in Analytics. That is the cry-wolf shape
this campaign exists to remove, so the affordance was built rather than the copy
pointed at a place the report is not.

**Not implemented (PRODUCT CALL, deliberately untouched):** WF-N3's "pause the
autopilot after an operator Stop" is on the verdict's off-limits list.

**Tests** — `test/providers/sequence/session_report_presentation_test.dart`
(all four gate combinations, queue identity/bound/removal) and
`skotiq_app/test/screens/sequencer/pending_session_reports_test.dart` (card
hidden when empty, listed + openable, Dismiss all, plus a structural guard that
the terminal listener consults the gate first).

---

## Gates

* `packages/skotiq_core`: full `flutter test` — **5901 passed, 4 skipped, 0
  failed**.
* `packages/skotiq_app`: full `flutter test` — 3485 passed, 56 failed, and
  **none of the 56 belong to this batch**:
  * 39 are `captures_landscape_test.dart` golden pixel diffs across **17
    screens** (dashboard, weather, guiding, equipment, analytics, diagnostics,
    settings, planner, framing, onboarding, flat_wizard, polar_alignment,
    stack_result, imaging, sequencer, …) — the known Windows-captured-goldens-
    fail-on-Linux class. Reproduced directly: `Golden
    "captures/sequencer_android_landscape_932x430.png": Pixel test failed,
    9.44%, 37838px diff`. The only widget this batch adds to a captured screen
    renders `SizedBox.shrink()` when its queue is empty, which every capture
    test's state is.
  * 8 `session_review_controller_test.dart` failures are network-dependent
    (`ClientException … basemaps.cartocdn.com … status 400`).
  * the rest (`help_reset_progress_promise`, `planner_copy_names_real_tabs`,
    `framing_*`, `morning_report_views`, `narrative_integrate_blocked`,
    `public_screenshots`) sit in files other F-fix batches had dirty in the
    same tree (`help_tutorials_settings.dart`, `status_bar.dart`,
    `skotiq_button.dart`, `preflight_validation_dialog.dart`, …) and touch
    nothing this batch changed. The first dashboard exception in the log is
    `SequenceLockedException` from `CockpitRunControls`.
* Targeted re-run of `test/screens/sequencer` + `notification_toast_dedupe_test`
  — **468 passed**, the same 2 golden pixel diffs failing.
* `flutter analyze` over every touched directory: clean apart from two
  pre-existing `info`s in `rejection_labels.dart` and one pre-existing unused
  import in `scheduler_rejection_labels_test.dart` (neither mine).
* `dart format` scoped to the 22 touched files only.

## Concurrency notes

Other F-fix batches were editing the tree throughout. `event_classifier.dart`
and `notification_router.dart` already carried the WD-EQ-2a disconnect-name fix
when this batch started; every edit here was made against the working-tree
content and placed in disjoint regions. Mid-batch the core package briefly
failed to compile on `nodeExposureTallyProvider` (a SEQ-18 batch landing
`node_exposure_tally.dart`); it resolved on its own and is not related to this
work. No git writes were made.
