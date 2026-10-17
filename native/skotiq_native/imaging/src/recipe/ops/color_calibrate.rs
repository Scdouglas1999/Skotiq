//! Colour calibration on linear data: a `B − V` colour-versus-flux regression
//! against the shipped photometry, solved from the frame's own astrometry.
//!
//! # What this operation is
//!
//! Aperture photometry measures every matched star's background-subtracted flux
//! in each channel. The catalogue supplies each star's Johnson `B − V`. For each
//! channel the pair `(B − V, log₁₀ flux)` is fitted robustly, and the flux a
//! reference-colour star would read is read off the fitted line; the reciprocal
//! of that flux, normalised so green is exactly `1`, is the channel scale.
//! [`crate::color_calibration::solve_color_calibration`] is the fit.
//!
//! Using the whole star population rather than one white star is what makes the
//! answer robust: a single star may be a blend, mildly saturated, or sitting on
//! a gradient, and the fit tolerates a large fraction of such blunders.
//!
//! # What this operation is not
//!
//! It is not spectrophotometric calibration. The shipped photometry is Johnson
//! `B` and `V` only (HYG `ci`, APASS DR9), there is no Gaia `BP`/`RP` in the
//! tree and no filter-transmission or sensor-QE database, so the colour term is
//! a single `B − V` slope per channel and nothing about the instrument's
//! spectral response is modelled. Neither the code nor the interface claims
//! otherwise.
//!
//! # Channels
//!
//! Three channels only. A one-channel master has no channel balance to solve —
//! the underlying normalisation would return a unit scale and the "calibrated"
//! image would be byte-identical to its input — so a mono master is
//! [`OpError::UnsupportedChannels`] here and is combined to RGB first.
//!
//! # Measuring once, replaying everywhere
//!
//! A step with no `channelScale` measures a balance from the image it is handed.
//! A step that carries one is in *pinned mode*: it applies exactly those scales
//! and reads neither the catalogue nor the astrometry. [`solve`] measures,
//! [`ColorSolve::to_params`] writes the answer into the step, and every later
//! render — full resolution or preview — replays the same numbers. That is what
//! a preview needs: a downsampled level carries fewer measurable stars than the
//! fit requires, so a step that re-measured at every level would fail on the
//! preview of a master it calibrates perfectly well at full resolution.
//!
//! The two modes are the same arithmetic over the same scales, so pinning the
//! scales a render reported reproduces that render's pixels bit for bit. Both
//! are `color_calibrate@1`: an absent `channelScale` renders exactly what it
//! always did, so every recipe already on disk replays unchanged.
//!
//! Every application reports what it applied — the scales, and for a solve the
//! reference colour, the matched-star count and the fit residual — as the step's
//! [`OpApplied::measurement`]. That read-back is how a draft learns the scales
//! to pin without solving the field a second time.
//!
//! # Astrometry
//!
//! The cross-match reads the astrometry out of the image's own header, which
//! `crop@1` and the preview pyramid keep truthful, so the catalogue lands in the
//! pixel frame the photometry was measured in. A master with no plate solve
//! cannot be cross-matched at all and reports [`OpError::Failed`].
//!
//! # Preview scale
//!
//! `matchRadiusPx` is in pixels at full resolution and is multiplied by
//! [`OpContext::scale`]. The aperture and annulus radii are derived from each
//! star's own measured HFR, which is already in render-level pixels, so they
//! need no scaling. `channelScale`, `whiteRefBv`, `magLimit` and `minStars` are
//! in value units.

use rayon::prelude::*;
use serde_json::{json, Value};

use crate::color_calibration::{
    solve_color_calibration, ColorCalError, ColorStar, MIN_MATCHED_STARS,
};
use crate::recipe::ops::star_detect;
use crate::recipe::{
    CatalogError, DarkroomOp, OpApplied, OpContext, OpError, OpImage, OpStage, Params,
};
use crate::robust_stats::median_in_place;
use crate::wcs_sip::SipWcs;
use crate::{DetectedStar, StarDetectionConfig};

/// Registry id.
const OP_ID: &str = "color_calibrate";
/// Registry version.
const OP_VERSION: u32 = 1;

/// The only channel layout this operation defines a result for.
const REQUIRED_CHANNELS: u32 = 3;

/// Bluest reference colour accepted, in `B − V`.
const WHITE_REF_BV_MIN: f64 = -0.5;
/// Reddest reference colour accepted, in `B − V`.
const WHITE_REF_BV_MAX: f64 = 2.5;
/// Reference colour when the parameter is absent: the `B − V` of a G2V star,
/// the conventional daylight-balanced white.
const WHITE_REF_BV_DEFAULT: f64 = 0.65;

/// Brightest magnitude limit accepted for the catalogue query.
const MAG_LIMIT_MIN: f64 = 5.0;
/// Faintest magnitude limit accepted for the catalogue query.
const MAG_LIMIT_MAX: f64 = 22.0;
/// Magnitude limit when the parameter is absent: the depth of the shipped
/// APASS photometry.
const MAG_LIMIT_DEFAULT: f64 = 17.0;

/// Tightest cross-match tolerance, in pixels at full resolution.
const MATCH_RADIUS_MIN: f64 = 0.5;
/// Widest cross-match tolerance, in pixels at full resolution.
const MATCH_RADIUS_MAX: f64 = 32.0;
/// Cross-match tolerance when the parameter is absent, in pixels at full
/// resolution.
const MATCH_RADIUS_DEFAULT: f64 = 3.0;

/// Fewest matched stars the fit accepts, the floor
/// [`solve_color_calibration`] itself enforces.
const MIN_STARS_MIN: u32 = MIN_MATCHED_STARS as u32;
/// Largest matched-star requirement a payload may ask for.
const MIN_STARS_MAX: u32 = 100_000;
/// Matched-star requirement when the parameter is absent.
const MIN_STARS_DEFAULT: u32 = MIN_MATCHED_STARS as u32;

/// Photometric aperture radius as a multiple of a star's measured HFR. HFR is
/// the half-flux radius, so twice it holds roughly 95% of a Gaussian PSF's
/// encircled energy.
const APERTURE_HFR_MULTIPLE: f64 = 2.0;
/// Inner radius of the local-background annulus, as a multiple of HFR: outside
/// the aperture, so the star's own wings do not set its background.
const ANNULUS_INNER_HFR_MULTIPLE: f64 = 3.0;
/// Outer radius of the local-background annulus, as a multiple of HFR.
const ANNULUS_OUTER_HFR_MULTIPLE: f64 = 5.0;
/// Smallest photometric aperture radius, in render-level pixels.
const APERTURE_RADIUS_MIN: f64 = 1.5;
/// Smallest annulus width, in render-level pixels, so a tight star still has a
/// ring to measure its background from.
const ANNULUS_WIDTH_MIN: f64 = 2.0;
/// Fewest annulus samples a background median is taken from.
const MIN_ANNULUS_SAMPLES: usize = 8;

/// Fraction of the frame's half-diagonal added to the catalogue query radius, so
/// a star just outside the corner is still available to match.
const FIELD_RADIUS_MARGIN: f64 = 1.05;

/// Smallest channel scale a payload may carry. A scale of zero would erase a
/// channel, which is not a white balance.
const SCALE_MIN: f64 = 1e-6;
/// Largest channel scale a payload may carry.
const SCALE_MAX: f64 = 1e6;

/// Report token for scales this render fitted from the catalogue.
const SOURCE_SOLVED: &str = "solved";
/// Report token for scales the step carried, applied without a fit.
const SOURCE_PINNED: &str = "pinned";

/// Applies a per-channel white balance solved from catalogue colours.
pub struct ColorCalibrateV1;

/// One step's validated parameters.
struct Settings {
    /// A white balance already carried by the recipe — pinned mode. `None`
    /// means the step measures one from the image it is handed.
    channel_scale: Option<Vec<f64>>,
    /// Colour index rendered neutral by the solved scales.
    white_ref_bv: f64,
    /// Faintest catalogue V magnitude queried.
    mag_limit: f64,
    /// Cross-match tolerance, in pixels at full resolution.
    match_radius_px: f64,
    /// Matched stars the fit is required to have.
    min_stars: u32,
}

/// The white balance one render solved, in the units the interface reports.
#[derive(Debug, Clone, PartialEq)]
pub struct ColorSolve {
    /// Multiplicative scale for each channel, in image channel order. Green is
    /// exactly `1.0`, so the calibration is a relative rebalance and never
    /// changes the overall brightness reference.
    pub channel_scale: Vec<f64>,
    /// Colour index the scales render neutral.
    pub white_ref_bv: f64,
    /// Stars that survived the cross-match and informed the fit.
    pub matched: usize,
    /// Robust RMS of the per-channel fit residuals, in log₁₀-flux units.
    pub residual: f64,
}

impl ColorSolve {
    /// The step parameter object that replays this balance.
    ///
    /// It carries the scales themselves, so a step written from a solve renders
    /// the same pixels at every level and on an install whose catalogue has
    /// since changed.
    pub fn to_params(&self) -> Value {
        json!({
            "channelScale": self.channel_scale,
            "whiteRefBv": self.white_ref_bv,
        })
    }

    /// The render report's detail for a step that solved this balance: the
    /// scales it applied and the evidence behind them.
    ///
    /// `source` names how the scales were arrived at, so a reader never has to
    /// infer it from which fields are present.
    pub fn to_measurement(&self) -> Value {
        json!({
            "source": SOURCE_SOLVED,
            "channelScale": self.channel_scale,
            "whiteRefBv": self.white_ref_bv,
            "matchedStars": self.matched,
            "residual": self.residual,
        })
    }
}

/// The render report's detail for a step in pinned mode.
///
/// It carries no reference colour, no star count and no residual: pinned mode
/// reads none of them, and reporting the payload's `whiteRefBv` here would
/// present a number that took no part in the pixels.
fn pinned_measurement(scales: &[f64]) -> Value {
    json!({
        "source": SOURCE_PINNED,
        "channelScale": scales,
    })
}

impl DarkroomOp for ColorCalibrateV1 {
    fn id(&self) -> &'static str {
        OP_ID
    }

    fn version(&self) -> u32 {
        OP_VERSION
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        self.apply_measured(image, params, ctx)
            .map(|applied| applied.image)
    }

    fn apply_measured(
        &self,
        image: &OpImage,
        params: &Value,
        ctx: &OpContext,
    ) -> Result<OpApplied, OpError> {
        let settings = read_settings(params)?;
        require_three_channels(image)?;
        let (scales, measurement) = match settings.channel_scale {
            Some(scales) => {
                let measurement = pinned_measurement(&scales);
                (scales, measurement)
            }
            None => {
                let solved = solve(image, params, ctx)?;
                let measurement = solved.to_measurement();
                (solved.channel_scale, measurement)
            }
        };
        ctx.check_cancel()?;

        let channels = image.channels() as usize;
        let row_len = image.width() as usize * channels;
        let source = image.data();
        let scales = &scales;
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..y * row_len + row_len];
                for (index, (slot, sample)) in row.iter_mut().zip(source_row.iter()).enumerate() {
                    let scale = scales[index % channels];
                    // A channel the fit left at unit scale keeps its exact
                    // samples; green is pinned to 1.0 by the normalisation.
                    *slot = if scale == 1.0 {
                        *sample
                    } else {
                        (*sample as f64 * scale) as f32
                    };
                }
            });
        ctx.check_cancel()?;

        Ok(OpApplied::measured(image.with_data(out)?, measurement))
    }
}

/// Measure the white balance for `image` without applying it.
///
/// The editor reads the scales, the matched-star count and the fit residual to
/// show what the calibration is doing, and writes [`ColorSolve::to_params`] back
/// into the step so every later render replays the same numbers.
///
/// This is the measurement path and it always measures: a `channelScale` already
/// in the payload is the *result* slot and is never read here.
///
/// # Errors
///
/// * [`OpError::UnsupportedChannels`] unless the image has three channels.
/// * [`OpError::Unavailable`] when no catalogue is attached, when the attached
///   catalogue reports itself unavailable, or when it holds no colour-indexed
///   star for this field. The engine records the step as explicitly skipped and
///   passes the image through.
/// * [`OpError::Failed`] when the master carries no plate solve, when too few
///   stars cross-match, or when the fit is degenerate.
pub fn solve(image: &OpImage, params: &Value, ctx: &OpContext) -> Result<ColorSolve, OpError> {
    let settings = read_settings(params)?;
    require_three_channels(image)?;
    ctx.check_cancel()?;

    let Some(catalog) = ctx.catalog() else {
        return Err(OpError::Unavailable {
            op_id: OP_ID,
            op_version: OP_VERSION,
            reason: "no photometric catalog is installed".to_string(),
        });
    };

    let wcs = image.wcs().ok_or_else(|| {
        failed("the master carries no plate solve, so catalog stars cannot be placed on it")
    })?;
    if !wcs.is_invertible() {
        return Err(failed(
            "the master's plate solve has no inverse, so catalog stars cannot be placed on it",
        ));
    }
    let (centre_ra, centre_dec) = wcs.pixel_to_world(
        (image.width() as f64 - 1.0) * 0.5,
        (image.height() as f64 - 1.0) * 0.5,
    );
    let pixel_scale_deg = wcs.pixel_scale_arcsec() / 3600.0;
    if !pixel_scale_deg.is_finite() || pixel_scale_deg <= 0.0 {
        return Err(failed(
            "the master's plate scale is degenerate, so no catalog field can be queried",
        ));
    }
    let half_diagonal =
        0.5 * ((image.width() as f64).hypot(image.height() as f64)) * pixel_scale_deg;
    let radius_deg = half_diagonal * FIELD_RADIUS_MARGIN;

    let catalog_stars = catalog
        .cone_search(centre_ra, centre_dec, radius_deg, settings.mag_limit)
        .map_err(|error| match error {
            CatalogError::Unavailable { reason } => OpError::Unavailable {
                op_id: OP_ID,
                op_version: OP_VERSION,
                reason,
            },
            CatalogError::QueryFailed { reason } => failed(&reason),
        })?;
    if catalog_stars.is_empty() {
        return Err(OpError::Unavailable {
            op_id: OP_ID,
            op_version: OP_VERSION,
            reason: format!(
                "the installed photometric catalog holds no color-indexed star within {radius_deg:.3} deg of ({centre_ra:.4}, {centre_dec:.4}) to V={}",
                settings.mag_limit
            ),
        });
    }
    ctx.check_cancel()?;

    // Photometry, not masking: the strict detector gates keep blends, hot
    // pixels and trailed sources out of the fit.
    let detected = star_detect::detect(image, &StarDetectionConfig::default(), ctx)?;
    if detected.is_empty() {
        return Err(failed(
            "no star was measured in the master, so no catalog star can be cross-matched",
        ));
    }

    let match_radius = settings.match_radius_px * ctx.scale();
    let matched = cross_match(image, &wcs, &detected, &catalog_stars, match_radius, ctx)?;
    if matched.len() < settings.min_stars as usize {
        return Err(failed(&format!(
            "{} catalog star{} cross-matched within {match_radius:.2} px but the fit needs {}; widen matchRadiusPx or lower minStars",
            matched.len(),
            if matched.len() == 1 { "" } else { "s" },
            settings.min_stars
        )));
    }
    ctx.check_cancel()?;

    let calibration = solve_color_calibration(
        &matched,
        REQUIRED_CHANNELS as usize,
        settings.white_ref_bv,
    )
    .map_err(|error| match error {
        ColorCalError::TooFewStars => failed(&format!(
            "{} cross-matched star{} {} below the {MIN_MATCHED_STARS} the color fit needs",
            matched.len(),
            if matched.len() == 1 { "" } else { "s" },
            if matched.len() == 1 { "is" } else { "are" }
        )),
        ColorCalError::ChannelMismatch { expected, actual } => failed(&format!(
            "the photometry produced {actual} channel flux value{} for a {expected}-channel master",
            if actual == 1 { "" } else { "s" }
        )),
        ColorCalError::DegenerateFit { channel } => failed(&format!(
            "channel {channel} has too few positive-flux stars or no color spread to fit; widen magLimit or matchRadiusPx"
        )),
    })?;

    Ok(ColorSolve {
        channel_scale: calibration.channel_scale,
        white_ref_bv: calibration.white_ref_bv,
        matched: calibration.matched,
        residual: calibration.residual,
    })
}

/// Read and range-check one step's payload. `validate_params`, `apply` and
/// [`solve`] share this, so none of them can disagree about a default.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&ColorCalibrateV1, params)?;
    p.allow(&[
        "channelScale",
        "whiteRefBv",
        "magLimit",
        "matchRadiusPx",
        "minStars",
    ])?;
    let channel_scale = if p.has("channelScale") {
        Some(p.f64_array_or(
            "channelScale",
            REQUIRED_CHANNELS as usize,
            SCALE_MIN..=SCALE_MAX,
            &[],
        )?)
    } else {
        None
    };
    Ok(Settings {
        channel_scale,
        white_ref_bv: p.f64_or(
            "whiteRefBv",
            WHITE_REF_BV_MIN..=WHITE_REF_BV_MAX,
            WHITE_REF_BV_DEFAULT,
        )?,
        mag_limit: p.f64_or("magLimit", MAG_LIMIT_MIN..=MAG_LIMIT_MAX, MAG_LIMIT_DEFAULT)?,
        match_radius_px: p.f64_or(
            "matchRadiusPx",
            MATCH_RADIUS_MIN..=MATCH_RADIUS_MAX,
            MATCH_RADIUS_DEFAULT,
        )?,
        min_stars: p.u32_or("minStars", MIN_STARS_MIN..=MIN_STARS_MAX, MIN_STARS_DEFAULT)?,
    })
}

/// The channel-count gate both entry points share.
fn require_three_channels(image: &OpImage) -> Result<(), OpError> {
    let channels = image.channels();
    if channels != REQUIRED_CHANNELS {
        return Err(OpError::UnsupportedChannels {
            op_id: OP_ID,
            op_version: OP_VERSION,
            channels,
            expected: "a colour master with 3 channels; combine a per-filter mono master first",
        });
    }
    Ok(())
}

/// A failure attributed to this operation.
fn failed(reason: &str) -> OpError {
    OpError::Failed {
        op_id: OP_ID,
        op_version: OP_VERSION,
        reason: reason.to_string(),
    }
}

/// Pair catalogue stars with detected stars and measure each pair's per-channel
/// flux.
///
/// Catalogue stars are walked in the order the catalogue returned them, which
/// its own contract fixes; each takes the nearest detected star inside
/// `match_radius` that no earlier catalogue star has taken, ties resolving to
/// the lower detection index. The match is therefore one-to-one and independent
/// of how the work is scheduled. A detection whose photometry cannot be
/// measured — it reaches the frame edge, its annulus is too small, or a sample
/// in its window is not finite — is consumed by the match and left out of the
/// fit rather than measured against a different catalogue row.
fn cross_match(
    image: &OpImage,
    wcs: &SipWcs,
    detected: &[DetectedStar],
    catalog: &[crate::recipe::CatalogStar],
    match_radius: f64,
    ctx: &OpContext,
) -> Result<Vec<ColorStar>, OpError> {
    let radius_sq = match_radius * match_radius;
    let mut claimed = vec![false; detected.len()];
    let mut matched = Vec::new();
    for (index, entry) in catalog.iter().enumerate() {
        if index % 1024 == 0 {
            ctx.check_cancel()?;
        }
        if !entry.b_minus_v.is_finite() {
            continue;
        }
        let Some((px, py)) = wcs.world_to_pixel(entry.ra_deg, entry.dec_deg) else {
            continue;
        };
        let mut best: Option<(usize, f64)> = None;
        for (candidate, star) in detected.iter().enumerate() {
            if claimed[candidate] {
                continue;
            }
            let dx = star.x - px;
            let dy = star.y - py;
            let distance_sq = dx * dx + dy * dy;
            if distance_sq > radius_sq {
                continue;
            }
            if best.is_none_or(|(_, closest)| distance_sq < closest) {
                best = Some((candidate, distance_sq));
            }
        }
        let Some((candidate, _)) = best else {
            continue;
        };
        claimed[candidate] = true;
        if let Some(channel_flux) = aperture_flux(image, &detected[candidate]) {
            matched.push(ColorStar {
                channel_flux,
                catalog_bv: entry.b_minus_v,
            });
        }
    }
    Ok(matched)
}

/// Background-subtracted flux of one star in every channel, or `None` when the
/// star cannot be measured.
///
/// The background is the median of the annulus in that channel, so a gradient
/// under the star is removed without assuming the frame has one level. Sums run
/// in row-major order and accumulate in `f64`, so the answer does not depend on
/// the thread count.
fn aperture_flux(image: &OpImage, star: &DetectedStar) -> Option<Vec<f64>> {
    if !star.x.is_finite() || !star.y.is_finite() || !star.hfr.is_finite() || star.hfr <= 0.0 {
        return None;
    }
    let aperture = (APERTURE_HFR_MULTIPLE * star.hfr).max(APERTURE_RADIUS_MIN);
    let inner = (ANNULUS_INNER_HFR_MULTIPLE * star.hfr).max(aperture + 1.0);
    let outer = (ANNULUS_OUTER_HFR_MULTIPLE * star.hfr).max(inner + ANNULUS_WIDTH_MIN);

    let width = image.width() as i64;
    let height = image.height() as i64;
    let channels = image.channels() as usize;
    let window = outer.ceil() as i64;
    let cx = star.x;
    let cy = star.y;
    let x0 = (cx.round() as i64) - window;
    let x1 = (cx.round() as i64) + window;
    let y0 = (cy.round() as i64) - window;
    let y1 = (cy.round() as i64) + window;
    if x0 < 0 || y0 < 0 || x1 >= width || y1 >= height {
        return None;
    }

    let data = image.data();
    let aperture_sq = aperture * aperture;
    let inner_sq = inner * inner;
    let outer_sq = outer * outer;

    let mut annulus: Vec<Vec<f64>> = vec![Vec::new(); channels];
    let mut sum = vec![0.0_f64; channels];
    let mut aperture_pixels = 0.0_f64;
    for y in y0..=y1 {
        let dy = y as f64 - cy;
        for x in x0..=x1 {
            let dx = x as f64 - cx;
            let distance_sq = dx * dx + dy * dy;
            let in_aperture = distance_sq <= aperture_sq;
            let in_annulus = distance_sq >= inner_sq && distance_sq <= outer_sq;
            if !in_aperture && !in_annulus {
                continue;
            }
            let base = ((y * width + x) as usize) * channels;
            for channel in 0..channels {
                let value = data[base + channel] as f64;
                if !value.is_finite() {
                    return None;
                }
                if in_aperture {
                    sum[channel] += value;
                } else {
                    annulus[channel].push(value);
                }
            }
            if in_aperture {
                aperture_pixels += 1.0;
            }
        }
    }

    if aperture_pixels <= 0.0 || annulus[0].len() < MIN_ANNULUS_SAMPLES {
        return None;
    }
    let mut flux = Vec::with_capacity(channels);
    for channel in 0..channels {
        let background = median_in_place(&mut annulus[channel]);
        flux.push(sum[channel] - background * aperture_pixels);
    }
    Some(flux)
}

#[cfg(test)]
#[path = "color_calibrate_tests.rs"]
mod color_calibrate_tests;
