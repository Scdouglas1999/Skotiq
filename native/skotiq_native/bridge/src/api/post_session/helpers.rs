use super::*;

/// Read an optional calibration master by path. Empty / `None` → `Ok(None)`.
pub(crate) fn load_optional_master(
    path: &Option<String>,
    label: &str,
) -> Result<Option<ImageData>, String> {
    match path {
        Some(p) if !p.trim().is_empty() => {
            let read = read_image(Path::new(p))
                .map_err(|e| format!("failed to read {label} master '{p}': {e}"))?;
            Ok(Some(read.image))
        }
        _ => Ok(None),
    }
}

/// Expand the caller's `exposuresSec` into exactly one exposure per light,
/// refusing any list that is neither empty nor as long as the frame list, and
/// any entry that is not a real, non-negative number of seconds.
///
/// An omitted / empty list is the documented "no exposure metadata" shape and
/// reports every frame as 0 s. A list that is *present but the wrong length* is
/// a different thing: back-filling its tail with 0 s silently under-reports
/// `totalIntegrationSec`, and on the accumulating path those missing seconds
/// become the master's FITS `EXPTIME` card. The HTTP surfaces
/// (`POST /api/post-session/integrate`, `.../master-accumulate`) forward request
/// bodies to the bridge unvalidated, so the refusal has to live here.
///
/// The same argument applies to the VALUES, which went unchecked: three lights
/// at -100 s produced a succeeded job reporting `totalIntegrationSec: -300.0`
/// and an 8 MB master on disk, while the accumulating path folded the same
/// input into a master whose header read `NFRAMES = 2, EXPTIME = 0.0` — two
/// wrong answers for one impossible input, neither refused. No exposure can run
/// backwards or last a NaN, and the project's own D1 harness treats a master
/// with `<= 0` integration seconds as a defect signal.
///
/// Zero is allowed: it is what an omitted list already means per frame.
pub(crate) fn exposures_per_light(
    exposures_sec: &[f64],
    lights: usize,
) -> Result<Vec<f64>, String> {
    if exposures_sec.is_empty() {
        return Ok(vec![0.0; lights]);
    }
    if exposures_sec.len() != lights {
        return Err(format!(
            "exposuresSec has {} entries but {lights} light frames were supplied; \
             supply one exposure per light, or omit exposuresSec entirely",
            exposures_sec.len()
        ));
    }
    // Name the index AND the value: the caller sent a list, and "one of them is
    // bad" leaves them to bisect it themselves.
    for (index, seconds) in exposures_sec.iter().enumerate() {
        if !seconds.is_finite() {
            return Err(format!(
                "exposuresSec[{index}] is {seconds}, which is not a number of \
                 seconds; every entry must be a finite value >= 0"
            ));
        }
        if *seconds < 0.0 {
            return Err(format!(
                "exposuresSec[{index}] is {seconds}, a negative exposure; every \
                 entry must be a finite value >= 0"
            ));
        }
    }
    Ok(exposures_sec.to_vec())
}

/// Pick the reference frame index: an explicit path among the loaded lights, or
/// (for `"auto"`/empty) the highest-quality sub by an SNR·sharpness·roundness
/// composite measured on the *un-aligned* light.
///
/// The quality composite alone is not sufficient. Every other sub is registered
/// AGAINST this frame, so a candidate the registration star detector cannot see
/// fails the whole night rather than just itself — and the two measures
/// disagree in practice: a frame carrying one near-saturated star scores highest
/// on SNR while yielding zero detected centroids. Candidates are therefore taken
/// in quality order and the first that is actually registrable wins.
pub(crate) fn choose_reference(
    reference: &Option<String>,
    loaded: &[LoadedLight],
    q_cfg: &FrameQualityConfig,
    reg_cfg: &RegistrationConfig,
) -> Result<usize, String> {
    let min_stars = min_registration_stars(reg_cfg.transform_kind);

    if let Some(r) = reference {
        let r = r.trim();
        if !r.is_empty() && !r.eq_ignore_ascii_case("auto") {
            let idx = loaded
                .iter()
                .position(|l| l.path == r)
                .ok_or_else(|| format!("reference '{r}' is not among the supplied lights"))?;
            // An explicitly chosen reference is honoured, but not silently: if
            // it cannot be registered against, say so instead of failing every
            // other sub one by one with a confusing per-frame reason.
            let stars = registrable_star_count(&loaded[idx].image, reg_cfg);
            if stars < min_stars {
                return Err(format!(
                    "reference '{r}' has only {stars} detectable stars (need >= {min_stars}); \
                     every other sub would fail to register against it"
                ));
            }
            return Ok(idx);
        }
    }

    // Auto: candidates in descending composite quality, first registrable wins.
    let mut candidates: Vec<(usize, f64)> = loaded
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let score = match aligned_quality(&l.image, q_cfg) {
                Some(q) => {
                    let round = q.eccentricity.map(|e| (1.0 - e).max(0.0)).unwrap_or(1.0);
                    let sharp = if q.fwhm > 0.0 { 1.0 / q.fwhm } else { 0.0 };
                    q.snr.max(0.0) * sharp * round
                }
                None => f64::NEG_INFINITY,
            };
            // A starless frame yields fwhm 0 and, on a frame whose noise
            // estimate collapses to zero, snr ∞ — so the product is NaN.
            // `total_cmp` orders a positive NaN ABOVE +∞, which would hand the
            // reference to the worst possible candidate; rank it last instead.
            let score = if score.is_nan() {
                f64::NEG_INFINITY
            } else {
                score
            };
            (i, score)
        })
        .collect();
    candidates.sort_by(|a, b| b.1.total_cmp(&a.1));

    let mut best_star_count = 0usize;
    for (i, _) in &candidates {
        let stars = registrable_star_count(&loaded[*i].image, reg_cfg);
        if stars >= min_stars {
            return Ok(*i);
        }
        best_star_count = best_star_count.max(stars);
    }

    Err(format!(
        "could not find a usable reference frame: no sub yielded at least {min_stars} \
         detectable stars (best was {best_star_count} across {} subs)",
        loaded.len()
    ))
}

/// Measure [`FrameQuality`] on an image, deriving a luminance plane for RGB so
/// the metric is channel-agnostic (the weighting + reference math expects a
/// single plane).
pub(crate) fn aligned_quality(image: &ImageData, cfg: &FrameQualityConfig) -> Option<FrameQuality> {
    if image.channels <= 1 {
        return analyze_frame_quality(image, cfg);
    }
    // Average channels into a luminance plane.
    let data = image.as_u16()?;
    let locations = (image.width as usize) * (image.height as usize);
    let chan = image.channels as usize;
    if data.len() != locations * chan {
        return None;
    }
    let mut luma = vec![0u16; locations];
    for (loc, out) in luma.iter_mut().enumerate() {
        let mut sum = 0u32;
        for ch in 0..chan {
            sum += data[loc * chan + ch] as u32;
        }
        *out = (sum / chan as u32) as u16;
    }
    let plane = ImageData::from_u16(image.width, image.height, 1, &luma);
    analyze_frame_quality(&plane, cfg)
}

/// Flatten an [`ImageData`] (U16 or F32) into a channel-interleaved f64 buffer.
pub(crate) fn image_to_f64(image: &ImageData) -> Vec<f64> {
    match image.pixel_type {
        PixelType::U16 => image
            .as_u16()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .unwrap_or_default(),
        PixelType::F32 => image
            .as_f32()
            .map(|v| v.into_iter().map(|x| x as f64).collect())
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

/// Derive a per-location luminance buffer (mean of channels) from a
/// channel-interleaved f64 buffer — used to build the zero-fill coverage mask.
pub(crate) fn derive_luma_f64(pixels: &[f64], locations: usize, channels: usize) -> Vec<f64> {
    if channels == 1 {
        return pixels.to_vec();
    }
    let mut luma = vec![0.0f64; locations];
    for (loc, out) in luma.iter_mut().enumerate() {
        let mut sum = 0.0;
        for ch in 0..channels {
            sum += pixels[loc * channels + ch];
        }
        *out = sum / channels as f64;
    }
    luma
}

/// Extract one channel plane from a channel-interleaved f64 buffer.
pub(crate) fn extract_channel(
    pixels: &[f64],
    locations: usize,
    channels: usize,
    ch: usize,
) -> Vec<f64> {
    let mut out = vec![0.0f64; locations];
    for (loc, o) in out.iter_mut().enumerate() {
        *o = pixels[loc * channels + ch];
    }
    out
}

/// Write one channel plane back into a channel-interleaved f64 buffer.
pub(crate) fn write_channel(
    pixels: &mut [f64],
    locations: usize,
    channels: usize,
    ch: usize,
    plane: &[f64],
) {
    for loc in 0..locations {
        pixels[loc * channels + ch] = plane[loc];
    }
}

pub(crate) fn build_registration_config(a: &AlignArgs) -> Result<RegistrationConfig, String> {
    let transform_kind = match a.model.trim().to_ascii_lowercase().as_str() {
        "similarity" => TransformKind::Similarity,
        "" | "affine" => TransformKind::Affine,
        "homography" => TransformKind::Homography,
        other => return Err(format!("unknown align model '{other}'")),
    };
    let interpolator = match a.resampler.trim().to_ascii_lowercase().as_str() {
        "bilinear" => Interpolator::Bilinear,
        "catmullrom" | "catmull_rom" => Interpolator::CatmullRom,
        "" | "lanczos3" | "lanczos" => Interpolator::Lanczos3,
        other => return Err(format!("unknown resampler '{other}'")),
    };
    let mut cfg = RegistrationConfig {
        transform_kind,
        interpolator,
        ..RegistrationConfig::default()
    };
    if a.ransac_threshold_px > 0.0 {
        cfg.ransac_threshold_px = a.ransac_threshold_px;
    }
    if a.max_ref_stars > 0 {
        cfg.max_stars_for_matching = a.max_ref_stars;
    }
    apply_detection_overrides(&mut cfg.star_detection, &a.detection);
    Ok(cfg)
}

/// Apply non-zero star-detection overrides onto a base [`StarDetectionConfig`],
/// leaving each unset (zero) knob at its production default.
pub(crate) fn apply_detection_overrides(
    cfg: &mut skotiq_imaging::StarDetectionConfig,
    d: &DetectionArgs,
) {
    if d.detection_sigma > 0.0 {
        cfg.detection_sigma = d.detection_sigma;
    }
    if d.min_area > 0 {
        cfg.min_area = d.min_area;
    }
    if d.max_eccentricity > 0.0 {
        cfg.max_eccentricity = d.max_eccentricity;
    }
    if d.min_hfr > 0.0 {
        cfg.min_hfr = d.min_hfr;
    }
    if d.min_snr > 0.0 {
        cfg.min_snr = d.min_snr;
    }
    if d.max_sharpness > 0.0 {
        cfg.max_sharpness = d.max_sharpness;
    }
}

/// Map the wire token onto a [`WeightFormula`].
///
/// The default (`snrSquared`) is the same family as PixInsight
/// `ImageIntegration`'s default noise-based weighting: for a fixed signal,
/// `SNR² ∝ 1/σ²`, and inverse-variance is exactly what noise-evaluation
/// weighting assigns. The two differ in how σ is measured (PI evaluates noise
/// with a multiscale estimator; we take it from the frame-quality pass), not in
/// what the weight means — so this is left as-is deliberately rather than
/// renamed or "corrected" toward PI.
pub(crate) fn build_weight_formula(a: &WeightingArgs) -> Result<WeightFormula, String> {
    Ok(match a.formula.trim().to_ascii_lowercase().as_str() {
        "snr" => WeightFormula::Snr,
        "" | "snrsquared" | "snr_squared" => WeightFormula::SnrSquared,
        "fwhminverse" | "fwhm_inverse" => WeightFormula::FwhmInverse,
        "custom" => WeightFormula::Custom {
            snr_pow: a.snr_pow,
            fwhm_pow: a.fwhm_pow,
            ecc_pow: a.ecc_pow,
        },
        other => return Err(format!("unknown weight formula '{other}'")),
    })
}

pub(crate) fn build_normalization_config(
    a: &NormalizationArgs,
) -> Result<NormalizationConfig, String> {
    let mode = match a.mode.trim().to_ascii_lowercase().as_str() {
        "" | "global" => NormMode::Global,
        "local" => {
            if a.local_rows == 0 || a.local_cols == 0 {
                return Err("local normalization requires localRows and localCols > 0".to_string());
            }
            NormMode::Local {
                rows: a.local_rows,
                cols: a.local_cols,
            }
        }
        other => return Err(format!("unknown normalization mode '{other}'")),
    };
    Ok(NormalizationConfig {
        mode,
        ..NormalizationConfig::default()
    })
}

pub(crate) fn build_integration_config(
    a: &IntegrationArgs,
    sub_count: usize,
) -> Result<IntegrationConfig, String> {
    let combine = match a.combine.trim().to_ascii_lowercase().as_str() {
        "" | "mean" => Combine::Mean,
        "median" => Combine::Median,
        other => return Err(format!("unknown combine '{other}'")),
    };
    let reject = match a.reject.trim().to_ascii_lowercase().as_str() {
        "auto" | "" => auto_reject(sub_count, a.reject_low, a.reject_high),
        "none" => Reject::None,
        "sigmaclip" | "sigma_clip" => Reject::SigmaClip {
            low: a.reject_low,
            high: a.reject_high,
        },
        "winsorizedsigma" | "winsorized_sigma" | "winsorizedsigmaclip" => {
            Reject::WinsorizedSigmaClip {
                low: a.reject_low,
                high: a.reject_high,
            }
        }
        "linearfit" | "linear_fit" | "linearfitclip" => Reject::LinearFitClip {
            low: a.reject_low,
            high: a.reject_high,
        },
        "percentile" | "percentileclip" => Reject::PercentileClip {
            low: a.reject_low,
            high: a.reject_high,
        },
        "minmax" | "min_max" => Reject::MinMax {
            n_low: a.min_max_low,
            n_high: a.min_max_high,
        },
        other => return Err(format!("unknown reject algorithm '{other}'")),
    };
    let output_type = match a.output_bit_depth.trim().to_ascii_lowercase().as_str() {
        "" | "f32" => PixelType::F32,
        "u16" => PixelType::U16,
        other => return Err(format!("unknown output bit depth '{other}'")),
    };
    Ok(IntegrationConfig {
        combine,
        reject,
        output_type,
        generate_rejection_map: a.generate_rejection_map,
        generate_weight_map: false,
        min_coverage: 1,
    })
}

/// Smart reject-algorithm selection by sub count (PixInsight-style):
/// `<8 → percentile`, `8–24 → winsorized-σ`, `≥25 → linear-fit`.
pub(crate) fn auto_reject(sub_count: usize, low: f64, high: f64) -> Reject {
    if sub_count < 8 {
        // Percentile bounds are fractions; map the sigma-style inputs to a
        // sensible default trim band when in "auto" mode.
        Reject::PercentileClip {
            low: 0.2,
            high: 0.1,
        }
    } else if sub_count < 25 {
        Reject::WinsorizedSigmaClip { low, high }
    } else {
        Reject::LinearFitClip { low, high }
    }
}

/// Read one keyword out of an [`ImageReadResult::header`] map.
///
/// That map is built with `format!("{:?}")`, so string values arrive wrapped in
/// escaped quotes (`FILTER` reads back as `"\"L\""`) and everything is padded
/// per the FITS fixed-format rules. Strip both, and treat an empty or FITS-null
/// (`""`) result as absent rather than writing a blank card onto the master.
pub(crate) fn header_string(
    header: &std::collections::HashMap<String, String>,
    key: &str,
) -> Option<String> {
    let raw = header.get(key)?.trim();
    let unquoted = raw.trim_matches('"').trim();
    (!unquoted.is_empty()).then(|| unquoted.to_string())
}

/// Observation metadata carried from the constituent lights onto the master.
///
/// Every field here was previously absent from batch-integrated masters, which
/// left all four per-filter masters of a session byte-identical in metadata —
/// nothing recorded which filter, target, instrument or night a master came
/// from. The values are read from the subs' own headers, never invented.
#[derive(Debug, Clone, Default)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterProvenance {
    /// `FILTER` from the subs, when they agree.
    pub(crate) filter: Option<String>,
    /// `OBJECT` (target name) from the subs.
    pub(crate) object: Option<String>,
    /// `INSTRUME` (camera) from the subs.
    pub(crate) instrument: Option<String>,
    /// Earliest `DATE-OBS` across the subs — the moment the stack begins.
    pub(crate) earliest_date_obs: Option<String>,
    /// Per-sub exposure, when every sub agrees on one.
    pub(crate) sub_exposure_sec: Option<f64>,
    /// Summed integration time over the accepted subs.
    pub(crate) total_integration_sec: f64,
    /// Set when the subs did not all report the same `FILTER`: the master then
    /// mixes filters, which is worth saying out loud rather than papering over
    /// by stamping whichever value happened to come first.
    pub(crate) filters_disagree: bool,
}

/// Collect [`MasterProvenance`] from the accepted subs' FITS headers.
///
/// `headers` and `exposures` are aligned to the accepted subs only, so a
/// rejected frame cannot contribute a filter name or drag `DATE-OBS` earlier
/// than the data that actually went in.
pub(crate) fn collect_master_provenance(
    headers: &[std::collections::HashMap<String, String>],
    exposures: &[f64],
) -> MasterProvenance {
    let first = |key: &str| headers.iter().find_map(|h| header_string(h, key));

    let filters: Vec<String> = headers
        .iter()
        .filter_map(|h| header_string(h, "FILTER"))
        .collect();
    let filters_disagree = filters.windows(2).any(|w| w[0] != w[1]);

    let earliest_date_obs = headers
        .iter()
        .filter_map(|h| header_string(h, "DATE-OBS"))
        // ISO-8601 timestamps sort lexicographically, which is why no date
        // parsing is needed to find the earliest.
        .min();

    let sub_exposure_sec = match exposures.split_first() {
        Some((head, rest)) if rest.iter().all(|e| (e - head).abs() < 1e-6) => Some(*head),
        _ => None,
    };

    MasterProvenance {
        filter: filters.first().cloned(),
        object: first("OBJECT"),
        instrument: first("INSTRUME"),
        earliest_date_obs,
        sub_exposure_sec,
        total_integration_sec: exposures.iter().sum(),
        filters_disagree,
    }
}

/// The rejection algorithm that actually ran, with its resolved parameters.
///
/// `IntegrationArgs::reject` is the *request* token, so recording it directly
/// stamps `REJECTM = 'auto'` on every default-path master — naming the wire
/// protocol rather than the science. `auto` resolves by sub count in
/// [`auto_reject`], and this reports what that resolved to.
pub(crate) fn reject_label(reject: &Reject) -> String {
    match reject {
        Reject::None => "none".to_string(),
        Reject::SigmaClip { low, high } => format!("sigmaClip({low},{high})"),
        Reject::WinsorizedSigmaClip { low, high } => format!("winsorizedSigma({low},{high})"),
        Reject::LinearFitClip { low, high } => format!("linearFit({low},{high})"),
        Reject::PercentileClip { low, high } => format!("percentile({low},{high})"),
        Reject::MinMax { n_low, n_high } => format!("minMax({n_low},{n_high})"),
    }
}

/// Build the integrated master's FITS header.
///
/// The calibration report is written out as `HISTORY` cards so the identity of
/// every applied dark / flat / bias — and every correction that did **not** run
/// — travels with the file rather than only with the database row that indexed
/// it. `CALWARN` summarises the same thing as a single boolean card a reader can
/// branch on without parsing prose.
///
/// Observation metadata ([`MasterProvenance`]) comes from the subs' own headers
/// so the master identifies its filter, target, instrument and night.
pub(crate) fn build_master_header(
    sub_count: usize,
    int_args: &IntegrationArgs,
    resolved_reject: &Reject,
    provenance: &MasterProvenance,
    reference_wcs: Option<&WcsInfo>,
    calibration: &CalibrationReport,
) -> FitsHeader {
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("FRAMETYP", "MASTER");
    header.set_string("CALSTAT", "Skotiq post-session integration");
    header.set_int("NFRAMES", sub_count as i64);
    // FITS keywords are capped at 8 chars (see `fits::is_valid_keyword`).
    header.set_string("COMBMETH", &int_args.combine);
    let reject = reject_label(resolved_reject);
    header.set_string("REJECTM", &reject);
    header.set_comment("REJECTM", "rejection algorithm as resolved and run");
    header.set_bool("CALWARN", calibration.has_warnings());

    // Observation metadata from the constituent subs.
    if let Some(f) = &provenance.filter {
        header.set_string("FILTER", f);
    }
    if let Some(o) = &provenance.object {
        header.set_string("OBJECT", o);
    }
    if let Some(i) = &provenance.instrument {
        header.set_string("INSTRUME", i);
    }
    if let Some(d) = &provenance.earliest_date_obs {
        header.set_string("DATE-OBS", d);
        header.set_comment("DATE-OBS", "earliest DATE-OBS of the integrated subs");
    }
    // EXPTIME is the SUMMED integration, matching the accumulating-master and
    // live-stack writers; the per-sub exposure is a separate card so neither
    // reading has to be inferred.
    header.set_float("EXPTIME", provenance.total_integration_sec);
    header.set_comment("EXPTIME", "total integration seconds over NFRAMES subs");
    if let Some(e) = provenance.sub_exposure_sec {
        header.set_float("SUBEXP", e);
        header.set_comment("SUBEXP", "per-sub exposure seconds");
    }
    if provenance.filters_disagree {
        header.add_history(
            "WARNING: integrated subs did not all report the same FILTER; \
             FILTER names the first sub only",
        );
    }

    header.add_history(&format!(
        "Integrated {sub_count} subs (combine={}, reject={reject})",
        int_args.combine
    ));
    for line in calibration_history_lines(calibration) {
        header.add_history(&line);
    }
    // Carry the registration reference's WCS into the master so the mosaic
    // stitcher's `wcs_from_header` succeeds *without* a post-hoc plate solve. The
    // integration output lives on the reference's pixel grid (every sub is
    // resampled onto it), so the reference's CRVAL/CRPIX/CD matrix describes the
    // master 1:1. Absent on the reference → left absent here; the project-service
    // cluster gates WCS-less panels out of the stitch.
    if let Some(wcs) = reference_wcs {
        add_wcs_headers(&mut header, wcs);
        header.add_history("WCS carried from registration reference frame");
    }
    header
}

/// Read the **registration reference** frame's WCS straight from its FITS
/// header, so the integrated master can carry it (see [`build_master_header`]).
///
/// Best-effort by construction: a reference that is not a FITS file, is
/// unreadable, or simply carries no astrometry yields `None` — integration still
/// produces a master, just without a stamped WCS (the stitcher then gates that
/// panel out). Mirrors the stitcher's `mosaic::wcs_from_header`: prefer an
/// explicit `CD1_1..CD2_2` matrix, fall back to the older `CDELT1/2` (+ optional
/// `CROTA2`) convention, and default `CRPIX` to the geometric centre.
pub(crate) fn reference_wcs_from_fits(path: &str) -> Option<WcsInfo> {
    // Only FITS carries a typed WCS header through this reader path; other
    // formats (XISF/RAW) flatten keywords lossily, so we don't attempt them.
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext != "fits" && ext != "fit" && ext != "fts" {
        return None;
    }
    let (_image, header) = read_fits(Path::new(path)).ok()?;

    let crval1 = header.get_float("CRVAL1")?;
    let crval2 = header.get_float("CRVAL2")?;
    let naxis1 = header.get_int("NAXIS1").unwrap_or(0) as f64;
    let naxis2 = header.get_int("NAXIS2").unwrap_or(0) as f64;
    let crpix1 = header
        .get_float("CRPIX1")
        .unwrap_or_else(|| naxis1 / 2.0 + 0.5);
    let crpix2 = header
        .get_float("CRPIX2")
        .unwrap_or_else(|| naxis2 / 2.0 + 0.5);

    // Prefer an explicit CD matrix.
    if let (Some(cd1_1), Some(cd2_2)) = (header.get_float("CD1_1"), header.get_float("CD2_2")) {
        return Some(WcsInfo {
            crval1,
            crval2,
            crpix1,
            crpix2,
            cd1_1,
            cd1_2: header.get_float("CD1_2").unwrap_or(0.0),
            cd2_1: header.get_float("CD2_1").unwrap_or(0.0),
            cd2_2,
        });
    }

    // Fall back to CDELT + CROTA2 (older WCS convention).
    let cdelt1 = header.get_float("CDELT1")?;
    let cdelt2 = header.get_float("CDELT2")?;
    let crota2 = header.get_float("CROTA2").unwrap_or(0.0).to_radians();
    let cos_r = crota2.cos();
    let sin_r = crota2.sin();
    Some(WcsInfo {
        crval1,
        crval2,
        crpix1,
        crpix2,
        cd1_1: cdelt1 * cos_r,
        cd1_2: -cdelt2 * sin_r,
        cd2_1: cdelt1 * sin_r,
        cd2_2: cdelt2 * cos_r,
    })
}

/// Write a stretched 8-bit preview PNG of a (U16 or F32) master.
///
/// F32 masters are first rescaled into U16 (preserving relative tone) so the
/// existing STF auto-stretch + `apply_stretch` path applies; the result is an
/// 8-bit (mono) or interleaved-RGB PNG written via the `image` crate.
///
/// `pub(crate)` so the sibling drizzle path ([`crate::api::finishing_combine`])
/// can emit the same stretched preview alongside its drizzled master FITS rather
/// than re-implementing the stretch.
pub(crate) fn write_preview_png(master: &ImageData, path: &Path) -> Result<(), String> {
    ensure_parent_dir(path)?;
    let u16_master = to_u16_for_preview(master);

    let width = u16_master.width;
    let height = u16_master.height;
    let channels = u16_master.channels;

    if channels == 1 {
        let params = auto_stretch_stf(&u16_master);
        let eight = apply_stretch(&u16_master, &params);
        let img = image::GrayImage::from_raw(width, height, eight)
            .ok_or_else(|| "failed to build preview buffer".to_string())?;
        img.save(path)
            .map_err(|e| format!("failed to write preview PNG: {e}"))
    } else if channels == 3 {
        let rgb = u16_master
            .as_u16()
            .ok_or_else(|| "RGB preview requires u16 master".to_string())?;
        let (r, g, b) = auto_stretch_rgb_with_mode(&rgb, width, height, RgbStretchMode::Linked);
        let eight = apply_stretch_rgb_per_channel(&rgb, width, height, &r, &g, &b);
        let img: image::RgbImage = image::ImageBuffer::from_raw(width, height, eight)
            .ok_or_else(|| "failed to build RGB preview buffer".to_string())?;
        img.save(path)
            .map_err(|e| format!("failed to write preview PNG: {e}"))
    } else {
        Err(format!("unsupported channel count {channels} for preview"))
    }
}

/// Convert any master into a U16 image for the auto-stretch preview path.
/// U16 is passed through; F32 is rescaled from its finite min..max into 0..65535.
pub(crate) fn to_u16_for_preview(master: &ImageData) -> ImageData {
    if master.pixel_type == PixelType::U16 {
        return master.clone();
    }
    let data = master.as_f32().unwrap_or_default();
    if data.is_empty() {
        return ImageData::from_u16(master.width, master.height, master.channels, &[]);
    }
    let mut lo = f64::INFINITY;
    let mut hi = f64::NEG_INFINITY;
    for &v in &data {
        let v = v as f64;
        if v.is_finite() {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    let u16data: Vec<u16> = if !lo.is_finite() || !hi.is_finite() || hi <= lo {
        vec![0u16; data.len()]
    } else {
        let range = hi - lo;
        data.iter()
            .map(|&v| {
                let n = ((v as f64 - lo) / range).clamp(0.0, 1.0);
                (n * 65535.0).round() as u16
            })
            .collect()
    };
    ImageData::from_u16(master.width, master.height, master.channels, &u16data)
}

pub(crate) fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create directory {}: {e}", parent.display()))?;
        }
    }
    Ok(())
}
