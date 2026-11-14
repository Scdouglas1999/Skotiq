//! The Darkroom FFI entry points.

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
    skotiq_processing::darkroom::entrypoints::darkroom_validate(recipe_json, context_json)
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
    let preview = skotiq_processing::darkroom::entrypoints::darkroom_render_preview(
        recipe_json,
        context_json,
    )?;
    Ok(DarkroomPreview {
        width: preview.width,
        height: preview.height,
        is_color: preview.is_color,
        rgba: preview.rgba,
        report_json: preview.report_json,
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
    skotiq_processing::darkroom::entrypoints::darkroom_render_export(recipe_json, args_json)
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
    skotiq_processing::darkroom::entrypoints::darkroom_registry(args_json)
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
    skotiq_processing::darkroom::entrypoints::darkroom_cancel(args_json)
}
