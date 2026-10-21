//! Large-scale color noise reduction on the background of linear color data.
//!
//! What is left of color noise after integration lives at scales of tens of
//! pixels: blotches of green and magenta across a sky that should be neutral
//! gray. A pixel-scale denoiser cannot see them, and smoothing color everywhere
//! would bleed a star's color into the sky around it. This operation smooths
//! color only where there is no signal, the way a PixInsight user runs
//! large-scale chrominance noise reduction through a luminance mask:
//!
//! ```text
//! Y      = (R + G + B) / 3                    luminance, untouched
//! C_c    = c − Y                              each channel's chrominance
//! S_c    = Gaussian(C_c, smoothingPx)         its large-scale part
//! w      = clamp((Gaussian(Y, 2 px) − sky) / (protection · σ), 0, 1)
//! out_c  = Y + w · C_c + (1 − w) · ((1 − amount) · C_c + amount · S_c)
//! ```
//!
//! `sky` and `σ` are the median and `1.4826 · MAD` of `Y`, measured over the
//! image at every render. A pixel `protection` sigmas above the sky (a star, the
//! target) keeps its own color exactly; the sky takes the smoothed color. The
//! chrominance terms of the three channels sum to zero, so every pixel's channel
//! mean, its lightness, is exactly what it was.
//!
//! `smoothingPx` is in full-resolution pixels and is scaled by
//! [`OpContext::scale`]; `protection` and `amount` are in value units.

use rayon::prelude::*;
use serde_json::{json, Value};

use crate::color_composite::mix::{background_and_noise, gaussian_blur};
use crate::recipe::{DarkroomOp, OpApplied, OpContext, OpError, OpImage, OpStage, Params};

/// Registry id.
const OP_ID: &str = "chroma_denoise";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Narrowest color smoothing, in full-resolution pixels.
const SMOOTHING_MIN: f64 = 0.5;
/// Widest color smoothing, in full-resolution pixels.
const SMOOTHING_MAX: f64 = 64.0;
/// Color smoothing when the parameter is absent, in full-resolution pixels.
const SMOOTHING_DEFAULT: f64 = 6.0;

/// Lowest protection threshold, in sky sigmas.
const PROTECTION_MIN: f64 = 0.5;
/// Highest protection threshold, in sky sigmas.
const PROTECTION_MAX: f64 = 100.0;
/// Sky sigmas above the sky at which a pixel keeps its own color entirely.
const PROTECTION_DEFAULT: f64 = 8.0;

/// Lowest amount; `0` is the identity.
const AMOUNT_MIN: f64 = 0.0;
/// Highest amount.
const AMOUNT_MAX: f64 = 1.0;
/// Amount when the parameter is absent.
const AMOUNT_DEFAULT: f64 = 1.0;

/// Smoothing of the luminance the protection mask is read from, in
/// full-resolution pixels, so the mask does not follow pixel noise.
const MASK_SMOOTHING_PX: f64 = 2.0;

/// Smooths the color of the background, leaving lightness and signal alone.
pub struct ChromaDenoiseV1;

/// One step's validated parameters.
struct Settings {
    smoothing_px: f64,
    protection: f64,
    amount: f64,
}

impl DarkroomOp for ChromaDenoiseV1 {
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
        Ok(self.apply_measured(image, params, ctx)?.image)
    }

    fn apply_measured(
        &self,
        image: &OpImage,
        params: &Value,
        ctx: &OpContext,
    ) -> Result<OpApplied, OpError> {
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
            return Ok(OpApplied::plain(image.clone()));
        }
        ctx.check_cancel()?;

        let width = image.width() as usize;
        let height = image.height() as usize;
        let source = image.data();
        let pixels = width * height;
        let luminance: Vec<f32> = (0..pixels)
            .into_par_iter()
            .map(|i| {
                ((source[i * 3] as f64 + source[i * 3 + 1] as f64 + source[i * 3 + 2] as f64) / 3.0)
                    as f32
            })
            .collect();
        let (sky, sigma) = background_and_noise(&luminance);
        let threshold = (settings.protection * sigma).max(f64::MIN_POSITIVE);
        let mask_plane = gaussian_blur(&luminance, width, height, MASK_SMOOTHING_PX * ctx.scale());
        ctx.check_cancel()?;
        let sigma_px = settings.smoothing_px * ctx.scale();
        let smoothed: Vec<Vec<f32>> = (0..3)
            .map(|c| {
                let chroma: Vec<f32> = (0..pixels)
                    .into_par_iter()
                    .map(|i| source[i * 3 + c] - luminance[i])
                    .collect();
                gaussian_blur(&chroma, width, height, sigma_px)
            })
            .collect();
        ctx.check_cancel()?;

        let amount = settings.amount;
        let mut out = vec![0.0_f32; image.len()];
        out.par_chunks_exact_mut(3)
            .enumerate()
            .for_each(|(i, pixel)| {
                let y = luminance[i] as f64;
                let weight = ((mask_plane[i] as f64 - sky) / threshold).clamp(0.0, 1.0);
                for (c, slot) in pixel.iter_mut().enumerate() {
                    let own = source[i * 3 + c] as f64 - y;
                    let background = (1.0 - amount) * own + amount * smoothed[c][i] as f64;
                    *slot = (y + weight * own + (1.0 - weight) * background) as f32;
                }
            });
        ctx.check_cancel()?;
        Ok(OpApplied::measured(
            image.with_data(out)?,
            json!({"sky": sky, "skySigma": sigma, "smoothingPx": sigma_px}),
        ))
    }
}

/// Read and range-check one step's payload.
fn read_settings(params: &Value) -> Result<Settings, OpError> {
    let p = Params::new(&ChromaDenoiseV1, params)?;
    p.allow(&["smoothingPx", "protection", "amount"])?;
    Ok(Settings {
        smoothing_px: p.f64_or(
            "smoothingPx",
            SMOOTHING_MIN..=SMOOTHING_MAX,
            SMOOTHING_DEFAULT,
        )?,
        protection: p.f64_or(
            "protection",
            PROTECTION_MIN..=PROTECTION_MAX,
            PROTECTION_DEFAULT,
        )?,
        amount: p.f64_or("amount", AMOUNT_MIN..=AMOUNT_MAX, AMOUNT_DEFAULT)?,
    })
}

#[cfg(test)]
#[path = "chroma_denoise_tests.rs"]
mod chroma_denoise_tests;
