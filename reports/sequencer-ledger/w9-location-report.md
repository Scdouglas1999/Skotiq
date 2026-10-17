# w9-location — one-click internet location detection

Workstream: `w9-location`. Branch `agent/w9-location`, base `1d8e6957f`
(verified `git rev-parse --short HEAD` = `1d8e6957f` at start, clean tree).

## Goal

"Detect location" must work on a desktop with no GPS receiver: device
GPS/GeoClue when present, the HTTPS IP lookup (ipinfo.io → ipwho.is)
automatically in the same click otherwise. The fix reports which path
answered and how precise it claims to be, and the confirmation says so.

## What changed

### `packages/skotiq_planetarium/lib/src/services/geolocation_service.dart`

- New `GeolocationSource { device, internet }` and `GeolocationFix`
  (`latitude`, `longitude`, `locationName`, `source`, `providerHost`,
  `accuracyMeters`) with `describeSource()` — the shared wording both
  surfaces append to their confirmation, so they cannot disagree:
  - device → `this machine’s GPS fix, ±N m` (metres dropped when the
    platform reports none or 0.0, which claims a perfect fix)
  - internet → `approximate: from your internet connection (<host>)`
- `_fetchIp(Uri)` now returns `GeolocationFix?` tagged
  `source: internet, providerHost: uri.host`; the public
  `fetchLocationFromIP` / `fetchLocationFromIPAlternative` / `fetchLocation`
  keep their tuple signatures via `_tupleOf`, so the estimate-offer flow and
  existing transport tests are untouched.
- `fetchLocationFromGPS({bool fallbackToIp = true})` now returns
  `Future<GeolocationFix?>`. Device success → `source: device` +
  `position.accuracy` metres. Every prior "null" exit (services off,
  permission denied/forever, any device-path exception) now routes to the
  internet lookup when `fallbackToIp` — unchanged mechanics, richer result.
- `getBestLocation()` returns `GeolocationFix?` (no other callers exist).
- Docs on `fetchLocationFromGPS` rewritten — they still claimed Settings and
  the wizard passed `false`.

### `packages/skotiq_app/lib/screens/settings/widgets/location_settings.dart`

- `DeviceLocationFetcher` typedef → `Future<GeolocationFix?> Function()`;
  `deviceLocationFetcherProvider` calls
  `fetchLocationFromGPS(fallbackToIp: true)`.
- `confirmGeolocationLookup(..., includeIpFallback: true)` — the shared
  dialog's existing true-branch copy already discloses the public-IP request
  to ipinfo.io/ipwho.is over HTTPS.
- SettingRow subtitle → `Uses this machine’s GPS if it has one, otherwise
  your internet connection.` (the "search for a place by name instead"
  sentence removed).
- `_detectLocation`: same site-radius elevation rule and imaging-host-changed
  guard kept verbatim; confirmation now reads
  `Coordinates set to <where> — <describeSource()>. Elevation kept/cleared…`
  and, only for an internet fix, ends with
  `Refine with Search place or the map if it is off.` (verbatim from brief).
- Null result message → `No fix from this machine or the internet lookup.
  Search for a place by name, or enter coordinates.` (both paths failed —
  the old "No GPS fix" wording was wrong for a machine with no receiver).

### `packages/skotiq_app/lib/screens/onboarding/steps/site_step.dart`

- New `DeviceLocationLookup` typedef (`Future<GeolocationFix?>`);
  `onboardingDeviceLocationProvider` calls
  `fetchLocationFromGPS(fallbackToIp: true)`. The passive
  `onboardingApproximateLocationProvider` (Estimate-from-IP offer) keeps
  `fetchLocation` and its tuple type — that flow is a suggestion card, not
  a write, and its copy already names the mechanism.
- `confirmGeolocationLookup(..., includeIpFallback: true)` — one shared
  dialog for both surfaces.
- Confirmation names the path the same way (`Coordinates set to <where> —
  <describeSource()>.`), elevation rule unchanged. Null message now says both
  paths failed and points at manual entry / skipping.
- Class doc bullet clarified: the explicit Detect path is consented and
  provenance-labelled, distinct from the passive IP-estimate offer.

### `packages/skotiq_app/lib/widgets/geolocation_consent.dart`

Unchanged. The `includeIpFallback` parameter stays (brief names it): both
surfaces pass `true`; the `false` copy branch remains for a hypothetical
device-only consent.

### `packages/skotiq_app/lib/screens/settings/settings_search_index.g.dart`

Regenerated via `dart run tools/production/settings_search_index_gen.dart`
(it embeds row text; the old subtitle was indexed). One-term diff:
`'Device GPS if this machine has it. Desktops'` → `'Uses this machine’s GPS
if it has one,'`. Outside the brief's file list, but it is a generated
artifact of `location_settings.dart` and a `--check` CI gate fails if stale.

## Design decisions vs the spec

- **Provenance rides on the result, not a side channel.** The brief says
  "the service returns which path produced the result (device / internet,
  with the provider host)". A `GeolocationFix` return type makes that
  impossible to drop; a `source` enum + `describeSource()` keeps both
  surfaces' wording identical (same argument as the shared consent dialog).
- **`fetchLocation` keeps its tuple type.** Only the Detect path needs
  provenance; the estimate-offer banner already discloses "from your IP
  address". Widening it would churn the suggestion flow for no user-visible
  gain.
- **`accuracyMeters` hides 0.0.** geolocator_platform_interface 4.2.6 has no
  `hasAccuracy` on `Position`; 0.0 is the "unavailable" placeholder, and
  printing "±0 m" would claim a surveyed fix — `describeSource` omits it.
- **`docs/api/planetarium-api.md` left stale on purpose.** It already
  documents a nonexistent `fetchLocationFromInternet()` and predates the
  `fallbackToIp` param — a one-line edit would still leave it wrong, and it
  is outside the file list.
- **Elevation rule + host-switch guard kept byte-for-byte** in both
  surfaces, per deliverable 3.

## Commands run + exit codes

(unpiped where noted; `>` redirects shown as run)

- `git rev-parse --short HEAD` → `1d8e6957f`, clean tree. EXIT=0
- `dart run tools/production/settings_search_index_gen.dart` → wrote index
  (722 terms). EXIT=0
- `cd packages/skotiq_planetarium && dart analyze` → 9 issues, all
  pre-existing `deprecated_member_use` infos in `test/time_*` files, zero in
  geolocation files. EXIT=0
- `cd packages/skotiq_app && dart analyze` → 891 issues, ALL
  pre-existing base lint debt (8 unused-import warnings + 883 info in files
  I did not touch; `grep geolocation|location_settings|site_step` = 0 hits).
  EXIT=2 (warnings). Base state verified: the same files produce the same
  findings with my touched files checked out at `1d8e6957f`.
- `dart format --output=none --set-exit-if-changed` on the three verification
  packages (+planetarium) → 41 files changed, ALL pre-existing drift in
  files I did not touch (`ip_geolocation.dart`, `skotiq_tooltip.dart`,
  …). Scoped to my 9 touched files: `Formatted 9 files (0 changed)`.
  EXIT=0.
- `cd packages/skotiq_planetarium && flutter test
  test/geolocation_transport_test.dart --concurrency=4` → +10 all passed.
  EXIT=0
- `cd packages/skotiq_planetarium && flutter test --concurrency=4` →
  +588 −1. EXIT=1. Sole failure: `test/benchmark/golden_compare_test.dart`
  "benchmark golden checkpoints (compare)" — pixel-diff benchmark
  (maxDelta=218, 4.43% changed vs 0.20% limit). Verified PRE-EXISTING on
  base `1d8e6957f` with identical deltas — renderer/environment, unrelated.
- `cd packages/skotiq_app && flutter test test/screens/settings
  test/screens/onboarding --concurrency=4` → +758 −4. EXIT=1. Failing:
  `backup_restore_notice_test` ×2, `pairing_observatory_kit_test` ×1,
  `settings_search_query_test` ×1 — all confirmed PRE-EXISTING on base by
  checking out my touched files at `1d8e6957f` into `/tmp/w9-mine` and
  rerunning those four files (same 4 failures, plus all site-step tests
  passing on base). My files were then restored from the temp copy.
- Focused rerun of every touched test file
  (`location_settings_truth_test`, `site_step_detect_truth_test`,
  `onboarding_steps_test`, `onboarding_notice_footer_test`) → +73 all
  passed. EXIT=0

## Final copy shipped

- Settings row: title `Detect location`, subtitle `Uses this machine’s GPS
  if it has one, otherwise your internet connection.`
- Consent dialog (both surfaces, `includeIpFallback: true`): asks for a GPS
  fix, states the HTTPS request to ipinfo.io/ipwho.is and that it estimates
  from the public IP to ~10 km, plus the outcome paragraph.
- Settings confirmation — internet: `Coordinates set to <where> —
  approximate: from your internet connection (<host>). Elevation
  kept|cleared… Refine with Search place or the map if it is off.`
- Settings confirmation — device: `… — this machine’s GPS fix, ±N m.
  Elevation kept|cleared…`
- Wizard confirmation — same provenance clause, no refine nudge (the wizard
  has no search/map affordance).
- Null result (both surfaces): names that both the machine and the internet
  lookup failed.

## Left undone / notes

- `Geolocator.getCurrentPosition` accuracy is the platform's horizontal
  estimate; on Linux GeoClue the value is whatever the agent reports.
- `includeIpFallback: false` dialog copy is now unexercised by app code (kept
  as part of the shared dialog's API, per the brief's naming of the flag).
- Pre-existing failures listed above are not mine; 4 in
  settings/onboarding, 1 in planetarium benchmark goldens.
