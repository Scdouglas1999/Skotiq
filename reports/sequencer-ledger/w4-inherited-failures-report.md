# w4-inherited-failures

Workstream: `w4-inherited-failures`
Branch: `agent/w4-inherited-failures`, based on `19a6a5a86`
Worktree: `/home/scdouglas/.cache/ns-worktrees/w4-inherited-failures`
`TMPDIR=$HOME/.cache/ns-tmp/w4-inherited-failures`, `--concurrency=3` throughout.

Note on the base: `briefs/common.md` names `23147bf0a` as the base commit, but this
workstream's brief names `19a6a5a86`, and `git rev-parse --short HEAD` in the worktree
returned `19a6a5a86`. Worked from `19a6a5a86` per the brief; nothing was detached or
re-checked-out.

Scope: the ten tests in `packages/skotiq_app` that were already failing on the base
commit. Nothing under `packages/skotiq_app/lib/screens/sequencer` or its tests was
touched (another agent owns it).

---

## The ten, and what each one was

| # | Test | Verdict | Fixed by |
|---|---|---|---|
| 1 | `analytics/analytics_empty_state_test.dart` — "the Analytics tab prints no page title and no essay" | **Both**: product copy wrong, test pinned in the wrong harness | `health_summary_cards.dart` + the test |
| 2 | `framing/framing_hips_layer_wiring_test.dart` — survey credit badge golden | **Neither** — Windows-captured baseline, unfixable on Linux | *not fixed, by design* |
| 3 | `framing/framing_registration_test.dart` — FOV reticle under rotation golden | **Neither** — Windows-captured baseline, unfixable on Linux | *not fixed, by design* |
| 4–6 | `mobile_tap_target_test.dart` — equipment at 360x640 / 390x844 / 430x932 | **Product** | `discovery_panel.dart` |
| 7–9 | `planetarium/planetarium_hud_labels_test.dart` — popup actions (3 cases) | **Test** (stale copy) | the test, + two stale comments |
| 10 | `planner/planner_screen_test.dart` — catalog search under keyboard insets | **Product** | `_header_and_controls_bar.dart`, `_recommendation_tab.dart` |

---

## 1. Analytics / Diagnostics — "Lower scores are better."

**Symptom.** `find.textContaining('Lower scores are better.')` found 0 widgets. The
string does not exist anywhere in the repo.

**What actually happened.** `git log -S` traces it precisely:

- `2cf430f0d` (2026-08-13) added the assertion. At that time the Diagnostics header
  carried the paragraph *"Optical-train health across the whole session: collimation,
  tilt, backfocus and field flatness. Lower scores are better."*
- `dab691498` (2026-09-09 18:45) *"Drop the Diagnostics explainer and its learn-more
  link"* deleted that whole paragraph, the docs chip and the guide dialog, citing
  `docs/design/overhaul/07-implementation-waves.md:234` — *"Do not add a subtitle, a
  hint sentence, a tooltip paragraph, or a 'Learn more' link to explain a screen."*
- `e743f9d44` (2026-09-09 18:52, seven minutes later) edited this very test file for an
  unrelated reason and left the assertion behind. It has been red ever since.

**The adjudication.** Both halves of the test were partly right.

- The removal was correct: the paragraph's first clause ("Optical-train health across
  the whole session: collimation, tilt, backfocus and field flatness") is exactly the
  screen-explaining hint sentence 07 forbids, and it printed above an *empty state*,
  where it labelled nothing.
- The legend half was not. A **penalty score** is the one number on that surface a
  reader cannot infer the direction of: 0 is a clean optical train, 100 is the worst
  measured, and every other figure in Skotiq reads better as it rises.

And the legend had in fact survived the removal — on `_HealthGradeCard`, directly above
the two `_ScoreBar`s whose figures it reads. But it was wrong there in two ways:

```dart
'Lower bars are better. Use this grade as a quick summary before diving into the field map and findings.'
```

1. *"bars"* names the decoration. `_ScoreBar` prints `clampedValue.toStringAsFixed(0)`
   at the end of each bar — the **figure** is the reading, the bar is the picture of it.
   The rest of the surface (`tiltScore`, `collimationScore`, "Score 0.0: …") says
   *score*.
2. The trailing sentence — *"Use this grade as a quick summary before diving into the
   field map and findings"* — is a screen hint, the same thing `dab691498` removed from
   the header. It survived only because it was bolted onto a legend.

**Product fix** (`lib/screens/diagnostics/diagnostics_screen/health_summary_cards.dart`):
the legend becomes `'Lower scores are better.'`, the hint sentence goes, and the raw
`TextStyle(fontSize: fontSize11, …)` becomes the named `SkotiqTypography.captionSm`.

**Test fix** (`test/screens/analytics/analytics_empty_state_test.dart`): the assertion
was pinned in a harness where the widget it names cannot exist — `DiagnosticsTabContent`
with `allSessionsProvider` empty renders the *empty state*, and a legend above an empty
state labels nothing. So:

- the empty-state case keeps its two `findsNothing` assertions (no H1, no scope essay)
  and gains a third: the legend must **not** come back as page chrome there;
- a new case, *"a measured session still says which direction is good"*, drives the
  Diagnostics **data** branch — one completed session, selected via a
  `SessionStateNotifier` override, nine PSF field tiles through the **real**
  `OpticalTrainDiagnosticsService` — and asserts `find.textContaining('Lower scores are
  better.')` `findsOneWidget` on the card that now owns it, plus `findsNothing` for the
  removed hint sentence.

Nothing was deleted or loosened: the original assertion still runs, verbatim, in a
harness where it can actually fail.

---

## 2 & 3. The two framing goldens — NOT regenerated

**Verdict: Windows-captured baselines that cannot match a Linux renderer. Do not
regenerate on this machine.** This is the outcome the brief asked for in that case.

Evidence, in order of weight:

1. **Both failing cases are tagged `golden`.** `framing_registration_test.dart:356` and
   `framing_hips_layer_wiring_test.dart:329` both carry `tags: 'golden'` — a per-test
   tag on the single golden case inside a file that otherwise holds non-golden geometry
   guards (all of which pass).
2. **`packages/skotiq_app/dart_test.yaml`** declares that tag with the reason:
   *"Pixel-diff / capture golden tests whose baselines are host-specific… EXCLUDED from
   `melos run test` (Linux CI + default local runs) via `--exclude-tags golden`."*
3. **`melos.yaml:318`** — `test` runs `flutter test --exclude-tags golden`; `test:golden`
   (line 326) is the opt-in that runs only them.
4. **`docs/testing/golden-tests.md`** names the host outright: *"The committed baselines
   were captured on a Windows host; they do not match a Linux renderer"*, and
   *"do not commit Linux-rendered baselines unless the team has decided to move the
   canonical host to Linux (in which case re-baseline ALL pixel-diff suites together)."*
5. **`docs/design/overhaul/07-implementation-waves.md:238`** — *"Do not regenerate
   Windows goldens on Linux and commit them."*
6. **Repo history has already rejected exactly this.** `11038acb0` *"revert(design):
   un-commit the Linux-rerendered screen goldens"* and `654b03744` *"revert: restore the
   Windows-rendered goldens a git add -A swept up"* both undo a Linux re-baseline that a
   `git add -A` picked up, 31 images between them.
7. **The pixel evidence agrees**, measured from the failure artefacts:

   | golden | pixels differing | max ΔRGB | >8Δ | >32Δ |
   |---|---|---|---|---|
   | `framing_hips_layer_wiring.png` | 100.00% | 84 | 0.63% | 0.16% |
   | `framing_canvas_registered.png` | 75.4% | 244 | 14.7% | 8.1% |

   For the HiPS badge golden this is textbook host drift: 99.4% of the differing pixels
   are off by ≤8 units — a one-unit shift over a full-screen near-black gradient, which
   is enough to score "100% of pixels differ" — and the badge itself is byte-for-byte in
   the same place with the same content. Nothing in the code moved.

   `framing_canvas_registered.png` carries host drift **plus** 15 months of chrome
   evolution: its baseline was last written in `fa48512fa` (2026-06-01) and the toolbar,
   right rail and bottom banner have all been rewritten since. Critically, the thing the
   test exists to lock — *"the composed survey background + co-registered FOV reticle
   renders pixel-stably under rotation"* — is **unchanged**: the rotated FOV rectangle,
   its four corners, the centre crosshair and the marker pin land on identical pixels in
   both images. The diff is entirely the surrounding chrome.

**Consequence for verification.** `flutter test test/screens` (no tag filter) therefore
cannot reach zero on a Linux host, and no code change can make it. The repo's own gate —
the one CI runs — is `--exclude-tags golden`, and that is green. Both numbers are
reported below rather than one being presented as the other.

Re-baselining these two is a Windows task: `flutter test --update-goldens --tags golden`
on the canonical host, per `docs/testing/golden-tests.md`.

---

## 4–6. Equipment tap targets — product

**Symptom.** At all three phone widths, three controls measured `48.0x44.0`:
`"Rescan"`, `"Scan all"`, `"Expand"`.

**Cause.** `discovery_panel.dart` wraps the drawer's head row in
`SizedBox(height: _discoveryHeadHeight)` where `_discoveryHeadHeight = 44.0` *("The
drawer's head row height, per 06 §Equipment")*. Below `_discoveryHeadCompactWidth`
(520 px) the two labelled scan buttons collapse to `SkotiqIconButton`s, and that
control already does the right thing — `math.max(widget.extent,
SkotiqTouchTarget.minExtent(context))` grows its interactive box to 48 on a touch
platform. But a `Row` can only hand down the height it was itself given, so the 48-tall
box was squeezed back to 44 by the fixed-height parent. Width 48, height 44 — exactly
what the test reported.

**Fix.** The sheet's 44 is a *pointer* height. The row now takes
`math.max(_discoveryHeadHeight, SkotiqTouchTarget.minExtent(context))`: 44 on
desktop (`minExtent` returns 0 there, so the mockup's density is untouched), 48 on a
phone. This is the helper's documented contract, used the same way
`SkotiqIconButton` uses it.

The test's assertion is right as written and was not touched.

---

## 7–9. Planetarium popup actions — test

**Symptom.** `find.text('Log Observation')` found **0** widgets, so all three cases in
the `object info popup actions` group failed on a missing finder — one on the explicit
`findsOneWidget`, one on `renderObject()` throwing `Bad state: No element`, one on
`getTopLeft()`.

**Cause.** Pure copy drift, not layout. The popup's labels are
`'Log observation'` and `'Target queue'`; the test named the pre-Observatory
`'Log Observation'` and `'Target Queue'`.

**The adjudication — the product is right.**
`docs/design/overhaul/06-screens.md:252` — *"Sentence case everywhere ('Frame type',
not 'Frame Type'), including tab labels and buttons"*, echoed by
`02-design-language.md:51`. The Observatory pass converted these correctly.

And the defect these three cases exist to guard is **already fixed** in the product:
`object_info_popup.dart:634` documents the two-per-row rule, the popup width was raised
to 340 for exactly this reason, and once the finders resolve all three cases pass
without any layout change. The test was the only stale part.

**Fix.** The three label lists now name the strings on screen, with a header comment
recording *why* they read the way they do so the next rename does not silently take the
guard with it. Two comments inside `object_info_popup.dart` that still quoted the old
title-case names were corrected with them.

**Not fixed (out of scope, flagged).** `'Add to List'` in the same popup is still
title case, as is `'Log Observation'` inside `ObservationLogDialog` — both are
sentence-case debt under 06 §252, neither is part of the ten failures, and renaming
`'Add to List'` would also require re-wording the `lists_tab.dart` copy that quotes it.
Left for a copy pass.

---

## 10. Planner catalog search under keyboard insets — product

**Symptom.** *"catalog search fits when an outer shell consumes keyboard insets"* —
`A RenderFlex overflowed by 20 pixels on the bottom`.

**Cause** (measured, not inferred — reproduced with a scratch harness that captured the
full `FlutterErrorDetails`; the scratch file was deleted, nothing of it is committed):

- The test puts `PlannerScreen` in an 86 px box at 932x430 with **no** `viewInsets` —
  the premise being an outer shell that already resized for the keyboard.
- `planner_screen.dart:298` keys its own `keyboardCompact` off
  `MediaQuery.viewInsetsOf(context).bottom > 0`, which is 0 here, so `PageHeader` stays
  and takes 57 px. The recommendation tab is handed **29 px**.
- `_recommendation_tab.dart` *did* already fall back to height
  (`constraints.maxHeight < 120`), and the controls bar *did* zero its vertical padding
  in response. That is not enough: the overflowing `RenderFlex` is the controls bar's
  own `Row`, at **49 px** against a 29 px slot — a 20 px overflow, exactly as reported.
- The 49 is the **Filters chip**: `_ControlChip` → `SkotiqFilterChip` →
  `SkotiqTouchTarget.hitBox`, which is a 48 dp interactive box on a touch platform,
  plus the bar's 1 px hairline. Zeroing padding cannot buy 48 px out of 29.

**Fix.** `07:237` — *"Do not scale fonts down to make something fit. Reduce content or
let it scroll."* Vertical space is the constraint, so content reduces:

- `_PlannerControlsBar` now takes `availableHeight` instead of a `keyboardCompact`
  boolean and derives both decisions from it. The height it was actually given is the
  only signal that survives an outer shell consuming the insets on its behalf, which is
  the whole point of the test.
- It drops the Filters chip (and, below the desktop breakpoint, the sort with it) when
  `availableHeight < max(SkotiqFilterChip.height, SkotiqTouchTarget.minExtent) +
  hairline` — i.e. only when the slot genuinely cannot hold one, never merely because a
  keyboard is up. The filters return the moment it closes, and nothing loses its control
  permanently: they all live in the Filters sheet either way.
- The bar's bottom hairline is now the named `_kPlannerControlsHairline` that the fit
  calculation uses, rather than a `BorderSide` default the arithmetic assumed.

**Dead code removed along the way.** `_SearchField.height` was stored and never read —
`build()` passes `dense: true`, which is always `fieldHeightDense` (28). The call site's
`height: keyboardCompact ? 32 : 36` described a field that has never been 32 or 36. Both
gone; the test's `expect(tester.getSize(search).height, fieldHeightDense)` is what has
always been true.

---

## Commands and exit codes

All unpiped, `TMPDIR=$HOME/.cache/ns-tmp/w4-inherited-failures`, from
`packages/skotiq_app` unless noted.

| Command | Exit | Result |
|---|---|---|
| `flutter test <the six files> --concurrency=3` (base, before any change) | 1 | 3745-equivalent slice: **10 failing** |
| `flutter test test/screens/mobile_tap_target_test.dart --concurrency=3` | 0 | 24 pass |
| `flutter test test/screens/planetarium/planetarium_hud_labels_test.dart --concurrency=3` | 0 | 9 pass |
| `flutter test test/screens/planner/planner_screen_test.dart --concurrency=3` | 0 | 25 pass |
| `flutter test test/screens/planner --concurrency=3` | 0 | 109 pass |
| `flutter test test/screens/analytics/analytics_empty_state_test.dart --concurrency=3` | 0 | 7 pass |
| `flutter test test/screens/diagnostics test/screens/analytics test/screens/equipment --concurrency=3` | 0 | 457 pass |
| `dart analyze` (in `packages/skotiq_app`) | 2 | **890 issues — identical to the documented baseline of 890; zero new** |
| `dart format --output=none --set-exit-if-changed <touched files>` | 0 | clean |

`dart analyze` exits 2 whenever any `info` is present; the number, not the exit code, is
the gate here, and it is unchanged at 890. None of the 890 sit on a line this workstream
wrote: the entries in the touched files are all pre-existing `deprecated_member_use`
(wave-4 token/typography deprecations), one pre-existing `unused_element`
(`_tapCandidateAction`) and one pre-existing `unnecessary_import`, all present on the
base commit.

### The two suite-level runs

| Command | Exit | Result |
|---|---|---|
| `flutter test test/screens --concurrency=3` | 1 | **3754 pass / 2 fail** — the two failures are the Windows goldens of §2 & 3, and nothing else |
| `flutter test test/screens --concurrency=3 --exclude-tags golden` (the repo's own gate: `melos.yaml:318`) | **0** | **3753 pass / 0 fail — fully green** |
| `flutter test test/screens/sequencer --concurrency=3` | **0** | **688 pass** — unchanged, as required |

Base was 3745 pass / 10 fail. Untagged now stands at 3754 / 2: the eight fixable
failures are fixed (+8) and the new measured-diagnostics case adds one more (+1). The
2 that remain are the pair no Linux host can make green, and the tag-filtered run — the
one `melos run test` and CI actually execute — is 3753 / 0.

No test outside the ten changed verdict in either direction, and the sequencer directory
is untouched at 688: this workstream wrote nothing under
`packages/skotiq_app/lib/screens/sequencer` or its tests.

---

## Left undone

- **The two framing goldens.** Deliberately not regenerated; see §2 & 3. They need
  `flutter test --update-goldens --tags golden` on the Windows canonical host. A Linux
  regeneration here would have made this branch green and the release path red, which
  both `docs/testing/golden-tests.md` and `07:238` forbid, and which this repo has
  already reverted twice (`11038acb0`, `654b03744`).
- **Sentence-case debt adjacent to the planetarium fix** — `'Add to List'` in
  `object_info_popup.dart` and `'Log Observation'` in `observation_log_dialog.dart`.
  Flagged in §7–9, not fixed: outside the ten, and the first has a copy dependency in
  `lists_tab.dart`.
