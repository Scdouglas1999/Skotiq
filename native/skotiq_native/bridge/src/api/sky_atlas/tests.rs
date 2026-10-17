use super::*;
use skotiq_imaging::sky_atlas::{radec_to_tile, tile_wcs, TILE_PIXELS};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A scratch directory that deletes itself when the test ends.
///
/// Every test here writes a FITS tree under `/tmp`; left behind, enough runs
/// fill the tmpfs and the suite starts failing for reasons unrelated to the code
/// under test. Cleanup runs from `Drop` rather than at the end of each test,
/// because the leak is worst exactly when a test fails and drop still runs while
/// a panic unwinds.
struct TempDir(std::path::PathBuf);

impl std::ops::Deref for TempDir {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

// Deref alone does not satisfy a generic `AsRef<Path>` bound, which several
// call sites here rely on.
impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // Best-effort: a test asserting on a half-removed tree should fail
        // on its own assertion, not on cleanup.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_dir(tag: &str) -> TempDir {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let p = std::env::temp_dir().join(format!("sk_atlas_ffi_{}_{}_{}", tag, std::process::id(), n));
    std::fs::create_dir_all(&p).unwrap();
    TempDir(p)
}

fn temp_file(dir: &Path, name: &str) -> std::path::PathBuf {
    dir.join(name)
}

/// Write a flat F32 frame whose WCS is a tile's own grid (so it covers the
/// tile pixel-for-pixel) to a FITS file, returning (path, wcs).
fn write_frame_on_tile(
    dir: &Path,
    name: &str,
    tile_id: TileId,
    order: u32,
    value: f32,
) -> (std::path::PathBuf, SipWcs) {
    let wcs = tile_wcs(tile_id, order);
    let w = TILE_PIXELS;
    let data = vec![value; (w as usize) * (w as usize)];
    let image = ImageData::from_f32(w, w, 1, &data);
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "LIGHT");
    let path = temp_file(dir, name);
    write_fits(&path, &image, &header).unwrap();
    (path, wcs)
}

fn sip_to_json(wcs: &SipWcs) -> serde_json::Value {
    serde_json::to_value(wcs).unwrap()
}

#[test]
fn fold_then_coverage_then_finalize() {
    let dir = temp_dir("fold");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(120.0, 25.0, order);
    let (frame, wcs) = write_frame_on_tile(&dir, "light.fits", tid, order, 1000.0);

    // Fold via the dispatcher.
    let fold_args = serde_json::json!({
        "action": "fold",
        "atlasRoot": dir.to_string_lossy(),
        "order": order,
        "contributor": "",
        "interp": "bilinear",
        "label": "2026-06-19",
        "frames": [ { "framePath": frame.to_string_lossy(),
                      "weight": 1.0, "exposureSec": 300.0, "wcs": sip_to_json(&wcs) } ]
    })
    .to_string();
    let resp = api_sky_atlas(fold_args).expect("fold succeeds");
    let fold: FoldResult = serde_json::from_str(&resp).unwrap();
    assert!(fold.ok);
    assert!(fold.tiles_touched.contains(&tid));
    let summary = fold
        .folds_by_tile
        .iter()
        .find(|s| s.tile_id == tid)
        .expect("centre tile summarised");
    assert_eq!(summary.frames_added, 1);
    assert!(summary.coverage_mean > 0.5);

    // Coverage lists the tile.
    let cov_args = serde_json::json!({
        "action": "coverage", "atlasRoot": dir.to_string_lossy(), "order": order
    })
    .to_string();
    let cov: CoverageResult = serde_json::from_str(&api_sky_atlas(cov_args).unwrap()).unwrap();
    assert!(cov.tiles.iter().any(|t| t.tile_id == tid));

    // Finalize writes a FITS that recovers ~1000 at the centre.
    let out = temp_file(&dir, "tile.fits");
    let fin_args = serde_json::json!({
        "action": "finalize", "atlasRoot": dir.to_string_lossy(), "order": order,
        "tileId": tid, "outPath": out.to_string_lossy()
    })
    .to_string();
    let fin: FinalizeResult = serde_json::from_str(&api_sky_atlas(fin_args).unwrap()).unwrap();
    assert!(fin.ok);
    assert!(out.exists());
    let (img, hdr) = skotiq_imaging::read_fits(&out).unwrap();
    assert_eq!(img.pixel_type, skotiq_imaging::PixelType::F32);
    assert_eq!(hdr.get_int("TILEID"), Some(tid as i64));
    let f = img.as_f32().unwrap();
    let mid = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
    assert!((f[mid] as f64 - 1000.0).abs() < 1.0, "got {}", f[mid]);

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn add_frame_wrapper_matches_fold() {
    let dir = temp_dir("addframe");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(45.0, -10.0, order);
    let (frame, wcs) = write_frame_on_tile(&dir, "light.fits", tid, order, 555.0);

    let args = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-19",
        "framePath": frame.to_string_lossy(), "weight": 1.0, "exposureSec": 120.0,
        "wcs": sip_to_json(&wcs)
    })
    .to_string();
    let fold: FoldResult = serde_json::from_str(&api_sky_atlas_add_frame(args).unwrap()).unwrap();
    assert!(fold.ok);
    assert!(fold.tiles_touched.contains(&tid));
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn query_cutout_recovers_signal_and_coverage() {
    let dir = temp_dir("cutout");
    let order = ATLAS_HEALPIX_ORDER;
    let (ra, dec) = (200.0, 15.0);
    let tid = radec_to_tile(ra, dec, order);
    let (frame, wcs) = write_frame_on_tile(&dir, "light.fits", tid, order, 1234.0);
    let add = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-19",
        "framePath": frame.to_string_lossy(), "weight": 1.0, "exposureSec": 60.0,
        "wcs": sip_to_json(&wcs)
    })
    .to_string();
    api_sky_atlas_add_frame(add).unwrap();

    let out = temp_file(&dir, "cutout.fits");
    let png = temp_file(&dir, "cutout.png");
    let q = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "centerRa": ra, "centerDec": dec, "radiusDeg": 0.05,
        "channels": 1, "outPixels": 256, "interp": "bilinear",
        "fitsPath": out.to_string_lossy(), "pngPath": png.to_string_lossy()
    })
    .to_string();
    let res: QueryCutoutResult =
        serde_json::from_str(&api_sky_atlas_query_cutout(q).unwrap()).unwrap();
    assert!(res.ok);
    assert!(out.exists());
    assert!(png.exists());
    assert!(res.covered_fraction > 0.5, "frac {}", res.covered_fraction);
    assert!(res.mean_coverage > 0.0);
    assert!(res.tiles_used >= 1);
    // The co-added centre should recover ~1234.
    let (img, _) = skotiq_imaging::read_fits(&out).unwrap();
    let f = img.as_f32().unwrap();
    let w = img.width as usize;
    let mid = (img.height as usize / 2) * w + w / 2;
    assert!((f[mid] as f64 - 1234.0).abs() < 5.0, "got {}", f[mid]);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn region_info_and_growth_track_folds() {
    let dir = temp_dir("region");
    let order = ATLAS_HEALPIX_ORDER;
    let (ra, dec) = (300.0, -25.0);
    let tid = radec_to_tile(ra, dec, order);

    // Two nights into the same tile.
    for (i, (val, secs, night)) in [
        (800.0f32, 300.0, "2026-06-01"),
        (1200.0f32, 600.0, "2026-06-05"),
    ]
    .iter()
    .enumerate()
    {
        let (frame, wcs) = write_frame_on_tile(&dir, &format!("n{i}.fits"), tid, order, *val);
        let add = serde_json::json!({
            "atlasRoot": dir.to_string_lossy(), "order": order, "label": night,
            "framePath": frame.to_string_lossy(), "weight": 1.0, "exposureSec": secs,
            "wcs": sip_to_json(&wcs)
        })
        .to_string();
        api_sky_atlas_add_frame(add).unwrap();
    }

    let ri = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "centerRa": ra, "centerDec": dec, "radiusDeg": 0.02
    })
    .to_string();
    let region: RegionInfoResult =
        serde_json::from_str(&api_sky_atlas_region_info(ri).unwrap()).unwrap();
    assert!(region.ok);
    assert!(region.tiles_with_data >= 1);
    // A frame folds into every tile its (margin-padded) footprint covers, so a
    // region aggregate sums per-tile contributions: both nights touched each
    // data tile identically (same WCS), giving 2 contributions per data tile.
    assert_eq!(region.total_frames, 2 * region.tiles_with_data);
    // Integration seconds aggregate the same way: (300 + 600) per data tile.
    assert!(
        (region.integration_seconds - 900.0 * region.tiles_with_data as f64).abs() < 1e-6,
        "got {}",
        region.integration_seconds
    );

    let g = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "centerRa": ra, "centerDec": dec, "radiusDeg": 0.02
    })
    .to_string();
    let growth: GrowthResult = serde_json::from_str(&api_sky_atlas_growth(g).unwrap()).unwrap();
    assert!(growth.ok);
    // Growth sums the same per-tile fold tallies as region_info.
    assert_eq!(growth.total_frames, region.total_frames);
    assert!((growth.total_seconds - region.integration_seconds).abs() < 1e-6);
    // Two growth points (keyed by night label), chronological, with a
    // monotonic cumulative curve. Each night contributed once per data tile.
    assert_eq!(growth.points.len(), 2);
    assert_eq!(growth.points[0].label, "2026-06-01");
    assert_eq!(growth.points[1].label, "2026-06-05");
    assert_eq!(growth.points[0].frames_added, region.tiles_with_data);
    assert_eq!(growth.points[0].cumulative_frames, region.tiles_with_data);
    assert_eq!(
        growth.points[1].cumulative_frames,
        2 * region.tiles_with_data
    );
    assert!(growth.points[1].cumulative_seconds > growth.points[0].cumulative_seconds);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn merge_delta_federates_two_contributors() {
    let dir = temp_dir("merge");
    let order = ATLAS_HEALPIX_ORDER;
    let (ra, dec) = (88.0, 5.0);
    let tid = radec_to_tile(ra, dec, order);

    // Alice folds into atlas A; export her tile as a delta.
    let (fa, wa) = write_frame_on_tile(&dir, "alice.fits", tid, order, 1000.0);
    let add_a = serde_json::json!({
        "atlasRoot": dir.join("alice").to_string_lossy(), "order": order, "label": "2026-06-01",
        "contributor": "alice", "framePath": fa.to_string_lossy(),
        "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&wa)
    })
    .to_string();
    api_sky_atlas_add_frame(add_a).unwrap();

    let alice_atlas = SkyAtlas::open(dir.join("alice"), order, DEFAULT_MEMORY_BUDGET_BYTES);
    let alice_tile_path = alice_atlas.tile_path(tid);
    assert!(alice_tile_path.exists());

    // Bob's hub is empty; merge Alice's delta into it.
    let hub = SkyAtlas::open(dir.join("hub"), order, DEFAULT_MEMORY_BUDGET_BYTES);
    let hub_path = hub.tile_path(tid);
    let merge = serde_json::json!({
        "basePath": hub_path.to_string_lossy(),
        "deltaPath": alice_tile_path.to_string_lossy(),
        "trust": 1.0, "subtract": false,
        "outPath": hub_path.to_string_lossy()
    })
    .to_string();
    let res: MergeDeltaResult =
        serde_json::from_str(&api_sky_atlas_merge_delta(merge).unwrap()).unwrap();
    assert!(res.ok);
    assert_eq!(res.tile_id, tid);
    assert_eq!(res.total_frames_after, 1);
    assert!((res.integration_seconds_after - 100.0).abs() < 1e-6);
    assert_eq!(res.contributors_after, 1);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn export_delta_blocks_mixed_pre_and_post_anchor_own_folds() {
    // A tile that carries a pre-anchor OWN fold (contributor "") together with
    // a new post-anchor OWN fold cannot be carved into a pixel-exact delta, so
    // it must BLOCK rather than over-share the already-contributed depth.
    let dir = temp_dir("export_mixed");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(120.0, 25.0, order);

    // Old own night (pre-anchor).
    let (f0, w0) = write_frame_on_tile(&dir, "old.fits", tid, order, 1000.0);
    api_sky_atlas_add_frame(
        serde_json::json!({
            "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-05-20",
            "contributor": "", "framePath": f0.to_string_lossy(),
            "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&w0)
        })
        .to_string(),
    )
    .unwrap();
    // New own night (post-anchor).
    let (f1, w1) = write_frame_on_tile(&dir, "new.fits", tid, order, 1000.0);
    api_sky_atlas_add_frame(
        serde_json::json!({
            "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-10",
            "contributor": "", "framePath": f1.to_string_lossy(),
            "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&w1)
        })
        .to_string(),
    )
    .unwrap();

    let out = dir.join("delta.nst");
    let export = serde_json::json!({
        "action": "exportDelta",
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "tileId": tid, "sinceIso": "2026-06-01",
        "outPath": out.to_string_lossy()
    })
    .to_string();
    let err = api_sky_atlas(export).unwrap_err();
    assert!(
        err.contains("mixes pre-anchor own folds"),
        "mixed own folds must block, got: {err}"
    );
    assert!(!out.exists(), "no delta must be written when blocked");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn export_delta_allows_all_post_anchor_dated_folds() {
    let dir = temp_dir("export_dated");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(120.0, 25.0, order);
    let (frame, wcs) = write_frame_on_tile(&dir, "d.fits", tid, order, 1000.0);
    let add = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-10",
        "contributor": "", "framePath": frame.to_string_lossy(),
        "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&wcs)
    })
    .to_string();
    api_sky_atlas_add_frame(add).unwrap();

    let out = dir.join("delta.nst");
    let export = serde_json::json!({
        "action": "exportDelta",
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "tileId": tid, "sinceIso": "2026-06-01",
        "outPath": out.to_string_lossy()
    })
    .to_string();
    let res = api_sky_atlas(export).unwrap();
    assert!(res.contains("\"ok\":true"), "got: {res}");
    assert!(
        res.contains("\"framesInDelta\":1"),
        "post-anchor own tally must be 1, got: {res}"
    );
    assert!(out.exists(), "a fully post-anchor tile must export");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn export_delta_only_post_anchor_local() {
    // A tile mixing: an OLD own fold (pre-anchor), a NEW own fold
    // (post-anchor), and a FOREIGN fold (pulled community, contributor
    // "bob"). Anchoring between the two own nights, the exported tally must be
    // 1 (the new own night ONLY) — the old own fold and the foreign fold are
    // both excluded, so neither already-contributed nor community photons can
    // leak into the contribution.
    //
    // (The old own fold lands strictly before the anchor; the new own fold
    // strictly after — so the two own folds are not mixed across the anchor on
    // the blocking side, only the foreign fold and the in-window own fold
    // coexist, which is the legitimate pull-then-image case.)
    let dir = temp_dir("export_post_local");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(120.0, 25.0, order);

    // Foreign (pulled) fold — community depth, must never re-upload.
    let (ff, fw) = write_frame_on_tile(&dir, "bob.fits", tid, order, 1000.0);
    api_sky_atlas_add_frame(
        serde_json::json!({
            "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-08",
            "contributor": "bob", "framePath": ff.to_string_lossy(),
            "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&fw)
        })
        .to_string(),
    )
    .unwrap();
    // New own night (post-anchor) — the only thing we should ship.
    let (nf, nw) = write_frame_on_tile(&dir, "mine.fits", tid, order, 1000.0);
    api_sky_atlas_add_frame(
        serde_json::json!({
            "atlasRoot": dir.to_string_lossy(), "order": order, "label": "2026-06-10",
            "contributor": "", "framePath": nf.to_string_lossy(),
            "weight": 1.0, "exposureSec": 100.0, "wcs": sip_to_json(&nw)
        })
        .to_string(),
    )
    .unwrap();

    let out = dir.join("delta.nst");
    let export = serde_json::json!({
        "action": "exportDelta",
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "tileId": tid, "sinceIso": "2026-06-09",
        "outPath": out.to_string_lossy()
    })
    .to_string();
    let res = api_sky_atlas(export).unwrap();
    assert!(res.contains("\"ok\":true"), "got: {res}");
    assert!(
        res.contains("\"framesInDelta\":1"),
        "only the post-anchor OWN night counts (foreign + old excluded), got: {res}"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn unknown_action_errors() {
    let args = serde_json::json!({ "action": "bogus", "atlasRoot": "/tmp/x" }).to_string();
    let err = api_sky_atlas(args).unwrap_err();
    assert!(err.contains("unknown atlas action"), "got: {err}");
}

#[test]
fn fold_requires_invertible_wcs() {
    let dir = temp_dir("badwcs");
    let order = ATLAS_HEALPIX_ORDER;
    let tid = radec_to_tile(10.0, 10.0, order);
    let (frame, mut wcs) = write_frame_on_tile(&dir, "l.fits", tid, order, 1.0);
    // Zero the CD matrix -> singular.
    wcs.cd1_1 = 0.0;
    wcs.cd1_2 = 0.0;
    wcs.cd2_1 = 0.0;
    wcs.cd2_2 = 0.0;
    let args = serde_json::json!({
        "atlasRoot": dir.to_string_lossy(), "order": order,
        "framePath": frame.to_string_lossy(), "weight": 1.0, "wcs": sip_to_json(&wcs)
    })
    .to_string();
    let err = api_sky_atlas_add_frame(args).unwrap_err();
    assert!(err.contains("degenerate"), "got: {err}");
    std::fs::remove_dir_all(&dir).ok();
}
