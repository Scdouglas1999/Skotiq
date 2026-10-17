# Automation & Sequencing Streamlining Plan

_Read-only audit, 2026-06-22. 10 automation subsystems mapped by parallel agents, cross-compared, and synthesized into a unification plan. No code changed._

---

# Streamlining Plan: Unifying Automatic Imaging Under One Roof

## Executive Summary

Skotiq already has exactly one execution engine (native Rust sequencer) and one authoring model (the 36-subtype `SequenceNode` tree); everything else is a *generator*, a *control veneer*, or a *target scorer* layered on top. The fragmentation a user feels is not architectural depth — it is **five entry points into one engine** and **three independent target scorers with non-shared weights**, plus two genuinely duplicated sub-engines (flat calibration and the focus-temperature model) straddling the Dart/Rust boundary. This plan adopts a single **Decide → Plan → Build → Execute → Watch** mental model, maps every subsystem onto exactly one layer, and names **Smart Night ("Plan Tonight, one tap")** as the single front door for "image automatically tonight." It establishes the **`targets` table as the source of truth for "what we image next"** and the **active `SequenceExecutor` run (loaded sequence + native run state) as the source of truth for "the active plan."** The riskiest merges are the three-scorer collapse and the shared-editor-slot contention (which the autopilot currently clobbers with `discardUnsaved: true`); both have master/slave sync implications and are sequenced last. Phase 0 is pure dead-code removal with zero behavior change, so the maintainer can start today without risk.

---

## 1. The Unifying Pipeline

Every automation subsystem belongs to **exactly one** of five layers. The layers are a strict left-to-right flow; each layer's only output is the next layer's input.

```
DECIDE            PLAN                BUILD               EXECUTE            WATCH
"what is worth    "lay it out across  "emit the           "run the one       "keep imaging
 imaging?"         the night"          SequenceNode tree"  engine"            safely, react"
──────────        ──────────────      ─────────────────   ───────────────    ────────────────
target scoring    whole-night         sequencer model     native Rust        in-run triggers
+ selection       scheduling          (the ONE authoring  SequenceExecutor   (dither/flip/
                  (overhead, dark      surface; all         (.start/pause/    recovery/weather/
                  window, ordering)    generators feed it)  resume/skip)       disk/checkpoint)
                                                                               + refocus triggering
                                                                               + run control veneer
```

### Subsystem → Layer (each maps to exactly one)

| Subsystem | Layer | Role in that layer |
|---|---|---|
| **scheduler-autopilot** (`SchedulerEngine`) | **DECIDE** | The authoritative live "what now" scorer + selector (the loop, hysteresis, dawn-park). |
| **planner** target scoring (`TargetScoringService`) | **DECIDE** | Advisory whole-night ranking surface (read-only "night outlook"). |
| **`TargetSchedulerNode`** (Rust `decision.rs`) | **DECIDE** | In-sequence adaptive re-pick (a *runtime embodiment* of the DECIDE engine, not a separate one — to be unified, see §6). |
| **smart-night** | **PLAN** | Composes the whole-night layout (dark window, overhead, exposure math, target ordering). |
| **planner** projects/forecast/session-optimizer | **PLAN** | Multi-night campaign progress + 7-night forecast feeding PLAN decisions. |
| **mosaic** (geometry + project) | **PLAN→BUILD** | Tiling math is PLAN; panel-tree expansion is a BUILD generator. |
| **sequencer model** (`SequenceNode`, editor, serializers) | **BUILD** | The sole authoring model. Every generator emits into it. |
| **flat-wizard** | **BUILD** | A calibration-subtree generator + a calibration *service* (engine dup to resolve). |
| **native Rust `SequenceExecutor`** | **EXECUTE** | The one and only run engine. |
| **run-surface (cockpit)** | **WATCH** | Pure control/monitor veneer over the EXECUTE engine — owns nothing. |
| **in-run-automation-triggers** | **WATCH** | Real-time hazard/correction reactions (Rust-owned, Dart config + mirroring). |
| **autofocus / focus model** | **DECIDE-of-focus (WATCH)** | Refocus *triggering* is WATCH; model *learning* is a distinct concern folded under WATCH. |

> **Key insight:** smart-night, scheduler, mosaic, and flat-wizard are **not four products** — they are four **generators** that all hand a `Sequence` to `currentSequenceProvider` + `sequenceExecutorProvider`. None can execute. Treating them as BUILD-stage front-ends, not parallel engines, is the whole reframe.

---

## 2. The Single Recommended Entry Point

### "Image automatically tonight" → **Smart Night ("Plan Tonight")**

A user who wants the rig to image automatically tonight should tap **one** button — **Smart Night** — and get a complete, editable, runnable whole-night plan. It is the only subsystem that already does end-to-end PLAN+BUILD from a single tap (target selection → dark-window scheduling → per-filter exposure math → full cool→align→guide→focus→expose→flip→flats→park tree), and crucially it produces an **inspectable `SequenceNode` tree** the user can review and tweak before running. That review-then-run property is what makes it the right default front door rather than the headless autopilot.

### Disposition of the other "start automatic imaging" entry points

| Entry point | Disposition | What happens |
|---|---|---|
| **Smart Night wizard** | **PROMOTE → the front door** | Becomes the single "Plan Tonight" affordance. Consolidate its three reachable surfaces (dashboard cards, sequencer toolbar, planner Projects tab) to one canonical launch + contextual deep-links. |
| **Scheduler autopilot** | **DEMOTE → power-user "Unattended autopilot" mode** | Keep for the operator who wants continuous re-evaluation (catalog-wide, hysteresis, dawn-park). Reframed in UI as "let it run itself all night and adapt," explicitly distinct from Smart Night's "build me a plan I can see." Stop having it silently clobber the editor (see §5). |
| **Dashboard cockpit "Start"** | **KEEP as WATCH veneer** | It does not author anything — it runs whatever is loaded. Keep as the at-a-glance start/steer surface. No change to its role. |
| **Sequencer playback bar** | **KEEP as power-user manual run** | The hand-authoring path for users who build trees by hand. Keep. |
| **Headless `/api/sequencer/start`** | **KEEP as the one API** | Canonical automation API. |
| **Headless `/api/sequences/start` alias** | **RETIRE** | Confirmed redundant duplicate (`sequencer_routes.dart:29`). Collapse onto `/api/sequencer/*`. |

The mental shift presented to the user: **Smart Night = "plan my night for me (I can see and edit it)." Autopilot = "run unattended and adapt." Sequencer = "I'll build it myself."** Three intents, one engine, one default.

---

## 3. Consolidation Table

| System | Disposition | Justification |
|---|---|---|
| Native Rust `SequenceExecutor` | **KEEP — EXECUTE (the spine)** | The one real engine. Everything funnels here. |
| `SequenceNode` model + editor | **KEEP — BUILD (the spine)** | The one authoring model; sole owner of the 36 sealed subtypes. |
| In-Dart legacy executor branch + `useNativeExecution` | **RETIRE** | Confirmed dead: `start()` logs *"Legacy Dart sequencer path is deprecated; forcing backend executor"* and always routes native (`sequence_executor.dart:465–472`). The flag is vestigial; delete branch + setting. |
| smart-night | **PROMOTE — PLAN front door** | Only end-to-end one-tap whole-night generator with an editable result. Becomes "Plan Tonight." |
| scheduler-autopilot (`SchedulerEngine`) | **DEMOTE → power-user "Unattended autopilot"; KEEP — DECIDE** | Real, well-wired closed loop. Valuable for hands-off nights but not the default; must stop clobbering the editor slot. |
| planner `TargetScoringService` (whole-night) | **MERGE into a shared DECIDE scoring contract; KEEP as advisory render** | Already demoted to read-only "Night Outlook"; should share the weight model with the autopilot rather than carry a parallel 5-weight set. |
| `TargetSchedulerNode` / Rust `decision.rs` | **MERGE into the shared DECIDE scorer** | **Confirmed LIVE** (emits real `scheduler_pick` decisions, `registry.rs:181`). It is a *third* autopilot with its own weights; unify weights/contract, do not retire. |
| planner screen (recommendation/projects/forecast) | **KEEP — PLAN; consolidate "Plan Tonight" buttons** | The whole-night human browse/campaign surface. Keep, but route its "plan tonight" affordance into Smart Night (one front door). |
| `scheduler_screen.dart` (standalone shell) | **RETIRE** | Self-documented unreachable (`scheduler_screen.dart:9–12`); `/scheduler` redirects to `/planner?tab=scheduler`. Keep only the leaf widgets the planner tab reuses. |
| mosaic geometry + durable project + stitch | **KEEP — PLAN/BUILD; consolidate generators** | Stitch (`api_stitch_mosaic`) is unique and stays. Collapse the **three** panel generators (`MosaicService`, planetarium `MosaicPlanner`, static template) to one. |
| Framing "Export-to-Targets" | **RETIRE (dead-end) or REWIRE to Create-Project** | Writes plain `targets` rows, creates no project/sequence — diverges from the wizard path. Either delete or point it at the durable-project path. |
| Rust `crate::mosaic` wizard scaffolding | **RETIRE (dormant)** | Forward-compat scaffolding; canonical path is Dart static-expansion; `wizard_states['mosaic']` slot unused. |
| Static "Mosaic Multi-Panel" template | **RETIRE** | Frozen 2-panel demo; a third geometry path. |
| flat-wizard (Dart `FlatWizardService`) **and** native `flat_wizard/mod.rs` | **MERGE — one calibration engine** | Two independent ADU-binary-search engines + duplicated `calculateNextExposure`. Pick one convergence implementation; the other path calls it. |
| `FlatPanelLocation` selector | **RETIRE** | Cosmetic dead code — never affects calibration/capture. |
| autofocus refocus triggers (Rust `triggers.rs`) | **KEEP — WATCH (authoritative)** | The real in-run refocus owner. |
| `FocusModelService` (legacy JSON) vs `PredictiveAfService` (DB) | **MERGE — one focus-temp model** | Two models that can disagree; `/api/focus-model/*` is wired to the legacy one while the run uses predictive. Route the HTTP surface to the predictive DB model the run actually consults. |
| run-surface (cockpit) | **KEEP — WATCH veneer** | Owns no engine; thin control/monitor over `SequenceExecutor`. |
| in-run-automation-triggers | **KEEP — WATCH (Rust-owned)** | The real-time safety/correction loop. Consolidate the **3-store safety config** (`settingsDao`/`weatherSettingsDao`/`appSettings`) into one. |
| Standalone meridian/disk watchdogs | **KEEP — WATCH (no-run-active scope)** | Clean hand-off to Rust when a sequence runs. Dedupe the HA/LST math (acknowledged copy of `scheduler_engine._localSiderealTime`). |
| `filteredSuggestionsProvider` | **RETIRE** | Legacy dup of `plannerFilteredSuggestionsProvider`; UI uses the planner variant. |
| `SessionOptimizerService.analyze()` retrospective | **DEMOTE → move to post-session subsystem** | Misplaced in the Plan-Tonight service; unused by planner UI. |
| `/api/sequences/*` alias family | **RETIRE** | Redundant with `/api/sequencer/*`. |
| `latitudeSign()` stub | **FIX (not consolidation)** | Hardcoded `return true` → southern-hemisphere correctness bug (`strategy_helpers.dart:303`). |

---

## 4. Single Sources of Truth

| Question | Single source of truth | Why |
|---|---|---|
| **"What do we image next?"** | The **`targets` table** (optionally INNER-JOINed to `project_targets`), as loaded by `SchedulerCandidateLoader`. | Confirmed the scheduler's real candidate source — *not* observing lists (those are curated marker/pin lists that never feed the scheduler). The canonical flow is `observing list → (manual) → targets table → DECIDE`. All three scorers must read this one candidate set. |
| **"What is the active plan?"** | The **loaded `Sequence` (`currentSequenceProvider`) + the native `SequenceExecutor` run state**. | One engine, one loaded tree. Cockpit, playback bar, headless, and autopilot all read/drive this single slot. The active run *is* the active plan — there is no second representation. |

**Corollary fix:** because the active plan is a *single shared slot*, two writers (the human editor and the autopilot) currently collide. The autopilot calls `loadSequence(sequence, discardUnsaved: true)` (`scheduler_provider.dart:136`), silently discarding the user's unsaved editor work. Establishing the slot as the source of truth means giving the autopilot its **own** sequence slot (or an explicit ownership lock) so "the active plan" has a single, non-clobbering writer at a time.

---

## 5. Riskiest Merges & Master/Slave Implications

The architecture is **master/slave**: a Windows host runs the real engine/DB; a Linux slave mirrors over `NetworkBackend` and renders read-only previews of the host's decisions. Any merge that changes *what the host decides* or *where state lives* has sync consequences.

1. **Collapsing the three DECIDE scorers (highest risk).**
   - **What breaks:** the in-sequence `TargetSchedulerNode` runs *inside Rust* with its own weight set; the live `SchedulerEngine` runs in Dart; the planner outlook runs in the planetarium package. Unifying the weight model means a **Dart↔Rust contract change** — exactly the drift hazard the codebase already warns about (`TriggerType` modeled 8 of 17 Rust variants). Get the wire serialization wrong and either the autopilot or the in-sequence picker silently scores differently.
   - **Master/slave:** the slave's `/preview` banner mirrors the **host's** pick. If the shared scorer changes scoring on the host but the slave's mirrored candidate set or weight snapshot lags, the slave shows a stale/wrong "what runs tonight." The scoring contract and the weight payload must version together and ship to the slave atomically.
   - **Mitigation:** introduce the shared scoring contract behind the *existing* outputs first (make all three call it, asserting identical results via parity tests) before changing any weights. Pin Dart↔Rust enums/weights with parity tests, as already done for the safety truth table.

2. **The shared-editor-slot / `discardUnsaved: true` fix (high risk, master/slave).**
   - **What breaks:** the single `currentSequenceProvider` slot is mirrored to the slave. If the autopilot gets its own slot, the slave's mirror must learn there are now *two* possible "active plans" (manual vs autopilot) and render the right one. Done naively, the slave shows the wrong run.
   - **Mitigation:** model an explicit "active plan owner" enum (manual | smart-night | autopilot | mosaic) in the mirrored state so both host and slave agree on which slot is live.

3. **Merging the two flat-calibration engines (medium risk).**
   - **What breaks:** the Dart `FlatWizardService` serves the standalone screen + headless `/api/flat-wizard/*`; the Rust engine serves the in-sequence node. Picking one convergence path risks subtly changing converged exposures. Flats are calibration data — a regression silently corrupts users' libraries.
   - **Master/slave:** flat history is recorded to the host DB (`recordFlat` → remote master). A convergence change on the host shifts the suggested starting exposures the slave reads. Low sync risk (read-only mirror) but real calibration risk.
   - **Mitigation:** choose the Rust engine as canonical (it already runs the in-sequence path with the cover/panel device dance), make Dart delegate, and snapshot-test converged exposures against the current Dart output before cutover.

4. **Merging the two focus-temp models (medium risk).**
   - **What breaks:** `/api/focus-model/*` (incl. `should-refocus`) is wired to the **legacy** `FocusModelService`; the run uses **predictive** DB. Re-routing the HTTP surface to predictive changes the answer headless clients (the slave) get.
   - **Master/slave:** the slave queries the host's `should-refocus`. After the merge it gets the predictive answer — which is *correct* (matches the run) but is a behavior change for any client that cached the legacy answer.
   - **Mitigation:** route HTTP to predictive, keep the legacy scatter-plot read path until the equipment plot is re-pointed.

Lower-risk merges (dead-shell removals, alias retirement, single-store safety config, geometry-generator collapse) have **no master/slave sync surface** and are safe early.

---

## 6. Phased, Low-Risk Sequencing

**No code is written here.** Each phase is independently shippable and ordered by ascending blast radius.

### Phase 0 — Dead-code removal, zero behavior change (start today)
- Delete the in-Dart legacy executor branch + `useNativeExecution` setting (already always-native).
- Retire `scheduler_screen.dart` shell (keep reused leaf widgets); confirm `/scheduler` redirect stands.
- Retire the `/api/sequences/*` alias family; keep `/api/sequencer/*`.
- Remove `filteredSuggestionsProvider`, the `FlatPanelLocation` selector, the static "Mosaic Multi-Panel" template, the dormant Rust `crate::mosaic` wizard scaffolding.
- Fix `latitudeSign()` (southern-hemisphere) and the stale "32 subtypes" comment.
- **Risk: none.** No mirrored state changes; pure deletion of unreachable paths.

### Phase 1 — Single front door + entry-point consolidation (UI/routing only)
- Make **Smart Night** the canonical "Plan Tonight" affordance; collapse its three launch surfaces to one + contextual deep-links.
- Relabel the scheduler as the power-user **"Unattended autopilot"** mode; consolidate the three "plan tonight"-style buttons (planner recommendation, Smart Night, autopilot) into one funnel with three clearly-named intents.
- Either retire or rewire Framing "Export-to-Targets" onto the durable mosaic-project path.
- **Risk: low.** No engine/scoring change; mirrored run state untouched.

### Phase 2 — Single-store consolidation of split config (no decision change)
- Unify the **3-store safety config** (`settingsDao`/`weatherSettingsDao`/`appSettings`) into one store with one mirrored payload.
- Dedupe the HA/LST math shared by the standalone meridian monitor and `scheduler_engine`.
- Collapse the **three mosaic panel generators** to the canonical `MosaicService.generatePanels`.
- **Risk: low–medium.** Behavior-preserving; verify mirrored safety state still serializes identically.

### Phase 3 — Sub-engine merges (behavior-preserving, parity-tested)
- Merge the two **flat-calibration engines** onto the Rust canonical path; snapshot converged exposures.
- Merge the two **focus-temp models**; route `/api/focus-model/*` to predictive DB.
- **Risk: medium.** Calibration/refocus correctness; gated by parity/snapshot tests before cutover.

### Phase 4 — DECIDE unification + active-plan ownership (deepest, last)
- Introduce a **shared DECIDE scoring contract**; make `SchedulerEngine`, planner outlook, and the in-sequence `TargetSchedulerNode` all call it. Land it behind existing outputs first (parity tests asserting identical picks), *then* unify weights.
- Pin the Dart↔Rust weight/enum contract with parity tests (as the safety truth table is).
- Give the autopilot its **own sequence slot** + an explicit **"active plan owner"** enum in the mirrored state; remove `discardUnsaved: true` clobbering.
- **Risk: high.** Touches the Dart↔Rust boundary and master/slave mirroring. Ship last, behind parity gates.

---

### Opinionated bottom line
The system is closer to unified than it looks — there is already one engine and one model. The work is **90% subtraction** (Phases 0–2: delete dead shells, pick one front door, collapse split stores) and **10% careful merging** (Phases 3–4: two duplicated sub-engines and the three-scorer DECIDE collapse). Do the subtraction now; gate the two real merges behind parity tests because they cross the Dart/Rust and host/slave boundaries. The single most valuable deep change is unifying the three target scorers behind one scoring contract — that is the actual architectural defect, and the live (not dead) in-sequence `TargetSchedulerNode` is the hidden third party that makes it urgent.

---

# Appendix: Overlap & Fragmentation Analysis

# OVERLAP & FRAGMENTATION ANALYSIS — Automatic Imaging/Sequencing Subsystems

## Executive frame

There is **one real execution engine** (native Rust sequencer) and **one real authoring model** (the 36-subtype `SequenceNode` tree). Almost everything else is either (a) a *generator* that emits that node tree, (b) a *control/monitor veneer* over the one `SequenceExecutor`, or (c) a *scorer* that picks targets. The fragmentation is concentrated in two places: **target selection (three+ competing scorers)** and **"start automated imaging" (five+ entry points into one engine)**. Calibration (flats) and refocus carry **genuine engine duplication** (Dart vs Rust).

---

## 1. Responsibility Matrix

Legend: **OWNS** = authoritative implementation · **emits→** = generates nodes for the sequencer · **drives** = remote-controls the shared engine · **DUP** = true duplication · **layer** = healthy layering.

| Capability | Owner(s) | Also claims it | Verdict |
|---|---|---|---|
| **Pick what to image (target selection)** | `scheduler-autopilot` (`SchedulerEngine._scoreCandidate`, instantaneous "right now"); `planner` (`TargetScoringService.scoreTargetForNight`, whole-night advisory); native `TargetSchedulerNode` (`decision.rs`, in-sequence runtime pick) | `smart-night` (ranks via `TargetSuggestionService`) | **TRUE DUPLICATION** — 3 independent scorers with 3 different weight sets (see §3). Partially mitigated: planner now *renders* the scheduler's pick read-only. |
| **Build/author a sequence (node tree)** | `sequencer` (`SequenceNode` model + editor) — sole owner | smart-night, mosaic, flat-wizard, scheduler all **emit→** trees | **Healthy layering.** One model, many generators. |
| **Score/rank targets for display** | `planner` (`SessionOptimizerService`, `target_scoring.dart`) | scheduler `target_score_row`, smart-night preview | Overlapping but mostly layered (advisory vs autopilot). |
| **Trigger refocus** | native Rust `triggers.rs` (Temp/Filter/Interval/HFR) — authoritative in-run | `FocusModelService` (legacy JSON, feeds ALL `/api/focus-model/*`) vs `PredictiveAfService` (DB, mirrors Rust) | **TRUE DUPLICATION** — two focus-temp models that can disagree; HTTP gate wired to legacy, run wired to predictive. |
| **Dither** | native `dither.rs` (in-run) | Dart config injection; `/api/phd2/dither`, `/api/guider/dither` (manual) | Layer (one evaluator, manual overrides). |
| **Meridian flip** | native `meridian_flip_executor.rs` (in-sequence) | Dart `MeridianFlipStandaloneMonitor` (only when NO sequence runs) | **Mostly layer** — clean hand-off, but HA/LST math is a **DUP** (acknowledged copy of `scheduler_engine._localSiderealTime`); standalone monitor can't evaluate 2 of 4 trigger types (capability gap). |
| **Capture calibration (flats)** | `flat-wizard` Dart `FlatWizardService` **and** native `flat_wizard/mod.rs` | standalone screen captures directly via `cameraStartExposure`; dialog injects nodes; native node captures in-run | **TRUE DUPLICATION** — two ADU-binary-search engines + duplicated exposure math (`calculateNextExposure` exists in both `FlatWizardService` and `FlatExposureCalculator`). Three capture paths. |
| **Capture calibration (darks)** | sequencer Dark/Exposure nodes only | `dark_library_service` (match/store only) | No auto-dark counterpart — asymmetry, not duplication. |
| **Start/monitor a run** | `SequenceExecutor.start()` (single engine) | `run-surface` cockpit, sequencer playback bar, scheduler autopilot, headless `/api/sequencer/start`, **and `/api/sequences/start` alias** | **Layer w/ UI sprawl** — one engine, 5 triggers (see §2). |
| **Recommend tonight** | `planner` (human browse-and-decide) vs `smart-night` (one-tap whole-night sequence) vs `scheduler` (autonomous loop) | dashboard cards surface all three | **Overlapping affordances** — three "plan tonight" buttons (see §2). |
| **Mosaic tiling** | `mosaic` `MosaicService.generatePanels` | `MosaicPlanner` (planetarium preview), static template | **DUP geometry** — 3 panel generators. |

---

## 2. User-facing confusion: "How many places can I start automated imaging?"

**At least five distinct entry surfaces, all funneling into the same `SequenceExecutor.start()`:**

1. **Dashboard cockpit** (`cockpit_run_controls.dart`) — "Start" on the home screen.
2. **Sequencer screen playback bar** (`MobilePlaybackBar` / `sequence_toolbar.dart`).
3. **Scheduler autopilot** (Planner → Schedule tab → Start) — but this *generates its own sequence and dispatches it*, overwriting the editor slot.
4. **Smart Night wizard** (reachable from sequencer toolbar, dashboard `smart_night_prompt_card`/`tonight_card`/`cockpit_standby`, AND planner Projects tab) — one tap, auto-builds and auto-starts.
5. **Headless** `POST /api/sequencer/start` **and** the duplicate thin alias `POST /api/sequences/start` (confirmed `sequencer_routes.dart:29`).

**Where a user cannot tell which to use:**

- **"Plan Tonight" means three different things.** The Planner Recommendation tab (browse & decide), the Smart Night "Plan tonight" wizard (auto-build a whole-night sequence), and the Scheduler "Start" (continuous autopilot) all answer "what do I image tonight?" with different mechanics and different scorers. A user on the dashboard sees a `tonight_card`, a `smart_night_prompt_card`, *and* an autopilot preview banner — three roads to "tonight."
- **Smart Night vs Scheduler do the opposite thing under one mental model.** Smart Night produces a *static whole-night tree* and does NOT use the autopilot's W1–W5 math; the Scheduler produces a *live re-evaluated pick*. Both are "automatic," reachable from the same Planner Projects tab, and neither label tells the user it's static-vs-dynamic.
- **Mosaic has three start paths with divergent outcomes** (§4): wizard "Generate" (loads sequence), wizard "Create Project" (durable + routes to `/mosaic/:id`), and Framing "Export-to-Targets" (a dead-end that writes plain `targets` rows, no sequence, no project).
- **Flat capture has three execution paths** (standalone screen direct-capture, sequencer dialog node-injection, in-sequence native node) doing the same conceptual job.

---

## 3. Conflicting sources of truth

**A. THREE target scorers can each "pick the next target," with non-shared weights:**

1. `SchedulerEngine._scoreCandidate` — 6 weighted soft factors + hard gates + hysteresis (live "right now").
2. `TargetScoringService.scoreTargetForNight` (planetarium pkg) — 5-weight whole-night (planner outlook).
3. **`TargetSchedulerNode` → native `decision.rs`** — its own weight set (`altitudeWeight`/`moonDistanceWeight`/`transitProximityWeight`/`darknessWeight`/`airmassWeight`), runs *inside* a sequence and emits real `scheduler_pick` decisions.

> **Profile correction (load-bearing):** The scheduler-autopilot profile asserts *"I found no sequence_executor node-handler that runs [TargetSchedulerNode] selection at runtime, so it reads as a parallel/legacy in-sequence scheduler concept."* **This is false.** The Rust executor implements `NodeType::TargetScheduler` as a live container variant: `registry.rs:181` (logic dispatch), `decision.rs` emits `DecisionCategory::SchedulerPick` ("TargetScheduler picked M27 (78/100)"), `context.rs` holds the mid-target recompute/adaptive-swap state, and `runtime.rs`/`logic/mod.rs` drive it. Smart Night deliberately emits this node for ≥N-target nights. So `TargetSchedulerNode` is **not** dead — it is a *third, fully-live* target picker with its own weights, which makes the duplication **worse**, not benign. The Dart-side preview computing scores through `planetarium.ScoringWeights` is yet a *fourth* code path for the *same node's* preview.

The partial unification (planner banner read-only mirrors the scheduler) only reconciles #1 vs #2 on *one screen*. #3 (the in-sequence node) is an independent autopilot whose weights nothing keeps in lockstep with #1.

**B. The single shared editor sequence slot is a contention point.** Scheduler dispatch calls `currentNotifier.loadSequence(sequence, discardUnsaved: true)` (`scheduler_provider.dart:136`) — starting the autopilot **silently discards the user's unsaved in-editor sequence**. Smart Night, mosaic, and the manual editor all write the same `currentSequenceProvider`. Two actors (autopilot + human) compete for one slot.

**C. Two focus-temperature models disagree by design:** legacy `FocusModelService` (feeds *all* `/api/focus-model/*` incl. `should-refocus`/`predict`) vs DB-backed `PredictiveAfService` (mirrors Rust `focus_prediction.rs`, used in-run). The HTTP "should-refocus" answer and the live run's refocus decision come from different models.

**D. Safety config split across three stores** (`settingsDao`, `weatherSettingsDao`, `appSettings`) for one logical safety config — drift-prone source-of-truth fragmentation.

---

## 4. Dead / legacy / stub systems to retire

| Item | Status | Evidence |
|---|---|---|
| **In-Dart sequence executor** | **DEAD.** `start()` ignores `useNativeExecution`, logs *"Legacy Dart sequencer path is deprecated; forcing backend executor"* (`sequence_executor.dart:465–480`), always routes native. `useNativeExecution` is vestigial. | Confirmed |
| **`scheduler_screen.dart`** | **DEAD shell.** Self-documents: *"`/scheduler` route now redirects to `/planner?tab=scheduler`, so this screen is unreachable through the router"* (lines 9–12). Whole `screens/scheduler/` dir is now just leaf widgets reused by the planner tab — misleading legacy structure. | Confirmed |
| **`/api/sequences/start` alias** | **Redundant.** Thin duplicate of `/api/sequencer/start` (`sequencer_routes.dart:29`). Two route families for one action. | Confirmed |
| **Framing "Export-to-Targets"** | **Dead-end.** Writes plain `targets` rows (objectType 'mosaic'); creates no durable project, no sequence — diverges from the wizard's Create-Project path. | Per profile |
| **Rust `crate::mosaic` wizard/orchestration scaffolding** | **DORMANT.** Forward-compat; canonical path is Dart static-expansion; `wizard_states['mosaic']` checkpoint slot unused. | Per profile |
| **Static 2-panel "Mosaic Multi-Panel" template** (`_createMosaicMultiPanelNodes`) | **Frozen demo**, not generator-driven — a third panel-geometry path. | Per profile |
| **`filteredSuggestionsProvider`** | **Legacy-ish dup** of `plannerFilteredSuggestionsProvider` (UI uses the planner variant). | Per profile |
| **`FlatPanelLocation` enum / panel-location selector** | **Cosmetic dead code** — collected, shown in Review, never affects calibration/capture. | Per profile |
| **`SessionOptimizerService.analyze()` retrospective path** | **Misplaced** — post-session insight bundled into the Plan-Tonight service, unused by planner UI. | Per profile |
| **`latitudeSign()`** | **Stub** — always `return true` (hardcoded northern hemisphere). Real correctness bug for southern-hemisphere users, confirmed `strategy_helpers.dart:303`. | Confirmed |
| Stale comment `sequence_models.dart:306` ("32 subtypes") | now 36 — doc drift. | Per profile |

---

## 5. Natural seams: one pipeline vs genuinely separate

The systems sort cleanly into a single **DECIDE → PLAN → BUILD → EXECUTE → WATCH** pipeline, plus a few genuinely-separate concerns:

```
DECIDE (what)         PLAN (whole night)      BUILD (node tree)     EXECUTE (engine)      WATCH (in-run)
─────────────         ──────────────────      ─────────────────     ────────────────      ─────────────
planner (advisory)    smart-night             sequencer model       native Rust           in-run-triggers
scheduler (autopilot) scheduler (gen+dispatch)  ← mosaic emits→      SequenceExecutor      (dither/flip/
TargetSchedulerNode   mosaic (durable proj)     ← flat-wizard emits→  (.start/pause/...)     recovery/weather)
(in-sequence pick)                              ← scheduler emits→                          + focus refocus
                                                                                            run-surface (control veneer)
```

**These ARE layers of one pipeline (should be unified, not separate products):**
- **smart-night, scheduler, mosaic, flat-wizard are all BUILD-stage generators** feeding the one `SequenceNode` model. They are not separate engines — none can execute a sequence; all hand a `Sequence` to `currentSequenceProvider` + `sequenceExecutorProvider`.
- **run-surface (cockpit) is pure WATCH/control veneer** — confirmed it owns no engine; cockpit Start, sequencer playback bar, headless, and scheduler all call the same `SequenceExecutor.start()`.
- **in-run-automation-triggers is the WATCH layer**, authoritatively owned by native Rust; Dart only injects config and mirrors events. The standalone Dart watchdogs (meridian/disk-space) are correctly scoped to "no sequence running" — clean hand-off, real layering.
- **planner ⊃ scheduler**: the scheduler is literally a *tab inside* the planner now (`SchedulerTabContent` embedded in `_schedule_tab.dart`). "planner" and "Planning Screen + Scheduler tab" are the **same screen** — the audit's premise of three separate planning surfaces collapses to one `PlannerScreen`.

**Genuinely separate (correctly distinct):**
- **mosaic stitching** (`api_stitch_mosaic` FFI, gnomonic-canvas feather-blend) — exists nowhere else; legitimately its own thing post-capture.
- **focus *model* learning** (regression fit/persist) vs focus *triggering* — modeling is a distinct concern from the in-run trigger.
- **observing lists** — two *unrelated* things share the name: curated marker lists (DB + `/api/observing-lists`, planetarium pins, do NOT feed the scheduler) vs `observing_list_json_importer` (NINA-style import → `CanonicalSequenceNode`). Neither feeds the scheduler directly; the real flow is `observing list → (manual) → targets table → scheduler → sequencer`.

**The one seam that is NOT a clean layer — the actual architectural defect:** the **DECIDE stage has three independent owners** (`SchedulerEngine`, planner `TargetScoringService`, in-sequence `TargetSchedulerNode`/Rust `decision.rs`) with three weight sets and no shared scoring contract. Collapsing these onto one scoring service (or at minimum sharing the weight model + hysteresis) is the highest-value consolidation. Secondary defects: the **single shared editor-sequence slot** as a multi-writer contention point, and the **duplicated flat-calibration + focus-model engines** straddling the Dart/Rust boundary.

---

### Most actionable consolidations
1. Unify the **3 target scorers** behind one scoring contract; the live `TargetSchedulerNode` (Rust `decision.rs`) being a separate autopilot is the biggest hidden conflict.
2. Retire dead shells: in-Dart executor branch + `useNativeExecution`, `scheduler_screen.dart`, `/api/sequences/start` alias, Framing Export-to-Targets dead-end, frozen mosaic template, `filteredSuggestionsProvider`.
3. Collapse the **two flat-calibration engines** (Dart `FlatWizardService` vs Rust `flat_wizard/mod.rs`) and the duplicated `calculateNextExposure`.
4. Pick one **focus-temp model** (route `/api/focus-model/*` to the predictive DB model the run actually uses).
5. Give the autopilot its **own sequence slot** instead of `discardUnsaved:true` clobbering the user's editor.
6. Fix `latitudeSign()` (southern-hemisphere correctness) and the stale "32 subtypes" comment.

Relevant verified paths: `/home/scdouglas/Documents/Skotiq2/packages/skotiq_core/lib/src/providers/sequence/sequence_executor.dart:465`, `/home/scdouglas/Documents/Skotiq2/packages/skotiq_core/lib/src/providers/scheduler_provider.dart:136`, `/home/scdouglas/Documents/Skotiq2/packages/skotiq_core/lib/src/providers/sequence/sequence_executor/serialization_operations.dart:561`, `/home/scdouglas/Documents/Skotiq2/native/skotiq_native/sequencer/src/decision.rs`, `/home/scdouglas/Documents/Skotiq2/native/skotiq_native/sequencer/src/node/registry.rs:181`, `/home/scdouglas/Documents/Skotiq2/packages/skotiq_app/lib/screens/scheduler/scheduler_screen.dart:9`, `/home/scdouglas/Documents/Skotiq2/apps/desktop/lib/headless_api/routes/sequencer_routes.dart:29`, `/home/scdouglas/Documents/Skotiq2/packages/skotiq_core/lib/src/services/smart_night_models/strategy_helpers.dart:303`.