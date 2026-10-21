//! The Darkroom wire types.
//!
//! Every payload is `camelCase` JSON decoded with `#[serde(default)]`, so a
//! field a newer Dart build sends and this build does not read is dropped rather
//! than rejected, and a field this build reads and an older Dart build omits
//! falls back to a documented default. That is the same compatibility mechanism
//! the post-session surface uses, and it is why every new field needs a sane
//! `Default`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use skotiq_imaging::recipe::{RenderReport, StepOutcome};

use crate::api::post_session::CANCELLED_KIND;

/// One catalogue star supplied by the caller, in degrees.
///
/// `bMinusV` is a catalogue measurement. A value derived from the frame's own
/// instrumental magnitude makes the colour fit circular, so a star without a
/// genuine `B − V` is left out of the payload rather than filled in.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CatalogStarArgs {
    pub(crate) ra_deg: f64,
    pub(crate) dec_deg: f64,
    pub(crate) v_mag: f64,
    pub(crate) b_minus_v: f64,
}

/// What a render is asked for: the master, the scale, how far up the stack, and
/// what the caller can lend the operations.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DarkroomContextArgs {
    /// Path to the linear master the recipe renders over. Empty for a
    /// validation that touches no pixels.
    pub(crate) master_path: String,
    /// Explicit pyramid level; `0` is full resolution. Takes precedence over
    /// `maxDimension`.
    pub(crate) level: Option<u32>,
    /// Longest viewport edge in pixels. The coarsest level still at least this
    /// large is chosen, so the preview is never upscaled.
    pub(crate) max_dimension: Option<u32>,
    /// Render only through this step index, materialising a stage master.
    pub(crate) stop_after: Option<usize>,
    /// Cancellation handle. A render started without one is not cancellable and
    /// says so in its reply.
    pub(crate) render_id: String,
    /// `"auto"` (default) | `"unit"` | `"screen"`; see
    /// [`super::render::PreviewEncoding`].
    pub(crate) encoding: String,
    /// Photometry for `color_calibrate`. An empty list attaches no catalogue, so
    /// the operation reports itself explicitly skipped instead of fitting
    /// against nothing.
    pub(crate) catalog_stars: Vec<CatalogStarArgs>,
}

/// Which stage of the stack an export materialises.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ExportStageArgs {
    /// `"final"` (default) | `"linear"` | `"afterStep"`.
    pub(crate) kind: String,
    /// Step index for `afterStep`.
    pub(crate) index: Option<usize>,
}

/// One file an export writes.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ExportOutputArgs {
    /// `"fits"` | `"png"` | `"jpeg"` | `"tiff"`.
    pub(crate) format: String,
    /// Absolute path to write.
    pub(crate) path: String,
    /// JPEG quality, 1-100. Read only for `jpeg`.
    pub(crate) quality: Option<u8>,
}

/// A full-resolution export of one stage of a recipe.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DarkroomExportArgs {
    /// Path to the linear master the recipe renders over.
    pub(crate) master_path: String,
    /// Cancellation handle.
    pub(crate) render_id: String,
    /// Which stage to write.
    pub(crate) stage: ExportStageArgs,
    /// The files to write. An empty list is an error: an export that writes
    /// nothing is not an export.
    pub(crate) outputs: Vec<ExportOutputArgs>,
    /// Where to write the `.skrecipe` sidecar. Absent derives it from the first
    /// FITS output.
    pub(crate) sidecar_path: Option<String>,
    /// Whether to write the sidecar at all. Defaults to `true`; see
    /// [`super::export`].
    pub(crate) write_sidecar: Option<bool>,
    /// Apply the engine's own auto screen transfer before quantising an
    /// 8/16-bit output whose pixels are still linear. Absent refuses the export
    /// rather than inventing a mapping.
    pub(crate) screen_transfer: bool,
    /// Photometry for `color_calibrate`.
    pub(crate) catalog_stars: Vec<CatalogStarArgs>,
}

/// What the registry call is asked for.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DarkroomRegistryArgs {
    /// A linear master to measure auto-parameters and a first-draft recipe
    /// from. Empty returns the operation catalogue alone.
    pub(crate) master_path: String,
    /// Identity the drafted recipe carries as its `baseMasterRef`. Empty uses
    /// `masterPath`.
    pub(crate) base_master_ref: String,
    /// Id the drafted recipe carries. Empty uses `"draft"`.
    pub(crate) recipe_id: String,
    /// A target's per-filter masters to draft as one colour composite, in
    /// place of `masterPath`. The reply names the reference master the
    /// composite's recipe renders over as `masterPath`.
    pub(crate) composite: Option<super::composite::CompositeArgs>,
}

/// Request for [`super::api_darkroom_cancel`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DarkroomCancelArgs {
    /// `"cancel"` (default) | `"status"` | `"clear"`.
    pub(crate) op: String,
    /// The render id the caller passed to a Darkroom entry point.
    pub(crate) render_id: String,
}

/// Response for [`super::api_darkroom_cancel`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DarkroomCancelResult {
    pub(crate) render_id: String,
    /// The op that ran.
    pub(crate) op: String,
    /// `true` when a render is executing under this id right now. `false` after
    /// a `cancel` means the flag is pre-armed for a render that has not started
    /// (or has already finished) — not that the request was lost.
    pub(crate) running: bool,
    /// The render's cancellation flag after the op.
    pub(crate) cancel_requested: bool,
}

/// The typed outcome a cancelled Darkroom call returns as its `Err` payload: the
/// JSON encoding of this struct, so a caller decodes it instead of matching on
/// prose.
///
/// The `kind` discriminator is the same constant the post-session surface uses,
/// so one Dart decoder recognises a cancelled dawn job and a cancelled render.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CancelledRender {
    /// Always `"cancelled"`.
    pub(crate) kind: String,
    pub(crate) render_id: String,
    /// The phase the render stopped at: `read`, `pyramid`, `render`, `encode`
    /// or `write`.
    pub(crate) phase: String,
}

impl CancelledRender {
    /// The encoded outcome for a render that stopped in `phase`.
    ///
    /// The encoding cannot fail for this shape; if it somehow did, the caller
    /// must still see a cancellation, so the discriminator alone is returned.
    pub(crate) fn err(render_id: &str, phase: &str) -> String {
        let outcome = Self {
            kind: CANCELLED_KIND.to_string(),
            render_id: render_id.to_string(),
            phase: phase.to_string(),
        };
        serde_json::to_string(&outcome).unwrap_or_else(|_| CANCELLED_KIND.to_string())
    }
}

/// The render report as wire JSON: one entry per step the render covered, in
/// order, naming what happened to it and why.
///
/// A step that solved something while it ran carries it as `measured` — for
/// `color_calibrate@1` the channel scales, the reference colour, the
/// cross-matched star count and the fit residual. That is the read-back a draft
/// pins into the recipe so later previews replay the balance rather than
/// re-fitting it at a level that holds too few stars.
pub(crate) fn report_json(report: &RenderReport) -> Value {
    let steps: Vec<Value> = report
        .steps
        .iter()
        .map(|step| {
            let mut entry = json!({
                "index": step.index,
                "opId": step.op_id,
                "opVersion": step.op_version,
                "outcome": step.outcome.as_wire(),
            });
            if let StepOutcome::Skipped { reason } = &step.outcome {
                entry["reason"] = Value::String(reason.clone());
            }
            if let Some(measured) = &step.measurement {
                entry["measured"] = measured.clone();
            }
            entry
        })
        .collect();
    json!({
        "level": report.level,
        "resumedAt": report.resumed_at,
        "cacheHits": report.cache_hits,
        "cacheMisses": report.cache_misses,
        "hasSkips": report.has_skips(),
        "steps": steps,
    })
}

/// An empty report for a stage that applies no step, so a caller reads the same
/// shape whether or not the render ran.
pub(crate) fn empty_report_json(level: u32) -> Value {
    json!({
        "level": level,
        "resumedAt": 0,
        "cacheHits": 0,
        "cacheMisses": 0,
        "hasSkips": false,
        "steps": [],
    })
}
