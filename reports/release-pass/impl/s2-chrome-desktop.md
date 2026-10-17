# Stage-2 batch: chrome-desktop

Items: EQP-23 (silent process death), CON-61b (Settings `?section=` ignored when
already open), SET-17 revoke-all.

All three were reproduced against HEAD before anything was changed; two by a
failing widget test, one by inspection of the death path plus a new unit suite
that pins the contract the entry point had none of.

## CON-61b — a `?section=` deep link taken while Settings is open did nothing

Confirmed at HEAD. `test/screens/settings/settings_section_route_update_test.dart`
rebuilds the SAME `SettingsScreen` element with a new `initialSection` (which is
exactly what the keyless `/settings` page does when the router re-runs its
pageBuilder) and asserts the pane follows. At HEAD:

```
Expected: exactly one matching candidate
  Actual: Found 0 widgets with type "AboutSettings"
```

Fix: `_SettingsScreenState.didUpdateWidget` resolves the new key
(`resolveSectionKey`, so merged-away aliases still land on their combined
section), selects it, expands its sidebar group and — on a phone — shows the
detail pane. Guards, both covered by tests in the same file:

* only a CHANGED key is a navigation request, so a plain parent rebuild does not
  snap the operator back to the deep-linked section;
* an unknown key resolves to null and moves nothing, rather than falling back to
  the first category under the operator.

This is the second half of the b-fix wave's CON-61: the title bar's profile icon
(`/settings?section=equipment-profiles`) and ~8 sibling in-Settings links now
land. The router itself was not touched (out of scope, and not the defect).

Note the one case still inert by construction: following the SAME link twice
(already on that exact section) changes nothing — because the screen is already
showing what the link names.

## SET-17 revoke-all — "take my rig off the network" was 13 dialogs deep

Confirmed at HEAD: `test/screens/settings/pairing_revoke_all_test.dart` fails
looking for a `Revoke All` control that does not exist. Built bottom-up so the
stored rows — not the painted list — are what changes:

* `PairingDatabase.revokeAllDevices()` flips every active row inactive and drops
  each device's cellular-push token + preference rows (same reason the
  single-device revoke does: a deauthorized phone must stop receiving
  criticals). Returns the rows it revoked.
* `TokenManager.revokeAllDevices()` announces every revoked session token
  through the existing revocation listener, so the headless auth middleware's
  in-memory `_pairedSessionTokens` map (keyed by token value, not device id)
  evicts them without a host restart, and returns the count.
* `PairingNotifier.revokeAll()` runs through the existing `_enqueue` serialiser
  and returns false when nothing was revoked, so the UI never reports a
  revocation that did not happen.
* Pairing screen: a destructive `Revoke All` button in the Paired Devices header,
  present only when there is something to revoke, behind a confirmation that
  names the count. `_showDeviceActionDialog` was split into a generic
  `_showConfirmDialog` (body text) plus the device-specific wrapper — same
  dialog, busy/PopScope/error-snackbar behaviour unchanged.
* New l10n keys in `en` + `es`: `pairingRevokeAllButton`, `pairingRevokeAllTitle`,
  `pairingRevokeAllBody` ({count}), `pairingRevokeAllConfirm`,
  `pairingErrorRevokeAll` (translation-completeness test green).

Tests: 3 widget tests (revokes the stored rows / cancel revokes nothing / no
control when the list is empty) and 4 protocol tests
(`packages/skotiq_remote_protocol/test/auth/revoke_all_devices_test.dart`:
count, per-token eviction announcements, push-row cleanup, and an
already-revoked device neither counted nor re-announced).

## EQP-23 — a death with no record and no safing

Re-scoped by the adjudication to the death path, not the GL frame timeout. At
HEAD the desktop entry point had no shutdown record of any kind and no safing
hook: nothing in `apps/desktop/lib/main.dart` writes anything on the way out,
and the only `safeRigServiceProvider` shutdown caller in the tree is
`main_headless.dart`. So the GUI could end with six devices connected and the
log's last line an unrelated warning.

New `apps/desktop/lib/desktop_last_gasp.dart`:

* `DesktopSessionRecord` + `resolveDesktopSessionRecordFile(dataRoot)` —
  `<data root>/last_session.json`, so it follows `SKOTIQ_DATA_DIR` like the
  logs do.
* `DesktopLastGasp.markRunning()` stamps the record at boot;
  `recordCleanExit()` marks an operator-initiated quit;
  `noteError()` (throttled) keeps the newest framework/engine error against the
  live record, which is what turns a vanished process into a diagnosable one.
* `handleFatal(reason)` writes the record FIRST — evidence has to survive a
  safing call that hangs — then runs the rig-safing hook bounded by a timeout,
  rewrites the record with the outcome, and exits. A safing failure or timeout
  is recorded and never blocks the exit; a second call forces an immediate exit
  so a repeated stop signal is an escape hatch, not a no-op. Same contract as
  `HeadlessShutdown`, which is why it reads like it.
* `install()` wires SIGINT (+ SIGTERM off Windows) to `handleFatal`, and wires
  `FlutterError.onError` / `PlatformDispatcher.onError` to `noteError` ONLY.
  Deliberate: an overflow or a stray async error is not a reason to park a mount
  mid-sequence, but it is the context the next launch needs.

Entry-point wiring in `main.dart`: build the coordinator on the boot paths, log
a CRITICAL when the previous session's record still says `running` (naming its
last recorded error), `markRunning()`, `install()`, and register
`recordCleanExit` with the shell.

Clean-exit seam: `packages/skotiq_app/lib/screens/shell/shell_exit_recorder.dart`
(`ShellExit`, single-slot, synchronous by contract) is called from
`_WindowCloseListener.onWindowClose` immediately before `windowManager.destroy()`.
Without it every normal quit would leave a `running` record and the startup
notice would cry wolf on every launch — the exact class this pass is trying to
remove. One-line barrel export added so the entry point can see it.

Tests: `apps/desktop/test/desktop_last_gasp_test.dart` (7) — record-before-safing
ordering, safing failure recorded and non-blocking, hung safing bounded, repeated
signal forces exit once with safing run exactly once, a vanished session's
`running` record carries its last error, a clean close is not a silent death, a
torn record reads as nothing.

Honest limits: the GTK/engine-level death (the one actually observed) still
cannot be intercepted from Dart — this makes it RECORDED and visible at the next
launch, and makes every death path Dart can see (stop signals) safe the rig.
Live-drive confirmation of the signal path belongs to Wave D.

## Verification

* `apps/desktop`: `flutter test` — 1090 passing.
* `packages/skotiq_remote_protocol`: `flutter test` — 195 passing.
* `packages/skotiq_app`: `flutter test --exclude-tags golden test/screens/settings
  test/screens/shell test/localization` — 593 passing.
* `flutter analyze` clean (no errors/warnings) on every file touched, and on all
  of `packages/skotiq_app/lib`.
* `dart format` applied to the touched files only.
