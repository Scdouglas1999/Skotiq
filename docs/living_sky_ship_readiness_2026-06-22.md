# Living Sky (Your Sky / First Light / Constellation) — Ship-Readiness Evaluation

> **Historical pre-fix audit — superseded for 5.0.0.** This document is retained
> as the finding record and intentionally describes the code as it existed on
> 2026-06-22. The coordinated remediation landed in Wave 0 (`bc9330b9`), Wave 1
> (`e1fd56dd`), Wave 2 (`41ed1ee4`), Wave 3 (`90fe0805`), the final sweep
> (`dec8d33f`), and deferred-backlog closure (`0d16b0bc`). Current release scope
> is defined by `docs/release/v5.0.0.md`: TNS has a real credentialed API path;
> AAVSO/MPC are explicit manual exports; Constellation uses a self-hosted hub;
> and physical-rig/on-sky validation remains pending. Do not treat the original
> “NOT ready” verdict below as the current branch status.

_Read-only deep evaluation, 2026-06-22. 3 pillars mapped end-to-end, evaluated through 6 lenses each (desired UX, functional gaps, adversarial UI, correctness, code quality, data/scale), adversarially verified. 126 raw findings -> 116 confirmed. No code changed._

---

I have confirmed the load-bearing cross-cutting structural facts: a single `SolvedFrameFoldHook` (one solve-persist seam) fans out to all three pillars, the swarm blend writes back into the same `basePath` that contribute exports (the corruption keystone), and Constellation mutates Pillar A's atlas tables directly. I have everything needed to write a decisive cross-pillar synthesis.

---

# Living Sky (Pillars A+B+C) — Cross-Pillar Executive Summary

## Overall verdict: NOT ready to ship fully functional. Shippable after one coordinated P0 wave.

Living Sky is a strong engine wearing an unfinished product. All three pillars share the same shape: **the hard part — the native math — is genuinely built, tested, and correct, while the product layer above it is incomplete, unreachable, or master/slave-blind.** None of the three is shippable as-is, but none requires new science to fix. The gap is plumbing, reachability, and data-integrity hardening — not algorithms.

The three pillars are not independent. They hang off **one shared seam**: a single `SolvedFrameFoldHook` (`imaging_records_repository.dart:27`) fires on every persisted plate-solve and fans out to atlas fold (A), transient scan (B), and — via the atlas tiles C blends into — the swarm. They also share **one storage substrate**: Constellation's `mergeSwarmDelta` writes directly into Pillar A's atlas tile sidecars (`sky_atlas_service.dart:396,402`, confirmed). This coupling is why the fixes must be sequenced as a wave, not three parallel sprints — a Constellation change can corrupt Your Sky, and a fold-path change touches all three.

Relative maturity: **B (First Light) is closest** — correct, tested science undercut by two quiet bugs and an overclaiming CTA. **A (Your Sky) is half-built** — a real engine and a working coverage map, but the headline "region" experience is unreachable dead code. **C (Constellation) is the most dangerous** — it works on the first night, then silently *corrupts the shared community co-add* on the normal multi-night workflow, which is worse than not shipping.

## The single most important issue per pillar

- **Pillar A — Your Sky:** The entire region layer is dead code. **Nothing in the app ever creates a region**, so the cutout/scrub/growth/provenance experience — the marquee "M31 deepens night-over-night" half of the pillar — is fully built but permanently unreachable. (Fix: auto-attach a region on fold from the active target + an explicit "Name this region" action.)

- **Pillar B — First Light:** **Self-subtraction.** The new frame is folded into the comparison template *before* it is differenced against it, so every transient is partially subtracted away and faint (SNR ~5–6) discoveries silently drop below the persist gate — the feature suppresses the exact events it exists to find. (Fix: difference before fold, or exclude the current frame from the template.)

- **Pillar C — Constellation:** **Silent corruption of the shared co-add.** Because the swarm blend writes back into the same base tile that `exportDelta` reads, (a) pull-then-contribute ships the community's own photons back up as your capture, and (b) re-contribute re-adds your *entire* accumulated depth (since=epoch), so the "fused depth" everyone trusts inflates per cycle, per participant. (Fix: separate the swarm-blend overlay sidecar from the contributable base — one architectural change kills three bugs.)

## Cross-cutting themes

1. **Master/slave parity is the systemic blind spot — and the slave is the primary night device.** The companion phone/tablet is *the* surface a user holds in the dark, yet all three pillars degrade or fake-function on a slave. Your Sky region detail reads an empty local DB and renders blank (and consumes a host-local file path that can't cross the wire at all). First Light's triage badge goes stale after Confirm/Dismiss on the tablet. Constellation presents fully-enabled Contribute/Pull buttons that read the slave's empty local atlas and no-op. This is the same defect class the prior audit already hit (slave empty-atlas read, First Light positionAngleDeg) — it keeps recurring because the master/slave seam has no parity test and "backend-agnostic" docstrings are aspirational, not enforced.

2. **No-op / overclaimed headline features.** Each pillar ships a marquee promise that the code does not honor: A's "name a region to track its depth" hint with no control behind it; B's "Submit to AAVSO/MPC/TNS" CTA that only writes a file to a buried folder (and the AAVSO row is non-ingestible); C's twice-printed "subtract your contribution exactly" privacy promise with no button and no saved id. These are trust defects, not feature gaps — they tell the user something happened that didn't.

3. **Append-only logs with no retention + per-fold I/O that scales with history.** Every pillar accrues unbounded state and re-reads it hot. A rewrites ~2 GiB of sidecars per wide-field sub (~120 GiB/night) and full-scans 40 MiB sidecars on every coverage poll; B's `transient_detections` never prunes and the feed/REST read all-time history with no LIMIT, while dismissed-suppression full-scans unindexed every frame; C accumulates swarm `.nst`/`.fits` blobs with no cleanup and cone-selects by materializing all tiles. On the constrained Pi/appliance target this degrades the one working surface over a season. This codebase prunes every other log — these three forgot.

4. **Concurrency on the shared solve hook is unguarded.** The single fire-and-forget hook serializes fold+scan with no single-flight lock. Under live-stacking / fast cadence / batched headless solves, A silently loses folds (shared `.skt.tmp`) and can double-fold a re-solved frame; B stacks concurrent native passes against live capture. The shared trigger is a shared hazard.

5. **"False completeness": built-and-wired native/REST APIs that nothing displays.** A's growth-curve and provenance providers, B's tile-coverage counters (decoded, never consumed), C's retract (impl, zero callers) — substantial native+wire work that the UI never surfaces, creating an illusion of done-ness that masks the real gaps.

## Recommended sequencing — one coordinated wave, grouped to minimize risk

The right model is **three risk-ordered waves across all pillars**, not pillar-by-pillar, because the storage substrate and solve hook are shared. Order by *blast radius*: stop the data corruption first, then make the science honest, then make the slave usable.

**WAVE 0 — Stop the bleeding (data integrity; ship-BLOCKING). Do before anything user-facing.**
The only changes that *corrupt persistent or shared data* live here, and C's fixes share a substrate, so land them together:
1. **C: persistence Drift table** (tagged P1 but is the prerequisite substrate for everything below) — joined targets, pulled-tile high-water marks, contribution receipts.
2. **C: separate the swarm-blend overlay sidecar from the contributable base** — one architectural change fixes pull-then-contribute re-upload, non-idempotent re-blend, *and* the inflated contribution bar. This is the single highest-leverage fix in all of Living Sky.
3. **C: per-tile contribution high-water + true deltas** (kills repeat-contribute double-count) + gate the button as belt-and-suspenders.
4. **A: serialize folds** (single-flight queue + unique temp filename) and **A: fold dedup** on re-solve — protects the shared hook all three pillars ride.
5. **Regression tests** gating #2–#4 (C repeat-contribute, A concurrent/double-fold). Ship-block until green via *full* CI gates (`melos run test` + launch gates), not subsets.

**WAVE 1 — Make the science honest (correctness + truth-in-UI; the credibility line).**
Cheap, high-trust fixes; mostly B:
6. **B: difference-before-fold** (the #1 First Light fix — stop self-suppressing transients).
7. **B: Δmag sign** + **B: Confirmed-filter `reviewed && !dismissed`** (two near-trivial science-credibility bugs on the primary surface).
8. **Overclaim reframes (all three):** B's "Submit…" → "Generate a discovery report" + fix/omit the AAVSO row; A's region/empty-state copy; C's SUBS option disabled + conditional privacy banner. Soften now, build real submission later.

**WAVE 2 — Make the slave usable + reachable (parity; the primary-device line).**
The companion tablet is the night surface; this wave is what turns "feels production" into production:
9. **A: region creation on fold** — unlocks the entire region half of the pillar (nothing else in A matters until this lands).
10. **A: backend-branch region detail + portable cutout bytes** — the three NetworkBackend client methods (host routes already exist) so region detail isn't blank on every slave; return PNG bytes, not a host-local path.
11. **A: honest time-scrub** — decouple `asOf` from tile render so the marquee scrubber stops showing a broken-image icon.
12. **B: remote-slave triage refresh** (`invalidate` after remote Confirm/Dismiss) — a triage action that visibly does nothing is a broken-feeling core interaction.
13. **C: `ensureTarget` + "Share one of my targets" CTA** — without it any user-stood-up hub is dead at step one.

**THEN (next release, before promoting Living Sky as a headline):** wire the built-but-dead APIs (A growth/provenance, B chase + push notification + light-curve detail, C retract on the now-persisted contributionId); fix C's follow-the-night local-id/hub-id collision; host-route or disable host-only Constellation actions on the slave. **Last:** the shared data-scale hardening (retention/pruning, DB-index reads instead of sidecar scans, write-amplification, spatial cone queries) before the install base accrues a multi-season history — and add the master/slave parity tests whose absence let this whole class of bug ship.

**Bottom line:** Living Sky's engines earned their keep; the work remaining is product plumbing with a sharp risk gradient. Sequence by blast radius — corruption (mostly C) before correctness (mostly B) before slave-reachability (mostly A) — and Living Sky becomes genuinely production-ready in roughly three focused waves without writing one new line of science.

Relevant paths: `packages/skotiq_core/lib/src/services/imaging_records_repository.dart:27` (shared solve hook); `packages/skotiq_core/lib/src/services/sky_atlas/sky_atlas_service.dart:390-428` (swarm writeback into base tile — the A↔C corruption seam); `packages/skotiq_core/lib/src/services/constellation/constellation_service.dart:355,407`; `packages/skotiq_core/lib/src/providers/sky_atlas_provider.dart`; `packages/skotiq_core/lib/src/providers/constellation_provider.dart:86`.

---

# Your Sky (Pillar A — personal growing atlas)

Both load-bearing claims confirmed: zero production callers for region creation, and no `getAtlasRegion`/cutout/timeline client method on NetworkBackend. Writing the report.

# Your Sky (Pillar A) — Ship-Readiness Report

## 1. Verdict

**Not shippable as-is — shippable-with-fixes after a focused P0 pass.** The Rust engine, auto-fold pipeline, and atlas-wide coverage map genuinely work, but the entire region layer (the headline "M31 deepens night-over-night" experience) is unreachable dead code because **nothing in the app ever creates a region**, and the region detail view is **blind on every mobile/remote slave** — which is the primary night-time use case.

## 2. What works today

- **The engine is real and tested.** A from-scratch HEALPix NESTED scheme (order 9), additive per-tile accumulation, photometric normalization (frozen reference for valid cross-rig co-adds), online sigma-clip, finalize/coverage, resumable `.nst` sidecars, and federation merge/subtract — ~28 Rust unit tests. This is the strong keystone.
- **Auto-fold is wired end-to-end on the host.** Every persisted plate-solve fires `onSolvedFrameFold` → `autoFoldCapturedImage` → native fold → DB index (`SkyTiles`) + append-only `SkyAtlasFolds` timeline. Fire-and-forget, errors logged not fatal.
- **The atlas-wide coverage overlay renders on host AND slave** (slave reads `/api/atlas/coverage` over REST). Total integration, tile count, depth heat strip — this delivers the "personal growing atlas" promise as a raw tile heat map.
- **Region + coverage LIST providers correctly branch host vs. NetworkBackend** (the prior empty-local-DB bug is genuinely fixed for these two readers).
- **Honesty is intact** where it matters: time-scrub and `exportDelta` refuse impossible per-pixel as-of reconstructions rather than faking them.

## 3. The gap to "fully functional"

The vision: you image M31 for five nights, open "M31" in Your Sky, and see a deep co-added preview that visibly deepens each session, with a scrubber that replays its growth and a per-tile provenance trail. The reality: **the "Regions" section is permanently empty for every user.** The screen literally says "name a region to track its depth," but there is no button, dialog, or text field anywhere to do so — and the fold pipeline never auto-creates one either. So the single richest half of the pillar (co-added cutout, time-scrub, growth curve, provenance, region cards) is fully built but can never be opened. Even if it could, on a phone/tablet companion it would render blank, because the detail screen reads a local database that is empty on a slave. What ships today is an abstract stats strip with no per-target meaning, and a few hot-path correctness/data-scale hazards (lost folds under live-stacking, ~2 GiB of disk churn per wide-field sub) waiting in the engine underneath.

## 4. Prioritized backlog

| Priority | Title | Type | User impact | Concrete fix | Effort | File pointer |
|---|---|---|---|---|---|---|
| **P0** | Region layer is dead — nothing ever creates a region | missing-feature | Entire region experience (cutout/scrub/growth/provenance/cards) permanently unreachable; "name a region" hint cannot be followed | Auto-attach a region on fold: in `_persistFold`, when `image.targetId` set, `getRegionForPoint(solvedRa,Dec)` → `ensureRegion(target name, cone, kind:target)` → `assignTileToRegion` per touched tile + `refreshRegionRollups`; add an explicit "Name this region" UI action for custom/mosaic/polar | L | `sky_atlas_service.dart:147-200,436-474`; `sky_atlas_dao.dart:258`; `your_sky_screen.dart:122,150-178` |
| **P0** | RegionDetail/AtlasTilePreview are local-only despite "backend-agnostic" docstrings — blank on every slave | bug | On the primary night device (phone/tablet companion) region detail shows blank cutout, empty scrubber, no provenance | Add NetworkBackend `getAtlasRegion(id)`/`cutout`/`timeline` clients (host routes already exist); branch `_region*Provider` + `skyTileProvider` on `backendProvider` like coverage/regions already do | L | `region_detail_screen.dart:12-39`; `sky_atlas_provider.dart:146-176`; `session_science_operations.dart:341-357` |
| **P0** | AtlasTilePreview consumes a local FILE PATH — cannot render remotely even with a remote method | bug | Tile/cutout image is structurally non-portable to the companion; always shows imageOff icon on slave | Have the remote path return PNG bytes (fetch `/api/atlas/region/<id>/cutout` into a verified-local cache file) and render via `Image.memory`/cached file instead of a host-local path | M | `atlas_tile_preview.dart:66-75`; `sky_atlas_provider.dart:146-153` |
| **P0** | Concurrent folds on same tile silently lose frames (no lock; shared `.skt.tmp`) | bug | Under live-stacking / fast cadence / concurrent headless POSTs, frames silently vanish from integration depth or sidecar corrupts — atlas quietly shallower than photons collected | Single-flight per-atlas fold queue in `SkyAtlasService` (await prior fold) and/or per-tile native lock + unique temp filename (`<tile>.<pid>.<nonce>.skt.tmp`) | M | `imaging_records_repository.dart:342`; native `sky_atlas.rs:1254-1256,1289-1297` |
| **P0** | Time-scrub shows broken-image icon on every past stop | ux-gap/bug | The marquee "replay how your region grew" interaction visibly fails on first use; "as of <date>" badge paints over a broken image | Decouple `asOf` from the tile render: pin cutout to latest, let the slider drive only the honestly-filtered Contributing-frames/timeline panels; or hide the scrubber for single-tile preview | M | `region_detail_screen.dart:205-218,272-274`; `atlas_tile_preview.dart:45-49`; native bridge `sky_atlas.rs:507-534` |
| **P1** | Region "cutout" panel renders one deepest tile, not the region co-add | missing-feature/ui-defect | At order 9 (~7') every real frame/mosaic is multi-tile, so the hero image is a fragment while the label/radius describe the whole region (misleading mismatch) | Route the panel through `service.cutout(centerRa,Dec,radius)` (host) / `/cutout` route (slave); keep single-tile only as fallback, or relabel "Deepest tile" with the tile's own coords | M | `region_detail_screen.dart:116-127,181-185`; `sky_atlas_service.dart:229-257`; `atlas_handlers.dart:92-124` |
| **P1** | Coverage read deserializes every ~40 MiB sidecar on every call (host + slave poll) | data-scale | Coverage overlay (the one working surface) gets slower and more I/O-bound the more you image; Pi appliance thrashes; slave polls amplify | Serve coverage from the `SkyTiles` DB index (`getAllTiles` already has the scalars) instead of the native full-scan; reserve native path for genuine per-pixel needs | M | `bridge sky_atlas.rs:594-619`; `sky_atlas_provider.dart:50`; `atlas_handlers.dart:49-56`; `sky_atlas_tables.dart:68-72` |
| **P1** | One wide-field sub rewrites ~2 GiB of sidecars; ~120 GiB write churn per night | data-scale | SSD wear, full disks, stalled imaging loops after a season; storage balloons tens of GiB per new region | Coarser order / smaller per-tile grid (1024² per 6.7' is far finer than needed), and/or sparse-or-compressed sidecars, and/or batch a session so each tile rewrites once per session; surface storage projection + configurable cap | L | native `sky_atlas.rs:908-925,1289-1297,1407-1410` |
| **P1** | Atlas-wide growth ("X deeper than last night") never surfaced where users look | ux-gap | The come-back hook is absent: the overlay every user/slave sees shows only static lifetime totals; the growth phrase lives only on the dead region card | Add an atlas-wide growth headline to `AtlasCoverageOverlay` driven by the global `SkyAtlasFolds` timeline + a `/api/atlas/growth-summary` rollup for slaves; independent of the region fix | M | `atlas_coverage_overlay.dart:14-98`; `sky_atlas_format.dart:44-60`; `sky_atlas_dao.dart` (watch/list folds) |
| **P1** | No closing loop from imaging/session into Your Sky | ux-gap | A 6-hour session ends and the user never learns their permanent sky deepened; the only way to find the feature is the Discover tab. (Sibling First Light on the *same hook* already announces via narrator) | Emit a Night Narrator insight on meaningful fold ("M31 is now your deepest field at 11h"); add "View in Your Sky" action on solved-image detail + session recap | M | `imaging_records_repository.dart:336-348,644-712` (First Light narrator template alongside) |
| **P1** | Region cutout `outPixels` is unbounded — companion request can OOM the host | bug | An authenticated slave (or operator typo `outPixels=100000`) allocates ~240 GB and crashes the rig controller mid-session | Clamp `outPixels` to a sane ceiling (e.g. 4096) in `handleGetRegionCutout` and again in native; reject larger with HTTP 400 | S | `atlas_handlers.dart:104`; native bridge `sky_atlas.rs:898,932` |
| **P1** | Re-solving a frame double-folds it (no frame-identity dedup) | bug | Duplicate inbound `updateCapturedImage{isPlateSolved:true}` (plausible in a sync architecture) double-counts photons/integration | Persist a folded marker (`foldedAt` flag or `(framePath,sessionId)` consumed-set) and skip `autoFoldCapturedImage` when already folded | M | `imaging_records_repository.dart:340-348`; `sky_atlas_service.dart:147-200`; `session_handlers.dart:407-420` |
| **P1** | Native growth-curve + provenance APIs built and wired but never displayed | missing-feature | "Deepening growth curve" + rich per-tile provenance (substantial native+REST work) never shown; region detail computes a coarse phrase from local rows | Wire `skyAtlasGrowthProvider` into a real growth chart and `skyTileInfoProvider` into the provenance panel — or delete the unused providers/route fields to kill the false-completeness | M | `sky_atlas_provider.dart:156-176`; `region_detail_screen.dart:398`; `atlas_handlers.dart:160-169` |
| **P1** | No export / "do something with it" affordance — deep cutout is a dead end | ux-gap | After investing nights, the user can't save, share, or reuse the co-add the engine already writes to FITS+PNG | Add Export/Share + "Use as reference frame" in RegionDetailScreen; slave fetches bytes over the existing `/cutout` route | M | `sky_atlas_service.dart:229-257`; `region_detail_screen.dart`; `atlas_routes.dart` |
| **P2** | No spatial all-sky map — coverage is a context-free heat STRIP | missing-feature | The "living sky" emotional core is missing: an unordered 18px-cell strip capped at 64, RA/Dec only in a tooltip, no projection | Render an Aitoff/Mollweide all-sky (reuse `skotiq_planetarium`, already a dependency) with tiles at true RA/Dec, brightness=depth, tap-to-open region | L | `atlas_coverage_overlay.dart:103-157`; `sky_atlas_models.dart:319-323` |
| **P2** | Depth heat map inert on phone — hover-only tooltips, 18px cells, no tap target | ux-gap | The one fully-rendering surface conveys nothing actionable one-handed in the dark | Make each cell tappable (`InkWell`) → bottom sheet with tile coords/depth/frames; replace hover-only tooltip with a long-press-capable one (cells are 18px vs 44px min-touch) | M | `atlas_coverage_overlay.dart:122-141`; `skotiq_tooltip.dart:126-131` |
| **P2** | First-run / onboarding copy misdescribes the product | ux-gap | Empty state implies a manual "fold the session" step (it's automatic); the regions hint promises naming with no control — reads as broken | Rewrite empty/hint copy to match reality; pair with the region-creation fix so hints become actionable; add a one-time growing-atlas explainer | S | `your_sky_screen.dart:150-196` |
| **P2** | Phantom zero-frame tiles pollute the DB index + timeline | bug | Coverage gallery / region tile list show empty 0-frame tiles; timeline gets "+0 frames" noise; dangling `sidecarPath` to never-written `.nst` | Guard `if (tile.framesAdded <= 0) continue;` in `_persistFold`, or drop zero-frame tids in the bridge aggregation | S | `sky_atlas_service.dart:446-473`; native `sky_atlas.rs:1293-1296`; bridge `sky_atlas.rs:348,365` |
| **P2** | No cache retention — cutout/delta cache grows forever | data-scale | Distinct region browses leave 2048² PNG+FITS that are never reclaimed; disk fills silently on a long-running host | Size/age-capped LRU sweep of `<atlasRoot>/cache` (evict on write past budget or sweep on startup); delete `exportDelta` files after a successful contribution upload | M | `sky_atlas_service.dart:242-243,294,494`; `constellation_service.dart:315` |
| **P2** | Remote atlas stream swallows all errors — broken host looks like empty atlas | code-quality | Companion can't distinguish "can't reach host" from "host has no data"; first load with host down hangs on loading forever | Log via `loggingService` and `controller.addError` when there's no prior snapshot, so the existing `_buildError` branch can fire | S | `sky_atlas_provider.dart:96-126` |
| **P2** | Per-fold integration seconds approximated (bridge drops exact value) | code-quality | On mixed-exposure tiles the timeline's per-fold "+Xh" is a frame-count-weighted guess, not what was shot (cumulative stays correct) | Add summed `integration_seconds_added` to `TileFoldSummary`, accumulate in `fold_impl`, use directly in `_persistFold` | S | `sky_atlas_service.dart:480-490`; native bridge `sky_atlas.rs:281-292` |
| **P2** | Duplicate `_regionTiles`/`_regionTimeline` providers in two files, both local-only | code-quality | Fixing the backend-branch requires editing both; they can silently diverge | Hoist a single backend-aware set into `sky_atlas_provider.dart`; consume from both card and detail (natural place to add the P0 remote branch) | S | `region_detail_screen.dart:18-28`; `atlas_region_card.dart:174-185` |
| **P2** | Empty-state flashes "Your sky is dark" before coverage loads | ui-defect | Jarring "you have nothing" flash on every visit for a user who has imaged plenty (regions always empty, coverage loads slower on a separate future) | Gate the empty decision on both providers loaded (combine the two `AsyncValue`s / hold shimmer until coverage resolves) | S | `your_sky_screen.dart:72-92` |
| **P2** | Headless atlas handlers untested; `_findRegion` full-table scan | code-quality | The slave's whole atlas data path is untested (wire-shape regressions can recur, like the prior createdAt fix); region request scans all regions | Add `AtlasHandlers` route-shape tests; replace `_findRegion` scan with keyed `getRegion(id)` | M | `atlas_handlers.dart:177-182`; `apps/desktop/test` (no atlas refs) |
| **P2** | Unbounded provenance fold-log in rewritten-every-fold header | code-quality | Header grows without cap; duplicates the DB `SkyAtlasFolds` timeline (note: the dominant cost is the 40 MiB payload, not the log) | Drop the fold log from the per-tile header (DB already is the append-only timeline), or cap/rotate `provenance.folds` | M | native `sky_atlas.rs:796,887-907` |
| **P2** | No accessibility semantics on the entire Your Sky surface | ux-gap | Screen readers get nothing from the heat map, stats, or scrub slider (app-wide pattern, not a Your-Sky outlier) | Wrap heat strip in a `Semantics` summary + per-cell labels; add `semanticFormatterCallback` to the scrub slider | S | `atlas_coverage_overlay.dart`; `atlas_timescrub.dart:81-94` |

## 5. Recommended ship plan

**Minimum P0 set to call Pillar A production-ready (do all five):**

1. **Region creation on fold** — auto-attach a region from the active target in `_persistFold` (`getRegionForPoint` → `ensureRegion` → `assignTileToRegion`), plus an explicit "Name this region" action. *Without this the entire region half of the pillar is unreachable; nothing else matters until it's done.*
2. **Backend-branch the region detail layer** — add the three NetworkBackend client methods (host routes already exist) and branch `_region*Provider` + `skyTileProvider`. *The primary night-use device is a slave; region detail is blank there until this lands.*
3. **Portable tile/cutout image** — make the remote path return PNG bytes into a verified-local cache (pairs with #2; the file-path consumption blocks remote rendering regardless).
4. **Serialize folds** — single-flight queue + unique temp filename, so the "every photon is a brick" promise doesn't silently drop frames during live-stacking.
5. **Make time-scrub honest** — decouple `asOf` from the tile render so the marquee scrubber stops showing a broken-image icon.

These five turn the pillar from "abstract heat strip with a dead region section" into the reachable, slave-capable, non-lossy, non-broken experience the copy promises. **P0 effort is roughly L+L+M+M+M.** Note #1, #2, #3, and the P2 duplicate-provider hoist all touch the same provider/seam seam, so sequence them together.

**P1 follow-ups, in order, immediately after ship:**

- **Coverage from the DB index** + **wide-field write-amplification** — the two data-scale hazards that degrade the one working surface over a season and threaten the Pi appliance. Do these first among P1; they protect what already ships.
- **Atlas-wide growth headline** + **session→Your Sky narrator loop** — the retention hooks the pillar's own copy sells; First Light on the same hook is a ready template.
- **Clamp `outPixels`** (S, security/robustness) and **fold dedup** — cheap correctness hardening for the sync architecture.
- **Region co-add cutout** + **wire the growth/provenance providers** + **export action** — close the fidelity and payoff gaps so the detail screen matches its own framing.

P2 is polish/upgrade (spatial all-sky map, touch affordances, onboarding copy, phantom-tile/cache cleanup, a11y, test coverage) — valuable, none blocking.

**Bottom line:** the engine earned its keep; the product gap is almost entirely the region layer and slave plumbing. Five P0 fixes (no new science, all confined to the fold-persist path, provider branches, and one UI decoupling) make Pillar A genuinely production-ready.

---

# First Light (Pillar B — transient discovery)

All three load-bearing claims verified against live code: the fold-before-difference self-subtraction (imaging_records_repository.dart:683-704), the inverted Δmag sign label (transient_candidate_card.dart:182-183 prints `+` for `dm <= 0`/brighter), and the Confirmed filter with no `!dismissed` guard (first_light_view.dart:248). Report follows.

# First Light (Pillar B — Transient Discovery) — Ship-Readiness Report

## 1. Verdict

**Shippable-with-fixes — but NOT as-is**, because the science core is genuinely real and well-tested, yet two correctness defects quietly sabotage the headline promise (every transient self-suppresses against a template it just contaminated, and the primary card shows a sign-flipped magnitude), and the marquee "Submit to AAVSO/MPC/TNS" call-to-action never submits anything.

## 2. What works today

This is the most complete of the three v5 pillars, and its functional core is real, not a demo:

- **Real native difference imaging** (`difference_image.rs`): WCS reprojection onto the tile's canonical grid, robust Theil-Sen photometric match (transient-resistant), optional PSF matching, signed-residual source extraction, second-moment shape, and dipole/streak/new-source/brightening classification — with 4 native tests asserting injected-source detection, thin-template gating, degenerate-WCS rejection, and cross-tile dedup.
- **Automatic, correctly-wired trigger**: every solved light frame fires the scan via the same solve-persist hook as the atlas fold; thin/absent-template tiles no-op cheaply.
- **Thoughtful astronomy in the cross-match**: high-proper-motion epoch widening, tight-vs-epoch-uncertain distinction, refusal to silently demote an unbacked new source coincident with a star, graceful network-down degradation.
- **Persistence + reactive feed** (schema v52 `transient_detections`): newest-first streams; dismissed-position suppression so the same hot pixel isn't re-announced nightly; `positionAngleDeg` carried correctly on the wire (prior-audit fix verified present).
- **Master/slave**: the host runs the scan even for solves arriving over the headless API; the slave reads via debounced REST snapshot and triages back to the host.
- **Night Narrator integration** with three real detectors + a celebrate banner, and **correct report generators** (AAVSO Extended, MPC 80-column length-validated, TNS AT-report TSV).

## 3. The gap to "fully functional"

The dream is: *you're asleep, your rig catches something new, you get pinged, you open one card, eyeball the actual pixels to confirm it's real and not a hot pixel, tap "Chase it" to grab confirmation frames, and tap "Submit" to actually report it to the world.* The reality is a flat list of terminal cards: there's no push, no real pixels (just a painted cartoon ellipse), no "Chase," no detail view to see if it's changing across nights, and "Submit" only writes a file into a buried folder you must upload by hand through three websites. Underneath, two silent bugs erode the science itself — the new frame is averaged into the comparison template *before* it's compared against it (so every transient is partly subtracted away, and faint ones drop below the detection cutoff and vanish), and the card prints a brightening as "+0.50 mag," which reads as *fainter* to any astronomer.

## 4. Prioritized backlog

| # | Title | Type | User impact | Concrete fix | Effort | File |
|---|-------|------|-------------|--------------|--------|------|
| 1 | Frame folded into template **before** it's differenced (self-subtraction) | bug (correctness) | Every transient self-suppressed ~1/(N+1); faint SNR~5–6 discoveries silently lost below the persist gate — defeats the feature's purpose | Difference **before** fold, or exclude the current `capturedImageId`/fold-label from the template the scan loads | M | `imaging_records_repository.dart:683-704`; `difference_image.rs:906-915` |
| 2 | Δmag chip inverts magnitude sign (shows "+0.50 mag" for a brightening) | bug (code-quality) | Primary triage card contradicts magnitude convention + Narrator; reads as fainter for a source that got brighter | Print signed value (`'${dm.toStringAsFixed(2)} mag'` → "-0.50") or relabel "0.50 brighter"/"Δinstr"; add a card-render test | S | `transient_candidate_card.dart:182-183` |
| 3 | "Submit to AAVSO/MPC/TNS" never submits — only writes a file; AAVSO row is non-ingestible | functional-gap / honesty | Headline CTA is a hollow promise; user believes they reported a nova/SN. AAVSO DIF row with `CNAME=na` is rejected even on manual upload | Min: soften all "submit … to AAVSO/MPC/TNS" copy to "Generate a discovery report to submit" + retitle dialog + add manual-upload note + deep-link; fix or omit the AAVSO generator for unnamed sources. Full: real TNS bulk-API/AAVSO WebObs/MPC submission seam | S (copy) / XL (real) | `first_light_view.dart:114-117`; `transient_report_panel.dart:77-79`; `transient_submit_dialog.dart:35`; `transient_report_service.dart:81-93,198-212` |
| 4 | Dismissed artefacts carry `reviewed=true`, polluting the "Confirmed" filter | bug (correctness) | **Every** dismissed artefact appears under "Confirmed" wearing a "Dismissed" badge; the curated submit list is wrong the moment anything is dismissed | `confirmed = r.reviewed && !r.dismissed`; optionally per-chip counts | S | `first_light_view.dart:248`; `transient_detections_dao.dart:85-92` |
| 5 | No "Chase it" / re-image action despite copy telling the user to | missing-feature | The core loop (confirm before it fades) is left manual: hand-copy sexagesimal coords on a phone in the dark; many lose the candidate. Narrator literally says "Re-image to confirm" | Add "Chase"/"Send to planner" on card + celebrate banner seeding a target/sub-sequence at the candidate RA/Dec; reuse existing `SlewDropdownButton`/`mountCommandServiceProvider` (already backend-routed for slaves) | M–L | `transient_candidate_card.dart:311-381` |
| 6 | Remote-slave triage badge goes stale after Confirm/Dismiss | bug | On the primary night tablet, Confirm/Dismiss shows a success snackbar but the card doesn't change until an unrelated event arrives; user re-taps, distrusts it | After successful remote triage, `ref.invalidate(firstLightCandidatesProvider)` or optimistically patch from the row the host already returns; or host emits a firstlight-changed event | S | `transient_candidate_card.dart:284-307`; `session_science_operations.dart:323-331`; `first_light_handlers.dart:60-108` |
| 7 | No push/notification on a real candidate | missing-feature | "We caught something while you slept" only surfaces as an in-app banner nobody is looking at; time-critical chase window lost by morning | On high-confidence unnamed `newSource`, fire a push deep-linking to the candidate, gated by a toggle; add a transient category to the notification matrix | M | narrator→push bridge absent; `imaging_records_repository.dart:771-777` |
| 8 | Card is a terminal tile — no detail screen, no multi-night light curve, no atlas link | ux-gap | Discoverer's core question ("is it real and changing?") is unanswerable; same transient over 3 nights = 3 unrelated cards. No detail screen (unlike Your Sky) | Tappable detail view: group detections within match radius across nights into a Δmag-vs-time curve, show position on planetarium/Your Sky, surface frame context; grouping also makes "Confirmed (seen 3 nights)" meaningful | XL | `transient_candidate_card.dart` (no onTap); no `first_light` detail screen |
| 9 | Cutout strip is a painted schematic ellipse, never real pixels (+ no on-screen "schematic" disclaimer) | ux-gap / trust | The first triage move is to eyeball the postage stamp to reject hot pixels/satellites; a cartoon blob can't do that and always looks clean. "Schematic" exists only in code comments | Min now: visible "Schematic — from measured shape, not raw pixels" caption + `Semantics` label. Then: request per-detection template/frame/residual crops in `scanFrame` (native crop work — flag isn't enough), persist + serve them, render real pixels with schematic fallback | S (label) / L (real pixels) | `cutout_strip.dart`; `first_light_service.dart:164-171`; `difference_image.rs:250-258` |
| 10 | Tile-coverage counters produced + decoded but never consumed | missing-feature | A thin-atlas no-op is indistinguishable from a clean sky; on sparse regions the pillar silently does nothing and reads as broken; logs say "no residuals" when truth is "every tile too thin" | Decode + log `tilesChecked/tilesSkippedThin/tilesNoTemplate` in `scanFrame`; surface "Atlas not deep enough here yet" | M | `first_light_service.dart:173-185`; `difference_image_seam.dart:18-19` |
| 11 | Submit allowed on any candidate (incl. dipoles/unreviewed) despite "confirmed" copy | functional-gap | One-tap-Submit a low-confidence dipole/registration artefact → TNS "possible supernova" false alarm the networks discourage | Gate Submit on `reviewed==true` and exclude `kind==dipole`, or drop the "confirmed" claim + add a not-yet-confirmed warning | S | `transient_candidate_card.dart:313-320`; `transient_report_panel.dart:215-231` |
| 12 | `transient_detections` has no retention/pruning — grows unbounded | data-scale | Multi-season runs accumulate dozens–hundreds of rows/night forever; sessionless rows never reclaimable; this codebase prunes every other append-only log | Add `pruneDetections({olderThan, keepUnreviewedUnnamed})` age-out of dismissed/artefact rows on the existing maintenance schedule | M | `transient_detections_dao.dart` (insert/read/markReviewed only) |
| 13 | UI feed + REST read the **entire** history with no LIMIT | data-scale | After months, multi-thousand-row payload reserialized/re-rendered on every write; jank + bandwidth waste on the companion-at-night target | Add `watchRecentDetections({limit=200})` + limit/offset on the REST endpoint; default feed to recent N, page older | M | `transient_detections_dao.dart:61-65`; `first_light_handlers.dart:40` |
| 14 | Dismissed-suppression full-table-scans unindexed every frame | data-scale | Per-frame suppression cost grows with all-time dismissed history (never deleted); on the host during imaging | Scope query to covered `tileId IN (...)` using existing `idx_transient_detections_tile`, or a coarse `(tileId, quantized ra/dec)` signature table (DAO doc already promises `dismissedTileSignatures`) | S–M | `transient_detections_dao.dart:78-82`; `first_light_service.dart:189,447-462` |
| 15 | First-run explainer missing — ≥5-frame template-depth gate is invisible | ux-gap | New region produces nothing for hours; user can't tell working-as-intended from broken; no nudge to deep regions | First-run card/richer empty state explaining differencing + the depth gate + a live "X of your tiles are deep enough tonight" readout (data already on the wire envelope) | M | `first_light_view.dart:85-128,280-323` |
| 16 | Fold+scan run serialized in one fire-and-forget hook, no concurrency guard | data-scale | A sequencer dumping queued solves stacks concurrent multi-tile native passes contending with live capture/guide/solve | Single-flight Lock/sequential runner per host; consider lower-priority queue for the scan vs latency-sensitive fold | M | `imaging_records_repository.dart:340-348,683-712` |
| 17 | No v51→v52 migration round-trip test | data-scale (test) | If the `_tableExists` guard or FK ordering regresses, a pre-v52 upgrade loses First Light silently; only a v52→v53 test exists | Add v51→v52 round-trip test asserting all four tables/indexes exist + round-trip an insert | S | `migration_v52.dart:21-38` |
| 18 | `scanFrame` mis-slices Narrator rows when two scans share a wall-clock second | bug | A fresh transient in a back-to-back batch can be skipped from the live announcement (still persisted/visible) | Return inserted ids and re-read exactly those, or add `OrderingTerm.desc(id)` tiebreak + filter to inserted ids | S | `first_light_service.dart:241-246`; `transient_detections_dao.dart:38-42` |
| 19 | Report panel detail tile shows raw wire enum (`pointBrightening`) | ui-defect | Leaked camelCase developer text at the exact moment the user chooses what to submit | Map through `TransientKind.fromWire` + existing `_kindLabel` | S | `transient_report_panel.dart:369` |
| 20 | Filter chips lack a11y selected-state semantics; selected uses `primary` not surface `accent` | ui-defect (a11y) | Screen-reader users get no "selected" announcement on the active filter; selected chip visually off-theme | Wrap chip in `Semantics(button:true, selected:selected, label:)` in `SkotiqChip` (helps every screen) | S | `skotiq_chip.dart:65-71`; `first_light_view.dart:217-224` |
| 21 | Report panel off-design-system (raw `TextStyle`, magic paddings) | ui-defect | Subtly inconsistent spacing/weight vs cards; fragile under theme/scale | Port to `SkotiqTokens`/`SkotiqTypography` | M | `transient_report_panel.dart:65-136,339,359-375` |
| 22 | Duplicated SNR `5.0` magic constant across Rust↔Dart | code-quality | Silent-drift hazard if either is tuned in isolation | Pass `minSnr` explicitly from Dart into the difference args (single source of truth); same for dedup/match radius | S | `first_light_service.dart:117,164-171`; `stats.rs:194` |

## 5. Recommended ship plan

**Minimum P0 set to call it production-ready** (the line for shipping a flagship discovery pillar honestly):

1. **#1 Difference-before-fold** (M) — without this, the feature systematically suppresses the very transients it exists to find. This is the single most important fix.
2. **#2 Δmag sign** (S) — a sign-flipped magnitude on the primary card is a science-credibility defect; trivial to fix.
3. **#3 "Submit" honesty + AAVSO fix** (S, copy path) — reframe every "submit … to AAVSO/MPC/TNS" string to "generate a discovery report," retitle the dialog, add the manual-upload note + a deep link, and fix/omit the non-ingestible AAVSO row. Ship the honest-copy version now; defer real network submission (XL) to a follow-up.
4. **#4 Confirmed-filter pollution** (S) — `reviewed && !dismissed`; one-line fix to stop junk masquerading as confirmed discoveries.
5. **#6 Remote-slave triage refresh** (S) — the companion tablet is the primary night surface; a triage action that visibly does nothing is a broken-feeling core interaction.

That set is roughly **1×M + 4×S** — achievable in a single focused pass, and it converts "feels production but isn't" into genuinely production-ready: the science is correct, the card tells the truth, and triage works on the device people actually use at night.

**P1 follow-ups** (the next sprint, in priority order): **#5 Chase action** and **#7 push notification** (together they make the "caught it while you slept → confirm before it fades" loop real — the soul of the feature), then **#9 schematic disclaimer + real cutout pixels**, **#8 detail/light-curve screen**, **#10 tile-coverage feedback** and **#15 first-run explainer** (so a quiet sparse-region night is explainable rather than reading as broken), and the data-scale trio **#12/#13/#14** before the install base accrues a multi-season history. **P2** (#11, #16–#22) are polish/hardening that can land opportunistically.

Honest bottom line: the math is real science and the plumbing is sound — this pillar earns its "most complete of the three" reputation. But P0 #1 and #2 are quiet correctness bugs that undercut the science on the primary surface, and #3 is a trust-eroding overclaim. Fix those five and First Light is shippable; the P1 chase/push/detail work is what turns it from "functional" into the magical capability the vision promises.

---

# Constellation (Pillar C — community swarm)

The key claims verify: no `ensureTarget`/`retract`/`releaseHandoff` callers in app, `since` defaults to epoch, and `mergeSwarmDelta` writes back into the same `basePath` tile that contribute exports. The MAP and findings are sound. Writing the report.

# Constellation (Pillar C — Community Swarm): Ship-Readiness Report

## 1. Verdict

**Not ready — shippable only with fixes.** The federation is genuinely built end-to-end (real native co-add math, a complete hub server, a coherent privacy model, a working happy path), but on the *normal multi-night workflow* it silently corrupts the shared community co-add (double-counting on re-contribute, and pull-then-contribute feeds the swarm's own photons back to the hub), the swarm can't be seeded from a user-stood-up hub, and the headline privacy promise ("subtract your contribution exactly") has no UI to invoke it.

## 2. What works today

The bundled happy path against a populated hub is real, not a stub:

- **Account registration** against a self-hosted hub, with credential/identity/privacy persisted as settings rows, plus a genuine HEALPix-order-mismatch refusal before any data moves.
- **Browse + Join** shared targets from `GET /v1/targets` (tolerant decoding), join state surviving in-session navigation.
- **Contribute (SUMS, first night)** — per-tile cone selection, `exportDelta` → octet-stream `pushTile` with provenance headers, per-tile geometry rejections collected instead of aborting the batch. The **first** contribution is correct.
- **Pull + native trust-scaled blend** — `mergeSwarmDelta` is real and folds community depth into Your Sky; the deepened depth persists (it lives in Pillar A's atlas tables).
- **Follow-the-night** sweep + **Claim baton**, ranked ready-now-then-shallowest.
- **The native federation math** (`merge_signed` additive/subtractive with order/tile/channel guards) and **the hub fusion server** are both fully implemented.

## 3. The gap to "fully functional"

The pillar sells a multi-night loop: *image a field tonight, share it, pull everyone's photons back so faint structure appears faster, come back tomorrow and go deeper.* In reality the loop only behaves on the **first** night against a **server-seeded** hub. Re-contribute the same field a second night and the hub re-adds your **entire** accumulated depth, not just the new night — so the "fused depth" number everyone trusts silently inflates. Pull a field and then contribute it and you ship the **community's** photons back up as if they were your own capture, compounding the corruption. On a hub you stand up yourself there's no button to even create the first shared target. And the privacy keystone — "we can subtract your contribution exactly" — is printed twice in the UI but has no button and no saved id to act on. The result feels like a polished demo that forgets you and, worse, quietly poisons the shared data it exists to build.

## 4. Prioritized backlog

| Pri | Title | Type | User impact | Concrete fix | Effort | File pointer |
|-----|-------|------|-------------|--------------|--------|--------------|
| **P0** | Pull-then-contribute feeds the swarm's own photons back to the hub | bug | Contribute-after-pull re-uploads community depth as your capture; compounds the shared co-add corruption per cycle, per participant — the inverse of federation's purpose | Keep swarm depth out of the contributable base: blend into a separate `swarm/<order>/<tileId>.nst` overlay composited only at read time, **or** tag foreign folds (the `contributor` field already exists) and have `export_delta_impl` exclude non-local folds | XL | `sky_atlas_service.dart:396,402` (writes blend into base tile); `bridge/src/api/sky_atlas.rs:648-692` (export reads same base); `imaging/src/sky_atlas.rs:1145` (folds.push) |
| **P0** | Repeat contribution double-counts the shared co-add (`since=epoch` ships whole tile) | bug | Second-night contribute re-adds ALL prior frames; "fused depth" + contributor-weight math become silently wrong for everyone | Persist a per-(hub,tile) contribution high-water mark in a Drift table, pass it as `since`, and ship true post-anchor frame/second deltas (not `tile.totalFrames`). Until then, block/warn on an already-contributed tile | L | `constellation_service.dart:297,315,321-322`; native guard `bridge/src/api/sky_atlas.rs:674-692` |
| **P0** | Pull & Blend re-folds the full community delta into the local atlas on every tap | bug | Each "Refresh blend" tap re-adds the entire (growing) community stack to your personal atlas; Your Sky depth becomes physically impossible; `.nst` sidecar grows unbounded | Make `mergeSwarmDelta` idempotent: track last-merged hub revision/high-water per tile and subtract-then-reapply on refresh, **or** merge into the separate overlay sidecar (shares the P0 above's fix) | L | `constellation_service.dart:405-417`; `sky_atlas_service.dart:390-403`; `imaging/src/sky_atlas.rs:1128,1143` |
| **P0** | No way to create/propose a shared target — swarm can't be seeded from the app | missing-feature | On any user-stood-up/empty hub the core loop is dead at step one; the empty-state hint promises a contribute-to-seed flow with no entry point | Add `ConstellationClient.ensureTarget` (`POST /v1/targets`) + `ConstellationService.proposeTarget`, and a "Share one of my targets" CTA seeded from local atlas coverage | L | client has no POST to `hub_server.dart:172`; `constellation_screen.dart:413-414` (dead hint); `shared_target_detail_screen.dart:73-77` (only entry gated on existing target) |
| **P1** | Retract is wired native+wire but has zero UI + no persisted `contributionId` | missing-feature | The headline privacy promise ("subtract exactly to restore prior depth") is structurally unfulfillable; the reason a privacy-conscious imager opts in at all | Persist `ContributionReceipt.contributionId` per tile in the new Drift table; add a per-target "Your contributions" list with a Retract action wired to `ConstellationService.retract`; same-session in-memory fallback | L | `constellation_service.dart:447` (impl, 0 callers); promise text `constellation_contribute_sheet.dart:120-122`, `shared_target_detail_screen.dart:437-438`; `constellation_models.dart:85` |
| **P1** | No persistence of join / swarm-pull / contribution state | ux-gap | Every relaunch re-locks Contribute/Pull behind Join, drops the BLENDED pill, and loses all retractable history; "come back tomorrow" loop resets nightly | Add a Drift table (joined targets, pulled-tile index + high-water marks, contribution receipts) behind a migration; rehydrate `_joined`/`_swarm` on init. (This is the shared substrate for the two P0 high-water fixes and the Retract P1) | L | `constellation_service.dart:23-25,128,131`; `shared_target_detail_screen.dart:38-42` |
| **P1** | Constellation fully interactive on a slave/tablet where it silently can't work | ux-gap | The headline remote-companion device shows enabled Contribute (reading **host** depth) but `contributeTarget` reads the **empty local** atlas → no-op snackbar; Pull blends into a store the slave never surfaces | Route contribute/pull through the host's headless_api, **or** detect slave mode and disable host-only actions with a "Contributing runs on your imaging host" notice; reconcile the contribution-bar source | L | `constellation_provider.dart:42-43` (local atlas); `constellation_ui_providers.dart:90` (host-aware bar); zero `isRemote` in `screens/constellation/` |
| **P1** | Follow-the-night queries hub with LOCAL DB row ids → wrong-target baton | bug | When a local row id collides with an existing hub `shared_targets.id` (both small autoincrement ints — likely), a Claim takes the baton for the *wrong* sky, defeating anti-double-collect | Build candidates only from JOINED hub ids, or carry an explicit `hubTargetId` on the local row; drop the `...byId.keys` union | M | `constellation_provider.dart:55`; `constellation_service.dart:484,487`; `constellation_screen.dart:323` |
| **P1** | "Your contribution" bar reads post-blend inflated index → lies after a pull | bug | The instant you pull, your "share" bar and per-target depth jump to include the whole community stack, overstating your contribution and making the share ratio meaningless | Track personal integration separately from blended swarm depth (dedicated column/sidecar); have the bar read the personal figure (folds out of the same overlay-sidecar P0 fix) | M | `sky_atlas_service.dart:404-425`; `constellation_ui_providers.dart:90-106`; `contribution_bar.dart` |
| **P1** | No rig-side test for repeat-contribute / release / persistence | code-quality | The highest-risk shipping paths have no Dart regression gate; the P0 double-count can regress undetected | Add `ConstellationService` tests: (a) contribute same tile twice → assert incremental-only delta (fails today, gates the fix), (b) `releaseHandoff` called, (c) join/swarm survive re-instantiation | M | rig constellation tests under `packages/skotiq_core/test/` |
| **P2** | Follow-the-night baton never released + never feeds planner | missing-feature | User holds duty indefinitely (relies on hub auto-expiry); "image it tonight" is just a snackbar with no scheduling teeth | Add a Release affordance on held cards wired to `releaseHandoff`; add a "Plan tonight" action pushing the target into the planner/sequencer | M | `constellation_service.dart:538` (0 callers); `constellation_screen.dart:330` |
| **P2** | After Pull & Blend the deeper sky never visibly appears | ux-gap | The emotional payoff ("others' photons deepened my sky") lands off-screen; only a count pill + "go look elsewhere" copy, no before/after, no deep link | Show "12h → 47h fused" before/after from the merge's returned totals + a tappable preview deep-linking to the Your Sky region (`getRegionForPoint`) | M | `shared_target_detail_screen.dart:380-400`; `RegionDetailScreen(regionId:)` |
| **P2** | SUBS rendered as a selectable option that always throws on submit | ui-defect | At the most trust-sensitive moment a user can pick "Share raw subframes," consent, tap Contribute, and only then hit an error; the static reassurance banner also contradicts the SUBS selection | Hide SUBS or render it disabled/"coming soon"; make the "you only share sums" banner conditional on `_privacy`; don't persist a refused choice | S | `constellation_contribute_sheet.dart:108-123`; `constellation_service.dart:286-292` |
| **P2** | Swarm pull/delta files accumulate on disk with no cleanup | data-scale | Slowly-growing working set of `.nst`/`.fits` blobs on the same disk as capture storage on a constrained appliance | Delete the exported delta after a successful `pushTile`; add an age/size-bounded sweep of `root/swarm` + `root/cache` | M | `constellation_service.dart:393-399`; `sky_atlas_service.dart:294` |
| **P2** | `coverage()` full-tile scan drives cone selection at scale | data-scale | Every Contribute/Pull/Your-Sky render materializes ALL tiles ever imaged and filters in Dart; latency scales with atlas size, not cone | Compute in-cone HEALPix tile ids and look them up via the unique `(tileId,order)` index, or a Dec-band prefilter on indexed `centerDecDeg` | M | `constellation_service.dart:577-590`; `sky_atlas_service.dart:260-275` |
| **P2** | Hub onboarding bare URL entry; sign-out leaves identity behind | ux-gap | First-run requires typing the hub URL from memory (no LAN discovery); sign-out clears only URL/token, leaving display name + key/privacy persisted | Add hub mDNS prefill for the URL; on sign-out clear the full identity set (or scope per hub). (Token-refresh is NOT needed — default signup tokens never expire) | M/S | `constellation_sign_in_sheet.dart:85-108`; `constellation_screen.dart:248-254` |
| **P2** | Dead code: `swarmTilesProvider`, unused `_swarm`/`swarmTiles`, `finalized:true` default, shadow `_joined` bool | code-quality | Latent footguns (side-effect-in-build pull provider; dangerous default that silently no-ops the blend); two-sources-of-truth join state | Delete `swarmTilesProvider`; flip `pullTarget` default to `finalized:false`; trim `SwarmTile` to consumed fields; drive detail-screen `_joined` off the service | S | `constellation_provider.dart:89-96,363`; `shared_target_detail_screen.dart:29` |

## 5. Recommended ship plan

**Minimum P0 set to call it production-ready** — fix the data-integrity core, because a community-trust feature that silently corrupts the shared co-add on the normal workflow is worse than not shipping:

1. **Persistence Drift table first** (P1 persistence row) — it is the prerequisite substrate for the two contribution high-water fixes and Retract. Land this even though it's tagged P1, because the P0 fixes depend on it.
2. **Separate the swarm-blend sidecar from the contributable base** — one architectural change (overlay sidecar composited at read time) fixes *three* P0/P1 bugs at once: pull-then-contribute re-upload, non-idempotent re-blend, and the inflated "your contribution" bar.
3. **Per-tile contribution high-water + true deltas** — kills the repeat-contribute double-count; gate the contribute button on an already-contributed tile as a belt-and-suspenders.
4. **`ensureTarget` + "Share one of my targets" CTA** — without it any self-hosted hub is dead-on-arrival.
5. **Regression test** the repeat-contribute path (P1 test row) as the gate for #3.

Ship-block until 1–5 are green via full CI gates (`melos run test` + the launch gates), not subset runs.

**P1 follow-ups (next release, before the swarm is promoted as a headline):** wire Retract to the now-persisted `contributionId`; gate or host-route Constellation on slave/tablet (the flagship companion device currently presents fake-functional buttons); fix the follow-the-night local-id/hub-id collision.

**P2 (polish):** baton release + planner wiring, the Pull & Blend before/after payoff, SUBS disable + banner fix, disk retention, the cone-query spatial index, onboarding/sign-out hygiene, and the dead-code sweep.

Note: this report excludes the prior-audit items already fixed (SUBS toggle no-op, pull-not-blending, the prior unreachable-retract *promise-text*, slave empty-atlas read, First Light positionAngleDeg) — they were not re-counted.

---

# Appendix: all 116 confirmed findings

| Pillar | Type | Severity | Title |
|---|---|---|---|
| constellation | bug | blocker-to-ship | Re-contributing the same field silently double-counts and corrupts the community co-add |
| constellation | bug | blocker-to-ship | Repeat contribution to the same tile double-counts on the hub (since=epoch + whole-tile export) |
| constellation | bug | blocker-to-ship | Pull-and-blend re-folds the full community co-add into the local atlas every press, double-counting (then N-counting) your own light locally |
| constellation | bug | blocker-to-ship | Contribute-then-pull-then-contribute feedback loop folds community data back into the hub on top of itself |
| constellation | missing-feature | high | No way to create/propose a shared target — the swarm can never be seeded from the app |
| constellation | ux-gap | high | Join / pulled-swarm / contribution state evaporates on every app restart |
| constellation | missing-feature | high | Privacy promise of "subtract your contribution exactly" is unreachable — no Retract or contribution-history UI |
| constellation | ux-gap | high | Constellation tab is fully interactive on a slave/tablet but silently can't contribute or show blended depth |
| constellation | bug | high | Pull-and-blend contaminates the local base tile, so the next Contribute re-uploads the swarm's own depth (or errors out) |
| constellation | missing-feature | high | Retract is fully implemented on the wire + native but has zero UI entry point and no persisted contributionId |
| constellation | missing-feature | high | No persistence of join / swarm-cache / contribution state — Constellation resets on every app restart |
| constellation | ux-gap | high | Constellation is fully interactive on a SLAVE/remote node but silently does nothing useful (no gating, no warning) |
| constellation | ux-gap | high | Constellation tab is fully interactive on a slave/remote node where it silently can't work |
| constellation | bug | high | Repeat contribution ships the WHOLE tile accumulator (since=epoch), so the hub over-counts on every re-contribution |
| constellation | bug | high | Follow-the-night queries the hub with LOCAL target-table row ids — wrong-target baton state and wrong-sky claims |
| constellation | bug | high | yourContributionSeconds and SwarmTile depth read the post-blend inflated index, so 'your share' bars lie after a pull |
| constellation | code-quality | high | No rig-side test covers repeat contribution, follow-the-night release, or persistence-across-restart — the highest-risk shipping paths |
| constellation | bug | high | Pull & Blend re-merges the FULL community delta into the local atlas on every tap, double-counting depth and bloating the .nst sidecar without bound |
| constellation | bug | high | Pull blends community frames into the same sidecar that Contribute exports, so a contribute-after-pull re-uploads the swarm's own frames back to the hub |
| constellation | missing-feature | high | No persistence of join / swarm-pull / contribution state — all Constellation session state is lost on every app restart |
| constellation | bug | high | Repeat contribution to the same tile re-ships the whole accumulator with full frame totals (since defaults to epoch), over-counting the shared co-add every time |
| constellation | missing-feature | medium | Follow-the-night baton has no Release, and never feeds the planner/scheduler |
| constellation | ux-gap | medium | After Pull & Blend, the deeper sky never visibly appears — the payoff is invisible |
| constellation | missing-feature | medium | Follow-the-night baton is claimed but never released from the UI (half-open handoff loop) |
| constellation | missing-feature | medium | SUBS privacy option is a permanently non-functional choice presented as a real toggle |
| constellation | ux-gap | medium | SUBS privacy card is fully selectable + sells an unbuilt feature, then errors on submit |
| constellation | ui-defect | medium | Contribute sheet's privacy reassurance contradicts the SUBS selection it sits under |
| constellation | ux-gap | medium | Blend card instructs "Open Your Sky to scrub the combined depth" with no way to get there |
| constellation | code-quality | medium | releaseHandoff is implemented end-to-end but has zero callers — the follow-the-night baton lifecycle is half-open |
| constellation | ui-defect | medium | Contribute sheet renders SUBS as a fully selectable option that always throws on submit (logic/UI mismatch baked into the screen) |
| constellation | data-scale | medium | First Light dismissed-artefact suppression does a full unindexed table scan and O(candidates × dismissed) match on every solved frame |
| constellation | data-scale | medium | Swarm pull cache and contribution delta files accumulate on disk with no cleanup or retention |
| constellation | data-scale | medium | coverage() full-tile scan drives contribute/pull cone selection and the atlas read path, with no spatial pre-filter at scale |
| constellation | ux-gap | low | SUBS is a visible privacy option that always errors on submit |
| constellation | ux-gap | low | Hub onboarding is bare manual URL entry — no LAN discovery, no token-refresh |
| constellation | bug | low | Sign out leaves display name, privacy choice, and public key behind; no token re-login path |
| constellation | ux-gap | low | Non-ready Follow-the-night cards are inert dead-ends (no claim, no tap, no path forward) |
| constellation | ux-gap | low | Join state resets every launch with no indication, so unlocked Contribute/Pull silently re-lock |
| constellation | code-quality | low | swarmTilesProvider is dead code AND performs a disk-writing pull inside provider build (side-effect-in-build anti-pattern) |
| constellation | bug | low | pullTarget default `finalized: true` contradicts every caller and the documented blend payoff |
| constellation | code-quality | low | Great-circle (haversine) separation is copy-pasted across 5 sites including two inside Pillar C |
| constellation | code-quality | low | SwarmTile carries write-only fields and the _swarm cache / swarmTiles getter have no consumers |
| constellation | bug | low | Detail screen mirrors join state in a local bool, diverging from the service's _joined map |
| first-light | missing-feature | high | No "chase it" action — a discovery can't be turned into the very next exposure or a follow-up plan |
| first-light | ux-gap | high | Candidate card is a terminal tile — no tap-to-detail, no light-curve / multi-night history, no link to the atlas or sky position |
| first-light | missing-feature | high | "Submit to AAVSO/MPC/TNS" never submits — only writes a local file, but the AAVSO report it writes is not even ingestible |
| first-light | bug | high | Frame is folded into the atlas template BEFORE it is differenced against that same template (self-subtraction) |
| first-light | ux-gap | medium | "Submit a real discovery report to AAVSO/MPC/TNS" promises a submission the app never performs — it only writes a file |
| first-light | ux-gap | medium | Cutout strip is a schematic ellipse, never the real pixels — and the native residual stamp is never even requested |
| first-light | bug | medium | Remote-slave triage badge goes stale after Confirm/Dismiss until an unrelated capture event arrives |
| first-light | missing-feature | medium | No notification/push when a real candidate is found — discovery only surfaces if the user happens to be on the First Light tab |
| first-light | ux-gap | medium | No "chase"/follow-up action despite the feature and Narrator explicitly telling the user to re-image to confirm |
| first-light | bug | medium | Remote-slave triage badge never refreshes after Confirm/Dismiss (no invalidate, no event) |
| first-light | ux-gap | medium | Cutout panels present painted schematics as if they were real pixels — no on-screen disclaimer |
| first-light | ux-gap | medium | Submit flow UI claims real network submission to AAVSO/MPC/TNS; it only writes a file/clipboard |
| first-light | bug | medium | Remote-slave triage leaves stale Confirmed/Dismissed badge — no invalidation, no SnackBar truth |
| first-light | ux-gap | medium | 'All' / 'Confirmed' filters and badges produce contradictory, confusing membership |
| first-light | bug | medium | Dismissed artefacts also carry reviewed=true, so they pollute the 'Confirmed' filter |
| first-light | bug | medium | Remote-slave triage badge never refreshes after Confirm/Dismiss (no event, no invalidate) |
| first-light | bug | medium | Δmag chip on the candidate card inverts the astronomical magnitude sign (shows "+0.50 mag" for a BRIGHTENING) |
| first-light | missing-feature | medium | Difference-result observability fields (tilesChecked / tilesSkippedThin / tilesNoTemplate) are produced + decoded but never consumed — a thin-atlas no-op is indistinguishable from a clean sky |
| first-light | bug | medium | Remote-slave triage never invalidates firstLightCandidatesProvider, so the card's Confirmed/Dismissed badge goes stale on a companion tablet |
| first-light | data-scale | medium | transient_detections has no retention/cleanup — the discovery log grows unbounded forever |
| first-light | data-scale | medium | Dismissed-position suppression does a full-table scan with no index, on the imaging loop, growing every night |
| first-light | data-scale | medium | UI feed and REST endpoint read the ENTIRE detection history with no LIMIT |
| first-light | data-scale | medium | No dedicated migration test that creates transient_detections on a real older DB through the v2–v17 recreate chain |
| first-light | data-scale | medium | First Light scan runs the heavy native difference pipeline serialized behind the atlas fold in one fire-and-forget hook, with no concurrency guard |
| first-light | ux-gap | low | No first-run explainer or "what to expect" — the empty state and intro assume the user already understands difference imaging |
| first-light | ux-gap | low | Submit panel claims "confirmed" detections but lets you submit any candidate, including dipoles/artefacts |
| first-light | ui-defect | low | Cutout strip is a schematic ellipse, not real pixels — a discoverer cannot vet the candidate from the card |
| first-light | ui-defect | low | Filter chips have no a11y semantics for selected state and use primary instead of the surface's accent |
| first-light | ui-defect | low | Report panel is heavily off-design-system: raw TextStyle, magic-number paddings, no tokens |
| first-light | ui-defect | low | Detection tile in report panel shows the raw wire enum string for kind |
| first-light | bug | low | scanFrame returns the wrong rows to the Narrator when two scans land in the same wall-clock second |
| first-light | data-scale | low | Dismissed-position suppression loads all-time dismissed rows unindexed on every scanned frame |
| first-light | missing-feature | low | "Submit to AAVSO / MPC / TNS" has no network-submission seam at all — report service is string-generation only, yet two surfaces' copy promises submission |
| first-light | code-quality | low | SNR floor is a duplicated magic constant across the Rust↔Dart boundary (native default 5.0 vs Dart _minSnr 5.0) — silent drift hazard |
| your-sky | missing-feature | blocker-to-ship | The entire region layer is dead: nothing ever creates a region from the active target, so the cutout/scrub/growth/provenance experience is unreachable in normal use |
| your-sky | missing-feature | blocker-to-ship | No region can ever be created: the entire region layer (cutout, scrub, growth, provenance, region cards) is unreachable dead code |
| your-sky | missing-feature | blocker-to-ship | Region layer is dead code: no path ever creates a region or assigns a tile, so the entire region UX is unreachable |
| your-sky | ux-gap | high | Atlas-wide growth ('X deeper than yesterday') is never surfaced where the user actually looks — it lives only on the unreachable region card |
| your-sky | bug | high | RegionDetailScreen, AtlasTilePreview and the tile/growth/provenance providers are local-only despite 'backend-agnostic' docstrings — blank on every slave |
| your-sky | bug | high | AtlasTilePreview loads a local FILE PATH, so it can never render remotely even if a remote tile method existed |
| your-sky | bug | high | Time-scrub slider errors out (imageOff) on every past position because native tilePng refuses asOf reconstructions |
| your-sky | ux-gap | high | Time-scrub always breaks the cutout image for any past stop — the headline feature shows a broken-image icon |
| your-sky | ux-gap | high | 'Name a region to track its depth' copy promises an affordance that does not exist anywhere on screen |
| your-sky | bug | high | Concurrent auto-folds of the same tile silently lose frames (no lock; shared .skt.tmp) |
| your-sky | missing-feature | high | Region layer is unreachable dead code: nothing ever creates a region |
| your-sky | bug | high | RegionDetailScreen / AtlasTilePreview are local-DB/FFI-only despite docstrings claiming 'backend-agnostic' |
| your-sky | data-scale | high | Coverage read deserializes every 40 MiB tile sidecar off disk on every call (host AND slave poll) |
| your-sky | data-scale | high | Single wide-field frame rewrites ~2 GiB of tile sidecars; one solved sub permanently allocates ~2 GiB of .nst on disk |
| your-sky | bug | high | Concurrent fire-and-forget folds on the same tile lose updates (no fold serialization) |
| your-sky | ux-gap | medium | No closing loop from imaging/session/post-session into Your Sky — the atlas only deepens silently, never reaches back to the user |
| your-sky | ux-gap | medium | No export / 'do something with it' affordance — the deep co-added cutout is a dead end the user cannot save, share, or set as a target reference |
| your-sky | missing-feature | medium | No spatial all-sky map view — coverage is a context-free heat STRIP, not a sky you can see filling in region-by-region |
| your-sky | missing-feature | medium | First-run / onboarding makes the atlas look broken: empty state and 'name a region' hint reference affordances and a fold step that don't exist |
| your-sky | missing-feature | medium | 'Co-added cutout' panel renders a single deepest tile, not the region co-add; service.cutout() and the /cutout route are dead |
| your-sky | missing-feature | medium | Native growth curve and tile provenance APIs are built and wired through providers but never displayed |
| your-sky | ux-gap | medium | Depth heat map is unreadable and inert on a phone — hover-only tooltips, 18px cells, no tap target |
| your-sky | ux-gap | medium | RegionDetail cutout is a single deepest tile but the whole UI frames it as the region's co-added cutout |
| your-sky | bug | medium | Phantom zero-frame tiles pollute the DB index + timeline (cone over-coverage) |
| your-sky | bug | medium | Re-solving a frame double-folds it into the atlas (no frame-identity dedup) |
| your-sky | bug | medium | RegionDetailScreen + AtlasTilePreview are NOT backend-agnostic — blank on a slave despite docstrings |
| your-sky | missing-feature | medium | No headless route serves a tile PNG, so the region card/cutout preview can never render on a slave |
| your-sky | code-quality | medium | Duplicated file-private region providers in two widgets, both local-only and separately maintained |
| your-sky | code-quality | medium | Per-fold integration seconds are approximated because the bridge summary omits the exact increment the native side already has |
| your-sky | code-quality | medium | Remote atlas snapshot stream swallows every fetch error silently, so a broken host looks like an empty atlas |
| your-sky | data-scale | medium | No retention/cleanup for the cutout + delta cache; it grows forever |
| your-sky | bug | medium | Region cutout outPixels is attacker/typo-controlled and unbounded — host OOM from a companion request |
| your-sky | code-quality | low | Duplicate divergent _regionTilesProvider/_regionTimelineProvider in two files, both local-only |
| your-sky | ui-defect | low | Empty-state flashes 'Your sky is dark' before coverage loads, because the body gates on regions only |
| your-sky | ux-gap | low | No accessibility semantics on the entire Your Sky surface — heat map, stats, and scrub are invisible to screen readers |
| your-sky | ui-defect | low | Region "cutout" panel shows a single tile, not the co-added region cutout |
| your-sky | code-quality | low | Per-fold integration seconds are approximated because the bridge drops the exact value |
| your-sky | code-quality | low | Headless atlas handlers have zero test coverage and _findRegion does a full-table scan per request |
| your-sky | data-scale | low | Per-frame provenance fold log grows unbounded inside the rewritten-every-fold JSON header (O(n²) write amplification) |
