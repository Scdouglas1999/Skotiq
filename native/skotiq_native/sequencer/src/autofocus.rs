//! Autofocus Engine with V-Curve Algorithm
//!
//! Provides production-ready autofocus implementation with:
//! - V-curve, parabolic, and hyperbolic curve fitting
//! - Backlash compensation
//! - Temperature-based focus prediction integration
//! - Robust error handling and outlier rejection
//!
//! # `unwrap_or` policy
//!
//! All `unwrap_or` sites here are one of:
//! - `partial_cmp(...).unwrap_or(Ordering::Equal)` — `f64` is `PartialOrd`,
//!   so NaN samples cluster as `Equal` in sort-by; the outlier-rejection
//!   stage filters them.
//! - `min_by(...).unwrap_or(intersection)` — `intersection` is the linear-
//!   regression projection; if no data points exist on a branch the linear
//!   projection is the correct extrapolation target.
//! - `min_by(...).unwrap_or(Ordering::Equal)` — partial_cmp idiom inside
//!   selection. Same f64-NaN rationale.

use serde::{Deserialize, Serialize};

/// Result of an autofocus run
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutofocusResult {
    pub best_position: i32,
    pub best_hfr: f64,
    pub curve_fit_quality: f64, // R-squared or similar metric
    pub method_used: AutofocusMethod,
    pub data_points: Vec<FocusDataPoint>,
    pub temperature_celsius: Option<f64>,
    pub backlash_applied: bool,
}

/// A single data point in the autofocus curve
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocusDataPoint {
    pub position: i32,
    pub hfr: f64,
    pub fwhm: Option<f64>,
    pub star_count: u32,
}

/// Fewest points a narrowed refit may use. Three points always fit a
/// parabola exactly (R²=1.0), which would make the narrowing rule pick
/// noise over data.
const NARROW_FIT_MIN_POINTS: usize = 5;

/// How much better a narrowed fit must be before it displaces the full-sweep
/// fit. Small enough to catch a wing that has stopped describing the curve,
/// large enough that ordinary fit-quality jitter does not reshape the sweep.
const NARROW_FIT_R2_MARGIN: f64 = 0.05;

struct NarrowedFit {
    position: i32,
    quality: f64,
    span: (i32, i32),
    points_used: usize,
}

/// Autofocus method selection
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum AutofocusMethod {
    /// V-curve with bisection search
    VCurve,
    /// Parabolic (quadratic) curve fitting
    Quadratic,
    /// Hyperbolic curve fitting
    Hyperbolic,
}

/// Configuration for autofocus run
#[derive(Debug, Clone)]
pub struct AutofocusConfig {
    pub method: AutofocusMethod,
    pub step_size: i32,
    pub steps_out: u32,
    pub exposure_duration: f64,
    pub backlash_compensation: i32,
    pub backlash_out_compensation: i32,
    pub use_temperature_prediction: bool,
    pub max_star_count_change: Option<f64>, // Reject points with >X% star count change
    pub outlier_rejection_sigma: f64,       // Sigma for outlier rejection (0 = disabled)
    /// Maximum duration in seconds before the autofocus run is aborted.
    /// Default 600s (10 minutes).
    pub max_duration_secs: f64,
}

impl Default for AutofocusConfig {
    fn default() -> Self {
        Self {
            method: AutofocusMethod::VCurve,
            step_size: 100,
            steps_out: 7,
            exposure_duration: 3.0,
            backlash_compensation: 0,
            backlash_out_compensation: 0,
            use_temperature_prediction: true,
            max_star_count_change: Some(0.5), // 50% change threshold
            outlier_rejection_sigma: 3.0,
            max_duration_secs: 600.0,
        }
    }
}

/// V-Curve Autofocus Engine
///
/// Algorithm:
/// 1. Start at initial position (optionally predicted from temperature model)
/// 2. Move outward by steps_out * step_size
/// 3. Move inward, taking exposures at each step
/// 4. Calculate HFR at each position
/// 5. Fit curve to data points (parabola, hyperbola, or V-curve)
/// 6. Find minimum of fitted curve
/// 7. Move to optimal position with backlash compensation
pub struct VCurveAutofocus {
    config: AutofocusConfig,
}

impl VCurveAutofocus {
    pub fn new(config: AutofocusConfig) -> Self {
        Self { config }
    }

    /// Calculate the focus sweep positions
    pub fn calculate_positions(&self, starting_position: i32) -> Vec<i32> {
        // Why: steps_out is a u32 user-config value but operationally bounded
        // (UI ranges 1..50). saturating to i32::MAX would silently produce
        // garbage sweep positions; saturating_mul on step_size then surfaces
        // as truncated half_range. We use checked_mul/checked_sub and clamp
        // explicitly so a misconfigured steps_out caps at i32::MAX instead
        // of wrapping a negative position.
        let steps_out_i32 = i32::try_from(self.config.steps_out).unwrap_or(i32::MAX);
        let half_range = steps_out_i32.saturating_mul(self.config.step_size);
        let start_pos = starting_position.saturating_sub(half_range);
        // Why: steps_out*2+1 with steps_out <= UI-bound (~50) is <= 101, well
        // within usize on all targets.
        let total_points =
            usize::try_from(self.config.steps_out.saturating_mul(2).saturating_add(1))
                .unwrap_or(usize::MAX);

        (0..total_points)
            .map(|i| {
                // Why: i is bounded by total_points (saturated above); i32 step
                // is safe via try_from to surface bizarre configs as the last
                // valid position rather than a wrap.
                let i_i32 = i32::try_from(i).unwrap_or(i32::MAX);
                start_pos.saturating_add(i_i32.saturating_mul(self.config.step_size))
            })
            .collect()
    }

    /// Process collected data points and find best focus position
    pub fn find_best_focus(
        &self,
        data_points: Vec<FocusDataPoint>,
    ) -> Result<AutofocusResult, String> {
        if data_points.len() < 3 {
            return Err("Not enough data points for curve fitting".to_string());
        }

        // Outlier rejection on the raw HFR samples before fitting protects
        // the curve fit from single bad frames (seeing spike, satellite
        // streak, cosmic ray) that would otherwise distort the V's minimum.
        // sigma=0 means "trust every point" — used by tests with synthetic
        // perfect curves.
        //
        // Fail-soft: when rejection eliminates too many points (poor seeing
        // can legitimately flag half the sweep), fitting the raw samples is
        // a far better night outcome than aborting AF — an abort leaves the
        // focuser wherever the sweep ended, which is maximally defocused.
        let filtered_points = if self.config.outlier_rejection_sigma > 0.0 {
            match self.reject_outliers(&data_points) {
                Ok(points) => points,
                Err(e) => {
                    tracing::warn!(
                        "Outlier rejection failed ({}); fitting raw sweep data instead",
                        e
                    );
                    data_points.clone()
                }
            }
        } else {
            data_points.clone()
        };

        if filtered_points.len() < 3 {
            return Err("Not enough valid data points after outlier rejection".to_string());
        }

        // Fail-soft on the curve fit too: a parabola opening the wrong way
        // (a <= 0) or a degenerate hyperbola means the model is wrong for
        // tonight's data, not that the sweep was useless. Falling back to
        // the minimum-HFR *sampled* position with quality 0.0 mirrors
        // N.I.N.A.'s behaviour; downstream only warns on low R² and the
        // verification exposure remains the backstop.
        let fit_result = self.fit_with_method(&filtered_points);
        let (best_position, curve_quality) = match fit_result {
            Ok(fit) => fit,
            Err(e) => {
                let min_point = filtered_points
                    .iter()
                    .min_by(|a, b| {
                        a.hfr
                            .partial_cmp(&b.hfr) /* f64 NaN orders Equal — see module-level policy */
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .ok_or_else(|| "No valid HFR values found".to_string())?;
                tracing::warn!(
                    "{:?} curve fit failed ({}); falling back to minimum-HFR sampled position {} (R²=0.0)",
                    self.config.method,
                    e,
                    min_point.position
                );
                (min_point.position, 0.0)
            }
        };

        // Both fitted models are SYMMETRIC about the focus position, and a
        // sweep's outer points stop obeying that symmetry once the stars are
        // too defocused to measure: the HFR that comes back is the median of
        // whichever few tight stars survived the validity window, so the wing
        // flattens — or reverses, which no real defocus curve does. A
        // symmetric model fitted through such a wing splits the difference
        // and lands the vertex off toward the flatter side.
        //
        // So: if a symmetric window around the best sample describes the
        // curve materially better than the whole sweep, the wings were not
        // describing the same curve and the narrower fit is the honest one.
        // Widest qualifying window wins, and nothing changes when the full
        // sweep already fits well — which is the common case.
        let (best_position, curve_quality) =
            match self.refit_near_focus(&filtered_points, curve_quality) {
                Some(narrowed) => {
                    tracing::info!(
                        "Curve fit over the full sweep was R²={:.3}; the {} points from {} to {} \
                         fit R²={:.3}, so the outer samples are not on the same curve. \
                         Using the narrower fit: {} (was {})",
                        curve_quality,
                        narrowed.points_used,
                        narrowed.span.0,
                        narrowed.span.1,
                        narrowed.quality,
                        narrowed.position,
                        best_position
                    );
                    (narrowed.position, narrowed.quality)
                }
                None => (best_position, curve_quality),
            };

        // The reported best_hfr is the minimum sampled HFR, not the
        // curve's analytic minimum: the user sees a number that actually
        // came from a real exposure, which they can verify visually.
        let best_hfr = filtered_points
            .iter()
            .map(|p| p.hfr)
            .min_by(|a, b| {
                a.partial_cmp(b) /* f64 NaN orders Equal — see module-level policy */
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .ok_or_else(|| "No valid HFR values found".to_string())?;

        Ok(AutofocusResult {
            best_position,
            best_hfr,
            curve_fit_quality: curve_quality,
            method_used: self.config.method,
            data_points: filtered_points,
            temperature_celsius: None, // Set by caller
            backlash_applied: self.config.backlash_compensation > 0
                || self.config.backlash_out_compensation > 0,
        })
    }

    fn fit_with_method(&self, points: &[FocusDataPoint]) -> Result<(i32, f64), String> {
        match self.config.method {
            AutofocusMethod::VCurve => self.fit_vcurve(points),
            AutofocusMethod::Quadratic => self.fit_parabola(points),
            AutofocusMethod::Hyperbolic => self.fit_hyperbola(points),
        }
    }

    /// Refit on the widest symmetric window around the best sample that beats
    /// the full-sweep fit by [`NARROW_FIT_R2_MARGIN`]. `None` keeps the full
    /// fit, which is what happens whenever the sweep is well behaved.
    fn refit_near_focus(
        &self,
        points: &[FocusDataPoint],
        full_quality: f64,
    ) -> Option<NarrowedFit> {
        let mut sorted = points.to_vec();
        sorted.sort_by_key(|p| p.position);

        let min_idx = sorted
            .iter()
            .enumerate()
            .min_by(|a, b| {
                a.1.hfr
                    .partial_cmp(&b.1.hfr) /* f64 NaN orders Equal — see module-level policy */
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .map(|(i, _)| i)?;

        // A window is only symmetric if the minimum has that many samples on
        // BOTH sides; a minimum sitting at the edge of the sweep gives none.
        let max_reach = min_idx.min(sorted.len().saturating_sub(1) - min_idx);

        // Best-fitting window, not merely the first that clears the margin:
        // on a sweep with a bad wing the ±3 window can beat the full sweep
        // and still be dragged by the same wing the ±2 window excludes.
        // Widest wins ties, so equal quality keeps the most data.
        let mut best: Option<NarrowedFit> = None;
        for half in (2..=max_reach).rev() {
            let window = &sorted[min_idx - half..=min_idx + half];
            if window.len() < NARROW_FIT_MIN_POINTS || window.len() == sorted.len() {
                continue;
            }

            let Ok((position, quality)) = self.fit_with_method(window) else {
                continue;
            };

            let span = (window[0].position, window[window.len() - 1].position);
            // A vertex outside the window it was fitted from is an
            // extrapolation, not a better answer.
            if !(span.0..=span.1).contains(&position) {
                continue;
            }

            if best.as_ref().is_none_or(|b| quality > b.quality) {
                best = Some(NarrowedFit {
                    position,
                    quality,
                    span,
                    points_used: window.len(),
                });
            }
        }

        best.filter(|b| b.quality >= full_quality + NARROW_FIT_R2_MARGIN)
    }

    /// Reject outliers using sigma clipping on HFR values
    fn reject_outliers(&self, points: &[FocusDataPoint]) -> Result<Vec<FocusDataPoint>, String> {
        if points.len() < 3 {
            return Ok(points.to_vec());
        }

        // MAD (median absolute deviation) is the robust estimator of choice
        // for outlier rejection — unlike mean+stdev, it does not get
        // inflated by the very outliers we are trying to detect.
        let mut hfrs: Vec<f64> = points.iter().map(|p| p.hfr).collect();
        hfrs.sort_by(|a, b| {
            a.partial_cmp(b) /* f64 NaN orders Equal — see module-level policy */
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let median = hfrs[hfrs.len() / 2];

        let mut deviations: Vec<f64> = hfrs.iter().map(|&h| (h - median).abs()).collect();
        deviations.sort_by(|a, b| {
            a.partial_cmp(b) /* f64 NaN orders Equal — see module-level policy */
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let mad = deviations[deviations.len() / 2];

        // 1.4826 is the consistency constant that scales MAD to match the
        // standard deviation of a Gaussian distribution — so a "3-sigma"
        // threshold here behaves like a 3-sigma threshold on stdev.
        let sigma = mad * 1.4826;
        let threshold = self.config.outlier_rejection_sigma * sigma;

        // One-sided, and this is the whole point: in a focus sweep the median
        // is a WING value, because most positions are away from focus. Clipping
        // symmetrically therefore treats the focus region as the outlier and
        // deletes the very minimum the sweep exists to find — and the cleaner
        // the sweep, the smaller the MAD and the more certain that deletion.
        // Seen on the rig: a nine-point sweep bottoming at 4.30 px had its
        // three best points cut, leaving only wings, and autofocus reported
        // success with a "best HFR" of 11.01 px.
        //
        // A frame can read spuriously HIGH for reasons that have nothing to do
        // with focus (cloud crossing, satellite trail, a lost guide star), and
        // those are worth rejecting. Nothing makes a frame read spuriously LOW
        // except being closer to focus.
        let filtered: Vec<FocusDataPoint> = points
            .iter()
            .filter(|p| p.hfr <= median || p.hfr - median <= threshold)
            .cloned()
            .collect();

        if filtered.len() < 3 {
            return Err("Too many outliers detected, autofocus failed".to_string());
        }

        Ok(filtered)
    }

    /// Fit a simple V-curve (piecewise linear) and find minimum
    fn fit_vcurve(&self, points: &[FocusDataPoint]) -> Result<(i32, f64), String> {
        if points.len() < 3 {
            return Err("Need at least 3 points for V-curve fit".to_string());
        }

        let mut sorted = points.to_vec();
        sorted.sort_by_key(|point| point.position);

        let mut best_fit: Option<(f64, f64)> = None;

        for split in 1..sorted.len() - 1 {
            let left = &sorted[..=split];
            let right = &sorted[split..];
            if left.len() < 2 || right.len() < 2 {
                continue;
            }

            let Some((left_m, left_b)) = fit_line(left) else {
                continue;
            };
            let Some((right_m, right_b)) = fit_line(right) else {
                continue;
            };

            if left_m >= 0.0 || right_m <= 0.0 || (left_m - right_m).abs() < 1e-10 {
                continue;
            }

            let intersection = (right_b - left_b) / (left_m - right_m);
            let min_position = sorted
                .first()
                // Why: i32 -> f64 is lossless (positions fit in 53-bit mantissa).
                .map(|p| p.position as f64)
                // Why: empty branch → use the linear-regression intersection as the
                // extrapolation target. See module-level policy.
                .unwrap_or(intersection);
            let max_position = sorted
                .last()
                // Why: i32 -> f64 is lossless (positions fit in 53-bit mantissa).
                .map(|p| p.position as f64)
                // Why: empty branch → use the linear-regression intersection as the
                // extrapolation target. See module-level policy.
                .unwrap_or(intersection);
            if !(min_position..=max_position).contains(&intersection) {
                continue;
            }

            // Why: sorted.len() is usize bounded by `sweep points` (<= a few dozen
            // in any plausible focus run); lossless to f64.
            let mean_hfr: f64 = sorted.iter().map(|p| p.hfr).sum::<f64>() / sorted.len() as f64;
            let mut ss_tot = 0.0;
            let mut ss_res = 0.0;

            for point in &sorted {
                // Why: point.position is i32 focuser position; lossless to f64
                // (i32 fits trivially in f64's 53-bit mantissa).
                let x = point.position as f64;
                let predicted = if x <= intersection {
                    left_m * x + left_b
                } else {
                    right_m * x + right_b
                };
                ss_tot += (point.hfr - mean_hfr).powi(2);
                ss_res += (point.hfr - predicted).powi(2);
            }

            let r_squared = if ss_tot > 0.0 {
                (1.0 - (ss_res / ss_tot)).max(0.0)
            } else {
                0.0
            };

            match best_fit {
                Some((_, best_r2)) if r_squared <= best_r2 => {}
                _ => best_fit = Some((intersection, r_squared)),
            }
        }

        if let Some((intersection, r_squared)) = best_fit {
            // Why: intersection is bounded by [min_position, max_position] (checked
            // at line 263 above). Focuser positions are i32; rounded back is
            // in-range. f64 -> i32 saturates per Rust 1.45 spec.
            return Ok((intersection.round() as i32, r_squared));
        }

        let min_point = sorted
            .iter()
            .min_by(|a, b| {
                a.hfr
                    .partial_cmp(&b.hfr)
                    /* f64 NaN orders Equal — see module-level policy */
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .ok_or("No minimum found")?;
        Ok((min_point.position, 0.0))
    }

    /// Fit a parabola (quadratic) to focus data
    /// Returns (best_position, r_squared)
    fn fit_parabola(&self, points: &[FocusDataPoint]) -> Result<(i32, f64), String> {
        if points.len() < 3 {
            return Err("Need at least 3 points for parabolic fit".to_string());
        }

        // Least-squares parabolic fit via the normal equations
        // (Σx⁰, Σx¹, …, Σx⁴ accumulated below). Closed-form is preferred
        // over iterative LSQ for this small problem: it is single-pass,
        // deterministic, and bounded in cost regardless of point count.
        // Why: points.len() is usize bounded by sweep size (<= a few dozen); lossless to f64.
        let n = points.len() as f64;
        let mut sum_x = 0.0;
        let mut sum_y = 0.0;
        let mut sum_x2 = 0.0;
        let mut sum_x3 = 0.0;
        let mut sum_x4 = 0.0;
        let mut sum_xy = 0.0;
        let mut sum_x2y = 0.0;

        for point in points {
            // Why: i32 focuser position -> f64 lossless.
            let x = point.position as f64;
            let y = point.hfr;
            sum_x += x;
            sum_y += y;
            sum_x2 += x * x;
            sum_x3 += x * x * x;
            sum_x4 += x * x * x * x;
            sum_xy += x * y;
            sum_x2y += x * x * y;
        }

        // Cramer's rule rather than a generic 3x3 inverse: for a fixed
        // 3-coefficient system it is the cleanest closed-form expression
        // and avoids pulling in a linear-algebra dependency.
        let det = n * (sum_x2 * sum_x4 - sum_x3 * sum_x3)
            - sum_x * (sum_x * sum_x4 - sum_x2 * sum_x3)
            + sum_x2 * (sum_x * sum_x3 - sum_x2 * sum_x2);

        if det.abs() < 1e-10 {
            return Err("Singular matrix in parabolic fit".to_string());
        }

        let det_a = sum_y * (sum_x2 * sum_x4 - sum_x3 * sum_x3)
            - sum_x * (sum_xy * sum_x4 - sum_x2y * sum_x3)
            + sum_x2 * (sum_xy * sum_x3 - sum_x2y * sum_x2);

        let det_b = n * (sum_xy * sum_x4 - sum_x2y * sum_x3)
            - sum_y * (sum_x * sum_x4 - sum_x2 * sum_x3)
            + sum_x2 * (sum_x * sum_x2y - sum_xy * sum_x2);

        let det_c = n * (sum_x2 * sum_x2y - sum_x3 * sum_xy)
            - sum_x * (sum_x * sum_x2y - sum_x2 * sum_xy)
            + sum_y * (sum_x * sum_x3 - sum_x2 * sum_x2);

        let a = det_c / det; // Coefficient of x^2
        let b = det_b / det; // Coefficient of x
        let c = det_a / det; // Constant

        // A negative or zero `a` means the parabola opens downward or is
        // degenerate — no minimum exists. Treating the resulting vertex
        // as "best focus" would send the focuser to a maximum HFR
        // position, which is the worst possible outcome.
        if a <= 0.0 {
            return Err("Parabola does not have a minimum (a <= 0)".to_string());
        }

        // Standard vertex formula for ax² + bx + c: x = -b / (2a).
        // Why: parabola fit only runs over sweep points whose i32 positions fit in
        // f64; vertex falls within (or near) that range. f64 -> i32 saturates per
        // Rust 1.45 spec, so a degenerate fit caps at i32::MIN/MAX rather than UB.
        let best_position = (-b / (2.0 * a)).round() as i32;

        let mean_y = sum_y / n;
        let mut ss_tot = 0.0;
        let mut ss_res = 0.0;

        for point in points {
            // Why: i32 focuser position -> f64 lossless.
            let x = point.position as f64;
            let predicted = a * x * x + b * x + c;
            ss_tot += (point.hfr - mean_y).powi(2);
            ss_res += (point.hfr - predicted).powi(2);
        }

        let r_squared = if ss_tot > 0.0 {
            1.0 - (ss_res / ss_tot)
        } else {
            0.0
        };

        Ok((best_position, r_squared.max(0.0)))
    }

    /// Fit a hyperbola to focus data
    /// Uses form: HFR = sqrt((x - x0)^2 * a^2 + b^2)
    /// Returns (best_position, r_squared)
    fn fit_hyperbola(&self, points: &[FocusDataPoint]) -> Result<(i32, f64), String> {
        if points.len() < 3 {
            return Err("Need at least 3 points for hyperbolic fit".to_string());
        }

        // Hyperbolic fit has no closed-form least-squares solution, so we
        // bootstrap from the parabolic fit (which is in the right
        // neighbourhood for any plausible focus curve) and refine
        // iteratively. Iteration count is bounded (10) so a non-converging
        // case cannot stall the sequence.
        let (initial_x0, _) = self.fit_parabola(points)?;
        // Why: i32 -> f64 lossless.
        let mut x0 = f64::from(initial_x0);

        let min_hfr = points
            .iter()
            .map(|p| p.hfr)
            .min_by(|a, b| {
                a.partial_cmp(b) /* f64 NaN orders Equal — see module-level policy */
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .ok_or_else(|| "No valid HFR values found for hyperbolic fit".to_string())?;
        let b = min_hfr;
        let mut prev_mean_residual: Option<f64> = None;

        for _iteration in 0..10 {
            let mut sum_num = 0.0;
            let mut sum_den = 0.0;

            for point in points {
                // Why: i32 focuser position -> f64 lossless.
                let x = point.position as f64;
                let dx = x - x0;
                let y = point.hfr;

                if y * y > b * b {
                    let term = (y * y - b * b).sqrt();
                    if term.abs() > 1e-10 {
                        // The model is `sqrt(y² - b²) = |dx| · a`, so the
                        // least-squares slope must regress `term` on |dx|.
                        // Pairing a SIGNED dx with an unsigned term made the
                        // numerator an odd function of dx, so a roughly
                        // symmetric sweep cancelled it to ~0 and `a` collapsed —
                        // see the R² site below for what that did downstream.
                        sum_num += dx.abs() * term;
                        sum_den += dx * dx;
                    }
                }
            }

            if sum_den > 1e-10 {
                let a = sum_num / sum_den;

                // Update x0 and b
                let mut new_x0_sum = 0.0;
                let mut residual_sum = 0.0;
                let mut count = 0.0;

                for point in points {
                    // Why: i32 focuser position -> f64 lossless.
                    let x = point.position as f64;
                    let y = point.hfr;
                    let dx = x - x0;

                    if a.abs() > 1e-10 {
                        let predicted_dx_sq = (y * y - b * b) / (a * a);
                        if predicted_dx_sq >= 0.0 {
                            let predicted_dx = predicted_dx_sq.sqrt();
                            new_x0_sum += x - predicted_dx * dx.signum();
                            count += 1.0;
                        }
                    }

                    let predicted_y = ((dx * a).powi(2) + b * b).sqrt();
                    residual_sum += (y - predicted_y).abs();
                }

                if count > 0.0 {
                    let new_x0 = new_x0_sum / count;
                    // Under-relaxation (0.3 step) prevents the iteration
                    // from oscillating between two near-equal candidates;
                    // we trade slower convergence for stability.
                    x0 = 0.7 * x0 + 0.3 * new_x0;

                    // Stop iterating when residual improvement is negligible.
                    let mean_residual = residual_sum / count;
                    if let Some(prev) = prev_mean_residual {
                        if (prev - mean_residual).abs() < 1e-4 {
                            break;
                        }
                    }
                    prev_mean_residual = Some(mean_residual);
                }
            }
        }

        // Calculate R-squared for final fit
        // Why: points.len() is usize bounded by sweep size (<= a few dozen); lossless to f64.
        let mean_y: f64 = points.iter().map(|p| p.hfr).sum::<f64>() / points.len() as f64;
        let mut ss_tot = 0.0;
        let mut ss_res = 0.0;

        // Recalculate 'a' for final fit
        let mut sum_num = 0.0;
        let mut sum_den = 0.0;
        for point in points {
            // Why: i32 focuser position -> f64 lossless.
            let x = point.position as f64;
            let dx = x - x0;
            let y = point.hfr;
            if y * y > b * b {
                let term = (y * y - b * b).sqrt();
                // Same magnitude-vs-magnitude fit as the iterative estimate
                // above. A signed-dx numerator drives `a` to ~0 on any
                // near-symmetric sweep, so `predicted` flattens to the constant
                // `b`, ss_res exceeds ss_tot, and R² clamps to exactly 0.000 —
                // every Hyperbolic autofocus then fails its own gate ("curve
                // fit R² 0.000 is below the configured threshold 0.700"), no
                // matter how clean the data. Measured on a real simulator
                // sweep: 41 stars per point, HFR 4.09 → 2.35 → 3.02, variance
                // 1.75.
                sum_num += dx.abs() * term;
                sum_den += dx * dx;
            }
        }
        let a = if sum_den > 1e-10 {
            sum_num / sum_den
        } else {
            1.0
        };

        for point in points {
            // Why: i32 focuser position -> f64 lossless.
            let x = point.position as f64;
            let dx = x - x0;
            let predicted = ((dx * a).powi(2) + b * b).sqrt();
            ss_tot += (point.hfr - mean_y).powi(2);
            ss_res += (point.hfr - predicted).powi(2);
        }

        let r_squared = if ss_tot > 0.0 {
            (1.0 - (ss_res / ss_tot)).max(0.0)
        } else {
            0.0
        };

        // Why: x0 is constrained by the iterative fit over i32 focuser positions
        // (lossless to f64); f64 -> i32 saturates per Rust 1.45 spec.
        Ok((x0.round() as i32, r_squared))
    }
}

fn fit_line(points: &[FocusDataPoint]) -> Option<(f64, f64)> {
    if points.len() < 2 {
        return None;
    }

    // Why: points.len() is usize bounded by sweep size; lossless to f64.
    // Why: point.position is i32; lossless to f64.
    let n = points.len() as f64;
    let sum_x: f64 = points.iter().map(|point| point.position as f64).sum();
    let sum_y: f64 = points.iter().map(|point| point.hfr).sum();
    let sum_xy: f64 = points
        .iter()
        .map(|point| point.position as f64 * point.hfr)
        .sum();
    let sum_x2: f64 = points
        .iter()
        .map(|point| (point.position as f64).powi(2))
        .sum();

    let denom = n * sum_x2 - sum_x.powi(2);
    if denom.abs() < 1e-10 {
        return None;
    }

    let slope = (n * sum_xy - sum_x * sum_y) / denom;
    let intercept = (sum_y - slope * sum_x) / n;
    Some((slope, intercept))
}

/// Backlash compensation helper
///
/// When moving to a target position, if we're moving inward (decreasing position),
/// we overshoot by the backlash amount then move back to ensure consistent approach direction.
#[derive(Debug, Clone)]
pub struct BacklashCompensation {
    pub backlash_in_steps: i32,
    pub backlash_out_steps: i32,
}

impl BacklashCompensation {
    pub fn new(backlash_steps: i32) -> Self {
        Self::new_directional(backlash_steps, 0)
    }

    pub fn new_directional(backlash_in_steps: i32, backlash_out_steps: i32) -> Self {
        Self {
            backlash_in_steps: backlash_in_steps.max(0),
            backlash_out_steps: backlash_out_steps.max(0),
        }
    }

    /// Calculate the approach positions for backlash compensation
    /// Returns (intermediate_position, final_position)
    pub fn calculate_approach(&self, current: i32, target: i32) -> (Option<i32>, i32) {
        if target < current {
            // Inward moves on most stepper focusers leave mechanical slack
            // in the gear train; approaching from a deliberate overshoot
            // ensures the final position is always reached from the same
            // side, eliminating direction-dependent focus error.
            if self.backlash_in_steps == 0 {
                return (None, target);
            }
            let overshoot = target.saturating_sub(self.backlash_in_steps);
            (Some(overshoot), target)
        } else if target > current && self.backlash_out_steps > 0 {
            let overshoot = target.saturating_add(self.backlash_out_steps);
            (Some(overshoot), target)
        } else {
            (None, target)
        }
    }

    /// Check if backlash compensation is needed for this move
    pub fn is_needed(&self, current: i32, target: i32) -> bool {
        (target < current && self.backlash_in_steps > 0)
            || (target > current && self.backlash_out_steps > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parabolic_fit() {
        let config = AutofocusConfig {
            method: AutofocusMethod::Quadratic,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        // Generate perfect parabola: HFR = 0.001 * (x - 5000)^2 + 2.0
        let positions = [4500, 4700, 4900, 5000, 5100, 5300, 5500];
        let points: Vec<FocusDataPoint> = positions
            .iter()
            .map(|&pos| {
                // Why: test fixture; pos is small i32 literal, lossless to f64.
                let x = pos as f64 - 5000.0;
                let hfr = 0.001 * x * x + 2.0;
                FocusDataPoint {
                    position: pos,
                    hfr,
                    fwhm: None,
                    star_count: 50,
                }
            })
            .collect();

        let (best_pos, r_squared) = engine.fit_parabola(&points).unwrap();

        assert!(
            (best_pos - 5000).abs() < 10,
            "Best position should be near 5000, got {}",
            best_pos
        );
        assert!(
            r_squared > 0.99,
            "R-squared should be very high for perfect parabola, got {}",
            r_squared
        );
    }

    #[test]
    fn test_vcurve_fit() {
        let config = AutofocusConfig {
            method: AutofocusMethod::VCurve,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        let points = vec![
            FocusDataPoint {
                position: 1000,
                hfr: 5.0,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1100,
                hfr: 3.5,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1200,
                hfr: 2.2,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1300,
                hfr: 3.8,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1400,
                hfr: 5.5,
                fwhm: None,
                star_count: 50,
            },
        ];

        let (best_pos, _) = engine.fit_vcurve(&points).unwrap();
        assert!(
            (best_pos - 1200).abs() <= 1,
            "Should find minimum near position 1200, got {}",
            best_pos
        );
    }

    #[test]
    fn test_vcurve_fit_handles_asymmetric_data() {
        let config = AutofocusConfig {
            method: AutofocusMethod::VCurve,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        let points = vec![
            FocusDataPoint {
                position: 4600,
                hfr: 6.4,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 4800,
                hfr: 4.3,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 4950,
                hfr: 2.5,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 5050,
                hfr: 2.2,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 5300,
                hfr: 3.6,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 5600,
                hfr: 5.5,
                fwhm: None,
                star_count: 50,
            },
        ];

        let (best_pos, quality) = engine.fit_vcurve(&points).unwrap();
        assert!((best_pos - 5000).abs() <= 100, "best_pos={}", best_pos);
        assert!(quality > 0.5, "quality={}", quality);
    }

    #[test]
    fn test_parabolic_fit_rejects_empty_points() {
        let config = AutofocusConfig {
            method: AutofocusMethod::Quadratic,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        assert!(engine.fit_parabola(&[]).is_err());
    }

    #[test]
    fn test_backlash_compensation() {
        let backlash = BacklashCompensation::new(50);

        // Moving inward - should apply backlash
        let (intermediate, final_pos) = backlash.calculate_approach(5000, 4500);
        assert_eq!(intermediate, Some(4450)); // Overshoot by 50
        assert_eq!(final_pos, 4500);

        // Moving outward - no backlash needed
        let (intermediate, final_pos) = backlash.calculate_approach(4500, 5000);
        assert_eq!(intermediate, None);
        assert_eq!(final_pos, 5000);

        // Directional configuration also honors the user's OUT value.
        let directional = BacklashCompensation::new_directional(50, 30);
        let (intermediate, final_pos) = directional.calculate_approach(4500, 5000);
        assert_eq!(intermediate, Some(5030));
        assert_eq!(final_pos, 5000);
    }

    #[test]
    fn test_outlier_rejection() {
        let config = AutofocusConfig {
            outlier_rejection_sigma: 2.0,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        let points = vec![
            FocusDataPoint {
                position: 1000,
                hfr: 3.0,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1100,
                hfr: 2.8,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1200,
                hfr: 2.5,
                fwhm: None,
                star_count: 50,
            },
            FocusDataPoint {
                position: 1300,
                hfr: 15.0,
                fwhm: None,
                star_count: 50,
            }, // Outlier
            FocusDataPoint {
                position: 1400,
                hfr: 3.2,
                fwhm: None,
                star_count: 50,
            },
        ];

        let filtered = engine.reject_outliers(&points).unwrap();
        assert_eq!(filtered.len(), 4, "Should reject 1 outlier");
        assert!(
            filtered.iter().all(|p| p.hfr < 10.0),
            "Outlier should be removed"
        );
    }

    #[test]
    fn test_calculate_positions() {
        let config = AutofocusConfig {
            step_size: 100,
            steps_out: 3,
            ..Default::default()
        };
        let engine = VCurveAutofocus::new(config);

        let positions = engine.calculate_positions(5000);

        // Should have 2*3+1 = 7 positions
        assert_eq!(positions.len(), 7);

        // Should range from 4700 to 5300 in steps of 100
        assert_eq!(positions[0], 4700);
        assert_eq!(positions[3], 5000); // Middle position
        assert_eq!(positions[6], 5300);
    }

    /// The DEFAULT method (`VCurve`) must return a usable R² for the V-curve a
    /// real sweep produces, because the caller gates on `r_squared_threshold`
    /// (0.7 by default) and aborts autofocus below it.
    ///
    /// Measured live against the simulator's star field: a clean sweep (HFR
    /// 4.09 down to 2.35 and back up to 3.02, variance 1.75) that scores R²
    /// exactly 0.000 fails autofocus with "curve fit R² 0.000 is below the
    /// configured threshold 0.700" and no "curve fit failed" warning — the fit
    /// reporting success while scoring itself zero.
    #[test]
    fn vcurve_fit_scores_a_realistic_sweep_above_the_default_threshold() {
        let engine = VCurveAutofocus::new(AutofocusConfig::default());

        // The shape a real sweep traces: steeper on one side of focus than the
        // other, best focus off the sweep's centre but inside its span.
        const BEST: f64 = 25_075.0;
        let points: Vec<FocusDataPoint> = (24_800..=25_200)
            .step_by(50)
            .map(|pos| {
                let d = pos as f64 - BEST;
                let hfr = 2.1 + (d.abs() / 200.0) * if d < 0.0 { 2.0 } else { 1.4 };
                FocusDataPoint {
                    position: pos,
                    hfr,
                    fwhm: None,
                    star_count: 40,
                }
            })
            .collect();

        let (best_pos, r_squared) = engine.fit_vcurve(&points).expect("a clean V must fit");
        assert!(
            r_squared > 0.7,
            "R² {r_squared} must clear the default 0.7 gate for a clean V-curve;              at 0.0 autofocus rejects its own good data"
        );
        assert!(
            (best_pos as f64 - BEST).abs() < 60.0,
            "best position {best_pos} should land near {BEST}"
        );
    }

    /// Which fit method actually runs matters: a trigger-inserted autofocus uses
    /// the runtime default, not a node config. All three must score a clean V
    /// above the default 0.7 gate, or that method silently makes autofocus
    /// unusable.
    #[test]
    fn every_fit_method_scores_a_realistic_sweep() {
        const BEST: f64 = 25_075.0;
        let points: Vec<FocusDataPoint> = (24_800..=25_200)
            .step_by(50)
            .map(|pos| {
                let d = pos as f64 - BEST;
                let hfr = 2.1 + (d.abs() / 200.0) * if d < 0.0 { 2.0 } else { 1.4 };
                FocusDataPoint {
                    position: pos,
                    hfr,
                    fwhm: None,
                    star_count: 40,
                }
            })
            .collect();

        for method in [
            AutofocusMethod::VCurve,
            AutofocusMethod::Quadratic,
            AutofocusMethod::Hyperbolic,
        ] {
            let engine = VCurveAutofocus::new(AutofocusConfig {
                method,
                ..Default::default()
            });
            let fit = match method {
                AutofocusMethod::VCurve => engine.fit_vcurve(&points),
                AutofocusMethod::Quadratic => engine.fit_parabola(&points),
                AutofocusMethod::Hyperbolic => engine.fit_hyperbola(&points),
            };
            let (pos, r2) = fit.unwrap_or_else(|e| panic!("{method:?} fit errored: {e}"));
            println!("{method:?} -> pos {pos}, R2 {r2:.3}");
            assert!(
                r2 > 0.7,
                "{method:?} scored R² {r2:.3} on a clean V-curve; autofocus rejects \
                 anything below 0.7, so this method cannot ever succeed"
            );
        }
    }
}
