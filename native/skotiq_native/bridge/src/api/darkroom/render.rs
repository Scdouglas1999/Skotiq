//! Replaying a recipe over a master, and turning the result into the RGBA
//! buffer the viewer already takes.
//!
//! # The display seam
//!
//! `AstroImageViewer` decodes an RGBA `Uint8List` plus a width and a height —
//! the same shape `api_apply_stretch` hands it for a captured frame. A Darkroom
//! preview therefore returns RGBA bytes and reuses that path whole; no new
//! decoding, caching or transform plumbing appears on the Dart side.
//!
//! What it does **not** reuse is the display stretch behind that path.
//! `auto_stretch_stf` decodes its input as `u16` pairs with no pixel-type check,
//! and masters are `F32`, so the existing screen transfer reads a master's bytes
//! as numbers that are not in it. Every pixel here comes from the recipe
//! engine's own `F32` arithmetic.
//!
//! # Encodings
//!
//! A render's samples are in one of two domains, and the reply always names
//! which one it encoded and how:
//!
//! * **stretched** — an enabled `Stretched`-stage step applied, so samples are
//!   display-domain and map to `[0, 255]` directly.
//! * **linear** — the stack stopped before the stretch (or has none), so samples
//!   are linear ADU with no display meaning. `screen` then applies the engine's
//!   own auto transfer *for viewing only*, and the reply carries the parameters
//!   it used so the editor can say so.

use std::sync::Arc;

use serde_json::{json, Value};
use skotiq_imaging::recipe::ops::stretch::{auto_params, StretchV1};
use skotiq_imaging::recipe::{
    render, DarkroomOp, ImagePyramid, OpContext, OpImage, OpRegistry, OpStage, Recipe, RecipeError,
    RenderOptions, RenderOutput, StepOutcome,
};

use super::args::{CancelledRender, CatalogStarArgs};
use super::catalog::SuppliedCatalog;
use super::state::{base_pyramid, registry, render_cache, LoadedMaster, RenderCancelToken};

/// How a render's samples become 8-bit RGBA.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PreviewEncoding {
    /// Encode the domain the render actually produced: `unit` for a stretched
    /// render, `screen` for one still in linear ADU.
    Auto,
    /// Map `[0, 1]` to `[0, 255]`, clamping outside it and reporting how many
    /// samples were clamped.
    Unit,
    /// Apply the engine's own auto stretch to the rendered pixels for viewing
    /// only, then encode as `unit`. The stored recipe is untouched.
    Screen,
}

impl PreviewEncoding {
    /// Read the wire token. An unrecognised token is an error rather than a
    /// silent fall back to a transfer the caller did not ask for.
    pub(crate) fn parse(token: &str) -> Result<Self, String> {
        match token.trim() {
            "" | "auto" => Ok(Self::Auto),
            "unit" => Ok(Self::Unit),
            "screen" => Ok(Self::Screen),
            other => Err(format!(
                "unknown preview encoding '{other}'; expected auto/unit/screen"
            )),
        }
    }

    /// The `camelCase` wire token.
    fn as_wire(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Unit => "unit",
            Self::Screen => "screen",
        }
    }
}

/// Decode a recipe from its wire JSON.
pub(crate) fn parse_recipe(recipe_json: &str) -> Result<Recipe, String> {
    Recipe::from_json(recipe_json).map_err(|e| e.to_string())
}

/// The master at `master_path` — its pyramid and the identity of the bytes read
/// — honouring cancellation around the read.
///
/// The identity travels back to the caller because the render it is about to
/// run has to key its step boundaries on the master it actually read, not on the
/// `baseMasterRef` the recipe was authored with.
pub(crate) fn load_pyramid(
    master_path: &str,
    token: &RenderCancelToken,
) -> Result<LoadedMaster, String> {
    let path = master_path.trim();
    if path.is_empty() {
        return Err("masterPath is required to render".to_string());
    }
    if token.is_cancelled() {
        return Err(CancelledRender::err(token.render_id(), "read"));
    }
    let master = base_pyramid(std::path::Path::new(path))?;
    if token.is_cancelled() {
        return Err(CancelledRender::err(token.render_id(), "pyramid"));
    }
    Ok(master)
}

/// The pyramid level a request resolves to.
///
/// An explicit `level` wins. Otherwise `maxDimension` picks the coarsest level
/// still at least that large, so the preview is never upscaled. With neither,
/// the render runs at full resolution.
pub(crate) fn resolve_level(
    pyramid: &ImagePyramid,
    level: Option<u32>,
    max_dimension: Option<u32>,
) -> Result<u32, String> {
    match (level, max_dimension) {
        (Some(explicit), _) => {
            if explicit >= pyramid.level_count() {
                return Err(format!(
                    "pyramid level {explicit} is out of range; this master has {} level{}",
                    pyramid.level_count(),
                    if pyramid.level_count() == 1 { "" } else { "s" }
                ));
            }
            Ok(explicit)
        }
        (None, Some(max_dimension)) => Ok(pyramid.level_for_max_dimension(max_dimension)),
        (None, None) => Ok(0),
    }
}

/// The context a render runs under: the cancel flag, the level, the base's own
/// astrometry, and the caller's photometry.
///
/// The star list needs no cache bookkeeping here: the engine's step-boundary key
/// carries `SuppliedCatalog::identity`, so a request with different stars keys
/// differently and the boundaries computed under the previous list stay
/// reachable for the next request that supplies it.
pub(crate) fn build_context(
    recipe: &Recipe,
    base: &OpImage,
    level: u32,
    token: &RenderCancelToken,
    catalog_stars: &[CatalogStarArgs],
) -> Result<(OpContext, usize), String> {
    let mut ctx = OpContext::new().with_cancel(token.flag()).at_level(level);
    if let Some(sources) = super::composite::sources_for(recipe)? {
        ctx = ctx.with_sources(sources);
    }
    if let Some(wcs) = base.wcs() {
        ctx = ctx.with_wcs(wcs);
    }
    let mut star_count = 0usize;
    if let Some(catalog) = SuppliedCatalog::new(catalog_stars) {
        star_count = catalog.len();
        ctx = ctx.with_catalog(catalog.into_handle());
    }
    Ok((ctx, star_count))
}

/// Replay `recipe` over `base`, mapping a cancelled render to the typed
/// cancelled payload.
pub(crate) fn run_render(
    recipe: &Recipe,
    base: &Arc<OpImage>,
    ctx: &OpContext,
    options: RenderOptions,
    token: &RenderCancelToken,
) -> Result<RenderOutput, String> {
    let registry = registry()?;
    let mut cache = render_cache();
    match render(recipe, base, registry, &mut cache, ctx, options) {
        Ok(output) => Ok(output),
        Err(RecipeError::Cancelled) => Err(CancelledRender::err(token.render_id(), "render")),
        Err(other) => Err(other.to_string()),
    }
}

/// Whether the render left the linear stage: an enabled step that applied and
/// emits display-domain data.
fn is_stretched_domain(output: &RenderOutput, registry: &OpRegistry) -> bool {
    output.report.steps.iter().any(|step| {
        matches!(step.outcome, StepOutcome::Applied)
            && registry
                .get(&step.op_id, step.op_version)
                .is_some_and(|op| op.stage() == OpStage::Stretched)
    })
}

/// A render encoded for the viewer.
pub(crate) struct EncodedPreview {
    /// RGBA8, row-major, four bytes per pixel.
    pub(crate) rgba: Vec<u8>,
    pub(crate) width: u32,
    pub(crate) height: u32,
    /// Whether the source render carried colour channels.
    pub(crate) is_color: bool,
    /// What the encoding did, for the reply.
    pub(crate) description: Value,
}

/// Uncalibrated RGB needs independent display transfers: filter throughput and
/// sky offsets otherwise dominate the preview. A measured color balance keeps
/// one shared transfer so viewing does not undo that balance.
pub(crate) fn screen_transfer(
    image: &OpImage,
    ctx: &OpContext,
    color_balanced: bool,
) -> Result<(OpImage, Value), String> {
    if image.channels() != 3 || color_balanced {
        let params = auto_params(image).map_err(|e| e.to_string())?.to_params();
        let result = StretchV1
            .apply(image, &params, ctx)
            .map_err(|e| e.to_string())?;
        return Ok((result, params));
    }
    let mut data = vec![0.0; image.len()];
    let mut transfers = Vec::with_capacity(3);
    for channel in 0..3 {
        ctx.check_cancel().map_err(|e| e.to_string())?;
        let mono = OpImage::new(
            image.width(),
            image.height(),
            1,
            image.data().chunks_exact(3).map(|p| p[channel]).collect(),
            image.header().clone(),
        )
        .map_err(|e| e.to_string())?;
        let params = auto_params(&mono).map_err(|e| e.to_string())?.to_params();
        let stretched = StretchV1
            .apply(&mono, &params, ctx)
            .map_err(|e| e.to_string())?;
        for (pixel, &sample) in data.chunks_exact_mut(3).zip(stretched.data()) {
            pixel[channel] = sample;
        }
        transfers.push(params);
    }
    Ok((
        image.with_data(data).map_err(|e| e.to_string())?,
        json!({"mode": "unlinked", "channels": transfers}),
    ))
}

/// Encode a render as RGBA for the viewer.
///
/// The chosen transfer is named in [`EncodedPreview::description`] together with
/// the number of samples clamped, so a caller never has to guess whether what it
/// is looking at was lifted for display.
pub(crate) fn encode_preview(
    output: &RenderOutput,
    encoding: PreviewEncoding,
    ctx: &OpContext,
    token: &RenderCancelToken,
    measure_only: bool,
) -> Result<EncodedPreview, String> {
    let registry = registry()?;
    let stretched = is_stretched_domain(output, registry);
    let resolved = match encoding {
        PreviewEncoding::Auto => {
            if stretched {
                PreviewEncoding::Unit
            } else {
                PreviewEncoding::Screen
            }
        }
        explicit => explicit,
    };

    if token.is_cancelled() {
        return Err(CancelledRender::err(token.render_id(), "encode"));
    }

    if measure_only {
        let screen_params = match resolved {
            PreviewEncoding::Screen => Some(
                auto_params(&output.image)
                    .map_err(|e| e.to_string())?
                    .to_params(),
            ),
            _ => None,
        };
        return Ok(EncodedPreview {
            rgba: Vec::new(),
            width: output.image.width(),
            height: output.image.height(),
            is_color: output.image.channels() >= 3,
            description: json!({
                "requested": encoding.as_wire(),
                "applied": "none",
                "sourceDomain": if stretched { "stretched" } else { "linear" },
                "clampedSamples": 0,
                "screenTransfer": screen_params,
                "screenTransferAffectsRecipe": false,
                "measureOnly": true,
            }),
        });
    }

    let (image, screen_params) = match resolved {
        PreviewEncoding::Screen => {
            let color_balanced = output.report.steps.iter().any(|step| {
                step.op_id == "color_calibrate" && matches!(step.outcome, StepOutcome::Applied)
            });
            let (stretched_image, payload) = screen_transfer(&output.image, ctx, color_balanced)?;
            (Arc::new(stretched_image), Some(payload))
        }
        _ => (Arc::clone(&output.image), None),
    };

    let (rgba, clamped) = rgba_from_unit(&image)?;
    let description = json!({
        "requested": encoding.as_wire(),
        "applied": if screen_params.is_some() { "screen" } else { "unit" },
        "sourceDomain": if stretched { "stretched" } else { "linear" },
        "clampedSamples": clamped,
        "screenTransfer": screen_params,
        "screenTransferAffectsRecipe": false,
    });

    Ok(EncodedPreview {
        rgba,
        width: image.width(),
        height: image.height(),
        is_color: image.channels() >= 3,
        description,
    })
}

/// Quantise `[0, 1]` samples to RGBA8, returning the buffer and how many
/// samples fell outside the unit range.
///
/// A mono image is replicated across R, G and B, matching what the viewer
/// expects for a single-channel frame. A four-channel image contributes its
/// first three channels; any other layout is an error, because inventing a
/// mapping for it would show a picture whose colours no operation produced.
pub(crate) fn rgba_from_unit(image: &OpImage) -> Result<(Vec<u8>, usize), String> {
    let channels = image.channels() as usize;
    let pixels = image.pixel_count();
    let data = image.data();
    let mut rgba = vec![255u8; pixels * 4];
    let mut clamped = 0usize;

    match channels {
        1 => {
            for (index, sample) in data.iter().enumerate() {
                let grey = quantise_unit(*sample, 255.0, &mut clamped) as u8;
                rgba[index * 4] = grey;
                rgba[index * 4 + 1] = grey;
                rgba[index * 4 + 2] = grey;
            }
        }
        3 | 4 => {
            for index in 0..pixels {
                for channel in 0..3 {
                    let sample = data[index * channels + channel];
                    rgba[index * 4 + channel] = quantise_unit(sample, 255.0, &mut clamped) as u8;
                }
            }
        }
        other => {
            return Err(format!(
                "a {other}-channel render has no display encoding; the viewer takes 1 (mono), 3 (RGB) or 4 (RGBA) channels"
            ))
        }
    }

    Ok((rgba, clamped))
}

/// Quantise one `[0, 1]` sample onto `[0, full_scale]`, counting a sample that
/// was outside the unit range or not finite.
///
/// A non-finite sample maps to zero and is counted: an operation that produced
/// one has produced no displayable value, and reporting the count is how that
/// reaches the caller instead of appearing as a black pixel with no explanation.
pub(crate) fn quantise_unit(value: f32, full_scale: f64, clamped: &mut usize) -> f64 {
    let sample = value as f64;
    if !sample.is_finite() || !(0.0..=1.0).contains(&sample) {
        *clamped += 1;
    }
    let bounded = if sample.is_finite() {
        sample.clamp(0.0, 1.0)
    } else {
        0.0
    };
    (bounded * full_scale).round()
}

/// The level description a reply carries so the editor can state the scale it is
/// looking at rather than infer one.
pub(crate) fn level_json(pyramid: &ImagePyramid, level: u32, base: &OpImage) -> Value {
    json!({
        "level": level,
        "levelCount": pyramid.level_count(),
        "width": base.width(),
        "height": base.height(),
        "channels": base.channels(),
        "scaleFromMaster": 1.0 / (1u64 << level.min(63)) as f64,
    })
}
