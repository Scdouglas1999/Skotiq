# Skotiq Web Dashboard

A single-page browser dashboard for the Skotiq headless API.

This SPA lives next to the Run-Watch PWA (`apps/desktop/web_run_watch/`)
and is served by the desktop's `HeadlessApiServer` at `/dashboard/`.
The Run-Watch view is the mobile-first one-glance run monitor; the
dashboard is the laptop-first surface that lets an operator watch and
control a session without installing the desktop app.

## Stack

Vanilla JavaScript, no build step. Two source files do everything:

- `js/api.js` — wraps every `/api/...` endpoint the server exposes,
  plus the `/events` WebSocket and `/api/logs/tail` SSE subscription.
- `js/app.js` — bootstraps the dashboard, handles the WebSocket event
  fan-out, panel rendering, hash routing, gallery, log tail, and the
  login overlay.

CSS lives in `css/dashboard.css`. Markup is `index.html`.

## Theme + layout preferences (overnight-tool polish)

The dashboard is built to sit open for an 8-hour imaging session, so a
couple of operator preferences are persisted to `localStorage`:

- **Theme toggle (light / dark).** The dashboard is dark-first to match
  `skotiq_ui` `SkotiqColors.dark`. A toggle in the top bar (sun /
  moon glyph, left of the Connect button) flips to a light palette. The
  whole UI is a CSS-variable swap: light mode only redefines the *core*
  palette tokens under `:root[data-theme="light"]` in `dashboard.css`, and
  every downstream alias (`--bg-*`, `--text-*`, `--tint-*`, …) cascades from
  there. The choice is saved to `localStorage.skotiq_theme`; on first
  visit with no stored choice the dashboard honours
  `prefers-color-scheme`. The `<meta name="theme-color">` updates so the
  browser chrome matches.
- **Persisted panel collapse.** Every panel header carries a caret
  (injected by `setupPanelPrefs()` in `app.js`) that collapses the panel to
  just its header. The set of collapsed panels is saved to
  `localStorage.skotiq_panel_collapsed` (a JSON array of panel ids) and
  restored on `init()`, so the operator's chosen layout survives a reload
  during a long session. Panel *order* is fixed in the markup; "which panels
  are open vs. collapsed" is the load-bearing layout pref here.

Both are pure vanilla JS/CSS — no build step, no dependencies.

## URL routes (hash-based)

The dashboard is a single-page grid; the hash drives which panel the
operator's eye lands on after a bookmark is opened or a deep link is
shared:

| URL fragment | Panel that scrolls into view |
|--------------|------------------------------|
| `#/run`      | Sequencer (current run)      |
| `#/devices`  | Devices                      |
| `#/gallery`  | Image gallery                |
| `#/logs`     | Server log tail              |
| `#/mount`    | Mount                        |
| `#/camera`   | Camera                       |
| `#/guiding`  | Guiding (PHD2)               |
| `#/sequences`| Saved sequences (ops)        |
| `#/analytics`| Profile + analytics (ops)    |
| `#/planetarium` | Planetarium (remote slew) |
| `#/settings` | Host settings                |

`#/run/<runId>` is reserved for the desktop replay scrubber; on the
web dashboard it currently lands on the sequencer panel and logs a
hint that the deeper replay UI is desktop-only.

## Authentication

On first visit the SPA shows a login overlay. The flow is:

1. The SPA reads `sessionStorage.skotiq_token` — if present, it
   skips the overlay and connects.
2. Otherwise, it calls `GET /api/auth/csrf`: a `200` indicates an
   HttpOnly cookie session is alive and the SPA reuses it.
3. Otherwise, it calls `GET /api/info`: a server reporting
   `authRequired: false` is connected without a token.
4. Otherwise, the overlay surfaces with two options:
   - **Pair this browser** — launches the existing 6-digit pairing
     modal, which calls `POST /api/pairing/start` and
     `POST /api/pairing/verify` to mint a fresh bearer.
   - **Sign in** — uses a bearer token the operator pasted (e.g. from
     the desktop's "Remote Access" screen).

The "Remember on this device for 30 days" toggle controls whether the
SPA upgrades the bearer to an `HttpOnly skotiq_session` cookie via
`POST /api/auth/cookie`. Unticking it keeps the bearer in
`sessionStorage` only, so it dies when the tab closes.

## Live data sources

| Surface | Endpoint | Notes |
|--------|----------|-------|
| Event firehose | `WebSocket /events?ticket=...` | Single-use 60s ticket from `POST /api/ws/ticket`; falls back to `?token=` for compatibility |
| Image preview  | `GET /api/camera/last-image/jpeg`, polled via the camera panel | Driven by `ExposureComplete` events; a 30s grace timer kicks a manual fetch if no event arrives |
| Image gallery  | `GET /api/images?limit=24` + `GET /api/images/<id>/thumbnail` | Modal preview uses the same thumbnail endpoint at higher resolution |
| Log tail       | `EventSource /api/logs/tail?minSeverity=info&access_token=...` | Bearer goes in the query string because EventSource lacks a header API |
| Sequencer state | `GET /api/sequencer/status` + WS sequencer events | WS-driven; REST fallback only when WS is silent for 45s |

### Update model: WS firehose first, REST as a silence fallback

Every live panel is driven by the `/events` WebSocket firehose, **not** by
per-panel polling. `api.on('event', …)` fans each event into
`handleServerEvent()` (`app.js`), which dispatches by `category` —
`camera`/`imaging`, `mount`, `focuser`, `filterWheel`, `rotator`,
`sequencer`, `dome`, `safety`/`weather`, `profile`, `guiding`/`phd2`,
`equipment`, `polarAlignment` — and refreshes only the affected panel.

There is **no per-panel `setInterval`**. The only timers are resilience
infrastructure: a 30 s WS ping, a 2 s staleness watchdog, and a 5 s REST
fallback (`fetchAllStatus`) that arms **only** once the WS has been silent
past `WS_FALLBACK_THRESHOLD_MS` (10 s) and is torn down the moment the
socket recovers (`checkStaleness()` in `app.js`). The two config-only
panels (Planetarium remote-slew and Settings) have no live event category
and refresh on connect, on their manual Refresh button, and via the
fallback — which is correct, as the host doesn't emit events for them.

The `tools/smoke.mjs` guard asserts this invariant (≤ 3 `setInterval`
timers, all resilience; REST fallback gated on WS silence) so a future
per-panel poll can't sneak back in.

## Automated smoke test (no browser, no build step)

The dashboard is vanilla JS/CSS and is not Flutter-golden-able, so the
automated guard is a static smoke script that runs under plain `node`:

```sh
node apps/desktop/web_dashboard/tools/smoke.mjs
```

It (1) compiles `js/app.js` and `js/api.js` (catches syntax errors), and
(2) asserts the Phase F polish hooks are wired and consistent across
`index.html` / `dashboard.css` / `app.js`: the theme toggle + light
palette + `skotiq_theme` persistence + `prefers-color-scheme`, the
persisted panel-collapse (`skotiq_panel_collapsed`), and the
WS-firehose update model (≤ 3 resilience `setInterval` timers; REST
fallback gated on WS silence). Exit 0 = pass, 1 = a check failed.

## Honesty contract (`node --test`)

```sh
cd apps/desktop/web_dashboard && node --test "test/*_test.js"
```

`test/dom_shim.js` supplies just enough DOM to **execute** each render path,
so these are assertions about what the operator sees rather than about how
the source is spelled. `test/dashboard_honesty_test.js` and
`test/run_watch_honesty_test.js` cover both static surfaces and pin the
rules that a remote monitoring page cannot bend:

| Rule | Why it is a rule |
|------|------------------|
| A dead or silent server flips the header to **No contact** and raises `#link-banner`; the sequencer badge stops asserting a state | `api.isConnected` is set once at connect. Before the watchdog, a `SIGKILL`ed backend left a green "Connected" + "running" on screen indefinitely (measured at 65 s). |
| A 429 becomes a typed `rate_limited` error carrying the server's `retryAfterSecs`; no request leaves the page inside that window and the limiter's body never reaches the DOM | The read budget is 60/s per token and `fetchAllStatus` fires a dozen requests per tick. The refusal JSON used to be printed straight into the log panel. |
| The Settings panel reads only keys `GET /api/settings` and `GET /api/settings/location` emit | `observatoryName`, `defaultSavePath`, `plateSolveSolver` and `elevationMeters` exist in no response, so four rows read `--` on a fully configured host. |
| A disconnected PHD2 shows no RMS at all | It reports `0.0` for every RMS while disconnected, and the panel read `rmsRA` — a key nothing sends. The result was a flawless `0.00"` guide for a dead guider. |
| `dataSource: 'unavailable'` yields no affirmative safety verdict | With no weather hardware the server still answers `safeToImage: true` / `alertLevel: 'clear'` / `isSafe: true`; rendering those verbatim gave an unwatched rig a green "safe". |
| A progressbar carries no `aria-valuenow` until a value is reported | `aria-valuenow="0"` announces "0 percent" — a figure nobody sent. |
| A control button reports the server's own answer | `POST /api/sequencer/stop` answers 200 with `wasRunning: false` when there is nothing to stop. |
| An unknown integration denominator renders `--` | `SequenceProgress.totalIntegrationSecs` is only filled in by the editor-driven start path, so a headless run's snapshot carries no total; the phone used to print `24s / 0s`. |
| The staleness window is counted in missed heartbeats, never in a wall-clock number picked apart from the poll cadence | An idle server pushes no events, so the 30 s ping/pong is the only thing that stamps contact. Against a 12 s window a healthy, idle server was declared lost for 18 s of every 30 s cycle — 26 of 40 samples over a 200 s soak. |
| Staleness is a link state, not a mark on the badge: contact returning hands the badge back to the data | The badge that went `unknown` on one missed exchange stayed `unknown` for the rest of the session, over every later healthy poll, because only the header was restored. |
| The run badge reads the field the snapshot actually carries | `SequenceExecutionState` has no `cancelled` member, so a stopped run reads `progress.state: 'idle'` while `sequencer.state` reads `cancelled` — and the phone told the operator the rig was idle 8 % into a night that had just been cancelled. |
| Before the first answer both surfaces say **connecting** and assert nothing | The shipped markup and the no-status render path both claimed `idle` — a live run reads as a parked telescope until the first exchange lands. |

## Reference screenshots

Captured headless via Chromium (`--screenshot`, 1440-wide) against the
static files; the login overlay is present because no server was connected
during capture. Stored in `docs/screenshots/`:

| File | Shows |
|------|-------|
| `docs/screenshots/dashboard-dark.png` | Default dark theme (the native palette). |
| `docs/screenshots/dashboard-light.png` | Light theme via the top-bar toggle (persisted to `localStorage`). |
| `docs/screenshots/dashboard-light-collapsed.png` | Light theme with Filter Wheel / Rotator / Settings panels collapsed and restored from `localStorage` after a reload. |

To re-capture after a UI change, serve the static files so `/dashboard/`
resolves (any static server that maps `/dashboard` → `web_dashboard/`),
then run Chromium headless with `--screenshot=…` against
`http://127.0.0.1:<port>/dashboard/`. Pre-seed `localStorage`
(`skotiq_theme`, `skotiq_panel_collapsed`) from a tiny bootstrap
page that `location.replace('/dashboard/')` to exercise the persisted
paths.

## Smoke test recipe (manual, against a live server)

After a code change, manually verify against a running headless
server. The recipe is:

1. **Start the headless server**. From the repo root:

   ```powershell
   cd apps/desktop
   .\start_headless.bat
   ```

   Or run the regular desktop app and check the Remote Access screen
   for the LAN URL.

2. **Open the dashboard** in any browser at the URL the server prints
   (e.g. `http://127.0.0.1:8080/dashboard/`). Expected: the login
   overlay appears.

3. **Pair the browser**. Click "Pair this browser". A 6-digit code
   appears on the desktop console. Type it and click Pair. The
   overlay closes and the dashboard loads with a green "Connected"
   dot in the top bar.

4. **Verify hash routing**. Click each of the Run / Devices / Gallery
   / Logs nav buttons. The URL hash should update (e.g.
   `…/dashboard/#/gallery`) and the matching panel should scroll into
   view with a brighter outline.

5. **Verify the gallery**. Navigate to `#/gallery`. The grid loads
   recent captures via `/api/images?limit=24`. Click a thumbnail —
   the modal preview opens with a "Download original" link.

6. **Verify the log tail**. Navigate to `#/logs`. The "live" badge
   should appear within a second. Trigger a server-side log line
   (e.g. capture an exposure) and confirm it appears in the panel.
   Click Pause → the badge flips to "offline" and the stream
   disconnects. Click Resume → the badge returns to "live".

7. **Verify the run dashboard**. Start a small sequence on the
   desktop and navigate to `#/run`. The sequencer panel should
   update its status, target, current node, and ETA in real time.

8. **Verify the 30-day session**. Tick "Remember on this device" in
   the login overlay before signing in, then close the browser and
   reopen the dashboard URL. Expected: no login overlay; the
   dashboard auto-connects via the HttpOnly cookie. The cookie's
   `Max-Age` is 30 days per `headless_api/handlers/auth_handlers.dart`.

9. **Verify the no-auth path**. Stop the server, set
   `SKOTIQ_REQUIRE_AUTH=false`, restart, and re-open the
   dashboard. Expected: no overlay appears at all; the dashboard
   auto-connects.

11. **Verify the theme toggle**. Click the sun/moon button in the top
    bar (left of Connect). The whole dashboard flips between dark and
    light, the glyph + browser chrome colour flip too, and the choice
    survives a reload (it's in `localStorage.skotiq_theme`). With
    no stored choice, the first load matches the OS light/dark setting.

12. **Verify persisted panel collapse**. Click the caret at the right
    of any panel header — the panel collapses to just its header. Reload
    the page: the same panels stay collapsed (restored from
    `localStorage.skotiq_panel_collapsed`). Re-open them and reload
    to confirm the cleared state persists too.

10. **Manually exercise edge cases**:
    - Disconnect the server while the dashboard is open — the status
      dot should turn red and the WS should reconnect with backoff.
    - Pause the log tail, trigger 200 log lines, then resume — the
      stream should reattach without dropping the panel's scroll
      position.
    - Type a malformed token into the login overlay — the status
      line should surface the server's `401` text instead of failing
      silently.

If any of these steps fails, treat it as a regression. The dashboard
covers remote control via the headless API only — full GPU planetarium
rendering remains desktop/mobile-only.

## Adding a new endpoint or panel

1. Add the wire method to `SkotiqApi` in `js/api.js` next to the
   existing endpoints. Keep the method name aligned with the server
   route's purpose (e.g. `imagesGetAll`, not `getImageList`).
2. Add markup to `index.html`. Re-use the existing `.panel /
   .panel-header / .panel-body` skeleton.
3. Add CSS to `css/dashboard.css` (the cascade matters — append to
   the file, don't rewrite earlier rules).
4. Wire setup + render functions in `js/app.js`. Hook into the
   `api.on('event', ...)` firehose if the panel needs to react to
   server events; otherwise poll via the existing
   `fetchAllStatus()` loop.
5. If the panel is route-addressable, add a hash route entry to
   `HASH_ROUTES` and a `data-route` nav button to the
   `.capability-nav` row.
