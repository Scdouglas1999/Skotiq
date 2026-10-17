# Architecture Unification Plan — Three Parallel Non-Agreeing Systems

**Date:** 2026-06-05
**Author:** Lead architect (read-only recon + design; no code changed)
**Branch context:** `roadmap/onboarding-and-night-readiness` (28-commit full-night remediation is GREEN; core 3111 pass, Rust sequencer 532, app/ui/bridge analyze clean)
**Source audits:** `docs/audits/2026-06-04-full-night-workflow-audit.md`, `docs/audits/2026-06-04-remediation-complete.md`
**Prime directive:** Any unification proposed here MUST NOT regress the just-fixed unattended-night path. Favor the **lowest-risk** seam — "share a core" or "make one a read-only view of another" over "rip a system out." When unification is high-risk-for-low-gain, the recommendation is to leave a **shared-core seam** and defer.

This doc was written after re-reading the cited source. Spot-checks that confirmed the recon is accurate, not confabulated:

- `scheduler_engine.dart:534-537` — the pure `scoreCandidate(c, now)` already exists and is documented "Public so tests and the UI's 'Preview' button can compute a decision without mutating state." The whole-night autopilot's bespoke six-factor formula is at `:644-707`; the hard Sun gate at `:561-569`; `customHorizon` hard reject at `:615-627`; goals-complete reject at `:579-593`. (read & confirmed)
- `weather_safety_provider.dart:370-372` pushes `finalStatus == unsafe` as a **plain bool** (never `None`); `:535-545` `_pushWeatherVerdict(bool)` only ever sends `true`/`false`. Rust `triggers.rs:535` is `!state.weather_safe || state.weather_verdict_unsafe == Some(true)` — the OR that makes the channel structurally add-only. (read & confirmed)
- `run_dashboard_providers.dart:589-679` — the bridge does banner + toast (`:635`) + audible (`:644-657`) + `pushService.enqueueCriticalNotification` (`:665-674`) gated **only** on `settings.pushCriticalAlerts` (`:616`). `push_notification_service.dart:177-192` `enqueueCriticalNotification` checks **only** `_config.enabled`, ignoring per-event toggles. Its own `start()/_handleEvent` subscription is at `:140-219`. (read & confirmed)

---

## "DO NOT TOUCH / PRESERVE EXACTLY" — the W1–W5 behaviors

These are the just-fixed unattended-night behaviors. Every change below is designed to leave these byte-for-byte intact. Any PR that modifies the decision/dispatch/enforcement surface of these is **out of scope** and must be rejected in review.

- **W1 — Twilight / Sun gate (no daylight imaging).** `scheduler_engine.dart:561-569` hard reject `sunAlt > maxSunAltitudeDegrees`. Guard: `scheduler_engine_test.dart:179` "rejects all candidates while the Sun is up", `:212` "does not apply the Sun gate at night".
- **W2 — Frame attribution (`catalogTargetId`).** `scheduler_engine.dart:1000` sets `catalogTargetId` in `buildSequenceForCandidate`. Guard: `test/providers/sequence/frame_attribution_test.dart`, `scheduler_engine_test.dart:387` "builds a sequence that exposes the highest-remaining filter".
- **W3 — Completion-reaction re-dispatch.** `SequenceCompleted` → re-evaluate, not idle-for-the-night. Guard: `scheduler_engine_test.dart:548` "SequenceCompleted re-dispatches a still-eligible current target", `:579` "a non-completion trigger does NOT re-dispatch".
- **W4 — Park-at-dawn, once per dawn + hysteresis.** `_isEndOfNight` (`:419-426`), `_handleNoEligibleTarget` park (`:433-457`), hysteresis (`:294-345`). Guard: `scheduler_engine_test.dart:615/:641/:665` (incl. goals-complete-but-night park), `:258-385` (hysteresis switching).
- **W5 — Fail-closed weather/safety gate.** Rust `triggers.rs:535` OR; `safety_is_safe` poll + `FailClosed`/`FailOpen`/`WarnOnly` (`executor/mod.rs:3666-3753`); the device AND-gate `resolve_safety_device_id` (`unified_device_ops.rs:180-216`) where "no device configured" → `Err` → `Some(false)` under FailClosed → abort. Guard: native `test_weather_unsafe_trigger`, `test_weather_unsafe_trigger_honours_dart_verdict` (`triggers.rs:2284-2347`), executor WeatherUnsafe recovery-re-check (`mod.rs:6135-6155`); Dart `weather_safety_verdict_push_test.dart`; `SafeRigService` enforcement tests.

The cross-language **scoring parity contract** (`scoring.rs` ↔ `target_scoring.dart`, dual parity fixtures) is also a preserve-exactly invariant for subsystem 1.

---

## Subsystem 1 — Target Selection (3 scorers)

### Current tangle

Three independent "what should I image" deciders with **two unrelated scoring formulae**:

- **SchedulerEngine** (`scheduler_engine.dart`) — AUTHORITATIVE live autopilot. Bespoke six-factor instantaneous score (`:644-707`): sin² altitude (`:719-727`), linear meridian factor over ±6h HA (`:729-743`), illumination-weighted moon, `hours-until-set/10`, filter-coverage from integration goals, `userPriority/10`, scheduledWindow boost. Self-contained Meeus moon (`astronomy_helpers.dart:27-71`, illumination `0..1`). Hard Sun gate, hard `customHorizon` reject at the imaging instant, goals-complete reject. This is the only one that slews/exposes/parks.
- **TargetSuggestionService** (`target_suggestion_service.dart`) — AUTHORITATIVE human Planner preview + Smart-Night ranker. Whole-night sampling (dusk→dawn, 15-min) on peak altitude / best airmass / transit-centeredness / imaging-window hours / moon-at-peak (`:44-258`), delegating to `target_scoring.dart:251-405`. Uses `AstronomyCalculations.moon*` (percent). Horizon checked only at **peak azimuth** (`:142-156`). Never dispatches.
- **Rust TargetScheduler node** (`target_scheduler.rs`, `scoring.rs`) — AUTHORITATIVE in-sequence picker, only when an operator hand-authors a `TargetScheduler` logic node. Five-axis piecewise score that is a **verbatim, parity-tested port** of `target_scoring.dart`. Adds per-azimuth horizon runnable-gate, hard moon-avoidance, count-budget completion, adaptive swap, recompute cadence.

**Why a senior reviewer rejects it:** the Planner can show a #1 the autopilot won't slew to (whole-night peak vs instantaneous altitude+meridian+most-remaining-filter), the disagreement is worst at dusk (the moment the user is watching), and moon/horizon/completion are each computed three ways with two illumination units. There is **no** parity test between the live engine and the other two — and there *cannot* be, the axes don't correspond.

### Chosen unification (lowest-risk)

**Two-track, touches ZERO autopilot decision math.**

- **Authoritative component:** the **SchedulerEngine** is the single authority for "what runs tonight." It already exposes a pure, side-effect-free `scoreCandidate(c, now)` (`:534-537`).
- **Planner becomes a READ-ONLY VIEW of the engine.** Add a new pure `previewRanking(now)` on the engine that maps `_scoreCandidate` over the candidate-loader's set **without** mutating `_status` and **without** dispatching. Point the Planner's "what will run tonight" at this. By construction the authoritative #1 the human sees is what the rig will slew to.
- **TargetSuggestionService is RE-SCOPED, not deleted** — kept as the **whole-night outlook supplement** it is genuinely better at: peak altitude, transit time, imaging-window hours, framing-fit, mosaic tagging, human reasoning strings. Surfaced as secondary advisory columns, no longer presented as the authoritative pick order.
- **Rust TargetScheduler node stays as-is**, documented as the in-sequence hand-authored picker that intentionally uses the **catalog-scoring core** (the `scoring.rs` ↔ `target_scoring.dart` parity contract). Do **not** merge its formula with the engine's bespoke formula. (Optional, later, low priority) extract the five-axis piecewise into one shared Dart `CatalogScoringCore` both `target_scoring.dart` and a future engine-alignment could consume.

**Net:** 3 deciders → 1 authoritative live decider (engine) + its read-only Planner view + 1 parity-locked in-sequence node sharing the planetarium core. No autopilot math changes.

| Component | Becomes |
|---|---|
| SchedulerEngine | Authoritative (unchanged decision math; gains one additive pure read-only method) |
| TargetSuggestionService | Re-scoped to read-only "night outlook" supplement (advisory columns) |
| Rust TargetScheduler / scoring.rs | Unchanged; documented as the catalog-scoring-core in-sequence picker |
| target_scoring.dart | Unchanged; (optional later) becomes/feeds the shared `CatalogScoringCore` |

### Concrete file-level change list

1. `scheduler_engine.dart` — **ADD** `previewRanking(now)` that reuses `_scoreCandidate` over the candidate set without touching `_status`/`_evaluateOnce`/`_handleNoEligibleTarget`/`buildSequenceForCandidate`. **Do not change** `_scoreCandidate` or any factor function.
2. `providers/scheduler_provider.dart` — expose a preview provider that runs `previewRanking` against the **same** `SchedulerCandidateLoader` the autopilot uses (same goals/constraints/horizon/filters/scheduledWindow inputs).
3. `target_suggestion_service.dart` — re-scope: keep peak-altitude/transit/imaging-window/framing-fit/reasoning as advisory; stop presenting its sort order as "what the rig will run."
4. `providers/target_suggestion_provider.dart` — re-point Planner consumers so authoritative pick order = engine preview; suggestion data is supplementary.
5. `packages/skotiq_app/lib/screens/planner/**` — label the engine-preview pick as authoritative "what will run tonight"; show suggestion night-outlook as secondary.
6. (Optional, later) `target_scoring.dart` / `scoring.rs` — extract shared five-axis core; **keep parity fixtures green**. No behavior change.

### Regression guards (must stay/turn green)

- **Untouched (by design):** the entire `scheduler_engine_test.dart` decision/dispatch/park suite — W1 (`:179`,`:212`), W2 (`:387` + `frame_attribution_test.dart`), W3 (`:548`,`:579`), W4 (`:258-385`,`:615`,`:641`,`:665`). The preview method calls the **pure** `scoreCandidate`; it must **never** call `_evaluateOnce` (which mutates/dispatches). Forbid that in review.
- **New tests:** (a) `previewRanking(now)` returns a ranking identical to mapping `scoreCandidate` over the same candidates and **does not** mutate `_status` or trigger dispatch (assert `_status` unchanged + no `buildSequenceForCandidate` call); (b) Planner preview provider's #1 == engine's would-dispatch pick for a fixed clock/candidate set.
- **Re-run before merge:** `skotiq_core` full suite (esp. `scheduler_engine_test.dart`, `scheduler_project_filter_test.dart`, `frame_attribution_test.dart`, `target_suggestion_service_test.dart`); the planetarium parity test; `cargo test -p skotiq_sequencer` (scoring + target_scheduler parity).

### Effort / risk

**Effort: medium. Risk: LOW.** The behavior-changing surface is additive (a pure read-only method) plus UI re-labeling. The single genuine footgun is wiring preview to `_evaluateOnce` instead of the pure scorer — explicitly forbidden and test-guarded.

---

## Subsystem 2 — Weather Evaluators (double-evaluation + 2-valued push)

### Current tangle

- **Dart `weatherSafetyProvider._evaluateAllSources`** (`:201-403`) — PRIMARY evaluator+enforcer. Folds hardware-weather thresholds (`_evaluateHardwareWeather:701-720`), `safetyMonitorStateProvider.isSafe`, API alert level, and park-before-dawn into one verdict; latches and calls `SafeRigService` on unsafe; **also** pushes a boolean verdict to Rust (`_pushWeatherVerdict:535-545`).
- **Rust trigger-monitor poll + `WeatherUnsafe`** — SECONDARY evaluator. Polls `device_ops.safety_is_safe`, applies fail-mode to `weather_safe` (`mod.rs:3666-3753`); always-armed `weather_unsafe` trigger fires on `!weather_safe || weather_verdict_unsafe == Some(true)` (`triggers.rs:535`). A **second** evaluation of the same physical device.
- **`weather_verdict_unsafe` slot + `UpdateWeatherVerdict`** — pure consumer channel, `Option<bool>`, ORed in as an additional unsafe source only.
- **`SafeRigService`** (`:119-288`) — correctly the single Dart enforcer.
- **`device_ops.safety_is_safe`** — the hardware AND-gate; "no device" → `Err` → `Some(false)` under FailClosed. **The W5 gate; do not weaken.**

**Why a senior reviewer rejects it:** both sides independently evaluate the same physical device with different logic, reconciled only by the OR. The recovery re-check (`mod.rs:1211`) re-polls **only** `safety_is_safe`, so a Dart-threshold-only abort is declared "recovered" the instant the hardware boolean reads safe → premature resume / abort-resume flap. And the push collapses snoozed/disabled/failOpen/warnOnly all to `false` (SAFE) and never sends `None` — a **latent landmine**: safe today only because Rust ORs it; if anyone ever makes Rust "trust" the verdict, a disabled toggle pushing SAFE would suppress a hardware-unsafe abort.

### Chosen unification (lowest-risk)

**Dart = single safety-VERDICT authority for API/threshold/dawn sources. Rust = device authority for the hardware boolean. Joined by an OR structurally incapable of weakening either. The W5 gate is not touched.**

- **Authoritative components:** Dart verdict authority for non-hardware sources; Rust `safety_is_safe` authority for the hardware boolean. Both retained — this is the "two authorities, one structural join" seam, not a rip-out.
- **Keep EXACTLY as-is:** `WeatherUnsafe = !weather_safe || weather_verdict_unsafe == Some(true)` (`triggers.rs:535`); the `safety_is_safe` poll + FailClosed semantics (`mod.rs:3666-3753`). Do **not** make Rust trust the verdict.
- **Remove the DUPLICATE evaluation, not the channel:** have `_pushWeatherVerdict` push the Dart verdict **excluding** the hardware-device component (push unsafe iff Dart's API-alert/threshold/dawn folding says unsafe). The safety monitor is then evaluated **once** (in Rust). The OR still guarantees the monitor aborts.
- **Push `None` (abstain), not `false`,** when `weatherSafetyEnabled == false` OR snoozed OR fail-mode is failOpen/warnOnly. The bridge API already accepts `Option<bool>` (`sequencer.rs:1704`); only the Dart caller changes. This makes the channel **strictly monotone add-unsafe-or-abstain** — it can never suppress a hardware abort even under a future mis-refactor. **Closes the landmine.**
- **Tighten the recovery re-check** (`mod.rs:1211`) to require `weather_verdict_unsafe != Some(true)` before declaring `WeatherUnsafe` recovered, so a Dart-threshold abort is not prematurely cleared by a hardware-only re-poll.

### Concrete file-level change list

1. `weather_safety_provider.dart` — `_pushWeatherVerdict` pushes the **non-hardware** verdict component; push `None` on disabled/snoozed/failOpen/warnOnly. Add a named accessor (`bool? get pushedVerdict`) so the abstain rules live in one place.
2. `test/providers/weather_safety_verdict_push_test.dart` — **intended contract change:** the `:124-139` case currently asserts `unsafeOverride: false` when safety disabled; update to expect `None` (abstain). This is the new contract, not a regression.
3. `executor/mod.rs` — recovery re-check requires `weather_verdict_unsafe != Some(true)`; add a staleness guard so a stale `Some(true)` doesn't pin a sequence paused indefinitely after Dart stops pushing (older than ~2 push intervals → treat as abstain for recovery).
4. `triggers.rs` — no logic change to the OR; only docs/parity-test additions for the fail-mode truth table.
5. (Shared-core, recommended) extract `_evaluateHardwareWeather` thresholds into a pure `WeatherThresholdEvaluator`; extract the fail-mode truth table (failClosed→unsafe / failOpen→safe / warnOnly→preserve) — implemented twice today (`weather_safety_provider.dart:281-303` + `mod.rs:3679-3720`) — into one documented table with a **cross-language parity unit test**. Reconcile or delete the duplicate humidity gate (Dart `_evaluateHardwareWeather` vs Rust standalone `HumidityThreshold` with a separate value).

### Regression guards

- **Preserve-exactly:** `triggers.rs:535` OR and the `safety_is_safe` poll/FailClosed path stay byte-for-byte (W5). The two behavior changes are **strictly no-less-safe** — they only remove redundant unsafe assertions Dart was making; the hardware OR term is never removed.
- **Tests that must stay green:** native `test_weather_unsafe_trigger`, `test_weather_unsafe_trigger_honours_dart_verdict` (`triggers.rs:2284-2347`); `SafeRigService` enforcement tests; executor WeatherUnsafe recovery-re-check tests (`mod.rs:6135-6155`).
- **Test that must CHANGE (intended):** `weather_safety_verdict_push_test.dart:124-139` (`false` → `None` on disabled). Flag explicitly in the PR as a deliberate contract change.
- **New tests:** (a) disabled/snoozed/failOpen/warnOnly each push `None`, never `false`; (b) Dart-threshold-only unsafe + hardware-safe → trigger fires AND recovery does **not** clear while verdict is `Some(true)`; (c) fail-mode truth-table parity (Dart == Rust); (d) staleness guard releases a stale verdict after the configured interval.
- **Mitigation for the secondary risk** (recovery tightening keeps a sequence paused longer if the verdict goes stale): the existing auto-resume path (`weather_safety_provider.dart:670-698`) re-pushes `Some(false)`/`None` on clear, plus the staleness guard above.

### Effort / risk

**Effort: medium. Risk: LOW (safety-monotone by construction).** Every change can only **add** unsafe or **abstain** — it cannot make the system declare SAFE where it previously aborted. The only watch item is the paused-longer recovery edge, mitigated by the staleness guard + auto-resume re-push.

---

## Subsystem 3 — Notifications (triple feed + config bypass + dead-when-idle)

### Current tangle

- **NotificationRouter** (`notification_router.dart:36-613`) — intended single router: classifies the event stream, fans out to 8 transports via the routing matrix (per-category transport set + min-severity + rate-limit + debounce). AUTHORITATIVE by design.
- **PushNotificationService** (`push_notification_service.dart:109-476`) — over-wired: owns its **own** `start()/_handleEvent` subscription (`:140-219`), classifying a different event subset under its own `PushNotificationConfig`, and is also driven by the router's `SystemPushTransport` and the dashboard bridge → **triple feed** to phones.
- **RunDashboard critical-events bridge** (`run_dashboard_providers.dart:589-679`) — does banner + toast + audible (correct, in-app) **and** `enqueueCriticalNotification` gated only on `settings.pushCriticalAlerts`, bypassing the matrix AND `PushNotificationConfig` per-event toggles.
- **NotificationService (legacy)** (`notification_service.dart:59-431`) — parallel Discord/Pushover from `AppSettingsState`, still called from 5 live sites; bypasses the router entirely.
- **UiNotificationNotifier** (`ui_notification_provider.dart:31-147`) — the legitimate shared in-app terminal sink. Keep.
- Two settings pages (`notification_settings.dart` legacy vs `notification_routing_settings.dart` router) configure the **same channels** into **different stores**.

**Why a senior reviewer rejects it:** a single critical event can page a phone up to 3×; per-event mobile-push toggles silently don't work for critical events (the bridge gates only on `pushCriticalAlerts`, and `enqueueCriticalNotification` checks only `_config.enabled`); Discord configured on one page does nothing for the other path; legacy call sites never reach email/Telegram/webhook/MQTT or rate-limiting; and the router is **dead unless a sequence is running** (mounted on first executor read), so idle weather/equipment failures never reach external channels.

### Chosen unification (lowest-risk re-wire, NOT delete)

**NotificationRouter becomes the single authoritative dispatcher; every other system becomes a transport (output sink) or a thin caller of `router.route()`. Keep working services, re-wire them.**

- **Authoritative component:** NotificationRouter.
- **PushNotificationService → output transport only.** Retire its own classifier/subscription (don't call `start()` from its provider); keep it purely as the WebSocket/LAN broadcaster behind `SystemPushTransport`.
- **Dashboard bridge:** keep banner/toast/audible (in-app, correct); change only its **push** call to `router.route(category, ctx, severity: critical)` so `SystemPushTransport` (matrix-governed) is the single PushNotification producer.
- **Legacy NotificationService:** re-point its 5 call sites at `router.route()`; keep it only as the impl behind the test-send buttons until the UI merges, then delete.
- **Config unify:** migrate `AppSettingsState.discordWebhook/pushoverKey` into the router's transport configs (one-shot, like `notification_secrets_migrated_v1`); make the legacy settings page a read-only redirect onto routing settings.
- **Mount eagerly:** add `ref.watch(notificationRouterProvider)` in the desktop+mobile app shell so it always classifies/dispatches (Provider is cached → single instance, no double-subscribe with the executor's later read).

| Component | Becomes |
|---|---|
| NotificationRouter | Authoritative dispatcher (mounted eagerly) |
| PushNotificationService | Output transport (WebSocket fan-out) — classifier/subscription retired |
| Dashboard bridge | In-app responsibilities kept; push routed via `router.route()` |
| Legacy NotificationService | Caller of `router.route()`; test-send shim → eventually deleted |
| UiNotificationNotifier | Unchanged terminal in-app sink |
| Legacy settings page | Read-only redirect onto routing settings |

### Concrete file-level change list

1. `apps/desktop/lib/desktop_app_bootstrap.dart` (+ mobile shell) — `ref.watch(notificationRouterProvider)` at app start (fixes dead-when-idle).
2. `providers/push_notification_provider.dart` — stop calling `start()`; service becomes broadcaster-only.
3. `services/push_notification_service.dart` — retire classifier/own subscription (keep `enqueueCriticalNotification` as the transport entry behind `SystemPushTransport`, or have the transport call the broadcast directly).
4. `screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart` — replace the `enqueueCriticalNotification` call with `router.route(..., severity: critical)`; keep banner/toast/audible untouched.
5. `services/imaging_service.dart`, `services/device_reconnect_coordinator.dart`, `providers/meridian_flip_provider.dart` — re-point the 5 legacy call sites at `router.route()` with the right category.
6. `services/notification_service.dart` — reduce to test-send shim (+ migration source).
7. `models/notification/notification_categories.dart` — make `_criticalByDefault` (or the matrix) the single criticality source the dashboard derives from.
8. `services/notification/transports/system_push_transport.dart` — single PushNotification producer.
9. `screens/settings/widgets/notification_settings.dart` — read-only redirect.
10. (Shared-core) extract ONE event→(category, context, severity) classifier consumed by router + dashboard bridge (root cause of disagreement); render copy via router templates only; share one audible player (`NotificationService._defaultPlayAlertSound` ↔ `CriticalAlertPlayer.play`).

### Regression guards

- **Preserve-exactly:** critical alerts (sequenceFailed, weatherUnsafe, guidingLost, exposureFailed, equipmentDisconnected, recoveryGaveUp, diskSpaceLow, autofocusFailed) still fire **exactly once** to the phone; in-app banner/toast still appear; audible bell still plays under `audibleAlertsOnCritical`.
- **Primary risk + guard:** collapsing the triple feed could drop a path that was the *only* one classifying some event (the bridge today catches FITS-save-failure-class events the PushNotificationService handlers miss — that's *why* `enqueueCriticalNotification` exists). Guard: route the bridge through `router.route(severity: critical)` so the matrix's `systemPush` still fires for those; keep banner/toast/audible untouched.
- **Secondary:** eager mount must not double-subscribe — Provider caching guarantees one instance; verify with a "single transport subscription" test.
- **Tertiary:** router fan-out must remain fire-and-forget (`Future.microtask`) so a slow transport can't stall the executor — preserve `_dispatch` semantics.
- **Tests that must stay green:** `notification_router_test.dart`, `notification_template_test.dart`, `notification_categories_test.dart`, `notification_service_sound_test.dart`; `critical_events_bridge_test.dart` (**the canary** for audible + push — extend it to assert exactly-once phone push post-consolidation); `sequence_executor_lifecycle_test.dart`; `apps/mobile/test/services/mobile_event_notifier_test.dart` + `mobile_remote_e2e_test.dart`.
- **New test:** a single backend critical event yields **exactly one** `PushNotification` on `pushNotificationStreamProvider`.

### Effort / risk

**Effort: large. Risk: MEDIUM.** Most steps are additive/re-wiring, but the triple-feed collapse touches the exactly-once paging path on an unattended night and the classifier coverage differs across the three feeds. The exactly-once canary test must be written **before** the collapse, not after.

---

## Overall sequencing

Do these as **independent, separately-gated PRs**, lowest-risk first. Each is self-contained; none blocks another.

1. **Subsystem 2, step (3) — push `None` not `false` (the landmine).** Smallest, safety-monotone, highest value-per-risk. Land first; it makes the weather channel un-weakenable before any other refactor touches it.
2. **Subsystem 1 — Planner read-only preview.** Additive pure method + UI re-label; autopilot untouched.
3. **Subsystem 2, steps (2) + (4) — de-duplicate evaluation + recovery tightening + shared threshold/fail-mode core.** After the abstain channel is in.
4. **Subsystem 3 — staged:** (a) eager mount; (b) write the exactly-once canary; (c) collapse the triple feed; (d) re-point legacy call sites; (e) config migration + settings redirect. Each sub-step is its own commit behind the canary.
5. **(Deferred / optional) shared-core extractions** — `CatalogScoringCore`, shared horizon evaluator + cross-language fixture, `MoonEphemeris` single convention, single night-window derivation. Pure refactors with parity fixtures; do only when there's slack, never coupled to a behavior change.

Re-run the full gate battery (`skotiq_core`, planetarium parity, `cargo test -p skotiq_sequencer`, app + mobile suites) after each PR, independently — do not trust workflow self-report.

---

## EXECUTIVE SUMMARY

**Subsystem 1 — Target selection:** Make the Planner a **read-only preview of the live SchedulerEngine** (new pure `previewRanking`); re-scope TargetSuggestionService to advisory night-outlook; leave the Rust node on its parity-locked planetarium core. **Risk: LOW** (additive pure method, zero autopilot math change).

**Subsystem 2 — Weather evaluators:** Keep Dart as verdict authority for API/threshold/dawn and Rust as the hardware-boolean authority, joined by the existing OR; **stop double-counting the monitor in Dart and push `None` (abstain) instead of `false`** to close the suppress-a-hardware-abort landmine; tighten the recovery re-check. **Risk: LOW** (every change is safety-monotone — can only add-unsafe or abstain).

**Subsystem 3 — Notifications:** Make **NotificationRouter the single dispatcher** (mount it eagerly), demote PushNotificationService to an output transport, route the dashboard bridge's phone-push through the router, re-point the 5 legacy call sites, unify config. **Risk: MEDIUM** (touches the unattended-night exactly-once paging path; gate behind a new exactly-once canary test before collapsing the triple feed).

**Overall recommendation:**

- **GO now — Subsystem 2 abstain-channel fix (`None` not `false`).** Tiny, safety-monotone, removes a real latent landmine guarding the just-fixed W5 gate. Highest value-per-risk in the whole plan.
- **GO now — Subsystem 1 Planner read-only preview.** Low risk, additive, and it fixes the most user-visible disagreement (the dusk "the preview said X, the rig imaged Y" confusion) without touching one line of autopilot decision math.
- **CAUTION / phase it — Subsystem 3.** Worth doing (3× phantom pages and silently-broken per-event toggles are real defects), but it's **large** and it sits on the unattended-night exactly-once paging path. Do **not** big-bang it: land the eager-mount + the exactly-once canary first, then collapse the feeds in small reversible commits. If schedule pressure forces a cut, ship only the **eager mount** (fixes dead-when-idle external alerts, near-zero risk) and **defer the triple-feed collapse** behind the canary.
- **DEFER (shared-core seam, not now) — the remaining Subsystem 1/2 duplications** (CatalogScoringCore, shared horizon/moon/night-window, fail-mode truth table). These are correctness-footgun cleanups but **high-effort, low-incremental-gain** once the authoritative seams above exist. Leave a documented shared-core seam (the parity fixtures already enforce lockstep) and extract opportunistically. Do **not** attempt to merge the engine's bespoke formula with the planetarium five-axis core — the axes don't correspond and the parity contract is worth more than formula unity.

**Bottom line:** GO on Subsystems 1 and 2 now (low-risk, high-value, W1–W5 provably preserved). CAUTION on Subsystem 3 — do it phased behind the exactly-once canary, or ship only the eager-mount slice and defer the feed collapse. Defer the pure shared-core extractions to opportunistic follow-ups.
