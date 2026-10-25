use super::*;

/// Turn a sidecar deserialize failure into an operator-honest message.
///
/// A version-1 sidecar is not corrupt — it is data accumulated by a build
/// whose normalization erased star flux from every fold (retired as
/// MASTER_STATE_VERSION 2). The message must say "start fresh, your subs are
/// safe", not "corrupt", because the operator's next action is different.
/// The clause that marks a refusal of a sidecar format this build has retired.
///
/// The Dart side matches on it (`kRetiredMasterSidecarMarker` in
/// `master_accumulation_service.dart`) to archive the retired accumulator aside
/// and start a new master rather than losing the night. The seam between the
/// two is a plain string, so the phrase is the contract, pinned by a test on
/// each side.
pub(crate) const RETIRED_SIDECAR_MARKER: &str = "accumulator format has been retired";

fn describe_sidecar_error(e: skotiq_imaging::master_accumulation::MasterError) -> String {
    use skotiq_imaging::master_accumulation::MasterError;
    match e {
        // The leading clause is also the marker the Dart side matches on to run
        // the graceful half — archive this accumulator aside and carry the
        // night into a new master. It is a sentence, not a code, because the
        // operator reads the same string; `RETIRED_SIDECAR_MARKER` and its test
        // keep it from drifting.
        MasterError::UnsupportedVersion { got, supported } if got < supported => format!(
            "this accumulating master's {RETIRED_SIDECAR_MARKER}: sidecar version {got} was \
             built by an earlier Skotiq whose frame normalization was defective and \
             erased star flux from the fold, so it cannot be extended. Start a new master — \
             every original sub is untouched on disk and re-integrates cleanly (this build \
             reads version {supported})."
        ),
        other => format!("corrupt sidecar: {other}"),
    }
}

// api_master_accumulate implementation

#[derive(Debug, Clone, Deserialize)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterOp {
    pub(crate) op: String,
}

/// Settings carried on master `create` (subset that must be frozen for the
/// master's lifetime).
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterSettingsArgs {
    /// Online-clip thresholds (σ). `None` ⇒ pure running mean (no rejection,
    /// exactly equal to a single-batch weighted mean).
    pub(crate) online_clip_low: Option<f64>,
    pub(crate) online_clip_high: Option<f64>,
}

impl Default for MasterSettingsArgs {
    fn default() -> Self {
        Self {
            online_clip_low: Some(4.0),
            online_clip_high: Some(4.0),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterCreateArgs {
    pub(crate) reference_path: String,
    pub(crate) sidecar_path: String,
    pub(crate) settings: MasterSettingsArgs,
    pub(crate) filter: Option<String>,
    pub(crate) target: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterAddArgs {
    /// Caller-chosen id this fold answers to for cancellation
    /// ([`api_post_session_cancel`]). Empty ⇒ the fold is not cancellable.
    pub(crate) run_id: String,
    pub(crate) sidecar_path: String,
    pub(crate) light_paths: Vec<String>,
    /// Per-light exposure seconds, aligned to `light_paths`. Empty ⇒ unknown
    /// (folded as 0 s); any other length than `light_paths` is refused rather
    /// than zero-filled — these seconds become the finalized master's `EXPTIME`.
    pub(crate) exposures_sec: Vec<f64>,
    /// ISO date / session id for the fold log.
    pub(crate) label: String,
    pub(crate) calibration: CalibrationArgs,
    pub(crate) settings: IntegrationSettingsArgs,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterFinalizeArgs {
    pub(crate) sidecar_path: String,
    pub(crate) master_fits_path: String,
    pub(crate) preview_png_path: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterInfoArgs {
    pub(crate) sidecar_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterAccumulateResult {
    pub(crate) sidecar_path: String,
    pub(crate) master_path: Option<String>,
    pub(crate) preview_path: Option<String>,
    pub(crate) frame_count: usize,
    pub(crate) total_integration_sec: f64,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    /// Frames added in this call (0 for create/finalize/info).
    pub(crate) frames_added: usize,
    /// Samples rejected by the online clip in this call.
    pub(crate) rejected: u64,
    /// Per-frame integration weight for the frames folded in THIS `add` call, in
    /// `lightPaths` order (empty for create/finalize/info). The Dart side
    /// persists these so the multi-night growth/best-night intelligence has real
    /// per-sub weights instead of nulls.
    #[serde(default)]
    pub(crate) frame_weights: Vec<f64>,
    /// Which dark / flat / bias shaped the frames folded in THIS `add` call, and
    /// how well each matched them. `null` for create/finalize/info, which apply
    /// no calibration. Every fold's report is also appended to the master's
    /// calibration log beside the sidecar, and replayed into the finalized
    /// master's FITS `HISTORY`.
    #[serde(default)]
    pub(crate) calibration: Option<CalibrationReport>,
    /// Why this fold's calibration could not be recorded in the master's log,
    /// when it could not. The fold itself succeeded — it is in the sidecar — and
    /// only its provenance is missing, so this rides back as a warning instead
    /// of failing a call whose work is already durable.
    #[serde(default)]
    pub(crate) calibration_log_warning: Option<String>,
}

pub(crate) fn master_create(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterCreateArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid create args: {e}"))?;
    if args.reference_path.trim().is_empty() || args.sidecar_path.trim().is_empty() {
        return Err("create requires referencePath and sidecarPath".to_string());
    }
    let read = read_image(Path::new(&args.reference_path))
        .map_err(|e| format!("failed to read reference '{}': {e}", args.reference_path))?;
    let reference = read.image;

    let clip = match (
        args.settings.online_clip_low,
        args.settings.online_clip_high,
    ) {
        (Some(low), Some(high)) => Some(OnlineClip { low, high }),
        _ => None,
    };
    let cfg = MasterCreateConfig {
        mode: AccumulationMode::RunningWeightedMean { clip },
        filter: args.filter.clone(),
        target: args.target.clone(),
    };
    let master = IntegratedMaster::create(&reference, &cfg)
        .map_err(|e| format!("master create failed: {e}"))?;

    let sidecar = Path::new(&args.sidecar_path);
    ensure_parent_dir(sidecar)?;
    // A new master replaces whatever was open or journaled at this path.
    forget_open_master(sidecar);
    std::fs::write(sidecar, master.serialize())
        .map_err(|e| format!("failed to write sidecar: {e}"))?;

    // Persist the U16 registration reference next to the sidecar. The committed
    // accumulation state freezes the *geometry* + photometric baseline but not a
    // reference *image*, and the running mean is empty until the first fold — so
    // every `add` aligns its subs against this frozen companion frame, keeping
    // cross-night geometry consistent regardless of fold order.
    let ref_companion = reference_companion_path(sidecar);
    let ref_u16 = ensure_u16(&reference);
    write_fits(&ref_companion, &ref_u16, &{
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "MASTER_REF");
        h
    })
    .map_err(|e| format!("failed to write reference companion: {e:?}"))?;

    Ok(MasterAccumulateResult {
        sidecar_path: args.sidecar_path,
        master_path: None,
        preview_path: None,
        frame_count: master.metadata.total_frames,
        total_integration_sec: master.metadata.total_integration_seconds,
        width: master.geometry.width,
        height: master.geometry.height,
        channels: master.geometry.channels,
        frames_added: 0,
        rejected: 0,
        frame_weights: Vec::new(),
        calibration: None,
        calibration_log_warning: None,
    })
}

/// Folds kept in memory before the sidecar is rewritten. Between rewrites each
/// fold's request is appended to the journal beside the sidecar, so an
/// interrupted process replays it instead of losing it.
const SAVE_EVERY_FOLDS: usize = 16;

/// Longest time an open master's folds stay out of the sidecar.
const SAVE_AFTER: std::time::Duration = std::time::Duration::from_secs(600);

/// The journal of folds not yet in the sidecar: `<sidecar>.journal`, one JSON
/// line per fold, `{"foldsBefore": n, "args": <add request>}`.
pub(crate) fn journal_path(sidecar: &Path) -> std::path::PathBuf {
    let mut p = sidecar.to_path_buf();
    let name = sidecar
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "master".to_string());
    p.set_file_name(format!("{name}.journal"));
    p
}

/// The sidecar's size and modification time, to notice another writer.
fn disk_stamp(path: &Path) -> Option<(u64, std::time::SystemTime)> {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.len(), meta.modified().ok()?))
}

/// The registration reference of an open master, prepared once.
struct FoldReference {
    stars: skotiq_imaging::registration::ReferenceStars,
    planes: Vec<Vec<f64>>,
}

/// An accumulating master held in memory between REST calls, so a fold of one
/// sub does not read and rewrite a sidecar of hundreds of megabytes.
struct OpenMaster {
    sidecar: std::path::PathBuf,
    master: IntegratedMaster,
    stamp: Option<(u64, std::time::SystemTime)>,
    pending: usize,
    saved_at: std::time::Instant,
    reference: Option<FoldReference>,
}

static OPEN_MASTER: std::sync::Mutex<Option<OpenMaster>> = std::sync::Mutex::new(None);

fn lock_open_master() -> std::sync::MutexGuard<'static, Option<OpenMaster>> {
    OPEN_MASTER.lock().unwrap_or_else(|p| p.into_inner())
}

impl OpenMaster {
    /// Write the sidecar atomically and clear the journal.
    fn save(&mut self) -> Result<(), String> {
        if self.pending == 0 {
            return Ok(());
        }
        let tmp = self.sidecar.with_extension("saving");
        std::fs::write(&tmp, self.master.serialize())
            .and_then(|_| std::fs::rename(&tmp, &self.sidecar))
            .map_err(|e| format!("failed to write sidecar: {e}"))?;
        // A journal line whose foldsBefore is below the saved fold count is
        // skipped on replay, so a crash before this removal is harmless.
        let _ = std::fs::remove_file(journal_path(&self.sidecar));
        self.stamp = disk_stamp(&self.sidecar);
        self.pending = 0;
        self.saved_at = std::time::Instant::now();
        Ok(())
    }

    fn prepare_reference(&mut self, reg_cfg: &RegistrationConfig) -> Result<(), String> {
        if self.reference.is_none() {
            let companion = reference_companion_path(&self.sidecar);
            let image = read_image(&companion)
                .map(|r| r.image)
                .map_err(|e| {
                    format!(
                        "failed to read reference companion '{}': {e} (was the master created with this build?)",
                        companion.display()
                    )
                })?;
            let stars = skotiq_imaging::registration::ReferenceStars::detect(&image, reg_cfg)
                .map_err(|e| format!("reference companion: {e}"))?;
            let locations = (image.width as usize) * (image.height as usize);
            let chan = image.channels as usize;
            let pixels = image_to_f64(&image);
            let planes = (0..chan)
                .map(|ch| extract_channel(&pixels, locations, chan, ch))
                .collect();
            self.reference = Some(FoldReference { stars, planes });
        }
        Ok(())
    }
}

/// Open `sidecar`: the master already in memory when nothing changed it on
/// disk, otherwise the sidecar with its journal replayed. Any other open
/// master is saved first.
fn open_master<'a>(
    slot: &'a mut Option<OpenMaster>,
    sidecar: &Path,
) -> Result<&'a mut OpenMaster, String> {
    let current = slot
        .as_ref()
        .is_some_and(|m| m.sidecar == sidecar && m.stamp == disk_stamp(sidecar));
    if !current {
        if let Some(mut other) = slot.take() {
            // Its folds are in its journal, so a master that cannot be saved
            // now (its folder was moved or removed) loses nothing it had.
            if other.sidecar != sidecar {
                if let Err(e) = other.save() {
                    tracing::warn!(
                        "could not save '{}' before opening another master: {e}",
                        other.sidecar.display()
                    );
                }
            }
        }
        let bytes = std::fs::read(sidecar).map_err(|e| format!("failed to read sidecar: {e}"))?;
        let master = IntegratedMaster::deserialize(&bytes).map_err(describe_sidecar_error)?;
        let mut open = OpenMaster {
            sidecar: sidecar.to_path_buf(),
            master,
            stamp: disk_stamp(sidecar),
            pending: 0,
            saved_at: std::time::Instant::now(),
            reference: None,
        };
        replay_journal(&mut open)?;
        *slot = Some(open);
    }
    Ok(slot.as_mut().expect("opened above"))
}

/// Re-fold the journaled requests the sidecar does not contain yet.
fn replay_journal(open: &mut OpenMaster) -> Result<(), String> {
    let journal = journal_path(&open.sidecar);
    let Ok(text) = std::fs::read_to_string(&journal) else {
        return Ok(());
    };
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let Ok(entry) = serde_json::from_str::<serde_json::Value>(line) else {
            // A line cut short by a crash: its add never returned success.
            tracing::warn!("ignoring an incomplete line in '{}'", journal.display());
            continue;
        };
        let before = entry["foldsBefore"].as_u64().unwrap_or(u64::MAX) as usize;
        let folds = open.master.metadata.folds.len();
        if before < folds {
            continue;
        }
        if before > folds {
            return Err(format!(
                "the journal '{}' does not continue the sidecar ({before} folds expected, {folds} present)",
                journal.display()
            ));
        }
        let args: MasterAddArgs = serde_json::from_value(entry["args"].clone())
            .map_err(|e| format!("unreadable journal entry: {e}"))?;
        tracing::info!(
            "replaying a journaled fold of {} subs into '{}'",
            args.light_paths.len(),
            open.sidecar.display()
        );
        fold_into(open, &args, None)?;
        open.pending += 1;
    }
    Ok(())
}

/// Drop the open master and journal for `sidecar` without saving them.
fn forget_open_master(sidecar: &Path) {
    let mut slot = lock_open_master();
    if slot.as_ref().is_some_and(|m| m.sidecar == sidecar) {
        *slot = None;
    }
    let _ = std::fs::remove_file(journal_path(sidecar));
}

/// Drop the open master without saving it, as a crash would.
#[cfg(test)]
pub(crate) fn abandon_open_master() {
    *lock_open_master() = None;
}

/// What one fold did.
struct FoldOutcome {
    report: skotiq_imaging::master_accumulation::AddReport,
    weights: Vec<f64>,
}

/// Calibrate, register and normalize `args`'s lights and fold them into the
/// open master. Calibration is in float with geometric warp coverage, as in a
/// full build.
fn fold_into(
    open: &mut OpenMaster,
    args: &MasterAddArgs,
    cancel: Option<&RunCancelToken>,
) -> Result<FoldOutcome, String> {
    let exposures = exposures_per_light(&args.exposures_sec, args.light_paths.len())?;
    let geom = open.master.geometry.clone();
    let (width, height) = (geom.width as usize, geom.height as usize);
    let chan = geom.channels as usize;
    let locations = width * height;
    let masters = fold_masters(&args.calibration)?;
    let reg_cfg = build_registration_config(&args.settings.align)?;
    let q_cfg = FrameQualityConfig::default();
    let norm_cfg = if args.settings.normalization.enabled {
        Some(build_normalization_config(&args.settings.normalization)?)
    } else {
        None
    };
    open.prepare_reference(&reg_cfg)?;
    let reference = open.reference.as_ref().expect("prepared above");

    let mut buffers: Vec<Vec<f64>> = Vec::new();
    let mut coverages: Vec<CoverageMask> = Vec::new();
    let mut qualities: Vec<FrameQuality> = Vec::new();
    let fold_total = args.light_paths.len() as u32;
    for (i, path) in args.light_paths.iter().enumerate() {
        if let Some(cancel) = cancel {
            cancel.check("registering", Some(i as u32), Some(fold_total))?;
        }
        let exposure = (exposures[i] > 0.0).then_some(exposures[i]);
        let calibrated = calibrate_for_fold(path, exposure, &args.calibration, &masters)?;
        let (transform, _) = skotiq_imaging::registration::solve_registration_against(
            &reference.stars,
            &calibrated.detection,
            &reg_cfg,
        )
        .map_err(|e| format!("registration of '{path}' failed: {e}"))?;
        if (
            calibrated.image.width,
            calibrated.image.height,
            calibrated.image.channels,
        ) != (geom.width, geom.height, geom.channels)
        {
            return Err(format!(
                "'{path}' is {}x{}x{}; the master is {}x{}x{}",
                calibrated.image.width,
                calibrated.image.height,
                calibrated.image.channels,
                geom.width,
                geom.height,
                geom.channels
            ));
        }
        let mut on_grid = OnGrid::new(
            &calibrated.image,
            (geom.width, geom.height),
            &transform,
            reg_cfg.interpolator,
        );
        drop(calibrated);
        let coverage = CoverageMask::new(width, height, on_grid.covered.clone())
            .expect("the mask has one entry per pixel");
        if let Some(cfg) = norm_cfg.as_ref() {
            for (ch, ref_plane) in reference.planes.iter().enumerate() {
                let mut plane = extract_channel(&on_grid.pixels, locations, chan, ch);
                let coeffs =
                    estimate_normalization(&plane, ref_plane, &coverage, width, height, cfg)
                        .map_err(|e| format!("normalization of '{path}' failed: {e}"))?;
                apply_normalization(&mut plane, &coeffs, width, height);
                write_channel(&mut on_grid.pixels, locations, chan, ch, &plane);
            }
        }
        let quality = aligned_quality(
            &on_grid.detection(geom.width, geom.height, geom.channels),
            &q_cfg,
        )
        .ok_or_else(|| format!("could not measure quality of '{path}'"))?;
        buffers.push(on_grid.pixels);
        coverages.push(coverage);
        qualities.push(quality);
    }

    // Weight each fold's subs on a fixed, population-independent quality scale
    // (`accumulation_weights`, anchored on `FrameQuality::neutral`) rather than
    // renormalizing every night to its own best sub, so weights stay
    // comparable across folds.
    let weights: Vec<f64> = if args.settings.weighting.enabled {
        let formula = build_weight_formula(&args.settings.weighting)?;
        accumulation_weights(&qualities, &formula)
    } else {
        vec![1.0; qualities.len()]
    };
    let frames: Vec<IntegrationFrame<'_>> = buffers
        .iter()
        .zip(coverages.iter())
        .zip(weights.iter())
        .map(|((px, cov), &w)| IntegrationFrame {
            pixels: px,
            weight: w,
            coverage: Some(cov),
        })
        .collect();
    let label = if args.label.trim().is_empty() {
        "fold".to_string()
    } else {
        args.label.clone()
    };
    // Last cancellation point: a committed fold must never be reported as
    // cancelled.
    if let Some(cancel) = cancel {
        cancel.check("integrating", None, None)?;
    }
    let report = open
        .master
        .add_frames(&frames, &exposures, &label)
        .map_err(|e| format!("add_frames failed: {e}"))?;
    Ok(FoldOutcome { report, weights })
}

fn result_of(open: &OpenMaster, sidecar_path: String) -> MasterAccumulateResult {
    MasterAccumulateResult {
        sidecar_path,
        master_path: None,
        preview_path: None,
        frame_count: open.master.metadata.total_frames,
        total_integration_sec: open.master.metadata.total_integration_seconds,
        width: open.master.geometry.width,
        height: open.master.geometry.height,
        channels: open.master.geometry.channels,
        frames_added: 0,
        rejected: 0,
        frame_weights: Vec::new(),
        calibration: None,
        calibration_log_warning: None,
    }
}

pub(crate) fn master_add(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterAddArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid add args: {e}"))?;
    if args.sidecar_path.trim().is_empty() {
        return Err("add requires sidecarPath".to_string());
    }
    if args.light_paths.is_empty() {
        return Err("add requires at least one light".to_string());
    }
    // One exposure per light, or none at all. Refused before the fold claims a
    // cancellation id or touches the sidecar: these seconds accumulate into the
    // master's `total_integration_seconds` and are stamped as its FITS `EXPTIME`
    // at finalize, so a short list must not be back-filled with zeros.
    exposures_per_light(&args.exposures_sec, args.light_paths.len())?;

    let cancel = RunCancelToken::register(&args.run_id)?;
    cancel.check("calibrating", None, None)?;

    // What the calibration masters for this fold actually are, measured against
    // the fold's anchor sub.
    let calibration_report = build_calibration_report(&args.light_paths[0], &args.calibration);

    let sidecar = Path::new(&args.sidecar_path);
    let mut slot = lock_open_master();
    let open = open_master(&mut slot, sidecar)?;
    let folds_before = open.master.metadata.folds.len();
    let outcome = match fold_into(open, &args, Some(&cancel)) {
        Ok(outcome) => outcome,
        Err(e) => {
            // A failed fold may have left the in-memory master partly
            // updated; the next call reloads it from disk and journal.
            *slot = None;
            return Err(e);
        }
    };

    // The fold is durable once its request is in the journal; the sidecar is
    // rewritten only every few folds.
    let mut request: serde_json::Value =
        serde_json::from_str(args_json).map_err(|e| format!("invalid add args: {e}"))?;
    if let Some(obj) = request.as_object_mut() {
        obj.remove("runId");
    }
    let line = serde_json::json!({"foldsBefore": folds_before, "args": request}).to_string();
    let journaled = {
        use std::io::Write;
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(journal_path(sidecar))
            .and_then(|mut f| {
                f.write_all(line.as_bytes())?;
                f.write_all(b"\n")?;
                f.sync_data()
            })
    };
    open.pending += 1;
    if journaled.is_err()
        || open.pending >= SAVE_EVERY_FOLDS
        || open.saved_at.elapsed() >= SAVE_AFTER
    {
        if let Err(e) = open.save() {
            *slot = None;
            return Err(e);
        }
    }
    let mut result = result_of(open, args.sidecar_path.clone());
    drop(slot);

    // The fold is committed above, and the caller records which subs went in
    // only when this call succeeds. Returning Err here would therefore make the
    // retry fold the same lights a second time, so a lost provenance record
    // rides back as a warning instead.
    let label = if args.label.trim().is_empty() {
        "fold".to_string()
    } else {
        args.label.clone()
    };
    let calibration_log_warning = append_fold_calibration(
        sidecar,
        FoldCalibration {
            label: label.clone(),
            lights: args.light_paths.len(),
            report: calibration_report.clone(),
        },
    )
    .err();
    if let Some(warning) = calibration_log_warning.as_deref() {
        tracing::warn!(
            "fold '{label}' is committed to '{}' but its calibration could not be recorded: {warning}",
            sidecar.display()
        );
    }
    result.frames_added = outcome.report.frames_added;
    result.rejected = outcome.report.rejected;
    result.frame_weights = outcome.weights;
    result.calibration = Some(calibration_report);
    result.calibration_log_warning = calibration_log_warning;
    Ok(result)
}

pub(crate) fn master_finalize(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterFinalizeArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid finalize args: {e}"))?;
    if args.sidecar_path.trim().is_empty() || args.master_fits_path.trim().is_empty() {
        return Err("finalize requires sidecarPath and masterFitsPath".to_string());
    }
    let sidecar = Path::new(&args.sidecar_path);
    let mut slot = lock_open_master();
    let open = open_master(&mut slot, sidecar)?;
    open.save()?;
    let master = &open.master;
    // A provenance log that cannot be read is reported in the master's HISTORY,
    // not turned into a refusal: the sidecar holds every night already folded in
    // and the log holds only the story of how they were calibrated.
    let calibration_log = match read_fold_calibration_log(sidecar) {
        Ok(log) => Ok(log),
        Err(reason) => {
            tracing::warn!(
                "finalizing '{}' without its calibration record: {reason}",
                sidecar.display()
            );
            Err(reason)
        }
    };

    let image = master.finalize();
    let master_path = Path::new(&args.master_fits_path);
    ensure_parent_dir(master_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq accumulating master");
    header.set_int("NFRAMES", master.metadata.total_frames as i64);
    header.set_int("NCOMBINE", master.metadata.total_frames as i64);
    header.set_float("EXPTIME", master.metadata.total_integration_seconds);
    if let Some(f) = &master.metadata.filter {
        header.set_string("FILTER", f);
    }
    if let Some(t) = &master.metadata.target {
        header.set_string("OBJECT", t);
    }
    header.add_history(&format!(
        "Accumulated from {} frames across {} folds",
        master.metadata.total_frames,
        master.metadata.folds.len()
    ));
    let record = match calibration_log.as_ref() {
        Ok(Some(log)) => FoldCalibrationRecord::Present(log),
        Ok(None) => FoldCalibrationRecord::Missing,
        Err(reason) => FoldCalibrationRecord::Unreadable(reason),
    };
    let calibration_warns =
        write_fold_calibration_history(&mut header, record, master.metadata.folds.len());
    header.set_bool("CALWARN", calibration_warns);
    write_fits(master_path, &image, &header)
        .map_err(|e| format!("failed to write master: {e:?}"))?;

    let preview_path = match args.preview_png_path.as_deref().map(str::trim) {
        Some(p) if !p.is_empty() => {
            write_preview_png(&image, Path::new(p))?;
            Some(p.to_string())
        }
        _ => None,
    };
    let mut result = result_of(open, args.sidecar_path.clone());
    result.master_path = Some(args.master_fits_path);
    result.preview_path = preview_path;
    Ok(result)
}

pub(crate) fn master_info(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterInfoArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid info args: {e}"))?;
    let mut slot = lock_open_master();
    let open = open_master(&mut slot, Path::new(&args.sidecar_path))?;
    Ok(result_of(open, args.sidecar_path))
}

/// Path of the frozen registration-reference companion FITS written next to a
/// master sidecar at `create` and read back on every `add`.
pub(crate) fn reference_companion_path(sidecar: &Path) -> std::path::PathBuf {
    let mut p = sidecar.to_path_buf();
    // `<sidecar>.ref.fits` — appended (not extension-replaced) so distinct
    // sidecars never collide and the link to the sidecar stays obvious.
    let name = sidecar
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "master".to_string());
    p.set_file_name(format!("{name}.ref.fits"));
    p
}

/// Ensure an image is U16 for the U16-only registration path. F32 frames are
/// rescaled from their finite min..max into 0..65535 (registration uses star
/// *positions* only, so the absolute scaling is irrelevant — the per-night
/// normalization against the frozen baseline restores photometry).
pub(crate) fn ensure_u16(image: &ImageData) -> ImageData {
    if image.pixel_type == PixelType::U16 {
        return image.clone();
    }
    to_u16_for_preview(image)
}

// api_build_master_flat implementation

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct BuildMasterFlatArgs {
    /// Raw flat-frame paths.
    pub(crate) flat_paths: Vec<String>,
    /// Optional master bias (short flats) or master dark-flat (long flats) path.
    pub(crate) bias_or_dark_flat: Option<String>,
    /// `"f32"` (default, lossless unit-mean) | `"u16"` (mean 32768).
    pub(crate) output_bit_depth: String,
    /// `"sigmaClip"` (default) | `"median"` | `"mean"`.
    pub(crate) method: String,
    /// Sigma-clip κ / iterations, used only when `method == "sigmaClip"`.
    pub(crate) sigma_kappa: f64,
    pub(crate) sigma_iterations: u32,
    /// Output FITS path (required).
    pub(crate) output_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct BuildMasterFlatResult {
    pub(crate) output_path: String,
    pub(crate) frame_count: u32,
    /// Pre-normalization mean (illumination level).
    pub(crate) input_mean: f64,
    /// Post-normalization mean (≈ unit-mean target).
    pub(crate) output_mean: f64,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    pub(crate) output_bit_depth: String,
    /// Raw flats left out of the master (banded or obstructed), with reasons.
    #[serde(default)]
    pub(crate) excluded: Vec<ExcludedFlat>,
}

// Keep non-FITS inputs supported by the existing image reader. Metadata
// validation is possible only when the input supplies typed FITS cards.
fn flat_metadata(path: &str) -> Result<FitsHeader, String> {
    let path = Path::new(path);
    match path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "fits" | "fit" | "fts" => read_fits_header(path).map_err(|e| {
            format!(
                "failed to read calibration metadata '{}': {e}",
                path.display()
            )
        }),
        _ => Ok(FitsHeader::new()),
    }
}

fn validate_flat_pedestal(flat: &FitsHeader, pedestal: &FitsHeader) -> Result<(), String> {
    if let (Some(a), Some(b)) = (flat.get_string("INSTRUME"), pedestal.get_string("INSTRUME")) {
        if a != b {
            return Err("Flat and bias/dark-flat cameras differ (INSTRUME)".into());
        }
    }
    for key in ["GAIN", "OFFSET", "XBINNING", "YBINNING"] {
        if let (Some(a), Some(b)) = (flat.get_float(key), pedestal.get_float(key)) {
            if (a - b).abs() > 1e-6 {
                return Err(format!("Flat and bias/dark-flat {key} differ"));
            }
        }
    }
    let kind = pedestal
        .get_string("IMAGETYP")
        .unwrap_or_default()
        .to_ascii_lowercase();
    let is_bias = kind.contains("bias") || kind.contains("offset");
    if !is_bias {
        if let (Some(a), Some(b)) = (flat.get_float("EXPTIME"), pedestal.get_float("EXPTIME")) {
            // Dark current in a dark-flat of 0.1 s or less is negligible, so it
            // stands in for a bias. A longer one must match within 10%.
            if b > 0.1 && (a - b).abs() > 0.1 * b {
                return Err(format!(
                    "Dark-flat exposure {b} s does not match a raw flat's {a} s; select a matching dark-flat or a master bias"
                ));
            }
        }
    }
    Ok(())
}

/// The header card that records whether a master flat's pedestal was removed.
pub(crate) const FLAT_PEDESTAL_CARD: &str = "PEDSUB";

/// Whether a flat master read from disk already had its bias or dark-flat
/// removed, so a light's bias must not be subtracted from it again.
///
/// Floating-point flats are normalized response maps. Integer flats count as
/// corrected when their header says so: Skotiq's `PEDSUB` card, a master frame
/// type, or a combine count. A single raw integer flat still carries its bias.
pub(crate) fn flat_pedestal_state(
    image: &ImageData,
    header: Option<&FitsHeader>,
) -> skotiq_imaging::calibration::FlatPedestal {
    use skotiq_imaging::calibration::FlatPedestal;
    if matches!(image.pixel_type, PixelType::F32 | PixelType::F64) {
        return FlatPedestal::Removed;
    }
    let Some(header) = header else {
        return FlatPedestal::Included;
    };
    if let Some(removed) = header.get_bool(FLAT_PEDESTAL_CARD) {
        return if removed {
            FlatPedestal::Removed
        } else {
            FlatPedestal::Included
        };
    }
    let upper = |key: &str| {
        header
            .get_string(key)
            .unwrap_or_default()
            .to_ascii_uppercase()
    };
    let master = upper("FRAMETYP").contains("MASTER")
        || upper("IMAGETYP").contains("MASTER")
        || header.get_int("NCOMBINE").is_some_and(|n| n > 1)
        || header.get_int("NFRAMES").is_some_and(|n| n > 1);
    if master {
        FlatPedestal::Removed
    } else {
        FlatPedestal::Included
    }
}

/// One raw flat left out of a master flat, and why.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct ExcludedFlat {
    pub(crate) path: String,
    pub(crate) reason: String,
}

pub(crate) fn build_master_flat_impl(
    args: BuildMasterFlatArgs,
) -> Result<BuildMasterFlatResult, String> {
    if args.flat_paths.is_empty() {
        return Err("no flat frames supplied".to_string());
    }
    if args.output_path.trim().is_empty() {
        return Err("output_path is required".to_string());
    }

    let source_headers = args
        .flat_paths
        .iter()
        .map(|path| flat_metadata(path))
        .collect::<Result<Vec<_>, _>>()?;
    // Exposure may vary: Skotiq's flat capture adjusts it frame by frame, and
    // each flat is scaled to its own median before combining.
    for header in &source_headers[1..] {
        for key in ["INSTRUME", "FILTER"] {
            if let (Some(first), Some(next)) =
                (source_headers[0].get_string(key), header.get_string(key))
            {
                if first != next {
                    return Err(format!(
                        "Raw flats have different {key}; build each calibration group separately"
                    ));
                }
            }
        }
        for key in ["GAIN", "OFFSET", "XBINNING", "YBINNING"] {
            if let (Some(first), Some(next)) =
                (source_headers[0].get_float(key), header.get_float(key))
            {
                if (first - next).abs() > 1e-6 {
                    return Err(format!(
                        "Raw flats have different {key}; build each calibration group separately"
                    ));
                }
            }
        }
    }
    let exposures: Vec<f64> = source_headers
        .iter()
        .filter_map(|h| h.get_float("EXPTIME"))
        .collect();
    let varied = exposures
        .iter()
        .any(|e| (e - exposures[0]).abs() > 1e-6 * exposures[0].abs().max(1.0));

    let pedestal_path = args
        .bias_or_dark_flat
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty());
    if let Some(path) = pedestal_path {
        let pedestal_header = flat_metadata(path)?;
        for header in &source_headers {
            validate_flat_pedestal(header, &pedestal_header)?;
        }
    } else if varied {
        return Err(
            "Raw flats have different exposures; select a master bias or dark-flat so each flat can be scaled to its own level"
                .into(),
        );
    }
    let pedestal = load_optional_master(&args.bias_or_dark_flat, "bias/dark-flat")?;

    let output_type = match args.output_bit_depth.trim().to_ascii_lowercase().as_str() {
        "" | "f32" => MasterOutputType::F32,
        "u16" => MasterOutputType::U16,
        other => return Err(format!("unknown output bit depth '{other}'")),
    };
    let method = match args.method.trim().to_ascii_lowercase().as_str() {
        "" | "sigmaclip" | "sigma_clip" => CombineMethod::SigmaClip {
            kappa: if args.sigma_kappa > 0.0 {
                args.sigma_kappa
            } else {
                3.0
            },
            iterations: if args.sigma_iterations > 0 {
                args.sigma_iterations
            } else {
                5
            },
        },
        "median" => CombineMethod::Median,
        "mean" => CombineMethod::Mean,
        other => return Err(format!("unknown combine method '{other}'")),
    };

    // Each flat is read, pedestal-corrected and normalized on its own, so only
    // one raw frame is in memory at a time. Banded flats are left out.
    let mut normalized = Vec::with_capacity(args.flat_paths.len());
    let mut levels = Vec::with_capacity(args.flat_paths.len());
    let mut excluded = Vec::new();
    for path in &args.flat_paths {
        let raw = read_image(Path::new(path))
            .map_err(|e| format!("failed to read flat '{path}': {e}"))?
            .image;
        if let Some(bands) = skotiq_imaging::calibration_masters::flat_bands(&raw) {
            tracing::warn!("master flat: leaving out '{path}': {bands}");
            excluded.push(ExcludedFlat {
                path: path.clone(),
                reason: bands,
            });
            continue;
        }
        let (frame, level) =
            skotiq_imaging::calibration_masters::normalize_raw_flat(&raw, pedestal.as_ref())
                .map_err(|e| format!("flat '{path}': {e}"))?;
        normalized.push(frame);
        levels.push(level);
    }
    if normalized.is_empty() {
        return Err(format!(
            "every raw flat is banded or obstructed (first: {}: {}); capture new flats",
            excluded[0].path, excluded[0].reason
        ));
    }

    let config = MasterFlatConfig {
        method,
        output_type,
    };
    let master = build_master_flat(&normalized, None, config)
        .map_err(|e| format!("master-flat build failed: {e}"))?;
    let input_mean = levels.iter().sum::<f64>() / levels.len() as f64;

    let out_path = Path::new(&args.output_path);
    ensure_parent_dir(out_path)?;
    let mut header = source_headers[0].clone();
    header.set_string("IMAGETYP", "FLAT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq master flat");
    header.set_int("NFRAMES", master.frame_count as i64);
    header.set_int("NCOMBINE", master.frame_count as i64);
    header.set_bool(FLAT_PEDESTAL_CARD, pedestal.is_some());
    match pedestal_path {
        Some(path) => header.add_history(&format!(
            "Bias-corrected: {path} subtracted from every raw flat before combining"
        )),
        None => header.add_history("No bias or dark-flat subtracted from the raw flats"),
    }
    header.add_history("Each raw flat scaled to unit median before combining");
    if varied {
        if let (Some(lo), Some(hi)) = (
            exposures.iter().copied().reduce(f64::min),
            exposures.iter().copied().reduce(f64::max),
        ) {
            header.add_history(&format!("Raw flat exposures {lo} s to {hi} s"));
        }
    }
    for flat in &excluded {
        header.add_history(&format!("Left out {}: {}", flat.path, flat.reason));
    }
    // FITS keywords are capped at 8 chars (see `fits::is_valid_keyword`).
    header.set_float("INMEAN", input_mean);
    header.set_float("OUTMEAN", master.output_mean);
    write_fits(out_path, &master.image, &header)
        .map_err(|e| format!("failed to write flat: {e:?}"))?;

    Ok(BuildMasterFlatResult {
        output_path: args.output_path,
        frame_count: master.frame_count,
        input_mean,
        output_mean: master.output_mean,
        width: master.image.width,
        height: master.image.height,
        channels: master.image.channels,
        output_bit_depth: match output_type {
            MasterOutputType::F32 => "f32".to_string(),
            MasterOutputType::U16 => "u16".to_string(),
        },
        excluded,
    })
}

// api_save_fits_master implementation

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SaveFitsMasterArgs {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    /// `"f32"` | `"u16"`.
    pub(crate) pixel_type: String,
    /// F32 sample buffer (channel-interleaved) when `pixelType == "f32"`.
    pub(crate) f32_data: Vec<f32>,
    /// U16 sample buffer (channel-interleaved) when `pixelType == "u16"`.
    pub(crate) u16_data: Vec<u16>,
    pub(crate) output_path: String,
    /// Optional provenance header cards (key → string value).
    pub(crate) object: Option<String>,
    pub(crate) filter: Option<String>,
    pub(crate) frame_count: Option<i64>,
    pub(crate) total_integration_sec: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SaveFitsMasterResult {
    pub(crate) output_path: String,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    pub(crate) pixel_type: String,
}

pub(crate) fn save_fits_master_impl(
    args: SaveFitsMasterArgs,
) -> Result<SaveFitsMasterResult, String> {
    if args.output_path.trim().is_empty() {
        return Err("output_path is required".to_string());
    }
    if args.width == 0 || args.height == 0 || args.channels == 0 {
        return Err("width/height/channels must be > 0".to_string());
    }
    let expected = (args.width as usize) * (args.height as usize) * (args.channels as usize);

    let (image, pt) = match args.pixel_type.trim().to_ascii_lowercase().as_str() {
        "f32" => {
            if args.f32_data.len() != expected {
                return Err(format!(
                    "f32Data has {} samples but width×height×channels = {}",
                    args.f32_data.len(),
                    expected
                ));
            }
            (
                ImageData::from_f32(args.width, args.height, args.channels, &args.f32_data),
                "f32",
            )
        }
        "u16" => {
            if args.u16_data.len() != expected {
                return Err(format!(
                    "u16Data has {} samples but width×height×channels = {}",
                    args.u16_data.len(),
                    expected
                ));
            }
            (
                ImageData::from_u16(args.width, args.height, args.channels, &args.u16_data),
                "u16",
            )
        }
        other => return Err(format!("unknown pixel type '{other}'; expected f32 or u16")),
    };

    let out_path = Path::new(&args.output_path);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq master (re-export)");
    if let Some(o) = &args.object {
        header.set_string("OBJECT", o);
    }
    if let Some(f) = &args.filter {
        header.set_string("FILTER", f);
    }
    if let Some(n) = args.frame_count {
        header.set_int("NFRAMES", n);
    }
    if let Some(s) = args.total_integration_sec {
        header.set_float("EXPTIME", s);
    }
    write_fits(out_path, &image, &header)
        .map_err(|e| format!("failed to write FITS master: {e:?}"))?;

    Ok(SaveFitsMasterResult {
        output_path: args.output_path,
        width: args.width,
        height: args.height,
        channels: args.channels,
        pixel_type: pt.to_string(),
    })
}
