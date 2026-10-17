# C3 — mechanical file splits — batch `shells-headless`

Scope: `apps/desktop/lib/headless_api/**` (plus the sibling headless shell file
`headless_api_server/http_middleware.dart`, §1.3 of the same map report).
Plan source: `reports/release-pass/map/apps-shells.md` §1.1–1.3.

Strictly behaviour-preserving: code moved verbatim, no logic edits, no public
signature or public symbol changes. Every split was verified line-for-line
against the HEAD copy (whitespace-normalised multiset diff) before running tests.

## Re-measure at HEAD

C1/C2 had already shrunk the subsystem. Only three files were still over the
1000-line Dart threshold:

| lines @ HEAD | file | action |
|---:|---|---|
| 2210 | `headless_api/handlers/sequencer_handlers.dart` | split (§1.1) |
| 1374 | `headless_api/route_metadata.dart` | split (§1.2) |
| 1110 | `headless_api_server/http_middleware.dart` | split (§1.3) |

Everything else under `headless_api/` is now below threshold and was **skipped**:
`db_read_handlers.dart` 932, `validation.dart` 872,
`sequence_management_handlers.dart` 861, `scheduler_handlers.dart` 861,
`device_handlers/camera_handlers.dart` 847, `focus_model_handlers.dart` 843,
`webrtc_live_view_handlers.dart` 836, `mosaic_handlers.dart` 802,
`planetarium_handlers.dart` 800, `calibration_handlers/dark_library_handlers.dart`
783, `science_handlers.dart` 776, `guiding_handlers.dart` 749,
`pairing_handlers.dart` 736, `backup_handlers.dart` 730,
`run_watch_handlers.dart` 706, `system_endpoint_catalog.dart` 705, and the
remaining ~25 handler files (all < 700).

## 1. `sequencer_handlers.dart` — 2210 → 169

Followed the repo's established `headless_api_server.dart` idiom: `part` files
holding one **private extension on `SequencerHandlers`**, with the main file
keeping a thin public forwarder per routed method. A library-private extension
is invisible to `routes/sequencer_routes.dart` (different library), which is why
the 52 routed entry points stay real instance methods on the class.

New `handlers/sequencer/`:

| file | extension | lines |
|---|---|---:|
| `sequencer_lifecycle_handlers.dart` | `_SequencerLifecycle` | 570 |
| `sequencer_start_preflight.dart` | `_SequencerStartPreflight` | 406 |
| `sequencer_config_handlers.dart` | `_SequencerConfig` | 424 |
| `sequencer_checkpoint_handlers.dart` | `_SequencerCheckpoints` | 216 |
| `sequencer_recovery_handlers.dart` | `_SequencerRecovery` | 83 |
| `sequencer_conditions_handlers.dart` | `_SequencerConditions` | 115 |
| `sequencer_secondary_rig_handlers.dart` | `_SequencerSecondaryRig` | 145 |
| `wire_sequence_summary.dart` | (holds `_WireSequenceSummary`) | 242 |

`sequencer_handlers.dart` retains the imports, the eight `part` directives, the
class declaration, `_explicitlyAssignedDeviceIds`, `_logger`/`_logInfo`/
`_logWarning`, the `_lastLoadedWire` field, and 52 forwarders.

Deviations from the map, both deliberate:

- **Step 1 done as a `part`, not a new library.** The map wanted
  `_WireSequenceSummary` renamed to public `WireSequenceSummary` because it
  would cross a library boundary. Making the file a `part` instead keeps the
  name private and needs **zero visibility widening**. It is referenced only
  inside this library (verified: no hits in `apps/` or `packages/` outside the
  defining file).
- **Step 2 was already done before this batch.** The six local payload readers
  (`_readNullableDouble`, `_readOptionalInteger`, `_readNullableBool`,
  `_readStringDoubleMap`, `_readStringBoolMap`, `_readNestedDoubleMap`) no
  longer exist at HEAD; the file already calls `optionalDouble` / `optionalInt` /
  `optionalBool` / `optionalStringDoubleMap` / `optionalStringBoolMap` /
  `optionalNestedDoubleMap` from `validation.dart`. Nothing to do, and the
  500 → 400 status change it describes is a behaviour change this batch would
  not have made anyway.

### Visibility / scope changes recorded

- 52 routed handlers renamed `handleX` → `_handleX` **inside the part files**.
  The public name is unchanged on the class (one-line forwarder each), so the
  external surface, the route tear-offs and every test call site are identical.
- `SequencerHandlers._nativeRunInProgressStates` (a `static const`) became a
  library-private **top-level** `const _nativeRunInProgressStates` in
  `sequencer_start_preflight.dart`. An unqualified reference to a class static
  does not resolve from inside an extension body, and its single reader
  (`_openSessionRowForNativeRun`) moved into that same file. Private before,
  private after; no external reference existed.

## 2. `route_metadata.dart` — 1374 → 11 (pure re-export barrel)

Every importer uses a prefixed `as route_metadata` import, so the barrel keeps
all call sites byte-identical. New `headless_api/route_metadata/`:

| file | lines | contents |
|---|---:|---|
| `body_limits.dart` | 88 | body-size consts, `methodCanHaveBody`, `requestBodyLimitForPath`, `validateContentLength` |
| `route_tables.dart` | 312 | the ten const path tables (**not** re-exported) |
| `path_classification.dart` | 461 | `endpointRateLimitFor`, `highRiskAuditActionFor`, the ten `_is…Path` matchers, `isHighRiskControlPath`, `isPublicEndpoint`, `requiredAuthScopeNameForEndpoint`, `resourceKeyForEndpoint`, `_normalizePath` |
| `rate_limiting.dart` | 376 | rate-limit consts, `EndpointRateLimit`, `RateLimitDecision`, `TokenRouteClass`, `defaultTokenBucketConfigs`, `tokenRouteClassFor`, `tokenRouteClassName`, `TokenBucketConfig`, `TokenBucketRateLimiter`, `_TokenBucketState`, `defaultEndpointRateLimiterMaxEntries`, `EndpointRateLimiter` |
| `openapi.dart` | 162 | `openApiRequestBodyFor`, `buildOpenApiSpec`, `openApiPath`, `openApiTag` |

`route_metadata.dart` is four `export` lines (`route_tables.dart` is
deliberately not exported, per the map). `path_classification.dart` and
`rate_limiting.dart` import each other — legal in Dart, and it is the seam the
map specifies (`endpointRateLimitFor` needs `EndpointRateLimit`;
`EndpointRateLimiter.check` needs `endpointRateLimitFor`).

### Visibility widening recorded

Ten const tables lost their leading underscore so the matchers can import them
across the new library boundary. Not re-exported from the barrel, so the
route-metadata public surface is unchanged:

`_resourcePrefixKeys` → `resourcePrefixKeys`,
`_rateLimitedMethods` → `rateLimitedMethods`,
`_adminOnlyPathPrefixes` → `adminOnlyPathPrefixes`,
`_adminOnlyPaths` → `adminOnlyPaths`,
`_pairingActivePaths` → `pairingActivePaths`,
`_controlPathPrefixes` → `controlPathPrefixes`,
`_rateLimitedReadPaths` → `rateLimitedReadPaths`,
`_rateLimitedPairingPaths` → `rateLimitedPairingPaths`,
`_highRiskControlPaths` → `highRiskControlPaths`,
`_highRiskAuditActions` → `highRiskAuditActions`.
(Prose mentions of those names in surrounding comments were renamed with them.)

Each new library carries a `/// …` doc + `library;` to satisfy
`dangling_library_doc_comments`.

## 3. `http_middleware.dart` — 1110 → 314

Already a `part of '../headless_api_server.dart'`. Split into two sibling parts,
registered in `headless_api_server.dart:44-46`:

- `auth_middleware.dart` (605) — `extension _HeadlessApiServerAuthMiddleware`:
  `_authMiddleware`, `_attachAuthIdentity`, `_authIdentityFrom`,
  `_authRouteClassFrom`, `_extractBearerToken`, `_sessionOwnershipMiddleware`,
  `_grantForToken`, `_scopeForToken`, `_touchPairedDeviceSeen`.
  (The map listed five of these; the other four are interleaved in the same
  contiguous auth block and moved with it rather than being split around.)
- `rate_limit_middleware.dart` (199) — `extension
  _HeadlessApiServerRateLimitMiddleware`: `_rateLimitMiddleware`,
  `_denyRateLimited`, `_highRiskAuditMiddleware`, `_rateLimitClientKey`, plus
  the top-level `_rateLimitTrustProxyHeaders` / `_readTrustProxyFlag`.

`http_middleware.dart` retains request tracking, CORS (`_corsMiddleware`,
`_buildCorsHeaders`, `_resolveAllowedOrigin`), the two body-limit middlewares,
`_readRequestBodyWithinLimit`, the API-version middleware and
`_apiCompatibilityHeaders`.

**Not done (deliberate):** the map's suggestion to hoist the `publicPaths` /
`webSocketPaths` closure-local consts to file level, and the follow-up
`_authorizeWebSocketUpgrade` extraction. Both change what runs, not where it
lives; out of scope for a mechanical split.

## Verification

- `dart analyze apps/desktop/lib` → **No issues found.**
- `dart format` on touched files only; `git diff --stat` confirms no collateral
  reformatting of files this batch did not split.
- Verbatim check: whitespace-normalised multiset diff of each original against
  its replacement set. Only expected deltas appeared — the `part of` / `library;`
  / `extension` / `export` scaffolding, the 52 handler declaration renames plus
  their forwarders, and the ten table renames. No body line changed.
- `flutter test` in `apps/desktop` → **1090 passed**, zero failures, **no test
  file edited** (not even imports).
- `dart run tools/production/headless_api_contract_audit.dart` → 0 registered-not-
  advertised, 0 advertised-not-registered; its generated JSON/MD are byte-identical
  to HEAD.
- `dart run tools/production/headless_route_policy_audit.dart` → passed, 0 issues,
  outputs byte-identical to HEAD.
- `dart run tools/production/bridge_boundary_audit.dart` → 1 violation, pre-existing
  and outside this batch (`packages/skotiq_app/lib/utils/user_facing_error.dart`);
  the sequencer parts inherit the whitelisted import from
  `sequencer_handlers.dart` and add no new importer.
- `dart run tools/production/headless_response_helper_audit.dart` → 0 issues.
