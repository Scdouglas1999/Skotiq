use super::*;

/// A light frame loaded, calibrated, and ready to register: kept around so the
/// reference can be picked after every sub's quality is known.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct LoadedLight {
    pub(crate) path: String,
    pub(crate) image: ImageData,
    pub(crate) exposure_sec: f64,
    /// The sub's own FITS keywords, kept from the single read so the master can
    /// inherit FILTER/OBJECT/INSTRUME/DATE-OBS without re-opening every file.
    pub(crate) header: std::collections::HashMap<String, String>,
}

pub(crate) fn integrate_session(
    args: IntegrateSessionArgs,
) -> Result<IntegrateSessionResult, String> {
    if args.light_paths.is_empty() {
        return Err("no light frames supplied".to_string());
    }
    if args.output.master_fits_path.trim().is_empty() {
        return Err("output.masterFitsPath is required".to_string());
    }
    // One exposure per light, or none at all. Refused before the run claims a
    // cancellation id: a mismatched request is never a run.
    let exposures = exposures_per_light(&args.exposures_sec, args.light_paths.len())?;

    let cancel = RunCancelToken::register(&args.run_id)?;
    cancel.check("calibrating", None, None)?;

    // Load calibration masters once (shared across all lights).
    let dark = load_optional_master(&args.calibration.dark, "dark")?;
    let flat = load_optional_master(&args.calibration.flat, "flat")?;
    let bias = load_optional_master(&args.calibration.bias, "bias")?;

    // What the masters above actually are, measured against the group's anchor
    // sub — the same first-sub anchor the Dart matcher selects on.
    let calibration_report = build_calibration_report(&args.light_paths[0], &args.calibration);

    // Load + calibrate every light.
    let total_lights = args.light_paths.len() as u32;
    emit_integration_progress(
        "calibrating",
        FRACTION_CALIBRATE,
        Some(0),
        Some(total_lights),
    );
    let mut loaded: Vec<LoadedLight> = Vec::with_capacity(args.light_paths.len());
    for (i, path) in args.light_paths.iter().enumerate() {
        cancel.check("calibrating", Some(i as u32), Some(total_lights))?;
        let read =
            read_image(Path::new(path)).map_err(|e| format!("failed to read '{path}': {e}"))?;
        let source_header = read.header;
        let mut image = read.image;
        if image.pixel_type != PixelType::U16 {
            return Err(format!(
                "light '{path}' is {:?}; registration requires U16 (debayer/convert first)",
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
            // Self-derived hot/cold transient repair (cosmic rays, residual hot
            // pixels). Operates per-channel in place; the RETURNED REPORT is
            // advisory, but the error is not: the calibration report stamps
            // `cosmetic correction: applied` straight off this request flag
            // (`build_calibration_report`), so a swallowed failure here writes a
            // master that claims a repair it never ran.
            cosmetic_correct_transient(&mut image, CosmeticConfig::default())
                .map_err(|e| format!("cosmetic correction of '{path}' failed: {e}"))?;
        }
        // `exposures_per_light` guaranteed one entry per light, so `i` is in range.
        loaded.push(LoadedLight {
            path: path.clone(),
            image,
            exposure_sec: exposures[i],
            header: source_header,
        });
        // Calibrate phase spans 0.0..0.20 across all lights.
        let done = (i + 1) as u32;
        let frac = if total_lights > 0 {
            FRACTION_REGISTER * (done as f32 / total_lights as f32)
        } else {
            FRACTION_REGISTER
        };
        emit_integration_progress("calibrating", frac, Some(done), Some(total_lights));
    }

    // Choose the reference frame.
    // The registration config is built first: reference choice must consult the
    // same star detector the registration will use.
    cancel.check("reference", None, None)?;
    let reg_cfg = build_registration_config(&args.settings.align)?;
    let q_cfg = FrameQualityConfig::default();
    let ref_index = choose_reference(&args.reference, &loaded, &q_cfg, &reg_cfg)?;
    let reference = &loaded[ref_index].image;
    let width = reference.width;
    let height = reference.height;
    let channels = reference.channels;
    let locations = (width as usize) * (height as usize);
    let chan = channels as usize;

    // Register every light onto the reference.
    // Per-frame outputs, aligned to `loaded`.
    struct Registered {
        path: String,
        // f64 channel-interleaved aligned pixels on the reference grid.
        pixels: Vec<f64>,
        coverage: CoverageMask,
        rms_residual_px: Option<f64>,
        exposure_sec: f64,
        // Quality measured on the *aligned* luminance plane.
        quality: Option<FrameQuality>,
        accepted: bool,
        reason: Option<String>,
        // Source→reference homogeneous transform fitted during registration
        // (identity for the reference). `None` only when registration failed.
        // Surfaced to Dart so the drizzle flow can deposit each sub's raw,
        // un-resampled pixels onto the finer output grid using this transform.
        transform: Option<TransformModel>,
    }

    emit_integration_progress(
        "registering",
        FRACTION_REGISTER,
        Some(0),
        Some(total_lights),
    );
    let mut registered: Vec<Registered> = Vec::with_capacity(loaded.len());
    for (i, light) in loaded.iter().enumerate() {
        // Registering one full-sensor frame is the pipeline's longest
        // uninterruptible step, so the flag is read before each one rather than
        // only at the phase boundary.
        cancel.check("registering", Some(i as u32), Some(total_lights))?;
        // Register phase spans 0.20..0.60; emit per frame (cheap), never per
        // pixel. Emitted at the top so both the reference (`continue`) and the
        // matched branches report uniform per-frame progress.
        let done = (i + 1) as u32;
        let frac = if total_lights > 0 {
            FRACTION_REGISTER
                + (FRACTION_WEIGHT - FRACTION_REGISTER) * (done as f32 / total_lights as f32)
        } else {
            FRACTION_WEIGHT
        };
        emit_integration_progress("registering", frac, Some(done), Some(total_lights));

        if i == ref_index {
            // The reference aligns to itself by identity; flatten directly.
            let pixels = image_to_f64(&light.image);
            let coverage = CoverageMask::full(width as usize, height as usize);
            let quality = aligned_quality(&light.image, &q_cfg);
            registered.push(Registered {
                path: light.path.clone(),
                pixels,
                coverage,
                rms_residual_px: Some(0.0),
                exposure_sec: light.exposure_sec,
                quality,
                accepted: true,
                reason: None,
                transform: Some(TransformModel::identity()),
            });
            continue;
        }

        match register_frame(reference, &light.image, &reg_cfg) {
            Ok(reg) => {
                let pixels = image_to_f64(&reg.aligned);
                let coverage = CoverageMask::from_zero_fill(
                    &derive_luma_f64(&pixels, locations, chan),
                    width as usize,
                    height as usize,
                );
                let quality = aligned_quality(&reg.aligned, &q_cfg);
                registered.push(Registered {
                    path: light.path.clone(),
                    pixels,
                    coverage,
                    rms_residual_px: Some(reg.stats.rms_residual_px),
                    exposure_sec: light.exposure_sec,
                    quality,
                    accepted: true,
                    reason: None,
                    transform: Some(reg.transform),
                });
            }
            Err(e) => {
                // A sub that cannot be registered is dropped (not fatal): the
                // rest of the night still integrates. Recorded honestly so the
                // UI can show why.
                registered.push(Registered {
                    path: light.path.clone(),
                    pixels: Vec::new(),
                    coverage: CoverageMask::full(0, 0),
                    rms_residual_px: None,
                    exposure_sec: light.exposure_sec,
                    quality: None,
                    accepted: false,
                    reason: Some(format!("registration failed: {e}")),
                    transform: None,
                });
            }
        }
    }

    // Weight the accepted subs.
    let accepted_idx: Vec<usize> = registered
        .iter()
        .enumerate()
        .filter(|(_, r)| r.accepted && r.quality.is_some())
        .map(|(i, _)| i)
        .collect();
    if accepted_idx.is_empty() {
        return Err("no subs could be registered + measured; nothing to integrate".to_string());
    }

    cancel.check("weighting", None, None)?;
    emit_integration_progress("weighting", FRACTION_WEIGHT, None, None);
    let weights: Vec<f64> = if args.settings.weighting.enabled {
        let qualities: Vec<FrameQuality> = accepted_idx
            .iter()
            .map(|&i| registered[i].quality.expect("filtered to Some"))
            .collect();
        let formula = build_weight_formula(&args.settings.weighting)?;
        let report = weight_frames(&qualities, &formula, &CullPolicy::default())
            .ok_or_else(|| "weighting produced no result".to_string())?;
        report.frames.iter().map(|f| f.weight).collect()
    } else {
        vec![1.0; accepted_idx.len()]
    };

    // Reference luminance for normalization (the anchor).
    // Use the *registered* reference buffer (already on the grid).
    let ref_reg_pos = accepted_idx
        .iter()
        .position(|&i| i == ref_index)
        .ok_or_else(|| "reference frame was dropped during registration".to_string())?;
    let ref_pixels = registered[ref_index].pixels.clone();

    // Normalize each accepted sub to the reference, per channel.
    let norm_total = accepted_idx.len() as u32;
    emit_integration_progress("normalizing", FRACTION_NORMALIZE, Some(0), Some(norm_total));
    if args.settings.normalization.enabled {
        let norm_cfg = build_normalization_config(&args.settings.normalization)?;
        // Per-channel reference planes (borrowed once).
        let ref_planes: Vec<Vec<f64>> = (0..chan)
            .map(|ch| extract_channel(&ref_pixels, locations, chan, ch))
            .collect();
        for (pos, &i) in accepted_idx.iter().enumerate() {
            cancel.check("normalizing", Some(pos as u32), Some(norm_total))?;
            // Normalize phase spans 0.62..0.80; emit per accepted sub (cheap),
            // emitted at the top so the reference (`continue`) frame still
            // advances the bar.
            let done = (pos + 1) as u32;
            let frac = if norm_total > 0 {
                FRACTION_NORMALIZE
                    + (FRACTION_INTEGRATE - FRACTION_NORMALIZE) * (done as f32 / norm_total as f32)
            } else {
                FRACTION_INTEGRATE
            };
            emit_integration_progress("normalizing", frac, Some(done), Some(norm_total));

            if i == ref_index {
                continue;
            }
            let coverage = registered[i].coverage.clone();
            for (ch, ref_plane) in ref_planes.iter().enumerate() {
                let mut plane = extract_channel(&registered[i].pixels, locations, chan, ch);
                let coeffs = estimate_normalization(
                    &plane,
                    ref_plane,
                    &coverage,
                    width as usize,
                    height as usize,
                    &norm_cfg,
                )
                .map_err(|e| format!("normalization of '{}' failed: {e}", registered[i].path))?;
                apply_normalization(&mut plane, &coeffs, width as usize, height as usize);
                write_channel(&mut registered[i].pixels, locations, chan, ch, &plane);
            }
        }
    }
    let _ = ref_reg_pos; // reference normalizes to identity; kept for clarity.

    // Integrate.
    let sub_count = accepted_idx.len();
    let int_cfg = build_integration_config(&args.settings.integration, sub_count)?;
    let frames: Vec<IntegrationFrame<'_>> = accepted_idx
        .iter()
        .zip(weights.iter())
        .map(|(&i, &w)| IntegrationFrame {
            pixels: &registered[i].pixels,
            weight: w,
            coverage: Some(&registered[i].coverage),
        })
        .collect();

    // `integrate_frames` has no inner progress callback, so bracket it: 0.80
    // before, 0.92 after. It is also the last point a cancellation can be
    // honoured cheaply — the combine itself runs to completion once entered.
    cancel.check("integrating", None, None)?;
    emit_integration_progress("integrating", FRACTION_INTEGRATE, None, None);
    let output = integrate_frames(&frames, width, height, channels, &int_cfg)
        .map_err(|e| format!("integration failed: {e}"))?;
    emit_integration_progress("integrating", FRACTION_INTEGRATE_DONE, None, None);

    // Write the master FITS. This is the last cancellation point: past the
    // write the master exists, and a run that reported itself cancelled while a
    // complete master sat on disk would misdescribe it.
    cancel.check("writing", None, None)?;
    emit_integration_progress("writing", FRACTION_WRITE, None, None);
    let master_path = Path::new(&args.output.master_fits_path);
    ensure_parent_dir(master_path)?;
    // Carry the reference frame's plate-solved WCS into the master so the mosaic
    // stitcher can place this panel without a post-hoc solve. Best-effort: a
    // reference with no WCS leaves the master WCS-less (the stitch gates it out).
    let reference_wcs = reference_wcs_from_fits(&loaded[ref_index].path);
    // Provenance comes from the ACCEPTED subs only: a frame that was rejected
    // contributed no signal and must not name the master's filter or pull
    // DATE-OBS earlier than the data actually integrated.
    let accepted_headers: Vec<_> = accepted_idx
        .iter()
        .map(|&i| loaded[i].header.clone())
        .collect();
    let accepted_exposures: Vec<f64> = accepted_idx
        .iter()
        .map(|&i| loaded[i].exposure_sec)
        .collect();
    let provenance = collect_master_provenance(&accepted_headers, &accepted_exposures);
    let header = build_master_header(
        sub_count,
        &args.settings.integration,
        &int_cfg.reject,
        &provenance,
        reference_wcs.as_ref(),
        &calibration_report,
    );
    write_fits(master_path, &output.master, &header)
        .map_err(|e| format!("failed to write master FITS: {e:?}"))?;

    // Optional rejection map FITS.
    let rejection_map_path = if let (Some(p), Some(map)) = (
        args.output.rejection_map_path.as_ref(),
        output.rejection_map.as_ref(),
    ) {
        if !p.trim().is_empty() {
            let path = Path::new(p);
            ensure_parent_dir(path)?;
            let mut h = FitsHeader::new();
            h.set_string("IMAGETYP", "REJECTION_MAP");
            h.add_history("Skotiq post-session rejection-count map");
            write_fits(path, map, &h)
                .map_err(|e| format!("failed to write rejection map: {e:?}"))?;
            Some(p.clone())
        } else {
            None
        }
    } else {
        None
    };

    // Optional stretched rejection-map PNG.
    // Flutter cannot decode the scientific FITS map directly. Keep that FITS
    // for inspection and emit a real image sibling for Session Review.
    let rejection_map_preview_path = if let (Some(p), Some(map)) = (
        args.output.rejection_map_preview_path.as_ref(),
        output.rejection_map.as_ref(),
    ) {
        if !p.trim().is_empty() {
            match write_preview_png(map, Path::new(p)) {
                Ok(()) => Some(p.clone()),
                Err(e) => {
                    tracing::warn!(
                        path = %p,
                        error = %e,
                        "rejection preview PNG write failed; keeping master and FITS map"
                    );
                    None
                }
            }
        } else {
            None
        }
    } else {
        None
    };

    // Optional stretched preview PNG.
    let preview_path = if let Some(p) = args.output.preview_png_path.as_ref() {
        if !p.trim().is_empty() {
            write_preview_png(&output.master, Path::new(p))?;
            Some(p.clone())
        } else {
            None
        }
    } else {
        None
    };
    // Final boundary: the master (and optional preview) are on disk.
    emit_integration_progress("preview", FRACTION_DONE, None, None);

    // Assemble per-frame stats + aggregate residual.
    // Map normalized weights back to the accepted frames by position.
    let mut weight_by_index: std::collections::HashMap<usize, f64> =
        std::collections::HashMap::new();
    for (pos, &i) in accepted_idx.iter().enumerate() {
        weight_by_index.insert(i, weights[pos]);
    }

    let mut per_frame_stats = Vec::with_capacity(registered.len());
    let mut residual_sum = 0.0;
    let mut residual_n = 0usize;
    let mut total_integration_sec = 0.0;
    let mut frames_rejected = 0usize;
    for (i, r) in registered.iter().enumerate() {
        let weight = weight_by_index.get(&i).copied().unwrap_or(0.0);
        if r.accepted {
            if let Some(rms) = r.rms_residual_px {
                if i != ref_index {
                    residual_sum += rms;
                    residual_n += 1;
                }
            }
            total_integration_sec += r.exposure_sec;
        } else {
            frames_rejected += 1;
        }
        // Thread this sub's own measured FrameQuality into the record so the
        // Dart side can persist per-sub snr/fwhm/eccentricity (the v42
        // `integrated_master_frames` columns the Night Doctor reads). Quality is
        // `None` only for subs that failed registration/measurement.
        per_frame_stats.push(PerFrameRecord {
            path: r.path.clone(),
            weight,
            rms_residual_px: r.rms_residual_px,
            accepted: r.accepted,
            reason: r.reason.clone(),
            snr: r.quality.map(|q| q.snr),
            // Surface the same measured quality the optimizer needs: `noise`
            // (its variance term) plus the background/star_count context. Without
            // `noise` the Dart morning-report curve is structurally dead.
            noise: r.quality.map(|q| q.noise),
            background: r.quality.map(|q| q.background),
            star_count: r.quality.map(|q| q.star_count),
            fwhm: r.quality.map(|q| q.fwhm),
            eccentricity: r.quality.and_then(|q| q.eccentricity),
            transform: r.transform.as_ref().map(transform_to_row_major),
            transform_kind: r
                .transform
                .as_ref()
                .map(|t| transform_kind_wire(t.kind).to_string()),
        });
    }
    let rms_residual = if residual_n > 0 {
        residual_sum / residual_n as f64
    } else {
        0.0
    };

    Ok(IntegrateSessionResult {
        master_fits_path: args.output.master_fits_path.clone(),
        preview_path,
        rejection_map_path,
        rejection_map_preview_path,
        frames_integrated: output.stats.frames_integrated,
        frames_rejected,
        total_integration_sec,
        rms_residual,
        width,
        height,
        channels,
        per_frame_stats,
        calibration: calibration_report,
    })
}
