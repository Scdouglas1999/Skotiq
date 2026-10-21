//! Green removal: PixInsight's SCNR (subtractive chromatic noise reduction)
//! for the green channel.
//!
//! Almost nothing in a broadband deep-sky field is green: stars run from blue
//! to orange and galaxies and dust are yellow to red, so a green cast left by
//! the color balance or by noise is never signal. SCNR limits green to a
//! neutral reference built from red and blue:
//!
//! ```text
//! averageNeutral:  N = (R + B) / 2
//! maximumNeutral:  N = max(R, B)
//! G' = (1 − amount) · G + amount · min(G, N)
//! ```
//!
//! `amount = 0` is the identity; PixInsight's default is average neutral at
//! amount 1. With `preserveLightness` (PixInsight's default too) every channel
//! of a pixel whose green was lowered is then scaled by `Y / Y'`, the ratio of
//! its channel mean before and after, so removing a green cast does not darken
//! the pixel.
//!
//! The operation is linear-stage: it runs on calibrated linear data before the
//! stretch, after the background has been neutralized, so a neutral sky is
//! equal in all three channels and is left alone. Every parameter is in value
//! units, so none scales with the preview level.

use rayon::prelude::*;
use serde_json::Value;

use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};

/// Registry id.
const OP_ID: &str = "scnr";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Lowest amount; `0` is the identity.
const AMOUNT_MIN: f64 = 0.0;
/// Highest amount; `1` limits green to the neutral reference.
const AMOUNT_MAX: f64 = 1.0;
/// Amount when the parameter is absent, PixInsight's default.
const AMOUNT_DEFAULT: f64 = 1.0;

/// Limits the green channel to a neutral reference built from red and blue.
pub struct ScnrV1;

/// The neutral reference green is limited to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Neutral {
    /// `(R + B) / 2`.
    Average,
    /// `max(R, B)`.
    Maximum,
}

/// One step's validated parameters.
struct Settings {
    amount: f64,
    neutral: Neutral,
    preserve_lightness: bool,
}

impl DarkroomOp for ScnrV1 {
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
        let settings = read_settings(params)?;
        if image.channels() != 3 {
            return Err(OpError::UnsupportedChannels {
                op_id: OP_ID,
                op_version: OP_VERSION,
                channels: image.channels(),
                expected: "a color image with 3 channels",
            });
        }
        if settings.amount == AMOUNT_MIN {
            return Ok(image.clone());
        }
        ctx.check_cancel()?;

        let row_len = image.width() as usize * 3;
        let source = image.data();
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..(y + 1) * row_len];
                for (pixel, sample) in row
                    .as_chunks_mut::<3>()
                    .0
                    .iter_mut()
                    .zip(source_row.as_chunks::<3>().0)
                {
                    let [r, g, b] = sample.map(|v| v as f64);
                    let neutral = match settings.neutral {
                        Neutral::Average => 0.5 * (r + b),
                        Neutral::Maximum => r.max(b),
                    };
                    if g <= neutral {
                        *pixel = *sample;
                        continue;
                    }
                    let green = (1.0 - settings.amount) * g + settings.amount * neutral;
                    let mut out = [r, green, b];
                    if settings.preserve_lightness {
                        let before = (r + g + b) / 3.0;
                        let after = (r + green + b) / 3.0;
                        if before > 0.0 && after > 0.0 {
                            let gain = before / after;
                            out = out.map(|v| v * gain);
                        }
                    }
                    *pixel = out.map(|v| v as f32);
                }
            });
        ctx.check_cancel()?;
        image.with_data(out)
    }
}

/// Read and range-check one step's payload.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&ScnrV1, params)?;
    p.allow(&["amount", "neutral", "preserveLightness"])?;
    Ok(Settings {
        amount: p.f64_or("amount", AMOUNT_MIN..=AMOUNT_MAX, AMOUNT_DEFAULT)?,
        neutral: match p.enum_or("neutral", &["average", "maximum"], "average")? {
            "maximum" => Neutral::Maximum,
            _ => Neutral::Average,
        },
        preserve_lightness: p.bool_or("preserveLightness", true)?,
    })
}

#[cfg(test)]
#[path = "scnr_tests.rs"]
mod scnr_tests;
