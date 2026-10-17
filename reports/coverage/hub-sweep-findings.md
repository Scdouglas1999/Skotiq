# Hub sweep findings — 2026-08-14

API-driven per-unit exercise of the 28 `hub:` units under `server/skotiq_hub/lib`,
per the hub sweep charter in CLOSEOUT-PLAN.md. A real hub instance was stood up with
`dart run bin/server.dart` (port 18099, scratch DB/atlas under the session scratchpad,
`--accepts-raw-subs`, strong secret) and driven through all 44 registered routes the
way the Collaborative Sky clients drive them: 90+ checks across account/login/lockout,
narrowed-token minting/attenuation/self-revoke, tile contribute/outlier-reject/retract,
raw subframes, calibration publish/poison/query/download/retract + flat scoping,
mosaic claim/eviction/upload-gate/assembling/complete, co-imaging join/SSE/accounting/
baton/close, moderation, per-identity rate limiting, and the audit ledger. Result:
**89-of-90 main-driver checks passed; 2 findings** (one hub behavior, one campaign
ledger). Per-unit evidence is recorded in `status.json` under the `hub:` keys.

Nothing was fixed; this file is the record.

---

## H1 — Suspended account still gets a 200 + fresh bearer token from `POST /v1/sessions`

**Severity: medium (misleading response + false audit row; NOT an authz bypass).**

`ModerationService.suspend` stamps `accounts.suspended_at` and revokes every live
token, and `TokenService.resolve` fails closed on `suspended_at` — so the kill
switch itself holds. But `AccountService.login` never checks `suspended_at`:

Reproduced against the live hub (driver `probe_suspend.dart`):

```
suspend:                        200 {"suspended":true,...}
old token after suspend:        401   <- fail-closed, correct
suspended re-login:             200 {"accountId":...,"bearerToken":"c9357e2...","trust":0.5}
fresh-token read after suspend: 401
fresh-token write after suspend:401
```

Three consequences:

1. **Misleading success**: a suspended user is handed a fresh bearer token and a
   `trust` value as if in good standing; every subsequent call then 401s
   ("invalid or expired token") with no hint the account is suspended — the
   cry-wolf defect class (the app states something untrue).
2. **False audit rows**: each such login writes a SUCCESSFUL `login` entry
   (`_loginHandler` audits status 200), so the moderation ledger shows a
   suspended account "logging in" repeatedly.
3. **Token-table growth**: each login inserts a token row that can never resolve.

Expected: `login` (or `_loginHandler`) should refuse a suspended account — e.g.
403 with a stable `accountSuspended` code — the same way `resolve` fails closed.

Where: `server/skotiq_hub/lib/src/auth/account_service.dart` (`login`),
`server/skotiq_hub/lib/src/hub_server.dart` (`_loginHandler`).

## H2 — The "counted hub tree" is not actually in inventory.json (denominator claim is hollow)

**Severity: campaign-ledger integrity (no hub code defect).**

Commit `8e6558cb7` ("counted hub tree") and the CLOSEOUT-PLAN reconciliation note
both state the 28 hub files are counted as `hub:`-prefixed units and that
"inventory now 1182 units / 3826 controls" includes them. The working-tree
`reports/coverage/inventory.json` DOES have 1182 units — but **zero** of them are
`hub:` units (`grep '"hub:' inventory.json` = 0 matches, verified again against
the committed blob).

Cause: `tools/production/coverage_inventory.dart` line 118 routes the hub tree
through `_treeUnits`, which drops any file where `_countControls` (Flutter/HTML
widget-control regexes: `Switch(`, `IconButton`, `onTap:`, ...) finds nothing —
and no file under `server/skotiq_hub/lib` matches any control pattern
(verified by grep). So all 28 hub files are silently filtered out and the
+35-unit growth in that commit came entirely from the API-route counter. The
denominator the plan says was "honestly widened" was not widened at all.

Suggested (not applied): give the hub tree its own unit collector that counts
routes/services instead of widget controls, or bypass the `controls.isEmpty`
filter for `kind == 'hub'`. The 28 `hub:` keys this sweep recorded in
`status.json` use the exact id shape `_treeUnits` would emit
(`hub:<path-under-lib>`), so they will line up if the tool is fixed.

---

## Validated-good notes (for the record)

- Error envelope is uniform and leak-free across every provoked 4xx/5xx family:
  `{"error":{"code","message"},"requestId"}` with `x-request-id` echoed; 409
  conflict codes (`geometryMismatch`, `handoffHeld`, `mosaicPanelHeld`,
  `coimagingBatonHeld`, `mosaicNotAssembling`) all observed as specified.
- RateLimiter limited exactly at the documented window (429 on the 121st
  in-window request, `retry-after: 59`, token-keyed — other identities
  unaffected); LoginThrottle locked a probed key after 5 failures (6th = 429).
- Audit rows landed for signup, login, lockout, and — via the audit-denial
  middleware — for returned 401/403/404/409/422 denials (65 entries at sweep
  end); `/v1/audit` itself is admin-gated (non-admin 403).
- Weak-secret refusal works through the real entrypoint (`--secret change-me`
  = exit 78 EX_CONFIG).
- Quality gate, consent gate, FITS poison gates, flat cross-account scoping,
  claim-token upload gate, and the participant scoping on mosaic/co-imaging
  blob pulls all behaved to spec (see `status.json` `hub:` entries for the
  per-unit one-liners).

Sweep artifacts (session scratchpad, not committed):
`scratchpad/hub-sweep/driver/bin/drive.dart` (main driver, 89/90),
`probe_suspend.dart` (H1 repro), `probe_tail.dart` (last 4 routes),
`drive-output.log` (full evidence log). Hub process was stopped and the port
verified closed at the end of the sweep; no orphans.
