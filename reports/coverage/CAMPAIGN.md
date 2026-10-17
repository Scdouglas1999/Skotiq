# End-to-end audit campaign — final state

The complaint this campaign answers: *every serious audit of Skotiq finds more bugs, gets
declared done, and the next one finds more again.* The cause was never that nobody looked. Coverage
was **exploratory** — each pass wandered a path, found what was on it, and reported the area
complete. Nothing recorded which of the app's ~1,800 controls had been exercised, so "done" could
not mean anything.

## Where it ended

| | |
|---|---|
| Units exercised | **347 visited** · 68 recorded unreached · 12 never claimed |
| Findings | **431** — 293 defects, 114 UX, 15 wrong-defaults, 9 missing |
| Independently reproduced | **248 confirmed**, **26 refuted and discarded** |
| Defects fixed | **281** · already closed by an earlier wave **120** · not real **4** |
| Confirmed defects still open | **0** |
| Product critique | **78 fixed** · **23 escalated to the owner** · 9 already correct · 3 not real |
| Product fixes independently verified | **85 of 85** — 55 held, **30 did not** |

Gates, all green on one tree: `skotiq_core` **5538** · `skotiq_app` **3046** ·
`skotiq_ui` **263** · `skotiq_desktop` **1014** · `skotiq_planetarium` **501** ·
`skotiq_mobile` **233** · bridge **120** · plugins **62** · remote_protocol **207** · updater
**89** · Rust workspace **2086** · `dart analyze` **0 errors 0 warnings** · analyzer rollup
**0/0/0 production** · `dart format` clean · `cargo fmt --check` clean · `semantics_audit` **16/16** ·
`placeholder_audit` and `behavioral_audit` pass. App suites run with the `golden` tag excluded,
exactly as `melos run test` does.

Convergence across fix waves: **118 → 65 → 31 → 18 → 7 → 2 → 0**.

The five planetarium benchmark goldens fail on this host and are **not** a regression: the identical
`maxDelta=218 changed=4.4271%` appears on a pristine `HEAD` worktree. Baselines are host-specific,
which is why `melos run test` excludes the `golden` tag by design.

## The machinery (this is what outlives the campaign)

* **`tools/production/coverage_inventory.dart`** — derives the audit's denominator from source: every
  screen, all 32 settings sections and their 664 rows, all 37 sequence instruction types, shared
  dialogs, mobile screens. `--report` names what has never been visited, so a new feature regenerates
  in as *untested* rather than escaping silently.
* **`tools/production/coverage_merge.dart`** — folds results back in, recording unreached units **with
  reasons**. A partial sweep can no longer read as a complete one.
* **`tools/production/findings_report.dart`** — one triage document ordered by the verifier's
  corrected severity; `--kind ux,default,missing` renders the product critique separately.
* **`tools/production/semantics_audit.dart`** — fails when a design-system component handles a tap but
  exposes no accessibility semantics.
* **`tools/ui_audit/drive_linux.py`** — sandboxed desktop instances, live accessibility tree with
  control STATES, window-cropped screenshots, `click-img` coordinate mapping.
* **`tools/ui_audit/drive_android.py`** — the same for a real Android emulator, where `uiautomator`
  supplies geometry so controls can be tapped BY NAME and a DISABLED control refuses the tap.

## What made the findings trustworthy

**Adversarial verification before fixing.** Verifiers were told to refute. 26 findings were refuted
and never reached a fixer. More valuable: **~74 of 175 verified findings (38% of P0/P1, 44% of
P2/P3) cited a `file:line` that did not contain the claim** — one pointed at a file with no weather
or safety code at all. Nearly half the fix work would have edited unrelated code while the symptom
stayed live.

**A fix is not accepted without a test that fails when reverted** — and the test must fail when the
production CALL SITE is severed, not just when logic inside a function changes. That drill caught a
batch whose entire production wiring could be cut with all 434 tests still green, and later found
three of four hops undefended in a fix that genuinely worked.

**The waves audited themselves.** Inside its own fix waves this campaign caught six fixes that only
DISCLOSED the problem, one that RELOCATED it, and one that INVERTED it — a scheduler change that
made a wheel-less rig unschedulable the moment the operator followed the app's own on-screen prompt.
Each became a warning in the next wave's brief.

**Corrections are recorded, not quietly rewritten.** The idle-CPU finding was downgraded P1 → P3
after a follow-up experiment refuted its stated reason; the DATE-OBS fix introduced a regression that
the audit caught. Both are preserved in `lead-findings-2026-08-01.md` with the original measurements
intact.

## The product-critique pass

The 138 UX / wrong-default / missing findings were worked separately from the defects, because they
are a different kind of claim: the code does what it was written to do, and the question is whether
that was the right thing to write. **113 were addressed — 78 fixed, 23 escalated, 9 already correct,
3 not real.**

The split was the point. Anything with an objectively right answer was fixed (the narrowband mixer
opened with every channel weight at 0.00, i.e. rendering black; `Loop` and `Conditional` defaulted to
no-ops; changing a flat count took 27 clicks; the Weather radar opened on the OLDEST frame, showing
two-hour-stale cloud by default). Anything that would decide *what the app is* was written up with
options, trade-offs and a recommendation, and left alone: see **`PRODUCT-DECISIONS.md`**. Several of
those recommendations are "leave it as it is, and here is what changing it would cost".

## The product-fix verification wave (2026-08-09)

All 85 product fixes have now been adversarially verified, in 15 shards of ~6. **55 held; 30 did
not** — 24 incomplete, 3 relocated, 2 regressions, 1 disclosure-only. That is a **35% refutation
rate**, more than double the ~1-in-6 of every earlier verify pass in this campaign, and it is the
strongest evidence the campaign produced that "the fixer says it is fixed" is not a state anything
should be shipped from. Verifiers repaired 28 of the 30 in place; the remaining two are dealt with
below.

Two of the thirty are worth naming because of what they were:

* **A hard compile error shipped in `skotiq_app`'s lib.** `stack_result_screen.dart:914` passed
  a `Future<DateTime?>` into a `DateTime?` parameter, so the app could not build and every test
  importing `StackResultScreen` failed to load. Caught and repaired by the shard verifying that
  area.
* **A re-entrancy crash introduced by another fix in the same wave.** The polar-alignment
  History-reveal fix drove `TabController.index` from inside `build` on the phone layout, whose
  synchronous listener wrote straight back into the provider: *"Tried to modify a provider while
  the widget tree was building"*. Repaired with a re-entrancy guard plus a regression test.

**Evidence taken during a fan-out is not evidence.** One shard reported the settings test directory
as non-deterministic — 10 failures, then 2 on the identical tree — and called it a test-infra
hazard. On a quiet tree it is not: three consecutive runs gave 459/459, 459/459, 459/459. Fourteen
other agents were editing and recompiling the same working tree during that shard's runs, and its
runs also included the `golden`-tagged captures tests whose baselines are host-specific. Several
other shards hit the same thing and correctly refused to attribute it. Drift's "created the
database class multiple times" warning is the known red herring — it fires for two in-memory
databases as readily as for two writers on one file.

One bookkeeping loss, recorded rather than papered over: this wave's shard filenames collided with
the older per-area verdict files and overwrote 8 verdicts from the earlier pass. The old workflow's
journal held nothing recoverable (all twelve of its agents had died before returning), so those 8
items were put back through as a `recovered` shard and re-verified for real.

## How this campaign ends

Not on a schedule. The owner's instruction (2026-08-09) is to keep launching waves until one comes
back **dry** — a wave that surfaces nothing new — because a campaign that stops when its *planned*
waves run out reproduces the exact failure it was convened to fix. Every wave here has been a
discovery pass as much as a fix pass, and every verify pass has refuted between one in six and one
in three of the fixes it checked, so no fix wave is terminal on its own.

## Still open, honestly

0. **The ledger was measuring one package's screen tree. Real coverage is 29%, not 97%.**
   This is the most serious item on the list, because every other coverage number in this document
   was a fraction of a denominator that left most of the product out.
   `coverage_inventory.dart` built its units from five sources only: `skotiq_app/lib/screens`,
   the settings search index, the sequence-node models, `skotiq_app/lib/widgets`, and
   `apps/mobile/lib`. It has now been extended, and the ledger went from **402 units to 1,143**:

   | added | units |
   |---|---|
   | headless HTTP/WS routes (`api:*`) | 577 |
   | design system (`skotiq_ui/lib`) | 36 |
   | planetarium package | 8 |
   | desktop app + headless handlers | 6 |
   | web dashboard, run-watch page | 2 |
   | screens and widgets newly visible to the gesture patterns | ~110 |

   Two separate blind spots caused it. One was scope: the web dashboard is a mouse-driven surface
   the appliance serves to anyone on the LAN, the API is the entire interface the mobile app and
   every third-party client see, and neither was ever counted. The other was subtler and worse —
   `_countControls` only recognised **Material-style** constructors, so a surface built out of
   gestures over a `CustomPainter` registered as having nothing to touch. The planetarium, one of
   the app's three headline features, contributed **two** units to a 402-unit ledger. Patterns for
   `GestureDetector` / `InkWell` / `onTap:` / drag / zoom-pan / keyboard shortcuts now exist, and
   that alone surfaced ~110 more units in trees that were already being counted.

   Regenerating also exposed **duplicate unit ids** — two files colliding on one basename-keyed id,
   so whichever a sweep visits marks both. The generator now warns about them rather than hiding
   them; they are not renamed because renaming orphans every `status.json` record.

   **333 of 1,143 visited (29.1%).** That is the honest starting point for the next waves.

1. **25 product decisions** — the owner's call, not the audit's. `PRODUCT-DECISIONS.md`. Item 25
   is new: the `Loop`/`Conditional` no-op defaults, where the wave's fix added an INFO badge
   announcing the no-op instead of changing the default. The verifier deliberately declined to
   invent a default, and so do I.
2. **80 units nobody has exercised** — 68 recorded unreached with a reason, 12 never claimed at
   all. `CLOSEOUT-PLAN.md` clusters them by what would actually unblock each, and flags four whose
   recorded reason is already stale. The old "7 unswept" figure counted only the never-claimed:
   a sweeper who wrote down why they could not reach something had it dropped from the
   denominator, which is precisely the accounting this campaign exists to end.
3. **The simulator cannot be plate-solved.** S9 in `simulator-fidelity-backlog.md`. This is the
   largest remaining fidelity gap by reach — Slew & Center, framing, mosaic, meridian-flip
   recentre, blind solve and the catalog overlay are all unexercisable without hardware because
   `sim_frame.rs` paints a pseudo-random field rather than the sky the mount points at. Proven
   closable: `tools/sim_fidelity/plate_solve_probe.py` renders real catalogue stars onto the
   simulated sensor and ASTAP recovers the centre to sub-pixel accuracy at every focal length from
   135mm to 1000mm.
4. **Nothing is validated on hardware.** Every telemetry read added here was exercised against
   simulators and test doubles. This cannot be closed until a rig is connected.

## Closed since the first draft of this document

* **Confirmed defects: 0.** The last two P2s were closed with evidence gathered at source.
* **The Night Narrator says something on a hand-driven night.** The second of the two verdicts no
  verifier would repair, and the better example of the INCOMPLETE shape: the wave's fix pointed the
  ticker at the sessionless feed, and nothing wrote to that feed. `_bindStreams` returns as soon as
  `_sessionId == null`, and `_onImagesChanged` — the only producer of `_imageStats`, `_skySamples`,
  `_gradeEvents` and `_solveHistory` — hangs off `sessionImagesStreamProvider`, bound below that
  return. `_bindLastImageStats` did fire sessionless but wrote only `_pendingFwhm`, read at exactly
  one place inside `_onImagesChanged`: a write-only variable. So an operator shooting by hand for an
  hour saw an empty strip, which was the original complaint, one layer down.

  Closed by giving the sessionless path its own producer (`_ingestSessionlessStats`, keyed on object
  IDENTITY because two consecutive subs of one target can legitimately measure equal), by moving the
  science-stage listener above the early return since that provider was never session-scoped, and by
  bounding the sessionless dedupe. That last one was a separate bug in the same chain:
  `hasDedupeKey(null, key)` filtered on `sessionId IS NULL` with no time component, so a static-key
  detector — `conditions.excellent`, `milestone.calibration_locked` — could fire once per install
  and never again on any later night. Session-scoped events were immune because each night gets a
  fresh id; the bucket the ticker had just been pointed at was not.
  `narrator_sessionless_test.dart` pins all of it, and severing the production call site turns three
  of its six red.
* **The idle-repaint question is settled** — and it was not what the first measurement implied. A
  purpose-built frame counter (`apps/desktop/lib/frame_timing_probe.dart`, armed by
  `SKOTIQ_FRAME_TIMING=1`) showed a rock-steady **1.0 fps** at idle with `buildAvgMs=0.1`: no
  runaway animation, just the status-bar clock's `setState` rebuilding the entire bar once a second
  to move one digit. The tick now lives in the clock chip behind a `RepaintBoundary`. Re-measured
  after the fix, the idle frame rate is **unchanged** (a clock showing seconds must produce a frame
  per second) and per-frame raster cost is unchanged within noise — so the proven benefit is the
  scoped rebuild, not a performance win, and the write-up says so. Full numbers in
  `lead-findings-2026-08-01.md`.
* **The "cold-start" test flakiness was never cold-start.** `databaseProvider` builds a fresh
  `SkotiqDatabase` per `ProviderContainer`, and every one of them resolves the SAME per-isolate
  temp file. Two containers alive at once put two SQLite writers on one file and both ran schema
  creation; the loser died with `database is locked` or `index idx_profiles_name already exists`,
  which surfaced as an unrelated-looking failure in whatever the test was doing — a capture test
  reporting that the frame "could not be saved". Reproduced directly with a two-instance probe, then
  closed by giving every affected container a private in-memory database
  (`packages/skotiq_core/test/harness/in_memory_database.dart`, applied across the core suite).
  The same hazard existed in `skotiq_app`, realised as `plan_tonight` failures under gate load.
  Closed there by exporting `inMemoryDatabaseOverride()` from
  `packages/skotiq_app/test/harness/mock_database.dart` and wiring it into tests that
  build `ProviderContainer`s or multiple scopes (plus the plan-tonight helpers).

  Two things about that closure are worth keeping, because both are traps for anyone repeating it.

  **Drift's own warning is not a hazard count.** "You've created the database class
  SkotiqDatabase multiple times" fires for two *in-memory* databases as readily as for two
  writers on one file, so grepping it out of a test log over-counts: after the override was applied
  it fired *more*, not less. The real signal is the shared temp path, not the instance count.

  **A working in-memory DB has a second-order cost.** Once a scope owns a real database, any
  provider watching a drift query stream holds a live subscription, and disposing the scope makes
  drift schedule a **zero-duration** timer in `StreamQueryStore.markAsClosed`. Flutter's binding
  then fails the test with `'!timersPending'`, reported against whatever assertion ran last — so it
  reads as a failure in the widget under test. A `tearDown` cannot fix it (the binding checks
  *before* tear-downs run) and neither can a bare `pump()` (it does not advance the fake clock, so a
  timer scheduled for *now* is still queued). `test/harness/provider_teardown.dart` does both
  halves: unmount, then pump a non-zero duration. `pumpAppScreen` already isolates the DB for the
  harness path.
