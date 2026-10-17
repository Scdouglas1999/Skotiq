# apps-shells implementation log

Batch key: `apps-shells`. Base: b07d91c9d.

---

## Item 1 — RELIABILITY: timeouts on the updater HTTP path

**Proved first.** Temporary `test/tmp_hang_proof_test.dart` (deleted after) drove
`UpdateService.checkForUpdates()` and `UpdateDownloader.download()` against
`http.BaseClient` fakes that accept the request and never answer. Both futures were
still pending after a 2s deadline:

```
PROOF: checkForUpdates hangs forever on a blackholed server [E]
  threw TimeoutException:<TimeoutException after 0:00:02.000000: Future not completed>
PROOF: download hangs forever on a stalled body [E]
  threw TimeoutException:<TimeoutException after 0:00:02.000000: Future not completed>
```

**Adjudication note on the second half of the item.** The work order also asks to
"release `_activeOperation` in finally". `UpdateController` *already* does this for
all four operations (`check` 648, `download` 794, `apply` 870, `rollback` 1040 — every
one inside a `finally`). The leak was never a missing `finally`; it was that the
`finally` could not run because the awaited future never settled. So the fix is the
timeout alone, and the regression test asserts the consequence the work order cares
about: after a blackholed check, `hasActiveOperation` is false and a second check
still runs instead of throwing `StateError`.

**Changes**
- `update_service.dart`: new `defaultUpdateHttpTimeout` (20s) + injectable
  `httpTimeout`; both metadata fetches now go through one `_get(Uri)` that carries the
  deadline and converts expiry into `UpdateException('… did not respond within …')`.
  Replaces the bare `_httpClient.get` at the old 245 / 319.
- `update_downloader.dart`: new `defaultDownloadStallTimeout` (60s) + injectable
  `stallTimeout`. Applied to `_client.send` (header deadline) and, re-armed per chunk,
  to the body loop (stall deadline — a slow-but-moving transfer is never killed). The
  partial file is deliberately left on disk because the next attempt resumes it via
  the `Range` header.

**Tests** — `packages/skotiq_updater/test/update_http_timeout_test.dart` (new, 4 tests)
- `checkForUpdates fails fast when the update server never responds`
- `a blackholed check releases the controller for the next operation`
- `download aborts when the body stalls mid-transfer`
- `download aborts when the server never sends headers`

**Result** — `flutter test` in `packages/skotiq_updater`: `00:03 +93: All tests passed!`
(one earlier run showed a load failure for `update_manager_widget_test.dart`; it passes
in isolation and on the clean re-run — a concurrent-agent transient, not a regression.)

**Re-verified after the resume** (this session, whole package): `00:05 +93: All tests passed!`
Baseline re-proof, independent of the predecessor's note: a scratch test built the service
with `httpTimeout: Duration(hours: 1)` — the stand-in for the baseline, which had no
`.timeout(...)` on either metadata fetch — against a blackhole client and asserted the
future was still unsettled after 2 s. It was (`BASELINE item 1: an untimed check never
settles` passed). Scratch file deleted.

---

## Item 2 — PERF: full-resolution JPEG encode off the server/UI isolate

**Baseline proved.** A scratch test replayed the pre-fix body (`img.Image.fromBytes` on a
`Uint8List.fromList` copy → `img.encodeJpg`) inline on a 1800×1800 RGBA frame while a 1 ms
`Timer.periodic` counted turns of the event loop:

```
BASELINE encode 237ms, ticks=0
```

Zero ticks: for 237 ms the calling isolate served nothing else. In the desktop GUI that
isolate is the Flutter root isolate, and `/api/run-watch/frame-thumbnail` is documented for
2–5 Hz polling.

**Changes** (`apps/desktop/lib/headless_api/display_buffer_jpeg.dart`)
- `encodeCapturedImageDisplayBufferToJpeg` is now `Future<…>`; resize + encode run under
  `Isolate.run`, with the pixels handed over as `TransferableTypedData`. Only locals are
  captured by the worker closure — capturing `image` would ship the whole
  `CapturedImageResult` back across the port.
- Both `Uint8List.fromList` copies are gone. The input copy is now conditional
  (`displayData` is already a `Uint8List` on the native path; the JSON transport path still
  yields a `List<int>`), and `img.encodeJpg` already returns a `Uint8List`.
- Encodes are serialised through one tail future, so a polling client cannot hold one
  sensor-sized buffer per in-flight isolate.
- The two call sites (`camera_handlers.dart:521`, `run_watch_handlers.dart:554`) now `await`.

**Tests** — `apps/desktop/test/headless_api/display_buffer_jpeg_test.dart` (4 new)
- `the encode does not block the calling isolate` — the mirror of the baseline proof above:
  same frame, same ticker, asserts `ticks > 0` **and** that the encode was slow enough
  (> 50 ms) for the assertion to mean anything.
- `a Uint8List view and an equal List<int> encode identically` — pins that the transfer
  honours a view's offset/length rather than its whole backing `ByteBuffer`.
- `maxWidth downscales and reports both source and encoded sizes`
- `a display buffer of the wrong length is rejected`

**Result** — `apps/desktop`: `00:24 +1083: All tests passed!` (whole suite).

---

## Item 3 — DEDUP+BUG: sequencer payload readers → `validation.dart`

**Baseline proved.** A scratch test ran the pre-fix `_readNullableDouble` body through the
real error-translation helper: `{"mag": "bright"}` came back **500 `internal_error`**
(`BASELINE item 3: a mistyped field lands as 500, not 400` passed). `FormatException` has no
clause in `errorTranslationMiddleware`, so it falls to the terminal `catch (e)`.

**Changes**
- `validation.dart` gains `optionalStringDoubleMap`, `optionalStringBoolMap`,
  `optionalNestedDoubleMap` (the three readers with no shared equivalent; they already threw
  `BadRequestError`, so this is a pure move).
- `sequencer_handlers.dart` deletes all six local readers (−104 lines) and routes every call
  site through `optionalDouble` / `optionalInt` / `optionalBool` / the three new map helpers.
  The shared helpers throw `BadRequestError` → 400, and additionally reject a non-finite
  number by name instead of letting NaN reach the bridge.

**Tests** — `apps/desktop/test/headless_api/sequencer_payload_validation_test.dart` (8 new)
covering `sky-brightness mag`, `weather-verdict unsafeOverride`, two `cloud-motion` fields,
`secondary-rig exposureSecs` / `targetTempC` (all 500 → 400), plus the two nested-map
endpoints asserting the field path survives the move (`perFilterMinSecs.L`,
`carry_over.M31.L`).

**Result** — all 8 pass; `apps/desktop` whole suite green.

---

## Item 4 — DELETE: `SecureDiscovery` + `ChannelEncryption`

**Zero callers re-proved fresh this session**, over `apps/ packages/ native/ tools/ docs/
scripts/` for `SecureDiscovery|SecureDiscoveredServer|ChannelEncryption|encryptJson|
decryptJson|secure_discovery|channel_encryption` and separately for `\bDiscoveryMode\b`
(exit 1 — no hits at all). Every surviving hit is prose in dated audit records under
`docs/audits/` and `docs/plans/`, which are historical documents and out of scope.

**Deleted** `lib/src/discovery/secure_discovery.dart` (620), `lib/src/crypto/
channel_encryption.dart` (205), and `test/channel_encryption_test.dart` (208 — its only
purpose was exercising the deleted class). Both barrel exports removed
(`skotiq_remote_protocol.dart`), package description updated.

**Docs.** `QUICK_START.md` presented `SecureDiscovery` as the recommended API in four places
and was rewritten around what actually ships (`EnhancedSkotiqDiscovery` + QR pairing +
`POST /api/ws/ticket`); every type and route it now names was checked to exist.
`SECURITY.md` and `INTEGRATION.md` lose their `SecureDiscovery` / encryption-helper sections;
`PRODUCTION_READY_VERIFICATION.md` gains a historical-record banner.

**Dependency check:** `crypto` and `pointycastle` both still have live users
(`server_identity.dart`, `token_manager.dart`, `push_jwt.dart`), so no pubspec dep is now dead.

**Result** — `packages/skotiq_remote_protocol`: `00:01 +190: All tests passed!`;
`flutter analyze`: `No issues found!`.

---

## Item 5 — PERF: LRU cap on `EndpointRateLimiter`

**Baseline proved.** A scratch copy of the pre-fix limiter (`putIfAbsent`, no cap) was driven
with one fresh `/api/coimaging/sessions/<id>/contribute` path per request:

```
BASELINE tracked keys: 8293
```

and the seed key was still blocked afterwards — nothing is ever evicted. Its sibling
`TokenBucketRateLimiter` has carried `maxBuckets = 8192` since it was written.

**Changes** (`route_metadata.dart`) — `maxEntries` (default
`defaultEndpointRateLimiterMaxEntries = 8192`, matching the sibling), insertion order used as
LRU order (every touch removes and reinserts), trim past the cap, and a key whose window has
fully expired is dropped outright rather than retained empty.

**Tests** — `apps/desktop/test/headless_api/endpoint_rate_limiter_memory_test.dart` (3 new):
LRU eviction past `maxEntries`, the default cap bounding a night-long run (the exact shape of
the baseline proof, inverted), and a hot key surviving eviction pressure so the limit still
bites. `route_metadata_test.dart` passes unchanged (47 tests).

---

## Item 6 — DEDUP: `NotificationDetails` literals

18 inline literals collapsed to 6 shared `const NotificationDetails` plus one
`_pushDetails({importance, priority, playSound})` factory — desktop push is the one channel
whose presentation follows the payload, so it cannot be a constant. In place, no service
split. 1061 → 922 lines; `grep -c 'AndroidNotificationDetails('` is now 7 (6 consts + the
factory), i.e. no inline literal survives in any `notify*` body.

Two of the six are *not* redundant and are held apart deliberately: `criticalAlarm`
(`AndroidNotificationCategory.alarm`, safety only) and `infoPassive` (`Priority.low` +
`InterruptionLevel.passive`, auto-release only). Eighteen copies of five channels is exactly
how those two became indistinguishable from drift, so they are pinned by test.

**Tests** — `apps/mobile/test/services/notification_details_test.dart` (6 new) against a new
`@visibleForTesting static const detailsByName` map: channel-id closure, per-tier
priority/sound parity, DND interruption for both critical variants, alarm category on the
safety post only, and the passive variant staying quieter than base info.

**Result** — `apps/mobile`: `00:17 +239: All tests passed!`; `flutter analyze lib/services
test/services`: `No issues found!`.

---

## Item 7 — SKIPPED (endpoint catalog)

Adjudication allows deriving the runtime list from the `HeadlessRoute` table **only if** the
CI check still compares against an independently-committed snapshot, and to skip otherwise.
Skipping, for three reasons that are all structural:

1. **The snapshot is read as source text, not as data.** Both
   `tools/production/headless_api_contract_audit.dart:538` and
   `apps/desktop/test/headless_api/network_backend_contract_test.dart:254` recover the catalog
   by regexing `List<String> availableHeadlessEndpoints() { return const [ … ]; }` out of the
   file. Preserving the snapshot therefore means preserving that literal exactly as it is.
2. **The runtime has no route table to derive from at the point of use.** `allRoutes` is built
   inside `_startServer` (`headless_api_server/server_lifecycle.dart:18+`) from ~50 private
   handler fields on the live `HeadlessApiServer`. `SystemHandlers` — which serves
   `GET /api/info`, the self-test endpoint count and the OpenAPI route list — is constructed
   before the server starts and holds no reference to it. Threading it in means a late-bound
   setter on `SystemHandlers` or hoisting handler construction out of the server: a bootstrap
   restructure, which this wave forbids.
3. **It would change the wire.** `GET /api/info`'s `endpoints` array is hand-ordered; a
   derivation would emit registration order instead.

Left intact and verified still honest: `dart run tools/production/headless_api_contract_audit.dart`
→ `Registered routes: 598 / Advertised routes: 598 / Registered not advertised: 0 /
Advertised not registered: 0`, and it regenerated
`docs/production-readiness/headless-api-contract-audit.{json,md}` byte-identically (clean
`git status`).

---

## Wave close-out

- No `*.tmp.*` files anywhere in scope; both scratch proof files deleted after recording.
- `dart format` run on the 15 touched files (2 needed reformatting).
- `flutter analyze`: desktop `lib/headless_api` + `test/headless_api`, mobile `lib/services` +
  `test/services`, `skotiq_remote_protocol`, `skotiq_updater` — all
  `No issues found!`.
- Suites: `apps/desktop` `+1083`, `apps/mobile` `+239`,
  `packages/skotiq_updater` `+93`, `packages/skotiq_remote_protocol` `+190`.
  All green.
- `packages/skotiq_plugins` untouched: the work order's dead-code entries there (§3.3,
  §3.4) are flagged as product decisions and are not in this batch's item list.
