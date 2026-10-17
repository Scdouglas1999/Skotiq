# w10-precise-location — Wi-Fi positioning with an honest accuracy radius

Workstream: `w10-precise-location`. Branch `agent/w10-precise-location`, base
`94f13cd6d` (verified `git rev-parse --short HEAD` = `94f13cd6d` at start,
clean tree). TMPDIR `$HOME/.cache/ns-tmp/w10-precise-location`.

## The requirement

"I want the internet based approach to be able to get your location to your
exact location … to clearly be in your yard, not a town over."

IP geolocation cannot do that by construction — it resolves the internet
provider's hand-off. Wi-Fi positioning can: the BSSIDs of the radios within
earshot, with how loud each one is, trilaterate to tens of metres wherever a
positioning service has mapped them.

## What was built

### `packages/skotiq_planetarium/lib/src/services/positioning/` (new)

- **`positioning_result.dart`** — `PositioningSource`
  (`platformService | wifiScan | ipAddress`), `PositioningTier`, `TierOutcome`
  (per-tier, operator-readable, kept whether or not the tier answered),
  `PositioningResult` (lat, lon, `accuracyMetres`, `source`, `provider`,
  `accessPointsUsed`, `locationName`, `explanation`, `isPrecise`,
  `accuracyRank`) and `PositioningAttempt` (best `fix`, all `outcomes`,
  `wifiRadioOff`, `wifiRadioCanBeEnabled`, `canRetryWithWifi`,
  `failureDetail`).
  `PositioningResult.preciseMetres = 150` is the stop threshold.
- **`wifi_scan.dart`** — `WifiAccessPoint`, the sealed `WifiScanOutcome`
  (`WifiScanOk | WifiScanNoAdapter | WifiScanRadioOff | WifiScanNoNetworks |
  WifiScanUnsupportedPlatform`), `CommandResult` / `ProcessRunner`, and
  `WifiScanner` with a platform switch, an injectable process runner and an
  injectable `operatingSystem`. Linux via `nmcli` (with an `iw dev … scan
  dump` fallback), Windows via `netsh wlan show networks mode=bssid`, macOS
  honestly unsupported. Radio power: `radioIsOff()` / `enableRadio()` /
  `disableRadio()` / `canToggleRadio`, Linux only.
- **`wifi_positioning.dart`** — `WifiPositioningProvider`: the shared
  Google/Ichnaea geolocate request, `beaconDbEndpoint`, `googleEndpoint(key)`,
  `strongest()` (cap 20, strongest first), `buildRequestBody`
  (`considerIp: false`), `parseGeolocateBody` (rejects any body with a
  `fallback` key), `locate()`.

### `geolocation_service.dart`

`fetchLocationFromGPS` / `GeolocationFix` / `GeolocationSource` are gone,
replaced by

```dart
static Future<PositioningAttempt> locate({
  required bool allowWifiScan,
  required bool allowIp,
  bool mayEnableWifiRadio = false,
  String? googleApiKey,
})
```

plus `scannerFactory` (injectable, beside the existing `clientFactory`) and
the private `_platformServiceFix()` / `_wifiFix()`. The IP legs, the tuple
APIs (`fetchLocation`, `fetchLocationFromIP…`) and `searchPlaces` are
unchanged except that `_fetchIp` now returns a `PositioningResult`. The file
re-exports the three positioning files, so the package barrel carries them.

### Tier design as built

| # | Tier | What it sends | Radius it reports |
|---|------|---------------|-------------------|
| 1 | `platformService` — `geolocator` (Windows Location Services / GeoClue / CoreLocation) | nothing leaves the app | platform metres; `0.0` is read as "none" |
| 2 | `wifiScan` — Google first *when a key is set*, then beaconDB | ≤ 20 strongest BSSIDs + dBm + channel | service metres (20–100 m typical) |
| 3 | `ipAddress` — ipinfo.io → ipwho.is | public IP | none (neither service reports one) |

Arbitration:

- Tiers run in order and stop at the first fix with
  `accuracyMetres <= 150`. A coarse fix never stops the search.
- The **smallest radius wins**, whatever order the tiers ran in
  (`accuracyRank`, with a null accuracy ranking below every reported one), so
  a 25 km platform answer can never beat a 40 m Wi-Fi one.
- A refused tier is never built and never reaches the network
  (`allowWifiScan: false` does not even construct a scanner).
- Every tier contributes a `TierOutcome` whether it answered or not, so a
  total failure names its causes instead of shrugging.

Three details that decide whether the feature is honest rather than merely
present:

1. **`considerIp: false` on every geolocate request.** Left at its default,
   beaconDB answers an unmappable network list with HTTP 200,
   `accuracy: 25000` and `fallback: "ipf"` — a 25 km IP guess dressed as a
   Wi-Fi fix. Verified live (below). With the flag false it answers
   `404 notFound`. `parseGeolocateBody` *also* rejects any body carrying a
   `fallback` key, so a future flag change cannot resurrect the lie.
2. **A platform accuracy of `0.0` is read as "none".** `geolocator` reports
   0.0 when the platform measured nothing; taken literally it is the smallest
   radius there is and would both win arbitration and end the search at
   tier 1.
3. **The `_nomap` opt-out is honoured in the parser**, so an SSID that has
   asked not to be used for geolocation never enters the request at all.

### `packages/skotiq_app/lib/widgets/geolocation_consent.dart`

- `GeolocationConsent` (per-tier) + `geolocationConsentProvider`
  (session-scoped, never persisted) + `ensureGeolocationConsent(...)`: one
  dialog, one consent, remembered for the session, and a **narrower** grant
  never satisfies a **wider** request — consenting to the IP-estimate offer
  does not authorise a Wi-Fi scan.
- `geolocationConsentBody(...)` is a pure function: one bullet per tier that
  will actually run, naming what it sends and to whom. A tier that is switched
  off has no disclosure on screen.
- `googleGeolocationKeyProvider` (`AsyncNotifier<String>` over
  `settingsDaoProvider`, key `location_google_geolocation_key`).
- The dialog keeps W9's 480 px `AdaptiveDialogConstraints` + `Align` +
  `heightFactor: 1` treatment verbatim, now wrapped in a
  `SingleChildScrollView` because the body grew from two paragraphs to four.

### Settings → Location

- `DeviceLocationFetcher` → `SiteLocator` (matches `locate`'s signature);
  `deviceLocationFetcherProvider` → `siteLocatorProvider`.
- Detect row subtitle now leads with the tier that works.
- A conditional **"Turn Wi-Fi on for a precise fix"** row appears only after a
  detect that was actually blocked by a switched-off radio, with a `Scan`
  button that calls `locate(mayEnableWifiRadio: true)`.
- A new **Advanced** section with the optional Google Geolocation API key
  field (obscured, autocorrect off, committed on Enter *and* on blur —
  paste-then-click-away is how a key normally gets entered).
- W9's site-radius elevation rule and imaging-host-changed guard kept
  verbatim.

### Onboarding → site step

Same `SiteLocator` swap, same consent entry point, the same radio-off offer as
a `SkotiqBanner` with a `Scan` action. The Estimate-from-IP offer now
passes `includeWifiScan: false`.

## Real check on this machine (brief item 6)

Radio was `disabled` at the start, as the brief said. Sequence run once:
`nmcli radio wifi on` → scan → one beaconDB call → `nmcli radio wifi off`.
The owner's state was restored (`nmcli radio wifi` → `disabled`,
`wlan0:unavailable`); nothing was written to the repo but the rounded figures
below.

- **Access points heard: 12** (`nmcli -t -f BSSID,SIGNAL,CHAN,FREQ,SSID dev
  wifi list --rescan yes`), all 12 sent.
- **beaconDB with `considerIp: false`: HTTP 404 `notFound` in 0.35 s.**
  *beaconDB has no coverage at this site.*
- **beaconDB with `considerIp` at its default: HTTP 200, `accuracy: 25000`,
  `fallback: "ipf"`, lat 39.95 / lng −75.17** — i.e. a 25 km IP estimate
  landing on the Philadelphia centroid, which is exactly the "a town over"
  the owner objected to. An identical response comes back for an *empty*
  access-point list, which is how the `fallback` key was confirmed to be the
  only thing distinguishing them.
- **So: the accuracy radius for a Wi-Fi fix here is not available — beaconDB
  cannot place this yard at all.** The Google tier is what covers this case,
  and the Advanced key field exists for it. The UI says so rather than
  presenting the 25 km guess as a fix.

Two measurements taken while the radio was up, both now encoded in the code:

- **nmcli's SIGNAL is NetworkManager quality, not dBm.** Calibrated against
  `iw dev wlan0 scan dump` on the same 12-network scan: the exact inverse of
  NM's mapping is `dBm = round(quality × 0.6) − 100`. Checks: 40→−76 (iw −76),
  59→−65 (−65), 70→−58 (−58), 87→−48 (−48), 44→−74 (−75). NM clamps at −40, so
  the three radios at quality 100 (really −13/−19 dBm) all report −40.
  Sending the raw percentage as dBm would have put every AP 50–60 dB off.
- **The adapter needs a retry loop after `nmcli radio wifi on`.** `wlan0`
  reports `unavailable` for the first two `--rescan yes` calls and answers on
  the third. `WifiScanner._linuxScanAttempts = 5`, a retry count rather than a
  sleep, because each nmcli call blocks on NetworkManager's own scan.

`iw dev wlan0 scan dump` was also found to work **unprivileged** (it reads the
kernel's cached results), and reports true dBm.

## Final copy shipped

**Settings row** — title `Detect location`, subtitle `Nearby Wi-Fi networks
place you to within about 100 m. Falls back to this machine’s GPS or your
internet address.`

**Radio-off row** — title `Turn Wi-Fi on for a precise fix`, subtitle `Wi-Fi
is switched off, so the precise scan was skipped. Skotiq will switch it
on, scan for nearby networks, and switch it back off.`, action `Scan`.

**Advanced row** — title `Google Geolocation API key`, subtitle `Optional.
beaconDB, the key-free service Detect location uses, is mapped by volunteers
and has no coverage in plenty of places; with a key from Google Cloud’s
Geolocation API the same list of nearby networks goes to a far larger map
first. The key is stored on this machine and sent only to Google.` (link-free,
as the brief asked.)

**Consent dialog** — title `Detect this site’s location?`, body:

> Skotiq will try these in order and stop as soon as one of them places
> you precisely:
>
> • This device’s own location service, if it has one. Nothing leaves the
> machine.
>
> • The names and signal strengths of nearby Wi-Fi networks, sent to beaconDB
> (an open positioning service). This is the step that finds your yard rather
> than your town. The networks are used for this one request and never saved.
>
> • Your public IP address, sent to ipinfo.io over HTTPS (falling back to
> ipwho.is). That only locates your internet provider — city level, tens of
> kilometres.
>
> \<outcome paragraph\>

With a Google key set, the second bullet reads `… sent to Google (your
Geolocation API key), and to beaconDB (an open positioning service) if Google
cannot place them. …`.

**`PositioningResult.explanation`** (one per source):

- Wi-Fi: `Located to within 40 m using 9 nearby Wi-Fi networks (beaconDB).`
- Platform: `Located to within 12 m by Windows Location Services.` /
  `Located by Windows Location Services, which reported no accuracy.`
- IP with a radius: `Approximate only: from your internet address (beaconDB),
  about 25 km.`
- IP without one (both real providers): `Approximate only: from your internet
  address (ipinfo.io). City level — typically tens of kilometres.`

**Settings confirmation** — `Coordinates set to <where>. <explanation>
<Elevation kept at N m. | Elevation cleared to 0 m — enter the elevation for
this site.> <Turn Wi-Fi on for a precise fix. | Refine on the map if it is
off.>` The Wi-Fi nudge wins whenever the radio is off and switchable, because
pointing someone at the map when a precise fix is one click away is the worse
advice.

**Wizard confirmation** — same first two clauses; the trailing nudge is
`Turn Wi-Fi on for a precise fix.` or `Correct the coordinates below if it is
off.` (the wizard has no map or place search), and nothing at all for a
precise fix.

**No-fix message** — Settings: `No position from Wi-Fi, this machine, or the
internet lookup. <every tier's reason> Search for a place by name, or enter
coordinates.` Wizard: same first two clauses, then `Enter your coordinates
below, or skip and set the site later in Settings → Location.`

## Deviations from the brief, and why

- **`locate()` returns `PositioningAttempt`, not `PositioningResult?`.** The
  brief asks for "null with the outcomes" on total failure; a nullable result
  cannot carry outcomes. `PositioningAttempt.fix` is the nullable result and
  the outcomes ride beside it. The radio-off offer needs the same channel: the
  UI cannot know Wi-Fi was skipped from a null.
- **A fifth `WifiScanOutcome` case, `WifiScanUnsupportedPlatform`.** The brief
  lists four and says to stub macOS honestly; "honestly" needs a case of its
  own, otherwise macOS reports `noAdapter`, which is false.
- **The Linux fallback is `iw dev <if> scan dump`, not `iw dev <if> scan`.**
  The brief names the latter and notes it needs privileges we must not take.
  `scan dump` reads the kernel's cached results unprivileged and returns true
  dBm. It is the fallback rather than the primary because the cache is only as
  fresh as whatever last triggered a scan.
- **Windows never offers the radio-power flow.** There is no supported
  command-line equivalent of `nmcli radio wifi on` (the radio-management API
  needs a packaged app identity), so `canToggleRadio` is Linux-only and the
  offer is gated on it rather than shipping a button that does nothing.
- **`geolocationConsentProvider` and `googleGeolocationKeyProvider` live in
  `widgets/geolocation_consent.dart`.** Both surfaces need them and that file
  is the only one both already import; a new sibling under `lib/widgets/` was
  not in the brief's file list, and importing the Settings page from the
  wizard would drag the whole settings tree into the wizard's import graph.
- **Per-tier consent instead of one flag.** "One dialog, one consent,
  remembered for the session" has a hole: the wizard's Estimate-from-IP offer
  sends only the public IP, and a remembered "yes" from it would have skipped
  the Wi-Fi disclosure on the next click. `GeolocationConsent.covers()` closes
  it — a wider grant covers a narrower request, never the reverse.
- **`settings_search_index.g.dart` regenerated** (`dart run
  tools/production/settings_search_index_gen.dart`, 722 → 727 terms). Outside
  the brief's file list, but it is a generated artifact of the row text I
  changed and a `--check` CI gate fails if it is stale. Same precedent as W9.
- **`_nomap` filtering and a −90 dBm floor** are not in the brief. The first
  is the opt-out convention every positioning service honours and is cheapest
  to honour before the request is built; the second keeps a beacon from three
  streets over out of a weighted trilateration.
- **`PositioningResult.explanation` carries no refinement nudge.** The brief's
  examples include one, but the two surfaces have different affordances (the
  wizard has no map). The service states the fact; each surface appends its
  own single nudge, and the tests pin both.
- **`docs/api/planetarium-api.md` left stale**, as W9 left it: it already
  documents a method that does not exist and is outside the file list.

## Commands run + exit codes

Real-machine experiment (item 6; the only permitted state change):

- `nmcli radio wifi` → `disabled`. EXIT=0
- `nmcli radio wifi on` → EXIT=0
- `nmcli -t -f BSSID,SIGNAL,CHAN,FREQ,SSID dev wifi list --rescan yes` →
  12 rows. EXIT=0
- `iw dev wlan0 scan dump` (unprivileged, for the dBm calibration) → 13 BSS
  blocks. EXIT=0
- one `POST https://api.beacondb.net/v1/geolocate` per variant (3 total) →
  404 / 200 / 200 as recorded above. EXIT=0
- `nmcli radio wifi off` → EXIT=0; `nmcli radio wifi` → `disabled`,
  `wlan0:unavailable`. Owner's state restored.

Verification:

- `dart format --output=none --set-exit-if-changed packages/skotiq_app
  packages/skotiq_core packages/skotiq_ui` → EXIT=1, 41 files changed
  — ALL pre-existing drift in files I did not touch (`ip_geolocation.dart`,
  `skotiq_tooltip.dart`, …); identical count and membership to W9's
  report. Zero of my touched files appear. Scoped to my files: 0 changed.
- `cd packages/skotiq_planetarium && dart analyze` → 9 issues, EXIT=0.
  All pre-existing `deprecated_member_use` infos in `test/time_*`; zero in
  `services/` or the positioning files (`dart analyze lib/src/services` →
  "No issues found!", EXIT=0).
- `cd packages/skotiq_app && dart analyze` → 891 issues, EXIT=2. Identical
  count to W9's report on the same base; `grep -icE
  'geolocation|location_settings|site_step'` over the output = **0**.
- `cd packages/skotiq_planetarium && flutter test
  test/geolocation_transport_test.dart --concurrency=3` → +18, EXIT=0.
- `cd packages/skotiq_planetarium && flutter test
  test/wifi_scan_parsing_test.dart --concurrency=3` → +16, EXIT=0.
- `cd packages/skotiq_planetarium && flutter test --concurrency=3` →
  +612 −1, EXIT=1. Sole failure `test/benchmark/golden_compare_test.dart`
  "benchmark golden checkpoints (compare)" — the pixel-diff benchmark W9
  already verified PRE-EXISTING on base; renderer/environment, unrelated.
- `cd packages/skotiq_app && flutter test test/screens/settings
  test/screens/onboarding test/widgets --concurrency=3` → +1067 −14, EXIT=1.
  All 14 failures are PRE-EXISTING and in files I did not touch:
  `backup_restore_notice_test` ×2, `pairing_observatory_kit_test` ×1,
  `settings_search_query_test` ×1 (the four W9 already documented on this
  base — the search-index one fails on `'GLADE+ Galaxy Catalog'`, a catalogs
  heading, and is unrelated to the `Advanced` section I added; the
  regenerated index is current), plus `go_to_position_dialog_test` ×10, which
  drives `screens/imaging/widgets/focus_panel.dart` — a file outside my diff
  entirely. Every test in the five files I touched passes; focused reruns:
  `location_settings_truth_test` +20, `site_step_detect_truth_test` +9,
  `geolocation_consent_copy_test` +8, `geolocation_consent_width_test` +1,
  `onboarding_steps_test` +19, all EXIT=0.

## Tests added

- `packages/skotiq_planetarium/test/wifi_scan_parsing_test.dart` (new,
  16 tests) — verbatim `nmcli -t`, `netsh … mode=bssid` and `iw scan dump`
  fixtures: escaped-colon BSSIDs, the quality→dBm conversions (calibrated
  against the live scan), channels, hidden SSIDs, an SSID containing an
  escaped colon, `_nomap` exclusion, the `Interface name :` header not being
  read as a BSSID, the −90 dBm floor, and the 20-strongest cap.
- `packages/skotiq_planetarium/test/geolocation_transport_test.dart`
  (rewritten tail, 12 new tier tests) — Wi-Fi beats a coarse platform fix; a
  precise platform fix makes no request at all; `fallback: ipf` never counts;
  `considerIp: false` is on the wire; Google first then beaconDB; a
  switched-off radio is reported and NOT switched on unasked; the explicit
  retry switches on, scans and switches back off; a *failed* scan still
  restores the radio; every tier failing names every reason; a refused tier
  never reaches the network; a 0 m platform accuracy neither wins nor stops
  the search; an IP fix states the mechanism instead of inventing a radius.
- `packages/skotiq_app/test/widgets/geolocation_consent_copy_test.dart`
  (new, 8 tests) — the disclosure per allowed tier, the Google variant, a
  switched-off tier having no disclosure, and the consent-coverage rule.
- `location_settings_truth_test.dart` — consent asked once then remembered;
  the Wi-Fi/IP/platform confirmation strings; the radio-off row appearing only
  after it applies and retrying with the flag set; a total failure naming each
  tier; the Advanced key field's copy and that the key reaches the lookup.
- `site_step_detect_truth_test.dart` — the dialog naming both outbound tiers;
  the IP-estimate offer not asking for (or inheriting) Wi-Fi consent; the
  Wi-Fi confirmation; the radio-off banner and its retry.

## Left undone / notes

- **beaconDB cannot place the owner's site.** Nothing in this workstream can
  fix that; the Google tier is the answer and needs a key the owner has to
  create. The alternative — contributing scans back to beaconDB via its
  `/v2/geosubmit` endpoint so the area gets mapped — is out of scope here and
  would need its own consent.
- The Windows and macOS scanner branches are not exercised on hardware; the
  `netsh` parser is pinned against a verbatim Windows 11 fixture, and the
  radio-power flow is Linux-only by design.
- The pre-existing failures listed above (41 format-drift files, 891 app
  analyzer infos/warnings, 1 planetarium benchmark golden) are unchanged from
  base.
