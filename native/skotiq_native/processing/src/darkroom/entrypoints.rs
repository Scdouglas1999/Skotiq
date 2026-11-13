//! The Darkroom FFI entry points.

use serde_json::{json, Value};

use skotiq_imaging::recipe::ops::crop::{crop_fit, CropRect};
use skotiq_imaging::recipe::{Recipe, RenderOptions, RECIPE_SCHEMA_VERSION};

use crate::darkroom::args::{
    report_json, DarkroomCancelArgs, DarkroomCancelResult, DarkroomContextArgs, DarkroomExportArgs,
    DarkroomRegistryArgs,
};
use crate::darkroom::export::run_export;
use crate::darkroom::render::{
    build_context, encode_preview, level_json, load_pyramid, parse_recipe, resolve_level,
    run_render, PreviewEncoding,
};
use crate::darkroom::schema::{draft_for_master, ops_json};
use crate::darkroom::state::{
    registry, render_cache, BASE_CACHE_CAPACITY_BYTES, RENDERS, RENDER_CACHE_CAPACITY_BYTES,
};

/// A rendered preview in the shape the viewer already takes.
///
/// `rgba` is row-major RGBA8, four bytes per pixel — the same buffer
/// `AstroImageViewer` decodes for a captured frame, so the editor shows a render
/// through the existing display path rather than a second one.
#[derive(Debug, Clone)]
pub struct DarkroomPreview {
    /// Width of the rendered level in pixels.
    pub width: u32,
    /// Height of the rendered level in pixels.
    pub height: u32,
    /// Whether the render carried colour channels.
    pub is_color: bool,
    /// Row-major RGBA8 samples, four bytes per pixel.
    pub rgba: Vec<u8>,
    /// JSON: the render report (every step and its outcome, including the reason
    /// a step was skipped), the pyramid level and its scale, the encoding that
    /// was applied, and the cache's accounting.
    pub report_json: String,
}

/// The work behind the bridge's `api_darkroom_validate`, which describes the request
/// and the reply.
pub fn darkroom_validate(recipe_json: String, context_json: String) -> Result<String, String> {
    let context: DarkroomContextArgs = serde_json::from_str(&context_json)
        .map_err(|e| format!("invalid darkroom context: {e}"))?;
    let recipe = parse_recipe(&recipe_json)?;
    let registry = registry()?;

    let verdict = skotiq_imaging::recipe::validate(&recipe, registry);
    let mut steps = Vec::with_capacity(recipe.steps.len());
    for (index, step) in recipe.steps.iter().enumerate() {
        let mut entry = json!({
            "index": index,
            "opId": step.op_id,
            "opVersion": step.op_version,
            "enabled": step.enabled,
        });
        match registry.get(&step.op_id, step.op_version) {
            None => {
                entry["registered"] = json!(false);
                entry["valid"] = json!(false);
                entry["error"] = json!(format!(
                    "no operation registered as {}@{}",
                    step.op_id, step.op_version
                ));
                if let Some(latest) = registry.latest_version(&step.op_id) {
                    entry["latestVersion"] = json!(latest);
                }
            }
            Some(op) => {
                entry["registered"] = json!(true);
                entry["stage"] = json!(op.stage().as_wire());
                match op.validate_params(&step.params) {
                    Ok(()) => {
                        entry["valid"] = json!(true);
                    }
                    Err(error) => {
                        entry["valid"] = json!(false);
                        entry["error"] = json!(error.to_string());
                    }
                }
            }
        }
        steps.push(entry);
    }

    let mut reply = json!({
        "ok": verdict.is_ok(),
        "error": verdict.err().map(|e| e.to_string()),
        "recipeId": recipe.id,
        "baseMasterRef": recipe.base_master_ref,
        "schemaVersion": RECIPE_SCHEMA_VERSION,
        "steps": steps,
        "geometryChecked": false,
        "findings": Vec::<Value>::new(),
    });

    if !context.master_path.trim().is_empty() {
        let token = RENDERS.register("")?;
        let master = load_pyramid(&context.master_path, &token)?;
        let base = master.pyramid.base();
        reply["base"] = json!({
            "path": context.master_path,
            "width": base.width(),
            "height": base.height(),
            "channels": base.channels(),
            "hasWcs": base.wcs().is_some(),
            "levelCount": master.pyramid.level_count(),
        });
        reply["geometryChecked"] = json!(true);
        reply["findings"] = json!(geometry_findings(&recipe, base.width(), base.height()));
    }

    serde_json::to_string(&reply).map_err(|e| format!("failed to encode result: {e}"))
}

/// Every step whose rectangle does not fit the pixels it would be replayed over.
///
/// The working geometry starts at the base master's full resolution and follows
/// the render: `crop@1` is the one registered operation that changes it, so each
/// enabled crop is measured against what the steps above it left, and then hands
/// on the rectangle a render would actually produce. A disabled step is not
/// applied and neither changes the geometry nor earns a finding — it is not part
/// of this render, and enabling it is what puts it back on the path.
///
/// A step whose parameters do not parse is already reported as invalid by the
/// per-step pass; there is no rectangle to measure, so it contributes nothing
/// here and leaves the geometry untouched, which is the same thing a failed
/// render would do.
fn geometry_findings(recipe: &Recipe, base_width: u32, base_height: u32) -> Vec<Value> {
    let mut findings = Vec::new();
    let (mut width, mut height) = (base_width, base_height);
    for (index, step) in recipe.steps.iter().enumerate() {
        if step.enabled && step.op_id == "channel_combine" && step.op_version == 1 {
            // The combination crops to the area every master covers.
            if let Some((w, h)) =
                skotiq_imaging::recipe::ops::channel_combine::output_size(&step.params)
            {
                width = w;
                height = h;
            }
            continue;
        }
        if !step.enabled || step.op_id != "crop" || step.op_version != 1 {
            continue;
        }
        let Ok(fit) = crop_fit(&step.params, width, height) else {
            continue;
        };
        if fit.origin_outside() || fit.clamped() {
            findings.push(json!({
                "index": index,
                "opId": step.op_id,
                "opVersion": step.op_version,
                "kind": if fit.origin_outside() { "cropOriginOutsideImage" } else { "cropDoesNotFit" },
                "message": fit.statement(),
                "imageWidth": fit.image_width,
                "imageHeight": fit.image_height,
                "requested": rect_json(&fit.recipe_rect),
                "applied": rect_json(&fit.applied),
            }));
        }
        if fit.origin_outside() {
            // The render fails typed at this step, so nothing below it runs and
            // there is no geometry to carry on with.
            break;
        }
        width = fit.applied.width;
        height = fit.applied.height;
    }
    findings
}

/// One rectangle as wire JSON.
fn rect_json(rect: &CropRect) -> Value {
    json!({
        "x": rect.x,
        "y": rect.y,
        "width": rect.width,
        "height": rect.height,
    })
}

/// The work behind the bridge's `api_darkroom_render_preview`, which describes the request
/// and the reply.
pub fn darkroom_render_preview(
    recipe_json: String,
    context_json: String,
) -> Result<DarkroomPreview, String> {
    let context: DarkroomContextArgs = serde_json::from_str(&context_json)
        .map_err(|e| format!("invalid darkroom context: {e}"))?;
    let encoding = PreviewEncoding::parse(&context.encoding)?;
    let recipe = parse_recipe(&recipe_json)?;

    let token = RENDERS.register(&context.render_id)?;
    let master = load_pyramid(&context.master_path, &token)?;
    let level = resolve_level(&master.pyramid, context.level, context.max_dimension)?;
    let base = master
        .pyramid
        .level(level)
        .ok_or_else(|| format!("resolution level {level} is out of range for this master"))?
        .clone();

    let (ctx, catalog_stars) =
        build_context(&recipe, &base, level, &token, &context.catalog_stars)?;
    let mut options = RenderOptions::full()
        .at_level(level)
        .over_master(master.identity.as_str());
    if let Some(stop_after) = context.stop_after {
        options = options.stopping_after(stop_after);
    }

    let output = run_render(&recipe, &base, &ctx, options, &token)?;
    let encoded = encode_preview(&output, encoding, &ctx, &token, context.measure_only)?;

    let cache_state = {
        let cache = render_cache();
        json!({
            "entries": cache.len(),
            "usedBytes": cache.used_bytes(),
            "capacityBytes": cache.capacity_bytes(),
        })
    };

    let report = json!({
        "recipeId": recipe.id,
        "baseMasterRef": recipe.base_master_ref,
        "masterPath": context.master_path,
        "renderId": token.id(),
        "cancellable": !token.id().is_empty(),
        "stopAfter": context.stop_after,
        "catalogStars": catalog_stars,
        "level": level_json(&master.pyramid, level, &base),
        "encoding": encoded.description,
        "report": report_json(&output.report),
        "cache": cache_state,
    });

    Ok(DarkroomPreview {
        width: encoded.width,
        height: encoded.height,
        is_color: encoded.is_color,
        rgba: encoded.rgba,
        report_json: serde_json::to_string(&report)
            .map_err(|e| format!("failed to encode result: {e}"))?,
    })
}

/// The work behind the bridge's `api_darkroom_render_export`, which describes the request
/// and the reply.
pub fn darkroom_render_export(recipe_json: String, args_json: String) -> Result<String, String> {
    let args: DarkroomExportArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid darkroom export: {e}"))?;
    let result = run_export(&recipe_json, args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_darkroom_registry`, which describes the request
/// and the reply.
pub fn darkroom_registry(args_json: String) -> Result<String, String> {
    let args: DarkroomRegistryArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid darkroom registry: {e}"))?;
    let registry = registry()?;

    let mut reply = json!({
        "schemaVersion": RECIPE_SCHEMA_VERSION,
        "ops": ops_json()?,
        "channelMixes": super::schema::channel_mixes_json(),
        "registered": registry
            .keys()
            .iter()
            .map(|(id, version)| json!({"id": id, "version": version}))
            .collect::<Vec<Value>>(),
        "cacheBudget": {
            "renderBytes": RENDER_CACHE_CAPACITY_BYTES,
            "baseMasterBytes": BASE_CACHE_CAPACITY_BYTES,
        },
    });

    if let Some(composite) = &args.composite {
        match super::composite::plan(composite)? {
            super::composite::CompositeOutcome::NotCombined(report) => {
                reply["composite"] = report;
            }
            super::composite::CompositeOutcome::Planned(planned) => {
                let planned = *planned;
                let base_master_ref = if args.base_master_ref.trim().is_empty() {
                    planned.reference_path.clone()
                } else {
                    args.base_master_ref.clone()
                };
                reply["draft"] = super::schema::draft_for_composite(
                    &planned.reference,
                    &args.recipe_id,
                    &base_master_ref,
                    super::schema::CompositePrefix {
                        step: planned.step,
                        sources: planned.sources,
                    },
                )?;
                reply["base"] = level_json(
                    &planned.reference.pyramid,
                    0,
                    planned.reference.pyramid.base(),
                );
                reply["masterPath"] = json!(planned.reference_path);
                reply["composite"] = planned.report;
            }
        }
        return serde_json::to_string(&reply).map_err(|e| format!("failed to encode result: {e}"));
    }

    if !args.master_path.trim().is_empty() {
        let token = RENDERS.register("")?;
        let master = load_pyramid(&args.master_path, &token)?;
        let base_master_ref = if args.base_master_ref.trim().is_empty() {
            args.master_path.clone()
        } else {
            args.base_master_ref.clone()
        };
        reply["draft"] = draft_for_master(&master, &args.recipe_id, &base_master_ref)?;
        reply["base"] = level_json(&master.pyramid, 0, master.pyramid.base());
    }

    serde_json::to_string(&reply).map_err(|e| format!("failed to encode result: {e}"))
}

/// The work behind the bridge's `api_darkroom_cancel`, which describes the request
/// and the reply.
pub fn darkroom_cancel(args_json: String) -> Result<String, String> {
    let args: DarkroomCancelArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid cancel args: {e}"))?;
    let id = args.render_id.trim();
    if id.is_empty() {
        return Err("renderId is required".to_string());
    }
    let op = match args.op.trim() {
        "" => "cancel",
        other => other,
    };
    let outcome = match op {
        "cancel" => RENDERS.request_cancel(id)?,
        "status" => RENDERS.status(id),
        "clear" => RENDERS.clear(id)?,
        other => {
            return Err(format!(
                "unknown cancel op '{other}'; expected cancel/status/clear"
            ))
        }
    };
    let result = DarkroomCancelResult {
        render_id: id.to_string(),
        op: op.to_string(),
        running: outcome.running,
        cancel_requested: outcome.cancel_requested,
    };
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}
