# Night Narrator — design spec

A real-time interpretive layer that turns the science pipeline's measurements into a
session-long feed of plain-language, timestamped insight cards ("the story of your
night"). Three surfaces: a dashboard cockpit tile, an imaging-screen ticker, and an
Analytics "Night Story" timeline.

The existing `ScienceInsightsEngine` is *stateless* — it reports what is true right
now. The Narrator is *stateful and temporal* — it detects **changes, events, and
records** (trends, thresholds crossed, discoveries, bests-of-night) with hysteresis
and cooldowns so cards fire on happenings, not on every frame.

## Event model

New Drift table `NarratorEvents` (in a new `tables/narrator_events.dart`, registered
in the database, schema bump 47 → 48 with an additive migration):

| column | type | notes |
|---|---|---|
| id | int autoincrement | |
| sessionId | int nullable → imaging_sessions | same pattern as science tables |
| capturedImageId | int nullable → captured_images | frame that triggered it, if any |
| timestamp | datetime, default now | |
| eventType | text | stable id, e.g. `discovery.moving_object` |
| category | text | `discovery` \| `milestone` \| `conditions` \| `equipment` \| `quality` |
| severity | text | `celebrate` \| `success` \| `info` \| `warning` \| `critical` |
| headline | text | one sentence, plain language, concrete numbers |
| body | text nullable | 1–2 sentences: what it means + what to do |
| evidenceJson | text nullable | payload for the micro-visualization (see below) |
| dedupeKey | text | engine-level dedupe/cooldown key |
| pinned | bool default false | discoveries pin to the top of feeds |

Dart-side enum types + a `NarratorEvent` plain class (no freezed needed) live in
`skotiq_core/lib/src/services/science/narrator/narrator_event.dart`.

### Evidence payloads
`evidenceJson` is one of a small set of typed shapes so the UI renders micro-viz
generically (`kind` discriminator):
- `{"kind":"sparkline","points":[..],"unit":"%","highlightLast":true}`
- `{"kind":"delta","from":18.6,"to":19.2,"unit":"mag","direction":"up"}`
- `{"kind":"vector","directionDeg":45,"magnitude":0.3,"label":"NE corner"}`
- `{"kind":"scalar","value":1.8,"unit":"\"","context":"session best"}`

## Engine architecture

`skotiq_core/lib/src/services/science/narrator/`:

- `narrator_event.dart` — event model + enums + evidence codecs.
- `narrator_context.dart` — `NarratorContext`: immutable snapshot handed to
  detectors. Latest values + short session history for each input: frame quality
  metrics, photometric calibrations, transparency samples, light-curve points,
  moving-object candidates, optical-train diagnostics, guide RMS stats, image
  stats (HFR/star count/FWHM), SQM samples, weather state, filter integration
  totals, solve counters, grader accept/reject events, pipeline stage failures,
  focuser temperature (if available), and a `DateTime now` (injected clock).
- `narrator_detector.dart` — `abstract class NarratorDetector { String get id;
  List<NarratorEventDraft> evaluate(NarratorContext ctx); }`. Detectors are pure
  given (ctx + their own mutable rolling state); each owns its hysteresis state.
- `narrator_engine.dart` — owns the detector list, runs them on input updates,
  applies dedupe (`dedupeKey`) + per-eventType cooldowns, returns accepted drafts.
- `detectors/` — one file per category (see catalog below).
- Service wiring: `narrator_service.dart` subscribes to the existing session
  product streams (`session_products.dart` providers / DAOs), guiding stats,
  weather, and the science status stream; builds contexts; persists accepted
  events through a `NarratorEventsDao`.
- Providers in `skotiq_core/lib/src/providers/narrator_provider.dart`:
  `narratorFeedProvider(sessionId)` (DB-watched stream, newest first, pinned
  bubbled), `recentNarratorFeedProvider` (sessionless, last N), and a
  `narratorServiceProvider` that keeps the service alive while a session runs
  (same lifecycle pattern as the science processing service).

All new public symbols exported from the skotiq_core barrel.

## Detector catalog (v1 — full send)

Thresholds are starting points; centralize them as consts on each detector.

### Discovery (severity `celebrate`, pinned)
1. `discovery.moving_object` — new `MovingObjectCandidate` with confidence ≥ 0.7.
   Headline: "Moving object detected — 2.1″/min at mag 17.3". Dedupe per candidate.
2. `discovery.lightcurve_event` — rolling baseline (median of last ≥8 light-curve
   points) deviates by > 3× combined uncertainty for ≥3 consecutive points.
   Direction-aware: "Your target faded 0.08 mag over the last hour — possible
   eclipse/transit ingress". Hysteresis: closes (new `info` event) when back within 1σ.
3. `discovery.period_found` — on period-analysis completion with Lomb-Scargle
   FAP < 0.01 or BLS SDE > 7: "Periodic signal found: 0.382 d (high confidence)".

### Milestone (severity `success`)
4. `milestone.limiting_mag` — first calibration of the night ("You're reaching
   magnitude 19.2 stars (5σ)") and each time `limitingMag5Sigma` beats the session
   best by ≥ 0.2 mag.
5. `milestone.calibration_locked` — ≥ 10 calibrated frames and zero-point std dev
   over the last 10 ≤ 0.05 mag: "Photometric calibration locked: ZP stable to ±0.03".
6. `milestone.best_seeing` — frame FWHM in the best 5% of the session (needs ≥ 20
   frames); cooldown 30 min: "Best seeing of the night — FWHM 1.8″".
7. `milestone.integration` — accumulated integration per filter crosses whole-hour
   marks: "2 hours of Ha on NGC 7000 in the bag".

### Conditions (severity by direction: improving `success`, degrading `warning`)
8. `conditions.transparency_trend` — linear trend of transparencyPercent over the
   last 30–45 min beyond ±8 points, narrated with the extinction delta.
9. `conditions.sky_darkness` — SQM tracker trend ≥ 0.3 mag/arcsec² over the session
   window: "Sky darkened 0.4 mag/arcsec² — fainter targets now in reach".
10. `conditions.clouds_vs_focus` — disambiguation: star count drops > 40% from its
    rolling median AND (transparency dropping OR weather layer reports clouds) →
    "Star count collapsed with the transparency drop — clouds, not focus". If star
    count drops while transparency is stable and HFR rose ≥ 15% → "…looks like
    focus drift, not clouds".
11. `conditions.excellent` — transparency > 90% sustained ≥ 20 min, once per
    session: "Exceptional transparency right now — a great window for your
    faintest filters".

### Equipment (severity `warning`, `critical` at the higher band)
12. `equipment.tilt` — `OpticalTrainDiagnostics.tiltScore` crosses warn (18) /
    critical (30); use `dominantTiltDirection` + PSF tiles for the headline:
    "Stars in the top-right are ~30% softer — possible sensor tilt toward NE".
    Action: open Diagnostics. Long cooldown (once per band per session).
13. `equipment.focus_drift` — rolling-median HFR ≥ 10% above the post-autofocus
    baseline sustained ≥ 15 min; mention focuser temperature delta when available:
    "HFR up 9% while temperature fell 3.5 °C — likely focus drift; refocus soon".
14. `equipment.gradient` — `gradientX/Y` magnitude above threshold for ≥ 5
    consecutive frames: "Persistent left-edge gradient — check for stray light or
    a low light-pollution dome".
15. `equipment.guiding_degraded` — guide RMS total ≥ 50% above the session median
    sustained: "Guiding RMS up 0.4″ over the last 20 min — wind, balance, or seeing?".

### Quality / pipeline (severity `info`/`warning`)
16. `quality.clipping` — high/low clip percent above threshold for ≥ 5 consecutive
    frames (one event, not per frame; subsumes the insights-engine rule).
17. `quality.reject_burst` — ≥ 3 consecutive auto-grader rejects; name the dominant
    cause from the grade rules ("3 frames rejected in a row — all over the HFR
    limit").
18. `quality.solve_drop` — plate-solve success rate over the last 10 frames falls
    below 50% after previously being healthy.
19. `quality.pipeline_failure` — a science stage fails (cooldown per stage type).

## UI

Shared design language: `SkotiqCard` chrome, `SkotiqColors` palette,
lucide icons, severity as a subtle left edge accent (never a filled red box).
Category icons: discovery `sparkles`, milestone `trophy`, conditions `cloudMoon`,
equipment `wrench`, quality `gauge`. `celebrate` severity gets a distinct treatment
(accent gradient + the evidence viz emphasized). Tone: a knowledgeable friend at
the eyepiece — specific, calm, genuinely excited for discoveries.

### Card library — `skotiq_app/lib/widgets/narrator/`
- `narrator_card.dart` — compact card: category icon, headline, relative
  timestamp, micro-viz (right-aligned sparkline/delta/vector/scalar renderer from
  evidenceJson), severity edge accent. Tap → detail sheet.
- `narrator_detail_sheet.dart` — bottom sheet: full headline/body, enlarged
  evidence chart, a static "why this matters" explainer per eventType (map in
  `narrator_explainers.dart`), and an optional action button (open Diagnostics /
  Analytics science tab / grader settings via existing navigation).
- `narrator_feed.dart` — reusable feed list (newest first, pinned on top, animated
  insertion, empty state: "The Narrator is watching — insights appear as your
  frames come in").

### Surfaces
1. **Dashboard cockpit tile** `cockpitNarrator` ("Night Narrator") — registry entry
   + `DashboardWidgetId` enum + string round-trip + default zone (secondary) in
   `dashboard_layout.dart`. Shows the feed (last ~8, scrollable), self-chromed.
2. **Imaging ticker** — one-line strip near the science HUD: latest event headline
   with category accent, auto-advances through recent events, tap opens a bottom
   sheet with the full feed.
3. **Analytics → Science tab: "Night Story" timeline** — vertical timeline grouped
   by hour with category filter chips, severity rail, inline micro-viz; uses the
   sessionful feed provider with the same session selector the science tab uses.

## Testing
- Pure detector unit tests (synthetic context sequences: trend fires once, cooldown
  respected, hysteresis closes events) in skotiq_core.
- Widget tests: card renders all evidence kinds; feed empty state; cockpit tile
  registers and round-trips its DashboardWidgetId.
