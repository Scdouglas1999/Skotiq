//! Narrowband palette channel combination — SHO / HOO / custom.
//!
//! Narrowband imaging captures a target through one bandpass at a time (Hα at
//! 656.3 nm, [O III] at 500.7 nm, [S II] at 671.6 nm, …), integrating each
//! emission line into its own monochrome master. To produce a colour image
//! those single-channel masters must be mapped — by a fixed linear recipe — onto
//! the red, green, and blue display channels. The choice of recipe is the
//! *palette*:
//!
//! - **SHO** ("Hubble palette"): `S II → R`, `Hα → G`, `O III → B`. The classic
//!   false-colour mapping popularised by the Hubble Space Telescope team.
//! - **HOO** ("bicolour"): `Hα → R`, `O III → G` *and* `B`. Two channels only;
//!   O III drives both the green and the blue, giving the teal/gold look that
//!   approximates a natural-ish rendition of an emission nebula.
//!
//! This module implements the underlying primitive both palettes share: a
//! **linear combination** of any number of single-channel masters into a
//! 3-channel (RGB) composite, where each input contributes a per-channel
//! weight triple `[r, g, b]`. SHO and HOO are then just two named weight
//! tables ([`sho_palette`], [`hoo_palette`]); arbitrary custom palettes are
//! expressed by passing your own weights to [`combine_channels`].
//!
//! ## Algorithm
//!
//! For inputs `I_0 … I_{n-1}` (each a single-channel linear master with
//! identical dimensions) and weights `W_0 … W_{n-1}` (each a `[r, g, b]`
//! triple), the output composite is, per pixel `p`:
//!
//! ```text
//! R(p) = Σ_i W_i[0] · I_i(p)
//! G(p) = Σ_i W_i[1] · I_i(p)
//! B(p) = Σ_i W_i[2] · I_i(p)
//! ```
//!
//! This is the standard "channel mixer" / palette-combination operation used by
//! PixInsight's `PixelMath` and `ChannelCombination` and by Siril's `pm`
//! expressions: a fixed linear map from line-masters to display primaries. The
//! accumulation is done in `f64` (so that many inputs, or weights outside
//! `[0, 1]`, do not lose precision) and the result is stored as a linear `F32`
//! RGB master — unquantised, ready for further post-processing (SCNR, stretch).
//!
//! The work is embarrassingly parallel over output rows; we parallelise with
//! `rayon` over disjoint row slices exactly like
//! [`crate::integration`]/[`crate::calibration`].
//!
//! ## Limitations
//!
//! - The combine is purely **linear and per-pixel**. It does *not* perform
//!   continuum subtraction, star removal, SCNR/green-cast suppression, or any
//!   non-linear blend (e.g. PixInsight's `Lighten`/`Screen`). Those are
//!   separate, downstream steps; this primitive deliberately stays a pure
//!   linear mixer so it is exact and testable.
//! - The weight tables returned by [`sho_palette`]/[`hoo_palette`] are the
//!   *canonical* 1.0 mappings (each line goes to its channel at unit gain).
//!   Real artistic palettes routinely rebalance these (e.g. a reduced Hα-into-R
//!   contribution to tame a magenta cast); those are defensible per-image
//!   choices, not defaults this module bakes in. Pass custom weights to
//!   [`combine_channels`] when you want them.
//! - No tone mapping, white balance, or clipping is applied. Negative results
//!   (possible if a weight is negative) are preserved as-is in the linear `F32`
//!   master; clamping is the display layer's job.

use crate::ImageData;
use rayon::prelude::*;

/// Errors produced by [`combine_channels`] for caller mistakes.
///
/// As with the rest of the crate, we never silently best-effort on bad input:
/// a mismatched set of masters or weights is a programming error at the call
/// site, and producing a garbage composite would only hide it. Each variant
/// names exactly which precondition was violated.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum CombineError {
    /// No input masters were supplied. There is nothing to combine, and the
    /// output dimensions would be undefined.
    #[error("no input channels supplied to combine")]
    NoInputs,

    /// The input masters do not all share the same dimensions, or one of them
    /// is not single-channel. Every master must be `width × height × 1` with
    /// identical `width`/`height` so they register pixel-for-pixel.
    #[error("input channels must all be single-channel with identical dimensions")]
    DimMismatch,

    /// The number of weight triples does not equal the number of inputs. Each
    /// input needs exactly one `[r, g, b]` contribution triple.
    #[error("number of weight triples must equal the number of input channels")]
    WeightMismatch,
}

/// Canonical **SHO** ("Hubble") palette weights.
///
/// For inputs supplied in the order `[S II, Hα, O III]`, this maps:
///
/// ```text
/// S II  → R   (weight [1, 0, 0])
/// Hα    → G   (weight [0, 1, 0])
/// O III → B   (weight [0, 0, 1])
/// ```
///
/// Pass the returned `Vec` straight to [`combine_channels`] alongside the three
/// masters in that same order. This is the unit-gain reference mapping; rebalance
/// the triples yourself for artistic palettes (see the module "Limitations").
pub fn sho_palette() -> Vec<[f64; 3]> {
    vec![
        [1.0, 0.0, 0.0], // S II  → Red
        [0.0, 1.0, 0.0], // Hα    → Green
        [0.0, 0.0, 1.0], // O III → Blue
    ]
}

/// Canonical **HOO** ("bicolour") palette weights.
///
/// For inputs supplied in the order `[Hα, O III]`, this maps:
///
/// ```text
/// Hα    → R          (weight [1, 0, 0])
/// O III → G and B    (weight [0, 1, 1])
/// ```
///
/// O III drives *both* the green and the blue channel, which is what gives HOO
/// its characteristic teal-and-gold rendition of emission nebulae. Pass the
/// returned `Vec` to [`combine_channels`] with the two masters in that order.
pub fn hoo_palette() -> Vec<[f64; 3]> {
    vec![
        [1.0, 0.0, 0.0], // Hα    → Red
        [0.0, 1.0, 1.0], // O III → Green + Blue
    ]
}

/// Combine single-channel narrowband masters into a 3-channel linear `F32`
/// RGB composite using per-input `[r, g, b]` weight triples.
///
/// Each entry of `inputs` must be a **single-channel** linear master (the lines
/// produced by the integration pipeline; `U16` and `F32` masters are both
/// accepted and read as `f64`). All inputs must share identical `width` and
/// `height`. `weights[i]` is the `[r, g, b]` contribution of `inputs[i]` to the
/// three output channels.
///
/// The result is, per pixel and per output channel `k ∈ {R, G, B}`:
/// `out_k(p) = Σ_i weights[i][k] · inputs[i](p)`, accumulated in `f64` and
/// stored as `F32`. See the module docs for the algorithm and references.
///
/// # Errors
///
/// - [`CombineError::NoInputs`] if `inputs` is empty.
/// - [`CombineError::WeightMismatch`] if `weights.len() != inputs.len()`.
/// - [`CombineError::DimMismatch`] if any input is not single-channel, or the
///   inputs do not all share the same dimensions.
pub fn combine_channels(
    inputs: &[&ImageData],
    weights: &[[f64; 3]],
) -> Result<ImageData, CombineError> {
    // Validate the call site
    if inputs.is_empty() {
        return Err(CombineError::NoInputs);
    }
    if weights.len() != inputs.len() {
        return Err(CombineError::WeightMismatch);
    }

    let width = inputs[0].width;
    let height = inputs[0].height;

    // Every master must be single-channel with the reference dimensions. A
    // zero-channel or multi-channel input, or any size mismatch, is a hard error.
    for img in inputs {
        if img.channels != 1 || img.width != width || img.height != height {
            return Err(CombineError::DimMismatch);
        }
    }

    let pixel_count = (width as usize) * (height as usize);

    // Decode each input master once into a flat f64 plane. Doing this up front
    // (a) keeps the hot per-pixel loop free of byte-decoding branches and
    // (b) lets us reject any input we cannot read as a linear plane before we
    // start writing output. A single-channel plane has exactly `pixel_count`
    // samples, so a short/oversized buffer also funnels into `DimMismatch`.
    let planes: Vec<Vec<f64>> = inputs
        .iter()
        .map(|img| decode_plane_f64(img, pixel_count))
        .collect::<Result<Vec<_>, _>>()?;

    // Combine
    // Output layout is interleaved RGB: 3 contiguous samples per pixel. The work
    // is parallelised over disjoint output rows (one row = `width` pixels = `3 *
    // width` samples), matching the crate's integration/calibration idiom. Each
    // row task writes only its own slice, so there is no locking.
    const OUT_CHANNELS: usize = 3;
    let row_stride = (width as usize) * OUT_CHANNELS;
    let mut out = vec![0.0f32; pixel_count * OUT_CHANNELS];

    out.par_chunks_mut(row_stride)
        .enumerate()
        .for_each(|(y, row_out)| {
            let row_base = y * (width as usize);
            for x in 0..(width as usize) {
                let loc = row_base + x;
                // f64 accumulators per output channel.
                let mut acc = [0.0f64; OUT_CHANNELS];
                for (plane, w) in planes.iter().zip(weights.iter()) {
                    let v = plane[loc];
                    acc[0] += w[0] * v;
                    acc[1] += w[1] * v;
                    acc[2] += w[2] * v;
                }
                let base = x * OUT_CHANNELS;
                row_out[base] = acc[0] as f32;
                row_out[base + 1] = acc[1] as f32;
                row_out[base + 2] = acc[2] as f32;
            }
        });

    Ok(ImageData::from_f32(
        width,
        height,
        OUT_CHANNELS as u32,
        &out,
    ))
}

/// Decode a single-channel master into a flat `f64` plane of exactly
/// `expected` samples.
///
/// Accepts the linear master types the integration pipeline emits (`F32` and
/// `U16`). Any other pixel type, or a buffer whose decoded length does not match
/// `expected`, yields [`CombineError::DimMismatch`] rather than guessing at an
/// unrecognised layout and fabricating a plane.
fn decode_plane_f64(img: &ImageData, expected: usize) -> Result<Vec<f64>, CombineError> {
    let plane: Vec<f64> = if let Some(f) = img.as_f32() {
        f.into_iter().map(|v| v as f64).collect()
    } else if let Some(u) = img.as_u16() {
        u.into_iter().map(|v| v as f64).collect()
    } else {
        return Err(CombineError::DimMismatch);
    };

    if plane.len() != expected {
        return Err(CombineError::DimMismatch);
    }
    Ok(plane)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ImageData, PixelType};

    /// Build a synthetic single-channel `F32` master from per-pixel values.
    fn mono_f32(width: u32, height: u32, values: &[f32]) -> ImageData {
        assert_eq!(values.len(), (width * height) as usize);
        ImageData::from_f32(width, height, 1, values)
    }

    /// Build a synthetic single-channel `U16` master from per-pixel values.
    fn mono_u16(width: u32, height: u32, values: &[u16]) -> ImageData {
        assert_eq!(values.len(), (width * height) as usize);
        ImageData::from_u16(width, height, 1, values)
    }

    /// Render a deterministic ramp plane (no rng) so each input is distinct and
    /// each pixel is unique — makes "did channel X get input Y exactly" checks
    /// unambiguous. `base` offsets the whole plane so the three SHO inputs never
    /// collide on any pixel.
    fn ramp(width: u32, height: u32, base: f32) -> Vec<f32> {
        let n = (width * height) as usize;
        (0..n).map(|i| base + i as f32).collect()
    }

    #[test]
    fn sho_maps_each_input_to_its_channel_exactly() {
        // Three distinct masters, three distinct ramps. After an SHO combine the
        // R plane must equal SII exactly, G must equal Hα, B must equal OIII.
        let (w, h) = (4u32, 3u32);
        let sii_vals = ramp(w, h, 1000.0);
        let ha_vals = ramp(w, h, 5000.0);
        let oiii_vals = ramp(w, h, 9000.0);

        let sii = mono_f32(w, h, &sii_vals);
        let ha = mono_f32(w, h, &ha_vals);
        let oiii = mono_f32(w, h, &oiii_vals);

        let out = combine_channels(&[&sii, &ha, &oiii], &sho_palette())
            .expect("SHO combine of three valid masters must succeed");

        assert_eq!(out.channels, 3);
        assert_eq!(out.pixel_type, PixelType::F32);
        assert_eq!(out.width, w);
        assert_eq!(out.height, h);

        let rgb = out.as_f32().expect("output must be F32");
        let n = (w * h) as usize;
        for p in 0..n {
            let r = rgb[p * 3];
            let g = rgb[p * 3 + 1];
            let b = rgb[p * 3 + 2];
            assert_eq!(r, sii_vals[p], "S II must map to R at pixel {p}");
            assert_eq!(g, ha_vals[p], "Hα must map to G at pixel {p}");
            assert_eq!(b, oiii_vals[p], "O III must map to B at pixel {p}");
        }
    }

    #[test]
    fn hoo_maps_ha_to_red_and_oiii_to_green_and_blue_exactly() {
        // HOO: Hα → R; O III → G and B (same value in both).
        let (w, h) = (5u32, 2u32);
        let ha_vals = ramp(w, h, 200.0);
        let oiii_vals = ramp(w, h, 7000.0);

        let ha = mono_f32(w, h, &ha_vals);
        let oiii = mono_f32(w, h, &oiii_vals);

        let out = combine_channels(&[&ha, &oiii], &hoo_palette())
            .expect("HOO combine of two valid masters must succeed");

        assert_eq!(out.channels, 3);
        let rgb = out.as_f32().expect("output must be F32");
        let n = (w * h) as usize;
        for p in 0..n {
            let r = rgb[p * 3];
            let g = rgb[p * 3 + 1];
            let b = rgb[p * 3 + 2];
            assert_eq!(r, ha_vals[p], "Hα must map to R at pixel {p}");
            assert_eq!(g, oiii_vals[p], "O III must map to G at pixel {p}");
            assert_eq!(b, oiii_vals[p], "O III must map to B at pixel {p}");
            // The defining HOO property: G == B exactly.
            assert_eq!(g, b, "HOO must drive G and B identically at pixel {p}");
        }
    }

    #[test]
    fn weighted_mix_accumulates_in_f64_per_channel() {
        // A single 1x1 master combined with a fractional + multi-channel weight
        // triple, to confirm the linear Σ_i w_i[k]·I_i is exact per channel and
        // that more than the canonical 0/1 weights are honoured.
        let only = mono_f32(1, 1, &[100.0]);
        let weights = [[0.5, 2.0, -1.0]]; // R=50, G=200, B=-100
        let out = combine_channels(&[&only], &weights).expect("single-input combine");
        let rgb = out.as_f32().unwrap();
        assert_eq!(rgb[0], 50.0);
        assert_eq!(rgb[1], 200.0);
        assert_eq!(rgb[2], -100.0);
    }

    #[test]
    fn u16_masters_are_accepted_and_decoded() {
        // The integration pipeline can emit U16 masters too; the combine must
        // read them as linear values, not reject them.
        let (w, h) = (2u32, 2u32);
        let a = mono_u16(w, h, &[10, 20, 30, 40]);
        let b = mono_u16(w, h, &[1, 2, 3, 4]);
        // Two inputs both into R only (sum), G from b only, B from a only.
        let weights = [[1.0, 0.0, 1.0], [1.0, 1.0, 0.0]];
        let out = combine_channels(&[&a, &b], &weights).expect("U16 combine");
        let rgb = out.as_f32().unwrap();
        // pixel 0: R = 10 + 1 = 11, G = 1 (b), B = 10 (a)
        assert_eq!(rgb[0], 11.0);
        assert_eq!(rgb[1], 1.0);
        assert_eq!(rgb[2], 10.0);
        // pixel 3: R = 40 + 4 = 44, G = 4, B = 40
        assert_eq!(rgb[9], 44.0);
        assert_eq!(rgb[10], 4.0);
        assert_eq!(rgb[11], 40.0);
    }

    #[test]
    fn empty_inputs_is_no_inputs_error() {
        let err = combine_channels(&[], &[]).expect_err("empty input must error");
        assert_eq!(err, CombineError::NoInputs);
    }

    #[test]
    fn weight_count_mismatch_is_weight_mismatch_error() {
        let m = mono_f32(2, 2, &[0.0, 1.0, 2.0, 3.0]);
        // Two inputs but only one weight triple.
        let err = combine_channels(&[&m, &m], &[[1.0, 0.0, 0.0]])
            .expect_err("weight/input count mismatch must error");
        assert_eq!(err, CombineError::WeightMismatch);
    }

    #[test]
    fn dimension_mismatch_is_dim_mismatch_error() {
        let a = mono_f32(4, 4, &[0.0f32; 16]);
        let b = mono_f32(4, 3, &[0.0f32; 12]); // different height
        let err = combine_channels(&[&a, &b], &sho_palette()[..2])
            .expect_err("mismatched dimensions must error");
        assert_eq!(err, CombineError::DimMismatch);
    }

    #[test]
    fn multi_channel_input_is_dim_mismatch_error() {
        // A 3-channel input is not a single-channel master; reject it.
        let mono = mono_f32(2, 2, &[0.0, 1.0, 2.0, 3.0]);
        let rgb = ImageData::from_f32(2, 2, 3, &[0.0f32; 12]);
        let err = combine_channels(&[&mono, &rgb], &[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
            .expect_err("multi-channel input must error");
        assert_eq!(err, CombineError::DimMismatch);
    }

    #[test]
    fn palettes_have_the_documented_shape() {
        // Guard the canonical weight tables so an accidental edit is caught.
        assert_eq!(
            sho_palette(),
            vec![[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
        );
        assert_eq!(hoo_palette(), vec![[1.0, 0.0, 0.0], [0.0, 1.0, 1.0]]);
    }
}
