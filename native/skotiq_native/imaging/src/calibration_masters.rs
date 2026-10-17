//! Master-flat construction and cosmetic (hot/cold pixel) correction.
//!
//! This module closes the two calibration-completeness gaps called out in the
//! post-session integration design (`docs/design/2026-06-07-post-session-integration-design.md`,
//! §1.7) that sit between the existing pieces:
//!
//! - [`calibration.rs`](crate::calibration) only *applies* masters (it has no
//!   builder for a master flat).
//! - [`defect_map.rs`](crate::defect_map) builds a *persistent* bad-pixel map
//!   from a stack of darks/bias frames and repairs against it, but there is no
//!   "build a defect map straight from a master dark" convenience and no
//!   transient single-frame cosmetic pass that works without a pre-built map.
//!
//! It deliberately reuses the already-tested engines rather than re-deriving
//! the math:
//!
//! - master-flat *combination* goes through
//!   [`combine_master_frames`](crate::stacking::combine_master_frames) with
//!   [`MasterFrameKind::Flat`](crate::stacking::MasterFrameKind), which already
//!   sigma-clips the stack and normalises the result to unit mean.
//! - defect *correction* goes through
//!   [`correct_frame_u16`](crate::defect_map::correct_frame_u16) /
//!   [`correct_u16_slice`](crate::defect_map::correct_u16_slice), the same
//!   neighbourhood-median repair the live capture path uses.
//!
//! ## Master flat
//!
//! A raw flat carries the same additive pedestal as any other frame (bias +,
//! for non-negligible flat exposures, dark current). Before combining we
//! subtract that pedestal — a master bias for snap flats, or a master
//! *dark-flat* (a dark taken at the flat's exposure/temperature) for longer
//! flats. The combine then normalises to mean 1.0 so the existing
//! [`divide_flat`](crate::calibration::divide_flat) step is a pure
//! illumination correction.
//!
//! ## Cosmetic correction
//!
//! Two entry points, both reusing `defect_map.rs`:
//!
//! - [`build_defect_map_from_master_dark`] turns an *already combined* master
//!   dark (single frame) into a [`DefectMap`] with a robust MAD/σ outlier test.
//!   This is the "I only kept the master, not the individual darks" path.
//! - [`cosmetic_correct_transient`] repairs a single light frame against a
//!   *self-derived* local outlier test (no master dark needed) — it flags
//!   pixels that deviate hugely from their local neighbourhood median (hot
//!   *and* cold) and repairs them by the same neighbourhood median. This is
//!   the per-light cosmic-ray / residual-hot-pixel safety net for the cases
//!   where no defect map is available.

use crate::defect_map::{correct_u16_slice, CorrectionMethod, DefectMap, KernelSize};
use crate::robust_stats::{median_in_place, MAD_TO_SIGMA};
use crate::stacking::{
    combine_master_frames, CombineMethod, MasterFrame, MasterFrameKind, MasterOutputType,
};
use crate::{calibration::CalibrationError, ImageData, PixelType};
use rayon::prelude::*;

/// Errors specific to master-flat / cosmetic-correction construction.
#[derive(Debug, Clone)]
pub enum MasterCalibrationError {
    /// No flat frames were supplied.
    EmptyFlatStack,
    /// A pedestal frame (bias / dark-flat) did not match the flat geometry.
    Calibration(CalibrationError),
    /// The underlying `combine_master_frames` rejected the stack (mismatched
    /// dimensions, unsupported pixel type, degenerate flat mean, …). The
    /// inner string is the combiner's own diagnostic.
    Combine(String),
    /// A frame had an unsupported pixel type for the requested operation.
    UnsupportedPixelType { pixel_type: PixelType },
    /// The frame buffer length did not match its declared dimensions.
    BufferLengthMismatch { expected: usize, actual: usize },
    /// A configuration value was outside its valid range.
    InvalidParameter(String),
}

impl std::fmt::Display for MasterCalibrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MasterCalibrationError::EmptyFlatStack => {
                write!(f, "cannot build a master flat from zero flat frames")
            }
            MasterCalibrationError::Calibration(e) => {
                write!(f, "flat pedestal subtraction failed: {}", e)
            }
            MasterCalibrationError::Combine(msg) => write!(f, "flat combine failed: {}", msg),
            MasterCalibrationError::UnsupportedPixelType { pixel_type } => write!(
                f,
                "cosmetic correction only supports U16 frames, got {:?}",
                pixel_type
            ),
            MasterCalibrationError::BufferLengthMismatch { expected, actual } => write!(
                f,
                "frame buffer length mismatch: expected {} bytes, got {}",
                expected, actual
            ),
            MasterCalibrationError::InvalidParameter(msg) => {
                write!(f, "invalid parameter: {}", msg)
            }
        }
    }
}

impl std::error::Error for MasterCalibrationError {}

impl From<CalibrationError> for MasterCalibrationError {
    fn from(e: CalibrationError) -> Self {
        MasterCalibrationError::Calibration(e)
    }
}

// Master flat

/// Configuration for [`build_master_flat`].
#[derive(Debug, Clone, Copy)]
pub struct MasterFlatConfig {
    /// How to combine the pedestal-subtracted flats. Defaults (via
    /// [`Default`]) to sigma-clipping, which rejects the odd dust-mote shift
    /// or stray light gradient on an individual flat. Median is a robust
    /// fallback when the flat count is small.
    pub method: CombineMethod,
    /// Output pixel type for the master flat. `F32` (the default) keeps the
    /// unit-mean normalisation lossless; `U16` targets a mean of 32768 so the
    /// legacy u16 divide-by-flat path still works.
    pub output_type: MasterOutputType,
}

impl Default for MasterFlatConfig {
    fn default() -> Self {
        MasterFlatConfig {
            // 3-sigma, 5 iterations is a sane flat-field default: aggressive
            // enough to drop a contaminated flat, gentle enough not to bias the
            // illumination profile.
            method: CombineMethod::SigmaClip {
                kappa: 3.0,
                iterations: 5,
            },
            output_type: MasterOutputType::F32,
        }
    }
}

/// Build a master flat from a stack of raw flat frames.
///
/// Pipeline:
/// 1. Subtract the pedestal (`bias_or_dark_flat`) from each raw flat. Pass a
///    master **bias** for short snap flats, or a master **dark-flat** (a dark
///    matched to the flat's exposure & temperature) for longer sky/panel
///    flats. `None` skips pedestal subtraction (acceptable only when the flats
///    are already pedestal-corrected, e.g. exported masters).
/// 2. Combine the pedestal-subtracted flats with
///    [`combine_master_frames`] using [`MasterFrameKind::Flat`], which
///    normalises the combined result to **unit mean** (1.0 for `F32`, 32768
///    for `U16`).
///
/// The returned [`MasterFrame`] reports the pre-normalisation mean
/// (`input_mean`) and the post-normalisation mean (`output_mean`, ≈ the target
/// mean), which the integration layer surfaces as a flat-quality diagnostic.
///
/// Errors fail closed: a zero-length stack, a geometry/type mismatch between a
/// flat and the pedestal, or a degenerate (≤ 0) flat mean all return an error
/// rather than silently emitting a flat that would corrupt every light it
/// divides.
pub fn build_master_flat(
    flats: &[ImageData],
    bias_or_dark_flat: Option<&ImageData>,
    config: MasterFlatConfig,
) -> Result<MasterFrame, MasterCalibrationError> {
    if flats.is_empty() {
        return Err(MasterCalibrationError::EmptyFlatStack);
    }

    // Step 1: pedestal subtraction. We materialise the corrected flats into a
    // fresh Vec because `combine_master_frames` takes an owned slice. When no
    // pedestal is supplied we clone (the combiner needs `&[ImageData]` and the
    // caller owns `flats`); the clone is unavoidable given the combiner's
    // by-value contract and matches the memory the offline path already pays.
    let corrected: Vec<ImageData> = match bias_or_dark_flat {
        Some(pedestal) => flats
            .iter()
            .map(|flat| crate::calibration::subtract_bias(flat, pedestal))
            .collect::<Result<Vec<_>, _>>()?,
        None => flats.to_vec(),
    };

    // Step 2: combine + normalise to unit mean. Reuse the tested combiner.
    combine_master_frames(
        &corrected,
        MasterFrameKind::Flat,
        config.method,
        config.output_type,
    )
    .map_err(MasterCalibrationError::Combine)
}

// Defect map from a master dark

/// Sigma multiplier for the master-dark hot/cold outlier test. A pixel whose
/// dark level deviates from the frame median by more than this many robust σ
/// (estimated from the MAD) is flagged defective. 5σ on a MAD-derived sigma is
/// conservative — it catches genuine stuck/hot/cold pixels without flagging the
/// shoulders of the dark-current distribution.
const MASTER_DARK_SIGMA_K: f64 = 5.0;

/// Build a [`DefectMap`] directly from a single, already-combined **master
/// dark** (or master bias).
///
/// Unlike [`build_defect_map`](crate::defect_map::build_defect_map), which
/// needs the *stack* of individual darks (to apply a per-frame consistency
/// vote), this works from one master frame for the common "I archived the
/// master but not the subs" case. It flags both hot pixels (dark level far
/// above the median) and cold/dead pixels (far below), using a robust
/// MAD-derived σ so a handful of genuine defects can't inflate the threshold
/// enough to mask themselves.
///
/// Only `U16` masters are supported (the on-disk defect-map format and the
/// repair paths are u16). `temperature_bucket_decicelsius` is recorded in the
/// returned map so it can be filed in the temperature-keyed library.
pub fn build_defect_map_from_master_dark(
    master_dark: &ImageData,
    temperature_bucket_decicelsius: i16,
) -> Result<DefectMap, MasterCalibrationError> {
    if master_dark.pixel_type != PixelType::U16 {
        return Err(MasterCalibrationError::UnsupportedPixelType {
            pixel_type: master_dark.pixel_type,
        });
    }
    let pixels = master_dark
        .as_u16()
        .ok_or(MasterCalibrationError::UnsupportedPixelType {
            pixel_type: master_dark.pixel_type,
        })?;
    let expected = (master_dark.width as usize)
        * (master_dark.height as usize)
        * (master_dark.channels as usize);
    if pixels.len() != expected {
        return Err(MasterCalibrationError::BufferLengthMismatch {
            expected: expected * 2,
            actual: master_dark.data.len(),
        });
    }
    if pixels.is_empty() {
        return Err(MasterCalibrationError::EmptyFlatStack);
    }

    // Robust statistics: median and MAD over the whole frame.
    let median = median_of(&pixels);
    let mut abs_dev: Vec<f64> = pixels.iter().map(|&v| (v as f64 - median).abs()).collect();
    let mad = median_in_place(&mut abs_dev).max(1.0e-9);
    let sigma = (mad * MAD_TO_SIGMA).max(1.0e-9);

    let upper = median + MASTER_DARK_SIGMA_K * sigma;
    let lower = median - MASTER_DARK_SIGMA_K * sigma;

    let width = master_dark.width;
    let height = master_dark.height;
    let channels = master_dark.channels as usize;
    let mut map = DefectMap::empty(width, height, temperature_bucket_decicelsius);

    // A pixel is flagged if it is an outlier in ANY channel. The defect map is
    // a single spatial bitmap (it has no channel dimension), so the most
    // conservative behaviour is to repair a (x,y) location if any channel there
    // is broken.
    let w = width as usize;
    for y in 0..height {
        for x in 0..width {
            let base = ((y as usize) * w + (x as usize)) * channels;
            let mut defective = false;
            for c in 0..channels {
                let v = pixels[base + c] as f64;
                if v > upper || v < lower {
                    defective = true;
                    break;
                }
            }
            if defective {
                map.mark_defective(x, y);
            }
        }
    }

    Ok(map)
}

// Transient cosmetic correction (self-derived, no master dark)

/// Configuration for [`cosmetic_correct_transient`].
#[derive(Debug, Clone, Copy)]
pub struct CosmeticConfig {
    /// Multiplier on the local robust σ above which a pixel is treated as hot.
    /// PixInsight's CosmeticCorrection "hot sigma" knob; 3.0 is a sensible
    /// default that repairs cosmic rays / residual hot pixels without chewing
    /// stars (stars span several pixels, so neighbours are also bright and the
    /// local σ rises with them).
    pub hot_sigma: f64,
    /// Multiplier on the local robust σ below which a pixel is treated as cold.
    pub cold_sigma: f64,
    /// Kernel diameter (3, 5 or 7) for the local-median statistic and repair.
    pub kernel: KernelSize,
    /// Replacement method for repaired pixels.
    pub method: CorrectionMethod,
}

impl Default for CosmeticConfig {
    fn default() -> Self {
        CosmeticConfig {
            hot_sigma: 3.0,
            cold_sigma: 3.0,
            kernel: KernelSize::default(),
            method: CorrectionMethod::Median,
        }
    }
}

/// Report from a transient cosmetic-correction pass.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CosmeticReport {
    /// Pixels flagged and repaired as hot (local-bright outliers).
    pub hot_repaired: u32,
    /// Pixels flagged and repaired as cold (local-dark outliers).
    pub cold_repaired: u32,
}

impl CosmeticReport {
    /// Total pixels repaired across both polarities.
    pub fn total(&self) -> u32 {
        self.hot_repaired + self.cold_repaired
    }
}

/// Repair a single light frame against a **self-derived** local-outlier test —
/// no master dark or pre-built defect map required.
///
/// For every pixel we compute the median of its local neighbourhood (the
/// configured kernel) and a robust σ from the neighbourhood MAD. A pixel that
/// sits more than `hot_sigma · σ` above, or `cold_sigma · σ` below, the local
/// median is flagged. The flag is *spatial* (channel-agnostic, like the defect
/// map), and the set of flagged pixels is then repaired by the same
/// neighbourhood-median engine used at capture time
/// ([`correct_u16_slice`]) so the repair behaviour is identical and tested.
///
/// This is the per-light cosmic-ray / residual-hot-pixel safety net for the
/// integration pre-pass when no defect map exists. It is intentionally
/// conservative: detection uses the *local* statistic so it does not flag real
/// extended structure (stars, galaxy cores) where neighbours are bright too.
///
/// Only `U16` frames are supported. The frame is corrected in place and the
/// report records how many hot / cold pixels were repaired.
pub fn cosmetic_correct_transient(
    frame: &mut ImageData,
    config: CosmeticConfig,
) -> Result<CosmeticReport, MasterCalibrationError> {
    if frame.pixel_type != PixelType::U16 {
        return Err(MasterCalibrationError::UnsupportedPixelType {
            pixel_type: frame.pixel_type,
        });
    }
    if !(config.hot_sigma.is_finite() && config.hot_sigma > 0.0) {
        return Err(MasterCalibrationError::InvalidParameter(format!(
            "hot_sigma must be finite and > 0, got {}",
            config.hot_sigma
        )));
    }
    if !(config.cold_sigma.is_finite() && config.cold_sigma > 0.0) {
        return Err(MasterCalibrationError::InvalidParameter(format!(
            "cold_sigma must be finite and > 0, got {}",
            config.cold_sigma
        )));
    }

    let width = frame.width;
    let height = frame.height;
    let channels = frame.channels;
    let expected = (width as usize) * (height as usize) * (channels as usize);

    let mut pixels = frame
        .as_u16()
        .ok_or(MasterCalibrationError::UnsupportedPixelType {
            pixel_type: frame.pixel_type,
        })?;
    if pixels.len() != expected {
        return Err(MasterCalibrationError::BufferLengthMismatch {
            expected: expected * 2,
            actual: frame.data.len(),
        });
    }

    // Detection pass: build a defect map from the local-outlier test. We scan
    // in parallel over rows, then mark the map serially (mark_defective mutates
    // a shared bitmap; the per-row outlier lists keep the parallel part lock
    // free).
    let half = config.kernel.half_width();
    let w_i = width as i32;
    let h_i = height as i32;
    let w = width as usize;
    let ch = channels as usize;

    // Per-pixel polarity classification, computed in parallel. 0 = clean,
    // 1 = hot, 2 = cold. Channel-agnostic: a location is hot/cold if any of
    // its channels trips the test (hot takes precedence for the report tally
    // when a multi-channel pixel is mixed, which is vanishingly rare).
    let classification: Vec<u8> = (0..(height as usize) * w)
        .into_par_iter()
        .map(|loc| {
            let x = (loc % w) as i32;
            let y = (loc / w) as i32;
            let mut polarity = 0u8;
            for c in 0..ch {
                // Gather neighbourhood values (excluding the centre) for this
                // channel.
                let mut nbr: Vec<f64> =
                    Vec::with_capacity(((2 * half + 1) * (2 * half + 1)) as usize);
                for dy in -half..=half {
                    for dx in -half..=half {
                        if dx == 0 && dy == 0 {
                            continue;
                        }
                        let nx = x + dx;
                        let ny = y + dy;
                        if nx < 0 || nx >= w_i || ny < 0 || ny >= h_i {
                            continue;
                        }
                        let idx = ((ny as usize) * w + nx as usize) * ch + c;
                        nbr.push(pixels[idx] as f64);
                    }
                }
                if nbr.len() < 3 {
                    // Too few neighbours (frame corner on a tiny frame) to make
                    // a robust call; leave it clean rather than guess.
                    continue;
                }
                let med = median_in_place(&mut nbr.clone());
                let mut dev: Vec<f64> = nbr.iter().map(|&v| (v - med).abs()).collect();
                let mad = median_in_place(&mut dev).max(1.0e-9);
                let sigma = (mad * MAD_TO_SIGMA).max(1.0e-9);

                let centre = pixels[(y as usize * w + x as usize) * ch + c] as f64;
                if centre > med + config.hot_sigma * sigma {
                    polarity = 1;
                    break;
                } else if centre < med - config.cold_sigma * sigma {
                    polarity = 2;
                    break;
                }
            }
            polarity
        })
        .collect();

    let mut map = DefectMap::empty(width, height, 0);
    let mut hot = 0u32;
    let mut cold = 0u32;
    for (loc, &p) in classification.iter().enumerate() {
        if p == 0 {
            continue;
        }
        let x = (loc % w) as u32;
        let y = (loc / w) as u32;
        map.mark_defective(x, y);
        if p == 1 {
            hot += 1;
        } else {
            cold += 1;
        }
    }

    if map.defective_count() == 0 {
        return Ok(CosmeticReport::default());
    }

    // Repair pass: reuse the capture-path corrector so the fill behaviour
    // (neighbour median, 5x5 fallback for clusters, cluster skip) is identical
    // and already tested.
    correct_u16_slice(
        &mut pixels,
        width,
        height,
        channels,
        &map,
        config.method,
        config.kernel,
    )
    .map_err(|e| MasterCalibrationError::Combine(e.to_string()))?;

    // Write the repaired pixels back into the frame's byte buffer.
    *frame = ImageData::from_u16(width, height, channels, &pixels);

    Ok(CosmeticReport {
        hot_repaired: hot,
        cold_repaired: cold,
    })
}

// Small numeric helpers (local to keep the module self-contained)

/// Median of a u16 slice as f64, without mutating the input.
fn median_of(values: &[u16]) -> f64 {
    let mut v: Vec<f64> = values.iter().map(|&x| x as f64).collect();
    median_in_place(&mut v)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a synthetic vignetted flat: brightness falls off radially from the
    /// centre. Returns a U16 `ImageData`.
    fn vignette_flat(width: u32, height: u32, centre_adu: f64, edge_falloff: f64) -> ImageData {
        let cx = (width as f64 - 1.0) / 2.0;
        let cy = (height as f64 - 1.0) / 2.0;
        let max_r2 = cx * cx + cy * cy;
        let mut pixels = vec![0u16; (width * height) as usize];
        for y in 0..height {
            for x in 0..width {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let r2 = (dx * dx + dy * dy) / max_r2.max(1.0);
                // Linear-ish radial falloff: centre = centre_adu, edge dimmer.
                let v = centre_adu * (1.0 - edge_falloff * r2);
                pixels[(y * width + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &pixels)
    }

    fn flat_image(width: u32, height: u32, value: u16) -> ImageData {
        ImageData::from_u16(width, height, 1, &vec![value; (width * height) as usize])
    }

    // Master flat

    #[test]
    fn master_flat_normalizes_vignette_to_unit_mean() {
        // A stack of identical vignetted flats must combine to a master whose
        // mean is exactly 1.0 (F32) while PRESERVING the vignette shape.
        let flats: Vec<ImageData> = (0..8)
            .map(|_| vignette_flat(32, 24, 50_000.0, 0.4))
            .collect();
        let master = build_master_flat(&flats, None, MasterFlatConfig::default())
            .expect("master flat should build");

        assert_eq!(master.kind, MasterFrameKind::Flat);
        assert_eq!(master.image.pixel_type, PixelType::F32);

        let data = master.image.as_f32().expect("f32 master");
        let mean: f64 = data.iter().map(|&v| v as f64).sum::<f64>() / data.len() as f64;
        assert!(
            (mean - 1.0).abs() < 1.0e-4,
            "normalised master-flat mean should be ~1.0, got {}",
            mean
        );

        // Vignette preserved: a centre pixel must be brighter than a corner
        // pixel in the normalised master.
        let w = master.image.width as usize;
        let centre = data[(master.image.height as usize / 2) * w + w / 2] as f64;
        let corner = data[0] as f64;
        assert!(
            centre > corner,
            "vignette must be preserved: centre {} should exceed corner {}",
            centre,
            corner
        );
        // And the normalised values straddle 1.0 (centre above, corner below).
        assert!(centre > 1.0 && corner < 1.0);
    }

    #[test]
    fn master_flat_subtracts_bias_pedestal() {
        // Flats sit on a 1000-ADU bias pedestal. After pedestal subtraction the
        // illumination ratios must match a pedestal-free build.
        let bias = flat_image(16, 16, 1000);
        let raw: Vec<ImageData> = (0..6)
            .map(|_| {
                // vignette on top of the pedestal
                let base = vignette_flat(16, 16, 40_000.0, 0.5);
                let mut p = base.as_u16().unwrap();
                for v in &mut p {
                    *v = v.saturating_add(1000);
                }
                ImageData::from_u16(16, 16, 1, &p)
            })
            .collect();

        let with_bias = build_master_flat(&raw, Some(&bias), MasterFlatConfig::default())
            .expect("build with bias");
        // The build without bias subtraction operates on the bias-free vignette.
        let pedestal_free: Vec<ImageData> = (0..6)
            .map(|_| vignette_flat(16, 16, 40_000.0, 0.5))
            .collect();
        let without_bias = build_master_flat(&pedestal_free, None, MasterFlatConfig::default())
            .expect("build without bias");

        let a = with_bias.image.as_f32().unwrap();
        let b = without_bias.image.as_f32().unwrap();
        assert_eq!(a.len(), b.len());
        // Pedestal subtraction restores the true illumination profile, so the
        // two normalised masters must agree closely.
        for (pa, pb) in a.iter().zip(b.iter()) {
            assert!(
                (*pa - *pb).abs() < 5.0e-3,
                "bias-subtracted master should match pedestal-free master: {} vs {}",
                pa,
                pb
            );
        }
    }

    #[test]
    fn master_flat_u16_targets_half_scale_mean() {
        let flats: Vec<ImageData> = (0..5).map(|_| flat_image(8, 8, 30_000)).collect();
        let cfg = MasterFlatConfig {
            method: CombineMethod::Median,
            output_type: MasterOutputType::U16,
        };
        let master = build_master_flat(&flats, None, cfg).expect("u16 master flat");
        assert_eq!(master.image.pixel_type, PixelType::U16);
        // Uniform flat → every normalised pixel equals the target mean 32768.
        let data = master.image.as_u16().unwrap();
        for v in &data {
            assert_eq!(*v, 32768);
        }
    }

    #[test]
    fn master_flat_rejects_empty_stack() {
        let empty: Vec<ImageData> = Vec::new();
        assert!(matches!(
            build_master_flat(&empty, None, MasterFlatConfig::default()),
            Err(MasterCalibrationError::EmptyFlatStack)
        ));
    }

    #[test]
    fn master_flat_rejects_pedestal_dimension_mismatch() {
        let flats: Vec<ImageData> = (0..3).map(|_| flat_image(8, 8, 20_000)).collect();
        let wrong_bias = flat_image(4, 4, 1000);
        let err = build_master_flat(&flats, Some(&wrong_bias), MasterFlatConfig::default())
            .expect_err("dimension mismatch must error");
        assert!(matches!(err, MasterCalibrationError::Calibration(_)));
    }

    // Defect map from master dark

    #[test]
    fn defect_map_from_master_dark_flags_hot_and_cold() {
        let w = 20u32;
        let h = 20u32;
        let base = 500u16;
        let mut pixels = vec![base; (w * h) as usize];
        // Hot pixel: far above the median.
        pixels[(5 * w + 5) as usize] = 60_000;
        // Cold/dead pixel: far below the median.
        pixels[(12 * w + 8) as usize] = 0;
        let master = ImageData::from_u16(w, h, 1, &pixels);

        let map =
            build_defect_map_from_master_dark(&master, -200).expect("defect map should build");
        assert_eq!(map.defective_count(), 2);
        assert!(map.is_defective(5, 5), "hot pixel must be flagged");
        assert!(map.is_defective(8, 12), "cold pixel must be flagged");
        assert!(!map.is_defective(0, 0));
        assert_eq!(map.temperature_bucket_decicelsius, -200);
    }

    #[test]
    fn defect_map_from_master_dark_rejects_non_u16() {
        let master = ImageData::from_f32(4, 4, 1, &[0.0; 16]);
        assert!(matches!(
            build_defect_map_from_master_dark(&master, 0),
            Err(MasterCalibrationError::UnsupportedPixelType { .. })
        ));
    }

    // Transient cosmetic correction

    #[test]
    fn cosmetic_correction_detects_and_repairs_hot_pixel() {
        let w = 9u32;
        let h = 9u32;
        let mut pixels = vec![1000u16; (w * h) as usize];
        // Single bright hot pixel in a uniform field.
        pixels[(4 * w + 4) as usize] = 60_000;
        let mut frame = ImageData::from_u16(w, h, 1, &pixels);

        let report = cosmetic_correct_transient(&mut frame, CosmeticConfig::default())
            .expect("cosmetic correction should run");
        assert_eq!(report.hot_repaired, 1);
        assert_eq!(report.cold_repaired, 0);

        let out = frame.as_u16().unwrap();
        // Repaired to the local median (1000).
        assert_eq!(out[(4 * w + 4) as usize], 1000);
    }

    #[test]
    fn cosmetic_correction_handles_cold_pixel() {
        let w = 9u32;
        let h = 9u32;
        let mut pixels = vec![30_000u16; (w * h) as usize];
        // Single dead/cold pixel in a bright uniform field.
        pixels[(4 * w + 4) as usize] = 0;
        let mut frame = ImageData::from_u16(w, h, 1, &pixels);

        let report = cosmetic_correct_transient(&mut frame, CosmeticConfig::default())
            .expect("cosmetic correction should run");
        assert_eq!(report.cold_repaired, 1);
        assert_eq!(report.hot_repaired, 0);

        let out = frame.as_u16().unwrap();
        assert_eq!(out[(4 * w + 4) as usize], 30_000);
    }

    #[test]
    fn cosmetic_correction_preserves_a_real_star() {
        // A small Gaussian star (extended structure) must NOT be flagged: its
        // neighbours are bright too, so the local sigma rises and the centre is
        // not an outlier.
        let w = 15u32;
        let h = 15u32;
        let mut pixels = vec![800u16; (w * h) as usize];
        let cx = 7i32;
        let cy = 7i32;
        let peak = 20_000.0;
        let sigma = 1.5;
        for dy in -3i32..=3 {
            for dx in -3i32..=3 {
                let x = cx + dx;
                let y = cy + dy;
                if x < 0 || x >= w as i32 || y < 0 || y >= h as i32 {
                    continue;
                }
                let r2 = (dx * dx + dy * dy) as f64;
                let v = 800.0 + peak * (-r2 / (2.0 * sigma * sigma)).exp();
                pixels[(y as u32 * w + x as u32) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        let star_peak_before = pixels[(cy as u32 * w + cx as u32) as usize];
        let mut frame = ImageData::from_u16(w, h, 1, &pixels);

        let report = cosmetic_correct_transient(&mut frame, CosmeticConfig::default())
            .expect("cosmetic correction should run");
        let out = frame.as_u16().unwrap();
        // The star peak must survive (the corrector must not nuke it as a hot
        // pixel). We allow that some faint star-skirt pixel could trip on a
        // tiny synthetic frame, but the peak itself must be preserved.
        assert_eq!(
            out[(cy as u32 * w + cx as u32) as usize],
            star_peak_before,
            "a real star core must not be repaired away (report: {:?})",
            report
        );
    }

    #[test]
    fn cosmetic_correction_clean_frame_is_noop() {
        let w = 8u32;
        let h = 8u32;
        let pixels = vec![2500u16; (w * h) as usize];
        let original = pixels.clone();
        let mut frame = ImageData::from_u16(w, h, 1, &pixels);

        let report = cosmetic_correct_transient(&mut frame, CosmeticConfig::default())
            .expect("cosmetic correction should run");
        assert_eq!(report.total(), 0);
        assert_eq!(frame.as_u16().unwrap(), original);
    }

    #[test]
    fn cosmetic_correction_rejects_non_u16() {
        let mut frame = ImageData::from_f32(4, 4, 1, &[0.0; 16]);
        assert!(matches!(
            cosmetic_correct_transient(&mut frame, CosmeticConfig::default()),
            Err(MasterCalibrationError::UnsupportedPixelType { .. })
        ));
    }

    #[test]
    fn cosmetic_correction_rejects_invalid_sigma() {
        let mut frame = flat_image(4, 4, 1000);
        let cfg = CosmeticConfig {
            hot_sigma: 0.0,
            ..CosmeticConfig::default()
        };
        assert!(matches!(
            cosmetic_correct_transient(&mut frame, cfg),
            Err(MasterCalibrationError::InvalidParameter(_))
        ));
    }

    #[test]
    fn defect_map_applied_repairs_full_frame() {
        // Integration-style check: build a defect map from a master dark, then
        // apply it (via the capture-path corrector) to a light that shares the
        // same hot/cold locations.
        let w = 16u32;
        let h = 16u32;
        let base = 600u16;
        let mut dark_pixels = vec![base; (w * h) as usize];
        dark_pixels[(3 * w + 3) as usize] = 65_000; // hot
        dark_pixels[(10 * w + 11) as usize] = 0; // cold
        let master_dark = ImageData::from_u16(w, h, 1, &dark_pixels);
        let map = build_defect_map_from_master_dark(&master_dark, -150).unwrap();
        assert_eq!(map.defective_count(), 2);

        // Light frame with signal + the same two defects.
        let mut light = vec![5000u16; (w * h) as usize];
        light[(3 * w + 3) as usize] = 64_000;
        light[(10 * w + 11) as usize] = 0;
        let corrected = correct_u16_slice(
            &mut light,
            w,
            h,
            1,
            &map,
            CorrectionMethod::Median,
            KernelSize::default(),
        )
        .expect("apply defect map");
        assert_eq!(corrected, 2);
        assert_eq!(light[(3 * w + 3) as usize], 5000);
        assert_eq!(light[(10 * w + 11) as usize], 5000);
    }
}
