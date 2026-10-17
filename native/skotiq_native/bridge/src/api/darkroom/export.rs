//! Full-resolution export of one stage of a recipe, with the recipe written
//! into the file.
//!
//! # Stages
//!
//! * `linear` — the master's own pixels, untouched. The recipe is *recorded* as
//!   provenance and explicitly marked as not applied, because a linear master
//!   that claimed an interpretation it never ran would be as untrue as a step
//!   that reports success while changing nothing. It follows that no step can
//!   refuse this stage: a recipe that is provenance here rather than a program
//!   is written as it stands, and only the master itself has to be readable.
//! * `afterStep N` — the stack replayed through step `N`. This is how a
//!   "post-gradient master" or a "starless master" is materialised: rendered on
//!   demand, never stored as a default checkpoint.
//! * `final` — the whole stack.
//!
//! # Provenance
//!
//! A FITS export carries the recipe twice: as human-readable `HISTORY` lines
//! naming every step and its outcome, and as a base64 payload of the recipe's
//! canonical JSON split across numbered `HISTORY` cards, so the exact recipe can
//! be read back out of the file alone. Base64 is used because a FITS reader
//! trims trailing spaces from a commentary card, which would silently corrupt a
//! raw JSON payload split at a space. A `.nsrecipe` sidecar carries the same
//! canonical JSON beside the file, so a recipe survives outside the database
//! even for a raster export.
//!
//! # Step numbering in an exported file
//!
//! Two numbers appear, and they are not the same number. `NSSTAGE` and the
//! sidecar's `stage.index` are the machine token: the caller's own 0-based
//! `stage.index`, unchanged, so a reader can split `afterStep:0` and replay
//! that exact request. Every sentence a person reads — the `HISTORY` step
//! lines, the summary line's `(through step 1 of 3)`, a refusal — counts from
//! 1, matching the editor's step list, the export sheet's suggested filename
//! and the recipe validator's own sentences.
//!
//! # Raster exports
//!
//! PNG, JPEG and TIFF are written from the recipe engine's own `F32` pixels,
//! quantised here. The display path's own stretch is not reused: it decodes its
//! input as `u16` pairs with no pixel-type check, and these pixels are `F32`.
//! A stage whose pixels are still linear has no display mapping, so a raster
//! export of one is refused unless the caller asks for the engine's own auto
//! screen transfer — which is then named in the reply.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use skotiq_imaging::recipe::ops::stretch::{auto_params, StretchV1};
use skotiq_imaging::recipe::{
    canonical_json, fingerprint_hex, DarkroomOp, OpImage, OpRegistry, OpStage, Recipe,
    RenderOptions, RenderReport, StepOutcome, RECIPE_SCHEMA_VERSION,
};
use skotiq_imaging::{write_jpeg, write_png, write_tiff, FitsHeader, ImageData, PixelType};
use serde_json::{json, Value};

use super::args::{empty_report_json, report_json, CancelledRender, DarkroomExportArgs};
use super::render::{
    build_context, level_json, load_pyramid, parse_recipe, quantise_unit, run_render,
};
use super::state::{registry, RenderCancelToken};

/// Marker every recipe-payload `HISTORY` card starts with.
const HISTORY_RECIPE_MARKER: &str = "NSRECIPE-B64";

/// Base64 characters per `HISTORY` card. A commentary card holds 72 bytes of
/// text; the marker and the four-digit index take 18, leaving room for this with
/// margin to spare.
const HISTORY_CHUNK_CHARS: usize = 48;

/// Default JPEG quality when the caller states none.
const DEFAULT_JPEG_QUALITY: u8 = 92;

/// Whether a sidecar is written when the caller states nothing. Provenance
/// travels with the file by default; opting out is explicit.
const SIDECAR_BY_DEFAULT: bool = true;

/// Which stage of the stack an export materialises.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExportStage {
    /// The master's own pixels.
    Linear,
    /// The stack replayed through this step index.
    AfterStep(usize),
    /// The whole stack.
    Final,
}

impl ExportStage {
    /// Read the wire form. An unrecognised kind is an error rather than a
    /// default stage the caller did not ask for.
    fn parse(kind: &str, index: Option<usize>) -> Result<Self, String> {
        match kind.trim() {
            "" | "final" => Ok(Self::Final),
            "linear" => Ok(Self::Linear),
            "afterStep" => match index {
                Some(index) => Ok(Self::AfterStep(index)),
                None => Err("stage 'afterStep' needs an index".to_string()),
            },
            other => Err(format!(
                "unknown export stage '{other}'; expected linear/afterStep/final"
            )),
        }
    }

    /// The wire description carried in the reply and in the `NSSTAGE` card.
    ///
    /// `afterStep:N` carries N exactly as the caller sent it in `stage.index`
    /// — 0-based, the same number the reply and the `.nsrecipe` sidecar echo.
    /// This is the token's contract: a file written by any build names the
    /// stage in the vocabulary an export request is made in, so a reader can
    /// split the token and replay it verbatim. Nothing in the tree parses the
    /// card back today (the sidecar is what the import path reads), which is
    /// why the human translation lives beside it in [`Self::as_summary`]
    /// rather than in the token itself.
    fn as_wire(&self) -> String {
        match self {
            Self::Linear => "linear".to_string(),
            Self::AfterStep(index) => format!("afterStep:{index}"),
            Self::Final => "final".to_string(),
        }
    }

    /// The stage as the `HISTORY` summary line states it: the wire token, plus
    /// the 1-based step number the operator sees in the editor, the export
    /// sheet's suggested filename and every validation sentence.
    fn as_summary(&self, step_count: usize) -> String {
        match self {
            Self::AfterStep(index) => format!(
                "{} (through step {} of {step_count})",
                self.as_wire(),
                index + 1
            ),
            _ => self.as_wire(),
        }
    }

    /// The stage as a refusal sentence names it, in the operator's numbers.
    fn as_prose(&self) -> String {
        match self {
            Self::Linear => "linear".to_string(),
            Self::AfterStep(index) => format!("step {}", index + 1),
            Self::Final => "final".to_string(),
        }
    }

    fn as_json(&self) -> Value {
        match self {
            Self::Linear => json!({"kind": "linear", "index": Value::Null}),
            Self::AfterStep(index) => json!({"kind": "afterStep", "index": index}),
            Self::Final => json!({"kind": "final", "index": Value::Null}),
        }
    }
}

/// Run one export. See [`super::api_darkroom_render_export`].
pub(crate) fn run_export(recipe_json: &str, args: DarkroomExportArgs) -> Result<Value, String> {
    let recipe = parse_recipe(recipe_json)?;
    let registry = registry()?;
    let stage = ExportStage::parse(&args.stage.kind, args.stage.index)?;
    if args.outputs.is_empty() {
        return Err("outputs is empty; an export writes at least one file".to_string());
    }

    let token = RenderCancelToken::register(&args.render_id)?;
    let master = load_pyramid(&args.master_path, &token)?;
    let base = Arc::clone(master.pyramid.base());
    let (ctx, catalog_stars) = build_context(&base, 0, &token, &args.catalog_stars);

    let (image, report, report_value) = match stage {
        // No `validate` here: the linear stage writes the master's own pixels
        // and replays not one step, so a step's parameters cannot refuse it. A
        // whole-recipe check ran here anyway, and one out-of-range stretch
        // parameter — a step this stage explicitly records as NOT applied —
        // refused an export of pixels that stretch never touches. The recipe
        // still rides along exactly as the caption promises: the HISTORY cards,
        // the canonical payload and the sidecar below are written from the
        // recipe as it stands, faults and all, because that is what provenance
        // means. What this stage does need is checked already — the master is
        // read by `load_pyramid` above, and `parse_recipe` refuses a schema
        // version this build cannot carry.
        ExportStage::Linear => (Arc::clone(&base), None, empty_report_json(0)),
        ExportStage::AfterStep(index) => {
            let output = run_render(
                &recipe,
                &base,
                &ctx,
                RenderOptions::full()
                    .stopping_after(index)
                    .over_master(master.identity.as_str()),
                &token,
            )?;
            let value = report_json(&output.report);
            (Arc::clone(&output.image), Some(output.report), value)
        }
        ExportStage::Final => {
            let output = run_render(
                &recipe,
                &base,
                &ctx,
                RenderOptions::full().over_master(master.identity.as_str()),
                &token,
            )?;
            let value = report_json(&output.report);
            (Arc::clone(&output.image), Some(output.report), value)
        }
    };

    if token.is_cancelled() {
        return Err(CancelledRender::err(token.render_id(), "write"));
    }

    let stretched_domain = report
        .as_ref()
        .is_some_and(|report| left_linear_stage(report, registry));
    let canonical_recipe = canonical_json(
        &serde_json::to_value(&recipe).map_err(|e| format!("cannot encode the recipe: {e}"))?,
    );
    let fingerprint = fingerprint_hex(canonical_recipe.as_bytes());

    let needs_raster = args
        .outputs
        .iter()
        .any(|output| !output.format.trim().eq_ignore_ascii_case("fits"));
    let (raster_image, screen_transfer) = if needs_raster && !stretched_domain {
        if !args.screen_transfer {
            return Err(format!(
                "the {} render is still linear ADU and has no display mapping; export FITS to keep the linear pixels, or set screenTransfer to render the 8/16-bit files through the engine's own auto stretch",
                stage.as_prose()
            ));
        }
        let params = auto_params(&image).map_err(|e| e.to_string())?;
        let payload = params.to_params();
        let transferred = StretchV1
            .apply(&image, &payload, &ctx)
            .map_err(|e| e.to_string())?;
        (Arc::new(transferred), Some(payload))
    } else {
        (Arc::clone(&image), None)
    };

    let mut history = history_lines(&stage, &recipe, report.as_ref(), &fingerprint);
    history.extend(recipe_payload_cards(&canonical_recipe));
    let mut written: Vec<Value> = Vec::new();
    let mut fits_paths: Vec<PathBuf> = Vec::new();
    for output in &args.outputs {
        let format = output.format.trim().to_ascii_lowercase();
        let path = output.path.trim();
        if path.is_empty() {
            return Err(format!("output '{format}' has no path"));
        }
        let path = PathBuf::from(path);
        let entry = match format.as_str() {
            "fits" => {
                let header = export_header(&image, &stage, &fingerprint, &recipe, &history);
                let record = write_fits_atomic(&path, &image, &header)?;
                fits_paths.push(path.clone());
                record
            }
            "png" | "tiff" | "jpeg" => write_raster(&path, &raster_image, &format, output.quality)?,
            other => {
                return Err(format!(
                    "unknown export format '{other}'; expected fits/png/jpeg/tiff"
                ))
            }
        };
        written.push(entry);
    }

    let sidecar = write_sidecar(
        &args,
        &fits_paths,
        &recipe,
        &stage,
        &fingerprint,
        &report_value,
        &canonical_recipe,
    )?;

    Ok(json!({
        "stage": stage.as_json(),
        "masterPath": args.master_path,
        "renderId": token.render_id(),
        "base": level_json(&master.pyramid, 0, &base),
        "report": report_value,
        "recipeFingerprint": fingerprint,
        "recipeSchemaVersion": RECIPE_SCHEMA_VERSION,
        "sourceDomain": if stretched_domain { "stretched" } else { "linear" },
        "screenTransfer": screen_transfer,
        "screenTransferAffectsRecipe": false,
        "catalogStars": catalog_stars,
        "historyCardCount": history.len(),
        "outputs": written,
        "sidecarPath": sidecar.path,
        "sidecarSkippedReason": sidecar.skipped_reason,
    }))
}

/// Whether a report shows the render left the linear stage.
fn left_linear_stage(report: &RenderReport, registry: &OpRegistry) -> bool {
    report.steps.iter().any(|step| {
        matches!(step.outcome, StepOutcome::Applied)
            && registry
                .get(&step.op_id, step.op_version)
                .is_some_and(|op| op.stage() == OpStage::Stretched)
    })
}

/// The `HISTORY` lines an exported FITS carries: one human-readable summary, one
/// line per step, then the recipe's canonical JSON as numbered base64 cards.
fn history_lines(
    stage: &ExportStage,
    recipe: &Recipe,
    report: Option<&RenderReport>,
    fingerprint: &str,
) -> Vec<String> {
    let mut lines = vec![format!(
        "Skotiq Darkroom: stage={}, recipe={} ({} step{}), fingerprint={}",
        stage.as_summary(recipe.steps.len()),
        recipe.id,
        recipe.steps.len(),
        if recipe.steps.len() == 1 { "" } else { "s" },
        fingerprint
    )];
    match report {
        None => lines.push(
            "Linear master passthrough: the recipe below is recorded as provenance and no step was applied".to_string(),
        ),
        Some(report) => {
            for step in &report.steps {
                let outcome = match &step.outcome {
                    StepOutcome::Applied => "applied".to_string(),
                    StepOutcome::Disabled => "disabled".to_string(),
                    StepOutcome::Skipped { reason } => format!("skipped: {reason}"),
                };
                // A step that solved something while it ran carries it here
                // too, not only in the render report the caller reads back: the
                // exported file is the copy that outlives the session, and
                // "applied" alone hid a crop rectangle the render had to shrink
                // to fit the master. HISTORY takes one logical line of any
                // length — the writer breaks it across cards.
                let measured = match &step.measurement {
                    Some(measured) => format!(" measured={measured}"),
                    None => String::new(),
                };
                // `step.index` is stored 0-based; the sentence counts from 1,
                // the way the editor's step list, the export sheet's own
                // suggested filename and every `RecipeError` sentence do. A
                // HISTORY line reading "step 0" named a step the operator
                // could not find on any other surface.
                lines.push(format!(
                    "  step {}: {}@{} {}{}",
                    step.index + 1,
                    step.op_id,
                    step.op_version,
                    outcome,
                    measured
                ));
            }
        }
    }
    lines
}

/// The recipe payload cards: numbered base64 chunks of the canonical JSON.
fn recipe_payload_cards(canonical_recipe: &str) -> Vec<String> {
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(canonical_recipe.as_bytes());
    encoded
        .as_bytes()
        .chunks(HISTORY_CHUNK_CHARS)
        .enumerate()
        .map(|(index, chunk)| {
            format!(
                "{HISTORY_RECIPE_MARKER} {index:04} {}",
                String::from_utf8_lossy(chunk)
            )
        })
        .collect()
}

/// The header an exported FITS carries: the master's own header — astrometry,
/// `DATE-OBS`, `EXPTIME`, `FILTER`, `OBJECT` and all — plus the Darkroom's
/// provenance keywords and `HISTORY` cards.
fn export_header(
    image: &OpImage,
    stage: &ExportStage,
    fingerprint: &str,
    recipe: &Recipe,
    history: &[String],
) -> FitsHeader {
    let mut header = image.header().clone();
    header.set_string("NSSTAGE", &stage.as_wire());
    header.set_string("NSRECIPE", fingerprint);
    header.set_int("NSRECVER", i64::from(RECIPE_SCHEMA_VERSION));
    header.set_int("NSRECSTP", recipe.steps.len() as i64);
    for line in history {
        header.add_history(line);
    }
    header
}

/// Write a FITS file atomically: a temporary sibling, then a rename.
fn write_fits_atomic(path: &Path, image: &OpImage, header: &FitsHeader) -> Result<Value, String> {
    let data = image.to_image_data();
    let temp = temp_sibling(path);
    skotiq_imaging::write_fits(&temp, &data, header)
        .map_err(|e| format!("cannot write '{}': {e}", path.display()))?;
    finish_atomic(&temp, path)?;
    Ok(json!({
        "format": "fits",
        "path": path.to_string_lossy(),
        "bytes": file_size(path),
        "width": image.width(),
        "height": image.height(),
        "channels": image.channels(),
        "pixelType": "f32",
        "clampedSamples": 0,
    }))
}

/// Write one 8/16-bit raster from the render's own samples.
fn write_raster(
    path: &Path,
    image: &OpImage,
    format: &str,
    quality: Option<u8>,
) -> Result<Value, String> {
    let channels = image.channels();
    if channels != 1 && channels != 3 {
        return Err(format!(
            "a {channels}-channel render has no {format} encoding; PNG, JPEG and TIFF carry 1 (mono) or 3 (RGB) channels"
        ));
    }
    let mut clamped = 0usize;
    let temp = temp_sibling(path);
    let (pixel_type, bits) = match format {
        "jpeg" => ("u8", 8u32),
        _ => ("u16", 16u32),
    };
    let quality = quality.unwrap_or(DEFAULT_JPEG_QUALITY).clamp(1, 100);

    match format {
        "jpeg" => {
            let samples: Vec<u8> = image
                .data()
                .iter()
                .map(|value| quantise_unit(*value, 255.0, &mut clamped) as u8)
                .collect();
            let data = ImageData {
                width: image.width(),
                height: image.height(),
                channels,
                pixel_type: PixelType::U8,
                data: samples,
            };
            write_jpeg(&temp, &data, quality)?;
        }
        "png" | "tiff" => {
            let samples: Vec<u16> = image
                .data()
                .iter()
                .map(|value| quantise_unit(*value, 65535.0, &mut clamped) as u16)
                .collect();
            let data = ImageData::from_u16(image.width(), image.height(), channels, &samples);
            if format == "png" {
                write_png(&temp, &data)?;
            } else {
                write_tiff(&temp, &data)?;
            }
        }
        other => {
            return Err(format!(
                "unknown raster format '{other}'; expected png/jpeg/tiff"
            ))
        }
    }
    finish_atomic(&temp, path)?;

    let mut entry = json!({
        "format": format,
        "path": path.to_string_lossy(),
        "bytes": file_size(path),
        "width": image.width(),
        "height": image.height(),
        "channels": channels,
        "pixelType": pixel_type,
        "bitsPerSample": bits,
        "clampedSamples": clamped,
    });
    if format == "jpeg" {
        entry["quality"] = json!(quality);
    }
    Ok(entry)
}

/// Where the sidecar landed, or why none was written.
struct SidecarOutcome {
    path: Value,
    skipped_reason: Value,
}

/// Write the `.nsrecipe` sidecar beside the exported FITS.
///
/// The sidecar is written when the caller names a path or when the export wrote
/// a FITS to derive one from. An export of raster files alone with no named path
/// has nowhere to put it, and the reply says so rather than dropping it in
/// silence.
fn write_sidecar(
    args: &DarkroomExportArgs,
    fits_paths: &[PathBuf],
    recipe: &Recipe,
    stage: &ExportStage,
    fingerprint: &str,
    report_value: &Value,
    canonical_recipe: &str,
) -> Result<SidecarOutcome, String> {
    let wanted = match args.write_sidecar {
        Some(explicit) => explicit,
        None => SIDECAR_BY_DEFAULT,
    };
    if !wanted {
        return Ok(SidecarOutcome {
            path: Value::Null,
            skipped_reason: Value::String("writeSidecar is false".to_string()),
        });
    }
    let path = match args.sidecar_path.as_deref().map(str::trim) {
        Some(explicit) if !explicit.is_empty() => PathBuf::from(explicit),
        _ => match fits_paths.first() {
            Some(fits) => sidecar_beside(fits),
            None => {
                return Ok(SidecarOutcome {
                    path: Value::Null,
                    skipped_reason: Value::String(
                        "no FITS output to place the sidecar beside and no sidecarPath given"
                            .to_string(),
                    ),
                })
            }
        },
    };

    let recipe_value =
        serde_json::to_value(recipe).map_err(|e| format!("cannot encode the recipe: {e}"))?;
    let document = json!({
        "kind": "nsrecipe",
        "schemaVersion": RECIPE_SCHEMA_VERSION,
        "fingerprint": fingerprint,
        "stage": stage.as_json(),
        "masterPath": args.master_path,
        "recipe": recipe_value,
        "report": report_value,
        "canonicalRecipe": canonical_recipe,
    });
    let body = canonical_json(&document);
    let temp = temp_sibling(&path);
    std::fs::write(&temp, body.as_bytes())
        .map_err(|e| format!("cannot write '{}': {e}", path.display()))?;
    finish_atomic(&temp, &path)?;

    Ok(SidecarOutcome {
        path: Value::String(path.to_string_lossy().to_string()),
        skipped_reason: Value::Null,
    })
}

/// `<path>.nsrecipe`, the sidecar-beside-the-artifact convention.
fn sidecar_beside(path: &Path) -> PathBuf {
    append_extension(path, "nsrecipe")
}

/// The temporary sibling an atomic write goes through.
fn temp_sibling(path: &Path) -> PathBuf {
    append_extension(path, "nshatmp")
}

/// `path` with `suffix` appended as a further extension, keeping the one it
/// already has: `master.fits` becomes `master.fits.nsrecipe`.
fn append_extension(path: &Path, suffix: &str) -> PathBuf {
    let mut extension = std::ffi::OsString::new();
    if let Some(existing) = path.extension() {
        extension.push(existing);
        extension.push(".");
    }
    extension.push(suffix);
    path.with_extension(extension)
}

/// Rename a completed temporary into place, removing it if the rename fails so
/// no half-named file is left behind.
fn finish_atomic(temp: &Path, path: &Path) -> Result<(), String> {
    match std::fs::rename(temp, path) {
        Ok(()) => Ok(()),
        Err(rename_error) => {
            if let Err(cleanup_error) = std::fs::remove_file(temp) {
                tracing::warn!(
                    "Darkroom export could not remove '{}' after a failed rename: {cleanup_error}",
                    temp.display()
                );
            }
            Err(format!("cannot place '{}': {rename_error}", path.display()))
        }
    }
}

/// The size of a written file, or `null` when it cannot be read back.
fn file_size(path: &Path) -> Value {
    match std::fs::metadata(path) {
        Ok(meta) => json!(meta.len()),
        Err(error) => {
            tracing::warn!(
                "Darkroom export wrote '{}' and could not stat it: {error}",
                path.display()
            );
            Value::Null
        }
    }
}

/// Read a canonical recipe back out of a FITS header's `HISTORY` cards.
///
/// The inverse of [`recipe_payload_cards`]: the numbered chunks are ordered by
/// their index, concatenated and decoded. A gap in the numbering is an error —
/// a recipe reassembled from a partial payload would describe a stack nobody
/// rendered.
#[cfg(test)]
pub(crate) fn recipe_from_history(history: &[String]) -> Result<String, String> {
    use base64::Engine;
    let mut chunks: Vec<(usize, String)> = Vec::new();
    for line in history {
        let Some(rest) = line.strip_prefix(HISTORY_RECIPE_MARKER) else {
            continue;
        };
        let mut parts = rest.trim().splitn(2, ' ');
        let index = parts
            .next()
            .ok_or_else(|| "a recipe card carries no index".to_string())?;
        let payload = parts
            .next()
            .ok_or_else(|| format!("recipe card {index} carries no payload"))?;
        let index: usize = index
            .parse()
            .map_err(|e| format!("recipe card index '{index}' is not a number: {e}"))?;
        chunks.push((index, payload.trim().to_string()));
    }
    if chunks.is_empty() {
        return Err("this header carries no Darkroom recipe payload".to_string());
    }
    chunks.sort_by_key(|(index, _)| *index);
    for (position, (index, _)) in chunks.iter().enumerate() {
        if position != *index {
            return Err(format!(
                "the recipe payload is missing card {position}; the cards present start at {index}"
            ));
        }
    }
    let joined: String = chunks.into_iter().map(|(_, chunk)| chunk).collect();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(joined.as_bytes())
        .map_err(|e| format!("the recipe payload does not decode: {e}"))?;
    String::from_utf8(decoded).map_err(|e| format!("the recipe payload is not text: {e}"))
}
