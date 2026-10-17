//! `color_calibrate@1`: recovery of an injected colour cast from a synthetic
//! scene, the explicit skips, the mono refusal, and determinism.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::fits::FitsHeader;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, wcs_header, Lcg,
};
use crate::recipe::{
    validate, CatalogError, CatalogStar, OpRegistry, PhotometryCatalog, Recipe, RecipeAuthor,
    RecipeError, RecipeStep, RenderOptions, StepOutcome,
};

/// Per-channel intercepts of the planted `log₁₀ amplitude = a + b·(B−V)` lines.
/// Red sits well above green and blue well below it: the colour cast the solve
/// has to find.
const PLANTED_A: [f64; 3] = [3.30, 3.20, 3.05];
/// Per-channel colour slopes of those lines.
const PLANTED_B: [f64; 3] = [0.30, 0.0, -0.35];
/// Sky pedestal of the synthetic scene, in ADU.
const SCENE_BACKGROUND: f64 = 800.0;
/// Gaussian noise sigma of the synthetic scene, in ADU.
const SCENE_NOISE: f64 = 8.0;
/// PSF sigma of the planted stars, in pixels.
const SCENE_PSF_SIGMA: f64 = 2.2;
/// Grid spacing of the planted stars, in pixels.
const SCENE_SPACING: usize = 32;
/// Margin left clear of planted stars at every edge, in pixels.
const SCENE_MARGIN: usize = 24;
/// Bluest planted colour index.
const SCENE_BV_MIN: f64 = -0.2;
/// Reddest planted colour index.
const SCENE_BV_MAX: f64 = 1.6;

/// The registry this build ships, which carries the operation under test.
fn registry() -> OpRegistry {
    OpRegistry::builtin().expect("the builtin list registers cleanly")
}

/// A one-step recipe over the operation under test.
fn recipe_with(params: Value) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    recipe.steps.push(
        RecipeStep::new(ColorCalibrateV1.id(), ColorCalibrateV1.version()).with_params(params),
    );
    recipe
}

/// A synthetic scene and the catalogue that describes it.
struct Scene {
    /// The frame, three channels of linear ADU with a full WCS header.
    image: OpImage,
    /// Every planted star, with the colour index it was planted at.
    catalog: Arc<dyn PhotometryCatalog>,
    /// Number of planted stars.
    planted: usize,
}

/// The colour index star `index` of `count` is planted at.
fn planted_bv(index: usize, count: usize) -> f64 {
    if count <= 1 {
        return SCENE_BV_MIN;
    }
    SCENE_BV_MIN + (SCENE_BV_MAX - SCENE_BV_MIN) * (index as f64 / (count - 1) as f64)
}

/// The channel scale a correct solve reports, relative to green.
///
/// The fit reads the flux a `white_ref_bv` star would have off each channel's
/// planted line and takes the reciprocal, so the answer is the ratio of the two
/// lines evaluated there — independent of what fraction of a star's flux the
/// aperture actually captured, because that fraction is common to all three
/// channels of a star and cancels in the normalisation.
fn expected_scale(channel: usize, white_ref_bv: f64) -> f64 {
    let green = PLANTED_A[1] + PLANTED_B[1] * white_ref_bv;
    let this = PLANTED_A[channel] + PLANTED_B[channel] * white_ref_bv;
    10f64.powf(green - this)
}

/// Build a synthetic scene: Gaussian noise on a pedestal plus a grid of round
/// Gaussian stars whose per-channel amplitudes follow the planted lines.
fn scene(width: u32, height: u32, seed: u64) -> Scene {
    let w = width as usize;
    let h = height as usize;
    let mut rng = Lcg::new(seed);
    let mut data = vec![0.0_f32; w * h * 3];
    for value in data.iter_mut() {
        let u1 = rng.next_unit().max(1e-12);
        let u2 = rng.next_unit();
        let gaussian = (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos();
        *value = (SCENE_BACKGROUND + gaussian * SCENE_NOISE) as f32;
    }

    let mut positions: Vec<(usize, usize)> = Vec::new();
    let mut y = SCENE_MARGIN;
    while y + SCENE_MARGIN < h {
        let mut x = SCENE_MARGIN;
        while x + SCENE_MARGIN < w {
            positions.push((x, y));
            x += SCENE_SPACING;
        }
        y += SCENE_SPACING;
    }
    let count = positions.len();

    let two_sigma_sq = 2.0 * SCENE_PSF_SIGMA * SCENE_PSF_SIGMA;
    let reach = (4.0 * SCENE_PSF_SIGMA).ceil() as i64;
    for (index, &(sx, sy)) in positions.iter().enumerate() {
        let bv = planted_bv(index, count);
        for dy in -reach..=reach {
            for dx in -reach..=reach {
                let x = sx as i64 + dx;
                let y = sy as i64 + dy;
                if x < 0 || y < 0 || x >= w as i64 || y >= h as i64 {
                    continue;
                }
                let profile = (-((dx * dx + dy * dy) as f64) / two_sigma_sq).exp();
                let pixel = (y as usize * w + x as usize) * 3;
                for (channel, (intercept, slope)) in
                    PLANTED_A.iter().zip(PLANTED_B.iter()).enumerate()
                {
                    let amplitude = 10f64.powf(intercept + slope * bv);
                    data[pixel + channel] += (amplitude * profile) as f32;
                }
            }
        }
    }

    let image = OpImage::new(width, height, 3, data, wcs_header(width, height, 3))
        .expect("the synthetic scene geometry is consistent");
    let wcs = image.wcs().expect("the scene header carries a solution");
    let stars: Vec<CatalogStar> = positions
        .iter()
        .enumerate()
        .map(|(index, &(sx, sy))| {
            let (ra_deg, dec_deg) = wcs.pixel_to_world(sx as f64, sy as f64);
            CatalogStar {
                ra_deg,
                dec_deg,
                v_mag: 12.0,
                b_minus_v: planted_bv(index, count),
            }
        })
        .collect();

    Scene {
        image,
        catalog: Arc::new(SceneCatalog { stars }),
        planted: count,
    }
}

/// A catalogue over a fixed star list, answering cone searches honestly.
struct SceneCatalog {
    /// Every star the scene planted, in a stable order.
    stars: Vec<CatalogStar>,
}

impl PhotometryCatalog for SceneCatalog {
    fn cone_search(
        &self,
        ra_deg: f64,
        dec_deg: f64,
        radius_deg: f64,
        mag_limit: f64,
    ) -> Result<Vec<CatalogStar>, CatalogError> {
        Ok(self
            .stars
            .iter()
            .filter(|star| {
                star.v_mag <= mag_limit
                    && separation_deg(ra_deg, dec_deg, star.ra_deg, star.dec_deg) <= radius_deg
            })
            .cloned()
            .collect())
    }

    fn identity(&self) -> String {
        let mut text = String::new();
        for star in &self.stars {
            text.push_str(&format!(
                "{},{},{},{};",
                star.ra_deg, star.dec_deg, star.v_mag, star.b_minus_v
            ));
        }
        crate::recipe::fingerprint_hex(text.as_bytes())
    }
}

/// A catalogue that is installed but carries no colour-indexed star, the
/// fresh-install shape.
struct EmptyCatalog;

impl PhotometryCatalog for EmptyCatalog {
    fn cone_search(
        &self,
        _ra_deg: f64,
        _dec_deg: f64,
        _radius_deg: f64,
        _mag_limit: f64,
    ) -> Result<Vec<CatalogStar>, CatalogError> {
        Ok(Vec::new())
    }

    fn identity(&self) -> String {
        // Every query answers with nothing, so one identity covers them all.
        "test-empty-catalog".to_string()
    }
}

/// A catalogue that reports itself unavailable.
struct MissingCatalog;

impl PhotometryCatalog for MissingCatalog {
    fn cone_search(
        &self,
        _ra_deg: f64,
        _dec_deg: f64,
        _radius_deg: f64,
        _mag_limit: f64,
    ) -> Result<Vec<CatalogStar>, CatalogError> {
        Err(CatalogError::Unavailable {
            reason: "the photometry pack is not downloaded".to_string(),
        })
    }

    fn identity(&self) -> String {
        // Every query reports the same unavailability, so one identity covers
        // them all.
        "test-missing-catalog".to_string()
    }
}

/// Great-circle separation between two sky positions, in degrees.
fn separation_deg(ra1: f64, dec1: f64, ra2: f64, dec2: f64) -> f64 {
    let (r1, d1) = (ra1.to_radians(), dec1.to_radians());
    let (r2, d2) = (ra2.to_radians(), dec2.to_radians());
    let cosine = d1.sin() * d2.sin() + d1.cos() * d2.cos() * (r1 - r2).cos();
    cosine.clamp(-1.0, 1.0).acos().to_degrees()
}

#[test]
fn the_solve_recovers_an_injected_color_cast_from_a_synthetic_scene() {
    let scene = scene(200, 200, 0xC01D_CA11);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let solved = solve(&scene.image, &json!({}), &ctx).expect("the scene solves");

    assert!(
        solved.matched >= MIN_MATCHED_STARS,
        "{} of {} planted stars cross-matched",
        solved.matched,
        scene.planted
    );
    assert_eq!(
        solved.channel_scale[1], 1.0,
        "green is the normalisation anchor and is pinned to exactly 1.0"
    );
    for channel in [0usize, 2] {
        let expected = expected_scale(channel, solved.white_ref_bv);
        let found = solved.channel_scale[channel];
        let relative = (found - expected).abs() / expected;
        assert!(
            relative < 0.08,
            "channel {channel}: recovered scale {found} does not match the planted {expected} (relative {relative})"
        );
    }
    // The cast is real, not a rounding difference: red was planted bright and
    // blue faint, so the solve has to pull them in opposite directions.
    assert!(solved.channel_scale[0] < 0.7, "red must be pulled down");
    assert!(solved.channel_scale[2] > 1.5, "blue must be pushed up");
    assert!(solved.residual.is_finite() && solved.residual >= 0.0);
}

#[test]
fn a_calibrated_scene_solves_to_a_neutral_balance() {
    // The end-to-end proof: apply the solve, then solve again. A correct
    // calibration leaves nothing for the second solve to correct.
    let scene = scene(200, 200, 0x05EC_011D);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let calibrated = ColorCalibrateV1
        .apply(&scene.image, &json!({}), &ctx)
        .expect("the scene calibrates");
    let again = solve(&calibrated, &json!({}), &ctx).expect("the calibrated scene solves");
    for (channel, scale) in again.channel_scale.iter().enumerate() {
        assert!(
            (scale - 1.0).abs() < 0.05,
            "channel {channel} still carries a cast after calibration: {scale}"
        );
    }
}

#[test]
fn the_green_channel_comes_through_byte_identical() {
    // The normalisation pins green to exactly 1.0, and a unit scale copies the
    // sample rather than multiplying it, so green is provably untouched.
    let scene = scene(200, 200, 0x9E11_0000);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let out = ColorCalibrateV1
        .apply(&scene.image, &json!({}), &ctx)
        .expect("the scene calibrates");

    let mut red_moved = false;
    let mut blue_moved = false;
    for (index, (found, source)) in out.data().iter().zip(scene.image.data().iter()).enumerate() {
        match index % 3 {
            1 => assert_eq!(
                found.to_bits(),
                source.to_bits(),
                "green sample {index} must be byte-identical"
            ),
            0 => red_moved |= found.to_bits() != source.to_bits(),
            _ => blue_moved |= found.to_bits() != source.to_bits(),
        }
    }
    assert!(red_moved && blue_moved, "the other channels must be scaled");
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries() {
    for (width, height) in [(200u32, 168u32), (201, 169)] {
        let scene = scene(width, height, 0xD0D0 + width as u64);
        let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
        let base = Arc::new(scene.image);
        let out = assert_deterministic(
            &recipe_with(json!({})),
            &base,
            &registry(),
            &ctx,
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_wcs_identical(&out.image, &base, "the calibration keeps the plate");
    }
}

#[test]
fn a_mono_master_is_refused_rather_than_returned_unchanged() {
    let mono = OpImage::new(32, 32, 1, vec![800.0_f32; 32 * 32], wcs_header(32, 32, 1))
        .expect("the mono frame geometry is consistent");
    // The refusal comes before the catalogue is consulted: a mono master has no
    // channel balance whether or not photometry is installed.
    let ctx = OpContext::new().with_catalog(Arc::new(SceneCatalog { stars: Vec::new() }));
    assert_eq!(
        ColorCalibrateV1.apply(&mono, &json!({}), &ctx).unwrap_err(),
        OpError::UnsupportedChannels {
            op_id: "color_calibrate",
            op_version: 1,
            channels: 1,
            expected: "a colour master with 3 channels; combine a per-filter mono master first",
        }
    );
    assert_eq!(
        ColorCalibrateV1
            .apply(&mono, &json!({}), &OpContext::new())
            .unwrap_err(),
        OpError::UnsupportedChannels {
            op_id: "color_calibrate",
            op_version: 1,
            channels: 1,
            expected: "a colour master with 3 channels; combine a per-filter mono master first",
        }
    );
}

#[test]
fn a_fresh_install_with_no_catalog_records_the_step_as_skipped() {
    let scene = scene(120, 120, 0xF00D);
    let base = Arc::new(scene.image);
    let out = assert_deterministic(
        &recipe_with(json!({})),
        &base,
        &registry(),
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("a skipped step still renders");
    assert_eq!(
        out.report.steps[0].outcome,
        StepOutcome::Skipped {
            reason: "no photometric catalog is installed".to_string()
        }
    );
    assert!(out.report.has_skips());
    assert_pixels_identical(&out.image, &base, "a skipped step passes the image through");
}

#[test]
fn a_catalog_with_no_color_indices_records_the_step_as_skipped() {
    let scene = scene(120, 120, 0xBEEF);
    let base = Arc::new(scene.image);
    let ctx = OpContext::new().with_catalog(Arc::new(EmptyCatalog));
    let out = assert_deterministic(
        &recipe_with(json!({})),
        &base,
        &registry(),
        &ctx,
        RenderOptions::full(),
    )
    .expect("a skipped step still renders");
    let StepOutcome::Skipped { reason } = &out.report.steps[0].outcome else {
        panic!("expected a skip, found {:?}", out.report.steps[0].outcome);
    };
    assert!(
        reason.contains("color-indexed"),
        "the reason must name what is missing: {reason}"
    );
    assert_pixels_identical(&out.image, &base, "a skipped step passes the image through");
}

#[test]
fn a_catalog_that_reports_itself_unavailable_records_the_step_as_skipped() {
    let scene = scene(120, 120, 0xCAFE);
    let base = Arc::new(scene.image);
    let ctx = OpContext::new().with_catalog(Arc::new(MissingCatalog));
    let out = assert_deterministic(
        &recipe_with(json!({})),
        &base,
        &registry(),
        &ctx,
        RenderOptions::full(),
    )
    .expect("a skipped step still renders");
    assert_eq!(
        out.report.steps[0].outcome,
        StepOutcome::Skipped {
            reason: "the photometry pack is not downloaded".to_string()
        }
    );
    assert_pixels_identical(&out.image, &base, "a skipped step passes the image through");
}

#[test]
fn a_master_with_no_plate_solve_is_reported_rather_than_guessed_at() {
    let mut header = FitsHeader::new();
    header.set_int("NAXIS1", 32);
    header.set_int("NAXIS2", 32);
    header.set_int("NAXIS3", 3);
    let unsolved = OpImage::new(32, 32, 3, vec![800.0_f32; 32 * 32 * 3], header)
        .expect("the unsolved frame geometry is consistent");
    let ctx = OpContext::new().with_catalog(Arc::new(EmptyCatalog));
    assert!(matches!(
        ColorCalibrateV1.apply(&unsolved, &json!({}), &ctx),
        Err(OpError::Failed {
            op_id: "color_calibrate",
            ..
        })
    ));
}

#[test]
fn too_few_cross_matches_are_reported_rather_than_fitted() {
    let scene = scene(200, 200, 0xA115);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let error = solve(&scene.image, &json!({ "minStars": 10_000 }), &ctx)
        .expect_err("an impossible requirement is reported");
    let OpError::Failed { reason, .. } = error else {
        panic!("expected a failure, found {error:?}");
    };
    assert!(
        reason.contains("cross-matched"),
        "the reason must say what fell short: {reason}"
    );
}

#[test]
fn the_astrometry_and_the_frame_metadata_survive() {
    let scene = scene(200, 200, 0x1234);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let out = ColorCalibrateV1
        .apply(&scene.image, &json!({}), &ctx)
        .expect("the scene calibrates");
    assert_wcs_identical(&out, &scene.image, "the calibration keeps the plate");
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
    assert_eq!(out.header().get_int("NAXIS1"), Some(200));
    assert_eq!(out.header().get_int("NAXIS3"), Some(3));
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let scene = scene(120, 120, 0x5555);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    ctx.request_cancel();
    assert_eq!(
        ColorCalibrateV1
            .apply(&scene.image, &json!({}), &ctx)
            .unwrap_err(),
        OpError::Cancelled
    );
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        ColorCalibrateV1.validate_params(&json!({ "whiteRef": 0.65 })),
        Err(OpError::UnknownParam {
            op_id: "color_calibrate",
            op_version: 1,
            key: "whiteRef".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "whiteRefBv": "0.65" })),
        Err(OpError::ParamType { key, .. }) if key == "whiteRefBv"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "minStars": -8 })),
        Err(OpError::ParamType { key, .. }) if key == "minStars"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "whiteRefBv": 9.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "whiteRefBv"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "matchRadiusPx": 0.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "matchRadiusPx"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "minStars": 1 })),
        Err(OpError::ParamRange { key, .. }) if key == "minStars"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        ColorCalibrateV1.validate_params(&json!([])),
        Err(OpError::ParamsNotObject {
            op_id: "color_calibrate",
            op_version: 1,
            found: "an array",
        })
    );
}

#[test]
fn the_operation_emits_linear_data_and_is_refused_after_a_stretch() {
    assert_eq!(ColorCalibrateV1.stage(), OpStage::Linear);
    let registry = registry();

    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps.push(RecipeStep::new("color_calibrate", 1));
    good.steps.push(
        RecipeStep::new("stretch", 1).with_params(json!({ "blackPoint": 0.0, "whitePoint": 1.0 })),
    );
    validate(&good, &registry).expect("a calibration above the stretch validates");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps.push(
        RecipeStep::new("stretch", 1).with_params(json!({ "blackPoint": 0.0, "whitePoint": 1.0 })),
    );
    bad.steps.push(RecipeStep::new("color_calibrate", 1));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn two_solves_of_the_same_scene_agree_exactly() {
    let scene = scene(200, 200, 0x7777);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let first = solve(&scene.image, &json!({}), &ctx).expect("the scene solves");
    let second = solve(&scene.image, &json!({}), &ctx).expect("the scene solves again");
    assert_eq!(first, second, "the solve carries no state between calls");
}

#[test]
fn a_wider_reference_colour_moves_the_scales_the_way_the_planted_lines_say() {
    // The reference colour is what the fit is evaluated at, so moving it moves
    // the scales along the planted slopes rather than leaving them alone.
    let scene = scene(200, 200, 0x8888);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    for white_ref_bv in [0.0_f64, 1.2] {
        let solved = solve(&scene.image, &json!({ "whiteRefBv": white_ref_bv }), &ctx)
            .expect("the scene solves");
        assert_eq!(solved.white_ref_bv, white_ref_bv);
        for channel in [0usize, 2] {
            let expected = expected_scale(channel, white_ref_bv);
            let found = solved.channel_scale[channel];
            let relative = (found - expected).abs() / expected;
            assert!(
                relative < 0.10,
                "channel {channel} at B-V {white_ref_bv}: {found} does not match the planted {expected} (relative {relative})"
            );
        }
    }
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    // The solve reaches star detection, per-star aperture photometry and a
    // per-row multiply, all of which run under rayon. A reduction whose split
    // tree followed the pool size would show up here as a last-bit difference.
    let scene = scene(200, 200, 0x7EAD);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| ColorCalibrateV1.apply(&scene.image, &json!({}), &ctx))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| ColorCalibrateV1.apply(&scene.image, &json!({}), &ctx))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}

#[test]
fn a_carried_balance_replays_without_a_catalog_or_a_plate_solve() {
    // A step written from a solve applies exactly the scales it carries, so a
    // render on an install with no photometry still reproduces the calibration.
    let mut header = FitsHeader::new();
    header.set_int("NAXIS1", 2);
    header.set_int("NAXIS2", 1);
    header.set_int("NAXIS3", 3);
    let base = OpImage::new(2, 1, 3, vec![100.0, 200.0, 400.0, 50.0, 60.0, 70.0], header)
        .expect("the swatch geometry is consistent");
    let out = ColorCalibrateV1
        .apply(
            &base,
            &json!({ "channelScale": [2.0, 1.0, 0.5] }),
            &OpContext::new(),
        )
        .expect("a carried balance renders with no catalog and no plate solve");
    assert_eq!(out.data(), &[200.0, 200.0, 200.0, 100.0, 60.0, 35.0]);
}

#[test]
fn a_solve_writes_a_payload_that_replays_it_at_a_preview_level() {
    // A downsampled level carries fewer measurable stars than the fit needs, so
    // re-measuring there fails on a master that calibrates at full resolution.
    // The carried balance is what makes the preview show the full render.
    let scene = scene(400, 400, 0x4444);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let solved = solve(&scene.image, &json!({}), &ctx).expect("the full render solves");

    let half = crate::recipe::downsample_2x(&scene.image).expect("the level-1 image builds");
    let preview = ctx.clone().at_level(1);
    assert!(
        matches!(
            solve(&half, &json!({}), &preview),
            Err(OpError::Failed { .. })
        ),
        "re-measuring at level 1 must report rather than invent a balance"
    );

    let params = solved.to_params();
    ColorCalibrateV1
        .validate_params(&params)
        .expect("the reported parameters are a valid payload");
    let out = ColorCalibrateV1
        .apply(&half, &params, &preview)
        .expect("the carried balance renders at level 1");
    for (index, (found, source)) in out.data().iter().zip(half.data().iter()).enumerate() {
        let scale = solved.channel_scale[index % 3];
        let expected = (*source as f64 * scale) as f32;
        let expected = if scale == 1.0 { *source } else { expected };
        assert_eq!(
            found.to_bits(),
            expected.to_bits(),
            "preview sample {index} must carry the full render's balance"
        );
    }
}

#[test]
fn a_carried_balance_of_the_wrong_shape_is_rejected() {
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "channelScale": [2.0, 1.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "channelScale"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "channelScale": [2.0, 1.0, 0.5, 0.5] })),
        Err(OpError::ParamRange { key, .. }) if key == "channelScale"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "channelScale": [] })),
        Err(OpError::ParamRange { key, .. }) if key == "channelScale"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "channelScale": [2.0, 1.0, 0.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "channelScale"
    ));
    assert!(matches!(
        ColorCalibrateV1.validate_params(&json!({ "channelScale": 2.0 })),
        Err(OpError::ParamType { key, .. }) if key == "channelScale"
    ));
}

#[test]
fn a_carried_balance_that_is_not_three_finite_numbers_is_rejected() {
    // JSON has no literal for a non-finite number, so one arrives as `null`, as
    // a string, or out of the range a white balance is defined on. Every form is
    // refused: a scale that is not a finite multiplier would write NaN into
    // every pixel of a channel.
    for payload in [
        json!({ "channelScale": [2.0, 1.0, null] }),
        json!({ "channelScale": [2.0, 1.0, "0.5"] }),
        json!({ "channelScale": [2.0, 1.0, true] }),
    ] {
        assert!(
            matches!(
                ColorCalibrateV1.validate_params(&payload),
                Err(OpError::ParamType { ref key, .. }) if key == "channelScale"
            ),
            "{payload} must be refused as a type error"
        );
    }
    for payload in [
        json!({ "channelScale": [2.0, 1.0, 1e12] }),
        json!({ "channelScale": [2.0, 1.0, -1.0] }),
    ] {
        assert!(
            matches!(
                ColorCalibrateV1.validate_params(&payload),
                Err(OpError::ParamRange { ref key, .. }) if key == "channelScale"
            ),
            "{payload} must be refused as a range error"
        );
    }
}

#[test]
fn a_solve_reports_the_scales_it_fitted_and_the_evidence_behind_them() {
    let scene = scene(200, 200, 0x005C_A1E5);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let base = Arc::new(scene.image);
    let rendered = assert_deterministic(
        &recipe_with(json!({})),
        &base,
        &registry(),
        &ctx,
        RenderOptions::full(),
    )
    .expect("the scene renders");

    let measured = rendered.report.steps[0]
        .measurement
        .clone()
        .expect("a step that solved a balance reports it");
    assert_eq!(measured["source"], json!("solved"));

    // The report is the fit that produced these pixels, not a second one: the
    // same scene solved directly agrees to the last bit.
    let direct = solve(&base, &json!({}), &ctx).expect("the scene solves");
    assert_eq!(measured["channelScale"], json!(direct.channel_scale));
    assert_eq!(measured["whiteRefBv"], json!(direct.white_ref_bv));
    assert_eq!(measured["matchedStars"], json!(direct.matched));
    assert_eq!(measured["residual"], json!(direct.residual));
}

#[test]
fn pinning_the_reported_scales_replays_the_solved_render_bit_for_bit() {
    // The read-back exists to be pinned: a draft solves once at full resolution
    // and writes the scales into the step, and every later render — including a
    // preview level that could never cross-match enough stars — replays those
    // numbers. If pinning changed one bit, the editor would be showing a
    // different picture from the one the proof render approved.
    let scene = scene(200, 200, 0x9111_0AD5);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let base = Arc::new(scene.image);
    let ops = registry();

    let solved = assert_deterministic(
        &recipe_with(json!({})),
        &base,
        &ops,
        &ctx,
        RenderOptions::full(),
    )
    .expect("the measuring render runs");
    let scales = solved.report.steps[0]
        .measurement
        .as_ref()
        .expect("the solve reports its scales")["channelScale"]
        .clone();

    // Pinned mode reads neither the catalogue nor the plate solve, so the
    // replay runs under a context that carries neither.
    let pinned = recipe_with(json!({ "channelScale": scales }));
    let replayed = assert_deterministic(
        &pinned,
        &base,
        &ops,
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("the pinned render runs");

    assert_pixels_identical(&solved.image, &replayed.image, "pinned vs re-fitted");
    assert_wcs_identical(&solved.image, &replayed.image, "pinned vs re-fitted");
    assert_eq!(replayed.report.steps[0].outcome, StepOutcome::Applied);
    let pinned_report = replayed.report.steps[0]
        .measurement
        .as_ref()
        .expect("a pinned step reports what it applied");
    assert_eq!(pinned_report["source"], json!("pinned"));
    assert_eq!(
        pinned_report["channelScale"],
        solved.report.steps[0].measurement.as_ref().expect("solved")["channelScale"]
    );
    assert!(
        pinned_report.get("matchedStars").is_none() && pinned_report.get("whiteRefBv").is_none(),
        "pinned mode fits nothing, so it reports no star count and no reference colour: {pinned_report}"
    );
}

#[test]
fn a_step_with_no_channel_scale_still_measures_and_still_applies_its_own_fit() {
    // The read-back rides along; it does not change what an existing recipe
    // renders. A step with no `channelScale` solves from the catalogue and
    // applies exactly those scales, which is what `color_calibrate@1` has always
    // done — so every recipe already on disk replays unchanged at version 1.
    let scene = scene(200, 200, 0x0FF0_0FF0);
    let ctx = OpContext::new().with_catalog(Arc::clone(&scene.catalog));
    let solved = solve(&scene.image, &json!({}), &ctx).expect("the scene solves");
    let out = ColorCalibrateV1
        .apply(&scene.image, &json!({}), &ctx)
        .expect("the scene calibrates");

    for (index, (found, source)) in out.data().iter().zip(scene.image.data().iter()).enumerate() {
        let scale = solved.channel_scale[index % 3];
        let expected = if scale == 1.0 {
            *source
        } else {
            (*source as f64 * scale) as f32
        };
        assert_eq!(
            found.to_bits(),
            expected.to_bits(),
            "sample {index} must carry the step's own fit"
        );
    }
}

#[test]
fn a_carried_balance_is_still_refused_on_a_mono_master() {
    let mono = OpImage::new(4, 4, 1, vec![800.0_f32; 16], wcs_header(4, 4, 1))
        .expect("the mono frame geometry is consistent");
    assert_eq!(
        ColorCalibrateV1
            .apply(
                &mono,
                &json!({ "channelScale": [2.0, 1.0, 0.5] }),
                &OpContext::new()
            )
            .unwrap_err(),
        OpError::UnsupportedChannels {
            op_id: "color_calibrate",
            op_version: 1,
            channels: 1,
            expected: "a colour master with 3 channels; combine a per-filter mono master first",
        }
    );
}
