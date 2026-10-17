# D-fix batch: settings-pairing-2

Source of truth for every item: `reports/release-pass/waveD-result.json` (still_broken /
new_findings) and `reports/release-pass/gui/waveD-settings-onboarding.md`.

Every behaviour item below has a test that FAILS at HEAD (proved by restoring the HEAD copy of
the lib file with `git show HEAD:<path>`, running the test, then restoring the fix). Two items
could not be reproduced in a widget test and are recorded as such rather than claimed.

---

## SET-2 residual (a) — "+ Add slot" on a full wheel

**Live evidence.** Step 6, Simulated Filter Wheel, 7/7 slots, caption "All 7 positions on this
wheel are listed." Clicking **+ Add slot** produced no row, no toast, no message; two a11y tree
dumps either side of the click diffed to nothing, and the role dump did *not* mark the button
`[DISABLED]`.

**Why the previous fix did not land.** The button was disabled (`onPressed: null`) and
`SkotiqButton` does publish `hasEnabledState`/`!isEnabled` — but its inner `GestureDetector`
always supplies `onTapDown`/`onTapUp`, so a `TapGestureRecognizer` exists and Flutter publishes a
**tap action on the disabled node**. Reproduced in a probe: the node came out as
`flags: [isButton, hasEnabledState]`, `actions: [tap]`. Assistive tech is offered a press that
does nothing.

**Fix** (`screens/onboarding/steps/filter_wheel_step.dart`): at the cap there is no control at
all. The header shows a muted "Wheel is full" / "Filter limit reached", and the reason moves out
of the removed button's tooltip onto the caption:
"All 7 positions on this wheel are listed — Simulated Filter Wheel has no slot 8 to hold another
filter." The generic (no-reading) cap now states itself too: "A profile can hold at most 12
filters." — previously that case printed nothing at all.

**Tests**: `test/screens/onboarding/filter_wheel_slot_cap_test.dart` — the two superseded
expectations were rewritten (they pinned the disabled-button contract) and the a11y assertion
added: no semantics node labelled "Add slot" may carry a tap action. All 3 rewritten/added
assertions fail at HEAD.

## SET-18 residual / WD-N4 — the pairing credential is unreadable to a screen reader

Both surfaces render the credential with `SelectableText`, which publishes its text as a semantic
**value**, not a name — so the AT-SPI tree showed `panel: Pairing phrase` then
`panel: Expires in 4:49` with nothing between them.

**Fix**: `Semantics(container: true, excludeSemantics: true, label: 'Pairing phrase: <code>')`
around the phrase in `remote_access_settings/lan_pairing_panel.dart`, and
`'Pairing code: <code>'` around the code in `settings/pairing_screen.dart`. The literal code is
kept verbatim in the label so a tree grep for it finds it. The Manage Pairing back arrow (also
called out, no accessible name — `IconButton` publishes `tooltip`, not `label`) is now an
`AccessibleIconButton` labelled "Back to Remote Access".

**Tests**: `remote_access_pairing_phrase_test.dart` ("the phrase has an accessible NAME, not only
a value") and `pairing_credential_truth_test.dart` (WD-N4). Both fail at HEAD.

## WD-N1 — raw Rust error debug text in the onboarding chips

`_BackendStatusRow` printed `state.error` verbatim: four wrapped red lines of
`SkotiqError.connectionFailed(deviceId: localhost:11111, reason: … tcp connect error:
Connection refused (os error 111))`, twice, on the third screen of the product.

**Fix**: `describeBackendFailure` (pure, `@visibleForTesting`) in `device_picker_step.dart`.
Recognised transports get the sentence that says what to do about them, keeping the endpoint —
"nothing is listening at localhost:11111", "… did not answer in time", "… could not be reached
from this network", "the address … could not be resolved", "… refused the connection as
unauthorised". A backend that already reports a *sentence* keeps it (the existing
`device_picker_backend_failure_test` case, "No Alpaca server answered on this network"); anything
carrying developer debris (`Type.method(`, `…Error`, `os error`, `://`, `package:`, `#0`, or >140
chars) is replaced with "the scan did not complete".

**Test**: `onboarding_backend_failure_copy_test.dart` — unit cases plus a widget assertion that no
rendered `Text` contains `SkotiqError` / `os error 111` / `tcp connect` / `http://`. Fails at
HEAD.

*Not fixed (out of scope, native)*: the log for the same scan still says "Discovery complete for
Camera: 1 devices, 0 backend errors" while the UI shows two backend errors.

## WD-N2 — step 6 painted two texts on top of each other

Root cause: the filter-wheel step hands the picker a **fixed 240 px box**, and the picker's chrome
is not fixed — the taller backend-error block (WD-N1) pushed the fixed children past the box, the
`Expanded` device list collapsed to zero, and the remainder overflowed and overprinted the slot
caption. (`RenderFlex overflowed` is raised by the widget test, which is what the pin catches.)

**Fix**: the picker body is a `LayoutBuilder` + `SingleChildScrollView` + `ConstrainedBox(minHeight:
constraints.maxHeight)`; the device list becomes a `ConstrainedBox(minHeight: 96)` instead of an
`Expanded` slot, and the inner `ListView` gets `NeverScrollableScrollPhysics` so the body scrolls
as one.

**Test**: same file, at 1600x900 and 1280x800 — no exception, and the caption's rect does not
overlap the "No matching device?" hint. Both fail at HEAD.

## WD-N3 — step 13 re-asserted the edited-away scope name

The optics step marks an edited library scope `Askar FRA400 — edited`; the closing step printed
`Telescope: Askar FRA400` beside an image scale computed from 1234 mm.

**Fix**: the match rule moved out of `_OpticalTrainStepState` into two shared functions in
`optical_train_step.dart` — `draftMatchesTelescopePreset` and `telescopeSummaryLabel` — and the
closing step now uses the latter (`next_steps_step.dart`).

**Test**: `onboarding_final_step_telescope_truth_test.dart` (3 cases: untouched preset, edited
preset, hand-entered rig). The edited case fails at HEAD.

## WD-N5 — the "paired" banner survived revoking that device

**Fix**: `PairingNotifier._adoptDevices(devices)` drops `lastPairedDevice` when its `deviceId` is
no longer in the refreshed active list; every device-list refresh (`loadPairedDevices`,
`revokeDevice`, `revokeAll`, `renameDevice`, `deleteDevice`) goes through it. Joined on identity,
never on list length.

## WD-N6 — "Revoke access for all 1 paired devices?"

**Fix**: with exactly one device the dialog uses the existing single-device copy — title
`pairingRevokeTitle`, body `pairingRevokeBody` (naming the device), confirm `pairingRevokeAccess`.
The plural body is kept for a real "all". No new l10n keys (the translation table is outside this
batch's scope); both strings already exist in en + es.

**Tests**: `pairing_credential_truth_test.dart` (WD-N5, WD-N6, plus a plural-still-works case).
Both fail at HEAD.

## WD-N7 — the Settings Tour coach mark covered Manage Pairing

The prompt wrapped the **whole** settings screen and floated. Turning on its existing
`reserveSpaceForCard` opt-in at that level is what previously pushed the sidebar's ADVANCED group
off-screen (SET-14, verified fixed in Wave D — must not regress).

**Fix** (`settings_screen.dart`): the `ContextualTourPrompt` now wraps only the pane the card sits
over — the detail pane on desktop, the single pane on a phone — with `reserveSpaceForCard: true`.
The section navigator keeps its full height; the detail pane holds a band clear while the nudge is
up, so nothing it draws ends up under the card.

**Test**: `settings_tour_prompt_overlap_test.dart`. Reproducing this needed the leaf as the
operator had it — remote access on AND the web server running (`webServerStateProvider` stubbed) —
otherwise the page is too short and the button never lands in the corner. At HEAD:
`the settings detail pane Rect.fromLTRB(260.0, 0.0, 1600.0, 900.0) runs under the tour card
Rect.fromLTRB(1344.0, 705.0, 1584.0, 884.0)`. A second case pins that ADVANCED and the rail are
untouched.

## WD-N8 — "Reset All Progress" promised a tour that never came back

`resetProgress()` deletes every `tutorial_progress` row, dismissed-coach-mark rows included — but
nothing told the running app: the dismissed set is held in memory and the first-launch tour status
is a cached future, so both still said "already seen" for the rest of the session.

**Fix** (`help_tutorials_settings.dart`): the confirm action also calls
`dismissedTourPromptsProvider.notifier.resetAllDismissed()` and
`onboardingTourProvider.notifier.reset()` — the same path the neighbouring "Re-run onboarding
tour" row uses, which invalidates `firstLaunchTourStatusProvider`.

**Test**: `help_reset_progress_promise_test.dart` — dismiss a prompt + complete the tour, reset,
then assert the dismissed set is empty and the status is `pending`. Fails at HEAD
(`Expected: empty  Actual: Set:['dashboard']`).

## WD-N9 — SET-20 residual: the idle "Pair phones and tablets" card

**Fix**: the panel's `Container` takes `width: double.infinity`, like every other card on the
leaf, so it cannot depend on how far its longest line happens to wrap (the QR's `Center` is what
stretched it once pairing started).

**Honest caveat**: I could NOT reproduce the ~530 px shrink in a widget test. At both 900 px and
1600 px window widths the card already measured full width at HEAD, because the body copy wraps to
the available width there. The fix removes the dependency entirely and the invariant is pinned
(`remote_access_pairing_phrase_test.dart` → "idle and pairing draw the same card", card ≥ 80 % of
the full-width neighbour), but that pin passes at HEAD as well, so it is a guard, not a proof.

## SET-12 residual — BLOCKED (owning files outside SCOPE)

The dashboard tour still narrates Session Progress / Weather Status / Focuser Control / Equipment
Overview on a dashboard that has none of them. The pass-over rule added by the earlier fix is
correct and unit-tested (`tutorialStepIndexPastMissingTarget`, `test/widgets/
tutorial_missing_target_test.dart`); what fails is the driver around it, in
`packages/skotiq_app/lib/widgets/tutorial_overlay.dart` (NOT in this batch's SCOPE, which is
`screens/{onboarding,settings,tutorial}`):

1. `_passOverMissingTarget` defers 450 ms before moving, so the absent step is drawn and announced
   first — which is exactly what an operator (and the auditor's tree dump immediately after a
   `Right` press) sees.
2. The chain stalls after ONE hop: `_resolvingMissingTarget` is cleared in a `finally` that runs
   *after* the rebuild triggered by `nextStep()`, and nothing schedules a further check, so at most
   one absent step is passed per operator action. Consecutive absent steps (3+4, 5+6, 9+10) leave
   the tour parked on one of them.

The deeper problem is content, not mechanism: the twelve dashboard-tour steps in
`packages/skotiq_core/lib/src/models/tutorial/tutorial_models_parts/workflow_tours.dart`
describe the legacy widget dashboard. Both files need an owner with that scope.

---

## Regression runs (this machine, concurrent agents editing other packages)

* `flutter test test/screens/onboarding` → **147 passed, 2 failed**; both failures are the
  Windows-captured goldens (`captures_landscape_test.dart`, 33.71 % / 27.09 % diff) and are
  **byte-identical at HEAD** — pre-existing, documented Linux-vs-Windows golden debt.
* `flutter test test/screens/settings` → **501 passed, 2 failed**; same golden pair
  (`settings_android_*`, 4.38 % / 8.70 %), identical diffs at HEAD.
* `flutter test test/widgets` → **293 passed, 0 failed** (covers the contextual-tour-prompt and
  tutorial-overlay pins that the WD-N7 change could have disturbed).
* `dart analyze` over the touched lib + test dirs: 0 errors, 0 warnings.
* `dart format` clean on every touched file.

Transient blocker seen repeatedly: `skotiq_core` / `skotiq_planetarium` failed to compile
mid-run while other D-fix agents were editing them (`ownsRun`, `Target`, `time_control_panel.dart`,
`plate_solve_service.dart`). Every run above was re-taken once those compiled.
