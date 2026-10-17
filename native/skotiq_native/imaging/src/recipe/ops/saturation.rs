//! Colour saturation on stretched data, with the boost attenuated where it
//! would do harm.
//!
//! Saturation moves each channel away from the pixel's own luminance:
//!
//! ```text
//! out_c = v_c + amount · protect(L) · (v_c − L)
//! L     = 0.2126·R + 0.7152·G + 0.0722·B
//! ```
//!
//! `amount = 0` leaves every sample exactly where it was, `amount > 0` pushes
//! the channels apart, and `amount = −1` collapses them onto `L` — a
//! desaturation to grey. Writing the operation as a *departure* from the input
//! rather than as `L + gain·(v_c − L)` is what makes the zero case exact.
//!
//! # Luminance protection
//!
//! ```text
//! protect(L) = 1 − protection · (1 − 4·L·(1 − L))
//! ```
//!
//! is `1` at mid-tone and falls to `1 − protection` at both ends of the display
//! range. Near white the channels are converging on the clip point and pushing
//! them apart only clips one of them; near black what separates the channels is
//! chroma noise, and a saturation boost there amplifies exactly that. `L` is
//! clamped into `[0, 1]` before the factor is evaluated, so a sample outside the
//! display range gets the end-of-range protection rather than a factor that
//! turns negative.
//!
//! # Domain
//!
//! Input and output are the display domain `[0, 1]` that `stretch@1` emits.
//! Output is clamped there, so `amount = 0` is an exact clone of any frame whose
//! samples already lie inside it.
//!
//! # Channels
//!
//! Three channels only: the luminance weights are the Rec. 709 primaries, and a
//! mono master has no channel to move away from its own luminance.
//!
//! Every parameter is in value units, so none of them scales with the preview
//! level.

use rayon::prelude::*;
use serde_json::Value;

use crate::recipe::{DarkroomOp, OpContext, OpError, OpImage, OpStage, Params};

/// Registry id.
const OP_ID: &str = "saturation";
/// Registry version.
const OP_VERSION: u32 = 1;

/// The only channel layout this operation defines a result for.
const REQUIRED_CHANNELS: u32 = 3;

/// Rec. 709 luminance weight of the red channel.
const LUMA_R: f64 = 0.2126;
/// Rec. 709 luminance weight of the green channel.
const LUMA_G: f64 = 0.7152;
/// Rec. 709 luminance weight of the blue channel.
const LUMA_B: f64 = 0.0722;

/// Strongest desaturation; `−1` collapses every channel onto its luminance.
const AMOUNT_MIN: f64 = -1.0;
/// Strongest boost.
const AMOUNT_MAX: f64 = 3.0;
/// Boost when the parameter is absent; `0` is the identity.
const AMOUNT_DEFAULT: f64 = 0.0;

/// Lowest protection; `0` applies the boost evenly across the display range.
const PROTECTION_MIN: f64 = 0.0;
/// Highest protection; `1` removes the boost entirely at black and at white.
const PROTECTION_MAX: f64 = 1.0;
/// Protection when the parameter is absent.
const PROTECTION_DEFAULT: f64 = 0.5;

/// Moves colour away from luminance, protecting both ends of the display range.
pub struct SaturationV1;

/// One step's validated parameters.
struct Settings {
    /// How far the channels move away from their own luminance.
    amount: f64,
    /// How strongly the boost is withdrawn at black and at white.
    protection: f64,
}

impl DarkroomOp for SaturationV1 {
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
        if channels != REQUIRED_CHANNELS {
            return Err(OpError::UnsupportedChannels {
                op_id: OP_ID,
                op_version: OP_VERSION,
                channels,
                expected: "a colour master with 3 channels",
            });
        }
        ctx.check_cancel()?;

        let row_len = image.width() as usize * REQUIRED_CHANNELS as usize;
        let source = image.data();
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(row_len)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let source_row = &source[y * row_len..y * row_len + row_len];
                for (pixel, slots) in row.as_chunks_mut::<3>().0.iter_mut().enumerate() {
                    let base = pixel * 3;
                    let r = source_row[base] as f64;
                    let g = source_row[base + 1] as f64;
                    let b = source_row[base + 2] as f64;
                    let luminance = LUMA_R * r + LUMA_G * g + LUMA_B * b;
                    let clamped = luminance.clamp(0.0, 1.0);
                    let protect =
                        1.0 - settings.protection * (1.0 - 4.0 * clamped * (1.0 - clamped));
                    let gain = settings.amount * protect;
                    for (slot, value) in slots.iter_mut().zip([r, g, b]) {
                        *slot = (value + gain * (value - luminance)).clamp(0.0, 1.0) as f32;
                    }
                }
            });
        ctx.check_cancel()?;

        image.with_data(out)
    }
}

/// Read and range-check one step's payload. `validate_params` and `apply` share
/// this, so the two can never disagree about a default.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&SaturationV1, params)?;
    p.allow(&["amount", "protection"])?;
    Ok(Settings {
        amount: p.f64_or("amount", AMOUNT_MIN..=AMOUNT_MAX, AMOUNT_DEFAULT)?,
        protection: p.f64_or(
            "protection",
            PROTECTION_MIN..=PROTECTION_MAX,
            PROTECTION_DEFAULT,
        )?,
    })
}

#[cfg(test)]
#[path = "saturation_tests.rs"]
mod saturation_tests;
