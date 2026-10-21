//! A target's per-filter masters combined into one color image, as a recipe
//! step.
//!
//! The base master is the reference the other masters were registered onto
//! (the luminance master for LRGB); the rest are named in the parameters by path
//! and read through the render's [`MasterSource`](crate::recipe::MasterSource).
//! Their geometry is stored, not re-solved: each input carries the master →
//! reference transform the draft measured, and `crop` is the rectangle every
//! master covers. Nothing about the masters changes on disk, so the step can be
//! edited, disabled or re-run like any other.
//!
//! # What it computes
//!
//! 1. Every input is resampled onto the reference grid inside `crop` with
//!    clamped Lanczos-3 (see [`crate::color_composite::align`]).
//! 2. Several masters of one filter (several sessions) are scaled onto the
//!    first of them and averaged by inverse noise variance.
//! 3. The palette maps the filters onto red, green and blue, in linear space and
//!    without any normalization of its own — the channel balance is
//!    `color_calibrate`'s job, after `background_extract` has flattened each
//!    channel, as PixInsight's ChannelCombination leaves it.
//!    * `rgb` / `lrgb`: R, G and B as recorded.
//!    * `haRgb` / `haLrgb`: Ha, scaled onto red so stars match, blended into red
//!      by `haRedWeight` (and into the luminance by `haLuminanceWeight`).
//!    * `sho`: SII → red, Ha → green, OIII → blue; `hoo`: Ha → red, OIII → green
//!      and blue. OIII and SII are scaled onto Ha so stars come out neutral.
//!    * `osc`: one-shot-color masters averaged.
//! 4. For `lrgb` and `haLrgb` the luminance master, fitted onto the RGB's own
//!    luminance, sets each pixel's lightness and the RGB its chromaticity
//!    ([`crate::color_composite::mix::apply_luminance`]).
//!
//! # Deviation from PixInsight, and why
//!
//! PixInsight applies the luminance after both images are stretched
//! (LRGBCombination replaces CIE L* of the stretched RGB). A recipe carries one
//! image through its steps, so here the luminance is applied in linear space and
//! the color image is then stretched with `stretch@1`'s color-preserving
//! `luminance` mode. Lightness from L and chromaticity from RGB is the same
//! split; the luminance also receives the background extraction and the noise
//! reduction the rest of the recipe applies, which is what a PixInsight user
//! does to L by hand.
//!
//! # Pinned measurements
//!
//! The flux fits are value-domain measurements. A step without `fits` measures
//! them from the image it is handed and reports them; a draft measures at full
//! resolution and pins the answer, so every preview level renders the same
//! balance.

use serde::Deserialize;
use serde_json::{json, Map, Value};

use crate::color_composite::align::{warp_window, Affine2, Rect};
use crate::color_composite::filters::{FilterRole, Palette};
use crate::color_composite::mix::{
    apply_luminance, blend, psf_match_sigmas, robust_fit, weighted_mean, LinearFit,
};
use crate::recipe::{DarkroomOp, OpApplied, OpContext, OpError, OpImage, OpStage};

/// Registry id.
const OP_ID: &str = "channel_combine";
/// Registry version.
const OP_VERSION: u32 = 1;

/// Default blur of the chromaticity in [`apply_luminance`], in full-resolution
/// pixels.
pub const CHROMA_SMOOTHING_DEFAULT: f64 = 1.0;
/// Largest chromaticity blur accepted.
const CHROMA_SMOOTHING_MAX: f64 = 8.0;
/// Default share of Ha in the red channel.
pub const HA_RED_WEIGHT_DEFAULT: f64 = 0.5;
/// Default share of Ha in the luminance.
pub const HA_LUMINANCE_WEIGHT_DEFAULT: f64 = 0.3;

/// Combines registered per-filter masters into a color image.
pub struct ChannelCombineV1;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct InputSpec {
    role: String,
    #[serde(default)]
    filter: Option<String>,
    path: String,
    width: u32,
    height: u32,
    #[serde(default)]
    reference: bool,
    #[serde(default)]
    transform: Option<Vec<f64>>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
struct CropSpec {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
struct FitSpec {
    scale: f64,
    offset: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct RawParams {
    palette: String,
    inputs: Vec<InputSpec>,
    crop: CropSpec,
    #[serde(default)]
    fits: Option<std::collections::BTreeMap<String, FitSpec>>,
    #[serde(default)]
    chroma_smoothing: Option<f64>,
    #[serde(default)]
    star_sigma: Option<std::collections::BTreeMap<String, f64>>,
    #[serde(default)]
    ha_red_weight: Option<f64>,
    #[serde(default)]
    ha_luminance_weight: Option<f64>,
}

/// One input, validated.
struct Input {
    role: FilterRole,
    filter: Option<String>,
    path: String,
    width: u32,
    height: u32,
    reference: bool,
    transform: Affine2,
}

/// One step's validated parameters.
struct Settings {
    palette: Palette,
    inputs: Vec<Input>,
    reference: usize,
    crop: Rect,
    fits: Option<std::collections::BTreeMap<String, LinearFit>>,
    chroma_smoothing: f64,
    star_sigma: std::collections::BTreeMap<String, f64>,
    ha_red_weight: f64,
    ha_luminance_weight: f64,
}

fn invalid(reason: impl Into<String>) -> OpError {
    OpError::Failed {
        op_id: OP_ID,
        op_version: OP_VERSION,
        reason: reason.into(),
    }
}

fn range(key: &str, value: f64, lo: f64, hi: f64) -> Result<f64, OpError> {
    if value.is_finite() && (lo..=hi).contains(&value) {
        Ok(value)
    } else {
        Err(OpError::ParamRange {
            op_id: OP_ID,
            op_version: OP_VERSION,
            key: key.to_string(),
            value: value.to_string(),
            range: format!("[{lo}, {hi}]"),
        })
    }
}

/// The roles each palette reads.
fn palette_roles(palette: Palette, inputs: &[Input]) -> Vec<FilterRole> {
    let rgb_from_color = inputs.iter().any(|i| i.role == FilterRole::Color)
        && !inputs.iter().any(|i| i.role == FilterRole::Red);
    let mut rgb = if rgb_from_color {
        vec![FilterRole::Color]
    } else {
        vec![FilterRole::Red, FilterRole::Green, FilterRole::Blue]
    };
    match palette {
        Palette::Rgb => rgb,
        Palette::Lrgb => {
            rgb.push(FilterRole::Luminance);
            rgb
        }
        Palette::HaRgb => {
            rgb.push(FilterRole::HAlpha);
            rgb
        }
        Palette::HaLrgb => {
            rgb.push(FilterRole::HAlpha);
            rgb.push(FilterRole::Luminance);
            rgb
        }
        Palette::Sho => vec![FilterRole::Sii, FilterRole::HAlpha, FilterRole::Oiii],
        Palette::Hoo => vec![FilterRole::HAlpha, FilterRole::Oiii],
        Palette::Osc => vec![FilterRole::Color],
    }
}

fn read_settings(params: &Value) -> Result<Settings, OpError> {
    if !params.is_object() {
        return Err(OpError::ParamsNotObject {
            op_id: OP_ID,
            op_version: OP_VERSION,
            found: match params {
                Value::Null => "null",
                Value::Array(_) => "an array",
                _ => "a scalar",
            },
        });
    }
    let raw: RawParams = serde_json::from_value(params.clone()).map_err(|e| {
        invalid(format!(
            "the parameters do not describe a channel combination: {e}"
        ))
    })?;
    let palette = Palette::from_wire(&raw.palette).ok_or_else(|| OpError::ParamRange {
        op_id: OP_ID,
        op_version: OP_VERSION,
        key: "palette".to_string(),
        value: raw.palette.clone(),
        range: Palette::WIRE.join(", "),
    })?;
    let mut inputs = Vec::with_capacity(raw.inputs.len());
    for (index, spec) in raw.inputs.iter().enumerate() {
        let role = FilterRole::from_wire(&spec.role).ok_or_else(|| {
            invalid(format!(
                "input {} names an unknown role '{}'",
                index + 1,
                spec.role
            ))
        })?;
        if spec.width == 0 || spec.height == 0 {
            return Err(invalid(format!("input {} has no size", index + 1)));
        }
        if spec.path.trim().is_empty() {
            return Err(invalid(format!("input {} names no master", index + 1)));
        }
        let transform = match (&spec.transform, spec.reference) {
            (None, true) => Affine2::IDENTITY,
            (Some(values), _) => Affine2::from_slice(values).ok_or_else(|| {
                invalid(format!(
                    "input {} carries a transform that is not six finite numbers of a non-singular map",
                    index + 1
                ))
            })?,
            (None, false) => {
                return Err(invalid(format!(
                    "input {} is not the reference and carries no registration transform",
                    index + 1
                )))
            }
        };
        if spec.reference && !transform.is_identity() {
            return Err(invalid(
                "the reference input must carry the identity transform",
            ));
        }
        inputs.push(Input {
            role,
            filter: spec.filter.clone(),
            path: spec.path.clone(),
            width: spec.width,
            height: spec.height,
            reference: spec.reference,
            transform,
        });
    }
    let references: Vec<usize> = inputs
        .iter()
        .enumerate()
        .filter(|(_, i)| i.reference)
        .map(|(n, _)| n)
        .collect();
    let [reference] = references[..] else {
        return Err(invalid(format!(
            "exactly one input must be the reference; {} are",
            references.len()
        )));
    };
    for role in palette_roles(palette, &inputs) {
        if !inputs.iter().any(|i| i.role == role) {
            return Err(invalid(format!(
                "{} needs a {} master and none is listed",
                palette.display_name(),
                role.short_name()
            )));
        }
    }
    let needed = palette_roles(palette, &inputs);
    if let Some(extra) = inputs.iter().find(|i| !needed.contains(&i.role)) {
        return Err(invalid(format!(
            "{} has no place for a {} master",
            palette.display_name(),
            extra.role.short_name()
        )));
    }
    let reference_input = &inputs[reference];
    let crop = Rect {
        x: raw.crop.x,
        y: raw.crop.y,
        width: raw.crop.width,
        height: raw.crop.height,
    };
    if crop.width == 0
        || crop.height == 0
        || crop.x.saturating_add(crop.width) > reference_input.width
        || crop.y.saturating_add(crop.height) > reference_input.height
    {
        return Err(invalid(format!(
            "the crop {}x{} at ({}, {}) does not lie inside the {}x{} reference",
            crop.width, crop.height, crop.x, crop.y, reference_input.width, reference_input.height
        )));
    }
    let fits = match raw.fits {
        None => None,
        Some(map) => {
            let mut out = std::collections::BTreeMap::new();
            for (key, fit) in map {
                if !fit.scale.is_finite() || fit.scale <= 0.0 || !fit.offset.is_finite() {
                    return Err(invalid(format!(
                        "the fit '{key}' must have a positive finite scale and a finite offset"
                    )));
                }
                out.insert(
                    key,
                    LinearFit {
                        scale: fit.scale,
                        offset: fit.offset,
                    },
                );
            }
            Some(out)
        }
    };
    Ok(Settings {
        palette,
        inputs,
        reference,
        crop,
        fits,
        chroma_smoothing: range(
            "chromaSmoothing",
            raw.chroma_smoothing.unwrap_or(CHROMA_SMOOTHING_DEFAULT),
            0.0,
            CHROMA_SMOOTHING_MAX,
        )?,
        star_sigma: {
            let mut out = std::collections::BTreeMap::new();
            for (role, sigma) in raw.star_sigma.unwrap_or_default() {
                if FilterRole::from_wire(&role).is_none() {
                    return Err(invalid(format!("starSigma names an unknown role '{role}'")));
                }
                out.insert(role, range("starSigma", sigma, 0.0, 50.0)?);
            }
            out
        },
        ha_red_weight: range(
            "haRedWeight",
            raw.ha_red_weight.unwrap_or(HA_RED_WEIGHT_DEFAULT),
            0.0,
            1.0,
        )?,
        ha_luminance_weight: range(
            "haLuminanceWeight",
            raw.ha_luminance_weight
                .unwrap_or(HA_LUMINANCE_WEIGHT_DEFAULT),
            0.0,
            1.0,
        )?,
    })
}

/// The full-resolution size of the image a step with `params` produces, or
/// `None` when the parameters do not describe a combination.
pub fn output_size(params: &Value) -> Option<(u32, u32)> {
    read_settings(params)
        .ok()
        .map(|settings| (settings.crop.width, settings.crop.height))
}

/// The size of a `width × height` image at pyramid level `level`.
fn dims_at_level(width: u32, height: u32, level: u32) -> (u32, u32) {
    let (mut w, mut h) = (width, height);
    for _ in 0..level {
        w = w.div_ceil(2);
        h = h.div_ceil(2);
    }
    (w, h)
}

/// The fits a render used, measured or pinned, keyed as the parameters store
/// them.
struct Fits<'a> {
    pinned: Option<&'a std::collections::BTreeMap<String, LinearFit>>,
    used: std::collections::BTreeMap<String, LinearFit>,
}

impl Fits<'_> {
    /// The pinned fit `key`, or one measured from `x` onto `y`.
    fn get(&mut self, key: &str, x: &[f32], y: &[f32], what: &str) -> Result<LinearFit, OpError> {
        let fit = match self.pinned.and_then(|map| map.get(key)) {
            Some(fit) => *fit,
            None => robust_fit(x, y).ok_or_else(|| {
                invalid(format!(
                    "{what}: the two masters share too few star or object pixels above the sky to match their flux scales"
                ))
            })?,
        };
        self.used.insert(key.to_string(), fit);
        Ok(fit)
    }
}

fn mapped(plane: &[f32], fit: LinearFit) -> Vec<f32> {
    plane.iter().map(|v| fit.apply(*v)).collect()
}

impl DarkroomOp for ChannelCombineV1 {
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
        let level = ctx.level();
        let reference = &settings.inputs[settings.reference];
        let expected = dims_at_level(reference.width, reference.height, level);
        if (image.width(), image.height()) != expected {
            return Err(invalid(format!(
                "the base image is {}x{} at level {level}, but the reference master is {}x{} ({}x{} at this level); render this step over the reference master",
                image.width(),
                image.height(),
                reference.width,
                reference.height,
                expected.0,
                expected.1
            )));
        }
        let crop = settings.crop.at_level(level);
        if crop.x + crop.width > image.width() || crop.y + crop.height > image.height() {
            return Err(invalid(
                "the crop falls outside the base image at this level",
            ));
        }
        let width = crop.width as usize;
        let height = crop.height as usize;

        // Every input resampled onto the crop window, one plane per channel.
        let mut planes: Vec<Vec<Vec<f32>>> = Vec::with_capacity(settings.inputs.len());
        for (index, input) in settings.inputs.iter().enumerate() {
            ctx.check_cancel()?;
            if input.reference {
                planes.push(deinterleave(
                    &crop_window(image, crop),
                    image.channels() as usize,
                ));
                continue;
            }
            let source = {
                let sources = ctx.sources().ok_or_else(|| OpError::Unavailable {
                    op_id: OP_ID,
                    op_version: OP_VERSION,
                    reason: "this render was given no masters beyond the base, so the other filters cannot be read".to_string(),
                })?;
                let loaded = sources.level(&input.path, level).map_err(invalid)?;
                let expected = dims_at_level(input.width, input.height, level);
                if (loaded.width(), loaded.height()) != expected {
                    return Err(invalid(format!(
                        "input {} ('{}') is {}x{} at level {level} but was registered as {}x{} ({}x{} at this level); the master changed since the step was drafted",
                        index + 1,
                        input.path,
                        loaded.width(),
                        loaded.height(),
                        input.width,
                        input.height,
                        expected.0,
                        expected.1
                    )));
                }
                if input.role == FilterRole::Color && loaded.channels() != 3 {
                    return Err(invalid(format!(
                        "input {} is listed as one-shot color but has {} channel(s)",
                        index + 1,
                        loaded.channels()
                    )));
                }
                if input.role != FilterRole::Color && loaded.channels() != 1 {
                    return Err(invalid(format!(
                        "input {} is listed as a {} master but has {} channels",
                        index + 1,
                        input.role.short_name(),
                        loaded.channels()
                    )));
                }
                loaded
            };
            let interleaved = warp_window(&source, &input.transform.at_level(level), crop, ctx)?;
            planes.push(deinterleave(&interleaved, source.channels() as usize));
        }
        ctx.check_cancel()?;

        let mut fits = Fits {
            pinned: settings.fits.as_ref(),
            used: std::collections::BTreeMap::new(),
        };

        // One plane set per role: several sessions scaled onto the first.
        let mut by_role: std::collections::BTreeMap<FilterRole, Vec<Vec<f32>>> =
            std::collections::BTreeMap::new();
        let mut primary: std::collections::BTreeMap<FilterRole, usize> =
            std::collections::BTreeMap::new();
        for (index, input) in settings.inputs.iter().enumerate() {
            let first = *primary.entry(input.role.clone()).or_insert(index);
            if first == index {
                continue;
            }
            let key = format!("session{index}");
            let fit = fits.get(
                &key,
                &mean_plane(&planes[index]),
                &mean_plane(&planes[first]),
                &format!("matching input {} to input {}", index + 1, first + 1),
            )?;
            for channel in planes[index].iter_mut() {
                *channel = mapped(channel, fit);
            }
        }
        for (role, first) in &primary {
            let members: Vec<usize> = settings
                .inputs
                .iter()
                .enumerate()
                .filter(|(_, i)| &i.role == role)
                .map(|(n, _)| n)
                .collect();
            let channels = planes[*first].len();
            let combined: Vec<Vec<f32>> = (0..channels)
                .map(|c| {
                    let set: Vec<Vec<f32>> =
                        members.iter().map(|m| planes[*m][c].clone()).collect();
                    weighted_mean(&set)
                })
                .collect();
            by_role.insert(role.clone(), combined);
        }
        drop(planes);
        ctx.check_cancel()?;

        let take =
            |role: FilterRole| -> Vec<Vec<f32>> { by_role.get(&role).cloned().unwrap_or_default() };
        let rgb_from = |by_role: &std::collections::BTreeMap<FilterRole, Vec<Vec<f32>>>| -> Option<[Vec<f32>; 3]> {
            if let Some(color) = by_role.get(&FilterRole::Color) {
                if let (Some(r), Some(g), Some(b)) = (color.first(), color.get(1), color.get(2)) {
                    return Some([r.clone(), g.clone(), b.clone()]);
                }
            }
            match (
                by_role.get(&FilterRole::Red),
                by_role.get(&FilterRole::Green),
                by_role.get(&FilterRole::Blue),
            ) {
                (Some(r), Some(g), Some(b)) => Some([r[0].clone(), g[0].clone(), b[0].clone()]),
                _ => None,
            }
        };

        let [mut red, mut green, mut blue] = match settings.palette {
            Palette::Rgb | Palette::Lrgb | Palette::HaRgb | Palette::HaLrgb | Palette::Osc => {
                rgb_from(&by_role).ok_or_else(|| {
                    invalid("the palette's red, green and blue masters are missing")
                })?
            }
            Palette::Sho => {
                let ha = take(FilterRole::HAlpha).remove(0);
                let s = take(FilterRole::Sii).remove(0);
                let o = take(FilterRole::Oiii).remove(0);
                let fs = fits.get("siiToHAlpha", &s, &ha, "matching SII to Ha")?;
                let fo = fits.get("oiiiToHAlpha", &o, &ha, "matching OIII to Ha")?;
                [mapped(&s, fs), ha, mapped(&o, fo)]
            }
            Palette::Hoo => {
                let ha = take(FilterRole::HAlpha).remove(0);
                let o = take(FilterRole::Oiii).remove(0);
                let fo = fits.get("oiiiToHAlpha", &o, &ha, "matching OIII to Ha")?;
                let o = mapped(&o, fo);
                [ha, o.clone(), o]
            }
        };

        let mut luminance = by_role.get(&FilterRole::Luminance).map(|l| l[0].clone());
        if matches!(settings.palette, Palette::HaRgb | Palette::HaLrgb) {
            let ha = take(FilterRole::HAlpha).remove(0);
            let fr = fits.get("hAlphaToRed", &ha, &red, "matching Ha to red")?;
            red = blend(&red, &mapped(&ha, fr), settings.ha_red_weight);
            if settings.palette == Palette::HaLrgb {
                if let Some(l) = luminance.take() {
                    let fl =
                        fits.get("hAlphaToLuminance", &ha, &l, "matching Ha to the luminance")?;
                    luminance = Some(blend(&l, &mapped(&ha, fl), settings.ha_luminance_weight));
                }
            }
        }
        ctx.check_cancel()?;

        if settings.palette.uses_luminance() {
            let l =
                luminance.ok_or_else(|| invalid("the palette's luminance master is missing"))?;
            let y: Vec<f32> = (0..l.len())
                .map(|i| ((red[i] as f64 + green[i] as f64 + blue[i] as f64) / 3.0) as f32)
                .collect();
            let fit = fits.get(
                "luminanceToRgb",
                &l,
                &y,
                "matching the luminance to the RGB",
            )?;
            let l = mapped(&l, fit);
            let sigma = chroma_sigmas(&settings).map(|s| s * ctx.scale());
            [red, green, blue] = apply_luminance([&red, &green, &blue], &l, width, height, sigma);
        }
        ctx.check_cancel()?;

        let mut out = vec![0.0_f32; width * height * 3];
        for (i, pixel) in out.as_chunks_mut::<3>().0.iter_mut().enumerate() {
            *pixel = [red[i], green[i], blue[i]];
        }
        let mut combined = image.with_geometry(crop.width, crop.height, 3, out)?;
        combined.translate_reference_pixel(crop.x as f64, crop.y as f64);
        let header = combined.header_mut();
        header.set_string("FILTER", settings.palette.display_name());
        if header.get("NAXIS").is_some() {
            header.set_int("NAXIS", 3);
            header.set_int("NAXIS3", 3);
        }

        let mut fit_json = Map::new();
        for (key, fit) in &fits.used {
            fit_json.insert(
                key.clone(),
                json!({"scale": fit.scale, "offset": fit.offset}),
            );
        }
        let measurement = json!({
            "palette": settings.palette.as_wire(),
            "inputs": settings
                .inputs
                .iter()
                .map(|i| json!({"role": i.role.as_wire(), "filter": i.filter}))
                .collect::<Vec<_>>(),
            "fits": Value::Object(fit_json),
            "fitsPinned": settings.fits.as_ref().is_some_and(|f| !f.is_empty()),
        });
        Ok(OpApplied::measured(combined, measurement))
    }
}

/// The chromaticity blur of each color channel, in full-resolution pixels:
/// the PSF match that brings the three channels' stars to one profile, then
/// `chromaSmoothing` on top, added in quadrature.
///
/// A channel whose stars are narrower than another's would otherwise color
/// every star's core with its own channel and its wings with the other, since
/// each pixel's color is the ratio of the channels there.
fn chroma_sigmas(settings: &Settings) -> [f64; 3] {
    let sigma_of = |roles: &[FilterRole]| {
        roles
            .iter()
            .find_map(|r| settings.star_sigma.get(r.as_wire()).copied())
    };
    let color = sigma_of(&[FilterRole::Color]);
    let measured = [
        sigma_of(&[FilterRole::Red]).or(color),
        sigma_of(&[FilterRole::Green]).or(color),
        sigma_of(&[FilterRole::Blue]).or(color),
    ];
    let matched = match measured {
        [Some(r), Some(g), Some(b)] => psf_match_sigmas([r, g, b]),
        _ => [0.0; 3],
    };
    matched.map(|m| (m * m + settings.chroma_smoothing * settings.chroma_smoothing).sqrt())
}

fn crop_window(image: &OpImage, crop: Rect) -> Vec<f32> {
    let channels = image.channels() as usize;
    let width = image.width() as usize;
    let data = image.data();
    let mut out = Vec::with_capacity(crop.width as usize * crop.height as usize * channels);
    for y in crop.y as usize..(crop.y + crop.height) as usize {
        let start = (y * width + crop.x as usize) * channels;
        out.extend_from_slice(&data[start..start + crop.width as usize * channels]);
    }
    out
}

fn deinterleave(data: &[f32], channels: usize) -> Vec<Vec<f32>> {
    if channels == 1 {
        return vec![data.to_vec()];
    }
    (0..channels)
        .map(|c| data.iter().skip(c).step_by(channels).copied().collect())
        .collect()
}

fn mean_plane(channels: &[Vec<f32>]) -> Vec<f32> {
    if channels.len() == 1 {
        return channels[0].clone();
    }
    let n = channels.len() as f64;
    (0..channels[0].len())
        .map(|i| (channels.iter().map(|c| c[i] as f64).sum::<f64>() / n) as f32)
        .collect()
}

#[cfg(test)]
#[path = "channel_combine_tests.rs"]
mod channel_combine_tests;
