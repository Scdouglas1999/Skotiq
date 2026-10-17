//! Rectangular crop, with an auto-proposal from the coverage map registration
//! leaves behind.
//!
//! Registration warps every frame onto a reference grid, so a stack's edges are
//! a ragged band where only some frames contributed — or none did, leaving the
//! integrator's fill value. Cropping that band away is the last linear-stage
//! step: it changes geometry, so the astrometry travels with it.
//!
//! # Astrometry
//!
//! The crop moves the image origin, which moves the WCS reference pixel by the
//! same amount and nothing else. `CRVAL`, the `CD` matrix and any SIP terms
//! describe the plate, not the framing, and are carried through untouched;
//! `NAXIS1`/`NAXIS2`/`NAXIS3` follow the new geometry.
//!
//! # Preview scale
//!
//! `x`, `y`, `width` and `height` are pixels at full resolution. A preview
//! renders over a downsampled level, so the rect is mapped by
//! [`OpContext::scale`]: the origin floors and the far edge ceils, so the
//! previewed region never shows less than the full render does. The rect is
//! intersected with the image, because that rounding can push the far edge one
//! pixel past the level's own size.
//!
//! # Rectangles that do not fit
//!
//! The same intersection also absorbs a rect that genuinely runs off the image —
//! a recipe written over a 1920x1080 master and replayed over a 640x480 one asks
//! for three times the frame and gets the frame. The pixels are not the problem:
//! a recipe replays bit-identical forever, so the clamp stays exactly as it is.
//! What the intersection must not do is stay silent, and it no longer does.
//! [`CropFit::clamped`] separates the two cases — the documented one-pixel
//! rounding from an intersection that cut real area away — and an application
//! that was clamped reports the rect it asked for beside the rect it applied
//! through [`OpApplied::measurement`], so the render report, the export
//! `HISTORY` and the step badge all state the adjustment. `crop_fit` answers the
//! same question before a render, which is how `api_darkroom_validate` warns an
//! editor holding a master the recipe does not fit.

use rayon::prelude::*;
use serde_json::{json, Value};

use crate::recipe::{DarkroomOp, OpApplied, OpContext, OpError, OpImage, OpStage, Params};

/// Largest coordinate or extent, in pixels. No sensor reaches it; it exists so a
/// hand-edited recipe cannot ask for a rect that overflows the geometry maths.
const COORD_MAX: u32 = 1_000_000;

/// Level pixels per axis the intersection may remove before it counts as having
/// changed the framing.
///
/// The far edge ceils, so a rect that ends exactly on the image can land at most
/// one pixel past the level's own size — that single pixel is the rounding the
/// intersection exists for and says nothing about the recipe. Anything past it
/// is area the rect asked for and did not get, which is a fact about this master
/// that the operator has to be told.
const ROUNDING_SLACK: u32 = 1;

/// Crops a rectangle out of linear data and moves the astrometry with it.
pub struct CropV1;

/// One step's validated parameters, in pixels at full resolution.
struct Settings {
    /// Left edge.
    x: u32,
    /// Top edge.
    y: u32,
    /// Width.
    width: u32,
    /// Height.
    height: u32,
}

impl DarkroomOp for CropV1 {
    fn id(&self) -> &'static str {
        "crop"
    }

    fn version(&self) -> u32 {
        1
    }

    fn stage(&self) -> OpStage {
        OpStage::Linear
    }

    fn validate_params(&self, params: &Value) -> Result<(), OpError> {
        self.read_settings(params).map(|_| ())
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
        let settings = self.read_settings(params)?;
        ctx.check_cancel()?;

        let width = image.width();
        let height = image.height();
        let channels = image.channels() as usize;
        let scale = ctx.scale();
        let fit = settings.fit(width, height, scale);

        let (x0, y0) = (fit.applied.x as usize, fit.applied.y as usize);
        if x0 >= width as usize || y0 >= height as usize {
            return Err(OpError::Failed {
                op_id: self.id(),
                op_version: self.version(),
                // The compared origin is the SCALED one, so that is what the
                // message quotes against the level's dimensions. Printing the
                // recipe's full-resolution origin against a downsampled size
                // read as a 20x overshoot at level 3 where the real one is
                // 2.6x — and a zoomed-out preview is exactly where an operator
                // meets this string. The recipe's own numbers follow, labelled
                // as the other space they live in.
                reason: format!(
                    "crop origin ({x0}, {y0}) lies outside the {width}x{height} image at render \
                     level {}: the recipe's full-resolution origin ({}, {}) scaled by {scale}",
                    ctx.level(),
                    settings.x,
                    settings.y
                ),
            });
        }
        let (x1, y1) = (
            (x0 + fit.applied.width as usize),
            (y0 + fit.applied.height as usize),
        );
        if x1 <= x0 || y1 <= y0 {
            return Err(OpError::Failed {
                op_id: self.id(),
                op_version: self.version(),
                // Same rule as the origin above: the emptiness is a fact about
                // the SCALED rectangle, so the message reports the scaled size
                // and names the recipe's rectangle as the source it came from.
                reason: format!(
                    "crop rect scales to {}x{} at render level {}, which covers no pixels of the \
                     {width}x{height} image: the recipe's full-resolution rect is {}x{} at ({}, {})",
                    x1.saturating_sub(x0),
                    y1.saturating_sub(y0),
                    ctx.level(),
                    settings.width,
                    settings.height,
                    settings.x,
                    settings.y
                ),
            });
        }

        let width = width as usize;
        let out_width = x1 - x0;
        let out_height = y1 - y0;
        let out_row = out_width * channels;
        let source_row = width * channels;
        let source = image.data();
        let mut out = vec![0.0_f32; out_row * out_height];
        out.par_chunks_exact_mut(out_row)
            .enumerate()
            .for_each(|(y, row)| {
                if ctx.cancel_requested() {
                    return;
                }
                let start = (y + y0) * source_row + x0 * channels;
                row.copy_from_slice(&source[start..start + out_row]);
            });
        ctx.check_cancel()?;

        let mut cropped =
            image.with_geometry(out_width as u32, out_height as u32, channels as u32, out)?;
        cropped.translate_reference_pixel(x0 as f64, y0 as f64);
        Ok(OpApplied {
            image: cropped,
            measurement: fit.measurement(ctx.level()),
        })
    }
}

impl CropV1 {
    /// Read and range-check one step's payload. `validate_params` and `apply`
    /// share this, so the two can never disagree about a default.
    ///
    /// `width` and `height` are required: the whole image is a different size at
    /// every master, so "the whole image" is not a constant a default could
    /// freeze.
    fn read_settings(&self, params: &Value) -> Result<Settings, OpError> {
        let p = Params::new(self, params)?;
        p.allow(&["x", "y", "width", "height"])?;
        Ok(Settings {
            x: p.u32_or("x", 0..=COORD_MAX, 0)?,
            y: p.u32_or("y", 0..=COORD_MAX, 0)?,
            width: p.u32_required("width", 1..=COORD_MAX)?,
            height: p.u32_required("height", 1..=COORD_MAX)?,
        })
    }
}

impl Settings {
    /// Where this rectangle lands on a `width` x `height` image rendered at
    /// `scale`.
    ///
    /// The only place the mapping and the intersection are written: `apply`
    /// crops what this returns, and [`crop_fit`] answers the pre-render question
    /// from it, so the warning an editor shows and the pixels a render produces
    /// cannot describe different rectangles.
    fn fit(&self, width: u32, height: u32, scale: f64) -> CropFit {
        let x0 = (self.x as f64 * scale).floor() as u32;
        let y0 = (self.y as f64 * scale).floor() as u32;
        let x1 = ((self.x as f64 + self.width as f64) * scale).ceil() as u32;
        let y1 = ((self.y as f64 + self.height as f64) * scale).ceil() as u32;
        CropFit {
            requested: CropRect {
                x: x0,
                y: y0,
                width: x1.saturating_sub(x0),
                height: y1.saturating_sub(y0),
            },
            applied: CropRect {
                x: x0,
                y: y0,
                width: x1.min(width).saturating_sub(x0),
                height: y1.min(height).saturating_sub(y0),
            },
            image_width: width,
            image_height: height,
            recipe_rect: CropRect {
                x: self.x,
                y: self.y,
                width: self.width,
                height: self.height,
            },
        }
    }
}

/// Where a `crop@1` payload's rectangle lands on an image, at full resolution.
///
/// The pre-render half of the same question `apply` answers: given the base
/// master's geometry, does the recipe's rectangle fit, and what would a render
/// produce if it does not. `api_darkroom_validate` walks a step list with it so
/// the editor can warn about a rect the master cannot hold before any pixels
/// move.
///
/// # Errors
///
/// [`OpError`] when `params` is not a valid `crop@1` payload — the same
/// rejection [`DarkroomOp::validate_params`] makes.
pub fn crop_fit(params: &Value, width: u32, height: u32) -> Result<CropFit, OpError> {
    Ok(CropV1.read_settings(params)?.fit(width, height, 1.0))
}

/// How one crop rectangle lands on one image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CropFit {
    /// The rectangle the step asks for, in the rendered image's own pixels.
    pub requested: CropRect,
    /// The part of it that lies on the image — the rectangle a render crops.
    pub applied: CropRect,
    /// Width of the image the rectangle was measured against.
    pub image_width: u32,
    /// Height of the image the rectangle was measured against.
    pub image_height: u32,
    /// The step's own rectangle, in full-resolution pixels. Equal to
    /// `requested` at level 0, and the number an operator reading the recipe
    /// sees at every level.
    pub recipe_rect: CropRect,
}

impl CropFit {
    /// Whether the origin lies off the image, which no render can crop: the step
    /// fails typed rather than producing a rectangle.
    pub fn origin_outside(&self) -> bool {
        self.applied.x >= self.image_width || self.applied.y >= self.image_height
    }

    /// Whether the intersection cut away more than the far edge's rounding —
    /// that is, whether the rectangle the render used is a different framing
    /// from the one the recipe asked for. See [`ROUNDING_SLACK`].
    pub fn clamped(&self) -> bool {
        self.requested.width.saturating_sub(self.applied.width) > ROUNDING_SLACK
            || self.requested.height.saturating_sub(self.applied.height) > ROUNDING_SLACK
    }

    /// The render report's detail for a clamped application: the rectangle asked
    /// for beside the one applied, and the image that decided it. `None` when
    /// the rectangle fit, because then the step's own parameters describe its
    /// result in full.
    fn measurement(&self, level: u32) -> Option<Value> {
        if !self.clamped() {
            return None;
        }
        Some(json!({
            "clampedToImage": {
                "level": level,
                "imageWidth": self.image_width,
                "imageHeight": self.image_height,
                "requested": self.requested.to_params(),
                "applied": self.applied.to_params(),
                "recipeRect": self.recipe_rect.to_params(),
            }
        }))
    }

    /// What happened to this rectangle, in the words a reader gets in the render
    /// report, the exported `HISTORY` and the editor's pre-render warning.
    pub fn statement(&self) -> String {
        if self.origin_outside() {
            return format!(
                "crop origin ({}, {}) lies outside the {}x{} image, so the render cannot run \
                 this step",
                self.recipe_rect.x, self.recipe_rect.y, self.image_width, self.image_height
            );
        }
        format!(
            "crop asks for {}x{} at ({}, {}), which does not fit the {}x{} image: the render \
             applies {}x{} at ({}, {})",
            self.recipe_rect.width,
            self.recipe_rect.height,
            self.recipe_rect.x,
            self.recipe_rect.y,
            self.image_width,
            self.image_height,
            self.applied.width,
            self.applied.height,
            self.applied.x,
            self.applied.y
        )
    }
}

/// A crop rectangle in pixels, in the coordinate system of the image it was
/// proposed from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CropRect {
    /// Left edge.
    pub x: u32,
    /// Top edge.
    pub y: u32,
    /// Width.
    pub width: u32,
    /// Height.
    pub height: u32,
}

impl CropRect {
    /// The step parameter object this rectangle describes.
    pub fn to_params(&self) -> Value {
        json!({
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
        })
    }
}

/// Which edge of the working rectangle a shrink step removes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Edge {
    /// The first row.
    Top,
    /// The last row.
    Bottom,
    /// The first column.
    Left,
    /// The last column.
    Right,
}

/// Propose the largest fully covered rectangle in `image`.
///
/// A pixel is **covered** when every one of its channels is finite and at least
/// one is not exactly zero. Registration writes `NaN` or the integrator's zero
/// fill outside a frame's own footprint, while a genuine sky sample in linear
/// ADU sits on a pedestal and is never exactly zero, so the two are separable
/// without a threshold.
///
/// The proposal starts at the whole frame and repeatedly removes whichever edge
/// row or column carries the smallest covered fraction, stopping once all four
/// edges are wholly covered. Ties resolve top, bottom, left, right. Returns
/// `None` when no rectangle survives, which is what an entirely uncovered frame
/// deserves — never a fabricated rect.
///
/// The rectangle is in `image`'s own pixels. `crop@1` reads its parameters at
/// full resolution, so the proposal is made from the full-resolution master.
pub fn auto_rect(image: &OpImage) -> Option<CropRect> {
    let width = image.width() as usize;
    let height = image.height() as usize;
    let channels = image.channels() as usize;

    let covered: Vec<bool> = image
        .data()
        .par_chunks_exact(channels)
        .map(|pixel| {
            pixel.iter().all(|value| value.is_finite()) && pixel.iter().any(|value| *value != 0.0)
        })
        .collect();

    let (mut x0, mut x1) = (0usize, width);
    let (mut y0, mut y1) = (0usize, height);
    loop {
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        let row_span = x1 - x0;
        let column_span = y1 - y0;
        let candidates = [
            (
                row_covered(&covered, width, y0, x0, x1),
                row_span,
                Edge::Top,
            ),
            (
                row_covered(&covered, width, y1 - 1, x0, x1),
                row_span,
                Edge::Bottom,
            ),
            (
                column_covered(&covered, width, x0, y0, y1),
                column_span,
                Edge::Left,
            ),
            (
                column_covered(&covered, width, x1 - 1, y0, y1),
                column_span,
                Edge::Right,
            ),
        ];
        if candidates
            .iter()
            .all(|(covered_count, span, _)| covered_count == span)
        {
            break;
        }

        let mut worst = candidates[0];
        for candidate in candidates.iter().skip(1) {
            if (candidate.0 as u64) * (worst.1 as u64) < (worst.0 as u64) * (candidate.1 as u64) {
                worst = *candidate;
            }
        }
        match worst.2 {
            Edge::Top => y0 += 1,
            Edge::Bottom => y1 -= 1,
            Edge::Left => x0 += 1,
            Edge::Right => x1 -= 1,
        }
    }

    Some(CropRect {
        x: x0 as u32,
        y: y0 as u32,
        width: (x1 - x0) as u32,
        height: (y1 - y0) as u32,
    })
}

/// Covered pixels in row `y` between columns `x0` and `x1`.
fn row_covered(covered: &[bool], width: usize, y: usize, x0: usize, x1: usize) -> usize {
    covered[y * width + x0..y * width + x1]
        .iter()
        .filter(|value| **value)
        .count()
}

/// Covered pixels in column `x` between rows `y0` and `y1`.
fn column_covered(covered: &[bool], width: usize, x: usize, y0: usize, y1: usize) -> usize {
    (y0..y1).filter(|y| covered[y * width + x]).count()
}

#[cfg(test)]
#[path = "crop_tests.rs"]
mod crop_tests;
