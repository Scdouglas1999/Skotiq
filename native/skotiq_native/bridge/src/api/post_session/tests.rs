use super::*;
use skotiq_imaging::read_fits;
use std::path::PathBuf;

/// A scratch directory that deletes itself when the test ends. Cleanup runs
/// from `Drop`, so it happens even while a panic unwinds out of a failing test.
struct TempDir(PathBuf);

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

/// Unique scratch directory so parallel test runs don't collide.
fn temp_dir(prefix: &str) -> TempDir {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("sk_ps_{prefix}_{}_{n}", std::process::id()));
    std::fs::create_dir_all(&p).unwrap();
    TempDir(p)
}

/// Deterministic, well-separated bright stars for a `size`x`size` frame —
/// mirrors the registration module's synthetic field so the quad matcher has
/// distinctive asterisms to lock onto.
fn base_stars(size: f64) -> Vec<(f64, f64, f64)> {
    vec![
        (size * 0.18, size * 0.22, 9000.0),
        (size * 0.72, size * 0.16, 12000.0),
        (size * 0.40, size * 0.55, 15000.0),
        (size * 0.83, size * 0.61, 8000.0),
        (size * 0.27, size * 0.78, 11000.0),
        (size * 0.61, size * 0.84, 10000.0),
        (size * 0.52, size * 0.33, 13000.0),
        (size * 0.12, size * 0.62, 9500.0),
        (size * 0.90, size * 0.40, 7000.0),
        (size * 0.35, size * 0.12, 8500.0),
    ]
}

/// A dense, regular grid of equal-brightness stars (peak `6000 * k`) so a
/// meaningful fraction of pixels sit in the bright tail — this makes the
/// 95th-percentile SNR proxy responsive to overall brightness `k` (a sparse
/// field leaves the 95th percentile in the background, brightness-blind).
fn grid_stars(size: f64, k: f64) -> Vec<(f64, f64, f64)> {
    let step = 12.0;
    let mut out = Vec::new();
    let mut y = step;
    while y < size - step {
        let mut x = step;
        while x < size - step {
            out.push((x, y, 6000.0 * k));
            x += step;
        }
        y += step;
    }
    out
}

/// Render a synthetic mono U16 star field with Gaussian PSFs over a flat,
/// lightly-noised sky.
fn render_field(size: u32, stars: &[(f64, f64, f64)], background: f64) -> ImageData {
    render_field_psf(size, stars, background, 1.6)
}

/// As [`render_field`] but with a configurable PSF width `sigma` (px) — a
/// larger `sigma` blurs the stars (worse focus/seeing ⇒ larger measured
/// FWHM ⇒ lower integration weight).
fn render_field_psf(
    size: u32,
    stars: &[(f64, f64, f64)],
    background: f64,
    sigma: f64,
) -> ImageData {
    let w = size as usize;
    let h = size as usize;
    let mut pixels = vec![0f64; w * h];
    for (i, p) in pixels.iter_mut().enumerate() {
        let n = ((i.wrapping_mul(2654435761) >> 8) % 1000) as f64 / 1000.0;
        *p = background + (n - 0.5) * 6.0;
    }
    let two_sigma_sq = 2.0 * sigma * sigma;
    let radius = (sigma * 4.0).ceil() as i64;
    for &(sx, sy, peak) in stars {
        let cx = sx.round() as i64;
        let cy = sy.round() as i64;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let x = cx + dx;
                let y = cy + dy;
                if x < 0 || y < 0 || x as usize >= w || y as usize >= h {
                    continue;
                }
                let ddx = x as f64 - sx;
                let ddy = y as f64 - sy;
                let g = peak * (-(ddx * ddx + ddy * ddy) / two_sigma_sq).exp();
                pixels[y as usize * w + x as usize] += g;
            }
        }
    }
    let u16data: Vec<u16> = pixels
        .iter()
        .map(|v| v.round().clamp(0.0, 65535.0) as u16)
        .collect();
    ImageData::from_u16(size, size, 1, &u16data)
}

/// Shift star positions by (dx, dy), keeping them in-frame.
fn shift_stars(stars: &[(f64, f64, f64)], dx: f64, dy: f64) -> Vec<(f64, f64, f64)> {
    stars.iter().map(|&(x, y, f)| (x + dx, y + dy, f)).collect()
}

fn write_field_fits(path: &Path, image: &ImageData) {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "LIGHT");
    write_fits(path, image, &h).expect("write synthetic light");
}

/// Relaxed star-detection overrides for clean synthetic Gaussian PSFs (the
/// production default detector deliberately rejects idealised single-peak
/// Gaussians — see the registration module's own test config). This is the
/// real, user-exposed `align.detection` knob, not a test backdoor.
fn synthetic_align() -> serde_json::Value {
    serde_json::json!({
        "model": "similarity",
        "resampler": "bilinear",
        "detection": {
            "detectionSigma": 3.0,
            "minArea": 1,
            "maxEccentricity": 1.0,
            "minHfr": 0.5,
            "minSnr": 3.0,
            "maxSharpness": 1.0
        }
    })
}

/// End-to-end: three slightly-shifted synthetic subs integrate into a linear
/// FITS master + preview PNG, and the per-frame stats report all three
/// accepted.
#[test]
fn integrate_session_produces_master_and_preview() {
    let dir = temp_dir("integrate_session_produces_master_and_preview");
    let size = 256u32;
    let stars = base_stars(size as f64);
    let mut light_paths = Vec::new();
    let shifts = [(0.0, 0.0), (3.0, -2.0), (-2.0, 4.0)];
    for (i, (dx, dy)) in shifts.iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("light{i}.fits"));
        write_field_fits(&p, &field);
        light_paths.push(p.to_string_lossy().to_string());
    }
    let master_path = dir.join("master.fits");
    let preview_path = dir.join("preview.png");
    let rejection_path = dir.join("rejection.fits");
    let rejection_preview_path = dir.join("rejection_preview.png");

    let args = serde_json::json!({
        "lightPaths": light_paths,
        "reference": "auto",
        "exposuresSec": [60.0, 60.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": {
            "masterFitsPath": master_path.to_string_lossy(),
            "previewPngPath": preview_path.to_string_lossy(),
            "rejectionMapPath": rejection_path.to_string_lossy(),
            "rejectionMapPreviewPath": rejection_preview_path.to_string_lossy()
        }
    });

    let resp = api_integrate_session(args.to_string()).expect("integration should succeed");
    let result: IntegrateSessionResult = serde_json::from_str(&resp).unwrap();

    assert_eq!(
        result.frames_integrated, 3,
        "all three subs should integrate"
    );
    assert_eq!(result.frames_rejected, 0);
    assert_eq!(result.width, size);
    assert_eq!(result.height, size);
    assert_eq!(result.channels, 1);
    assert!((result.total_integration_sec - 180.0).abs() < 1e-6);
    assert_eq!(result.per_frame_stats.len(), 3);

    // The master is a real, readable F32 linear FITS of the right geometry.
    let (master_img, _h) = read_fits(master_path.as_path()).expect("read master");
    assert_eq!(master_img.pixel_type, PixelType::F32);
    assert_eq!(master_img.width, size);
    assert_eq!(master_img.height, size);
    assert!(preview_path.exists(), "preview PNG should be written");
    assert!(rejection_path.exists(), "rejection FITS should be written");
    assert!(
        rejection_preview_path.exists(),
        "rejection preview PNG should be written"
    );
    assert_eq!(
        result.rejection_map_preview_path.as_deref(),
        Some(rejection_preview_path.to_string_lossy().as_ref())
    );
    let rejection_preview = image::open(&rejection_preview_path).expect("decode rejection preview");
    assert_eq!(rejection_preview.width(), size);
    assert_eq!(rejection_preview.height(), size);
}

/// Write a synthetic light whose FITS header carries a plate-solved WCS
/// (CRVAL/CRPIX + an explicit CD matrix), so the reference-WCS carry-over can
/// be exercised end-to-end.
fn write_field_fits_with_wcs(path: &Path, image: &ImageData, wcs: &WcsInfo) {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "LIGHT");
    add_wcs_headers(&mut h, wcs);
    write_fits(path, image, &h).expect("write synthetic light with WCS");
}

/// The integrated master must carry the **registration reference**'s WCS in
/// its FITS header so the mosaic stitcher can place the panel without a
/// post-hoc plate solve. Without the carry-over the master has NO WCS and
/// `read_fits` finds no CRVAL/CD keywords — this test fails.
#[test]
fn integrate_session_stamps_reference_wcs_into_master() {
    let dir = temp_dir("integrate_session_stamps_reference_wcs_into_master");
    let size = 256u32;
    let stars = base_stars(size as f64);
    // A representative plate-solved panel WCS: ~1.5 arcsec/px, small rotation.
    let ref_wcs = WcsInfo::from_plate_solve(83.822, -5.391, 12.0, 1.5, size, size);

    let mut light_paths = Vec::new();
    let shifts = [(0.0, 0.0), (3.0, -2.0), (-2.0, 4.0)];
    for (i, (dx, dy)) in shifts.iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("wcslight{i}.fits"));
        // Only the reference (sub 0, selected explicitly below) carries WCS.
        if i == 0 {
            write_field_fits_with_wcs(&p, &field, &ref_wcs);
        } else {
            write_field_fits(&p, &field);
        }
        light_paths.push(p.to_string_lossy().to_string());
    }
    let master_path = dir.join("wcsmaster.fits");

    let args = serde_json::json!({
        "lightPaths": light_paths,
        // Pin the reference to the WCS-bearing sub so the carry-over is
        // deterministic regardless of measured quality.
        "reference": light_paths[0],
        "exposuresSec": [60.0, 60.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    });

    let resp = api_integrate_session(args.to_string()).expect("integration should succeed");
    let result: IntegrateSessionResult = serde_json::from_str(&resp).unwrap();
    assert_eq!(result.frames_integrated, 3);

    // Read the master back: it must carry the reference's WCS, so the
    // stitcher's `wcs_from_header` (CRVAL1/2 + CD matrix) succeeds. FITS cards
    // serialize floats at finite precision, so compare with a tolerance tight
    // enough to prove it's the reference's WCS (sub-arcsec on a ~1.5"/px CD,
    // sub-µdeg on RA/Dec), not a default or invented one.
    let (_master_img, h) = read_fits(master_path.as_path()).expect("read master");
    let near = |key: &str, want: f64| {
        let got = h
            .get_float(key)
            .unwrap_or_else(|| panic!("master is missing WCS keyword {key}"));
        assert!(
            (got - want).abs() <= want.abs() * 1e-9 + 1e-12,
            "{key}: master {got} != reference {want}"
        );
    };
    near("CRVAL1", ref_wcs.crval1);
    near("CRVAL2", ref_wcs.crval2);
    near("CRPIX1", ref_wcs.crpix1);
    near("CRPIX2", ref_wcs.crpix2);
    near("CD1_1", ref_wcs.cd1_1);
    near("CD1_2", ref_wcs.cd1_2);
    near("CD2_1", ref_wcs.cd2_1);
    near("CD2_2", ref_wcs.cd2_2);
    assert_eq!(h.get_string("CTYPE1"), Some("RA---TAN"));
}

/// A reference frame with NO astrometry must leave the master WCS-less (the
/// project-service cluster gates such panels out of the stitch) — the
/// carry-over must never invent a WCS.
#[test]
fn integrate_session_leaves_master_wcs_absent_when_reference_has_none() {
    let dir = temp_dir("integrate_session_leaves_master_wcs_absent_when_reference_has_none");
    let size = 256u32;
    let stars = base_stars(size as f64);
    let mut light_paths = Vec::new();
    let shifts = [(0.0, 0.0), (3.0, -2.0), (-2.0, 4.0)];
    for (i, (dx, dy)) in shifts.iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("nowcslight{i}.fits"));
        write_field_fits(&p, &field); // no WCS on any sub
        light_paths.push(p.to_string_lossy().to_string());
    }
    let master_path = dir.join("nowcsmaster.fits");
    let args = serde_json::json!({
        "lightPaths": light_paths,
        "reference": light_paths[0],
        "exposuresSec": [60.0, 60.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    });
    api_integrate_session(args.to_string()).expect("integration should succeed");

    let (_img, h) = read_fits(master_path.as_path()).expect("read master");
    assert_eq!(
        h.get_float("CRVAL1"),
        None,
        "no WCS to carry → none stamped"
    );
    assert_eq!(h.get_float("CD1_1"), None);
}

/// Multi-night accumulation: create -> add -> finalize round-trips through
/// the sidecar and yields a finalized master with the accumulated count.
#[test]
fn master_accumulate_create_add_finalize() {
    let dir = temp_dir("master_accumulate_create_add_finalize");
    let size = 256u32;
    let stars = base_stars(size as f64);

    let ref_field = render_field(size, &stars, 200.0);
    let ref_path = dir.join("ref.fits");
    write_field_fits(&ref_path, &ref_field);

    let sidecar = dir.join("master.nsmaster");
    let create = serde_json::json!({
        "op": "create",
        "referencePath": ref_path.to_string_lossy(),
        "sidecarPath": sidecar.to_string_lossy(),
        "filter": "L"
    });
    let r = api_master_accumulate(create.to_string()).expect("create");
    let cr: MasterAccumulateResult = serde_json::from_str(&r).unwrap();
    assert_eq!(cr.frame_count, 0, "create folds no frames");
    assert_eq!(cr.channels, 1);

    let mut light_paths = Vec::new();
    for (i, (dx, dy)) in [(0.0f64, 0.0f64), (2.0, -3.0)].iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("add{i}.fits"));
        write_field_fits(&p, &field);
        light_paths.push(p.to_string_lossy().to_string());
    }
    let add = serde_json::json!({
        "op": "add",
        "sidecarPath": sidecar.to_string_lossy(),
        "lightPaths": light_paths,
        "exposuresSec": [60.0, 60.0],
        "label": "2026-06-07",
        "settings": { "align": synthetic_align() }
    });
    let r = api_master_accumulate(add.to_string()).expect("add");
    let ar: MasterAccumulateResult = serde_json::from_str(&r).unwrap();
    assert_eq!(ar.frames_added, 2, "both subs fold in");
    assert_eq!(ar.frame_count, 2);
    assert!((ar.total_integration_sec - 120.0).abs() < 1e-6);

    let master_path = dir.join("acc_master.fits");
    let finalize = serde_json::json!({
        "op": "finalize",
        "sidecarPath": sidecar.to_string_lossy(),
        "masterFitsPath": master_path.to_string_lossy()
    });
    let r = api_master_accumulate(finalize.to_string()).expect("finalize");
    let fr: MasterAccumulateResult = serde_json::from_str(&r).unwrap();
    assert_eq!(fr.frame_count, 2);
    assert_eq!(
        fr.master_path.as_deref(),
        Some(master_path.to_string_lossy().as_ref())
    );

    let (img, _h) = read_fits(master_path.as_path()).expect("read accumulated master");
    assert_eq!(img.pixel_type, PixelType::F32);
    assert_eq!(img.width, size);
}

/// Folding a good-seeing night and then a uniformly worse-seeing (blurrier ⇒
/// larger-FWHM) night into the accumulating master must give the good night
/// strictly more *total* weight. `accumulation_weights` anchors both folds on a
/// fixed scale so the worse night contributes proportionally less; a per-fold
/// max-normalization would reset each night's best sub to 1.0 and make the two
/// folds' totals near-equal regardless of cross-night quality.
#[test]
fn accumulate_weights_better_night_more_than_worse_night() {
    let dir = temp_dir("accumulate_weights_better_night_more_than_worse_night");
    let size = 256u32;
    let stars = base_stars(size as f64);

    // A dense star grid so the bright-tail SNR proxy (95th-percentile signal
    // over background) actually tracks star brightness — with only a handful
    // of stars the 95th percentile sits in the background and is brightness-
    // blind. The asterism from `base_stars` is overlaid so the quad matcher
    // still has distinctive anchors to register against.
    let mut field_stars = grid_stars(size as f64, 1.0);
    field_stars.extend_from_slice(&stars);

    // Reference frame defines the master grid/anchor (bright, like night A).
    let ref_field = render_field(size, &field_stars, 200.0);
    let ref_path = dir.join("img001_ref.fits");
    write_field_fits(&ref_path, &ref_field);

    let sidecar = dir.join("img001_master.nsmaster");
    let create = serde_json::json!({
        "op": "create",
        "referencePath": ref_path.to_string_lossy(),
        "sidecarPath": sidecar.to_string_lossy(),
        "filter": "L"
    });
    api_master_accumulate(create.to_string()).expect("create");

    // Helper: render two slightly-shifted subs whose stars are scaled to
    // brightness `k`, write them, fold them in, return this fold's weights.
    let fold = |k: f64, label: &str, tag: &str| -> Vec<f64> {
        let mut paths = Vec::new();
        for (i, (dx, dy)) in [(0.0f64, 0.0f64), (2.0, -3.0)].iter().enumerate() {
            let mut night = grid_stars(size as f64, k);
            night.extend_from_slice(&stars);
            let field = render_field(size, &shift_stars(&night, *dx, *dy), 200.0);
            let p = dir.join(format!("{tag}{i}.fits"));
            write_field_fits(&p, &field);
            paths.push(p.to_string_lossy().to_string());
        }
        let add = serde_json::json!({
            "op": "add",
            "sidecarPath": sidecar.to_string_lossy(),
            "lightPaths": paths,
            "exposuresSec": [60.0, 60.0],
            "label": label,
            "settings": { "align": synthetic_align() }
        });
        let r = api_master_accumulate(add.to_string()).expect("add fold");
        let res: MasterAccumulateResult = serde_json::from_str(&r).unwrap();
        assert_eq!(res.frames_added, 2, "both subs of '{label}' must fold in");
        res.frame_weights
    };

    // Night A: full-brightness subs (high SNR). Night B: uniformly dimmer ⇒
    // lower SNR ⇒ lower per-sub quality on every sub.
    let w_a = fold(1.0, "night-A", "img001_a");
    let w_b = fold(0.45, "night-B", "img001_b");

    let sum_a: f64 = w_a.iter().sum();
    let sum_b: f64 = w_b.iter().sum();
    assert!(sum_a > 0.0 && sum_b > 0.0, "weights must be positive");
    assert!(
        sum_a > sum_b * 1.3,
        "the better-seeing night must carry meaningfully more total weight across folds: A={sum_a} ({w_a:?}) B={sum_b} ({w_b:?})"
    );
}

/// Master-flat build normalizes to unit mean and writes a readable FITS.
#[test]
fn build_master_flat_unit_mean() {
    let dir = temp_dir("build_master_flat_unit_mean");
    let size = 48u32;
    let len = (size * size) as usize;
    let mut flat_paths = Vec::new();
    for i in 0..5u32 {
        let data: Vec<u16> = (0..len)
            .map(|p| {
                let x = (p % size as usize) as f64 / size as f64;
                (20000.0 + 8000.0 * x + i as f64 * 50.0) as u16
            })
            .collect();
        let img = ImageData::from_u16(size, size, 1, &data);
        let p = dir.join(format!("flat{i}.fits"));
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "FLAT");
        write_fits(&p, &img, &h).unwrap();
        flat_paths.push(p.to_string_lossy().to_string());
    }
    let out = dir.join("master_flat.fits");
    let args = serde_json::json!({
        "flatPaths": flat_paths,
        "outputBitDepth": "f32",
        "method": "median",
        "outputPath": out.to_string_lossy()
    });
    let r = api_build_master_flat(args.to_string()).expect("flat build");
    let res: BuildMasterFlatResult = serde_json::from_str(&r).unwrap();
    assert_eq!(res.frame_count, 5);
    assert!(
        (res.output_mean - 1.0).abs() < 0.05,
        "output mean {} not ~1.0",
        res.output_mean
    );

    let (img, _h) = read_fits(out.as_path()).unwrap();
    assert_eq!(img.pixel_type, PixelType::F32);
}

/// save_fits_master re-exports a buffer with the declared geometry/type.
#[test]
fn save_fits_master_round_trips() {
    let dir = temp_dir("save_fits_master_round_trips");
    let size = 16u32;
    let len = (size * size) as usize;
    let f32_data: Vec<f32> = (0..len).map(|i| i as f32 * 0.5).collect();
    let out = dir.join("export.fits");
    let args = serde_json::json!({
        "width": size,
        "height": size,
        "channels": 1,
        "pixelType": "f32",
        "f32Data": f32_data,
        "outputPath": out.to_string_lossy(),
        "object": "M42"
    });
    let r = api_save_fits_master(args.to_string()).expect("save");
    let res: SaveFitsMasterResult = serde_json::from_str(&r).unwrap();
    assert_eq!(res.pixel_type, "f32");
    let (img, h) = read_fits(out.as_path()).unwrap();
    assert_eq!(img.pixel_type, PixelType::F32);
    assert_eq!(img.width, size);
    assert_eq!(h.get_string("OBJECT"), Some("M42"));
}

/// Bad JSON and unknown ops surface as errors, never a silent success.
#[test]
fn invalid_inputs_error() {
    assert!(api_integrate_session("not json".to_string()).is_err());
    assert!(api_integrate_session(r#"{"lightPaths":[]}"#.to_string()).is_err());
    assert!(api_master_accumulate(r#"{"op":"bogus"}"#.to_string()).is_err());
}

/// A present-but-wrong-length `exposuresSec` is refused on BOTH post-session
/// paths, naming both lengths — never zero-filled. Zero-filling the tail would
/// under-report `totalIntegrationSec` on the integrate path, and on the
/// accumulating path the missing seconds would fold into the master's
/// `total_integration_seconds` and be stamped as its FITS `EXPTIME`. The refusal
/// happens at entry, before any frame or sidecar is read, so nonexistent paths
/// here are enough — and prove that ordering.
#[test]
fn mismatched_exposure_lengths_are_refused_on_both_paths() {
    let short_integrate = serde_json::json!({
        "lightPaths": ["a.fits", "b.fits", "c.fits"],
        "exposuresSec": [60.0, 60.0],
        "output": { "masterFitsPath": "/nonexistent/master.fits" }
    });
    let err = api_integrate_session(short_integrate.to_string())
        .expect_err("a short exposuresSec must be refused, not zero-filled");
    assert!(
        err.contains("exposuresSec has 2 entries") && err.contains("3 light frames"),
        "the refusal must name both lengths, got '{err}'"
    );

    // The over-long list is the same defect from the other side.
    let long_integrate = serde_json::json!({
        "lightPaths": ["a.fits", "b.fits"],
        "exposuresSec": [60.0, 60.0, 60.0],
        "output": { "masterFitsPath": "/nonexistent/master.fits" }
    });
    let err = api_integrate_session(long_integrate.to_string())
        .expect_err("an over-long exposuresSec must be refused");
    assert!(
        err.contains("exposuresSec has 3 entries") && err.contains("2 light frames"),
        "the refusal must name both lengths, got '{err}'"
    );

    let short_add = serde_json::json!({
        "op": "add",
        "sidecarPath": "/nonexistent/master.nsmaster",
        "lightPaths": ["a.fits", "b.fits"],
        "exposuresSec": [60.0],
        "label": "2026-08-16"
    });
    let err = api_master_accumulate(short_add.to_string())
        .expect_err("a short exposuresSec must be refused, not zero-filled");
    assert!(
        err.contains("exposuresSec has 1 entries") && err.contains("2 light frames"),
        "the refusal must name both lengths, got '{err}'"
    );
}

/// The validated list is still threaded per frame: three subs with three
/// DIFFERENT exposures report their true sum (a count×constant mapping would
/// pass with any permutation), and omitting `exposuresSec` entirely stays legal
/// — the documented "unknown ⇒ 0 s" shape.
#[test]
fn equal_length_exposures_sum_and_an_omitted_list_stays_legal() {
    let dir = temp_dir("equal_length_exposures");
    let size = 192u32;
    let stars = base_stars(size as f64);
    let mut light_paths = Vec::new();
    for (i, (dx, dy)) in [(0.0f64, 0.0f64), (3.0, -2.0), (-2.0, 4.0)]
        .iter()
        .enumerate()
    {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("exp{i}.fits"));
        write_field_fits(&p, &field);
        light_paths.push(p.to_string_lossy().to_string());
    }

    let matched_master = dir.join("matched_master.fits");
    let matched = serde_json::json!({
        "lightPaths": light_paths,
        "reference": "auto",
        "exposuresSec": [30.0, 45.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": matched_master.to_string_lossy() }
    });
    let resp = api_integrate_session(matched.to_string()).expect("matched lengths integrate");
    let result: IntegrateSessionResult = serde_json::from_str(&resp).unwrap();
    assert_eq!(result.frames_integrated, 3);
    assert!(
        (result.total_integration_sec - 135.0).abs() < 1e-6,
        "each sub's own exposure must be summed, got {}",
        result.total_integration_sec
    );

    let unknown_master = dir.join("unknown_master.fits");
    let omitted = serde_json::json!({
        "lightPaths": light_paths,
        "reference": "auto",
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": unknown_master.to_string_lossy() }
    });
    let resp = api_integrate_session(omitted.to_string()).expect("omitted exposuresSec integrates");
    let result: IntegrateSessionResult = serde_json::from_str(&resp).unwrap();
    assert_eq!(result.frames_integrated, 3);
    assert_eq!(
        result.total_integration_sec, 0.0,
        "an omitted exposure list reports unknown as 0, not a guess"
    );
}

/// Every accepted sub must surface a positive, finite `noise` (and `snr`): the
/// marginal-SNR optimizer `integration_curve` drops any `noise <= 0` sub from
/// its variance sums, so a record that omits noise yields an all-zero
/// improvement curve.
///
/// This drives the real pipeline both ways: `api_integrate_session` measures the
/// per-sub `FrameQuality`, and the exact `qualities` map the Dart
/// `_analyzeAndStoreCurve` builds from these records is fed to the real
/// `api_analyze_night`, so no scripted curve can mask a zero. The assertions are
/// a positive, monotone-non-decreasing curve and a non-zero `target_snr`.
#[test]
fn per_frame_noise_drives_a_positive_optimizer_curve() {
    let dir = temp_dir("per_frame_noise_drives_a_positive_optimizer_curve");
    use crate::api::finishing_analyze::api_analyze_night;

    let size = 256u32;
    let stars = base_stars(size as f64);
    let mut light_paths = Vec::new();
    let shifts = [(0.0, 0.0), (3.0, -2.0), (-2.0, 4.0), (1.0, 1.0)];
    for (i, (dx, dy)) in shifts.iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 200.0);
        let p = dir.join(format!("noise_light{i}.fits"));
        write_field_fits(&p, &field);
        light_paths.push(p.to_string_lossy().to_string());
    }
    let master_path = dir.join("noise_master.fits");

    let args = serde_json::json!({
        "lightPaths": light_paths,
        "reference": "auto",
        "exposuresSec": [60.0, 60.0, 60.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    });

    let resp = api_integrate_session(args.to_string()).expect("integration should succeed");
    let result: IntegrateSessionResult = serde_json::from_str(&resp).unwrap();

    // Every accepted sub carries a positive, finite noise + snr — the inputs
    // the optimizer's variance sums need.
    let accepted: Vec<&PerFrameRecord> = result
        .per_frame_stats
        .iter()
        .filter(|r| r.accepted)
        .collect();
    assert!(accepted.len() >= 2, "need ≥2 accepted subs to form a curve");
    for r in &accepted {
        let noise = r.noise.expect("accepted sub must surface measured noise");
        assert!(
            noise.is_finite() && noise > 0.0,
            "noise must be positive: {noise}"
        );
        let snr = r.snr.expect("accepted sub must surface measured snr");
        assert!(
            snr.is_finite() && snr >= 0.0,
            "snr must be finite/non-negative: {snr}"
        );
    }

    // Build the exact `qualities` payload the Dart `_analyzeAndStoreCurve`
    // sends (snr + noise + background + starCount + fwhm/eccentricity), and
    // drive the REAL optimizer through `api_analyze_night`.
    let qualities: Vec<serde_json::Value> = accepted
        .iter()
        .map(|r| {
            let mut q = serde_json::Map::new();
            q.insert("snr".into(), serde_json::json!(r.snr.unwrap()));
            q.insert("noise".into(), serde_json::json!(r.noise.unwrap()));
            if let Some(bg) = r.background {
                q.insert("background".into(), serde_json::json!(bg));
            }
            if let Some(sc) = r.star_count {
                q.insert("starCount".into(), serde_json::json!(sc));
            }
            if let Some(f) = r.fwhm {
                q.insert("fwhm".into(), serde_json::json!(f));
            }
            if let Some(e) = r.eccentricity {
                q.insert("eccentricity".into(), serde_json::json!(e));
            }
            serde_json::Value::Object(q)
        })
        .collect();
    let weights: Vec<f64> = accepted.iter().map(|r| r.weight.max(0.001)).collect();
    let exposures: Vec<f64> = vec![60.0; accepted.len()];

    let night_args = serde_json::json!({
        "qualities": qualities,
        "weights": weights,
        "exposuresS": exposures,
    });
    let night_resp =
        api_analyze_night(night_args.to_string()).expect("analyze_night should succeed");
    let night: serde_json::Value = serde_json::from_str(&night_resp).unwrap();

    let points = night["curve"].as_array().expect("curve points array");
    assert_eq!(
        points.len(),
        accepted.len(),
        "one curve point per accepted sub"
    );

    // The curve is POSITIVE and monotone-non-decreasing in SNR (more subs
    // never lowers the predicted stack SNR), and the full-night anchor SNR is
    // strictly > 0 — the value Dart persists as `target_snr`.
    let mut prev = -1.0_f64;
    for (i, p) in points.iter().enumerate() {
        let snr = p["snr"].as_f64().expect("point snr");
        assert!(
            snr.is_finite() && snr > 0.0,
            "curve point {i} snr must be > 0: {snr}"
        );
        assert!(
            snr + 1e-9 >= prev,
            "curve must be monotone-non-decreasing at point {i}: {snr} < {prev}"
        );
        prev = snr;
    }
    let target_snr = points.last().unwrap()["snr"].as_f64().unwrap();
    assert!(
        target_snr > 0.0,
        "target_snr (full-night anchor) must be non-zero, got {target_snr}"
    );
}

// Applied-masters report

/// Sensor / exposure metadata a real light frame carries, so the calibration
/// report has something to compare against.
fn set_frame_metadata(h: &mut FitsHeader, date_obs: &str, ccd_temp: f64, exptime: f64) {
    h.set_string("INSTRUME", "Test Cam");
    h.set_float("CCD-TEMP", ccd_temp);
    h.set_float("EXPTIME", exptime);
    h.set_int("GAIN", 100);
    h.set_int("OFFSET", 30);
    h.set_int("XBINNING", 1);
    h.set_int("YBINNING", 1);
    h.set_string("FILTER", "L");
    h.set_string("DATE-OBS", date_obs);
}

/// Write a flat, unit-mean synthetic master flat (a constant illumination map
/// divides out to a no-op, so the pixels stay comparable across tests).
fn write_master_flat(path: &Path, size: u32, date_obs: &str) {
    let data = vec![30000u16; (size * size) as usize];
    let image = ImageData::from_u16(size, size, 1, &data);
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "FLAT");
    h.set_string("FRAMETYP", "MASTER");
    set_frame_metadata(&mut h, date_obs, -10.0, 3.0);
    write_fits(path, &image, &h).expect("write master flat");
}

/// Write a synthetic light carrying full sensor metadata.
fn write_light_with_metadata(path: &Path, image: &ImageData, date_obs: &str) {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "LIGHT");
    set_frame_metadata(&mut h, date_obs, -10.0, 60.0);
    write_fits(path, image, &h).expect("write synthetic light");
}

/// Write a flat, low-level synthetic master dark of `size`x`size`, with the
/// metadata a matcher would have keyed on.
fn write_master_dark(path: &Path, size: u32, date_obs: &str, ccd_temp: f64, exptime: f64) {
    let data = vec![50u16; (size * size) as usize];
    let image = ImageData::from_u16(size, size, 1, &data);
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "DARK");
    h.set_string("FRAMETYP", "MASTER");
    set_frame_metadata(&mut h, date_obs, ccd_temp, exptime);
    write_fits(path, &image, &h).expect("write master dark");
}

/// Build the three lights + args skeleton every calibration-report test shares.
fn calibration_test_lights(dir: &TempDir, size: u32, prefix: &str) -> Vec<String> {
    let stars = base_stars(size as f64);
    let shifts = [(0.0, 0.0), (3.0, -2.0), (-2.0, 4.0)];
    let mut light_paths = Vec::new();
    for (i, (dx, dy)) in shifts.iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 400.0);
        let p = dir.join(format!("{prefix}{i}.fits"));
        write_light_with_metadata(&p, &field, "2026-08-14T21:00:00");
        light_paths.push(p.to_string_lossy().to_string());
    }
    light_paths
}

/// Run an integration over `light_paths` with the given calibration block.
fn run_integration(
    light_paths: &[String],
    master_path: &Path,
    calibration: serde_json::Value,
) -> IntegrateSessionResult {
    let args = serde_json::json!({
        "lightPaths": light_paths,
        "reference": light_paths[0],
        "exposuresSec": [60.0, 60.0, 60.0],
        "calibration": calibration,
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    });
    let resp = api_integrate_session(args.to_string()).expect("integration should succeed");
    serde_json::from_str(&resp).expect("decode result")
}

/// A FITS commentary block wraps at 72 bytes per card, so a statement longer
/// than one card arrives as consecutive `HISTORY` records. Rejoin them the way
/// any reader must before matching on the text.
fn history_text(header: &FitsHeader) -> String {
    header.history.concat()
}

/// The slot entry for one calibration kind.
fn slot<'a>(report: &'a CalibrationReport, kind: &str) -> &'a AppliedMaster {
    report
        .masters
        .iter()
        .find(|m| m.kind == kind)
        .unwrap_or_else(|| panic!("report is missing the {kind} slot"))
}

/// A run with no calibration at all must still name all three slots, and the
/// master's HISTORY must say so — silence about a correction that never ran is
/// the failure this report exists to prevent.
#[test]
fn integrate_session_names_every_calibration_slot_when_none_is_supplied() {
    let dir = temp_dir("calibration_report_none_supplied");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "nocal");
    let master_path = dir.join("master.fits");

    let result = run_integration(&light_paths, &master_path, serde_json::json!({}));
    assert_eq!(
        result.calibration.masters.len(),
        3,
        "dark, flat and bias each get an entry"
    );
    for kind in ["dark", "flat", "bias"] {
        let entry = slot(&result.calibration, kind);
        assert_eq!(entry.quality, MatchQuality::Missing, "{kind}");
        assert!(!entry.applied, "{kind} did not run");
        assert_eq!(entry.path, None, "{kind}");
    }
    assert_eq!(
        result.calibration.anchor_light.as_deref(),
        Some(light_paths[0].as_str()),
        "the group's first sub anchors the comparison"
    );
    assert!(result.calibration.has_warnings());

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    for kind in ["dark", "flat", "bias"] {
        let want = format!("Calibration {kind}: none applied [missing]");
        assert!(
            history_text(&header).contains(&want),
            "master HISTORY is missing '{want}': {:?}",
            header.history
        );
    }
    assert_eq!(header.get("CALWARN").and_then(|v| v.as_bool()), Some(true));
}

/// A dark whose sensor metadata matches the lights exactly reports as an exact
/// match, and the bias slot reads `notRequired` — a matched dark already carries
/// the bias pedestal, so an absent bias there is deliberate, not a gap.
#[test]
fn integrate_session_reports_an_exactly_matched_dark() {
    let dir = temp_dir("calibration_report_exact_dark");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "exact");
    let dark_path = dir.join("master_dark.fits");
    write_master_dark(&dark_path, size, "2026-08-14T19:00:00", -10.0, 60.0);
    let master_path = dir.join("master.fits");

    let result = run_integration(
        &light_paths,
        &master_path,
        serde_json::json!({ "dark": dark_path.to_string_lossy() }),
    );

    let dark = slot(&result.calibration, "dark");
    assert!(dark.applied);
    assert_eq!(
        dark.path.as_deref(),
        Some(dark_path.to_string_lossy().as_ref())
    );
    assert_eq!(dark.quality, MatchQuality::Exact, "{:?}", dark.mismatches);
    assert!(dark.mismatches.is_empty(), "{:?}", dark.mismatches);
    assert!(dark.unverified.is_empty(), "{:?}", dark.unverified);
    assert!(!dark.stale);
    // Two hours before the lights, same setpoint.
    let age = dark.staleness.age_days.expect("age must be measured");
    assert!((age + 2.0 / 24.0).abs() < 1e-6, "age was {age}");
    assert_eq!(dark.staleness.temperature_delta_c, Some(0.0));
    assert_eq!(dark.staleness.max_age_days, DARK_MAX_AGE_DAYS);
    assert_eq!(
        dark.staleness.max_temperature_delta_c,
        Some(DARK_MAX_TEMP_DELTA_C)
    );

    assert_eq!(
        slot(&result.calibration, "bias").quality,
        MatchQuality::NotRequired
    );
    assert_eq!(
        slot(&result.calibration, "flat").quality,
        MatchQuality::Missing
    );

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    let dark_line = format!("Calibration dark: {} [exact]", dark_path.to_string_lossy());
    let history = history_text(&header);
    assert!(
        history.contains(&dark_line),
        "master HISTORY is missing '{dark_line}': {:?}",
        header.history
    );
    assert!(
        history.contains("Calibration bias: none applied [notRequired]"),
        "{:?}",
        header.history
    );
}

/// A dark from another season, at another setpoint, is applied but reported as a
/// stale fallback with both deltas and both thresholds on the record.
#[test]
fn integrate_session_reports_a_stale_warm_dark_as_a_fallback() {
    let dir = temp_dir("calibration_report_stale_dark");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "stale");
    let dark_path = dir.join("old_dark.fits");
    // 200 days before the lights and 6 C warmer: both terms out of tolerance.
    write_master_dark(&dark_path, size, "2026-01-26T19:00:00", -4.0, 60.0);
    let master_path = dir.join("master.fits");

    let result = run_integration(
        &light_paths,
        &master_path,
        serde_json::json!({ "dark": dark_path.to_string_lossy() }),
    );

    let dark = slot(&result.calibration, "dark");
    assert!(dark.applied, "a stale master still ran; the report says so");
    assert_eq!(dark.quality, MatchQuality::Fallback);
    assert!(dark.stale);
    assert!(dark.staleness.stale);
    let age = dark.staleness.age_days.expect("age must be measured");
    assert!(
        age < -DARK_MAX_AGE_DAYS,
        "dark should predate the lights by more than the max age, got {age}"
    );
    assert_eq!(dark.staleness.temperature_delta_c, Some(6.0));

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    assert!(
        history_text(&header).contains("STALE"),
        "master HISTORY must state the staleness verdict: {:?}",
        header.history
    );
    assert_eq!(header.get("CALWARN").and_then(|v| v.as_bool()), Some(true));
}

/// The dark is subtracted as-is, with no exposure scaling, so a dark of a
/// different duration is a real calibration error and must read as a fallback
/// with the offending dimension named.
#[test]
fn integrate_session_reports_an_exposure_mismatched_dark_as_a_fallback() {
    let dir = temp_dir("calibration_report_exposure_mismatch");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "exp");
    let dark_path = dir.join("long_dark.fits");
    write_master_dark(&dark_path, size, "2026-08-14T19:00:00", -10.0, 120.0);
    let master_path = dir.join("master.fits");

    let result = run_integration(
        &light_paths,
        &master_path,
        serde_json::json!({ "dark": dark_path.to_string_lossy() }),
    );

    let dark = slot(&result.calibration, "dark");
    assert_eq!(dark.quality, MatchQuality::Fallback);
    assert!(!dark.stale, "the error is exposure, not age or temperature");
    let mismatch = dark
        .mismatches
        .iter()
        .find(|m| m.dimension == "EXPTIME")
        .expect("EXPTIME mismatch must be reported");
    assert_eq!(mismatch.delta, Some(60.0));
    assert!(!mismatch.within_tolerance);
    assert_eq!(
        mismatch.tolerance,
        Some(60.0 * DARK_MAX_EXPOSURE_FRACTION),
        "the tolerance is the documented fraction of the light's exposure"
    );

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    let history = history_text(&header);
    assert!(
        history.contains("EXPTIME") && history.contains("OUT OF TOLERANCE"),
        "{:?}",
        header.history
    );
}

/// A master carrying no sensor metadata cannot be judged. It must read
/// `unverified` with every dimension listed — never `exact`, which would claim
/// agreement that was never checked.
#[test]
fn integrate_session_reports_a_metadata_free_dark_as_unverified() {
    let dir = temp_dir("calibration_report_unverified_dark");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "bare");
    let dark_path = dir.join("bare_dark.fits");
    let data = vec![50u16; (size * size) as usize];
    let image = ImageData::from_u16(size, size, 1, &data);
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "DARK");
    write_fits(dark_path.as_path(), &image, &h).expect("write bare dark");
    let master_path = dir.join("master.fits");

    let result = run_integration(
        &light_paths,
        &master_path,
        serde_json::json!({ "dark": dark_path.to_string_lossy() }),
    );

    let dark = slot(&result.calibration, "dark");
    assert_eq!(dark.quality, MatchQuality::Unverified);
    assert!(dark.mismatches.is_empty());
    assert!(!dark.stale, "unknown is not stale");
    assert_eq!(dark.staleness.age_days, None);
    assert_eq!(dark.staleness.temperature_delta_c, None);
    for dimension in [
        "INSTRUME",
        "EXPTIME",
        "GAIN",
        "OFFSET",
        "age",
        "temperature",
    ] {
        assert!(
            dark.unverified.iter().any(|d| d == dimension),
            "{dimension} must be listed as unverified: {:?}",
            dark.unverified
        );
    }
}

// Staleness thresholds

/// Write a 2x2 stub frame carrying only header metadata — enough for the
/// calibration report, which reads headers and never pixels.
fn write_metadata_stub(path: &Path, imagetyp: &str, date_obs: &str, ccd_temp: f64) {
    let image = ImageData::from_u16(2, 2, 1, &[10u16; 4]);
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", imagetyp);
    set_frame_metadata(&mut h, date_obs, ccd_temp, 60.0);
    write_fits(path, &image, &h).expect("write metadata stub");
}

/// The age term is judged at exactly the documented constant: a dark that old to
/// the second is still fresh, and one second older is stale.
#[test]
fn dark_age_threshold_is_the_documented_constant() {
    let dir = temp_dir("staleness_age_threshold");
    let light = dir.join("light.fits");
    // 2026-08-14T21:00:00 minus exactly DARK_MAX_AGE_DAYS (90) is 2026-05-16.
    write_metadata_stub(&light, "LIGHT", "2026-08-14T21:00:00", -10.0);

    let at_limit = dir.join("dark_at_limit.fits");
    write_metadata_stub(&at_limit, "DARK", "2026-05-16T21:00:00", -10.0);
    let past_limit = dir.join("dark_past_limit.fits");
    write_metadata_stub(&past_limit, "DARK", "2026-05-16T20:59:59", -10.0);

    let fresh = build_calibration_report(
        &light.to_string_lossy(),
        &CalibrationArgs {
            dark: Some(at_limit.to_string_lossy().to_string()),
            ..CalibrationArgs::default()
        },
    );
    let fresh_dark = slot(&fresh, "dark");
    assert_eq!(fresh_dark.staleness.age_days, Some(-DARK_MAX_AGE_DAYS));
    assert!(!fresh_dark.stale, "exactly at the limit is still in date");
    assert_eq!(fresh_dark.quality, MatchQuality::Exact);

    let stale = build_calibration_report(
        &light.to_string_lossy(),
        &CalibrationArgs {
            dark: Some(past_limit.to_string_lossy().to_string()),
            ..CalibrationArgs::default()
        },
    );
    let stale_dark = slot(&stale, "dark");
    assert!(stale_dark.stale, "one second past the limit is stale");
    assert_eq!(stale_dark.quality, MatchQuality::Fallback);
}

/// The temperature term is judged at exactly the documented constant, and a flat
/// has no temperature term at all — a unit-mean flat divides regardless of the
/// temperature it was shot at, so inventing a threshold would invent a verdict.
#[test]
fn temperature_threshold_is_the_documented_constant_and_flats_have_none() {
    let dir = temp_dir("staleness_temperature_threshold");
    let light = dir.join("light.fits");
    write_metadata_stub(&light, "LIGHT", "2026-08-14T21:00:00", -10.0);

    let at_limit = dir.join("dark_at_temp_limit.fits");
    write_metadata_stub(
        &at_limit,
        "DARK",
        "2026-08-14T19:00:00",
        -10.0 + DARK_MAX_TEMP_DELTA_C,
    );
    let past_limit = dir.join("dark_past_temp_limit.fits");
    write_metadata_stub(
        &past_limit,
        "DARK",
        "2026-08-14T19:00:00",
        -10.0 + DARK_MAX_TEMP_DELTA_C + 0.5,
    );

    let at = build_calibration_report(
        &light.to_string_lossy(),
        &CalibrationArgs {
            dark: Some(at_limit.to_string_lossy().to_string()),
            ..CalibrationArgs::default()
        },
    );
    assert_eq!(
        slot(&at, "dark").staleness.temperature_delta_c,
        Some(DARK_MAX_TEMP_DELTA_C)
    );
    assert!(
        !slot(&at, "dark").stale,
        "exactly at the limit is in tolerance"
    );

    let past = build_calibration_report(
        &light.to_string_lossy(),
        &CalibrationArgs {
            dark: Some(past_limit.to_string_lossy().to_string()),
            ..CalibrationArgs::default()
        },
    );
    assert!(slot(&past, "dark").stale);

    // A flat 20 C away from the lights carries no temperature verdict at all.
    let flat = dir.join("flat.fits");
    write_metadata_stub(&flat, "FLAT", "2026-08-14T19:00:00", 10.0);
    let flat_report = build_calibration_report(
        &light.to_string_lossy(),
        &CalibrationArgs {
            flat: Some(flat.to_string_lossy().to_string()),
            ..CalibrationArgs::default()
        },
    );
    let flat_slot = slot(&flat_report, "flat");
    assert_eq!(flat_slot.staleness.max_temperature_delta_c, None);
    assert_eq!(flat_slot.staleness.temperature_delta_c, None);
    assert!(!flat_slot.stale);
    assert!(
        !flat_slot.unverified.iter().any(|d| d == "temperature"),
        "a term a flat does not have is not an unverified term: {:?}",
        flat_slot.unverified
    );
    assert_eq!(flat_slot.staleness.max_age_days, FLAT_MAX_AGE_DAYS);
}

// Cancellation

/// Decode the `Err` payload of a cancelled run.
fn decode_cancelled(err: &str) -> CancelledOutcome {
    serde_json::from_str(err)
        .unwrap_or_else(|e| panic!("cancelled runs must return a typed outcome, got '{err}': {e}"))
}

/// Cancelling a run id before the run starts must stop it at its first check and
/// leave no master behind: a cancelled run is never a partial success.
#[test]
fn a_pre_armed_cancellation_stops_the_run_and_writes_no_master() {
    let dir = temp_dir("cancel_pre_armed");
    let size = 128u32;
    let light_paths = calibration_test_lights(&dir, size, "cancel");
    let master_path = dir.join("master.fits");
    let run_id = "pre-armed-run";

    let resp = api_post_session_cancel(serde_json::json!({ "runId": run_id }).to_string())
        .expect("pre-arm");
    let cancel: PostSessionCancelResult = serde_json::from_str(&resp).unwrap();
    assert!(!cancel.running, "nothing is in flight yet");
    assert!(cancel.cancel_requested);

    let args = serde_json::json!({
        "runId": run_id,
        "lightPaths": light_paths,
        "reference": light_paths[0],
        "exposuresSec": [60.0, 60.0, 60.0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    });
    let err = api_integrate_session(args.to_string())
        .expect_err("a pre-armed cancellation must stop the run");
    let outcome = decode_cancelled(&err);
    assert_eq!(outcome.kind, "cancelled");
    assert_eq!(outcome.run_id, run_id);
    assert_eq!(outcome.stage, "calibrating");
    assert!(
        !master_path.exists(),
        "a cancelled run must leave no master on disk"
    );

    // The token released the id, so the flag is gone rather than latched.
    let resp =
        api_post_session_cancel(serde_json::json!({ "op": "status", "runId": run_id }).to_string())
            .expect("status");
    let status: PostSessionCancelResult = serde_json::from_str(&resp).unwrap();
    assert!(!status.running);
    assert!(!status.cancel_requested);
}

/// Cancelling a run already in flight stops it inside a per-frame loop — the
/// reported `framesTotal` proves the check that fired was a per-frame one, not a
/// stage boundary (which reports no frame counts).
#[test]
fn cancelling_a_live_run_stops_it_inside_a_per_frame_loop() {
    let dir = temp_dir("cancel_live_run");
    let size = 192u32;
    let stars = base_stars(size as f64);
    let mut light_paths = Vec::new();
    for i in 0..10 {
        let dx = (i % 5) as f64 - 2.0;
        let dy = (i / 5) as f64 * 2.0 - 1.0;
        let field = render_field(size, &shift_stars(&stars, dx, dy), 400.0);
        let p = dir.join(format!("live{i}.fits"));
        write_light_with_metadata(&p, &field, "2026-08-14T21:00:00");
        light_paths.push(p.to_string_lossy().to_string());
    }
    let master_path = dir.join("master.fits");
    let run_id = "live-run";

    let args = serde_json::json!({
        "runId": run_id,
        "lightPaths": light_paths,
        "reference": light_paths[0],
        "settings": {
            "align": synthetic_align(),
            "integration": { "reject": "auto", "outputBitDepth": "f32" }
        },
        "output": { "masterFitsPath": master_path.to_string_lossy() }
    })
    .to_string();

    let worker = std::thread::spawn(move || api_integrate_session(args));

    // Wait for the run to claim its id, then cancel it.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let resp = api_post_session_cancel(
            serde_json::json!({ "op": "status", "runId": run_id }).to_string(),
        )
        .expect("status");
        let status: PostSessionCancelResult = serde_json::from_str(&resp).unwrap();
        if status.running {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the run never registered its id"
        );
        std::thread::yield_now();
    }
    api_post_session_cancel(serde_json::json!({ "runId": run_id }).to_string()).expect("cancel");

    let err = worker
        .join()
        .expect("worker thread")
        .expect_err("a cancelled run must not report success");
    let outcome = decode_cancelled(&err);
    assert_eq!(outcome.kind, "cancelled");
    assert_eq!(outcome.run_id, run_id);
    assert_eq!(
        outcome.frames_total,
        Some(light_paths.len() as u32),
        "a per-frame check reports the frame counts; a boundary check reports none"
    );
    assert!(
        !master_path.exists(),
        "a cancelled run must leave no master on disk"
    );
}

/// The cancel surface refuses what it cannot honestly answer, and never
/// resurrects a run that is already stopping.
#[test]
fn cancel_surface_rejects_bad_requests() {
    assert!(
        api_post_session_cancel(serde_json::json!({ "runId": "  " }).to_string()).is_err(),
        "a blank run id has no run to cancel"
    );
    assert!(
        api_post_session_cancel(serde_json::json!({ "op": "explode", "runId": "x" }).to_string())
            .is_err(),
        "an unknown op is an error, not a no-op"
    );

    // Unknown keys are tolerated, matching the rest of the post-session surface.
    let resp = api_post_session_cancel(
        serde_json::json!({ "runId": "tolerant-run", "somethingNew": 7 }).to_string(),
    )
    .expect("unknown keys must not break the call");
    let result: PostSessionCancelResult = serde_json::from_str(&resp).unwrap();
    assert!(result.cancel_requested);

    // `clear` drops the pre-arm it just made.
    api_post_session_cancel(
        serde_json::json!({ "op": "clear", "runId": "tolerant-run" }).to_string(),
    )
    .expect("clear a pre-arm");
    let resp = api_post_session_cancel(
        serde_json::json!({ "op": "status", "runId": "tolerant-run" }).to_string(),
    )
    .expect("status");
    let result: PostSessionCancelResult = serde_json::from_str(&resp).unwrap();
    assert!(!result.cancel_requested);
}

/// A live run owns its id: `clear` may not silently un-cancel it, and a second
/// run may not claim the same id and release the first one's flag.
#[test]
fn a_live_run_owns_its_id() {
    let token = RunCancelToken::register("owned-run").expect("register");
    assert!(
        RunCancelToken::register("owned-run").is_err(),
        "two runs sharing one id could not be cancelled independently"
    );
    assert!(
        api_post_session_cancel(
            serde_json::json!({ "op": "clear", "runId": "owned-run" }).to_string()
        )
        .is_err(),
        "clearing a live run's flag would resurrect a stopped run"
    );

    api_post_session_cancel(serde_json::json!({ "runId": "owned-run" }).to_string())
        .expect("cancel");
    assert!(token.is_cancelled());
    let err = token
        .check("registering", Some(3), Some(9))
        .expect_err("a cancelled token must stop the caller");
    let outcome = decode_cancelled(&err);
    assert_eq!(outcome.stage, "registering");
    assert_eq!(outcome.frames_done, Some(3));
    assert_eq!(outcome.frames_total, Some(9));

    drop(token);
    // Dropping the token releases the id for reuse.
    let reused = RunCancelToken::register("owned-run").expect("id is free again");
    assert!(!reused.is_cancelled(), "a fresh run starts uncancelled");
}

/// A run with no run id is simply not cancellable, and says so rather than
/// pretending a handle exists.
#[test]
fn a_run_without_a_run_id_is_not_cancellable() {
    let token = RunCancelToken::register("").expect("an id-less run still runs");
    assert_eq!(token.run_id(), "");
    assert!(!token.is_cancelled());
    assert!(token.check("calibrating", None, None).is_ok());
}

// Multi-night calibration record

/// Each fold's calibration is recorded beside the sidecar and replayed into the
/// finalized master's HISTORY — the FITS may be written nights later, in another
/// process, long after the fold's own result was returned.
#[test]
fn master_add_records_its_calibration_and_finalize_replays_every_fold() {
    let dir = temp_dir("master_fold_calibration");
    let size = 128u32;
    let stars = base_stars(size as f64);
    let reference = render_field(size, &stars, 400.0);
    let ref_path = dir.join("ref.fits");
    write_light_with_metadata(&ref_path, &reference, "2026-08-14T21:00:00");
    let sidecar = dir.join("m31.nsmaster");

    let create = serde_json::json!({
        "op": "create",
        "referencePath": ref_path.to_string_lossy(),
        "sidecarPath": sidecar.to_string_lossy(),
        "target": "M31",
        "filter": "L"
    });
    api_master_accumulate(create.to_string()).expect("create");

    let dark_path = dir.join("fold_dark.fits");
    write_master_dark(&dark_path, size, "2026-08-14T19:00:00", -10.0, 60.0);
    let flat_path = dir.join("fold_flat.fits");
    write_master_flat(&flat_path, size, "2026-08-14T18:00:00");

    let mut light_paths = Vec::new();
    for (i, (dx, dy)) in [(0.0, 0.0), (2.0, -1.0)].iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 400.0);
        let p = dir.join(format!("fold{i}.fits"));
        write_light_with_metadata(&p, &field, "2026-08-14T21:00:00");
        light_paths.push(p.to_string_lossy().to_string());
    }

    let add = serde_json::json!({
        "op": "add",
        "sidecarPath": sidecar.to_string_lossy(),
        "lightPaths": light_paths,
        "exposuresSec": [60.0, 60.0],
        "label": "2026-08-14",
        "calibration": {
            "dark": dark_path.to_string_lossy(),
            "flat": flat_path.to_string_lossy()
        },
        "settings": { "align": synthetic_align() }
    });
    let resp = api_master_accumulate(add.to_string()).expect("add");
    let added: MasterAccumulateResult = serde_json::from_str(&resp).unwrap();
    let fold_report = added.calibration.expect("an add reports its calibration");
    assert_eq!(slot(&fold_report, "dark").quality, MatchQuality::Exact);
    assert_eq!(slot(&fold_report, "flat").quality, MatchQuality::Exact);
    assert_eq!(
        slot(&fold_report, "bias").quality,
        MatchQuality::NotRequired
    );
    assert!(
        !fold_report.has_warnings(),
        "a fully matched fold raises nothing: {:?}",
        fold_report.masters
    );

    // The record survives the call in a log beside the sidecar.
    let log = read_fold_calibration_log(sidecar.as_path())
        .expect("read log")
        .expect("the first fold creates the log");
    assert_eq!(log.folds.len(), 1);
    assert_eq!(log.folds[0].label, "2026-08-14");
    assert_eq!(log.folds[0].lights, 2);

    let master_path = dir.join("m31_master.fits");
    let finalize = serde_json::json!({
        "op": "finalize",
        "sidecarPath": sidecar.to_string_lossy(),
        "masterFitsPath": master_path.to_string_lossy()
    });
    api_master_accumulate(finalize.to_string()).expect("finalize");

    let (_img, header) = read_fits(master_path.as_path()).expect("read finalized master");
    let history = history_text(&header);
    assert!(
        history.contains("Fold '2026-08-14' (2 lights)"),
        "{:?}",
        header.history
    );
    let dark_line = format!("Calibration dark: {} [exact]", dark_path.to_string_lossy());
    assert!(
        history.contains(&dark_line),
        "the finalized master must name the dark each fold applied: {:?}",
        header.history
    );
    assert_eq!(header.get("CALWARN").and_then(|v| v.as_bool()), Some(false));
}

/// A master finalized with no calibration log says so out loud and raises the
/// warning flag: a silent absence would read as "no calibration problems".
#[test]
fn finalize_without_a_calibration_log_states_the_gap() {
    let dir = temp_dir("master_missing_calibration_log");
    let size = 64u32;
    let reference = render_field(size, &base_stars(size as f64), 400.0);
    let ref_path = dir.join("ref.fits");
    write_field_fits(&ref_path, &reference);
    let sidecar = dir.join("bare.nsmaster");

    api_master_accumulate(
        serde_json::json!({
            "op": "create",
            "referencePath": ref_path.to_string_lossy(),
            "sidecarPath": sidecar.to_string_lossy()
        })
        .to_string(),
    )
    .expect("create");

    let master_path = dir.join("bare_master.fits");
    api_master_accumulate(
        serde_json::json!({
            "op": "finalize",
            "sidecarPath": sidecar.to_string_lossy(),
            "masterFitsPath": master_path.to_string_lossy()
        })
        .to_string(),
    )
    .expect("finalize");

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    assert!(
        history_text(&header).contains("Calibration record unavailable"),
        "{:?}",
        header.history
    );
    assert_eq!(header.get("CALWARN").and_then(|v| v.as_bool()), Some(true));
}

/// One fold's lights, folded into a master whose provenance log is already
/// corrupt on disk.
///
/// The fold is committed to the sidecar before the log is touched, and the Dart
/// caller records the folded sub ids only when the call succeeds — so a call
/// that commits and then reports failure makes the retry fold the same lights a
/// second time, inflating `total_frames` and re-weighting the pixels with
/// duplicated data. The provenance log may not veto a fold that is already
/// durable.
#[test]
fn a_committed_fold_is_not_reported_as_failed_by_its_calibration_log() {
    let dir = temp_dir("master_corrupt_calibration_log");
    let size = 128u32;
    let stars = base_stars(size as f64);
    let reference = render_field(size, &stars, 400.0);
    let ref_path = dir.join("ref.fits");
    write_light_with_metadata(&ref_path, &reference, "2026-08-14T21:00:00");
    let sidecar = dir.join("m31.nsmaster");

    api_master_accumulate(
        serde_json::json!({
            "op": "create",
            "referencePath": ref_path.to_string_lossy(),
            "sidecarPath": sidecar.to_string_lossy(),
            "target": "M31"
        })
        .to_string(),
    )
    .expect("create");

    // What a process killed mid-write leaves behind: a log that exists and does
    // not parse.
    std::fs::write(
        calibration_log_path(sidecar.as_path()),
        b"{\"folds\":[{\"label\":\"2026-08-1",
    )
    .expect("write a torn log");

    let mut light_paths = Vec::new();
    for (i, (dx, dy)) in [(0.0, 0.0), (2.0, -1.0)].iter().enumerate() {
        let field = render_field(size, &shift_stars(&stars, *dx, *dy), 400.0);
        let p = dir.join(format!("fold{i}.fits"));
        write_light_with_metadata(&p, &field, "2026-08-14T21:00:00");
        light_paths.push(p.to_string_lossy().to_string());
    }

    let outcome = api_master_accumulate(
        serde_json::json!({
            "op": "add",
            "sidecarPath": sidecar.to_string_lossy(),
            "lightPaths": light_paths,
            "exposuresSec": [60.0, 60.0],
            "label": "2026-08-14",
            "settings": { "align": synthetic_align() }
        })
        .to_string(),
    );

    // What the sidecar actually holds, whatever the call answered.
    let info: MasterAccumulateResult = serde_json::from_str(
        &api_master_accumulate(
            serde_json::json!({"op": "info", "sidecarPath": sidecar.to_string_lossy()}).to_string(),
        )
        .expect("info"),
    )
    .unwrap();

    let resp = match outcome {
        Ok(resp) => resp,
        Err(e) => panic!(
            "the fold is already committed to the sidecar ({} frames) but master_add reported failure, so the caller retries and folds the same lights again: {e}",
            info.frame_count
        ),
    };
    let added: MasterAccumulateResult = serde_json::from_str(&resp).unwrap();
    assert_eq!(added.frames_added, 2);
    assert_eq!(info.frame_count, 2);
    let warning = added
        .calibration_log_warning
        .expect("a fold whose provenance could not be recorded says so");
    assert!(
        warning.contains("corrupt calibration log"),
        "the warning names what went wrong: {warning}"
    );
}

/// A retired accumulator is refused in words the Dart side can act on.
///
/// The seam is a plain string, so the marker clause IS the contract: it is what
/// `master_accumulation_service.dart` matches to archive the retired sidecar
/// aside and carry the night into a new master. Reword it here and the night
/// silently starts failing instead.
#[test]
fn a_retired_sidecar_is_refused_with_the_marker_the_dart_side_acts_on() {
    let dir = temp_dir("master_retired_sidecar");
    let sidecar = dir.join("v1.nsmaster");
    // A version-1 sidecar: the magic and header this build reads, with the
    // retired version stamped in it.
    let mut bytes = Vec::new();
    bytes.extend_from_slice(skotiq_imaging::master_accumulation::MASTER_MAGIC);
    bytes.extend_from_slice(&1u32.to_le_bytes());
    bytes.extend_from_slice(&0u32.to_le_bytes());
    std::fs::write(&sidecar, &bytes).expect("write a v1 sidecar");

    let error = api_master_accumulate(
        serde_json::json!({"op": "info", "sidecarPath": sidecar.to_string_lossy()}).to_string(),
    )
    .expect_err("a retired sidecar is refused");

    assert!(
        error.contains(RETIRED_SIDECAR_MARKER),
        "the refusal must carry the marker the Dart side matches on: {error}"
    );
    assert!(
        error.contains("every original sub is untouched on disk"),
        "and must still tell the operator their data is safe: {error}"
    );
}

/// The provenance log is written through a temporary sibling and renamed, so a
/// process killed mid-append leaves the previous log intact rather than a torn
/// one that fails every later fold.
#[test]
fn the_calibration_log_is_written_atomically() {
    let dir = temp_dir("master_atomic_calibration_log");
    let sidecar = dir.join("atomic.nsmaster");
    let report = CalibrationReport {
        masters: Vec::new(),
        cosmetic_correction: false,
        anchor_light: None,
        anchor_unreadable: false,
    };

    for label in ["night-one", "night-two"] {
        append_fold_calibration(
            sidecar.as_path(),
            FoldCalibration {
                label: label.to_string(),
                lights: 1,
                report: report.clone(),
            },
        )
        .expect("append");
    }

    let log = read_fold_calibration_log(sidecar.as_path())
        .expect("read log")
        .expect("the log exists");
    assert_eq!(log.folds.len(), 2);
    let leftovers: Vec<PathBuf> = std::fs::read_dir(dir.as_ref())
        .expect("read dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.to_string_lossy().contains("nshatmp"))
        .collect();
    assert!(
        leftovers.is_empty(),
        "an atomic write leaves no temporary behind: {leftovers:?}"
    );
}

/// A master whose provenance log cannot be read still gets written.
///
/// The sidecar holds the integrated data of every night folded so far; the log
/// beside it holds the story of how they were calibrated. A torn story must not
/// cost the operator the master — it costs them the provenance, said out loud
/// in HISTORY and flagged with CALWARN.
#[test]
fn finalize_with_an_unreadable_calibration_log_still_writes_the_master() {
    let dir = temp_dir("master_unreadable_calibration_log");
    let size = 64u32;
    let reference = render_field(size, &base_stars(size as f64), 400.0);
    let ref_path = dir.join("ref.fits");
    write_field_fits(&ref_path, &reference);
    let sidecar = dir.join("torn.nsmaster");

    api_master_accumulate(
        serde_json::json!({
            "op": "create",
            "referencePath": ref_path.to_string_lossy(),
            "sidecarPath": sidecar.to_string_lossy()
        })
        .to_string(),
    )
    .expect("create");
    std::fs::write(calibration_log_path(sidecar.as_path()), b"{\"folds\":[")
        .expect("write a torn log");

    let master_path = dir.join("torn_master.fits");
    api_master_accumulate(
        serde_json::json!({
            "op": "finalize",
            "sidecarPath": sidecar.to_string_lossy(),
            "masterFitsPath": master_path.to_string_lossy()
        })
        .to_string(),
    )
    .expect("a corrupt provenance log does not block the data product");

    let (_img, header) = read_fits(master_path.as_path()).expect("read master");
    let history = history_text(&header);
    assert!(
        history.contains("Calibration record unreadable"),
        "the master states why its provenance is missing: {:?}",
        header.history
    );
    assert_eq!(header.get("CALWARN").and_then(|v| v.as_bool()), Some(true));
}

/// `exposuresSec` is the source of both `totalIntegrationSec` and the
/// accumulating master's FITS `EXPTIME`, and it was value-unchecked: three
/// lights at -100 s produced a succeeded job reporting -300.0 seconds of
/// integration. Every entry has to be a real, non-negative number of seconds,
/// and the refusal has to say WHICH entry and WHAT it was.
#[test]
fn exposures_per_light_refuses_impossible_seconds() {
    let negative = exposures_per_light(&[100.0, -100.0, 100.0], 3).unwrap_err();
    assert!(
        negative.contains("exposuresSec[1]") && negative.contains("-100"),
        "the refusal must name the index and the value: {negative}"
    );

    let nan = exposures_per_light(&[f64::NAN], 1).unwrap_err();
    assert!(
        nan.contains("exposuresSec[0]") && nan.contains("NaN"),
        "the refusal must name the index and the value: {nan}"
    );

    let infinite = exposures_per_light(&[300.0, f64::INFINITY], 2).unwrap_err();
    assert!(
        infinite.contains("exposuresSec[1]") && infinite.contains("inf"),
        "the refusal must name the index and the value: {infinite}"
    );

    // Still accepted: real seconds, zero (what an omitted list means per
    // frame), and an omitted list itself.
    assert_eq!(
        exposures_per_light(&[300.0, 0.0], 2).unwrap(),
        vec![300.0, 0.0]
    );
    assert_eq!(exposures_per_light(&[], 3).unwrap(), vec![0.0, 0.0, 0.0]);
}
