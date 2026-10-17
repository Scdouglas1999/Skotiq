//! The linear → stretched boundary: a generalised hyperbolic stretch (GHS)
//! evaluated natively in `f32`.
//!
//! # The transfer function
//!
//! GHS is defined by its slope. With `t = |x − SP|` the one-sided slope is
//! `(1 + b·D·t)^(−(b+1)/b)`, whose integral — the *arm* of the curve — is
//!
//! ```text
//! arm(t) = (1 − (1 + b·D·t)^(−1/b)) / D        b ≠ 0
//! arm(t) = (1 − exp(−D·t)) / D                 b = 0   (the b → 0 limit)
//! ```
//!
//! The curve is that arm reflected about the symmetry point,
//! `S(x) = sign(x − SP)·arm(|x − SP|)`, then mapped onto the unit interval:
//!
//! ```text
//! Y(x) = (S(x) − S(0)) / (S(1) − S(0))
//! ```
//!
//! The normalisation is what makes it a *stretch*: the raw arm has its steepest
//! slope at `SP` and flattens away from it, so rescaling the whole curve back to
//! `[0, 1]` amplifies the neighbourhood of `SP` and compresses the rest. `b`
//! selects the family — `b > 0` hyperbolic, `b = 0` exponential, `b < 0` the
//! integral family, which saturates at `t = 1/(|b|·D)` and is clamped there —
//! and `D` sets how hard the amplification bites. `D = 0` is the identity
//! transfer.
//!
//! Two closed forms fall out and are what the tests assert against: at `b = 1`,
//! `SP = 0` the curve is `Y(x) = x·(1 + D)/(1 + D·x)`; at `b = 0`, `SP = 0` it is
//! `Y(x) = (1 − e^{−D·x})/(1 − e^{−D})`.
//!
//! # Domain
//!
//! Input is linear ADU on no assumed scale, so the operation takes its own
//! normalisation: `blackPoint` and `whitePoint` are in ADU and map to `0` and
//! `1`. Both are required — an ADU scale has no defensible default, and guessing
//! one is how a float master gets read as if it were 16-bit. Output is the
//! display domain `[0, 1]`, which is why this operation emits
//! [`OpStage::Stretched`] and is the one place the stack leaves the linear
//! stage.
//!
//! Every parameter is in value units. None of them is measured in pixels, so
//! none scales with the preview level.
//!
//! # Channels
//!
//! One transfer for every channel (a *linked* stretch), so a colour master's
//! channel ratios survive the stretch and colour calibration is not undone here.

use rayon::prelude::*;
use serde_json::{json, Value};

use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};
use crate::robust_stats::{median_in_place, percentile_nearest_rank, MAD_TO_SIGMA};

/// Registry id.
const OP_ID: &str = "stretch";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Widest ADU magnitude accepted for a black or white point.
const POINT_BOUND: f64 = 1e12;

/// Lowest stretch intensity; `0` is the identity transfer.
const D_MIN: f64 = 0.0;
/// Highest stretch intensity.
const D_MAX: f64 = 100.0;
/// Stretch intensity when the parameter is absent.
const D_DEFAULT: f64 = 1.0;

/// Lowest local intensity. Below `0` the curve saturates at a finite distance
/// from the symmetry point.
const B_MIN: f64 = -5.0;
/// Highest local intensity.
const B_MAX: f64 = 15.0;
/// Local intensity when the parameter is absent: the exponential family.
const B_DEFAULT: f64 = 0.0;

/// Lowest symmetry point, in normalised units.
const SYMMETRY_MIN: f64 = 0.0;
/// Highest symmetry point, in normalised units.
const SYMMETRY_MAX: f64 = 1.0;
/// Symmetry point when the parameter is absent: the black end, which is the
/// classic shadow-lifting stretch.
const SYMMETRY_DEFAULT: f64 = 0.0;

/// `|b|` below this is evaluated as the `b → 0` exponential limit. The two forms
/// agree to well under one `f32` step there, and the power form loses the whole
/// `b·D·t` term to rounding once it underflows against `1`.
const B_EXPONENTIAL_EPSILON: f64 = 1e-8;

/// Sigmas below the measured background [`auto_params`] places the black point.
const AUTO_SHADOW_CLIP: f64 = 2.8;
/// Quantile [`auto_params`] places the white point at, so a hot pixel does not
/// set the top of the range.
const AUTO_WHITE_QUANTILE: f64 = 0.999;
/// Normalised level [`auto_params`] lifts the background to.
const AUTO_TARGET_BACKGROUND: f64 = 0.25;
/// Samples [`auto_params`] measures the histogram from. The stride follows from
/// the sample count, so it never depends on how the work is scheduled.
const AUTO_SAMPLE_BUDGET: usize = 262_144;
/// Bisection steps [`auto_params`] spends solving for `D`. A fixed count, never
/// an elapsed-time bound.
const AUTO_BISECTION_STEPS: u32 = 64;

/// Applies a generalised hyperbolic stretch, leaving the linear stage.
pub struct StretchV1;

/// One step's validated parameters.
struct Settings {
    /// ADU mapped to `0`.
    black_point: f64,
    /// ADU mapped to `1`.
    white_point: f64,
    /// Stretch intensity.
    d: f64,
    /// Local intensity: the GHS family selector.
    b: f64,
    /// Normalised position the curve is symmetric about.
    symmetry_point: f64,
}

impl DarkroomOp for StretchV1 {
    fn id(&self) -> &'static str {
        OP_ID
    }

    fn version(&self) -> u32 {
        OP_VERSION
    }

    fn stage(&self) -> OpStage {
        OpStage::Stretched
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        self.read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let settings = self.read_settings(params)?;
        ctx.check_cancel()?;

        let curve = Curve::new(settings.d, settings.b, settings.symmetry_point);
        let black = settings.black_point;
        let inverse_range = 1.0 / (settings.white_point - settings.black_point);

        let row_len = image.width() as usize * image.channels() as usize;
        let source = image.data();
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..y * row_len + row_len];
                for (slot, sample) in row.iter_mut().zip(source_row.iter()) {
                    let x = ((*sample as f64 - black) * inverse_range).clamp(0.0, 1.0);
                    *slot = curve.eval(x) as f32;
                }
            });
        ctx.check_cancel()?;

        image.with_data(out)
    }
}

impl StretchV1 {
    /// Read and range-check one step's payload. `validate_params` and `apply`
    /// share this, so the two can never disagree about a default.
    fn read_settings(&self, params: &Value) -> Result<Settings, OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["blackPoint", "whitePoint", "d", "b", "symmetryPoint"])?;
        let black_point = p.f64_required("blackPoint", -POINT_BOUND..=POINT_BOUND)?;
        let white_point = p.f64_required("whitePoint", -POINT_BOUND..=POINT_BOUND)?;
        if white_point <= black_point {
            return Err(OpError::ParamRange {
                op_id: self.id(),
                op_version: self.version(),
                key: "whitePoint".to_string(),
                value: white_point.to_string(),
                range: format!("({black_point}, {POINT_BOUND}]"),
            });
        }
        Ok(Settings {
            black_point,
            white_point,
            d: p.f64_or("d", D_MIN..=D_MAX, D_DEFAULT)?,
            b: p.f64_or("b", B_MIN..=B_MAX, B_DEFAULT)?,
            symmetry_point: p.f64_or(
                "symmetryPoint",
                SYMMETRY_MIN..=SYMMETRY_MAX,
                SYMMETRY_DEFAULT,
            )?,
        })
    }
}

/// The GHS transfer, with its normalisation solved once per render.
struct Curve {
    /// Stretch intensity.
    d: f64,
    /// Local intensity.
    b: f64,
    /// Symmetry point in normalised units.
    symmetry: f64,
    /// `S(0)`, the raw curve's value at the black end.
    offset: f64,
    /// `1 / (S(1) − S(0))`.
    inverse_span: f64,
    /// Whether the parameters reduce the transfer to `Y(x) = x`.
    identity: bool,
}

impl Curve {
    /// Solve the normalisation for one parameter set.
    ///
    /// `D = 0` is the identity transfer by definition. A parameter set whose
    /// `b·D` product underflows against `1` has the same limit — its arm is
    /// linear to every bit the double can hold — and is evaluated as the
    /// identity rather than divided by a zero span.
    fn new(d: f64, b: f64, symmetry: f64) -> Self {
        let mut curve = Self {
            d,
            b,
            symmetry,
            offset: 0.0,
            inverse_span: 1.0,
            identity: d <= 0.0,
        };
        if curve.identity {
            return curve;
        }
        let low = curve.raw(0.0);
        let high = curve.raw(1.0);
        let span = high - low;
        if !span.is_finite() || span <= 0.0 {
            curve.identity = true;
            return curve;
        }
        curve.offset = low;
        curve.inverse_span = 1.0 / span;
        curve
    }

    /// `S(x)`: the arm reflected about the symmetry point.
    fn raw(&self, x: f64) -> f64 {
        if x >= self.symmetry {
            arm(x - self.symmetry, self.d, self.b)
        } else {
            -arm(self.symmetry - x, self.d, self.b)
        }
    }

    /// `Y(x)`, the normalised transfer on `[0, 1]`.
    fn eval(&self, x: f64) -> f64 {
        if self.identity {
            return x;
        }
        (self.raw(x) - self.offset) * self.inverse_span
    }
}

/// The one-sided GHS arm for a distance `t ≥ 0` from the symmetry point.
fn arm(t: f64, d: f64, b: f64) -> f64 {
    if d <= 0.0 {
        return t;
    }
    if b.abs() < B_EXPONENTIAL_EPSILON {
        return (1.0 - (-d * t).exp()) / d;
    }
    let base = 1.0 + b * d * t;
    if base <= 0.0 {
        // Only reachable for b < 0, where the arm saturates at t = 1/(|b|·D)
        // and stays there.
        return 1.0 / d;
    }
    (1.0 - base.powf(-1.0 / b)) / d
}

/// Initial GHS parameters computed from an image's own histogram.
///
/// Held in the units `stretch@1` reads, so [`StretchAutoParams::to_params`] is
/// the payload of an autopilot-authored step.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StretchAutoParams {
    /// ADU mapped to `0`.
    pub black_point: f64,
    /// ADU mapped to `1`.
    pub white_point: f64,
    /// Stretch intensity.
    pub d: f64,
    /// Local intensity.
    pub b: f64,
    /// Normalised position the curve is symmetric about.
    pub symmetry_point: f64,
}

impl StretchAutoParams {
    /// The step parameter object these values describe.
    pub fn to_params(&self) -> Value {
        json!({
            "blackPoint": self.black_point,
            "whitePoint": self.white_point,
            "d": self.d,
            "b": self.b,
            "symmetryPoint": self.symmetry_point,
        })
    }
}

/// Compute a first-draft parameter set from `image`'s histogram.
///
/// The formula, in order:
///
/// 1. Sample the image on a fixed stride (at most [`AUTO_SAMPLE_BUDGET`]
///    samples), drop non-finite samples, and sort.
/// 2. `median` is the sample median; `sigma` is the sample MAD scaled by the
///    Gaussian consistency constant.
/// 3. `blackPoint = max(min sample, median − `[`AUTO_SHADOW_CLIP`]`·sigma)` —
///    the shadow clip never cuts below data that exists.
/// 4. `whitePoint` is the [`AUTO_WHITE_QUANTILE`] sample quantile, so one hot
///    pixel does not set the top of the range.
/// 5. `b = 0` and `symmetryPoint = 0`: the exponential family anchored at the
///    black end, which is the family whose lift is monotone in `D`.
/// 6. `D` is solved by [`AUTO_BISECTION_STEPS`] bisection steps on `[0, D_MAX]`
///    so the normalised background `(median − blackPoint)/(whitePoint −
///    blackPoint)` lands on [`AUTO_TARGET_BACKGROUND`]. A background already at
///    or above the target needs no lift and yields `D = 0`.
///
/// Reports [`OpError::Failed`] rather than inventing a parameter when the image
/// carries no finite samples, no measurable background spread, or no dynamic
/// range above its black point.
pub fn auto_params(image: &OpImage) -> Result<StretchAutoParams, OpError> {
    let data = image.data();
    let stride = (data.len() / AUTO_SAMPLE_BUDGET).max(1);
    let mut samples: Vec<f64> = data
        .iter()
        .step_by(stride)
        .map(|&value| value as f64)
        .filter(|value| value.is_finite())
        .collect();
    if samples.is_empty() {
        return Err(auto_failure(
            "the image carries no finite sample to measure",
        ));
    }
    samples.sort_unstable_by(f64::total_cmp);

    let median = percentile_nearest_rank(&samples, 0.5);
    let mut deviations: Vec<f64> = samples.iter().map(|value| (value - median).abs()).collect();
    let sigma = median_in_place(&mut deviations) * MAD_TO_SIGMA;
    if sigma <= 0.0 {
        return Err(auto_failure(
            "the background has no measurable spread to place a black point",
        ));
    }

    let black_point = (median - AUTO_SHADOW_CLIP * sigma).max(samples[0]);
    let white_point = percentile_nearest_rank(&samples, AUTO_WHITE_QUANTILE);
    if white_point <= black_point {
        return Err(auto_failure(
            "the image has no dynamic range above its black point",
        ));
    }

    let background = (median - black_point) / (white_point - black_point);
    if background <= 0.0 || background >= 1.0 {
        return Err(auto_failure(
            "the measured background falls outside the black-to-white range",
        ));
    }

    Ok(StretchAutoParams {
        black_point,
        white_point,
        d: solve_intensity(background, AUTO_TARGET_BACKGROUND),
        b: B_DEFAULT,
        symmetry_point: SYMMETRY_DEFAULT,
    })
}

/// The `D` that lifts a normalised `background` to `target` under `b = 0`,
/// `SP = 0`.
///
/// `Y(x)` is monotone increasing in `D` for a fixed `x ∈ (0, 1)`, so bisection
/// converges; the step count is fixed, never a wall-clock bound. A background
/// already at or above the target needs no lift.
fn solve_intensity(background: f64, target: f64) -> f64 {
    if background >= target {
        return 0.0;
    }
    let mut low = D_MIN;
    let mut high = D_MAX;
    for _ in 0..AUTO_BISECTION_STEPS {
        let mid = 0.5 * (low + high);
        if Curve::new(mid, B_DEFAULT, SYMMETRY_DEFAULT).eval(background) < target {
            low = mid;
        } else {
            high = mid;
        }
    }
    0.5 * (low + high)
}

/// An [`auto_params`] failure attributed to this operation.
fn auto_failure(reason: &str) -> OpError {
    OpError::Failed {
        op_id: OP_ID,
        op_version: OP_VERSION,
        reason: reason.to_string(),
    }
}

#[cfg(test)]
#[path = "stretch_tests.rs"]
mod stretch_tests;
