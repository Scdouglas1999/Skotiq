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
//! 2. **Compare only deep pixels**: a tile pixel is compared only where the
//!    template has at least `min_template_coverage` frames under it.
//! 3. **Match**: remove the smooth sky from both planes, blur the sharper one to
//!    the other's seeing, and scale the frame by the median template/frame
//!    aperture-flux ratio of isolated, unsaturated template stars. Sky noise is
//!    never used as the scale.
//! 4. **Subtract** to a signed `F32` residual and extract sources on it.
//! 5. **Gate** each source: frame and coverage edges, saturation, sharpness (hot
//!    pixels, cosmic rays), bright-star halos, dipoles, elongation, then forced
//!    aperture photometry on the residual and the template with an empirical
//!    aperture noise plus a systematic floor. A source with template flux under
//!    it is reported only as a clear brightening; one without as a new source.
//!
//! A single frame is never enough to announce anything: the Dart layer requires
//! the same source in a second frame before it reports it.
//!
//! The catalog / photometric / moving-object cross-match that turns a residual
//! source into a *named* known object (or a flagged unknown) happens Dart-side in
//! `FirstLightService.scanFrame`; this module deliberately stops at the geometry +
//! photometry so the native boundary stays catalog-free.

use serde::{Deserialize, Serialize};

use crate::registration::{kernel_inside, sample_interleaved, Interpolator};
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

/// Gates a residual must pass before it is reported. Every gate exists because
/// real frames produced false detections without it: hot pixels and cosmic
/// rays, the frame and template-coverage edges, saturated star cores, halos of
/// bright stars, PSF-mismatch dipoles and trails.
#[derive(Debug, Clone, PartialEq)]
pub struct DifferenceOptions {
    /// Per-pixel template depth (frames) below which a pixel is not compared.
    pub min_template_coverage: u32,
    /// Minimum distance (px) of a candidate from the frame edge and from the
    /// edge of the compared (deep-enough) template area.
    pub edge_margin_px: f64,
    /// Minimum aperture significance of the residual, counting both the
    /// measured aperture noise and [`Self::systematic_fraction`] of the
    /// template flux under it.
    pub min_significance: f64,
    /// Fraction of the template flux treated as irreducible subtraction error
    /// (PSF and normalization mismatch), added in quadrature to the noise.
    pub systematic_fraction: f64,
    /// Smallest brightening (mag) of a source already in the template that is
    /// reported.
    pub min_brightening_mag: f64,
    /// Raw frame value at or above which a pixel counts as saturated; `None`
    /// uses 95% of the frame's maximum.
    pub saturation_level: Option<f64>,
}

impl Default for DifferenceOptions {
    fn default() -> Self {
        Self {
            min_template_coverage: 5,
            edge_margin_px: 16.0,
            min_significance: 7.0,
            systematic_fraction: 0.1,
            min_brightening_mag: 0.3,
            saturation_level: None,
        }
    }
}

/// Why residual sources were not reported, for diagnostics and evaluation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DifferenceRejections {
    /// Too close to the frame edge or the edge of the compared template area.
    pub edge: usize,
    /// On or next to saturated pixels.
    pub saturated: usize,
    /// Sharper than the PSF allows (hot pixel, cosmic ray).
    pub sharp: usize,
    /// In the halo or core of a bright template star.
    pub bright_star: usize,
    /// Paired with a negative lobe (registration / PSF mismatch).
    pub dipole: usize,
    /// Elongated (satellite / aircraft trail or subtraction artifact).
    pub elongated: usize,
    /// Below the aperture significance threshold.
    pub insignificant: usize,
    /// A source already in the template that changed by less than the
    /// brightening threshold.
    pub small_change: usize,
}

/// The full result of differencing one frame against one tile template.
#[derive(Debug, Clone)]
pub struct DifferenceResult {
    /// Residual candidate sources, most significant first.
    pub candidates: Vec<TransientCandidate>,
    /// The signed residual `(matched_frame − template)` as an `F32` image on the
    /// tile grid. Pixels with no frame-or-template coverage are `0.0`.
    pub residual: ImageData,
    /// The fresh frame reprojected + photometrically matched onto the tile grid
    /// (the "science" plane the residual was differenced from). Pixels the frame
    /// did not cover are `0.0`. Surfaced so the FFI layer can crop a real
    /// per-detection science postage stamp alongside the template + residual ones.
    pub science: ImageData,
    /// The finalized template raster on the tile grid (the deep co-add the frame
    /// was differenced against), for the per-detection template crop.
    pub template_image: ImageData,
    /// Multiplicative photometric scale applied to the reprojected frame (the
    /// median template/frame flux ratio of the matched stars).
    pub matched_scale: f64,
    /// Additive offset applied to the reprojected frame (0: both planes are
    /// background-subtracted before matching).
    pub matched_offset: f64,
    /// Stars the photometric scale was measured on; below
    /// [`MIN_NORMALIZATION_STARS`] the tile is not differenced.
    pub normalization_stars: usize,
    /// Minimum template coverage depth across the pixels that overlapped the
    /// frame.
    pub template_coverage_min: u32,
    /// Tile pixels compared (frame covered and template deep enough).
    pub compared_pixels: usize,
    /// Residual sources dropped, by reason.
    pub rejections: DifferenceRejections,
}

/// Fewest unsaturated, isolated template stars the frame-to-template flux scale
/// is measured on. With fewer the scale is not trustworthy and the tile is
/// skipped rather than differenced on a guess.
pub const MIN_NORMALIZATION_STARS: usize = 6;

/// Eccentricity at or above which a residual is treated as a trail or a
/// subtraction artifact, never a point-source transient.
const MAX_POINT_ECCENTRICITY: f64 = 0.75;

/// Background mesh size (tile px) for the smooth sky removed from both planes.
const BACKGROUND_MESH: usize = 64;

/// Subtract the finalized atlas `template` (on its tile grid) from `frame`
/// reprojected onto the same grid and report point sources that are new or
/// clearly brighter than in the template.
///
/// Both planes have their smooth sky removed, the sharper one is blurred to the
/// other's seeing, and the frame is scaled to the template by the median flux
/// ratio of matched template stars (not by sky noise). Residual sources are then
/// measured with forced aperture photometry on the residual and the template,
/// and kept only if they pass every gate in [`DifferenceOptions`]. Only
/// [`TransientKind::NewSource`] and [`TransientKind::PointBrightening`] are
/// reported.
///
/// Returns [`AtlasError::DegenerateWcs`] if the frame WCS cannot be inverted,
/// [`AtlasError::ChannelMismatch`] if the frame and template channel counts differ.
pub fn difference_against_template(
    template: &SkyTileAccumulator,
    frame: &ImageData,
    frame_wcs: &SipWcs,
    interp: Interpolator,
    star_cfg: &StarDetectionConfig,
    opts: &DifferenceOptions,
) -> Result<DifferenceResult, AtlasError> {
    difference_against_decoded(
        template,
        &DecodedFrame::new(frame),
        frame_wcs,
        interp,
        star_cfg,
        opts,
    )
}

/// A frame decoded once to linear f64 (channel-interleaved), for differencing
/// against many tiles without re-decoding per tile.
#[derive(Debug, Clone)]
pub struct DecodedFrame {
    src: Vec<f64>,
    width: u32,
    height: u32,
    channels: u32,
}

impl DecodedFrame {
    /// Decode `frame` (U16 or F32; other types decode empty and difference to
    /// nothing).
    pub fn new(frame: &ImageData) -> Self {
        Self {
            src: decode_to_f64(frame),
            width: frame.width,
            height: frame.height,
            channels: frame.channels,
        }
    }
}

/// [`difference_against_template`] on an already decoded frame.
pub fn difference_against_decoded(
    template: &SkyTileAccumulator,
    frame: &DecodedFrame,
    frame_wcs: &SipWcs,
    interp: Interpolator,
    star_cfg: &StarDetectionConfig,
    opts: &DifferenceOptions,
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

    let tmpl_img = template.finalize();
    let tmpl_f32 = tmpl_img
        .as_f32()
        .ok_or_else(|| AtlasError::Corrupt("finalized template is not F32".into()))?;
    let tmpl: Vec<f64> = tmpl_f32.iter().map(|&v| v as f64).collect();
    let coverage = &template.state.coverage;

    let src = &frame.src;
    let sw = frame.width as usize;
    let sh = frame.height as usize;
    let src_ok = !src.is_empty() && src.len() == sw * sh * ch;

    // Reproject; a tile pixel is valid only where the whole interpolation
    // kernel reads real frame pixels.
    let mut warped = vec![0.0f64; npix * ch];
    let mut frame_valid = vec![false; npix];
    if src_ok {
        for ty in 0..th {
            for tx in 0..tw {
                let (ra, dec) = template.wcs.pixel_to_world(tx as f64, ty as f64);
                let Some((fx, fy)) = frame_wcs.world_to_pixel(ra, dec) else {
                    continue;
                };
                if !kernel_inside(fx, fy, sw, sh, interp) {
                    continue;
                }
                let p = ty * tw + tx;
                let mut ok = true;
                for c in 0..ch {
                    let v = sample_interleaved(src, sw, sh, ch, c, fx, fy, interp);
                    if v.is_finite() {
                        warped[p * ch + c] = v;
                    } else {
                        ok = false;
                    }
                }
                frame_valid[p] = ok;
            }
        }
    }

    // Compared pixels: frame covered and the template deep enough right there.
    let mut overlap = vec![false; npix];
    let mut template_coverage_min = u32::MAX;
    let mut compared_pixels = 0usize;
    for p in 0..npix {
        let cov = coverage[p * ch];
        if frame_valid[p] && cov > 0 {
            template_coverage_min = template_coverage_min.min(cov);
            if cov >= opts.min_template_coverage.max(1) {
                overlap[p] = true;
                compared_pixels += 1;
            }
        }
    }
    if template_coverage_min == u32::MAX {
        template_coverage_min = 0;
    }

    let empty_result = |rejections: DifferenceRejections, stars: usize| DifferenceResult {
        candidates: Vec::new(),
        residual: ImageData::from_f32(
            template.width,
            template.height,
            template.channels,
            &vec![0.0f32; npix * ch],
        ),
        science: ImageData::from_f32(
            template.width,
            template.height,
            template.channels,
            &vec![0.0f32; npix * ch],
        ),
        template_image: tmpl_img.clone(),
        matched_scale: 1.0,
        matched_offset: 0.0,
        normalization_stars: stars,
        template_coverage_min,
        compared_pixels,
        rejections,
    };
    if compared_pixels < 64 * 64 {
        return Ok(empty_result(DifferenceRejections::default(), 0));
    }

    // Remove the smooth sky from both planes so the match is a pure scale.
    let mut frame_bs = warped.clone();
    let mut tmpl_bs = tmpl.clone();
    for c in 0..ch {
        subtract_mesh_background(&mut frame_bs, &overlap, tw, th, ch, c);
        subtract_mesh_background(&mut tmpl_bs, &overlap, tw, th, ch, c);
    }

    // PSF matching: blur the sharper plane to the other's seeing.
    let mut frame_psf = frame_bs.clone();
    let mut tmpl_psf = tmpl_bs.clone();
    const MIN_MATCH_SIGMA: f64 = 0.35;
    let mut broad_sigma: f64 = 1.5;
    for c in 0..ch {
        let fs = estimate_psf_sigma(&frame_bs, &overlap, tw, th, ch, c);
        let ts = estimate_psf_sigma(&tmpl_bs, &overlap, tw, th, ch, c);
        if let (Some(fs), Some(ts)) = (fs, ts) {
            if c == 0 {
                broad_sigma = fs.max(ts);
            }
            if fs > ts + MIN_MATCH_SIGMA {
                blur_channel_gaussian(&mut tmpl_psf, tw, th, ch, c, (fs * fs - ts * ts).sqrt());
            } else if ts > fs + MIN_MATCH_SIGMA {
                blur_channel_gaussian(&mut frame_psf, tw, th, ch, c, (ts * ts - fs * fs).sqrt());
            }
        }
    }
    let aperture = (1.5 * 2.354_820_045 * broad_sigma).clamp(3.0, 12.0);

    // Pixels far enough from the compared area's edge for a whole aperture
    // and its sky annulus.
    let edge_reach = opts.edge_margin_px.max(aperture + 8.0).ceil() as usize;
    let interior = erode_mask(&overlap, tw, th, edge_reach);

    // Photometric scale from matched template stars.
    let lum = |plane: &[f64]| -> Vec<f64> {
        (0..npix)
            .map(|p| (0..ch).map(|c| plane[p * ch + c]).sum::<f64>() / ch as f64)
            .collect()
    };
    let tmpl_lum = lum(&tmpl_psf);
    let frame_lum = lum(&frame_psf);
    let tmpl_raw_lum = lum(&tmpl);
    let tmpl_max = (0..npix)
        .filter(|&p| overlap[p])
        .map(|p| tmpl_raw_lum[p])
        .fold(f64::NEG_INFINITY, f64::max);
    let stars = template_reference_stars(&tmpl_lum, &tmpl_raw_lum, &interior, tw, th, tmpl_max);
    let mut ratios: Vec<f64> = Vec::new();
    for &(x, y, _) in &stars {
        let t = aperture_sum(&tmpl_lum, &overlap, tw, th, x as f64, y as f64, aperture);
        let f = aperture_sum(&frame_lum, &overlap, tw, th, x as f64, y as f64, aperture);
        if let (Some(t), Some(f)) = (t, f) {
            if t > 0.0 && f > 0.0 {
                ratios.push(t / f);
            }
        }
    }
    if ratios.len() < MIN_NORMALIZATION_STARS {
        return Ok(empty_result(DifferenceRejections::default(), ratios.len()));
    }
    let scale = median(&mut ratios);
    if !(scale.is_finite() && scale > 0.0) {
        return Ok(empty_result(DifferenceRejections::default(), 0));
    }
    let normalization_stars = stars.len();

    let mut frame_match = frame_psf;
    for v in frame_match.iter_mut() {
        *v *= scale;
    }
    let tmpl_match = tmpl_psf;

    let mut residual = vec![0.0f32; npix * ch];
    let mut lum_plane = vec![0.0f64; npix];
    let mut chan_planes: Vec<Vec<f64>> = vec![vec![0.0f64; npix]; ch];
    for p in 0..npix {
        if !overlap[p] {
            continue;
        }
        let mut l = 0.0;
        for c in 0..ch {
            let d = frame_match[p * ch + c] - tmpl_match[p * ch + c];
            residual[p * ch + c] = d as f32;
            l += d;
            chan_planes[c][p] = d;
        }
        lum_plane[p] = l / ch as f64;
    }
    let mut detect_planes: Vec<&[f64]> = vec![&lum_plane];
    if ch > 1 {
        for plane in &chan_planes {
            detect_planes.push(plane);
        }
    }
    let pos_sources = extract_best_across_planes(&detect_planes, &overlap, tw, th, star_cfg, 1.0);
    let neg_sources = extract_best_across_planes(&detect_planes, &overlap, tw, th, star_cfg, -1.0);

    // Aperture noise measured empirically on the residual and the template
    // (resampling and PSF matching correlate neighbouring pixels, so a
    // per-pixel σ·√N would understate it).
    let resid_ap_sigma = empirical_aperture_sigma(&lum_plane, &interior, tw, th, aperture);
    let tmpl_ap_sigma = empirical_aperture_sigma(&tmpl_lum, &interior, tw, th, aperture);

    // Frame-space context for the pixel-level guards.
    let frame_px_scale = frame_wcs.pixel_scale_arcsec();
    let tile_px_scale = template.wcs.pixel_scale_arcsec();
    let frame_sigma_px = if frame_px_scale > 0.0 {
        broad_sigma * tile_px_scale / frame_px_scale
    } else {
        broad_sigma
    };
    let frame_max = if src_ok {
        src.iter()
            .cloned()
            .filter(|v| v.is_finite())
            .fold(f64::NEG_INFINITY, f64::max)
    } else {
        f64::INFINITY
    };
    let saturation = opts.saturation_level.unwrap_or(0.95 * frame_max);

    let mut rejections = DifferenceRejections::default();
    let mut candidates = Vec::new();
    for s in &pos_sources {
        let (xi, yi) = (s.x.round() as isize, s.y.round() as isize);
        if xi < 0 || yi < 0 || xi as usize >= tw || yi as usize >= th {
            rejections.edge += 1;
            continue;
        }
        if !interior[yi as usize * tw + xi as usize] {
            rejections.edge += 1;
            continue;
        }
        let (ra, dec) = template.wcs.pixel_to_world(s.x, s.y);
        let Some((fx, fy)) = frame_wcs.world_to_pixel(ra, dec) else {
            rejections.edge += 1;
            continue;
        };
        if fx < opts.edge_margin_px
            || fy < opts.edge_margin_px
            || fx > sw as f64 - 1.0 - opts.edge_margin_px
            || fy > sh as f64 - 1.0 - opts.edge_margin_px
        {
            rejections.edge += 1;
            continue;
        }
        if s.eccentricity >= MAX_POINT_ECCENTRICITY {
            rejections.elongated += 1;
            continue;
        }
        let dipole = neg_sources.iter().any(|n| {
            let dx = n.x - s.x;
            let dy = n.y - s.y;
            (dx * dx + dy * dy).sqrt() <= DIPOLE_SEARCH_RADIUS && n.flux >= 0.3 * s.flux
        });
        if dipole {
            rejections.dipole += 1;
            continue;
        }
        if src_ok {
            if frame_window_max(src, sw, sh, ch, fx, fy, 4) >= saturation {
                rejections.saturated += 1;
                continue;
            }
            if too_sharp(src, sw, sh, ch, fx, fy, frame_sigma_px) {
                rejections.sharp += 1;
                continue;
            }
        }
        if near_bright_star(&tmpl_raw_lum, &overlap, tw, th, s, tmpl_max) {
            rejections.bright_star += 1;
            continue;
        }

        let Some(r_ap) = aperture_sum(&lum_plane, &overlap, tw, th, s.x, s.y, aperture) else {
            rejections.edge += 1;
            continue;
        };
        let t_ap = aperture_sum(&tmpl_lum, &overlap, tw, th, s.x, s.y, aperture).unwrap_or(0.0);
        let noise =
            (resid_ap_sigma.powi(2) + (opts.systematic_fraction * t_ap.max(0.0)).powi(2)).sqrt();
        let significance = if noise > 0.0 { r_ap / noise } else { 0.0 };
        if significance.is_nan() || significance < opts.min_significance {
            rejections.insignificant += 1;
            continue;
        }
        let backed = t_ap > 3.0 * tmpl_ap_sigma.max(f64::MIN_POSITIVE);
        let (kind, delta_mag) = if backed {
            let dm = -2.5 * ((t_ap + r_ap) / t_ap).log10();
            if dm.is_nan() || dm > -opts.min_brightening_mag {
                rejections.small_change += 1;
                continue;
            }
            (TransientKind::PointBrightening, dm)
        } else {
            (TransientKind::NewSource, f64::NEG_INFINITY)
        };
        candidates.push(TransientCandidate {
            ra,
            dec,
            tile_x: s.x,
            tile_y: s.y,
            residual_flux: r_ap,
            delta_mag,
            snr: significance,
            fwhm: s.fwhm,
            eccentricity: s.eccentricity,
            position_angle_deg: s.position_angle,
            kind,
        });
    }
    candidates.sort_by(|a, b| b.snr.total_cmp(&a.snr));

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
        matched_scale: scale,
        matched_offset: 0.0,
        normalization_stars,
        template_coverage_min,
        compared_pixels,
        rejections,
    })
}

/// Subtract a smooth background from one channel: the median of each
/// [`BACKGROUND_MESH`]² cell (over `mask` pixels), bilinearly interpolated
/// between cell centres. Pixels outside `mask` are left unchanged.
fn subtract_mesh_background(
    plane: &mut [f64],
    mask: &[bool],
    width: usize,
    height: usize,
    channels: usize,
    channel: usize,
) {
    let m = BACKGROUND_MESH;
    let gw = width.div_ceil(m);
    let gh = height.div_ceil(m);
    let mut grid = vec![f64::NAN; gw * gh];
    for gy in 0..gh {
        for gx in 0..gw {
            let mut vals: Vec<f64> = Vec::new();
            for y in gy * m..((gy + 1) * m).min(height) {
                for x in gx * m..((gx + 1) * m).min(width) {
                    let p = y * width + x;
                    if mask[p] {
                        let v = plane[p * channels + channel];
                        if v.is_finite() {
                            vals.push(v);
                        }
                    }
                }
            }
            if vals.len() >= m * m / 8 {
                // Clip stars before the median: two passes of 3σ (MAD).
                for _ in 0..2 {
                    let med = median(&mut vals.clone());
                    let mut dev: Vec<f64> = vals.iter().map(|v| (v - med).abs()).collect();
                    let sigma = MAD_TO_SIGMA * median(&mut dev);
                    if sigma > 0.0 {
                        vals.retain(|v| (v - med).abs() <= 3.0 * sigma);
                    }
                }
                if !vals.is_empty() {
                    grid[gy * gw + gx] = median(&mut vals);
                }
            }
        }
    }
    // Fill empty cells with the global median of the filled ones.
    let mut filled: Vec<f64> = grid.iter().cloned().filter(|v| v.is_finite()).collect();
    if filled.is_empty() {
        return;
    }
    let fill = median(&mut filled);
    for v in grid.iter_mut() {
        if !v.is_finite() {
            *v = fill;
        }
    }
    for y in 0..height {
        let gyf = ((y as f64 + 0.5) / m as f64 - 0.5).clamp(0.0, (gh - 1) as f64);
        let gy0 = gyf.floor() as usize;
        let gy1 = (gy0 + 1).min(gh - 1);
        let ty = gyf - gy0 as f64;
        for x in 0..width {
            let p = y * width + x;
            if !mask[p] {
                continue;
            }
            let gxf = ((x as f64 + 0.5) / m as f64 - 0.5).clamp(0.0, (gw - 1) as f64);
            let gx0 = gxf.floor() as usize;
            let gx1 = (gx0 + 1).min(gw - 1);
            let tx = gxf - gx0 as f64;
            let b = (1.0 - tx) * (1.0 - ty) * grid[gy0 * gw + gx0]
                + tx * (1.0 - ty) * grid[gy0 * gw + gx1]
                + (1.0 - tx) * ty * grid[gy1 * gw + gx0]
                + tx * ty * grid[gy1 * gw + gx1];
            plane[p * channels + channel] -= b;
        }
    }
}

/// `mask` eroded by a square of half-width `reach`: true where every pixel
/// within `reach` is set.
fn erode_mask(mask: &[bool], width: usize, height: usize, reach: usize) -> Vec<bool> {
    let cov: Vec<u32> = mask.iter().map(|&m| u32::from(m)).collect();
    crate::sky_atlas::eroded_coverage(&cov, width, height, 1, reach)
}

/// Sum of `plane` within a circular aperture of `radius` around `(cx, cy)`,
/// minus the median of an annulus `radius+3 .. radius+8` times the aperture
/// area. `None` when any aperture pixel is outside `mask`.
fn aperture_sum(
    plane: &[f64],
    mask: &[bool],
    width: usize,
    height: usize,
    cx: f64,
    cy: f64,
    radius: f64,
) -> Option<f64> {
    let r_out = radius + 8.0;
    let x0 = (cx - r_out).floor() as isize;
    let x1 = (cx + r_out).ceil() as isize;
    let y0 = (cy - r_out).floor() as isize;
    let y1 = (cy + r_out).ceil() as isize;
    let mut sum = 0.0;
    let mut n = 0usize;
    let mut sky: Vec<f64> = Vec::new();
    for y in y0..=y1 {
        for x in x0..=x1 {
            let dx = x as f64 - cx;
            let dy = y as f64 - cy;
            let r = (dx * dx + dy * dy).sqrt();
            if r > r_out {
                continue;
            }
            let inside = x >= 0 && y >= 0 && (x as usize) < width && (y as usize) < height;
            let p = if inside {
                y as usize * width + x as usize
            } else {
                0
            };
            if r <= radius {
                if !inside || !mask[p] {
                    return None;
                }
                sum += plane[p];
                n += 1;
            } else if r >= radius + 3.0 && inside && mask[p] {
                sky.push(plane[p]);
            }
        }
    }
    let bg = if sky.len() >= 8 {
        median(&mut sky)
    } else {
        0.0
    };
    Some(sum - bg * n as f64)
}

/// Robust σ of aperture sums placed on a regular lattice over `mask`.
fn empirical_aperture_sigma(
    plane: &[f64],
    mask: &[bool],
    width: usize,
    height: usize,
    radius: f64,
) -> f64 {
    let step = ((2.0 * radius + 17.0).ceil() as usize).max(8);
    let mut sums: Vec<f64> = Vec::new();
    let mut y = step / 2;
    while y < height {
        let mut x = step / 2;
        while x < width {
            if mask[y * width + x] {
                if let Some(s) =
                    aperture_sum(plane, mask, width, height, x as f64, y as f64, radius)
                {
                    sums.push(s);
                }
            }
            x += step;
        }
        y += step;
    }
    if sums.len() < 8 {
        return 0.0;
    }
    let med = median(&mut sums.clone());
    let mut dev: Vec<f64> = sums.iter().map(|s| (s - med).abs()).collect();
    MAD_TO_SIGMA * median(&mut dev)
}

/// Bright, unsaturated, isolated template stars (local maxima of the
/// background-subtracted template inside `mask`), as `(x, y, peak)`, brightest
/// first, at most 60.
fn template_reference_stars(
    tmpl_bs: &[f64],
    tmpl_raw: &[f64],
    mask: &[bool],
    width: usize,
    height: usize,
    tmpl_max: f64,
) -> Vec<(usize, usize, f64)> {
    let mut vals: Vec<f64> = (0..width * height)
        .filter(|&p| mask[p])
        .map(|p| tmpl_bs[p])
        .collect();
    if vals.len() < 64 {
        return Vec::new();
    }
    let med = median(&mut vals.clone());
    let mut dev: Vec<f64> = vals.iter().map(|v| (v - med).abs()).collect();
    let sigma = MAD_TO_SIGMA * median(&mut dev);
    vals.clear();
    if sigma.is_nan() || sigma <= 0.0 {
        return Vec::new();
    }
    let threshold = med + 25.0 * sigma;
    let mut peaks: Vec<(usize, usize, f64)> = Vec::new();
    for y in 2..height.saturating_sub(2) {
        for x in 2..width.saturating_sub(2) {
            let p = y * width + x;
            if !mask[p] || tmpl_bs[p] < threshold || tmpl_raw[p] >= 0.7 * tmpl_max {
                continue;
            }
            let v = tmpl_bs[p];
            let mut is_max = true;
            'nb: for dy in -2isize..=2 {
                for dx in -2isize..=2 {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let q = (y as isize + dy) as usize * width + (x as isize + dx) as usize;
                    if tmpl_bs[q] > v {
                        is_max = false;
                        break 'nb;
                    }
                }
            }
            if is_max {
                peaks.push((x, y, v));
            }
        }
    }
    peaks.sort_by(|a, b| b.2.total_cmp(&a.2));
    // Isolated: no other peak above a tenth of this one within 12 px.
    let mut out: Vec<(usize, usize, f64)> = Vec::new();
    for (i, &(x, y, v)) in peaks.iter().enumerate() {
        let crowded = peaks.iter().enumerate().any(|(j, &(x2, y2, v2))| {
            j != i && {
                let dx = x as f64 - x2 as f64;
                let dy = y as f64 - y2 as f64;
                dx * dx + dy * dy <= 144.0 && v2 >= 0.1 * v
            }
        });
        if !crowded {
            out.push((x, y, v));
            if out.len() >= 60 {
                break;
            }
        }
    }
    out
}

/// Largest raw frame value within `radius` px of `(fx, fy)` (all channels).
fn frame_window_max(
    src: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    fx: f64,
    fy: f64,
    radius: isize,
) -> f64 {
    let (cx, cy) = (fx.round() as isize, fy.round() as isize);
    let mut best = f64::NEG_INFINITY;
    for y in cy - radius..=cy + radius {
        for x in cx - radius..=cx + radius {
            if x < 0 || y < 0 || x as usize >= width || y as usize >= height {
                continue;
            }
            for c in 0..channels {
                best = best.max(src[(y as usize * width + x as usize) * channels + c]);
            }
        }
    }
    best
}

/// Whether the brightest frame pixel near `(fx, fy)` stands out from its four
/// neighbours more than a PSF of σ `sigma_px` allows: a hot pixel or a cosmic
/// ray rather than a star.
fn too_sharp(
    src: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    fx: f64,
    fy: f64,
    sigma_px: f64,
) -> bool {
    let at = |x: isize, y: isize| -> f64 {
        if x < 0 || y < 0 || x as usize >= width || y as usize >= height {
            return f64::NAN;
        }
        (0..channels)
            .map(|c| src[(y as usize * width + x as usize) * channels + c])
            .sum::<f64>()
            / channels as f64
    };
    let (cx, cy) = (fx.round() as isize, fy.round() as isize);
    let (mut px, mut py, mut peak) = (cx, cy, f64::NEG_INFINITY);
    for y in cy - 2..=cy + 2 {
        for x in cx - 2..=cx + 2 {
            let v = at(x, y);
            if v > peak {
                peak = v;
                px = x;
                py = y;
            }
        }
    }
    let mut ring: Vec<f64> = Vec::new();
    for y in py - 9..=py + 9 {
        for x in px - 9..=px + 9 {
            let r2 = (x - px).pow(2) + (y - py).pow(2);
            if (25..=81).contains(&r2) {
                let v = at(x, y);
                if v.is_finite() {
                    ring.push(v);
                }
            }
        }
    }
    if ring.len() < 8 || !peak.is_finite() {
        return false;
    }
    let bg = median(&mut ring);
    let excess = peak - bg;
    if excess <= 0.0 {
        return false;
    }
    let neighbours = [
        at(px - 1, py),
        at(px + 1, py),
        at(px, py - 1),
        at(px, py + 1),
    ];
    if neighbours.iter().any(|v| !v.is_finite()) {
        return false;
    }
    let ratio = (neighbours.iter().sum::<f64>() / 4.0 - bg) / excess;
    let sigma = sigma_px.max(0.5);
    let expected = (-1.0 / (2.0 * sigma * sigma)).exp();
    ratio < (0.5 * expected).max(0.15)
}

/// Whether a residual source sits on the core of a star near saturation in the
/// template, or in the wings of a template star far brighter than the residual.
fn near_bright_star(
    tmpl_raw: &[f64],
    mask: &[bool],
    width: usize,
    height: usize,
    s: &ResidualSource,
    tmpl_max: f64,
) -> bool {
    let (cx, cy) = (s.x.round() as isize, s.y.round() as isize);
    let local_sky = {
        let mut ring: Vec<f64> = Vec::new();
        for y in cy - 30..=cy + 30 {
            for x in cx - 30..=cx + 30 {
                let r2 = (x - cx).pow(2) + (y - cy).pow(2);
                if (r2 >= 26 * 26)
                    && x >= 0
                    && y >= 0
                    && (x as usize) < width
                    && (y as usize) < height
                {
                    let p = y as usize * width + x as usize;
                    if mask[p] {
                        ring.push(tmpl_raw[p]);
                    }
                }
            }
        }
        if ring.is_empty() {
            return false;
        }
        median(&mut ring)
    };
    let source_peak = s.peak.max(f64::MIN_POSITIVE);
    for y in cy - 25..=cy + 25 {
        for x in cx - 25..=cx + 25 {
            if x < 0 || y < 0 || x as usize >= width || y as usize >= height {
                continue;
            }
            let p = y as usize * width + x as usize;
            if !mask[p] {
                continue;
            }
            let v = tmpl_raw[p] - local_sky;
            let d2 = ((x - cx).pow(2) + (y - cy).pow(2)) as f64;
            if d2 <= 4.0 && tmpl_raw[p] >= 0.5 * tmpl_max {
                return true;
            }
            if d2 > 4.0 && v > 30.0 * source_peak {
                return true;
            }
        }
    }
    false
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
    /// Highest residual value in the footprint above the background.
    peak: f64,
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

    let peak = footprint
        .iter()
        .map(|&idx| plane[idx] - background)
        .fold(0.0f64, f64::max);
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
        peak,
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

    /// Deterministic standard-normal samples (LCG + Box–Muller).
    struct Noise(u64);
    impl Noise {
        fn uniform(&mut self) -> f64 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((self.0 >> 11) as f64 + 0.5) / (1u64 << 53) as f64
        }
        fn normal(&mut self) -> f64 {
            let (u1, u2) = (self.uniform(), self.uniform());
            (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
        }
    }

    const W: usize = 400;

    /// A star field like a real sub: 30 stars of 2,000–40,000 ADU total flux on
    /// a sky pedestal with Gaussian noise.
    fn field_stars() -> Vec<(f64, f64, f64)> {
        let mut n = Noise(7);
        (0..30)
            .map(|i| {
                let x = 40.0 + n.uniform() * (W as f64 - 80.0);
                let y = 40.0 + n.uniform() * (W as f64 - 80.0);
                (x, y, 2000.0 + 38000.0 * (i as f64 / 29.0).powi(2))
            })
            .collect()
    }

    fn render_field(
        stars: &[(f64, f64, f64)],
        sky: f64,
        sigma_psf: f64,
        noise: f64,
        seed: u64,
    ) -> Vec<f32> {
        let mut buf = vec![0.0f32; W * W];
        let mut n = Noise(seed);
        for v in buf.iter_mut() {
            *v = (sky + noise * n.normal()) as f32;
        }
        for &(cx, cy, flux) in stars {
            render_star(&mut buf, W, W, cx, cy, flux, sigma_psf);
        }
        buf
    }

    /// A template co-added from `n_frames` independent noisy renderings of
    /// `stars`, folded on the tile's own grid (reprojection is the identity).
    fn build_template(
        tile_id: u64,
        stars: &[(f64, f64, f64)],
        n_frames: usize,
    ) -> SkyTileAccumulator {
        let order = ATLAS_HEALPIX_ORDER;
        let wcs = tile_wcs(tile_id, order);
        let mut acc = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        for i in 0..n_frames {
            let buf = render_field(stars, 500.0, 1.6, 10.0, 100 + i as u64);
            let img = ImageData::from_f32(W as u32, W as u32, 1, &buf);
            acc.fold_frame(
                &img,
                &wcs,
                1.0,
                120.0,
                Interpolator::Bilinear,
                &format!("t{i}"),
                "",
            )
            .expect("fold");
        }
        acc
    }

    fn cfg() -> StarDetectionConfig {
        StarDetectionConfig {
            detection_sigma: 5.0,
            min_area: 3,
            max_area: 2000,
            min_snr: 4.0,
            min_hfr: 1.0,
            ..StarDetectionConfig::default()
        }
    }

    fn tile() -> u64 {
        crate::sky_atlas::radec_to_tile(120.0, 25.0, ATLAS_HEALPIX_ORDER)
    }

    fn run(
        template: &SkyTileAccumulator,
        frame: &[f32],
        opts: &DifferenceOptions,
    ) -> DifferenceResult {
        let wcs = tile_wcs(template.tile_id, ATLAS_HEALPIX_ORDER);
        let img = ImageData::from_f32(W as u32, W as u32, 1, frame);
        difference_against_template(template, &img, &wcs, Interpolator::Bilinear, &cfg(), opts)
            .expect("difference")
    }

    #[test]
    fn new_source_is_found_and_stable_stars_cancel() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let mut frame = render_field(&stars, 500.0, 1.6, 10.0, 999);
        render_star(&mut frame, W, W, 205.0, 117.0, 2500.0, 1.6);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(res.normalization_stars >= MIN_NORMALIZATION_STARS);
        assert_eq!(
            res.candidates.len(),
            1,
            "{:?} {:?}",
            res.candidates,
            res.rejections
        );
        let c = &res.candidates[0];
        assert!((c.tile_x - 205.0).abs() < 1.5 && (c.tile_y - 117.0).abs() < 1.5);
        assert_eq!(c.kind, TransientKind::NewSource);
        assert!(c.snr >= 7.0);
    }

    #[test]
    fn a_hazier_frame_scales_on_star_flux_and_cancels() {
        // Thin cloud: 60% of the starlight and a brighter sky. A sky-noise
        // normalization would turn every star into a residual.
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let dim: Vec<(f64, f64, f64)> = stars.iter().map(|&(x, y, f)| (x, y, 0.6 * f)).collect();
        let frame = render_field(&dim, 900.0, 1.6, 14.0, 4242);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(
            (res.matched_scale - 1.0 / 0.6).abs() < 0.08,
            "scale {}",
            res.matched_scale
        );
        assert!(res.candidates.is_empty(), "{:?}", res.candidates);
    }

    #[test]
    fn worse_seeing_alone_produces_no_candidates() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let frame = render_field(&stars, 500.0, 2.6, 10.0, 77);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(
            res.candidates.is_empty(),
            "{:?} {:?}",
            res.candidates,
            res.rejections
        );
    }

    #[test]
    fn brightening_reports_the_measured_change() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let mut bright = stars.clone();
        let (bx, by, bf) = bright[10];
        bright[10] = (bx, by, bf * 3.0);
        let frame = render_field(&bright, 500.0, 1.6, 10.0, 31);
        let res = run(&template, &frame, &DifferenceOptions::default());
        let c = res
            .candidates
            .iter()
            .find(|c| (c.tile_x - bx).abs() < 2.0 && (c.tile_y - by).abs() < 2.0)
            .expect("brightening found");
        assert_eq!(c.kind, TransientKind::PointBrightening);
        let want = -2.5 * 3.0f64.log10();
        assert!(
            (c.delta_mag - want).abs() < 0.15,
            "dm {} want {want}",
            c.delta_mag
        );
        assert_eq!(res.candidates.len(), 1, "{:?}", res.candidates);
    }

    #[test]
    fn a_small_change_of_a_template_star_is_not_reported() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let mut changed = stars.clone();
        let (bx, by, bf) = changed[29];
        changed[29] = (bx, by, bf * 1.15);
        let frame = render_field(&changed, 500.0, 1.6, 10.0, 5);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(res.candidates.is_empty(), "{:?}", res.candidates);
    }

    #[test]
    fn hot_pixel_and_cosmic_ray_are_rejected() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let mut frame = render_field(&stars, 500.0, 1.6, 10.0, 8);
        frame[150 * W + 300] = 30000.0;
        frame[250 * W + 120] = 12000.0;
        frame[250 * W + 121] = 9000.0;
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(res.candidates.is_empty(), "{:?}", res.candidates);
    }

    #[test]
    fn sources_at_the_frame_edge_or_saturated_are_rejected() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 8);
        let mut frame = render_field(&stars, 500.0, 1.6, 10.0, 9);
        render_star(&mut frame, W, W, 6.0, 200.0, 8000.0, 1.6);
        render_star(&mut frame, W, W, 300.0, 300.0, 400000.0, 1.6);
        let res = run(
            &template,
            &frame,
            &DifferenceOptions {
                saturation_level: Some(20000.0),
                ..DifferenceOptions::default()
            },
        );
        assert!(res.candidates.is_empty(), "{:?}", res.candidates);
        assert!(res.rejections.saturated >= 1, "{:?}", res.rejections);
    }

    #[test]
    fn a_shallow_template_is_not_compared() {
        let stars = field_stars();
        let template = build_template(tile(), &stars, 3);
        let mut frame = render_field(&stars, 500.0, 1.6, 10.0, 10);
        render_star(&mut frame, W, W, 205.0, 117.0, 8000.0, 1.6);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(res.candidates.is_empty());
        assert_eq!(res.compared_pixels, 0);
    }

    #[test]
    fn a_field_without_enough_stars_is_not_differenced() {
        let stars: Vec<(f64, f64, f64)> = field_stars().into_iter().take(3).collect();
        let template = build_template(tile(), &stars, 8);
        let mut frame = render_field(&stars, 500.0, 1.6, 10.0, 11);
        render_star(&mut frame, W, W, 205.0, 117.0, 8000.0, 1.6);
        let res = run(&template, &frame, &DifferenceOptions::default());
        assert!(res.normalization_stars < MIN_NORMALIZATION_STARS);
        assert!(res.candidates.is_empty());
    }

    #[test]
    fn channel_mismatch_is_rejected() {
        let order = ATLAS_HEALPIX_ORDER;
        let tile_id = crate::sky_atlas::radec_to_tile(0.0, 0.0, order);
        let template = SkyTileAccumulator::create(tile_id, order, 1, no_clip());
        let wcs = tile_wcs(tile_id, order);
        let frame = ImageData::from_f32(16, 16, 3, &vec![0.0; 16 * 16 * 3]);
        let err = difference_against_template(
            &template,
            &frame,
            &wcs,
            Interpolator::Bilinear,
            &cfg(),
            &DifferenceOptions::default(),
        )
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
        let err = difference_against_template(
            &template,
            &frame,
            &bad,
            Interpolator::Bilinear,
            &cfg(),
            &DifferenceOptions::default(),
        )
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
