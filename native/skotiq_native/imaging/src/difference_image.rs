//! Difference imaging (Pillar B — "First Light"): subtract the atlas's deep
//! co-added template from a fresh plate-solved frame and surface what changed.
//!
//! # Why this module exists
//!
//! The sky atlas ([`crate::sky_atlas`]) gives every patch of sky a deep, additive
//! template — the running weighted mean of every night ever folded into a tile.
//! That template is the strongest reference an amateur rig can have for "what does
//! this field normally look like". Difference imaging exploits it: reproject
//! tonight's frame onto the exact tile grid the template lives on, scale it
//! photometrically to the template, subtract, and whatever is *left* in the
//! residual is something that changed — a nova, a supernova, an outburst, an
//! asteroid streak, or (most often) a star that simply was not deep enough in the
//! template yet. That last class is the false-positive the catalog cross-match in
//! the Dart layer rejects; this module's job is to find every real residual source
//! honestly and hand it up with enough shape/flux metadata to classify it.
//!
//! # The pipeline (one tile)
//!
//! 1. **Reproject** the new frame onto the tile's canonical TAN grid
//!    ([`crate::sky_atlas::tile_wcs`]) using the frame's full CD + SIP astrometry
//!    ([`crate::wcs_sip::SipWcs`]) and the shared resampler
//!    ([`crate::registration::sample_interleaved`]) — exactly the reprojection the
//!    fold path uses, so the residual is registered to sub-pixel accuracy.
//! 2. **Photometrically match** the reprojected frame to the template with a robust
//!    Theil–Sen line fit (`template ≈ scale·frame + offset`) over the overlap: the
//!    median of pairwise slopes has a ~29% breakdown point, so the very transients
//!    we are hunting cannot bias the scale even on a sparse field with few shared
//!    stars (where an iterated-OLS clip would be dragged by a high-leverage point).
//! 3. **Subtract** to a signed `F32` residual `(matched_frame − template)`, only
//!    where both the reprojected frame and the template have coverage (a thin
//!    template region is a quality gate, not a fabricated zero).
//! 4. **Extract sources** on the `+residual` (brightenings / new sources) and the
//!    `−residual` (the negative lobe of a subtraction dipole — a registration or
//!    PSF-mismatch artefact, flagged so the Dart layer can down-weight it). Source
//!    extraction is a sigma-clipped-background, 8-connected-maxima detector with
//!    HFR/FWHM/eccentricity measurement, the same estimator family as
//!    [`crate::stats::detect_stars`] but operating on the signed residual plane
//!    (which `detect_stars` cannot, as it decodes `U16`).
//! 5. **Classify** each candidate ([`TransientKind`]) from its residual sign, the
//!    presence of a paired opposite-sign lobe (dipole), and its elongation
//!    (a streak), and convert its tile pixel to `(ra, dec)` through the tile WCS.
//!
//! The catalog / photometric / moving-object cross-match that turns a residual
//! source into a *named* known object (or a flagged unknown) happens Dart-side in
//! `FirstLightService.scanFrame`; this module deliberately stops at the geometry +
//! photometry so the native boundary stays catalog-free.

use serde::{Deserialize, Serialize};

use crate::registration::{sample_interleaved, Interpolator};
use crate::robust_stats::{
    median_in_place as median, percentile_nearest_rank as percentile_sorted, MAD_TO_SIGMA,
};
use crate::sky_atlas::{AtlasError, SkyTileAccumulator};
use crate::stats::StarDetectionConfig;
use crate::wcs_sip::SipWcs;
use crate::ImageData;

/// Half-width (px) of the box around a positive residual source searched for an
/// opposite-sign lobe before the source is classified as a subtraction dipole.
/// A dipole's two lobes sit within roughly one PSF of each other; 6 px comfortably
/// spans the separation a sub-pixel registration error or PSF mismatch produces at
/// the atlas tile scale without reaching across to an unrelated source.
const DIPOLE_SEARCH_RADIUS: f64 = 6.0;

/// Eccentricity above which a residual source is read as a streak (a moving object
/// trailed across the exposure) rather than a point source. Matches the spirit of
/// the star detector's roundness gate, loosened because a genuine slow mover is
/// only mildly elongated.
const STREAK_ECCENTRICITY: f64 = 0.85;

/// Classification of a residual detection, by shape and residual sign. Wire names
/// are the contract's `camelCase` tokens (`pointBrightening` / `movingStreak` /
/// `dipole` / `newSource`); do not rename.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransientKind {
    /// A point source brighter in the frame than in the template at a location the
    /// template already had signal (a brightening / outburst).
    PointBrightening,
    /// An elongated positive residual — a trailed object (asteroid / satellite).
    MovingStreak,
    /// A positive lobe paired with an adjacent negative lobe — a subtraction
    /// artefact from registration / PSF mismatch, not an astrophysical change.
    Dipole,
    /// A point source present in the frame with little or no template signal under
    /// it (a genuine new source — the headline First Light case).
    NewSource,
}

impl TransientKind {
    /// The `camelCase` wire token (matches the Dart enum + DB `kind` column).
    pub fn as_wire(&self) -> &'static str {
        match self {
            TransientKind::PointBrightening => "pointBrightening",
            TransientKind::MovingStreak => "movingStreak",
            TransientKind::Dipole => "dipole",
            TransientKind::NewSource => "newSource",
        }
    }
}

/// One residual detection: a candidate transient on a single atlas tile.
#[derive(Debug, Clone, PartialEq)]
pub struct TransientCandidate {
    /// Right ascension (deg) via the tile WCS.
    pub ra: f64,
    /// Declination (deg) via the tile WCS.
    pub dec: f64,
    /// Source centroid x on the tile grid (0-based pixels).
    pub tile_x: f64,
    /// Source centroid y on the tile grid.
    pub tile_y: f64,
    /// Template-subtracted flux (sum of residual over the source footprint).
    pub residual_flux: f64,
    /// Estimated brightness change in magnitudes vs. the template under the source
    /// (negative = brighter than the template). `f64::NEG_INFINITY` for a source
    /// with no measurable template flux beneath it (a true new source).
    pub delta_mag: f64,
    /// Detection signal-to-noise on the residual plane.
    pub snr: f64,
    /// Full width at half maximum (px) of the residual source.
    pub fwhm: f64,
    /// Eccentricity of the residual source (0 = round, → 1 = a line).
    pub eccentricity: f64,
    /// Position angle (deg) of the source's major axis, measured from the +x tile
    /// axis toward +y, in `[0, 180)` (an axis has no head/tail so the angle wraps
    /// at 180°). Computed from the second-moment covariance as
    /// `0.5·atan2(2·Ixy, Ixx − Iyy)`. Meaningful for an elongated source (a
    /// streak's trail direction); ~arbitrary for a round one.
    pub position_angle_deg: f64,
    /// Shape/sign classification.
    pub kind: TransientKind,
}

/// The full result of differencing one frame against one tile template.
#[derive(Debug, Clone)]
pub struct DifferenceResult {
    /// Residual candidate sources, brightest (highest SNR) first.
    pub candidates: Vec<TransientCandidate>,
    /// The signed residual `(matched_frame − template)` as an `F32` image on the
    /// tile grid. Pixels with no frame-or-template coverage are `0.0`.
    pub residual: ImageData,
    /// The fresh frame reprojected + photometrically matched onto the tile grid
    /// (the "science" plane the residual was differenced from). Pixels the frame
    /// did not cover are `0.0`. Surfaced so the FFI layer can crop a real
    /// per-detection science postage stamp alongside the template + residual ones,
    /// instead of the UI painting a schematic.
    pub science: ImageData,
    /// The finalized template raster on the tile grid (the deep co-add the frame
    /// was differenced against), for the per-detection template crop.
    pub template_image: ImageData,
    /// Multiplicative photometric scale applied to the reprojected frame.
    pub matched_scale: f64,
    /// Additive photometric offset applied to the reprojected frame.
    pub matched_offset: f64,
    /// Minimum template coverage depth across the pixels that overlapped the frame
    /// (the quality gate the caller compares against `min_template_coverage`).
    pub template_coverage_min: u32,
}

/// Subtract the finalized atlas `template` (on its tile grid) from `frame`
/// reprojected onto the same grid, photometrically matched via the robust line
/// fit, then extract + classify residual sources.
///
/// `frame_wcs` is the frame's solved CD + SIP astrometry; `interp` selects the
/// resampling kernel for the reprojection; `star_cfg` tunes the residual source
/// detector (detection σ, min area/SNR, roundness gates — reused verbatim from the
/// star detector's configuration so a caller tunes both with one struct).
///
/// Returns [`AtlasError::DegenerateWcs`] if the frame WCS cannot be inverted,
/// [`AtlasError::ChannelMismatch`] if the frame and template channel counts differ.
pub fn difference_against_template(
    template: &SkyTileAccumulator,
    frame: &ImageData,
    frame_wcs: &SipWcs,
    interp: Interpolator,
    star_cfg: &StarDetectionConfig,
) -> Result<DifferenceResult, AtlasError> {
    if !frame_wcs.is_invertible() {
        return Err(AtlasError::DegenerateWcs);
    }
    if frame.channels != template.channels {
        return Err(AtlasError::ChannelMismatch {
            got: frame.channels,
            expected: template.channels,
        });
    }

    let tw = template.width as usize;
    let th = template.height as usize;
    let ch = template.channels as usize;
    let npix = tw * th;

    // The finalized template raster (weighted mean per pixel) + its coverage depth.
    let tmpl_img = template.finalize();
    let tmpl_f32 = tmpl_img
        .as_f32()
        .ok_or_else(|| AtlasError::Corrupt("finalized template is not F32".into()))?;
    let tmpl: Vec<f64> = tmpl_f32.iter().map(|&v| v as f64).collect();
    // Per-tile-pixel template coverage (channel 0 carries the count; coverage is
    // replicated across channels by the accumulator).
    let coverage = &template.state.coverage;

    // Decode the source frame to interleaved f64 for the resampler.
    let src = decode_to_f64(frame);
    let sw = frame.width as usize;
    let sh = frame.height as usize;
    let src_ok = !src.is_empty() && src.len() == sw * sh * ch;

    // Reproject the frame onto the tile grid; track which tile pixels the frame
    // validly covered so the normalization fit and the subtraction only use pixels
    // backed by real data on both sides.
    let mut warped = vec![f64::NAN; npix * ch];
    let mut frame_valid = vec![false; npix];
    if src_ok {
        for ty in 0..th {
            for tx in 0..tw {
                let (ra, dec) = template.wcs.pixel_to_world(tx as f64, ty as f64);
                let Some((fx, fy)) = frame_wcs.world_to_pixel(ra, dec) else {
                    continue;
                };
                if fx < 0.0 || fy < 0.0 || fx > (sw as f64 - 1.0) || fy > (sh as f64 - 1.0) {
                    continue;
                }
                let p = ty * tw + tx;
                let mut all_finite = true;
                for c in 0..ch {
                    let v = sample_interleaved(&src, sw, sh, ch, c, fx, fy, interp);
                    if v.is_finite() {
                        warped[p * ch + c] = v;
                    } else {
                        all_finite = false;
                    }
                }
                if all_finite {
                    frame_valid[p] = true;
                }
            }
        }
    }

    // Pixels usable for the photometric fit + subtraction: the frame covered them
    // *and* the template has at least one sample under them. The min template
    // coverage over that overlap is the quality gate the caller honours.
    let mut overlap = vec![false; npix];
    let mut template_coverage_min = u32::MAX;
    let mut any_overlap = false;
    for p in 0..npix {
        let cov = coverage[p * ch]; // channel-0 count
        if frame_valid[p] && cov > 0 {
            overlap[p] = true;
            any_overlap = true;
            if cov < template_coverage_min {
                template_coverage_min = cov;
            }
        }
    }
    if !any_overlap {
        template_coverage_min = 0;
    }

    // PSF matching (Gaussian kernel) — applied BEFORE the photometric fit. A pure
    // scalar match on PSF-mismatched planes leaves a residual whose shape is the
    // *difference of two PSFs* — a dipole/ring — at every common star whenever
    // tonight's seeing != the template's blended effective seeing (essentially
    // always); worse, the flux-vs-flux regression that sets the photometric scale
    // is itself biased by that shape mismatch. So we first measure the effective
    // Gaussian σ of the common point sources in both the reprojected frame and the
    // template, and convolve the SHARPER plane with the Gaussian that broadens it
    // to the other's σ (`σ_kernel = sqrt(σ_broad² − σ_sharp²)`), per channel — the
    // single-Gaussian case of Alard–Lupton matching — THEN fit + subtract on the
    // PSF-matched planes. This removes the bulk of the dipoles the classifier would
    // otherwise be flooded by on a typical mismatched-seeing night.
    let mut frame_psf = warped.clone();
    let mut tmpl_psf = tmpl.clone();
    const MIN_MATCH_SIGMA: f64 = 0.35; // sub-pixel kernels are not worth applying.
    if any_overlap {
        for c in 0..ch {
            let frame_sigma = estimate_psf_sigma(&warped, &overlap, tw, th, ch, c);
            let tmpl_sigma = estimate_psf_sigma(&tmpl, &overlap, tw, th, ch, c);
            if let (Some(fs), Some(ts)) = (frame_sigma, tmpl_sigma) {
                if fs > ts + MIN_MATCH_SIGMA {
                    // Frame is broader -> broaden the template to match the frame.
                    let k = (fs * fs - ts * ts).sqrt();
                    blur_channel_gaussian(&mut tmpl_psf, tw, th, ch, c, k);
                } else if ts > fs + MIN_MATCH_SIGMA {
                    // Template is broader -> broaden tonight's frame to match it.
                    let k = (ts * ts - fs * fs).sqrt();
                    blur_channel_gaussian(&mut frame_psf, tw, th, ch, c, k);
                }
            }
        }
    }

    // Fit + apply a per-channel photometric match (template ≈ scale·frame + offset)
    // over the overlap, on the PSF-matched planes, robustly clipping the transients
    // we are about to detect. The reported scalar scale/offset are the channel-0
    // fit (mono is the norm; for OSC the per-channel coefficients are applied but
    // the headline pair is luminance channel 0).
    let mut frame_match = frame_psf.clone();
    let mut report_scale = 1.0;
    let mut report_offset = 0.0;
    if any_overlap {
        for c in 0..ch {
            // Collect the (frame, template) pairs over the overlap for this channel.
            let mut pairs: Vec<(f64, f64)> = Vec::new();
            for p in 0..npix {
                if !overlap[p] {
                    continue;
                }
                let f = frame_psf[p * ch + c];
                let t = tmpl_psf[p * ch + c];
                if f.is_finite() && t.is_finite() {
                    pairs.push((f, t));
                }
            }
            // Robust slope + offset via Theil–Sen. Plain iterated OLS (even κ-clipped)
            // is pulled by a single bright transient on a SPARSE field: with few
            // shared stars the transient is a high-leverage point that drags the slope
            // before the clip can converge, biasing the whole subtraction and
            // erasing/inflating the very residual we are hunting. Theil–Sen takes the
            // median of pairwise slopes (≈29% breakdown point), so a handful of
            // transient pixels among the shared structure cannot move the fit — the
            // robust line difference imaging needs.
            let (scale, offset) = robust_theil_sen(&pairs)
                .filter(|&(s, o)| s.is_finite() && s > 0.0 && o.is_finite())
                .unwrap_or((1.0, 0.0));
            for p in 0..npix {
                let v = frame_psf[p * ch + c];
                if v.is_finite() {
                    frame_match[p * ch + c] = scale * v + offset;
                }
            }
            if c == 0 {
                report_scale = scale;
                report_offset = offset;
            }
        }
    }
    let tmpl_match = tmpl_psf;

    // Signed residual = PSF+photometrically matched frame − matched template, only
    // on the overlap. Build the per-channel signed residual for the output image,
    // plus a set of single-channel detection planes: the luminance mean AND each
    // colour channel on its own.
    let mut residual = vec![0.0f32; npix * ch];
    let mut lum_plane = vec![0.0f64; npix];
    // One detection plane per colour channel (OSC) — a single-colour outburst
    // (e.g. an Hα brightening, or a transient bright in only one Bayer channel)
    // lands at full amplitude in its own plane but is diluted by ~√ch in the
    // luminance mean. Detecting per-channel and keeping the best-SNR hit per source
    // recovers the ~√3 (OSC) sensitivity the mean-only detector threw away.
    let mut chan_planes: Vec<Vec<f64>> = vec![vec![0.0f64; npix]; ch];
    for p in 0..npix {
        if !overlap[p] {
            continue;
        }
        let mut lum = 0.0;
        for c in 0..ch {
            let d = frame_match[p * ch + c] - tmpl_match[p * ch + c];
            residual[p * ch + c] = d as f32;
            lum += d;
            chan_planes[c][p] = d;
        }
        lum_plane[p] = lum / ch as f64;
    }

    // Detection planes to search: the luminance mean first (so a panchromatic
    // source's combined-SNR detection wins on ties), then each colour channel.
    // For mono the per-channel plane is identical to the luminance plane, so search
    // only one to avoid duplicate work.
    let mut detect_planes: Vec<&[f64]> = vec![&lum_plane];
    if ch > 1 {
        for plane in &chan_planes {
            detect_planes.push(plane);
        }
    }

    // Extract sources on +residual (brightenings / new) and −residual (dipole
    // negative lobes) across every detection plane, then keep the best-SNR
    // detection per spatial source (a one-channel outburst is not lost to the mean).
    let pos_sources = extract_best_across_planes(&detect_planes, &overlap, tw, th, star_cfg, 1.0);
    let neg_sources = extract_best_across_planes(&detect_planes, &overlap, tw, th, star_cfg, -1.0);

    // The template's robust sky pedestal (per-channel summed), so the template flux
    // under a source is measured *above* the local sky — a source on bare sky has
    // ~zero template flux (a NewSource) rather than the pedestal × footprint.
    let tmpl_background = template_background(&tmpl, &overlap, ch);

    let mut candidates = Vec::with_capacity(pos_sources.len());
    for s in &pos_sources {
        let (ra, dec) = template.wcs.pixel_to_world(s.x, s.y);
        // Template flux (above sky) under the source footprint -> a Δmag estimate.
        let tmpl_flux = template_flux_under(&tmpl, &overlap, ch, tmpl_background, s);
        let delta_mag = delta_magnitude(s.flux, tmpl_flux);
        // Dipole if a comparable negative lobe sits within a PSF.
        let dipole = neg_sources.iter().any(|n| {
            let dx = n.x - s.x;
            let dy = n.y - s.y;
            (dx * dx + dy * dy).sqrt() <= DIPOLE_SEARCH_RADIUS && n.flux.abs() >= 0.5 * s.flux.abs()
        });
        let kind = classify(s, tmpl_flux, dipole);
        candidates.push(TransientCandidate {
            ra,
            dec,
            tile_x: s.x,
            tile_y: s.y,
            residual_flux: s.flux,
            delta_mag,
            snr: s.snr,
            fwhm: s.fwhm,
            eccentricity: s.eccentricity,
            position_angle_deg: s.position_angle,
            kind,
        });
    }

    // Brightest (highest SNR) first — the order the UI / narrator surfaces.
    candidates.sort_by(|a, b| b.snr.total_cmp(&a.snr));

    // The matched science plane on the tile grid: the reprojected, PSF+photo-
    // metrically matched frame the residual was differenced from. Non-overlap
    // (or non-finite) pixels become 0.0 so the crop is defined everywhere.
    let mut science = vec![0.0f32; npix * ch];
    for p in 0..npix {
        if !overlap[p] {
            continue;
        }
        for c in 0..ch {
            let v = frame_match[p * ch + c];
            if v.is_finite() {
                science[p * ch + c] = v as f32;
            }
        }
    }

    Ok(DifferenceResult {
        candidates,
        residual: ImageData::from_f32(
            template.width,
            template.height,
            template.channels,
            &residual,
        ),
        science: ImageData::from_f32(template.width, template.height, template.channels, &science),
        template_image: tmpl_img,
        matched_scale: report_scale,
        matched_offset: report_offset,
        template_coverage_min,
    })
}

/// A measured residual source on the detection plane (tile-grid pixels).
#[derive(Debug, Clone)]
struct ResidualSource {
    x: f64,
    y: f64,
    /// Background-subtracted residual flux over the source footprint (always
    /// positive in the searched sign's frame; the caller knows the sign).
    flux: f64,
    snr: f64,
    fwhm: f64,
    eccentricity: f64,
    /// Major-axis position angle (deg, `[0, 180)`) from the second-moment
    /// covariance.
    position_angle: f64,
    /// Footprint pixel indices, for the template-flux measurement.
    footprint: Vec<usize>,
}

/// Run [`extract_residual_sources`] over several detection planes (the luminance
/// mean plus each colour channel) and merge the results, keeping the **best-SNR**
/// detection for each physical source. Two detections are the same source when
/// their centroids sit within one PSF (the dipole search radius). This is the
/// per-channel extraction that stops a single-colour transient from being diluted
/// in the channel-mean luminance plane: whichever plane the source is strongest in
/// supplies its measured flux/SNR/shape.
fn extract_best_across_planes(
    planes: &[&[f64]],
    overlap: &[bool],
    width: usize,
    height: usize,
    cfg: &StarDetectionConfig,
    sign: f64,
) -> Vec<ResidualSource> {
    let mut merged: Vec<ResidualSource> = Vec::new();
    for plane in planes {
        for src in extract_residual_sources(plane, overlap, width, height, cfg, sign) {
            // Match against an already-kept source by centroid proximity.
            let hit = merged.iter_mut().find(|m| {
                let dx = m.x - src.x;
                let dy = m.y - src.y;
                (dx * dx + dy * dy).sqrt() <= DIPOLE_SEARCH_RADIUS
            });
            match hit {
                Some(existing) if src.snr > existing.snr => *existing = src,
                Some(_) => {}
                None => merged.push(src),
            }
        }
    }
    merged
}

/// Extract sources from the signed residual plane in the chosen `sign` direction
/// (`+1` = bright residuals, `−1` = negative lobes). A sigma-clipped background +
/// noise are estimated on the overlap pixels, then 8-connected local maxima above
/// `detection_sigma·noise` are flood-grown to their footprint and measured
/// (centroid, flux, peak, SNR, FWHM, eccentricity), gated by the same min-area /
/// min-SNR / roundness thresholds [`crate::stats::detect_stars`] uses.
fn extract_residual_sources(
    detect_plane: &[f64],
    overlap: &[bool],
    width: usize,
    height: usize,
    cfg: &StarDetectionConfig,
    sign: f64,
) -> Vec<ResidualSource> {
    let n = width * height;
    if n == 0 || detect_plane.len() != n {
        return Vec::new();
    }
    // Work on the sign-flipped plane so the detector always hunts positive peaks.
    let plane: Vec<f64> = (0..n)
        .map(|i| {
            if overlap[i] {
                sign * detect_plane[i]
            } else {
                0.0
            }
        })
        .collect();

    let (background, noise) = residual_background(&plane, overlap);
    if !noise.is_finite() || noise <= 0.0 {
        return Vec::new();
    }
    let threshold = background + cfg.detection_sigma * noise;

    let mut visited = vec![false; n];
    let mut out = Vec::new();
    // Interior pixels only (the 8-neighbour maximum test needs a 1-px border).
    for y in 1..height.saturating_sub(1) {
        for x in 1..width.saturating_sub(1) {
            let idx = y * width + x;
            if visited[idx] || !overlap[idx] || plane[idx] < threshold {
                continue;
            }
            let val = plane[idx];
            let is_max = val >= plane[idx - 1]
                && val >= plane[idx + 1]
                && val >= plane[idx - width]
                && val >= plane[idx + width]
                && val >= plane[idx - width - 1]
                && val >= plane[idx - width + 1]
                && val >= plane[idx + width - 1]
                && val >= plane[idx + width + 1];
            if !is_max {
                continue;
            }
            if let Some(src) = measure_residual_source(
                &plane,
                overlap,
                width,
                height,
                x,
                y,
                background,
                noise,
                threshold,
                cfg,
                &mut visited,
            ) {
                out.push(src);
            }
        }
    }
    out
}

/// Sigma-clipped background + noise (median, robust σ) over the residual's overlap
/// pixels. The residual is mean-zero by construction so the median is near zero.
///
/// The primary noise estimate is `1.4826·MAD` (the star-robust Gaussian-consistent
/// σ). For a very deep template differenced against a clean frame the residual is
/// near-zero across the great majority of pixels, so the MAD can underflow to zero;
/// in that case we fall back to a higher robust spread (the inter-percentile range
/// of the source-free bulk) and finally to a small fraction of the residual's
/// dynamic range, so a genuine source on an otherwise-perfect subtraction is still
/// detectable rather than swamped by a zero noise floor.
fn residual_background(plane: &[f64], overlap: &[bool]) -> (f64, f64) {
    let mut vals: Vec<f64> = plane
        .iter()
        .zip(overlap.iter())
        .filter_map(|(&v, &ok)| if ok && v.is_finite() { Some(v) } else { None })
        .collect();
    if vals.len() < 16 {
        return (0.0, 0.0);
    }
    vals.sort_unstable_by(f64::total_cmp);
    let median = percentile_sorted(&vals, 0.5);
    let mut dev: Vec<f64> = vals.iter().map(|&v| (v - median).abs()).collect();
    dev.sort_unstable_by(f64::total_cmp);
    let mad = percentile_sorted(&dev, 0.5);
    // 1.4826·MAD is the Gaussian-consistent σ estimator.
    let mut sigma = MAD_TO_SIGMA * mad;

    if !(sigma.is_finite() && sigma > 0.0) {
        // MAD underflowed (a near-perfect subtraction). Use the 84th-percentile
        // absolute deviation as a higher robust spread, which still ignores the
        // sparse bright source pixels but captures the residual's real scatter.
        sigma = percentile_sorted(&dev, 0.84);
    }
    if !(sigma.is_finite() && sigma > 0.0) {
        // Still zero (a literally flat residual apart from the source spikes):
        // floor σ to a small fraction of the residual range so the source's spike
        // clears the detection threshold. This only ever fires on synthetic /
        // noiseless data; real residuals always carry pixel noise.
        let span =
            (vals.last().copied().unwrap_or(0.0) - vals.first().copied().unwrap_or(0.0)).abs();
        sigma = (span * 1e-3).max(f64::MIN_POSITIVE);
    }
    (median, sigma)
}

/// Flood-grow a source from a seed maximum (8-connected, pixels above threshold),
/// measure its centroid / flux / peak / SNR / FWHM / eccentricity, and apply the
/// area / SNR / roundness gates. Marks every visited footprint pixel so a source is
/// counted once. Returns `None` if the source fails a gate.
#[allow(clippy::too_many_arguments)]
fn measure_residual_source(
    plane: &[f64],
    overlap: &[bool],
    width: usize,
    height: usize,
    seed_x: usize,
    seed_y: usize,
    background: f64,
    noise: f64,
    threshold: f64,
    cfg: &StarDetectionConfig,
    visited: &mut [bool],
) -> Option<ResidualSource> {
    let mut stack = vec![(seed_x, seed_y)];
    let mut footprint: Vec<usize> = Vec::new();
    let max_pixels = (cfg.max_area as usize).saturating_mul(4).max(64);
    while let Some((x, y)) = stack.pop() {
        if x == 0 || y == 0 || x >= width - 1 || y >= height - 1 {
            continue;
        }
        let idx = y * width + x;
        if visited[idx] || !overlap[idx] || plane[idx] < threshold {
            continue;
        }
        visited[idx] = true;
        footprint.push(idx);
        if footprint.len() > max_pixels {
            break;
        }
        for (dx, dy) in [
            (-1i64, -1i64),
            (0, -1),
            (1, -1),
            (-1, 0),
            (1, 0),
            (-1, 1),
            (0, 1),
            (1, 1),
        ] {
            let nx = x as i64 + dx;
            let ny = y as i64 + dy;
            if nx > 0 && ny > 0 && (nx as usize) < width - 1 && (ny as usize) < height - 1 {
                stack.push((nx as usize, ny as usize));
            }
        }
    }

    let area = footprint.len();
    if area < cfg.min_area as usize || area > cfg.max_area as usize {
        return None;
    }

    // Flux-weighted centroid + second moments on the background-subtracted plane.
    let mut sum_w = 0.0;
    let mut sum_x = 0.0;
    let mut sum_y = 0.0;
    for &idx in &footprint {
        let px = (idx % width) as f64;
        let py = (idx / width) as f64;
        let w = (plane[idx] - background).max(0.0);
        sum_w += w;
        sum_x += w * px;
        sum_y += w * py;
    }
    if sum_w <= 0.0 {
        return None;
    }
    let cx = sum_x / sum_w;
    let cy = sum_y / sum_w;

    // Second central moments -> eccentricity (same definition as the star detector).
    let mut mxx = 0.0;
    let mut myy = 0.0;
    let mut mxy = 0.0;
    for &idx in &footprint {
        let px = (idx % width) as f64;
        let py = (idx / width) as f64;
        let w = (plane[idx] - background).max(0.0);
        let ddx = px - cx;
        let ddy = py - cy;
        mxx += w * ddx * ddx;
        myy += w * ddy * ddy;
        mxy += w * ddx * ddy;
    }
    mxx /= sum_w;
    myy /= sum_w;
    mxy /= sum_w;
    let eccentricity = moment_eccentricity(mxx, myy, mxy);
    // Major-axis position angle from the second-moment covariance: the angle that
    // diagonalizes [[Ixx, Ixy],[Ixy, Iyy]]. `0.5·atan2(2·Ixy, Ixx − Iyy)` gives the
    // major-axis direction in radians; wrap into [0, 180) since an axis has no
    // orientation sense. This is a measured shape attribute: a streak's trail
    // direction.
    let position_angle = position_angle_deg(mxx, myy, mxy);

    let flux = sum_w; // background-subtracted footprint flux
                      // SNR on the residual: peak signal over the residual noise scaled by the
                      // footprint (the standard √N background-noise propagation).
    let snr = if noise > 0.0 {
        flux / (noise * (area as f64).sqrt())
    } else {
        0.0
    };
    if snr < cfg.min_snr {
        return None;
    }

    // FWHM from the geometric-mean second moment: σ = √((mxx+myy)/2),
    // FWHM = 2√(2 ln 2)·σ. Robust for the modest footprints residual sources have.
    let sigma = ((mxx + myy) * 0.5).max(0.0).sqrt();
    let fwhm = 2.354_820_045 * sigma;
    if fwhm < cfg.min_hfr {
        // Reuse min_hfr as the lower size gate (hot pixels / single-pixel spikes).
        return None;
    }

    Some(ResidualSource {
        x: cx,
        y: cy,
        flux,
        snr,
        fwhm,
        eccentricity,
        position_angle,
        footprint,
    })
}

/// Major-axis position angle (deg, `[0, 180)`) of a source from its second central
/// moments. `θ = 0.5·atan2(2·Ixy, Ixx − Iyy)` is the rotation that diagonalizes the
/// moment covariance; measured from the +x tile axis toward +y. Wrapped into
/// `[0, 180)` because an axis is direction-less (θ and θ+180° describe the same
/// line). For a perfectly round source the angle is ill-defined but harmless (the
/// classifier only treats elongated sources as streaks).
fn position_angle_deg(mxx: f64, myy: f64, mxy: f64) -> f64 {
    let theta = 0.5 * (2.0 * mxy).atan2(mxx - myy);
    let mut deg = theta.to_degrees() % 180.0;
    if deg < 0.0 {
        deg += 180.0;
    }
    deg
}

/// Robust photometric line fit `y ≈ scale·x + offset` by the Theil–Sen estimator:
/// `scale` = the median of pairwise slopes `(yj − yi)/(xj − xi)`, `offset` = the
/// median of `yi − scale·xi`. With a ~29% breakdown point this is immune to the
/// bright transients (and a sparse field's high-leverage points) that bias an
/// iterated OLS fit. Returns `None` when there is too little spread to fit a slope.
///
/// The exact estimator is O(n²) in the number of pairs; over an atlas tile's
/// ~10⁶-pixel overlap that is prohibitive, so we evenly subsample to a bounded
/// number of points first (deterministic stride — no RNG, so the fit is
/// reproducible), which preserves the median-of-slopes robustness while keeping the
/// pairwise sweep cheap. Pairs whose x-separation is tiny are skipped (their slope
/// is numerically unstable and carries no leverage).
fn robust_theil_sen(pairs: &[(f64, f64)]) -> Option<(f64, f64)> {
    if pairs.len() < 2 {
        return None;
    }
    // Even-stride subsample to at most MAX_POINTS so the pairwise sweep stays cheap.
    const MAX_POINTS: usize = 400;
    let sampled: Vec<(f64, f64)> = if pairs.len() > MAX_POINTS {
        let stride = pairs.len() / MAX_POINTS;
        pairs.iter().step_by(stride.max(1)).copied().collect()
    } else {
        pairs.to_vec()
    };
    if sampled.len() < 2 {
        return None;
    }

    // Minimum x-separation for a stable slope: a small fraction of the x-range so a
    // near-vertical pair (two points at nearly the same frame value) is dropped.
    let (mut xmin, mut xmax) = (f64::INFINITY, f64::NEG_INFINITY);
    for &(x, _) in &sampled {
        xmin = xmin.min(x);
        xmax = xmax.max(x);
    }
    let span = xmax - xmin;
    if !(span.is_finite() && span > 0.0) {
        return None;
    }
    let min_dx = span * 1e-3;

    let mut slopes: Vec<f64> = Vec::new();
    for i in 0..sampled.len() {
        let (xi, yi) = sampled[i];
        for &(xj, yj) in &sampled[i + 1..] {
            let dx = xj - xi;
            if dx.abs() < min_dx {
                continue;
            }
            let s = (yj - yi) / dx;
            if s.is_finite() {
                slopes.push(s);
            }
        }
    }
    if slopes.is_empty() {
        return None;
    }
    let scale = median(&mut slopes);

    // Offset = median residual, the robust intercept consistent with the slope.
    let mut intercepts: Vec<f64> = sampled.iter().map(|&(x, y)| y - scale * x).collect();
    let offset = median(&mut intercepts);
    Some((scale, offset))
}

/// Eccentricity from the second central moments of a source's flux distribution.
/// `e = √(1 − b²/a²)` with `a`/`b` the major/minor axis lengths from the moment
/// eigenvalues — identical to the star detector's roundness measure.
fn moment_eccentricity(mxx: f64, myy: f64, mxy: f64) -> f64 {
    let common = (((mxx - myy) * (mxx - myy)) / 4.0 + mxy * mxy)
        .max(0.0)
        .sqrt();
    let sum = (mxx + myy) / 2.0;
    let lambda1 = sum + common; // major-axis variance
    let lambda2 = (sum - common).max(0.0); // minor-axis variance
    if lambda1 <= 0.0 {
        return 0.0;
    }
    (1.0 - lambda2 / lambda1).max(0.0).sqrt()
}

/// The template's robust sky pedestal, summed across channels — the median
/// template value over the overlap (per channel), summed. Used to measure source
/// flux *above* sky so a source on bare sky reports no template backing.
fn template_background(tmpl: &[f64], overlap: &[bool], channels: usize) -> f64 {
    let npix = overlap.len();
    let mut sum = 0.0;
    for c in 0..channels {
        let mut vals: Vec<f64> = (0..npix)
            .filter(|&p| overlap[p])
            .map(|p| tmpl[p * channels + c])
            .filter(|v| v.is_finite())
            .collect();
        if vals.is_empty() {
            continue;
        }
        vals.sort_unstable_by(f64::total_cmp);
        sum += percentile_sorted(&vals, 0.5);
    }
    sum
}

/// Total template flux **above the sky pedestal** under a residual source's
/// footprint, summed across channels. `background` is the per-footprint-pixel sky
/// (the summed-channel template median); the per-pixel contribution is clamped at
/// zero so faint negative excursions below sky do not subtract. The reference
/// brightness the residual change is measured against; ~zero for a source sitting
/// on bare sky (which `delta_magnitude` then reads as a new source).
fn template_flux_under(
    tmpl: &[f64],
    overlap: &[bool],
    channels: usize,
    background: f64,
    src: &ResidualSource,
) -> f64 {
    let mut total = 0.0;
    for &idx in &src.footprint {
        if idx >= overlap.len() || !overlap[idx] {
            continue;
        }
        let mut pix = 0.0;
        for c in 0..channels {
            let v = tmpl[idx * channels + c];
            if v.is_finite() {
                pix += v;
            }
        }
        total += (pix - background).max(0.0);
    }
    total
}

/// Estimated magnitude change of the source vs. the template flux beneath it.
/// `Δmag = −2.5·log10((tmpl + residual) / tmpl)`; negative when the source is
/// brighter than the template. Returns `NEG_INFINITY` when the template has no
/// measurable flux under the source (a true new source — an undefined ratio).
fn delta_magnitude(residual_flux: f64, template_flux: f64) -> f64 {
    if template_flux <= 0.0 {
        return f64::NEG_INFINITY;
    }
    let combined = template_flux + residual_flux;
    if combined <= 0.0 {
        return f64::NEG_INFINITY;
    }
    -2.5 * (combined / template_flux).log10()
}

/// Classify a positive residual source by its template backing, shape, and the
/// presence of a paired negative lobe.
fn classify(src: &ResidualSource, template_flux: f64, dipole: bool) -> TransientKind {
    if dipole {
        return TransientKind::Dipole;
    }
    if src.eccentricity >= STREAK_ECCENTRICITY {
        return TransientKind::MovingStreak;
    }
    if template_flux <= 0.0 {
        TransientKind::NewSource
    } else {
        TransientKind::PointBrightening
    }
}

/// Estimate the effective Gaussian σ (px) of the point sources in one channel of
/// an interleaved plane, over the overlap. Detects the brightest local maxima
/// above a robust sky threshold and measures each one's intensity-weighted second
/// moment in a small window; the median σ across the brightest few is the
/// effective seeing. Returns `None` when too few clean sources are found to judge
/// (the caller then skips PSF matching for that channel — the scalar match alone).
fn estimate_psf_sigma(
    plane: &[f64],
    overlap: &[bool],
    width: usize,
    height: usize,
    channels: usize,
    channel: usize,
) -> Option<f64> {
    let npix = width * height;
    // Single-channel view + robust sky.
    let mut vals: Vec<f64> = (0..npix)
        .filter(|&p| overlap[p])
        .map(|p| plane[p * channels + channel])
        .filter(|v| v.is_finite())
        .collect();
    if vals.len() < 64 {
        return None;
    }
    vals.sort_unstable_by(f64::total_cmp);
    let median = percentile_sorted(&vals, 0.5);
    let dev: Vec<f64> = vals.iter().map(|&v| (v - median).abs()).collect();
    let mut dev_sorted = dev;
    dev_sorted.sort_unstable_by(f64::total_cmp);
    let sigma_bg = MAD_TO_SIGMA * percentile_sorted(&dev_sorted, 0.5);
    let noise = if sigma_bg.is_finite() && sigma_bg > 0.0 {
        sigma_bg
    } else {
        // Flat synthetic plane: use a small fraction of the dynamic range.
        ((vals.last().copied().unwrap_or(0.0) - vals.first().copied().unwrap_or(0.0)).abs() * 1e-3)
            .max(f64::MIN_POSITIVE)
    };
    let threshold = median + 5.0 * noise;

    // Collect candidate peaks (8-connected local maxima above threshold).
    let win = 4i64; // moment window half-width (px) — a few PSF sigmas.
    let mut sigmas: Vec<(f64, f64)> = Vec::new(); // (peak, sigma)
    for y in win as usize..height.saturating_sub(win as usize) {
        for x in win as usize..width.saturating_sub(win as usize) {
            let idx = y * width + x;
            if !overlap[idx] {
                continue;
            }
            let v = plane[idx * channels + channel];
            if !v.is_finite() || v < threshold {
                continue;
            }
            let mut is_max = true;
            'nb: for dy in -1i64..=1 {
                for dx in -1i64..=1 {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let nidx = ((y as i64 + dy) * width as i64 + (x as i64 + dx)) as usize;
                    if plane[nidx * channels + channel] > v {
                        is_max = false;
                        break 'nb;
                    }
                }
            }
            if !is_max {
                continue;
            }
            // Intensity-weighted second moment in the window (sky-subtracted).
            let mut sw = 0.0;
            let mut sr2 = 0.0;
            for dy in -win..=win {
                for dx in -win..=win {
                    let px = (x as i64 + dx) as usize;
                    let py = (y as i64 + dy) as usize;
                    let pidx = py * width + px;
                    if !overlap[pidx] {
                        continue;
                    }
                    let w = (plane[pidx * channels + channel] - median).max(0.0);
                    sw += w;
                    sr2 += w * ((dx * dx + dy * dy) as f64);
                }
            }
            if sw > 0.0 {
                // <r²> = 2σ² for a 2-D Gaussian -> σ = sqrt(<r²>/2).
                let sigma = (sr2 / sw / 2.0).max(0.0).sqrt();
                if sigma.is_finite() && sigma > 0.2 && sigma < win as f64 {
                    sigmas.push((v, sigma));
                }
            }
        }
    }
    if sigmas.len() < 3 {
        return None;
    }
    // Median σ of the brightest dozen sources (robust to a faint mis-measure).
    sigmas.sort_by(|a, b| b.0.total_cmp(&a.0));
    let take = sigmas.len().min(12);
    let mut top: Vec<f64> = sigmas[..take].iter().map(|s| s.1).collect();
    top.sort_unstable_by(f64::total_cmp);
    Some(percentile_sorted(&top, 0.5))
}

/// Blur one channel of an interleaved plane in place with a separable Gaussian of
/// standard deviation `sigma` (px). A no-op for a non-positive/tiny σ. The kernel
/// is truncated at ±3σ and renormalized so flux is conserved; edge pixels use a
/// clamped (replicate) border so the convolution is defined everywhere.
fn blur_channel_gaussian(
    plane: &mut [f64],
    width: usize,
    height: usize,
    channels: usize,
    channel: usize,
    sigma: f64,
) {
    if !(sigma.is_finite() && sigma > 0.0) {
        return;
    }
    let radius = (3.0 * sigma).ceil() as i64;
    if radius < 1 {
        return;
    }
    let mut kernel = vec![0.0f64; (2 * radius + 1) as usize];
    let two_s2 = 2.0 * sigma * sigma;
    let mut ksum = 0.0;
    for (i, k) in kernel.iter_mut().enumerate() {
        let d = i as i64 - radius;
        *k = (-(d * d) as f64 / two_s2).exp();
        ksum += *k;
    }
    for k in kernel.iter_mut() {
        *k /= ksum;
    }

    // Horizontal pass into a scratch single-channel plane, then vertical pass.
    let npix = width * height;
    let mut tmp = vec![0.0f64; npix];
    for y in 0..height {
        for x in 0..width {
            let mut acc = 0.0;
            for (i, &k) in kernel.iter().enumerate() {
                let sx = (x as i64 + i as i64 - radius).clamp(0, width as i64 - 1) as usize;
                acc += k * plane[(y * width + sx) * channels + channel];
            }
            tmp[y * width + x] = acc;
        }
    }
    for y in 0..height {
        for x in 0..width {
            let mut acc = 0.0;
            for (i, &k) in kernel.iter().enumerate() {
                let sy = (y as i64 + i as i64 - radius).clamp(0, height as i64 - 1) as usize;
                acc += k * tmp[sy * width + x];
            }
            plane[(y * width + x) * channels + channel] = acc;
        }
    }
}

/// Decode an [`ImageData`] to channel-interleaved f64 (the resampler's layout).
/// U16 and F32 are supported (the linear types the pipeline emits); other types
/// decode to an empty buffer, which the caller treats as no frame contribution.
fn decode_to_f64(image: &ImageData) -> Vec<f64> {
    if let Some(f) = image.as_f32() {
        f.into_iter().map(|v| v as f64).collect()
    } else if let Some(u) = image.as_u16() {
        u.into_iter().map(|v| v as f64).collect()
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::master_accumulation::AccumulationMode;
    use crate::sky_atlas::{tile_center, tile_wcs, ATLAS_HEALPIX_ORDER};

    fn no_clip() -> AccumulationMode {
        AccumulationMode::RunningWeightedMean { clip: None }
    }

    /// Render a Gaussian star of total `flux` at tile-pixel `(cx, cy)` into a
    /// mono f32 buffer, on a flat `background` pedestal.
    fn render_star(buf: &mut [f32], w: usize, h: usize, cx: f64, cy: f64, flux: f64, sigma: f64) {
        let norm = flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        let r = (4.0 * sigma).ceil() as i64;
        for dy in -r..=r {
            for dx in -r..=r {
                let x = cx.round() as i64 + dx;
                let y = cy.round() as i64 + dy;
                if x < 0 || y < 0 || x >= w as i64 || y >= h as i64 {
                    continue;
                }
                let ddx = x as f64 - cx;
                let ddy = y as f64 - cy;
                let g = norm * (-(ddx * ddx + ddy * ddy) / (2.0 * sigma * sigma)).exp();
                buf[y as usize * w + x as usize] += g as f32;
            }
        }
    }

    /// Build a template tile co-added from `n_frames` identical synthetic frames,
    /// each a flat pedestal with a set of fixed stars. The frames share the tile's
    /// own WCS so reprojection is the identity (isolating the differencing logic).
    fn build_template(
        order: u32,
        tile_id: u64,
        w: usize,
        h: usize,
        background: f64,
        stars: &[(f64, f64, f64)],
        n_frames: usize,
    ) -> SkyTileAccumulator {
        let wcs = tile_wcs(tile_id, order);
        // The synthetic "frame" raster (what each night looks like).
        let mut frame = vec![background as f32; w * h];
        for &(cx, cy, flux) in stars {
            render_star(&mut frame, w, h, cx, cy, flux, 1.6);
        }
        let frame_img = ImageData::from_f32(w as u32, h as u32, 1, &frame);

        let mut acc = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        for i in 0..n_frames {
            acc.fold_frame(
                &frame_img,
                &wcs,
                1.0,
                300.0,
                Interpolator::Bilinear,
                &format!("2026-06-{:02}", i + 1),
                "",
            )
            .expect("fold");
        }
        acc
    }

    fn cfg() -> StarDetectionConfig {
        StarDetectionConfig {
            detection_sigma: 5.0,
            min_area: 4,
            max_area: 2000,
            min_snr: 4.0,
            min_hfr: 1.0,
            ..StarDetectionConfig::default()
        }
    }

    #[test]
    fn injected_new_source_is_detected() {
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(120.0, 25.0, order);
        let (w, h) = (256usize, 256usize);
        let bg = 100.0;
        // Template has two stable stars.
        let stars = [(80.0, 90.0, 4000.0), (170.0, 60.0, 5000.0)];
        let template = build_template(order, tile_id, w, h, bg, &stars, 8);

        // Tonight's frame = the same two stars PLUS a brand-new source.
        let wcs = tile_wcs(tile_id, order);
        let mut frame = vec![bg as f32; w * h];
        for &(cx, cy, flux) in &stars {
            render_star(&mut frame, w, h, cx, cy, flux, 1.6);
        }
        let (nx, ny) = (128.0, 140.0);
        render_star(&mut frame, w, h, nx, ny, 6000.0, 1.6);
        let frame_img = ImageData::from_f32(w as u32, h as u32, 1, &frame);

        let res = difference_against_template(
            &template,
            &frame_img,
            &wcs,
            Interpolator::Bilinear,
            &cfg(),
        )
        .expect("difference");

        // The new source must be detected near (nx, ny).
        let found = res
            .candidates
            .iter()
            .find(|c| (c.tile_x - nx).abs() < 2.0 && (c.tile_y - ny).abs() < 2.0);
        let found = found.expect("injected new source detected");
        assert!(found.residual_flux > 0.0);
        assert!(found.snr >= cfg().min_snr);
        // No template flux under a brand-new source -> NewSource + -inf delta_mag.
        assert_eq!(found.kind, TransientKind::NewSource);
        assert!(found.delta_mag.is_infinite() && found.delta_mag < 0.0);

        // The two stable template stars must cancel: no spurious candidate sits on
        // top of either of them.
        for &(sx, sy, _) in &stars {
            assert!(
                !res.candidates
                    .iter()
                    .any(|c| { (c.tile_x - sx).abs() < 3.0 && (c.tile_y - sy).abs() < 3.0 }),
                "a matching template star at ({sx},{sy}) must cancel, not appear as a candidate"
            );
        }
        assert!(res.template_coverage_min >= 1);
    }

    #[test]
    fn matching_template_source_cancels_to_no_candidate() {
        // A frame identical to the template (after photometric match) must yield no
        // significant residual sources.
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(10.0, -20.0, order);
        let (w, h) = (256usize, 256usize);
        let bg = 200.0;
        let stars = [(100.0, 100.0, 5000.0), (60.0, 180.0, 3000.0)];
        let template = build_template(order, tile_id, w, h, bg, &stars, 6);

        let wcs = tile_wcs(tile_id, order);
        // Same field, but uniformly scaled brighter + a pedestal shift: the
        // photometric match must absorb both, leaving a clean residual.
        let mut frame = vec![(bg * 1.15 + 30.0) as f32; w * h];
        for &(cx, cy, flux) in &stars {
            render_star(&mut frame, w, h, cx, cy, flux * 1.15, 1.6);
        }
        let frame_img = ImageData::from_f32(w as u32, h as u32, 1, &frame);

        let res = difference_against_template(
            &template,
            &frame_img,
            &wcs,
            Interpolator::Bilinear,
            &cfg(),
        )
        .expect("difference");

        // The fit regresses template ≈ scale·frame + offset, so a frame 1.15× the
        // template's brightness recovers scale ≈ 1/1.15 and absorbs the pedestal.
        assert!(
            (res.matched_scale - 1.0 / 1.15).abs() < 0.03,
            "scale {}",
            res.matched_scale
        );
        // No bright positive candidate should survive on a matching field.
        assert!(
            res.candidates.iter().all(|c| c.snr < 12.0),
            "matching field produced a strong spurious candidate: {:?}",
            res.candidates
        );
    }

    #[test]
    fn brightening_is_classified_against_template_flux() {
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(200.0, 40.0, order);
        let (w, h) = (256usize, 256usize);
        let bg = 100.0;
        // A realistic field: several stable stars that pin the photometric scale,
        // plus one star (index 0) that brightens. The stable stars are what let the
        // κ-clip reject the brightening as an outlier rather than absorbing it.
        let stars = [
            (128.0, 128.0, 3000.0),
            (60.0, 70.0, 4000.0),
            (200.0, 90.0, 3500.0),
            (90.0, 200.0, 4500.0),
            (170.0, 190.0, 2800.0),
            (40.0, 150.0, 3200.0),
        ];
        let template = build_template(order, tile_id, w, h, bg, &stars, 8);

        // Tonight the star at (128,128) is much brighter (an outburst); the rest are
        // unchanged.
        let wcs = tile_wcs(tile_id, order);
        let mut frame = vec![bg as f32; w * h];
        for (i, &(cx, cy, flux)) in stars.iter().enumerate() {
            let f = if i == 0 { 9000.0 } else { flux };
            render_star(&mut frame, w, h, cx, cy, f, 1.6);
        }
        let frame_img = ImageData::from_f32(w as u32, h as u32, 1, &frame);

        let res = difference_against_template(
            &template,
            &frame_img,
            &wcs,
            Interpolator::Bilinear,
            &cfg(),
        )
        .expect("difference");

        let c = res
            .candidates
            .iter()
            .find(|c| (c.tile_x - 128.0).abs() < 2.0 && (c.tile_y - 128.0).abs() < 2.0)
            .expect("brightening detected");
        assert_eq!(c.kind, TransientKind::PointBrightening);
        // Brighter than the template -> a negative (finite) delta mag.
        assert!(
            c.delta_mag.is_finite() && c.delta_mag < 0.0,
            "delta_mag {}",
            c.delta_mag
        );
        // The stable stars must cancel: only the brightening survives.
        for &(sx, sy, _) in &stars[1..] {
            assert!(
                !res.candidates
                    .iter()
                    .any(|c| (c.tile_x - sx).abs() < 3.0 && (c.tile_y - sy).abs() < 3.0),
                "stable star at ({sx},{sy}) must cancel"
            );
        }
    }

    #[test]
    fn mismatched_seeing_stars_cancel_via_psf_matching() {
        // The template's effective seeing (σ=1.6) differs from tonight's frame
        // (σ=2.6, worse seeing). Without PSF matching every common star leaves a
        // dipole/ring residual; with the Gaussian kernel match the stable stars
        // must cancel and only a genuinely new source survives.
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(50.0, 15.0, order);
        let (w, h) = (256usize, 256usize);
        let bg = 100.0;
        let stars = [
            (80.0, 90.0, 9000.0),
            (170.0, 60.0, 11000.0),
            (120.0, 180.0, 8000.0),
        ];
        // Template co-added at σ=1.6.
        let wcs = tile_wcs(tile_id, order);
        let mut tframe = vec![bg as f32; w * h];
        for &(cx, cy, flux) in &stars {
            render_star(&mut tframe, w, h, cx, cy, flux, 1.6);
        }
        let timg = ImageData::from_f32(w as u32, h as u32, 1, &tframe);
        let mut template = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        for i in 0..8 {
            template
                .fold_frame(
                    &timg,
                    &wcs,
                    1.0,
                    300.0,
                    Interpolator::Bilinear,
                    &format!("2026-07-{:02}", i + 1),
                    "",
                )
                .unwrap();
        }

        // Tonight: same stars at WORSE seeing (σ=2.6) + a new source.
        let mut frame = vec![bg as f32; w * h];
        for &(cx, cy, flux) in &stars {
            render_star(&mut frame, w, h, cx, cy, flux, 2.6);
        }
        render_star(&mut frame, w, h, 200.0, 200.0, 9000.0, 2.6);
        let frame_img = ImageData::from_f32(w as u32, h as u32, 1, &frame);

        let res = difference_against_template(
            &template,
            &frame_img,
            &wcs,
            Interpolator::Bilinear,
            &cfg(),
        )
        .expect("difference");

        // The genuinely new source must be detected and must dominate the list —
        // PSF matching keeps real transients from being buried under PSF-mismatch
        // residuals.
        let new_src = res
            .candidates
            .iter()
            .find(|c| (c.tile_x - 200.0).abs() < 4.0 && (c.tile_y - 200.0).abs() < 4.0)
            .expect("new source detected through mismatched seeing");
        let strongest_snr = res.candidates.iter().map(|c| c.snr).fold(0.0f64, f64::max);
        assert_eq!(
            new_src.snr, strongest_snr,
            "the real new source must be the strongest detection"
        );

        // Any residual that DOES survive on a stable star must be classified as a
        // PSF-mismatch dipole (so the Dart layer down-weights it), never a clean
        // newSource/brightening masquerading as a real transient.
        for &(sx, sy, _) in &stars {
            for c in &res.candidates {
                if (c.tile_x - sx).abs() < 4.0 && (c.tile_y - sy).abs() < 4.0 {
                    assert_eq!(
                        c.kind,
                        TransientKind::Dipole,
                        "a surviving residual on the stable star at ({sx},{sy}) must be a dipole"
                    );
                }
            }
        }
    }

    #[test]
    fn channel_mismatch_is_rejected() {
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(0.0, 0.0, order);
        let template = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        let wcs = tile_wcs(tile_id, order);
        let frame = ImageData::from_f32(16, 16, 3, &vec![0.0; 16 * 16 * 3]);
        let err =
            difference_against_template(&template, &frame, &wcs, Interpolator::Bilinear, &cfg())
                .unwrap_err();
        assert_eq!(
            err,
            AtlasError::ChannelMismatch {
                got: 3,
                expected: 1
            }
        );
    }

    #[test]
    fn degenerate_wcs_is_rejected() {
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(0.0, 0.0, order);
        let template = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        let bad = SipWcs::tan_only(10.0, 20.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);
        let frame = ImageData::from_f32(16, 16, 1, &vec![0.0; 16 * 16]);
        let err =
            difference_against_template(&template, &frame, &bad, Interpolator::Bilinear, &cfg())
                .unwrap_err();
        assert_eq!(err, AtlasError::DegenerateWcs);
    }

    #[test]
    fn kind_wire_tokens_match_contract() {
        assert_eq!(
            TransientKind::PointBrightening.as_wire(),
            "pointBrightening"
        );
        assert_eq!(TransientKind::MovingStreak.as_wire(), "movingStreak");
        assert_eq!(TransientKind::Dipole.as_wire(), "dipole");
        assert_eq!(TransientKind::NewSource.as_wire(), "newSource");
        // Serde uses the same camelCase tokens on the wire.
        let json = serde_json::to_string(&TransientKind::NewSource).unwrap();
        assert_eq!(json, "\"newSource\"");
    }

    #[test]
    fn tile_center_is_reachable() {
        // Sanity that the test tiles' centres are well-formed (the differencing
        // path projects through the tile WCS, which is centred there).
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(120.0, 25.0, order);
        let (ra, dec) = tile_center(tile_id, order);
        assert!((0.0..360.0).contains(&ra));
        assert!((-90.0..=90.0).contains(&dec));
    }
}
