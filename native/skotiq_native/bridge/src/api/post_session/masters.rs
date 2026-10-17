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
    let exposures = exposures_per_light(&args.exposures_sec, args.light_paths.len())?;

    let cancel = RunCancelToken::register(&args.run_id)?;
    cancel.check("calibrating", None, None)?;

    // What the calibration masters for this fold actually are, measured against
    // the fold's anchor sub.
    let calibration_report = build_calibration_report(&args.light_paths[0], &args.calibration);

    let sidecar = Path::new(&args.sidecar_path);
    let bytes = std::fs::read(sidecar).map_err(|e| format!("failed to read sidecar: {e}"))?;
    let mut master = IntegratedMaster::deserialize(&bytes).map_err(describe_sidecar_error)?;

    let geom = master.geometry.clone();
    let width = geom.width;
    let height = geom.height;
    let channels = geom.channels;
    let locations = (width as usize) * (height as usize);
    let chan = channels as usize;

    // Load + calibrate masters once.
    let dark = load_optional_master(&args.calibration.dark, "dark")?;
    let flat = load_optional_master(&args.calibration.flat, "flat")?;
    let bias = load_optional_master(&args.calibration.bias, "bias")?;

    // Register against the frozen reference companion written at `create` (the
    // running mean is empty until the first fold, so we cannot use it as the
    // alignment anchor — and using a frozen anchor keeps every night's geometry
    // mutually consistent regardless of fold order).
    let ref_companion = reference_companion_path(sidecar);
    let ref_image = read_image(&ref_companion)
        .map(|r| r.image)
        .map_err(|e| {
            format!(
                "failed to read reference companion '{}': {e} (was the master created with this build?)",
                ref_companion.display()
            )
        })?;

    let reg_cfg = build_registration_config(&args.settings.align)?;
    let q_cfg = FrameQualityConfig::default();

    // Build the per-sub aligned + normalized f64 buffers and weights.
    let mut buffers: Vec<Vec<f64>> = Vec::new();
    let mut coverages: Vec<CoverageMask> = Vec::new();
    let mut qualities: Vec<FrameQuality> = Vec::new();

    let norm_cfg = if args.settings.normalization.enabled {
        Some(build_normalization_config(&args.settings.normalization)?)
    } else {
        None
    };
    let ref_planes: Option<Vec<Vec<f64>>> = norm_cfg.as_ref().map(|_| {
        let ref_f64 = image_to_f64(&ref_image);
        (0..chan)
            .map(|ch| extract_channel(&ref_f64, locations, chan, ch))
            .collect()
    });

    let fold_total = args.light_paths.len() as u32;
    for (i, path) in args.light_paths.iter().enumerate() {
        // Each iteration registers and normalizes one full-sensor frame, so the
        // flag is read before every sub rather than once for the fold.
        cancel.check("registering", Some(i as u32), Some(fold_total))?;
        let read =
            read_image(Path::new(path)).map_err(|e| format!("failed to read '{path}': {e}"))?;
        let mut image = read.image;
        if image.pixel_type != PixelType::U16 {
            return Err(format!(
                "light '{path}' is {:?}; expected U16",
                image.pixel_type
            ));
        }
        if dark.is_some() || flat.is_some() || bias.is_some() {
            image = skotiq_imaging::calibration::calibrate_frame(
                &image,
                dark.as_ref(),
                flat.as_ref(),
                bias.as_ref(),
            )
            .map_err(|e| format!("calibration of '{path}' failed: {e}"))?;
        }
        if args.calibration.cosmetic_correction {
            // The returned report is advisory; the error is not. The fold's
            // calibration record states `cosmetic correction: applied` from the
            // request flag alone, so a swallowed failure here folds a frame that
            // never got the repair into a master that claims it.
            cosmetic_correct_transient(&mut image, CosmeticConfig::default())
                .map_err(|e| format!("cosmetic correction of '{path}' failed: {e}"))?;
        }

        let reg = register_frame(&ref_image, &image, &reg_cfg)
            .map_err(|e| format!("registration of '{path}' failed: {e}"))?;
        // Geometry guard: aligned frame must match the master grid.
        frame_buffer_for_master(i, &reg.aligned, &geom).map_err(|e| format!("'{path}': {e}"))?;

        let mut pixels = image_to_f64(&reg.aligned);
        let coverage = CoverageMask::from_zero_fill(
            &derive_luma_f64(&pixels, locations, chan),
            width as usize,
            height as usize,
        );

        if let (Some(cfg), Some(planes)) = (norm_cfg.as_ref(), ref_planes.as_ref()) {
            for (ch, ref_plane) in planes.iter().enumerate() {
                let mut plane = extract_channel(&pixels, locations, chan, ch);
                let coeffs = estimate_normalization(
                    &plane,
                    ref_plane,
                    &coverage,
                    width as usize,
                    height as usize,
                    cfg,
                )
                .map_err(|e| format!("normalization of '{path}' failed: {e}"))?;
                apply_normalization(&mut plane, &coeffs, width as usize, height as usize);
                write_channel(&mut pixels, locations, chan, ch, &plane);
            }
        }

        let quality = aligned_quality(&reg.aligned, &q_cfg)
            .ok_or_else(|| format!("could not measure quality of '{path}'"))?;

        buffers.push(pixels);
        coverages.push(coverage);
        qualities.push(quality);
    }

    // Weight each fold's subs on a fixed, population-independent quality scale
    // (`accumulation_weights`, anchored on `FrameQuality::neutral`) rather than
    // renormalizing every night to its own best sub. The accumulating master
    // sums weights across folds, so a per-fold max-normalization (`weight_frames`)
    // would reset each night's best sub to 1.0 and erase real cross-night quality
    // differences — a uniformly worse night would contribute as much weight as a
    // pristine one. Anchoring on a fixed reference keeps the weights comparable
    // across folds while leaving a single-night master unchanged (a weighted mean
    // is invariant to a global weight rescale).
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
    // Last cancellation point: the fold commits to the sidecar below, and a
    // committed fold must never be reported as cancelled.
    cancel.check("integrating", None, None)?;
    let report = master
        .add_frames(&frames, &exposures, &label)
        .map_err(|e| format!("add_frames failed: {e}"))?;

    std::fs::write(sidecar, master.serialize())
        .map_err(|e| format!("failed to write sidecar: {e}"))?;

    // The sidecar carries no calibration, and the FITS is only written at
    // `finalize` — possibly nights later, in another process. The log beside the
    // sidecar is where this fold's calibration survives until then.
    //
    // The fold is committed above, and the caller records which subs went in
    // only when this call succeeds. Returning Err here would therefore make the
    // retry fold the same lights a second time — inflating the frame count and
    // weighting the pixels with duplicated data — to punish a provenance file.
    // The lost provenance rides back as a warning instead.
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

    Ok(MasterAccumulateResult {
        sidecar_path: args.sidecar_path,
        master_path: None,
        preview_path: None,
        frame_count: master.metadata.total_frames,
        total_integration_sec: master.metadata.total_integration_seconds,
        width,
        height,
        channels,
        frames_added: report.frames_added,
        rejected: report.rejected,
        frame_weights: weights,
        calibration: Some(calibration_report),
        calibration_log_warning,
    })
}

pub(crate) fn master_finalize(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterFinalizeArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid finalize args: {e}"))?;
    if args.sidecar_path.trim().is_empty() || args.master_fits_path.trim().is_empty() {
        return Err("finalize requires sidecarPath and masterFitsPath".to_string());
    }
    let sidecar = Path::new(&args.sidecar_path);
    let bytes = std::fs::read(sidecar).map_err(|e| format!("failed to read sidecar: {e}"))?;
    let master = IntegratedMaster::deserialize(&bytes).map_err(describe_sidecar_error)?;
    // A provenance log that cannot be read is reported in the master's HISTORY,
    // not turned into a refusal: the sidecar holds every night already folded in
    // and the log holds only the story of how they were calibrated. Blocking the
    // FITS would cost the operator the data to protect the record of it.
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

    let preview_path = if let Some(p) = args.preview_png_path.as_ref() {
        if !p.trim().is_empty() {
            write_preview_png(&image, Path::new(p))?;
            Some(p.clone())
        } else {
            None
        }
    } else {
        None
    };

    Ok(MasterAccumulateResult {
        sidecar_path: args.sidecar_path,
        master_path: Some(args.master_fits_path),
        preview_path,
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

pub(crate) fn master_info(args_json: &str) -> Result<MasterAccumulateResult, String> {
    let args: MasterInfoArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid info args: {e}"))?;
    let bytes =
        std::fs::read(&args.sidecar_path).map_err(|e| format!("failed to read sidecar: {e}"))?;
    let master = IntegratedMaster::deserialize(&bytes).map_err(describe_sidecar_error)?;
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

    let flats: Vec<ImageData> = args
        .flat_paths
        .iter()
        .map(|p| {
            read_image(Path::new(p))
                .map(|r| r.image)
                .map_err(|e| format!("failed to read flat '{p}': {e}"))
        })
        .collect::<Result<_, _>>()?;

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
        }, // sigma_iterations is u32 (see SigmaClip below)
        "median" => CombineMethod::Median,
        "mean" => CombineMethod::Mean,
        other => return Err(format!("unknown combine method '{other}'")),
    };

    let config = MasterFlatConfig {
        method,
        output_type,
    };
    let master = build_master_flat(&flats, pedestal.as_ref(), config)
        .map_err(|e| format!("master-flat build failed: {e}"))?;

    let out_path = Path::new(&args.output_path);
    ensure_parent_dir(out_path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "FLAT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq master flat");
    header.set_int("NFRAMES", master.frame_count as i64);
    // FITS keywords are capped at 8 chars (see `fits::is_valid_keyword`).
    header.set_float("INMEAN", master.input_mean);
    header.set_float("OUTMEAN", master.output_mean);
    write_fits(out_path, &master.image, &header)
        .map_err(|e| format!("failed to write flat: {e:?}"))?;

    Ok(BuildMasterFlatResult {
        output_path: args.output_path,
        frame_count: master.frame_count,
        input_mean: master.input_mean,
        output_mean: master.output_mean,
        width: master.image.width,
        height: master.image.height,
        channels: master.image.channels,
        output_bit_depth: match output_type {
            MasterOutputType::F32 => "f32".to_string(),
            MasterOutputType::U16 => "u16".to_string(),
        },
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
