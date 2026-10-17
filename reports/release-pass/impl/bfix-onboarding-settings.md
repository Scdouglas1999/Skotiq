# B-fix batch: onboarding-settings

Items: SET-17 (P1), SET-1, SET-3, SET-6, SET-8/9, SET-12, SET-18, SET-23, SET-28 (P2), SET-2/5/11 (P3).

## Log

### SET-17 (P1) — pairing store outside the data dir
HEAD already resolves `pairing.db` under `SKOTIQ_DATABASE_DIR`
(`resolvePairingDatabaseFile`), so the *location* half was fixed before this
wave. The observed symptom — a `--fresh` profile listing 13 devices with
`control`/`admin` scope, matching `~/Documents/Skotiq/pairing.db` — was
`migrateLegacyPairingStore` copying the machine-wide store into every new data
directory unconditionally. Made that carry-forward opt-in
(`SKOTIQ_IMPORT_LEGACY_PAIRINGS`), so wiping the data dir now really does
revoke. Failing test first in
`packages/skotiq_remote_protocol/test/database/pairing_database_location_test.dart`.

### SET-3 — one guider status line (guider_step.dart `_statusLine`)
### SET-9 — the IP offer derives from the live fields; lookups round to 4 dp
### SET-8 — `heightFactor: 1` on the consent dialog's Align
### SET-5 — telescope badge reads "<model> — edited" once optics diverge
### SET-2 — a re-added slot recovers the wheel's name, else opens blank
### SET-11 — camera preset names the pixel size it replaced; step-8 hint fixed
### SET-1 — backend chips carry a reason on screen and in semantics
### SET-23 — read-only profile values lose the input chrome, gain readOnly semantics
### SET-18 — pairing card shows phrase + countdown + Stop pairing mode
### SET-28 — precedence disclosed; the three unread legacy switches disabled with the reason
### SET-12 — tour passes over steps whose target panel is not on screen

### SET-6 — covered-by-component
`SkotiqSwitchRow`/`SkotiqSwitch` live in skotiq_ui and are being
edited by the A11Y-STATE batch this wave (`git status` shows both modified).

### Pre-existing, not mine
- `test/screens/{onboarding,settings}/captures_landscape_test.dart` — `@Tags(['golden'])`,
  host-specific baselines, excluded from `melos run test`; fail on Linux by policy.
- `test/screens/settings/general_language_scope_test.dart` — a `Semantics` wrapper
  now sits where the test casts to `Text`; `skotiq_dropdown.dart` is modified
  by the A11Y-STATE batch.

## Final state
`flutter test --exclude-tags golden test/screens/{settings,onboarding,tutorial} test/widgets`
in `packages/skotiq_app`: 1 failure, out of scope
(`general_language_scope_test` — the A11Y-STATE batch wrapped the dropdown item
in `Semantics`, and the test casts `item.child as Text`).
`flutter test` in `packages/skotiq_remote_protocol`: 191 passing.
`flutter analyze` clean on every file touched.

Two existing tests needed a scroll, not a weaker assertion: the Notifications
leaf and the Remote Access card both grew, pushing a button below a fixed test
viewport — `tester.ensureVisible` before the tap in
`notification_push_authority_test.dart` and `remote_access_tailscale_test.dart`.
