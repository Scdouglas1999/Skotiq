//! Planning a color composite: which of a target's masters combine, how they
//! register onto one another, and the `channel_combine@1` step that makes it.
//!
//! The plan is measured once, at full resolution, when the draft is composed.
//! Everything it measured — the palette, each master's registration transform,
//! the overlap rectangle — is written into the step's parameters, so a render
//! replays the stored geometry instead of solving it again.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{json, Value};

use skotiq_imaging::color_composite::{
    alignment_check, overlap_rect, plan_filter_set, register_onto, star_sigma, warp_window,
    Affine2, FilterRole, FilterSetInput, Palette, PyramidSources, Rect,
};
use skotiq_imaging::recipe::{MasterSource, OpContext, OpImage, Recipe, RecipeStep};

use super::state::{base_pyramid, LoadedMaster};

/// One master offered to a composite.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CompositeInputArgs {
    pub(crate) path: String,
    /// The filter name; the FITS `FILTER` card is read when absent.
    pub(crate) filter: Option<String>,
    /// Total integration seconds; the FITS `EXPTIME` card when absent.
    pub(crate) integration_seconds: Option<f64>,
}

/// A composite request.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CompositeArgs {
    pub(crate) inputs: Vec<CompositeInputArgs>,
    /// One of the plan's alternatives, instead of the conventional default.
    pub(crate) palette: Option<String>,
}

/// Pixels of source support kept between the overlap rectangle and the edge of
/// every master, so the Lanczos window never leaves a master's own pixels.
const OVERLAP_MARGIN_PX: f64 = 4.0;
/// Largest alignment the overlap rectangle is rounded to.
const MAX_ALIGNMENT: u32 = 64;
/// Side of the central window the registration check resamples.
const CHECK_WINDOW_PX: u32 = 2048;

/// A planned composite, ready to draft.
pub(crate) struct PlannedComposite {
    /// The reference master's path and pyramid: the recipe's base.
    pub(crate) reference_path: String,
    pub(crate) reference: LoadedMaster,
    /// Every other master the step reads.
    pub(crate) sources: Arc<PyramidSources>,
    /// The `channel_combine@1` step, fits not yet pinned.
    pub(crate) step: RecipeStep,
    /// The account of the plan, for the report.
    pub(crate) report: Value,
}

/// The outcome of planning: a composite, or the reason there is none.
pub(crate) enum CompositeOutcome {
    Planned(Box<PlannedComposite>),
    NotCombined(Value),
}

struct Loaded {
    path: String,
    filter: Option<String>,
    seconds: f64,
    master: LoadedMaster,
}

fn header_filter(image: &OpImage) -> Option<String> {
    image
        .header()
        .get_string("FILTER")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Plan a composite from `args`.
pub(crate) fn plan(args: &CompositeArgs) -> Result<CompositeOutcome, String> {
    if args.inputs.is_empty() {
        return Err("a composite needs at least one master".to_string());
    }
    let mut loaded = Vec::with_capacity(args.inputs.len());
    for input in &args.inputs {
        let master = base_pyramid(std::path::Path::new(input.path.trim()))?;
        let base = master.pyramid.base();
        let filter = input
            .filter
            .clone()
            .filter(|f| !f.trim().is_empty())
            .or_else(|| header_filter(base));
        let seconds = input
            .integration_seconds
            .or_else(|| base.header().get_float("EXPTIME"))
            .unwrap_or(0.0);
        loaded.push(Loaded {
            path: input.path.trim().to_string(),
            filter,
            seconds,
            master,
        });
    }

    let preferred = match args.palette.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(token) => Some(Palette::from_wire(token).ok_or_else(|| {
            format!(
                "unknown palette '{token}'; expected one of {}",
                Palette::WIRE.join(", ")
            )
        })?),
    };
    let set: Vec<FilterSetInput> = loaded
        .iter()
        .map(|l| FilterSetInput {
            filter: l.filter.clone(),
            channels: l.master.pyramid.base().channels(),
            integration_seconds: l.seconds,
        })
        .collect();
    let plan = plan_filter_set(&set, preferred);
    let describe = |index: usize| {
        json!({
            "path": loaded[index].path,
            "filter": loaded[index].filter,
            "integrationSeconds": loaded[index].seconds,
        })
    };
    let excluded: Vec<Value> = plan
        .excluded
        .iter()
        .map(|(index, reason)| {
            let mut entry = describe(*index);
            entry["reason"] = json!(reason);
            entry
        })
        .collect();
    let alternatives: Vec<Value> = plan
        .alternatives
        .iter()
        .map(|p| json!({"palette": p.as_wire(), "name": p.display_name()}))
        .collect();

    let (Some(palette), Some(reference_index)) = (plan.palette, plan.reference) else {
        return Ok(CompositeOutcome::NotCombined(json!({
            "combined": false,
            "reason": plan.reason,
            "alternatives": alternatives,
            "excluded": excluded,
        })));
    };

    let reference = &loaded[reference_index];
    let reference_image = Arc::clone(reference.master.pyramid.base());
    let (ref_w, ref_h) = (reference_image.width(), reference_image.height());
    let ctx = OpContext::new();

    let mut inputs_json: Vec<Value> = Vec::new();
    let mut report_inputs: Vec<(usize, Value)> = Vec::new();
    let mut geometry: Vec<(usize, Affine2)> = Vec::new();
    for planned in &plan.used {
        let entry = &loaded[planned.index];
        let image = entry.master.pyramid.base();
        if planned.index == reference_index {
            geometry.push((planned.index, Affine2::IDENTITY));
            continue;
        }
        let alignment = register_onto(&reference_image, image, &ctx).map_err(|reason| {
            format!(
                "the {} master could not be registered onto the {} reference: {reason}",
                entry.filter.as_deref().unwrap_or("unnamed"),
                reference.filter.as_deref().unwrap_or("unnamed")
            )
        })?;
        geometry.push((planned.index, alignment.transform));
        report_inputs.push((
            planned.index,
            json!({
                "path": entry.path,
                "filter": entry.filter,
                "role": planned.role.as_wire(),
                "model": alignment.model,
                "starsMatched": alignment.inliers,
                "fitRmsPx": alignment.rms_px,
                "rotationDeg": alignment.transform.rotation_deg(),
                "scale": alignment.transform.scale(),
                "shiftPx": [alignment.transform.m[2], alignment.transform.m[5]],
            }),
        ));
    }

    let alignment = MAX_ALIGNMENT.min(1 << (reference.master.pyramid.level_count() - 1).min(6));
    let footprints: Vec<(Affine2, u32, u32)> = geometry
        .iter()
        .map(|(index, transform)| {
            let base = loaded[*index].master.pyramid.base();
            (*transform, base.width(), base.height())
        })
        .collect();
    let crop =
        overlap_rect(ref_w, ref_h, &footprints, OVERLAP_MARGIN_PX, alignment).ok_or_else(|| {
            "the registered masters share no common area, so there is nothing to combine"
                .to_string()
        })?;

    // The registration check: star centroid offsets between the reference and
    // each resampled master, over a central window of the overlap.
    let window = Rect {
        x: crop.x + crop.width.saturating_sub(CHECK_WINDOW_PX) / 2,
        y: crop.y + crop.height.saturating_sub(CHECK_WINDOW_PX) / 2,
        width: crop.width.min(CHECK_WINDOW_PX),
        height: crop.height.min(CHECK_WINDOW_PX),
    };
    let reference_window = window_image(&reference_image, window)?;
    let mut checks = Vec::new();
    for (index, transform) in &geometry {
        if *index == reference_index {
            continue;
        }
        let image = loaded[*index].master.pyramid.base();
        let warped = warp_window(image, transform, window, &ctx).map_err(|e| e.to_string())?;
        let warped = OpImage::new(
            window.width,
            window.height,
            image.channels(),
            warped,
            reference_window.header().clone(),
        )
        .map_err(|e| e.to_string())?;
        let check = alignment_check(&reference_window, &warped, &ctx).map_err(|e| e.to_string())?;
        let value = match check {
            Some(c) => json!({
                "stars": c.stars,
                "medianOffsetPx": c.median_px,
                "rmsOffsetPx": c.rms_px,
                "meanOffsetPx": [c.mean_dx, c.mean_dy],
            }),
            None => Value::Null,
        };
        if let Some((_, entry)) = report_inputs.iter_mut().find(|(i, _)| i == index) {
            entry["check"] = value.clone();
        }
        checks.push(value);
    }

    let mut sources = PyramidSources::new();
    for planned in &plan.used {
        let (index, transform) = geometry
            .iter()
            .find(|(i, _)| *i == planned.index)
            .copied()
            .expect("every used input has a geometry");
        let entry = &loaded[index];
        let base = entry.master.pyramid.base();
        let mut spec = json!({
            "role": planned.role.as_wire(),
            "filter": entry.filter,
            "path": entry.path,
            "width": base.width(),
            "height": base.height(),
        });
        if index == reference_index {
            spec["reference"] = json!(true);
        } else {
            spec["transform"] = json!(transform.m.to_vec());
            sources.insert(
                entry.path.clone(),
                entry.master.identity.clone(),
                Arc::clone(&entry.master.pyramid),
            );
        }
        inputs_json.push(spec);
    }

    // Each color role's star profile, so the luminance layer can bring the
    // three channels' stars to one size before reading color from them.
    let mut sigmas = serde_json::Map::new();
    let mut sigma_report = serde_json::Map::new();
    for planned in &plan.used {
        let role = planned.role.as_wire();
        if sigmas.contains_key(role) || planned.role == FilterRole::Luminance {
            continue;
        }
        let image = loaded[planned.index].master.pyramid.base();
        if let Some(sigma) = star_sigma(image, &ctx).map_err(|e| e.to_string())? {
            sigmas.insert(role.to_string(), json!(sigma));
            sigma_report.insert(role.to_string(), json!(sigma * 1.177_410_022_515_474_6));
        }
    }
    let mut params = json!({
        "palette": palette.as_wire(),
        "inputs": inputs_json,
        "crop": {"x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height},
    });
    if palette.uses_luminance() && !sigmas.is_empty() {
        params["starSigma"] = Value::Object(sigmas);
    }
    let worst_check = checks
        .iter()
        .filter_map(|c| c["medianOffsetPx"].as_f64())
        .fold(0.0_f64, f64::max);
    let report = json!({
        "combined": true,
        "palette": palette.as_wire(),
        "paletteName": palette.display_name(),
        "reason": plan.reason,
        "alternatives": alternatives,
        "excluded": excluded,
        "reference": {
            "path": reference.path,
            "filter": reference.filter,
            "role": plan.used.iter().find(|p| p.index == reference_index).map(|p| p.role.as_wire()),
        },
        "inputs": report_inputs.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
        "crop": {"x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height},
        "referenceSize": {"width": ref_w, "height": ref_h},
        "worstMedianOffsetPx": worst_check,
        "starHfrPx": Value::Object(sigma_report),
        "luminance": if palette.uses_luminance() {
            json!("the luminance master sets each pixel's lightness and the RGB masters its color, applied in linear space before a color-preserving stretch")
        } else {
            Value::Null
        },
    });

    let reference_path = reference.path.clone();
    let reference_master = LoadedMaster {
        pyramid: Arc::clone(&reference.master.pyramid),
        identity: reference.master.identity.clone(),
    };
    Ok(CompositeOutcome::Planned(Box::new(PlannedComposite {
        reference_path,
        reference: reference_master,
        sources: Arc::new(sources),
        step: RecipeStep::new("channel_combine", 1).with_params(params),
        report,
    })))
}

fn window_image(image: &OpImage, window: Rect) -> Result<OpImage, String> {
    let channels = image.channels() as usize;
    let width = image.width() as usize;
    let mut data = Vec::with_capacity(window.width as usize * window.height as usize * channels);
    for y in window.y as usize..(window.y + window.height) as usize {
        let start = (y * width + window.x as usize) * channels;
        data.extend_from_slice(&image.data()[start..start + window.width as usize * channels]);
    }
    image
        .with_geometry(window.width, window.height, image.channels(), data)
        .map_err(|e| e.to_string())
}

/// The masters an enabled `channel_combine@1` step in `recipe` reads beyond its
/// base, loaded for the render; `None` when the recipe has no such step.
///
/// They are loaded before the render takes the render-cache lock, which is
/// the lock order [`super::state`] requires.
pub(crate) fn sources_for(recipe: &Recipe) -> Result<Option<Arc<dyn MasterSource>>, String> {
    let mut sources = PyramidSources::new();
    for step in &recipe.steps {
        if !step.enabled || step.op_id != "channel_combine" {
            continue;
        }
        let Some(inputs) = step.params.get("inputs").and_then(Value::as_array) else {
            continue;
        };
        for input in inputs {
            if input.get("reference").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let Some(path) = input.get("path").and_then(Value::as_str) else {
                continue;
            };
            let master = base_pyramid(std::path::Path::new(path)).map_err(|e| {
                let role = input
                    .get("role")
                    .and_then(Value::as_str)
                    .and_then(FilterRole::from_wire)
                    .map(|r| r.short_name())
                    .unwrap_or_else(|| "a".to_string());
                format!("the {role} master this composite combines cannot be read: {e}")
            })?;
            sources.insert(path, master.identity, master.pyramid);
        }
    }
    Ok(if sources.is_empty() {
        None
    } else {
        Some(Arc::new(sources) as Arc<dyn MasterSource>)
    })
}
