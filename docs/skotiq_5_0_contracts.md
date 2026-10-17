# Skotiq 5.0 — interface contract (authoritative)

Builder agents MUST use these names, signatures, and JSON keys **verbatim**. This
is the shared boundary that lets the keystone, the three pillars, and the hub be
built in parallel and still fit. Field names are the wire contract; do not rename.
Anything not pinned here is the implementer's choice, provided it compiles, has no
stubs/TODOs, and passes tests.

Conventions:
- Rust pixel layout is channel-interleaved `f64` internally, `ImageData` (U16/F32)
  at the boundary — same as `master_accumulation.rs` / `mosaic_stitch.rs`.
- SIP coefficients are row-major: term `(i, j)` at index `i * (order + 1) + j`
  (matches `PlateSolveResult` and `gnomonic_projection.dart`).
- Bridge heavy ops are `String -> Result<String, String>` (`args_json` in, JSON
  out), so no FRB binding regen is needed to add params. All JSON is `camelCase`.
- Drift tables are real `Table` classes registered in `@DriftDatabase`; one
  schema bump 51 → 52; one additive guarded `migration_v52`.

---

## 1. Rust keystone

### 1.1 `native/skotiq_native/imaging/src/wcs_sip.rs`

```rust
/// CD + full SIP astrometry for one frame, ported from `gnomonic_projection.dart`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SipWcs {
    pub crval1: f64,   // ref RA  (deg)
    pub crval2: f64,   // ref Dec (deg)
    pub crpix1: f64,   // 1-based ref pixel x (FITS convention)
    pub crpix2: f64,   // 1-based ref pixel y
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    pub a_order: u32,
    pub b_order: u32,
    pub a_coeffs: Vec<f64>,   // forward SIP, row-major i*(order+1)+j
    pub b_coeffs: Vec<f64>,
    pub ap_order: u32,
    pub bp_order: u32,
    pub ap_coeffs: Vec<f64>,  // inverse SIP; empty -> Newton fallback
    pub bp_coeffs: Vec<f64>,
}

impl SipWcs {
    /// Build from the plate solver's result (CD + SIP carry straight over).
    pub fn from_plate_solve(r: &crate::platesolve::PlateSolveResult) -> Option<Self>;
    /// CD-only (no distortion) — the canonical grid for atlas tiles.
    pub fn tan_only(crval1: f64, crval2: f64, crpix1: f64, crpix2: f64,
                    cd1_1: f64, cd1_2: f64, cd2_1: f64, cd2_2: f64) -> Self;
    /// 0-based pixel -> (ra_deg in [0,360), dec_deg). Applies forward SIP.
    pub fn pixel_to_world(&self, x: f64, y: f64) -> (f64, f64);
    /// (ra_deg, dec_deg) -> 0-based pixel. None on the far hemisphere.
    /// Applies inverse SIP (AP/BP, else Newton iteration), like the Dart ref.
    pub fn world_to_pixel(&self, ra: f64, dec: f64) -> Option<(f64, f64)>;
    /// Approx isotropic scale (arcsec/px), geometric mean of CD column norms.
    pub fn pixel_scale_arcsec(&self) -> f64;
    /// False if the CD matrix is singular (|det| < 1e-18).
    pub fn is_invertible(&self) -> bool;
}
```

### 1.2 `native/skotiq_native/imaging/src/sky_atlas.rs`

```rust
pub const TILE_STATE_VERSION: u32 = 1;
pub const TILE_MAGIC: &[u8; 4] = b"NST1";

/// HEALPix NESTED tile id at a fixed base order. Builders pick the order const;
/// it is recorded in every tile + DB row so mixed-order is detectable.
pub type TileId = u64;

/// Default HEALPix order for atlas tiles (nside = 2^order). Single source of truth.
pub const ATLAS_HEALPIX_ORDER: u32 = 9;
/// Per-tile raster edge in pixels (square tile grid).
pub const TILE_PIXELS: u32 = 1024;

/// Tile addressing. NESTED scheme, geometry derived deterministically from id.
pub fn tile_ids_for_cone(center_ra: f64, center_dec: f64, radius_deg: f64,
                         order: u32) -> Vec<TileId>;
pub fn tile_ids_for_frame(wcs: &SipWcs, width: u32, height: u32,
                          order: u32) -> Vec<TileId>;
/// The canonical local TAN grid (no SIP) for a tile: centre = tile centre,
/// fixed scale so TILE_PIXELS spans the tile + a small margin.
pub fn tile_wcs(id: TileId, order: u32) -> SipWcs;
pub fn tile_center(id: TileId, order: u32) -> (f64, f64); // (ra_deg, dec_deg)

/// Per-tile additive accumulator — the master's PerPixelAccumulator on a tile.
#[derive(Debug, Clone, PartialEq)]
pub struct SkyTileAccumulator {
    pub version: u32,
    pub tile_id: TileId,
    pub order: u32,
    pub width: u32,      // == TILE_PIXELS
    pub height: u32,     // == TILE_PIXELS
    pub channels: u32,
    pub wcs: SipWcs,                                  // == tile_wcs(id, order)
    pub norm_reference: crate::master_accumulation::NormalizationReference,
    pub mode: crate::master_accumulation::AccumulationMode,
    pub state: crate::master_accumulation::PerPixelAccumulator, // six running vecs
    pub provenance: TileProvenance,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct TileProvenance {
    pub total_frames: usize,
    pub total_integration_seconds: f64,
    pub contributors: Vec<String>,   // device/account ids that have folded in
    pub folds: Vec<TileFoldRecord>,  // oldest first; mirrors master FoldRecord
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TileFoldRecord {
    pub frames_added: usize,
    pub weight_added: f64,
    pub integration_seconds_added: f64,
    pub rejected: u64,
    pub label: String,        // ISO date / session id
    pub contributor: String,  // "" for local
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum AtlasError {
    #[error("frame has a degenerate (non-invertible) WCS")] DegenerateWcs,
    #[error("frame footprint covers no tiles")] NoCoverage,
    #[error("tile geometry mismatch: {got} vs {expected}")] GeometryMismatch { got: TileId, expected: TileId },
    #[error("tile order mismatch: {got} vs {expected}")] OrderMismatch { got: u32, expected: u32 },
    #[error("channel mismatch: {got} vs {expected}")] ChannelMismatch { got: u32, expected: u32 },
    #[error("serialized tile is truncated/corrupt: {0}")] Corrupt(String),
    #[error("bad magic (not a Skotiq tile sidecar)")] BadMagic,
    #[error("unsupported tile version {got} (this build reads {supported})")] UnsupportedVersion { got: u32, supported: u32 },
}

impl SkyTileAccumulator {
    pub fn create(tile_id: TileId, order: u32, channels: u32,
                  mode: crate::master_accumulation::AccumulationMode) -> Self;

    /// Reproject `frame` (with its `wcs`) onto this tile and fold it in with the
    /// scalar `weight`/`exposure`. `interp` reuses registration::Interpolator.
    /// `contributor` tags provenance ("" for local). Returns the fold record.
    pub fn fold_frame(&mut self, frame: &ImageData, wcs: &SipWcs, weight: f64,
                      exposure_sec: f64, interp: crate::registration::Interpolator,
                      label: &str, contributor: &str) -> Result<TileFoldRecord, AtlasError>;

    /// master(p) = sum_wx/sum_w per pixel -> F32 ImageData (the finalized tile).
    pub fn finalize(&self) -> ImageData;
    pub fn coverage_map(&self) -> ImageData;
    pub fn rejection_map(&self) -> ImageData;

    /// Resumable sidecar: MAGIC | version(u32) | header_len(u32) | JSON header |
    /// packed payload (same layout discipline as IntegratedMaster).
    pub fn serialize(&self) -> Vec<u8>;
    pub fn deserialize(bytes: &[u8]) -> Result<Self, AtlasError>;
}

/// The federation primitive: add `other` into `dst` (same tile_id+order+grid).
/// Sums the six running vectors and unions provenance. With clip==None this is
/// exact vs. folding both contributors' frames into one accumulator.
/// `trust` scales `other`'s weighted sums before addition (1.0 = full trust).
/// Pass a negative-equivalent via `merge_tiles_subtract` for retraction.
pub fn merge_tiles(dst: &mut SkyTileAccumulator, other: &SkyTileAccumulator,
                   trust: f64) -> Result<(), AtlasError>;
pub fn merge_tiles_subtract(dst: &mut SkyTileAccumulator, other: &SkyTileAccumulator,
                            trust: f64) -> Result<(), AtlasError>;
```

### 1.3 `native/skotiq_native/imaging/src/difference_image.rs`

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct TransientCandidate {
    pub ra: f64,            // deg, via tile WCS
    pub dec: f64,
    pub tile_x: f64,        // pixel on the tile grid
    pub tile_y: f64,
    pub residual_flux: f64, // template-subtracted flux
    pub delta_mag: f64,     // estimated brightness change (negative = brighter)
    pub snr: f64,
    pub fwhm: f64,
    pub eccentricity: f64,
    pub position_angle_deg: f64, // major-axis PA from the 2nd-moment covariance, [0,180)
    pub kind: TransientKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransientKind { PointBrightening, MovingStreak, Dipole, NewSource }

#[derive(Debug, Clone)]
pub struct DifferenceResult {
    pub candidates: Vec<TransientCandidate>,
    pub residual: ImageData,   // F32 signed residual (new - matched template)
    pub matched_scale: f64,    // photometric scale applied to the new frame
    pub matched_offset: f64,
    pub template_coverage_min: u32, // min tile coverage used (quality gate)
}

/// Subtract the finalized atlas `template` (tile grid) from `frame` reprojected
/// onto the same grid, photometrically matched via
/// normalization::estimate_normalization (the stitcher's robust line fit), then
/// detect_stars on the +residual (sources) and -residual (dipole flag).
pub fn difference_against_template(
    template: &SkyTileAccumulator,
    frame: &ImageData,
    frame_wcs: &SipWcs,
    interp: crate::registration::Interpolator,
    star_cfg: &crate::stats::StarDetectionConfig,
) -> Result<DifferenceResult, AtlasError>;
```

---

## 2. Bridge `api_*` functions + JSON schemas

All in `native/skotiq_native/bridge/src/api/`, registered in `mod.rs`.
Dart bindings mirror each in `packages/skotiq_bridge/lib/src/api/`.

### 2.1 `api_sky_atlas(args_json: String) -> Result<String, String>`
File: `api/sky_atlas.rs`. Dispatched on `action`.

```jsonc
// action "fold"  — fold one or more solved frames into the atlas
{ "action": "fold",
  "atlasRoot": "/path/to/atlas",
  "order": 9,
  "sessionId": 123,
  "contributor": "",                 // "" = local
  "interp": "lanczos3",              // bilinear|catmullRom|lanczos3
  "frames": [ { "framePath": "/…/light_001.fits", "weight": 1.0,
                "exposureSec": 300.0, "wcs": <SipWcs JSON> } ] }
// -> { "ok": true, "tilesTouched": [<TileId>,…],
//      "foldsByTile": [ { "tileId": 42, "framesAdded": 1, "weightAdded": 1.0,
//                         "rejected": 0, "coverageMean": 12.0 } ] }

// action "finalize" — write a finalized tile raster to disk
{ "action": "finalize", "atlasRoot": …, "order": 9, "tileId": 42,
  "outPath": "/…/tile_42.fits" }
// -> { "ok": true, "outPath": "…", "width": 1024, "height": 1024, "channels": 1 }

// action "tilePng" — finalized tile PNG, optionally as-of a date (time-scrub)
{ "action": "tilePng", "atlasRoot": …, "order": 9, "tileId": 42,
  "outPath": "/…/tile_42.png", "asOfIso": "2026-06-10T00:00:00Z" /*optional*/ }
// -> { "ok": true, "outPath": "…" }

// action "coverage" — summary for the heat overlay / gallery
{ "action": "coverage", "atlasRoot": …, "order": 9 }
// -> { "ok": true, "tiles": [ { "tileId": 42, "centerRa": …, "centerDec": …,
//        "coverageMean": 12.0, "totalFrames": 30, "integrationSeconds": 9000.0,
//        "lastFoldIso": "…", "channels": 1 } ] }

// action "exportDelta" — accumulator state for the folds since `sinceIso`
{ "action": "exportDelta", "atlasRoot": …, "order": 9, "tileId": 42,
  "sinceIso": "2026-06-01T00:00:00Z", "outPath": "/…/delta_42.nst" }
// -> { "ok": true, "outPath": "…", "framesInDelta": 30, "integrationSeconds": 9000.0 }

// action "info" — provenance for one tile
{ "action": "info", "atlasRoot": …, "order": 9, "tileId": 42 }
// -> { "ok": true, "provenance": <TileProvenance JSON> }
```

`<SipWcs JSON>` keys are exactly the `SipWcs` field names in §1.1 (camelCase via
serde rename: `crval1`, `crpix1`, `cd1_1`, `aOrder`, `aCoeffs`, `apOrder`, …).

### 2.2 `api_difference_image(args_json: String) -> Result<String, String>`
File: `api/difference_image.rs`.

```jsonc
{ "atlasRoot": "/…", "order": 9,
  "framePath": "/…/light_999.fits", "wcs": <SipWcs JSON>,
  "interp": "lanczos3",
  "minTemplateCoverage": 5,          // skip tiles thinner than this
  "residualOutDir": "/…/residuals"   // optional; writes residual PNG per tile
}
// -> { "ok": true,
//      "candidates": [ { "ra": …, "dec": …, "tileId": 42, "tileX": …, "tileY": …,
//                        "residualFlux": …, "deltaMag": -1.2, "snr": 18.0,
//                        "fwhm": 2.1, "eccentricity": 0.1, "positionAngleDeg": 31.7,
//                        "kind": "pointBrightening",
//                        "catalogMatch": null /* filled Dart-side */ } ],
//      "tilesChecked": [42,43], "tilesSkippedThin": [44] }
```

### 2.3 `api_constellation_merge_tiles(args_json: String) -> Result<String, String>`
File: `api/constellation.rs`. Pure native merge; called by client local-merge and
by the hub.

```jsonc
{ "basePath": "/…/hub/tiles/9/42.nst",       // existing hub/local accumulator
  "deltaPath": "/…/incoming/delta_42.nst",   // contributor delta
  "trust": 0.85,                              // [0,1] trust weight
  "subtract": false,                          // true = retraction
  "outPath": "/…/hub/tiles/9/42.nst" }
// -> { "ok": true, "tileId": 42, "totalFramesAfter": 130,
//      "integrationSecondsAfter": 39000.0, "contributorsAfter": 7 }
```

---

## 3. Drift tables (migration_v52, schemaVersion 51 → 52)

New file `tables/sky_atlas_tables.dart` (3 tables),
`tables/transient_detections.dart`, `tables/constellation_contributions.dart`.
Register all in `@DriftDatabase`. `migration_v52.dart` mirrors `migration_v51`'s
guarded style; add `_upgradeSchemaV52(m, from)` to the chain in
`migration_strategy.dart`. Exact columns:

### `SkyTiles` (`@DataClassName('SkyTileRow')`)
```
id            integer autoIncrement
tileId        integer            // HEALPix NESTED id
healpixOrder  integer            // ATLAS_HEALPIX_ORDER at fold time
channels      integer
centerRaDeg   real
centerDecDeg  real
coverageMean  real               // mean sum-count across tile pixels
totalFrames   integer  default 0
integrationSeconds  real default 0
sidecarPath   text               // path to the .nst accumulator
lastFoldSessionId integer nullable references ImagingSessions(id)
lastFoldAt    dateTime nullable
regionId      integer nullable references SkyAtlasRegions(id)
createdAt     dateTime withDefault(currentDateAndTime)
// index: unique (tileId, healpixOrder)
```

### `SkyAtlasRegions` (`@DataClassName('SkyAtlasRegionRow')`)
```
id            integer autoIncrement
name          text
kind          text               // target|mosaic|custom|polar
centerRaDeg   real
centerDecDeg  real
radiusDeg     real
targetId      integer nullable references Targets(id)
tileCount     integer  default 0
integrationSeconds real default 0
createdAt     dateTime withDefault(currentDateAndTime)
```

### `SkyAtlasFolds` (`@DataClassName('SkyAtlasFoldRow')`) — time-scrub timeline
```
id            integer autoIncrement
tileId        integer
healpixOrder  integer
sessionId     integer nullable references ImagingSessions(id)
foldedAt      dateTime withDefault(currentDateAndTime)
framesAdded   integer
weightAdded   real
integrationSecondsAdded real
rejected      integer  default 0
contributor   text     withDefault(const Constant(''))
label         text
// index: (tileId, healpixOrder, foldedAt)
```

### `TransientDetections` (`@DataClassName('TransientDetectionRow')`)
```
id            integer autoIncrement
sessionId     integer nullable references ImagingSessions(id) onDelete cascade
capturedImageId integer nullable references CapturedImages(id) onDelete setNull
tileId        integer
detectedAt    dateTime withDefault(currentDateAndTime)
raDeg         real
decDeg        real
residualFlux  real
deltaMag      real
snr           real
fwhm          real
eccentricity  real
positionAngleDeg real withDefault(const Constant(0.0)) // major-axis PA, [0,180)
kind          text               // pointBrightening|movingStreak|dipole|newSource
catalogMatch  text nullable      // resolved name or null = unknown (the headline)
confidence    real
reviewed      boolean withDefault(const Constant(false))
dismissed     boolean withDefault(const Constant(false))
// indexes: (sessionId), (tileId), (detectedAt)
```

### `ConstellationContributions` (`@DataClassName('ConstellationContributionRow')`)
```
id            integer autoIncrement
tileId        integer
healpixOrder  integer
hubUrl        text
direction     text               // push|pull
framesDelta   integer
integrationSecondsDelta real
trustWeight   real nullable      // hub-reported, on pull
status        text               // pending|accepted|rejected|retracted
remoteContributionId text nullable
occurredAt    dateTime withDefault(currentDateAndTime)
// index: (tileId, healpixOrder), (hubUrl)
```

---

## 4. Dart services / providers (method signatures)

### `services/sky_atlas/sky_atlas_service.dart` — `class SkyAtlasService`
```dart
Future<AtlasFoldSummary> foldSession({ required int sessionId,
  required List<SolvedFrameRef> frames, AtlasInterp interp = AtlasInterp.lanczos3 });
Future<String> finalizeTilePng(int tileId, { DateTime? asOf });
Future<List<AtlasTileCoverage>> coverage();
Future<TileProvenanceView> tileInfo(int tileId);
Future<String> exportDelta(int tileId, { required DateTime since });
Future<int> ensureRegion({ required String name, required double centerRaDeg,
  required double centerDecDeg, required double radiusDeg, int? targetId });
```
Models in `sky_atlas_models.dart`: `SolvedFrameRef`, `AtlasFoldSummary`,
`AtlasTileCoverage`, `TileProvenanceView`, `AtlasInterp` (enum:
`bilinear|catmullRom|lanczos3`, wire = the camelCase name).

### `services/transients/first_light_service.dart` — `class FirstLightService`
```dart
Future<List<TransientDetectionRow>> scanFrame({ required String framePath,
  required SolvedWcs wcs, int? sessionId, int? capturedImageId,
  int minTemplateCoverage = 5 });
Future<void> markReviewed(int id, { bool dismissed = false });
```
Cross-match (catalog/photometric/moving-object) happens inside `scanFrame`
before persisting, filling `catalogMatch`/`confidence`/`kind`.

### `services/constellation/constellation_client.dart` — `class ConstellationClient`
```dart
ConstellationClient({ required Uri hubBaseUrl, required String bearerToken });
Future<HubInfo> info();
Future<ContributionReceipt> pushTile({ required int tileId, required int order,
  required String deltaPath });
Future<String> pullTile({ required int tileId, required int order,
  required String outPath, bool finalized = true });
Future<HandoffClaim?> claimHandoff(int targetId);
Future<void> releaseHandoff(int targetId);
Future<void> retract(String remoteContributionId);
```

### Providers
- `providers/sky_atlas_provider.dart`: `skyAtlasServiceProvider`,
  `skyAtlasCoverageProvider` (watched), `skyTileProvider(SkyTileQuery)` (tileId +
  optional `asOf`), `skyAtlasRegionsProvider`.
- `providers/constellation_provider.dart`: `constellationClientProvider`,
  `swarmTilesProvider`, `followTheNightProvider(targetId)`.
- First Light reuses the Narrator provider surface; transient feed via
  `transientDetectionsProvider(sessionId)`.

### Narrator detectors (`detectors/first_light_detectors.dart`)
Register in `narrator_detectors.dart::buildDefaultNarratorEngine`. Ids:
`first_light.transient` (celebrate, pinned — `catalogMatch == null` clean PSF),
`first_light.brightening` (celebrate — `deltaMag < -0.3`),
`first_light.mover` (success — `kind == movingStreak`). Evidence:
`{"kind":"vector",…}` for movers, `{"kind":"delta",…}` for brightenings. Add the
latest candidate list to `NarratorContext` (`narrator_context.dart`).

---

## 5. Constellation hub — REST endpoints (`server/skotiq_hub/`)

Dart shelf `Router` mirroring `headless_api_server.dart`; bearer-token middleware
with scopes `contribute` / `read` / `admin`; SHA-256 server identity from
`skotiq_remote_protocol/server_identity`. Base path `/v1`. All bodies JSON
except tile blobs (binary `application/octet-stream`, the `.nst` payload).

```
GET  /v1/info
  -> { "name": str, "fingerprint": <sha256 hex>, "version": "5.0.0",
       "healpixOrder": 9, "tilePixels": 1024, "selfHosted": true }

POST /v1/accounts                          (open or admin-gated per hub policy)
  { "publicKey": str, "displayName": str }
  -> { "accountId": str, "bearerToken": str, "trust": 0.5 }

GET  /v1/tiles/{tileId}?order=9&finalized=true   [read]
  -> 200 application/octet-stream  (finalized FITS or merged .nst when finalized=false)
     headers: X-Total-Frames, X-Integration-Seconds, X-Contributors

POST /v1/tiles/{tileId}/contributions?order=9    [contribute]
  body: application/octet-stream  (the contributor's .nst delta)
  query/headers: framesDelta, integrationSecondsDelta, medianFwhm, solver,
                 instrument (instrument fingerprint, not PII)
  -> { "contributionId": str, "accepted": true, "trustApplied": 0.85,
       "totalFramesAfter": 130, "integrationSecondsAfter": 39000.0 }

DELETE /v1/contributions/{contributionId}        [contribute]  // retraction
  -> { "retracted": true, "totalFramesAfter": 100 }

GET  /v1/handoff/{targetId}                       [contribute]  // follow-the-night
  -> { "targetId": int, "activeTileId": 42, "holder": str|null,
       "altitudeOk": true, "claimToken": str|null }
POST /v1/handoff/{targetId}/claim                 [contribute]
  -> { "claimToken": str, "expiresAt": iso }
POST /v1/handoff/{targetId}/release               [contribute]
  -> { "released": true }
```

Hub-side merge calls `api_constellation_merge_tiles` (§2.3) — the same native
`merge_tiles`, with `trust` from `trust_model.dart`. A geometry/order mismatch
returns HTTP 409. Geometry rejection, trust scaling, and exact retraction
subtraction are the hub's test obligations.

---

## 6. Constants that must agree everywhere (single source of truth)

| name | value | defined in |
|---|---|---|
| HEALPix order | `9` | `sky_atlas.rs::ATLAS_HEALPIX_ORDER`; echoed in hub `/v1/info`, `migration_v52` default, all `order` JSON fields |
| Tile raster edge | `1024` | `sky_atlas.rs::TILE_PIXELS` |
| Tile sidecar magic / version | `b"NST1"` / `1` | `sky_atlas.rs` |
| SIP coeff packing | `i*(order+1)+j` | `wcs_sip.rs`, matches `PlateSolveResult` + Dart |
| Schema version | `52` | `database.dart`; single bump from 51 |
| Interp wire names | `bilinear`/`catmullRom`/`lanczos3` | bridge + `AtlasInterp` |
| `TransientKind` wire | `pointBrightening`/`movingStreak`/`dipole`/`newSource` | Rust enum + Dart + DB |

Any builder that needs a value not listed here picks it, but the seven rows above
are load-bearing across modules and MUST match verbatim.
</content>
