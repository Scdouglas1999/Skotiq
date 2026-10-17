//! Tone curve on stretched data: a monotone cubic through user control points.
//!
//! # Why monotone cubic
//!
//! A tone curve must not fold: if the curve ever descends, a brighter input maps
//! to a darker output and the image inverts locally. An ordinary cubic spline
//! through monotone data can still overshoot between knots and do exactly that.
//! The Fritsch–Carlson construction takes the natural tangents and clips them
//! into the region where the Hermite cubic is provably monotone on every
//! interval — with `Δ` a secant slope and `m` the tangents at its ends, the
//! constraint is `(m_i/Δ)² + (m_{i+1}/Δ)² ≤ 9` — so the rendered curve is
//! monotone whenever the control points are.
//!
//! The control points themselves are checked at validate time: `x` strictly
//! increasing, `y` non-decreasing. A descending `y` is rejected rather than
//! rendered, because a fold is a mistake in the payload and not a look.
//!
//! # Modes
//!
//! `luminance` applies the curve to the pixel's Rec. 709 luminance and scales
//! all three channels by the same ratio, so the hue and the channel ratios
//! survive the tone move. `perChannel` applies the curve to each channel
//! independently, which does shift hue — that is what a per-channel curve is
//! for. A one-channel master takes the curve directly in either mode.
//!
//! # Domain
//!
//! Input and output are the display domain `[0, 1]` that `stretch@1` emits, and
//! the curve is required to span it: `x` starts at `0` and ends at `1`. Samples
//! are clamped into the domain before the curve is evaluated, so a curve whose
//! control points all lie on the diagonal is an exact clone of any frame whose
//! samples already lie inside it.
//!
//! Every parameter is in value units, so none of them scales with the preview
//! level.

use rayon::prelude::*;
use serde_json::Value;

use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};

/// Registry id.
const OP_ID: &str = "curves";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Rec. 709 luminance weight of the red channel.
const LUMA_R: f64 = 0.2126;
/// Rec. 709 luminance weight of the green channel.
const LUMA_G: f64 = 0.7152;
/// Rec. 709 luminance weight of the blue channel.
const LUMA_B: f64 = 0.0722;

/// Fewest control points: the two domain ends.
const POINTS_MIN: usize = 2;
/// Most control points. Beyond this a tone curve is describing noise.
const POINTS_MAX: usize = 16;

/// The curve applied to the pixel's luminance, preserving channel ratios.
const MODE_LUMINANCE: &str = "luminance";
/// The curve applied to each channel independently.
const MODE_PER_CHANNEL: &str = "perChannel";
/// Modes this version accepts.
const MODES: [&str; 2] = [MODE_LUMINANCE, MODE_PER_CHANNEL];

/// Control-point inputs when the parameter is absent: the identity curve.
const X_DEFAULT: [f64; 2] = [0.0, 1.0];
/// Control-point outputs when the parameter is absent: the identity curve.
const Y_DEFAULT: [f64; 2] = [0.0, 1.0];

/// Applies a monotone tone curve to luminance or to each channel.
pub struct CurvesV1;

/// One step's validated parameters.
struct Settings {
    /// Which planes the curve is applied to.
    mode: &'static str,
    /// The monotone cubic the control points describe.
    curve: Curve,
}

/// A Fritsch–Carlson monotone cubic through its control points.
struct Curve {
    /// Control-point inputs, strictly increasing, spanning `[0, 1]`.
    x: Vec<f64>,
    /// Control-point outputs, non-decreasing.
    y: Vec<f64>,
    /// Tangent at each control point, clipped into the monotone region.
    m: Vec<f64>,
    /// Whether every control point lies on the diagonal, so the curve is the
    /// identity on the display domain.
    identity: bool,
}

impl Curve {
    /// Build the curve from control points `validate_params` has already
    /// checked.
    fn new(x: Vec<f64>, y: Vec<f64>) -> Self {
        let n = x.len();
        let identity = x.iter().zip(y.iter()).all(|(a, b)| a == b);
        let secant: Vec<f64> = (0..n - 1)
            .map(|i| (y[i + 1] - y[i]) / (x[i + 1] - x[i]))
            .collect();

        let mut m = vec![0.0_f64; n];
        m[0] = secant[0];
        m[n - 1] = secant[n - 2];
        for i in 1..n - 1 {
            m[i] = 0.5 * (secant[i - 1] + secant[i]);
        }
        // Fritsch–Carlson: a flat secant pins both its tangents to zero, and a
        // tangent pair outside the radius-3 circle is scaled back onto it.
        for (i, &delta) in secant.iter().enumerate() {
            if delta == 0.0 {
                m[i] = 0.0;
                m[i + 1] = 0.0;
                continue;
            }
            let a = m[i] / delta;
            let b = m[i + 1] / delta;
            let radius_sq = a * a + b * b;
            if radius_sq > 9.0 {
                let t = 3.0 / radius_sq.sqrt();
                m[i] = t * a * delta;
                m[i + 1] = t * b * delta;
            }
        }

        Self { x, y, m, identity }
    }

    /// The curve at `value`, which is already inside `[0, 1]`.
    fn eval(&self, value: f64) -> f64 {
        if self.identity {
            return value;
        }
        let n = self.x.len();
        if value <= self.x[0] {
            return self.y[0];
        }
        if value >= self.x[n - 1] {
            return self.y[n - 1];
        }
        let mut i = 0;
        while i + 1 < n - 1 && value > self.x[i + 1] {
            i += 1;
        }
        let span = self.x[i + 1] - self.x[i];
        let t = (value - self.x[i]) / span;
        let t2 = t * t;
        let t3 = t2 * t;
        let h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
        let h10 = t3 - 2.0 * t2 + t;
        let h01 = -2.0 * t3 + 3.0 * t2;
        let h11 = t3 - t2;
        h00 * self.y[i] + h10 * span * self.m[i] + h01 * self.y[i + 1] + h11 * span * self.m[i + 1]
    }
}

impl DarkroomOp for CurvesV1 {
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
        read_settings(params).map(|_| ())
    }

    fn apply(&self, image: &OpImage, params: &Value, ctx: &OpContext) -> Result<OpImage, OpError> {
        let settings = read_settings(params)?;
        let channels = image.channels();
        if channels != 1 && channels != 3 {
            return Err(OpError::UnsupportedChannels {
                op_id: OP_ID,
                op_version: OP_VERSION,
                channels,
                expected: "a mono master with 1 channel or a colour master with 3",
            });
        }
        ctx.check_cancel()?;

        let channels = channels as usize;
        let row_len = image.width() as usize * channels;
        let source = image.data();
        let curve = &settings.curve;
        let per_channel = channels == 1 || settings.mode == MODE_PER_CHANNEL;
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..y * row_len + row_len];
                if per_channel {
                    for (slot, sample) in row.iter_mut().zip(source_row.iter()) {
                        *slot = curve.eval((*sample as f64).clamp(0.0, 1.0)) as f32;
                    }
                    return;
                }
                for (pixel, slots) in row.as_chunks_mut::<3>().0.iter_mut().enumerate() {
                    let base = pixel * 3;
                    let r = (source_row[base] as f64).clamp(0.0, 1.0);
                    let g = (source_row[base + 1] as f64).clamp(0.0, 1.0);
                    let b = (source_row[base + 2] as f64).clamp(0.0, 1.0);
                    let luminance = (LUMA_R * r + LUMA_G * g + LUMA_B * b).clamp(0.0, 1.0);
                    let mapped = curve.eval(luminance);
                    for (slot, value) in slots.iter_mut().zip([r, g, b]) {
                        // Scaling by the luminance ratio keeps the channel
                        // ratios, and so the hue, across the tone move. A black
                        // pixel has no ratio to scale, so the curve's own lift
                        // is added instead.
                        *slot = if luminance > 0.0 {
                            (value * (mapped / luminance)).clamp(0.0, 1.0) as f32
                        } else {
                            (value + mapped).clamp(0.0, 1.0) as f32
                        };
                    }
                }
            });
        ctx.check_cancel()?;

        image.with_data(out)
    }
}

/// Read and range-check one step's payload. `validate_params` and `apply` share
/// this, so the two can never disagree about a default.
///
/// The control points are checked here and nowhere else: a curve that folds, a
/// `y` list of a different length than `x`, or an `x` list that does not span
/// the display domain is rejected before any pixel is read.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&CurvesV1, params)?;
    p.allow(&["mode", "x", "y"])?;
    let mode = p.enum_or("mode", &MODES, MODE_LUMINANCE)?;
    let x = p.f64_list_or("x", POINTS_MIN..=POINTS_MAX, 0.0..=1.0, &X_DEFAULT)?;
    let y = p.f64_list_or("y", POINTS_MIN..=POINTS_MAX, 0.0..=1.0, &Y_DEFAULT)?;

    if y.len() != x.len() {
        return Err(range_error(
            "y",
            format!("{} element{}", y.len(), if y.len() == 1 { "" } else { "s" }),
            format!(
                "the {} element{} 'x' carries",
                x.len(),
                if x.len() == 1 { "" } else { "s" }
            ),
        ));
    }
    if x[0] != 0.0 || x[x.len() - 1] != 1.0 {
        return Err(range_error(
            "x",
            format!("[{}, {}]", x[0], x[x.len() - 1]),
            "a list starting at 0 and ending at 1, spanning the display domain".to_string(),
        ));
    }
    for window in x.windows(2) {
        if window[1] <= window[0] {
            return Err(range_error(
                "x",
                format!("{} then {}", window[0], window[1]),
                "strictly increasing control-point inputs".to_string(),
            ));
        }
    }
    for window in y.windows(2) {
        if window[1] < window[0] {
            return Err(range_error(
                "y",
                format!("{} then {}", window[0], window[1]),
                "non-decreasing control-point outputs, so the curve does not fold".to_string(),
            ));
        }
    }

    Ok(Settings {
        mode,
        curve: Curve::new(x, y),
    })
}

/// A control-point rejection attributed to this operation.
fn range_error(key: &str, value: String, range: String) -> OpError {
    OpError::ParamRange {
        op_id: OP_ID,
        op_version: OP_VERSION,
        key: key.to_string(),
        value,
        range,
    }
}

#[cfg(test)]
#[path = "curves_tests.rs"]
mod curves_tests;
