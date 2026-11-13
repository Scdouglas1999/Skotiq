/// One-shot batch integration of a sub list into a linear FITS master.
///
/// Pipeline: optional calibration (dark/flat/bias) + cosmetic correction →
/// star-based registration to a reference → per-channel normalization →
/// per-sub quality weighting → batch integration with pixel rejection →
/// 16-bit/float linear FITS master + stretched preview PNG.
///
/// `args_json` is an [`IntegrateSessionArgs`]; the result is an
/// [`IntegrateSessionResult`]. All failure modes (no subs, unreadable frame,
/// no consistent geometry, write failure) surface as `Err(String)` — never a
/// silent partial stack.
///
/// Passing a non-empty `runId` makes the run cancellable through
/// [`api_post_session_cancel`]. A cancelled run returns `Err` carrying the JSON
/// encoding of a [`CancelledOutcome`] (`{"kind":"cancelled", …}`) and writes no
/// master — cancellation is never reported as a partial success.
pub fn api_integrate_session(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::integrate_session(args_json)
}

/// Multi-night accumulating master. `op` selects the operation:
///
/// * `create`   `{ op, referencePath, sidecarPath, masterFitsPath?, settings?, filter?, target? }`
/// * `add`      `{ op, sidecarPath, lightPaths[], exposuresSec?, calibration?, settings? }`
/// * `finalize` `{ op, sidecarPath, masterFitsPath, previewPngPath? }`
/// * `info`     `{ op, sidecarPath }`
/// * `build`    `{ op, gridReference, normalizationReference?, groups[], filter?, target?,
///   settings?, clip?, masterFitsPath, previewPngPath?, runId? }` — one filter's master from
///   every group (night) of subs in one call, folding a sub at a time; a sub that will not
///   register is skipped and reported ([`MasterBuildResult`]).
/// * `registrationPreview` `{ op, gridReference, groups[], settings?, minOverlap,
///   minRetainedArea, runId? }` — register every light from its stars, without
///   warping, and report each footprint and the common crop it allows.
/// * `deliver`  `{ op, masters[], referenceFilter?, outputDir, target }` — register a target's
///   per-filter masters onto one grid and write linear mono masters plus a planar RGB FITS
///   for PixInsight ([`MasterDeliverResult`]).
///
/// Returns a [`MasterAccumulateResult`]. The running accumulator state lives in
/// the `.skmaster` sidecar; the FITS is the shareable artifact written on
/// `finalize` (and re-finalizable after more `add`s).
///
/// `add` accepts a `runId` and honours [`api_post_session_cancel`] the same way
/// [`api_integrate_session`] does: a cancelled fold returns the encoded
/// [`CancelledOutcome`] and leaves the sidecar untouched.
pub fn api_master_accumulate(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::master_accumulate(args_json)
}

/// Build a unit-mean master flat from raw flats (+ optional bias / dark-flat
/// pedestal) and write it as a FITS master, wrapping
/// [`build_master_flat`](skotiq_imaging::calibration_masters::build_master_flat).
///
/// `args_json` is a [`BuildMasterFlatArgs`]; the result is a
/// [`BuildMasterFlatResult`].
pub fn api_build_master_flat(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::build_master_flat(args_json)
}

/// Build a dark or bias master from raw frames on disk: a winsorized
/// sigma-clipped mean written as unsigned 16-bit FITS with the acquisition
/// keys, reading one band of rows at a time so memory does not grow with the
/// frame count. Frames that read brighter than the group's first frames (a
/// light leak) are left out and reported.
///
/// `args_json` is a [`BuildCalibrationMasterArgs`]; the result is a
/// [`BuildCalibrationMasterResult`].
pub fn api_build_calibration_master(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::build_calibration_master(args_json)
}

/// Re-export an in-memory pixel buffer as a 16-bit or float FITS master with
/// provenance. The integration paths already write the FITS natively, so this
/// is for re-export from Dart-held buffers.
///
/// `args_json` is a [`SaveFitsMasterArgs`]; the result is a
/// [`SaveFitsMasterResult`].
pub fn api_save_fits_master(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::save_fits_master(args_json)
}

/// Set, read, or drop the cancellation flag for a post-session run.
///
/// A post-session call is one synchronous FFI descent with no await point, so
/// Dart cannot abort it — it can only ask the native loops to stop. `op` selects
/// the operation, defaulting to `cancel`:
///
/// * `cancel` `{ runId }` — request cancellation. Honoured at the next stage
///   boundary or frame, always before the master is written. A request for a run
///   that has not started yet is **pre-armed**: safing can fire before the run
///   reaches Rust, and the run then stops at its first check.
/// * `status` `{ op: "status", runId }` — read whether the run is in flight and
///   whether cancellation has been requested.
/// * `clear`  `{ op: "clear", runId }` — drop a pre-armed cancellation. Refused
///   for a run in flight, which would otherwise resurrect a stopped run.
///
/// `args_json` is a [`PostSessionCancelArgs`]; the result is a
/// [`PostSessionCancelResult`]. A blank `runId`, an unknown `op`, or clearing a
/// live run surface as `Err(String)`.
pub fn api_post_session_cancel(args_json: String) -> Result<String, String> {
    skotiq_processing::post_session::entrypoints::post_session_cancel(args_json)
}
