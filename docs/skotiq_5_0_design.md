# Skotiq 5.0 — "The Living Sky" — design spec

The headline of 5.0 is that every photon you capture stops being a throwaway sub
and becomes a permanent brick in a **growing, all-sky, multi-night atlas** —
yours, and (opt-in) the community's. Three things fall out of that one idea:
your sky becomes a place you can revisit and scrub through time (**Your Sky**),
the atlas becomes a reference template that lets the app *find what changed*
between tonight and every night before it (**First Light**, transient/difference
discovery), and many observers' atlases co-add into one deeper sky without ever
shipping a single sub off anyone's disk (**Constellation**).

All three rest on one new piece of math — the **keystone**: a HEALPix-tiled,
SIP-aware, *additive* WCS sky accumulator. It is the multi-night
`IntegratedMaster` (`master_accumulation.rs`) generalised from a single fixed
pixel grid to the whole celestial sphere, and made *mergeable* so two people's
running sums combine by addition.

This document is the architecture and data-flow narrative. The companion
`docs/skotiq_5_0_contracts.md` is the verbatim interface contract (exact
names, signatures, JSON shapes, column lists); builder agents conform to **that**
file. Where the two ever disagree, the contracts file wins.

---

## 0. The keystone — the additive WCS sky accumulator

### 0.1 Why the existing master is the seed (and where it stops)

`IntegratedMaster` already proves the core property 5.0 needs: a per-pixel
**weighted mean** decomposes into running sums (`sum_w`, `sum_wx`, `sum_wx2`,
`sum_w2`, `coverage`, `rejected`) that are **exactly additive across disjoint
batches**. Folding night-2 into night-1 is bit-for-bit identical to integrating
both at once, and the state serialises to a resumable sidecar (`NSM1`). That is
*precisely* the algebra a federated co-add wants: if my sums and your sums live
on the same grid, `merged = mine + yours` is the correct deeper stack, computed
without re-reading a single sub.

It stops at one place: **a single fixed pixel grid**. There is no tiling, no
sphere, and the reprojection engine that *could* place arbitrary frames onto a
common grid (`mosaic_stitch.rs`) is CD-only (no SIP) and builds one bespoke
tangent-plane canvas per call.

The keystone removes that limit: the sky is partitioned into **HEALPix tiles**,
each tile is its own small `IntegratedMaster`-style additive accumulator on a
fixed local TAN grid, and frames are reprojected into the tiles they touch using
the **full CD + SIP** astrometry the plate solver already produces.

### 0.2 The two new Rust modules

**`native/skotiq_native/imaging/src/wcs_sip.rs`** — SIP ported from the Dart
reference (`gnomonic_projection.dart`). A `SipWcs` value carries the CD matrix +
forward (A/B) and inverse (AP/BP) SIP terms (row-major `i*(order+1)+j`, matching
`PlateSolveResult`). It exposes `world_to_pixel` / `pixel_to_world` that apply
SIP (Newton-iteration inverse fallback when AP/BP are absent, exactly as the Dart
code does). This is the generalisation of `mosaic_stitch.rs::WcsProjection` from
CD-only to CD+SIP, and it is the projection both the stitcher and the atlas use.

**`native/skotiq_native/imaging/src/sky_atlas.rs`** — the keystone proper:

- **Tile addressing** (HEALPix NESTED, a chosen base `order`/`nside`): map a sky
  cone or a frame footprint to the set of tile ids it covers, and give each tile
  a deterministic local TAN `SipWcs` (centre = tile centre, fixed pixel scale,
  no distortion — the canonical grid every contributor reprojects *onto*). The
  HiPS/HEALPix addressing math already exists in Dart
  (`framing_hips_projection.dart`) as a reference; this is its Rust twin.
- **`SkyTileAccumulator`** — the per-tile additive state. Structurally the
  `PerPixelAccumulator` from `master_accumulation.rs` (the six running vectors)
  plus a frozen `NormalizationReference` and the tile's `SipWcs`. Same
  serialisation discipline as the master (magic + version + JSON header + packed
  payload), magic `"SKT1"`.
- **Reproject-and-fold** — given a frame (`ImageData` + its solved `SipWcs` +
  scalar weight + exposure), for each output tile pixel: world ← tile WCS; pixel
  ← frame WCS (CD+SIP); resample (reuse the Lanczos3/Catmull/Bilinear kernels
  the stitcher already has); fold the sample into that tile's running sums with
  the same online-clip logic as the master. A frame touching four tiles folds
  into four accumulators; nothing is wasted at tile seams because the sums are
  additive and `finalize` re-divides.
- **`merge_tiles`** — add two `SkyTileAccumulator`s for the *same tile id +
  geometry* by summing the six vectors (and unioning provenance). This is the
  federation primitive; it is the master's additivity proof applied per tile.
- **`finalize`** — `sum_wx / sum_w` per pixel → an `ImageData` tile, plus
  coverage/rejection maps, exactly like the master.

The honesty caveat is the same one the master already documents: cross-batch
*online* rejection is not identical to a from-scratch full-population clip; with
`clip: None` the merge is provably exact. We carry that wording over verbatim.

### 0.3 Where tiles live

Tile accumulator sidecars are files under the app data dir
(`<atlas_root>/tiles/<order>/<tileId>.skt`); the DB (`sky_tiles`,
`sky_atlas_regions`) is the **index** over them (which tiles exist, their depth,
coverage, last-folded session, bounding cone), not the bulk pixel store —
exactly the `integrated_masters` (DB row) + `.skmaster` (sidecar) split that
already ships.

---

## A. Pillar — "Your Sky" (personal growing all-sky atlas + time-scrub)

### A.1 The experience

A pan/zoom all-sky view that fills in as you image. Each region you've shot is a
real, integrated tile (not a survey download); zoom in and you see *your* depth.
A **time-scrub** slider replays the atlas as it grew — drag back to "three
sessions ago" and the tile re-finalises from only the folds up to that date.
Coverage and depth are first-class: a heat overlay shows integration time per
tile so you can see your own "deep field" forming and find the holes.

### A.2 Data flow

1. Post-session (or live, opportunistically), each plate-solved light frame is
   handed to the atlas with its `SipWcs` + weight + exposure.
2. `api_sky_atlas` (action `fold`) computes covered tile ids, loads/creates each
   tile sidecar, reproject-and-folds the frame, rewrites the sidecars, and
   upserts `sky_tiles` rows (depth, coverage, totals) + a `sky_atlas_folds` row
   per (tile, session) for the time-scrub history and provenance.
3. `sky_atlas_regions` groups tiles into named user regions (a target, a mosaic,
   "north polar") for the gallery and for region-scoped finalize/export.
4. The UI requests finalized tile rasters (`api_sky_atlas` action `tile_png`,
   optionally `as_of` a date for the scrub) and a coverage summary
   (action `coverage`).

### A.3 Files

Create:
- `native/skotiq_native/imaging/src/wcs_sip.rs`
- `native/skotiq_native/imaging/src/sky_atlas.rs`
- `native/skotiq_native/bridge/src/api/sky_atlas.rs` (`api_sky_atlas`)
- `packages/skotiq_bridge/lib/src/api/sky_atlas.dart`
- `packages/skotiq_core/lib/src/database/tables/sky_atlas_tables.dart`
  (`SkyTiles`, `SkyAtlasRegions`, `SkyAtlasFolds`)
- `packages/skotiq_core/lib/src/database/daos/sky_atlas_dao.dart`
- `packages/skotiq_core/lib/src/database/database/migration_v52.dart`
- `packages/skotiq_core/lib/src/services/sky_atlas/sky_atlas_service.dart`
- `packages/skotiq_core/lib/src/services/sky_atlas/sky_atlas_models.dart`
- `packages/skotiq_core/lib/src/providers/sky_atlas_provider.dart`
- `apps/desktop/lib/screens/sky_atlas/your_sky_screen.dart`
  + widgets `widgets/sky_atlas/atlas_canvas.dart`, `atlas_timescrub.dart`,
  `atlas_coverage_overlay.dart`, `atlas_region_card.dart`

Edit:
- `native/skotiq_native/imaging/src/lib.rs` (module decls + re-exports)
- `native/skotiq_native/bridge/src/api/mod.rs` (register `sky_atlas`)
- `packages/skotiq_core/lib/src/database/database.dart` (register 3 tables,
  bump `schemaVersion` 51 → 52)
- `packages/skotiq_core/lib/src/database/database/migration_strategy.dart`
  (add `_upgradeSchemaV52` to the chain)
- the skotiq_core barrel (export new public symbols)
- the post-session pipeline hook (`api_integrate_session` / its Dart caller) so
  finishing a session offers "fold into Your Sky".

### A.4 DB additions — see contracts §3 for the exact column list

`sky_tiles` (one row per occupied tile), `sky_atlas_regions` (named groupings),
`sky_atlas_folds` (one row per (tile, session) fold — the time-scrub timeline +
provenance). Added the proper Drift way: `Table` classes registered in
`@DriftDatabase`, generated, with a guarded additive `migration_v52`.

### A.5 Bridge / service / providers / UI — see contracts §2, §4

`api_sky_atlas(action, …)`; `SkyAtlasService` (fold/finalize/coverage/scrub);
`skyAtlasCoverageProvider`, `skyTileProvider(tileId, asOf)`,
`skyAtlasRegionsProvider`. UI surface: a top-level **Your Sky** screen
(planetarium-adjacent) with the canvas, the time-scrub, the coverage heat
overlay, and a region gallery. Follow the skotiq_ui contract (design tokens,
`SkotiqCard` chrome, no overflow, lucide icons).

---

## B. Pillar — "First Light" (difference-imaging transient discovery)

### B.1 The experience

The atlas is the deepest, cleanest record of what your patch of sky *normally*
looks like. So when a new frame comes in, the app reprojects it onto the matching
atlas tile(s), subtracts the atlas template, and surfaces what's *new*:
asteroids/comets streaking through, a star that brightened, a nova/supernova that
wasn't there last week. This is the classic image-subtraction transient pipeline,
with the personal atlas as the reference template — and it plugs straight into the
existing Night Narrator as celebrate-severity discovery cards.

### B.2 Data flow

1. New light frame (live or post-session), plate-solved → `SipWcs`.
2. `api_difference_image`: for each covered atlas tile that has sufficient
   coverage depth, finalize the tile template, reproject the new frame onto the
   tile grid, photometrically match (reuse `estimate_normalization` — the same
   robust line fit the stitcher uses for cross-panel scale/offset), subtract, and
   run `detect_stars` (`stats.rs`) on the **positive** residual to extract
   candidate sources (and on the negative residual to flag dipoles / bad
   subtraction). Each candidate carries position (→ RA/Dec via the tile WCS),
   residual flux, an estimated delta-mag against the template, SNR, and a
   classification hint (point-source brightening vs. moving streak vs. dipole
   artefact).
3. Cross-match candidates against known sources: the planetarium catalogs
   (`CelestialSpatialIndex.queryCone`) for "is this a known star/DSO", the
   photometric standards (`photometric_catalog_service.coneSearch`, APASS) for a
   magnitude baseline, and the existing minor-planet/moving-object machinery
   (`MovingObjectCandidates` + transient screens) for asteroids. A candidate with
   no catalog match and a clean PSF is the headline event.
4. Persist to a new `transient_detections` table (richer than the existing
   `MovingObjectCandidates`, which First Light feeds for the moving subset) and
   emit Narrator drafts through a **new detector** registered in
   `narrator_detectors.dart`.

### B.3 Files

Create:
- `native/skotiq_native/imaging/src/difference_image.rs` (subtraction +
  residual source extraction; reuses `wcs_sip`, `sky_atlas`,
  `normalization::estimate_normalization`, `stats::detect_stars`)
- `native/skotiq_native/bridge/src/api/difference_image.rs`
  (`api_difference_image`)
- `packages/skotiq_bridge/lib/src/api/difference_image.dart`
- `packages/skotiq_core/lib/src/database/tables/transient_detections.dart`
- `packages/skotiq_core/lib/src/database/daos/transient_detections_dao.dart`
- `packages/skotiq_core/lib/src/services/transients/first_light_service.dart`
- `packages/skotiq_core/lib/src/services/science/narrator/detectors/first_light_detectors.dart`
  (`first_light.transient`, `first_light.brightening`, `first_light.mover`)
- `apps/desktop/lib/screens/transients/first_light_screen.dart`
  + `widgets/transients/transient_card.dart`,
  `widgets/transients/difference_triptych.dart` (new / reference / residual).

Edit:
- `native/skotiq_native/imaging/src/lib.rs`, bridge `mod.rs`
- `migration_v52.dart` (add `transient_detections`; same migration as the atlas
  tables — one schema bump, version 52, carries all of 5.0's new tables)
- `database.dart` (register `TransientDetections`)
- `narrator_detectors.dart` (`buildDefaultNarratorEngine` registers the new
  detectors), `narrator_context.dart` (add latest transient candidates to the
  immutable snapshot)
- the skotiq_core barrel.

### B.4 Narrator integration

Reuse the proven pattern from `night_narrator_design.md`: the detectors are pure
`NarratorDetector`s, emit `celebrate`/`success` severities, pin discoveries, and
carry typed `evidenceJson` (`{"kind":"vector",…}` for a streak, `{"kind":"delta",
…}` for a brightening). The difference triptych is the detail-sheet visual.

---

## C. Pillar — "Constellation" (community swarm: federated tile co-add)

### C.1 The experience

Opt-in. Pick a tile (or a target region) and "join the swarm": your tile's
running sums upload to a hub, where they're **added** to everyone else's sums for
that tile, and you pull back the merged deeper tile. A faint object you could
never reach solo emerges from a hundred backyards. Plus **follow-the-night
handoff**: as a target sets in your sky and rises in someone else's, the swarm
hands the still-accumulating tile westward, so a single object integrates around
the globe through one rotation.

This is the first time Skotiq has accounts/identity/trust — today it is
LAN-only with no cloud backend. Constellation introduces a self-hostable hub,
lightweight accounts, and **trust-weighting** so a bad contributor can't poison a
co-add.

### C.2 Why additivity makes this safe and cheap

Because tiles are additive running sums on a shared HEALPix grid, the hub never
needs anyone's subs — only their `SkyTileAccumulator` deltas (the six vectors for
the folds since their last contribution). Merge = vector addition. Trust-weighting
is just a per-contributor scalar multiplied into their weights before summation
(the master already weights every sample; trust is one more factor). A retraction
is a *subtraction* of that contributor's recorded delta — exact, because the math
is linear.

### C.3 Data flow

1. Client computes a per-tile **contribution delta** (the accumulator state for
   the new folds, via `api_sky_atlas` action `export_delta`).
2. Client `POST /v1/tiles/{tileId}/contributions` (bearer token) with the delta
   blob + provenance (frame count, integration seconds, median FWHM, solver,
   instrument fingerprint).
3. Hub validates geometry (same tile id + grid), computes a trust weight for the
   contributor, scales the delta, and folds it into the hub's master tile
   accumulator (`api_constellation_merge_tiles` runs the same Rust `merge_tiles`
   on the server, since the hub is a Dart shelf service that calls the native
   bridge). It records the contribution in `constellation_contributions`.
4. Client `GET /v1/tiles/{tileId}` pulls the merged finalized tile (or the merged
   accumulator, to keep stacking locally). Follow-the-night uses
   `GET /v1/handoff/{targetId}` to claim/relay an active tile.

### C.4 The hub — a new directory `server/skotiq_hub/`

A self-hostable Dart shelf service, built on the **exact patterns** of
`apps/desktop/lib/headless_api_server.dart` (Shelf `Router`, bearer-token
middleware, scopes) and the `skotiq_remote_protocol` crypto
(`server_identity` SHA-256 fingerprints, `token_manager` pairing). It is NOT a
mandatory cloud — a user can run their own, point friends at it, and stay fully
self-hosted. Accounts are minimal: a public key / device identity + a display
name; trust is derived, not bought.

```
server/skotiq_hub/
  bin/skotiq_hub.dart            # entry point (port, data dir, admin token)
  lib/skotiq_hub.dart            # library barrel
  lib/src/hub_server.dart            # shelf Router + middleware (mirrors headless_api_server)
  lib/src/auth/account_store.dart    # identity + bearer tokens (reuses crypto patterns)
  lib/src/auth/trust_model.dart      # per-contributor trust weight
  lib/src/tiles/tile_store.dart      # per-tile master accumulator sidecars on disk
  lib/src/tiles/merge.dart           # calls native merge_tiles via the bridge
  lib/src/handoff/handoff_registry.dart  # follow-the-night active-tile registry
  lib/src/contributions/contribution_log.dart
  pubspec.yaml
  test/...
```

### C.5 Client-side files

Create:
- `packages/skotiq_bridge/lib/src/api/constellation.dart`
  (`api_constellation_merge_tiles` — used by both client local-merge and hub)
- `native/skotiq_native/bridge/src/api/constellation.rs`
- `packages/skotiq_core/lib/src/services/constellation/constellation_client.dart`
  (REST client against the hub; reuses `webdav_sync_target.dart`'s upload
  transport idioms + `NetworkBackend` HTTP conventions)
- `packages/skotiq_core/lib/src/services/constellation/constellation_models.dart`
- `packages/skotiq_core/lib/src/providers/constellation_provider.dart`
- `apps/desktop/lib/screens/constellation/constellation_screen.dart`
  + `widgets/constellation/swarm_tile_card.dart`,
  `widgets/constellation/contribution_sheet.dart`,
  `widgets/constellation/follow_the_night_strip.dart`

Edit:
- `migration_v52.dart` (+ `constellation_contributions` table)
- `database.dart` (register `ConstellationContributions`)
- bridge `mod.rs`, imaging `lib.rs`
- skotiq_core barrel.

### C.6 DB additions

`constellation_contributions` (local ledger of what you've pushed/pulled per
tile + the hub it went to + trust feedback). Hub-side state lives in the hub's
own store under `server/skotiq_hub/`, not the app DB. See contracts §3.

### C.7 Privacy / trust posture

Opt-in per tile; nothing uploads unless the user joins a tile to a hub. Deltas
are pixel running-sums, not subs and not raw frames. Trust weight is transparent
(shown in the contribution sheet). Retraction is supported (linear subtraction).
Self-host is a first-class path, identical binary, no Skotiq-operated cloud
required.

---

## Testing

- **Rust:** `wcs_sip` round-trip < 1e-6 px and SIP-vs-Dart parity on known
  coefficients; `sky_atlas` tile addressing covers the right HEALPix ids for a
  cone; **the additivity property** — folding a frame split across two tiles and
  merging two contributors' deltas equals one combined fold (the master's parity
  test, lifted to tiles); serialize/deserialize round-trip; `difference_image`
  recovers an injected synthetic transient and rejects a flat (no-change) frame.
- **Dart:** DAO CRUD for the three atlas tables + transient + contribution tables
  with an in-memory DB; `migration_v52` applies cleanly from v51; First Light
  Narrator detectors fire once / respect cooldown on synthetic candidate streams;
  `ConstellationClient` against a fake hub; **`migration_v52` is the only schema
  bump (51 → 52)** and carries every 5.0 table.
- **Hub:** `hub_server` route tests (auth required, geometry rejection, merge
  math, retraction subtracts exactly, trust scaling) with a shelf test harness.
- Do not regenerate/commit Linux-captured goldens.
</content>
</invoke>
