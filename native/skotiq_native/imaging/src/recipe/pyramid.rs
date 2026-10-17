//! The power-of-two downsample pyramid a preview renders over.
//!
//! Level `0` is the base master. Level `n` is a `2^n` box downsample of it. The
//! pyramid is built once per base image; a parameter drag replays the operation
//! stack over one level, so the downsample cost is paid once instead of per
//! frame.
//!
//! # Astrometry
//!
//! Each level's header is rewritten so the level's WCS describes the level's
//! grid: `NAXIS1`/`NAXIS2` shrink, `CRPIX` moves to `(crpix + 0.5) / 2`, the
//! `CD` matrix doubles, and SIP coefficients scale by `2^(i+j-1)`. Those are the
//! exact transforms for the FITS 1-based pixel convention, where output pixel
//! `j` covers input pixels `2j-1` and `2j` and so sits at input coordinate
//! `2j - 0.5`.

use std::sync::Arc;

use crate::fits::FitsHeader;

use super::model::{OpError, OpImage};

/// A level is not downsampled further once its shorter side reaches this.
pub const DEFAULT_MIN_PYRAMID_DIMENSION: u32 = 64;

/// The levels of one base image, coarsening by a factor of two.
#[derive(Debug, Clone)]
pub struct ImagePyramid {
    levels: Vec<Arc<OpImage>>,
}

impl ImagePyramid {
    /// Build down to [`DEFAULT_MIN_PYRAMID_DIMENSION`].
    pub fn build(base: Arc<OpImage>) -> Result<Self, OpError> {
        Self::build_with_min_dimension(base, DEFAULT_MIN_PYRAMID_DIMENSION)
    }

    /// Build until the shorter side would drop below `min_dimension`.
    ///
    /// A `min_dimension` of `0` is raised to `1`; a base already smaller than
    /// the floor yields a single-level pyramid.
    pub fn build_with_min_dimension(
        base: Arc<OpImage>,
        min_dimension: u32,
    ) -> Result<Self, OpError> {
        if base.is_empty() {
            return Err(OpError::EmptyImage);
        }
        let floor = min_dimension.max(1);
        let mut levels = vec![base];
        loop {
            let current = levels.last().ok_or(OpError::EmptyImage)?;
            if current.width() / 2 < floor || current.height() / 2 < floor {
                break;
            }
            let next = downsample_2x(current)?;
            levels.push(Arc::new(next));
        }
        Ok(Self { levels })
    }

    /// Number of levels, always at least one.
    pub fn level_count(&self) -> u32 {
        self.levels.len() as u32
    }

    /// The image at `level`, or `None` when the pyramid does not go that deep.
    pub fn level(&self, level: u32) -> Option<&Arc<OpImage>> {
        self.levels.get(level as usize)
    }

    /// The base image (level `0`).
    pub fn base(&self) -> &Arc<OpImage> {
        &self.levels[0]
    }

    /// The coarsest level whose longer side is still at least `max_dimension`,
    /// or the coarsest level the pyramid holds.
    ///
    /// This is the level to render a viewport of `max_dimension` pixels: it is
    /// never smaller than the viewport, so the preview is not upscaled.
    pub fn level_for_max_dimension(&self, max_dimension: u32) -> u32 {
        let target = max_dimension.max(1);
        let mut chosen = 0u32;
        for (index, image) in self.levels.iter().enumerate() {
            if image.width().max(image.height()) >= target {
                chosen = index as u32;
            } else {
                break;
            }
        }
        chosen
    }

    /// Total bytes of pixel data held across every level.
    pub fn byte_size(&self) -> usize {
        self.levels.iter().map(|level| level.byte_size()).sum()
    }
}

/// Halve an image with a box filter, rewriting the header's geometry and
/// astrometry to match.
///
/// An odd dimension yields a final output pixel averaged over the single input
/// pixel that remains, so no row or column is dropped.
pub fn downsample_2x(image: &OpImage) -> Result<OpImage, OpError> {
    let width = image.width() as usize;
    let height = image.height() as usize;
    let channels = image.channels() as usize;
    if width < 2 && height < 2 {
        return Err(OpError::GeometryMismatch {
            width: image.width(),
            height: image.height(),
            channels: image.channels(),
            expected: 2,
            found: width.min(height),
        });
    }
    let out_width = width.div_ceil(2);
    let out_height = height.div_ceil(2);
    let src = image.data();
    let mut out = vec![0.0_f32; out_width * out_height * channels];

    for oy in 0..out_height {
        let y0 = oy * 2;
        let y1 = (y0 + 1).min(height - 1);
        let rows = if y0 == y1 { 1 } else { 2 };
        for ox in 0..out_width {
            let x0 = ox * 2;
            let x1 = (x0 + 1).min(width - 1);
            let cols = if x0 == x1 { 1 } else { 2 };
            let count = (rows * cols) as f64;
            for c in 0..channels {
                let mut sum = 0.0_f64;
                for y in [y0, y1].iter().take(rows) {
                    for x in [x0, x1].iter().take(cols) {
                        sum += src[(y * width + x) * channels + c] as f64;
                    }
                }
                out[(oy * out_width + ox) * channels + c] = (sum / count) as f32;
            }
        }
    }

    let mut header = image.header().clone();
    scale_header_for_downsample(&mut header, out_width as u32, out_height as u32);
    OpImage::new(
        out_width as u32,
        out_height as u32,
        channels as u32,
        out,
        header,
    )
}

/// Rewrite a header for a factor-of-two downsample: geometry keywords, the
/// reference pixel, the `CD` matrix, and any SIP coefficients.
fn scale_header_for_downsample(header: &mut FitsHeader, out_width: u32, out_height: u32) {
    if header.get("NAXIS1").is_some() {
        header.set_int("NAXIS1", out_width as i64);
    }
    if header.get("NAXIS2").is_some() {
        header.set_int("NAXIS2", out_height as i64);
    }
    for key in ["CRPIX1", "CRPIX2"] {
        if let Some(crpix) = header.get_float(key) {
            header.set_float(key, (crpix + 0.5) / 2.0);
        }
    }
    for key in ["CD1_1", "CD1_2", "CD2_1", "CD2_2"] {
        if let Some(cd) = header.get_float(key) {
            header.set_float(key, cd * 2.0);
        }
    }
    for prefix in ["A", "B", "AP", "BP"] {
        scale_sip_polynomial(header, prefix);
    }
}

/// Scale one SIP polynomial for a factor-of-two downsample.
///
/// The polynomial maps pixel offsets to pixel offsets, so halving the grid
/// scales term `(i, j)` by `2^(i+j) / 2`.
fn scale_sip_polynomial(header: &mut FitsHeader, prefix: &str) {
    let order = header
        .get_int(&format!("{prefix}_ORDER"))
        .unwrap_or(0)
        .max(0) as u32;
    if order == 0 {
        return;
    }
    let n = (order + 1) as usize;
    for i in 0..n {
        for j in 0..n {
            let key = format!("{prefix}_{i}_{j}");
            if let Some(coeff) = header.get_float(&key) {
                let exponent = (i + j) as i32 - 1;
                header.set_float(&key, coeff * 2.0_f64.powi(exponent));
            }
        }
    }
}

#[cfg(test)]
#[path = "pyramid_tests.rs"]
mod pyramid_tests;
