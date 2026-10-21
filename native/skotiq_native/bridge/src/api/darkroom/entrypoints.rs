//! The Darkroom FFI entry points.

use serde_json::{json, Value};

use skotiq_imaging::recipe::ops::crop::{crop_fit, CropRect};
use skotiq_imaging::recipe::{Recipe, RenderOptions, RECIPE_SCHEMA_VERSION};

use super::args::{
    report_json, DarkroomCancelArgs, DarkroomCancelResult, DarkroomContextArgs, DarkroomExportArgs,
    DarkroomRegistryArgs,
};
use super::export::run_export;
use super::render::{
    build_context, encode_preview, level_json, load_pyramid, parse_recipe, resolve_level,
    run_render, PreviewEncoding,
};
use super::schema::{draft_for_master, ops_json};
use super::state::{
    cancel_status, clear_cancel, registry, render_cache, request_cancel, RenderCancelToken,
    BASE_CACHE_CAPACITY_BYTES, RENDER_CACHE_CAPACITY_BYTES,
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

/// Check a recipe without touching pixels.
///
/// `recipe_json` is a recipe; `context_json` is a
/// [`DarkroomContextArgs`] whose `masterPath` is optional here — supplying one
/// adds the base master's geometry to the reply, which is what tells an editor
/// whether a three-channel operation has three channels to work with.
///
/// The reply is `{ok, error, steps[], geometryChecked, findings[], base?}`. A
/// recipe that decodes and fails validation is `ok: false` with the engine's own
/// message plus a per-step diagnosis, so an editor can mark every bad step at
/// once instead of the first one. A payload that is not a recipe at all surfaces
/// as `Err(String)`.
///
/// # Findings
///
/// `ok` answers whether the recipe is well formed, which is a question about the
/// recipe alone. A `masterPath` adds the second question — whether it fits
/// *these* pixels — and the answer travels as `findings`, because a recipe whose
/// crop runs off this master is still a valid recipe: the render succeeds and
/// silently frames something else. `geometryChecked` says whether that question
/// was asked at all, so an empty `findings` never has to stand in for "no
/// master was supplied".
pub fn api_darkroom_validate(recipe_json: String, context_json: String) -> Result<String, String> {
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
        let token = RenderCancelToken::register("")?;
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

/// Render a recipe over a master at one pyramid level and return the RGBA buffer
/// the viewer takes.
///
/// `context_json` is a [`DarkroomContextArgs`]: `masterPath` names the linear
/// master; `level` or `maxDimension` chooses the scale; `stopAfter` renders only
/// through that step, which is how a stage master is shown without storing one;
/// `renderId` makes the render cancellable through [`api_darkroom_cancel`];
/// `encoding` chooses the display transfer; `catalogStars` lends `color_calibrate`
/// the photometry it needs.
///
/// A cancelled render returns `Err` carrying the JSON encoding of the cancelled
/// outcome (`{"kind":"cancelled", …}`) and no pixels — a partial render is never
/// returned as a picture.
pub fn api_darkroom_render_preview(
    recipe_json: String,
    context_json: String,
) -> Result<DarkroomPreview, String> {
    let context: DarkroomContextArgs = serde_json::from_str(&context_json)
        .map_err(|e| format!("invalid darkroom context: {e}"))?;
    let encoding = PreviewEncoding::parse(&context.encoding)?;
    let recipe = parse_recipe(&recipe_json)?;

    let token = RenderCancelToken::register(&context.render_id)?;
    let master = load_pyramid(&context.master_path, &token)?;
    let level = resolve_level(&master.pyramid, context.level, context.max_dimension)?;
    let base = master
        .pyramid
        .level(level)
        .ok_or_else(|| format!("pyramid level {level} is out of range for this master"))?
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
        "renderId": token.render_id(),
        "cancellable": !token.render_id().is_empty(),
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

/// Write one stage of a recipe at full resolution.
///
/// `args_json` is a [`DarkroomExportArgs`]. `stage` selects `linear` (the
/// master's own pixels), `afterStep` with an index, or `final`. Every FITS
/// output carries the recipe in `HISTORY` cards — readable lines plus a base64
/// payload of the canonical JSON — and a `.skrecipe` sidecar is written beside
/// it unless the caller opts out.
///
/// PNG, JPEG and TIFF are quantised from the recipe engine's own pixels. A stage
/// whose pixels are still linear has no display mapping, so those formats are
/// refused for it unless `screenTransfer` is set, which renders them through the
/// engine's own auto stretch and says so in the reply.
pub fn api_darkroom_render_export(
    recipe_json: String,
    args_json: String,
) -> Result<String, String> {
    let args: DarkroomExportArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid darkroom export: {e}"))?;
    let result = run_export(&recipe_json, args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

/// The operations this build renders, and the first-draft parameters for a
/// master.
///
/// `args_json` is a [`DarkroomRegistryArgs`]. With no `masterPath` the reply is
/// the operation catalogue alone: every registered `(id, version)` with its
/// stage and the type, range and default of each parameter. With a `masterPath`
/// the reply also carries a first-draft recipe and the measurements behind it —
/// the auto crop rectangle, the auto stretch parameters, and the documented
/// defaults for the operations that need no measurement — so the autopilot and
/// the editor build a draft from the operations' own numbers.
pub fn api_darkroom_registry(args_json: String) -> Result<String, String> {
    let args: DarkroomRegistryArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid darkroom registry: {e}"))?;
    let registry = registry()?;

    let mut reply = json!({
        "schemaVersion": RECIPE_SCHEMA_VERSION,
        "ops": ops_json()?,
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
        let token = RenderCancelToken::register("")?;
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

/// Set, read, or drop the cancellation flag for a Darkroom render.
///
/// A render is one synchronous FFI descent with no await point, so Dart cannot
/// abort it — it can only ask the engine's loops to stop. The flag this raises is
/// the one the render engine and every operation poll.
///
/// `op` selects the operation, defaulting to `cancel`:
///
/// * `cancel` `{ renderId }` — request cancellation. Honoured at the next step
///   boundary or pixel-budget poll, and always before a file is written. A
///   request for a render that has not started yet is **pre-armed**.
/// * `status` `{ op: "status", renderId }` — read whether the render is in
///   flight and whether cancellation has been requested.
/// * `clear` `{ op: "clear", renderId }` — drop a pre-armed cancellation.
///   Refused for a render in flight, which would resurrect a stopped render.
///
/// The render ids here are the Darkroom's own; a post-session run id is
/// cancelled through `api_post_session_cancel`. Both report the same
/// `{"kind":"cancelled", …}` shape from the call they stop.
pub fn api_darkroom_cancel(args_json: String) -> Result<String, String> {
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
        "cancel" => request_cancel(id)?,
        "status" => cancel_status(id),
        "clear" => clear_cancel(id)?,
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
