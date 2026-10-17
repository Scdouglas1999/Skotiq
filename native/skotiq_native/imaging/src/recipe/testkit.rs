//! Test operations, synthetic images, and the determinism harness.
//!
//! The harness is the contract an operation is held to: [`assert_deterministic`]
//! renders the same recipe four ways — twice cold, twice warm, and once with the
//! cache switched off — and asserts every result is byte-identical. An operation
//! that reads a clock, draws unseeded randomness, or lets thread scheduling
//! reach a pixel value fails it.
//!
//! Bit comparison goes through `f32::to_bits`, so a `NaN` that should have been
//! preserved is not silently accepted as equal to a different `NaN`.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};

use crate::fits::FitsHeader;

use super::cache::RenderCache;
use super::model::{
    CatalogError, CatalogStar, DarkroomOp, OpContext, OpError, OpImage, OpStage, PhotometryCatalog,
    Recipe, RecipeError,
};
use super::params::Params;
use super::registry::OpRegistry;
use super::render::{render, RenderOptions, RenderOutput};

// ---------------------------------------------------------------------------
// Synthetic images
// ---------------------------------------------------------------------------

/// A deterministic linear congruential generator. Test images must be
/// reproducible without a `rand` dependency.
pub(crate) struct Lcg(u64);

impl Lcg {
    /// Seeded generator.
    pub(crate) fn new(seed: u64) -> Self {
        Self(seed | 1)
    }

    /// Next raw value.
    pub(crate) fn next_u64(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }

    /// Next value in `[0, 1)`.
    pub(crate) fn next_unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// A FITS header with a complete CD-only WCS, matching what a master carries.
pub(crate) fn wcs_header(width: u32, height: u32, channels: u32) -> FitsHeader {
    let mut header = FitsHeader::new();
    header.set_int("NAXIS1", width as i64);
    header.set_int("NAXIS2", height as i64);
    if channels > 1 {
        header.set_int("NAXIS3", channels as i64);
    }
    header.set_float("CRVAL1", 10.684_708);
    header.set_float("CRVAL2", 41.268_75);
    header.set_float("CRPIX1", (width as f64 + 1.0) / 2.0);
    header.set_float("CRPIX2", (height as f64 + 1.0) / 2.0);
    header.set_float("CD1_1", -0.000_5);
    header.set_float("CD1_2", 0.0);
    header.set_float("CD2_1", 0.0);
    header.set_float("CD2_2", 0.000_5);
    header.set_string("CTYPE1", "RA---TAN");
    header.set_string("CTYPE2", "DEC--TAN");
    header.set_string("OBJECT", "M31");
    header.set_string("FILTER", "L");
    header.set_string("DATE-OBS", "2026-08-16T02:11:04");
    header.set_float("EXPTIME", 300.0);
    header
}

/// A synthetic linear star field: Gaussian noise on a pedestal plus a grid of
/// round Gaussian stars, in `F32` ADU, carrying a full WCS header.
pub(crate) fn synthetic_star_field(width: u32, height: u32, channels: u32, seed: u64) -> OpImage {
    let w = width as usize;
    let h = height as usize;
    let c = channels as usize;
    let mut rng = Lcg::new(seed);
    let mut data = vec![0.0_f32; w * h * c];
    for value in data.iter_mut() {
        let u1 = rng.next_unit().max(1e-12);
        let u2 = rng.next_unit();
        let g = (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos();
        *value = (800.0 + g * 30.0) as f32;
    }

    let sigma = 1.8_f64;
    let two_sig_sq = 2.0 * sigma * sigma;
    let radius = (4.0 * sigma).ceil() as i64;
    let step = 17usize;
    let mut sy = step;
    while sy + step < h {
        let mut sx = step;
        while sx + step < w {
            let peak = 4000.0 + ((sx * 31 + sy * 17) % 97) as f64 * 120.0;
            for dy in -radius..=radius {
                for dx in -radius..=radius {
                    let x = sx as i64 + dx;
                    let y = sy as i64 + dy;
                    if x < 0 || y < 0 || x >= w as i64 || y >= h as i64 {
                        continue;
                    }
                    let rr = (dx * dx + dy * dy) as f64;
                    let add = peak * (-rr / two_sig_sq).exp();
                    for channel in 0..c {
                        let idx = (y as usize * w + x as usize) * c + channel;
                        data[idx] += (add * (1.0 - 0.15 * channel as f64)) as f32;
                    }
                }
            }
            sx += step;
        }
        sy += step;
    }

    OpImage::new(
        width,
        height,
        channels,
        data,
        wcs_header(width, height, channels),
    )
    .expect("synthetic star field geometry is consistent")
}

// ---------------------------------------------------------------------------
// Test operations
// ---------------------------------------------------------------------------

/// A linear-stage operation multiplying every sample by `factor`.
pub(crate) struct ScaleOp {
    /// Registry version this instance answers as.
    pub(crate) version: u32,
    /// Applications since construction, for cache tests.
    pub(crate) applications: Arc<AtomicUsize>,
}

impl ScaleOp {
    pub(crate) fn new(version: u32) -> Self {
        Self {
            version,
            applications: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl DarkroomOp for ScaleOp {
    fn id(&self) -> &'static str {
        "test_scale"
    }

    fn version(&self) -> u32 {
        self.version
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["factor"])?;
        p.f64_or("factor", 0.0..=1000.0, 1.0)?;
        Ok(())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        self.applications.fetch_add(1, Ordering::Relaxed);
        let p = Params::new(self, params)?;
        // Version 2 doubles what version 1 did: two registered versions that
        // must not render the same, so the version-permanence test can see it.
        let factor = p.f64_or("factor", 0.0..=1000.0, 1.0)? * self.version as f64;
        let mut out = Vec::with_capacity(image.len());
        for (index, value) in image.data().iter().enumerate() {
            if index % super::model::CANCEL_POLL_PIXELS == 0 {
                ctx.check_cancel()?;
            }
            out.push(value * factor as f32);
        }
        image.with_data(out)
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

/// A stretched-stage operation raising every sample to `gamma` after
/// normalising by `pivot`. Stands in for `stretch@1` in ordering tests.
pub(crate) struct StretchLikeOp;

impl DarkroomOp for StretchLikeOp {
    fn id(&self) -> &'static str {
        "test_stretch"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["gamma", "pivot"])?;
        p.f64_or("gamma", 0.01..=10.0, 0.5)?;
        p.f64_or("pivot", 1.0..=65535.0, 10000.0)?;
        Ok(())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let p = Params::new(self, params)?;
        let gamma = p.f64_or("gamma", 0.01..=10.0, 0.5)?;
        let pivot = p.f64_or("pivot", 1.0..=65535.0, 10000.0)?;
        ctx.check_cancel()?;
        let out: Vec<f32> = image
            .data()
            .iter()
            .map(|v| {
                let normalised = (*v as f64 / pivot).clamp(0.0, 1.0);
                normalised.powf(gamma) as f32
            })
            .collect();
        image.with_data(out)
    }

    fn stage(&self) -> OpStage {
        OpStage::Stretched
    }
}

/// A stretched-stage operation adding a constant. Stands in for `curves@1`.
pub(crate) struct CurvesLikeOp;

impl DarkroomOp for CurvesLikeOp {
    fn id(&self) -> &'static str {
        "test_curves"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["lift"])?;
        p.f64_or("lift", -1.0..=1.0, 0.0)?;
        Ok(())
    }

    fn apply(&self, image: &OpImage, params: &Value, _ctx: &OpContext) -> Result<OpImage, OpError> {
        let p = Params::new(self, params)?;
        let lift = p.f64_or("lift", -1.0..=1.0, 0.0)? as f32;
        let out: Vec<f32> = image.data().iter().map(|v| v + lift).collect();
        image.with_data(out)
    }

    fn stage(&self) -> OpStage {
        OpStage::Stretched
    }
}

/// A linear-stage operation that always fails.
pub(crate) struct FailingOp;

impl DarkroomOp for FailingOp {
    fn id(&self) -> &'static str {
        "test_failing"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        Params::new(self, params)?.allow(&[])
    }

    fn apply(
        &self,
        _image: &OpImage,
        _params: &Value,
        _ctx: &OpContext,
    ) -> Result<OpImage, OpError> {
        Err(OpError::Failed {
            op_id: self.id(),
            op_version: self.version(),
            reason: "the test operation always fails".to_string(),
        })
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

/// A linear-stage operation that needs a photometric catalogue and reports the
/// step as unavailable when none is attached. Stands in for the fresh-install
/// `color_calibrate@1` path.
pub(crate) struct CatalogDependentOp;

impl DarkroomOp for CatalogDependentOp {
    fn id(&self) -> &'static str {
        "test_catalog"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        Params::new(self, params)?.allow(&[])
    }

    fn apply(&self, image: &OpImage, _params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let Some(catalog) = ctx.catalog() else {
            return Err(OpError::Unavailable {
                op_id: self.id(),
                op_version: self.version(),
                reason: "no photometric catalog is installed".to_string(),
            });
        };
        let stars = catalog
            .cone_search(10.0, 41.0, 0.5, 17.0)
            .map_err(|e| OpError::Failed {
                op_id: self.id(),
                op_version: self.version(),
                reason: e.to_string(),
            })?;
        let gain = 1.0 + stars.len() as f32 / 100.0;
        let out: Vec<f32> = image.data().iter().map(|v| v * gain).collect();
        image.with_data(out)
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

/// A linear-stage operation that raises the cancel flag partway through its own
/// loop and then observes it, the way a long operation aborts at safing.
pub(crate) struct SelfCancellingOp;

impl DarkroomOp for SelfCancellingOp {
    fn id(&self) -> &'static str {
        "test_self_cancel"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        Params::new(self, params)?.allow(&[])
    }

    fn apply(&self, image: &OpImage, _params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        ctx.request_cancel();
        for (index, _) in image.data().iter().enumerate() {
            if index % 8 == 0 {
                ctx.check_cancel()?;
            }
        }
        Ok(image.clone())
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

/// A linear-stage operation cropping a fixed margin off every edge, so geometry
/// and astrometry updates are exercised.
pub(crate) struct CropOp;

impl DarkroomOp for CropOp {
    fn id(&self) -> &'static str {
        "test_crop"
    }

    fn version(&self) -> u32 {
        1
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["margin"])?;
        p.u32_or("margin", 0..=4096, 1)?;
        Ok(())
    }

    fn apply(&self, image: &OpImage, params: &Value, _ctx: &OpContext) -> Result<OpImage, OpError> {
        let p = Params::new(self, params)?;
        let margin = p.u32_or("margin", 0..=4096, 1)? as usize;
        let width = image.width() as usize;
        let height = image.height() as usize;
        let channels = image.channels() as usize;
        if width <= margin * 2 || height <= margin * 2 {
            return Err(OpError::Failed {
                op_id: self.id(),
                op_version: self.version(),
                reason: format!("margin {margin} leaves no pixels"),
            });
        }
        let out_width = width - margin * 2;
        let out_height = height - margin * 2;
        let mut out = Vec::with_capacity(out_width * out_height * channels);
        for y in 0..out_height {
            for x in 0..out_width {
                for c in 0..channels {
                    out.push(image.data()[((y + margin) * width + (x + margin)) * channels + c]);
                }
            }
        }
        let mut cropped =
            image.with_geometry(out_width as u32, out_height as u32, channels as u32, out)?;
        cropped.translate_reference_pixel(margin as f64, margin as f64);
        Ok(cropped)
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }
}

/// A photometric catalogue returning a fixed, ordered star list.
pub(crate) struct FixedCatalog {
    /// Stars every query returns.
    pub(crate) stars: Vec<CatalogStar>,
}

impl PhotometryCatalog for FixedCatalog {
    fn cone_search(
        &self,
        _ra_deg: f64,
        _dec_deg: f64,
        _radius_deg: f64,
        _mag_limit: f64,
    ) -> Result<Vec<CatalogStar>, CatalogError> {
        Ok(self.stars.clone())
    }

    fn identity(&self) -> String {
        let mut text = String::new();
        for star in &self.stars {
            text.push_str(&format!(
                "{},{},{},{};",
                star.ra_deg, star.dec_deg, star.v_mag, star.b_minus_v
            ));
        }
        super::model::fingerprint_hex(text.as_bytes())
    }
}

/// The three ordered stars [`fixed_catalog`] answers with.
pub(crate) fn fixed_stars() -> Vec<CatalogStar> {
    vec![
        CatalogStar {
            ra_deg: 10.1,
            dec_deg: 41.0,
            v_mag: 11.2,
            b_minus_v: 0.62,
        },
        CatalogStar {
            ra_deg: 10.2,
            dec_deg: 41.1,
            v_mag: 12.4,
            b_minus_v: 0.41,
        },
        CatalogStar {
            ra_deg: 10.3,
            dec_deg: 41.2,
            v_mag: 13.7,
            b_minus_v: 1.05,
        },
    ]
}

/// A catalogue with three ordered stars.
pub(crate) fn fixed_catalog() -> Arc<dyn PhotometryCatalog> {
    Arc::new(FixedCatalog {
        stars: fixed_stars(),
    })
}

/// A registry holding every test operation.
pub(crate) fn test_registry() -> OpRegistry {
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(ScaleOp::new(1)))
        .expect("test_scale@1 registers once");
    registry
        .register(Arc::new(ScaleOp::new(2)))
        .expect("test_scale@2 registers once");
    registry
        .register(Arc::new(StretchLikeOp))
        .expect("test_stretch@1 registers once");
    registry
        .register(Arc::new(CurvesLikeOp))
        .expect("test_curves@1 registers once");
    registry
        .register(Arc::new(FailingOp))
        .expect("test_failing@1 registers once");
    registry
        .register(Arc::new(CatalogDependentOp))
        .expect("test_catalog@1 registers once");
    registry
        .register(Arc::new(SelfCancellingOp))
        .expect("test_self_cancel@1 registers once");
    registry
        .register(Arc::new(CropOp))
        .expect("test_crop@1 registers once");
    registry
}

/// Parameters for [`ScaleOp`].
pub(crate) fn scale_params(factor: f64) -> Value {
    json!({ "factor": factor })
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

/// Assert two images hold bit-identical samples with the same geometry.
pub(crate) fn assert_pixels_identical(left: &OpImage, right: &OpImage, context: &str) {
    assert_eq!(
        (left.width(), left.height(), left.channels()),
        (right.width(), right.height(), right.channels()),
        "{context}: geometry differs"
    );
    assert_eq!(left.len(), right.len(), "{context}: sample count differs");
    for (index, (a, b)) in left.data().iter().zip(right.data().iter()).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{context}: sample {index} differs ({a} vs {b})"
        );
    }
}

/// Assert two images carry the same astrometry.
pub(crate) fn assert_wcs_identical(left: &OpImage, right: &OpImage, context: &str) {
    for key in [
        "CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD1_2", "CD2_1", "CD2_2",
    ] {
        assert_eq!(
            left.header().get_float(key),
            right.header().get_float(key),
            "{context}: header {key} differs"
        );
    }
}

/// Render `recipe` four ways and assert every result is byte-identical:
/// twice with a cold cache, twice more against a warm one, and once with the
/// cache switched off. Returns the first render's output.
///
/// The warm pair is the cache-hit path and the cold/disabled renders are the
/// cache-miss path; a cache that ever changed pixels fails here.
pub(crate) fn assert_deterministic(
    recipe: &Recipe,
    base: &Arc<OpImage>,
    registry: &OpRegistry,
    ctx: &OpContext,
    opts: RenderOptions,
) -> Result<RenderOutput, RecipeError> {
    let mut cold_a = RenderCache::unbounded();
    let first = render(recipe, base, registry, &mut cold_a, ctx, opts.clone())?;

    let mut cold_b = RenderCache::unbounded();
    let second = render(recipe, base, registry, &mut cold_b, ctx, opts.clone())?;
    assert_pixels_identical(&first.image, &second.image, "repeated cold render");
    assert_wcs_identical(&first.image, &second.image, "repeated cold render");
    assert_eq!(
        first.report.steps, second.report.steps,
        "repeated cold render: step reports differ"
    );

    let warm = render(recipe, base, registry, &mut cold_a, ctx, opts.clone())?;
    assert_pixels_identical(&first.image, &warm.image, "warm cache render");
    assert_wcs_identical(&first.image, &warm.image, "warm cache render");
    assert_eq!(
        first.report.steps, warm.report.steps,
        "warm cache render: step reports differ"
    );

    let warm_again = render(recipe, base, registry, &mut cold_a, ctx, opts.clone())?;
    assert_pixels_identical(&first.image, &warm_again.image, "second warm render");

    let mut off = RenderCache::disabled();
    let uncached = render(recipe, base, registry, &mut off, ctx, opts)?;
    assert_pixels_identical(&first.image, &uncached.image, "cache-disabled render");
    assert_wcs_identical(&first.image, &uncached.image, "cache-disabled render");
    assert_eq!(
        first.report.steps, uncached.report.steps,
        "cache-disabled render: step reports differ"
    );

    Ok(first)
}
