//! High-quality star-based image registration.
//!
//! This module implements the "precise" alignment path used when stacking
//! demands sub-pixel accuracy across frames that may differ by translation,
//! rotation, scale, flip, or even mild optical distortion — the regime where
//! the [`crate::stacking::LiveStacker`]'s deliberately-cheap rigid path
//! (translation + small rotation, nearest-neighbour star matching) is not
//! good enough.
//!
//! Pipeline (PixInsight StarAlignment / astrometry.net lineage):
//!
//! 1. **Star detection** — reuse [`crate::detect_stars`], which already does
//!    PSF-weighted sub-pixel centroiding in [`crate::stats::measure_star`].
//!    We additionally re-centroid in this module is *not* required because the
//!    detector's centroid is already flux-weighted to sub-pixel precision.
//!
//! 2. **Geometric matching** — descriptors built from triangles of stars.
//!    A triangle's two side-length *ratios* (longest-normalised) are invariant
//!    to translation, rotation, uniform scale, and reflection, so two frames
//!    that differ by any similarity transform (with or without a flip) produce
//!    matching triangle descriptors. Descriptors are matched in a 2-D ratio
//!    space, and each descriptor match casts votes for the underlying star↔star
//!    correspondences. Stars that consistently co-occur across many matched
//!    triangles win — this is robust to a large fraction (>30%) of spurious
//!    detections in either frame because a false star rarely forms congruent
//!    triangles with several true stars.
//!
//! 3. **RANSAC transform estimation** — from the voted correspondences we fit a
//!    [`TransformModel`] (similarity, affine, or homography) with RANSAC to
//!    reject the remaining mismatches, then refine on all inliers by
//!    least-squares.
//!
//! 4. **Resampling** — the source frame is warped onto the reference grid using
//!    a high-quality separable interpolator ([`Interpolator::Lanczos3`] or
//!    [`Interpolator::CatmullRom`]). Both are flux-approximately-conserving for
//!    smooth signals; bilinear is offered for parity/speed.
//!
//! The public entry point is [`register_frame`].

use crate::{detect_stars, DetectedStar, ImageData, PixelType, StarDetectionConfig};
use rayon::prelude::*;

// Public types

/// Which transform family to fit between the two frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TransformKind {
    /// 4 degrees of freedom: uniform scale, rotation, translation (no shear).
    /// Optionally reflected. This is the correct model for two frames from the
    /// same optical train differing only by mount motion / field rotation, and
    /// it is the most robust because it needs the fewest correspondences (2).
    #[default]
    Similarity,
    /// 6 degrees of freedom: independent x/y scale + shear + translation.
    /// Absorbs mild differential flexure / non-square-pixel mismatch. Needs 3
    /// correspondences.
    Affine,
    /// 8 degrees of freedom: full projective transform. Absorbs keystone /
    /// strong field distortion between very different optical setups. Needs 4
    /// correspondences and is the least numerically stable, so it is opt-in.
    Homography,
}

/// A fitted 2-D coordinate transform mapping *source* (frame B) pixel
/// coordinates to *reference* (frame A) pixel coordinates.
///
/// Internally every model is stored as a 3×3 homogeneous matrix `H` such that
/// `[x' y' w']ᵀ = H · [x y 1]ᵀ` and the mapped point is `(x'/w', y'/w')`. For
/// similarity and affine models the bottom row is `[0 0 1]` (so `w' ≡ 1`); the
/// homography uses a general bottom row. Storing one representation keeps the
/// forward/inverse mapping and residual code uniform across models.
#[derive(Debug, Clone, Copy)]
pub struct TransformModel {
    /// Row-major 3×3 homogeneous matrix (source → reference).
    pub matrix: [[f64; 3]; 3],
    /// Which family this matrix was fitted as (purely informational).
    pub kind: TransformKind,
}

impl TransformModel {
    /// The identity transform.
    pub fn identity() -> Self {
        Self {
            matrix: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            kind: TransformKind::Similarity,
        }
    }

    /// Map a source point to reference coordinates.
    #[inline]
    pub fn apply(&self, x: f64, y: f64) -> (f64, f64) {
        let m = &self.matrix;
        let xp = m[0][0] * x + m[0][1] * y + m[0][2];
        let yp = m[1][0] * x + m[1][1] * y + m[1][2];
        let wp = m[2][0] * x + m[2][1] * y + m[2][2];
        if wp.abs() < f64::EPSILON {
            (f64::NAN, f64::NAN)
        } else {
            (xp / wp, yp / wp)
        }
    }

    /// The inverse transform (reference → source), used when resampling because
    /// the warp samples the source for each reference-grid pixel.
    pub fn inverse(&self) -> Option<Self> {
        invert_3x3(&self.matrix).map(|m| Self {
            matrix: m,
            kind: self.kind,
        })
    }

    /// Approximate isotropic scale factor of the transform, derived from the
    /// determinant of the upper-left 2×2 block. Used to convert pixel residuals
    /// into reference-frame pixels and to sanity-check fits (a similarity warp
    /// of an astrophoto stack should be ≈1.0).
    pub fn scale(&self) -> f64 {
        let a = self.matrix[0][0];
        let b = self.matrix[0][1];
        let c = self.matrix[1][0];
        let d = self.matrix[1][1];
        (a * d - b * c).abs().sqrt()
    }
}

/// High-quality resampling kernels for the warp step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Interpolator {
    /// 2×2 bilinear — fastest, softest; matches the rigid `LiveStacker` path.
    Bilinear,
    /// 4×4 Catmull-Rom cubic — sharp, no ringing, mild overshoot. A good
    /// default for noisy sub-frames where Lanczos ringing on bright stars is
    /// undesirable.
    CatmullRom,
    /// 6×6 windowed-sinc (Lanczos, `a = 3`) — sharpest reconstruction, the
    /// PixInsight default for high-SNR data; can ring around saturated stars.
    #[default]
    Lanczos3,
}

/// Per-frame registration quality report.
#[derive(Debug, Clone)]
pub struct RegistrationStats {
    /// Stars detected in the reference frame.
    pub reference_star_count: usize,
    /// Stars detected in the frame being registered.
    pub frame_star_count: usize,
    /// Star↔star correspondences that survived geometric matching.
    pub correspondence_count: usize,
    /// Correspondences classified as inliers by RANSAC + refinement.
    pub inlier_count: usize,
    /// Fraction of correspondences that were inliers, in `[0, 1]`.
    pub inlier_fraction: f64,
    /// RMS residual of inliers, in reference-frame pixels.
    pub rms_residual_px: f64,
    /// RMS residual in arcseconds, if a plate scale (arcsec/px) was supplied.
    pub rms_residual_arcsec: Option<f64>,
}

/// The complete result of registering one frame onto a reference.
#[derive(Debug, Clone)]
pub struct RegisteredFrame {
    /// Source → reference transform.
    pub transform: TransformModel,
    /// The source frame resampled onto the reference grid. Same dimensions,
    /// channel count, and pixel type as the reference. Pixels with no valid
    /// source support (mapped outside the source frame) are zero-filled.
    pub aligned: ImageData,
    /// Quality metrics for this registration.
    pub stats: RegistrationStats,
}

/// Tunables for the registration pipeline. [`Default`] values are tuned for
/// typical deep-sky sub-frames (50–500 stars).
#[derive(Debug, Clone)]
pub struct RegistrationConfig {
    /// Star detection parameters (shared with the rest of the imaging crate).
    pub star_detection: StarDetectionConfig,
    /// Brightest-N stars used to build triangle descriptors. Triangle count is
    /// `C(n, 3)`, so this is capped to keep matching tractable; 60 → ~34k
    /// triangles per frame, which is plenty for a robust fit.
    pub max_stars_for_matching: usize,
    /// Tolerance on the (normalised) triangle side-length ratios when matching
    /// descriptors between frames. Larger tolerates more centroid noise / mild
    /// distortion at the cost of more spurious descriptor matches (which the
    /// vote step and RANSAC then filter).
    pub descriptor_tolerance: f64,
    /// Transform family to fit.
    pub transform_kind: TransformKind,
    /// RANSAC inlier threshold in reference-frame pixels.
    pub ransac_threshold_px: f64,
    /// Maximum RANSAC iterations (an adaptive early-out usually stops sooner).
    pub ransac_max_iterations: usize,
    /// Minimum inlier correspondences required to accept a fit. Below this the
    /// registration fails closed rather than returning a garbage transform.
    pub min_inliers: usize,
    /// Resampling kernel.
    pub interpolator: Interpolator,
    /// Optional plate scale (arcsec/pixel) to report `rms_residual_arcsec`.
    pub arcsec_per_pixel: Option<f64>,
}

impl Default for RegistrationConfig {
    fn default() -> Self {
        Self {
            star_detection: StarDetectionConfig::default(),
            max_stars_for_matching: 60,
            descriptor_tolerance: 0.004,
            transform_kind: TransformKind::Similarity,
            ransac_threshold_px: 2.0,
            ransac_max_iterations: 2000,
            min_inliers: 6,
            interpolator: Interpolator::Lanczos3,
            arcsec_per_pixel: None,
        }
    }
}

/// Errors from the registration pipeline. These are *expected* failure modes
/// (too few stars, no consistent geometry); they are returned so the caller can
/// fall back to the rigid path or skip the sub-frame, never silently producing
/// a misaligned stack.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum RegistrationError {
    #[error("frames must be U16; reference is {0:?}")]
    UnsupportedReferencePixelType(PixelType),
    #[error("frames must be U16; frame is {0:?}")]
    UnsupportedFramePixelType(PixelType),
    #[error("reference and frame channel counts differ ({reference} vs {frame})")]
    ChannelMismatch { reference: u32, frame: u32 },
    #[error("unsupported channel count {0}; only 1 (mono) and 3 (RGB) are supported")]
    UnsupportedChannels(u32),
    #[error("too few stars to register: reference={reference}, frame={frame}, need >= {needed}")]
    TooFewStars {
        reference: usize,
        frame: usize,
        needed: usize,
    },
    #[error(
        "could not establish a consistent geometry: only {found} correspondences/inliers, need >= {needed}"
    )]
    NoConsistentGeometry { found: usize, needed: usize },
}

// Public entry point

/// The number of detected stars [`register_frame`] requires on BOTH the
/// reference and the frame for `kind`: enough to form triangles and to fit the
/// minimal model.
pub fn min_registration_stars(kind: TransformKind) -> usize {
    3usize.max(min_correspondences(kind))
}

/// How many stars [`register_frame`] would actually detect on `image` with
/// `config` — 0 when the image cannot be a registration operand at all (wrong
/// pixel type or channel layout, exactly as [`register_frame`] validates).
///
/// Exposed so a caller *choosing* an alignment reference can reject a candidate
/// this detector cannot see, rather than discovering it one failed frame at a
/// time. A frame can score highest on SNR/sharpness/roundness and still yield
/// zero centroids — a near-saturated star flattens the local peak the detector
/// looks for — and picking that frame as the reference fails EVERY other frame
/// against it, silently discarding a whole night.
pub fn registrable_star_count(image: &ImageData, config: &RegistrationConfig) -> usize {
    if image.pixel_type != PixelType::U16 || !matches!(image.channels, 1 | 3) {
        return 0;
    }
    detect_stars(&detection_plane(image), &config.star_detection).len()
}

/// Register `frame` (source) onto `reference`, returning the fitted transform,
/// the resampled aligned frame, and quality statistics.
///
/// This is the high-quality alternative to the rigid alignment baked into
/// [`crate::stacking::LiveStacker`]. It is robust to rotation, scale, and flip
/// between the two frames and to a large fraction of spurious star detections.
pub fn register_frame(
    reference: &ImageData,
    frame: &ImageData,
    config: &RegistrationConfig,
) -> Result<RegisteredFrame, RegistrationError> {
    let (transform, stats) = solve_registration(reference, frame, config)?;
    let aligned = warp_frame(frame, reference, &transform, config.interpolator);
    Ok(RegisteredFrame {
        transform,
        aligned,
        stats,
    })
}

/// The star-based geometry fit on its own: the source→reference transform and
/// its residual statistics, without resampling the frame.
///
/// [`register_frame`] is this plus the warp. Callers that only need the
/// geometry — DepthLock composes it with the reference frame's WCS and then
/// samples the *unwarped* signed pixels — skip the full-frame Lanczos pass
/// and the quantized aligned preview it would produce.
pub fn solve_registration(
    reference: &ImageData,
    frame: &ImageData,
    config: &RegistrationConfig,
) -> Result<(TransformModel, RegistrationStats), RegistrationError> {
    validate_pair(reference, frame)?;

    let ref_plane = detection_plane(reference);
    let frame_plane = detection_plane(frame);

    let ref_stars = detect_stars(&ref_plane, &config.star_detection);
    let frame_stars = detect_stars(&frame_plane, &config.star_detection);

    // We need at least enough stars to form triangles and a minimal fit.
    let min_stars = min_registration_stars(config.transform_kind);
    if ref_stars.len() < min_stars || frame_stars.len() < min_stars {
        return Err(RegistrationError::TooFewStars {
            reference: ref_stars.len(),
            frame: frame_stars.len(),
            needed: min_stars,
        });
    }

    let transform = solve_transform_from_stars(&ref_stars, &frame_stars, config).ok_or(
        RegistrationError::NoConsistentGeometry {
            found: 0,
            needed: config.min_inliers,
        },
    )?;

    // Recompute the correspondence/inlier statistics for the returned model.
    let correspondences = correspondences_from_stars(&ref_stars, &frame_stars, config);
    let residuals: Vec<f64> = correspondences
        .iter()
        .map(|c| {
            let (mx, my) = transform.model.apply(c.frame.0, c.frame.1);
            ((mx - c.reference.0).powi(2) + (my - c.reference.1).powi(2)).sqrt()
        })
        .collect();

    let inlier_residuals: Vec<f64> = residuals
        .iter()
        .copied()
        .filter(|r| *r <= config.ransac_threshold_px)
        .collect();

    let inlier_count = inlier_residuals.len();
    if inlier_count < config.min_inliers {
        return Err(RegistrationError::NoConsistentGeometry {
            found: inlier_count,
            needed: config.min_inliers,
        });
    }

    let rms_residual_px = rms(&inlier_residuals);
    let correspondence_count = correspondences.len();

    let stats = RegistrationStats {
        reference_star_count: ref_stars.len(),
        frame_star_count: frame_stars.len(),
        correspondence_count,
        inlier_count,
        inlier_fraction: if correspondence_count == 0 {
            0.0
        } else {
            inlier_count as f64 / correspondence_count as f64
        },
        rms_residual_px,
        rms_residual_arcsec: config.arcsec_per_pixel.map(|s| rms_residual_px * s),
    };

    Ok((transform.model, stats))
}

// Validation + detection-plane helpers

fn validate_pair(reference: &ImageData, frame: &ImageData) -> Result<(), RegistrationError> {
    if reference.pixel_type != PixelType::U16 {
        return Err(RegistrationError::UnsupportedReferencePixelType(
            reference.pixel_type,
        ));
    }
    if frame.pixel_type != PixelType::U16 {
        return Err(RegistrationError::UnsupportedFramePixelType(
            frame.pixel_type,
        ));
    }
    if reference.channels != frame.channels {
        return Err(RegistrationError::ChannelMismatch {
            reference: reference.channels,
            frame: frame.channels,
        });
    }
    if !matches!(reference.channels, 1 | 3) {
        return Err(RegistrationError::UnsupportedChannels(reference.channels));
    }
    Ok(())
}

/// Single-channel plane that star detection runs on. Mono frames are borrowed
/// unchanged; RGB frames are collapsed to a Rec. 601 luminance proxy so star
/// centroids come from a coherent plane (mirrors `stacking::detection_plane`).
fn detection_plane(frame: &ImageData) -> std::borrow::Cow<'_, ImageData> {
    match frame.channels {
        1 => std::borrow::Cow::Borrowed(frame),
        3 => std::borrow::Cow::Owned(luminance_proxy(frame)),
        other => unreachable!("validate_pair rejects channel count {other}"),
    }
}

fn luminance_proxy(rgb: &ImageData) -> ImageData {
    let width = rgb.width;
    let height = rgb.height;
    let pixel_count = (width as usize) * (height as usize);
    let interleaved = rgb
        .as_u16()
        .expect("luminance_proxy requires a U16 RGB image");

    let luma: Vec<u16> = (0..pixel_count)
        .into_par_iter()
        .map(|i| {
            let base = i * 3;
            let r = interleaved[base] as f64;
            let g = interleaved[base + 1] as f64;
            let b = interleaved[base + 2] as f64;
            (0.299 * r + 0.587 * g + 0.114 * b)
                .round()
                .clamp(0.0, 65535.0) as u16
        })
        .collect();

    ImageData::from_u16(width, height, 1, &luma)
}

// Geometric matching (triangle descriptors -> star correspondences)

/// A pairing of a reference star centroid with a frame star centroid.
#[derive(Debug, Clone, Copy)]
struct Correspondence {
    reference: (f64, f64),
    frame: (f64, f64),
}

/// A triangle descriptor: the indices of the three stars (ordered so side
/// `a >= b >= c`) and the two scale/rotation/flip-invariant side-length ratios
/// `(b/a, c/a)`. Two congruent triangles (up to similarity, including a flip)
/// share the same `(r1, r2)` to within centroid noise.
#[derive(Debug, Clone, Copy)]
struct TriangleDescriptor {
    /// Star indices, ordered so the vertex opposite the longest side is first.
    /// Concretely: `v[0]`–`v[1]` is the longest side, `v[1]`–`v[2]` the middle,
    /// `v[2]`–`v[0]` the shortest. This canonical vertex ordering lets us read
    /// off star↔star correspondences directly when two descriptors match.
    vertices: [usize; 3],
    r1: f64,
    r2: f64,
}

/// Build triangle descriptors from the brightest stars.
///
/// Cost is `C(n, 3)`; with the default cap of 60 stars that is ~34k triangles,
/// which is comfortably fast. Stars are assumed pre-sorted brightest-first by
/// `detect_stars`, so taking the prefix keeps the most reliable centroids.
fn build_descriptors(stars: &[DetectedStar], max_stars: usize) -> Vec<TriangleDescriptor> {
    let n = stars.len().min(max_stars);
    let mut descriptors = Vec::new();

    for i in 0..n {
        for j in (i + 1)..n {
            for k in (j + 1)..n {
                if let Some(d) = describe_triangle(stars, i, j, k) {
                    descriptors.push(d);
                }
            }
        }
    }

    descriptors
}

/// Compute the canonical descriptor for the triangle (i, j, k), or `None` if it
/// is degenerate (collinear / coincident stars).
fn describe_triangle(
    stars: &[DetectedStar],
    i: usize,
    j: usize,
    k: usize,
) -> Option<TriangleDescriptor> {
    let p = [
        (stars[i].x, stars[i].y),
        (stars[j].x, stars[j].y),
        (stars[k].x, stars[k].y),
    ];
    let idx = [i, j, k];

    // Side `s[e]` is the edge *opposite* vertex `e`, i.e. between the other two.
    let dist = |a: usize, b: usize| -> f64 {
        let dx = p[a].0 - p[b].0;
        let dy = p[a].1 - p[b].1;
        (dx * dx + dy * dy).sqrt()
    };
    // edge lengths: e01, e12, e20
    let e01 = dist(0, 1);
    let e12 = dist(1, 2);
    let e20 = dist(2, 0);

    // Order edges descending to find the longest/middle/shortest and the
    // canonical vertex layout. We want vertices ordered so v0-v1 is longest,
    // v1-v2 is middle, v2-v0 is shortest.
    // Represent each edge by (length, endpoint_a, endpoint_b).
    let edges = [(e01, 0usize, 1usize), (e12, 1, 2), (e20, 2, 0)];

    let longest = edges
        .iter()
        .copied()
        .max_by(|a, b| a.0.total_cmp(&b.0))
        .unwrap();
    let shortest = edges
        .iter()
        .copied()
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .unwrap();

    let a = longest.0;
    if a < f64::EPSILON {
        return None; // coincident stars
    }

    // The middle edge length is total - longest - shortest only if all three
    // edges are distinct; instead pick the edge that is neither longest nor
    // shortest by length value. Guard the rare ties by recomputing.
    let mut mid_len = f64::NAN;
    for &(len, _, _) in &edges {
        if (len - longest.0).abs() > f64::EPSILON && (len - shortest.0).abs() > f64::EPSILON {
            mid_len = len;
            break;
        }
    }
    // Tie handling: if two edges share the longest or shortest length, the
    // "middle" is whichever wasn't consumed; fall back to sorting.
    if !mid_len.is_finite() {
        let mut lens = [e01, e12, e20];
        lens.sort_by(f64::total_cmp);
        mid_len = lens[1];
    }

    let b = mid_len;
    let c = shortest.0;

    // Reject near-collinear triangles: the shortest side relative to the
    // longest is tiny, which makes the descriptor unstable and the vertex
    // ordering ambiguous.
    let r1 = b / a;
    let r2 = c / a;
    if r2 < 0.02 {
        return None;
    }

    // Canonical vertex ordering: v0 and v1 are the endpoints of the longest
    // edge; v2 is the remaining vertex. We further fix the v0/v1 ordering by a
    // chirality-independent rule (smaller global index first) so both frames
    // order identical triangles the same way regardless of flip.
    let (la, lb) = (longest.1, longest.2);
    let local_remaining = 3 - la - lb; // 0+1+2 = 3
    let v0_local = la.min(lb);
    let v1_local = la.max(lb);
    let v2_local = local_remaining;

    Some(TriangleDescriptor {
        vertices: [idx[v0_local], idx[v1_local], idx[v2_local]],
        r1,
        r2,
    })
}

/// Match descriptors between reference and frame and accumulate star↔star votes.
///
/// Each matched descriptor pair (similar `(r1, r2)`) implies three star
/// correspondences via the canonical vertex ordering. We tally votes in a
/// `(ref_star, frame_star)` histogram; true correspondences accumulate many
/// votes because they participate in many congruent triangles, while spurious
/// stars scatter their (few) votes and never win.
fn correspondences_from_stars(
    ref_stars: &[DetectedStar],
    frame_stars: &[DetectedStar],
    config: &RegistrationConfig,
) -> Vec<Correspondence> {
    let ref_desc = build_descriptors(ref_stars, config.max_stars_for_matching);
    let mut frame_desc = build_descriptors(frame_stars, config.max_stars_for_matching);

    if ref_desc.is_empty() || frame_desc.is_empty() {
        return Vec::new();
    }

    // Sort frame descriptors by r1 so we can binary-search a candidate window
    // instead of scanning every reference×frame descriptor pair.
    frame_desc.sort_by(|a, b| a.r1.total_cmp(&b.r1));
    let frame_r1: Vec<f64> = frame_desc.iter().map(|d| d.r1).collect();

    let tol = config.descriptor_tolerance;
    let n_ref = ref_stars.len().min(config.max_stars_for_matching);
    let n_frame = frame_stars.len().min(config.max_stars_for_matching);

    // votes[ref_idx * n_frame + frame_idx]
    let mut votes = vec![0u32; n_ref * n_frame];

    for rd in &ref_desc {
        let lo = lower_bound(&frame_r1, rd.r1 - tol);
        let hi = lower_bound(&frame_r1, rd.r1 + tol);
        for fd in &frame_desc[lo..hi] {
            if (fd.r2 - rd.r2).abs() > tol {
                continue;
            }
            // Congruent triangle: vertices correspond by canonical order.
            for slot in 0..3 {
                let ri = rd.vertices[slot];
                let fi = fd.vertices[slot];
                if ri < n_ref && fi < n_frame {
                    votes[ri * n_frame + fi] += 1;
                }
            }
        }
    }

    // For each reference star, take the frame star with the most votes, then
    // enforce a mutual / unique assignment (greedy by vote strength) so two
    // reference stars cannot both claim the same frame star.
    let mut candidates: Vec<(u32, usize, usize)> = Vec::new(); // (votes, ref, frame)
    for ri in 0..n_ref {
        let mut best_votes = 0u32;
        let mut best_fi = usize::MAX;
        for fi in 0..n_frame {
            let v = votes[ri * n_frame + fi];
            if v > best_votes {
                best_votes = v;
                best_fi = fi;
            }
        }
        // Require a minimum of corroborating triangles to suppress noise pairs.
        if best_fi != usize::MAX && best_votes >= 3 {
            candidates.push((best_votes, ri, best_fi));
        }
    }

    candidates.sort_by_key(|c| std::cmp::Reverse(c.0));

    let mut used_frame = vec![false; n_frame];
    let mut correspondences = Vec::new();
    for (_, ri, fi) in candidates {
        if used_frame[fi] {
            continue;
        }
        used_frame[fi] = true;
        correspondences.push(Correspondence {
            reference: (ref_stars[ri].x, ref_stars[ri].y),
            frame: (frame_stars[fi].x, frame_stars[fi].y),
        });
    }

    correspondences
}

/// First index `i` in the sorted slice with `slice[i] >= value`.
fn lower_bound(slice: &[f64], value: f64) -> usize {
    let mut lo = 0usize;
    let mut hi = slice.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if slice[mid] < value {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

// RANSAC transform estimation

struct FittedTransform {
    model: TransformModel,
}

fn min_correspondences(kind: TransformKind) -> usize {
    match kind {
        TransformKind::Similarity => 2,
        TransformKind::Affine => 3,
        TransformKind::Homography => 4,
    }
}

/// Full matching + RANSAC + refinement, returning the best transform or `None`
/// if no consistent geometry meets `config.min_inliers`.
fn solve_transform_from_stars(
    ref_stars: &[DetectedStar],
    frame_stars: &[DetectedStar],
    config: &RegistrationConfig,
) -> Option<FittedTransform> {
    let correspondences = correspondences_from_stars(ref_stars, frame_stars, config);
    ransac(&correspondences, config)
}

/// Estimate the transform with RANSAC over the correspondence set.
fn ransac(
    correspondences: &[Correspondence],
    config: &RegistrationConfig,
) -> Option<FittedTransform> {
    let sample_size = min_correspondences(config.transform_kind);
    let n = correspondences.len();
    if n < sample_size.max(config.min_inliers) {
        return None;
    }

    let threshold_sq = config.ransac_threshold_px * config.ransac_threshold_px;
    let mut rng = Rng::new(0x5eed_1234_abcd_ef01);

    let mut best_inliers: Vec<usize> = Vec::new();
    let mut iterations = config.ransac_max_iterations;
    let mut iter = 0usize;

    while iter < iterations {
        iter += 1;

        // Draw a minimal, distinct random sample.
        let sample = match draw_sample(n, sample_size, &mut rng) {
            Some(s) => s,
            None => continue,
        };
        let sample_pairs: Vec<Correspondence> =
            sample.iter().map(|&i| correspondences[i]).collect();

        let model = match fit_model(&sample_pairs, config.transform_kind) {
            Some(m) => m,
            None => continue, // degenerate sample
        };

        // Reject obviously broken similarity fits (e.g. collapsed scale) early.
        let scale = model.scale();
        if !scale.is_finite() || !(1e-3..=1e3).contains(&scale) {
            continue;
        }

        let inliers = inliers_for(correspondences, &model, threshold_sq);
        if inliers.len() > best_inliers.len() {
            best_inliers = inliers;

            // Adaptive iteration count: once we have a good inlier ratio we can
            // stop far short of the hard cap (standard RANSAC stopping rule).
            let w = best_inliers.len() as f64 / n as f64;
            if w > 0.0 {
                let p_no_outlier = 1.0 - w.powi(sample_size as i32);
                if p_no_outlier > f64::EPSILON && p_no_outlier < 1.0 {
                    let needed = ((1.0 - 0.9999_f64).ln() / p_no_outlier.ln()).ceil();
                    if needed.is_finite() && needed >= 0.0 {
                        iterations = iterations.min((needed as usize).max(iter + 1));
                    }
                }
            }
        }
    }

    if best_inliers.len() < config.min_inliers {
        return None;
    }

    // Refit on all inliers (least squares) for the final, precise model.
    let inlier_pairs: Vec<Correspondence> =
        best_inliers.iter().map(|&i| correspondences[i]).collect();
    let refined = fit_model(&inlier_pairs, config.transform_kind)?;

    Some(FittedTransform { model: refined })
}

fn draw_sample(n: usize, k: usize, rng: &mut Rng) -> Option<Vec<usize>> {
    if n < k {
        return None;
    }
    let mut chosen = Vec::with_capacity(k);
    let mut attempts = 0;
    while chosen.len() < k {
        let idx = (rng.next_u64() % n as u64) as usize;
        if !chosen.contains(&idx) {
            chosen.push(idx);
        }
        attempts += 1;
        if attempts > k * 20 {
            return None;
        }
    }
    Some(chosen)
}

fn inliers_for(
    correspondences: &[Correspondence],
    model: &TransformModel,
    threshold_sq: f64,
) -> Vec<usize> {
    correspondences
        .iter()
        .enumerate()
        .filter_map(|(i, c)| {
            let (mx, my) = model.apply(c.frame.0, c.frame.1);
            if !mx.is_finite() || !my.is_finite() {
                return None;
            }
            let d2 = (mx - c.reference.0).powi(2) + (my - c.reference.1).powi(2);
            if d2 <= threshold_sq {
                Some(i)
            } else {
                None
            }
        })
        .collect()
}

// Model fitting (least squares)

/// Fit the requested model from `>= min` correspondences (source → reference).
fn fit_model(pairs: &[Correspondence], kind: TransformKind) -> Option<TransformModel> {
    if pairs.len() < min_correspondences(kind) {
        return None;
    }
    match kind {
        TransformKind::Similarity => fit_similarity(pairs),
        TransformKind::Affine => fit_affine(pairs),
        TransformKind::Homography => fit_homography(pairs),
    }
}

/// Closed-form least-squares similarity (scale·rotation + translation, with
/// optional reflection) via the Umeyama / complex-number formulation.
///
/// We solve for `a, b, tx, ty` such that
/// `x' = a·x - b·y + tx`, `y' = b·x + a·y + ty`
/// minimising the squared residual. `(a, b)` encode `scale·(cosθ, sinθ)`. To
/// also admit a reflected solution we fit a second model with `y` negated in
/// the rotation block and keep whichever has the lower residual — astrophoto
/// frames can be mirrored (e.g. through a diagonal / meridian flip).
fn fit_similarity(pairs: &[Correspondence]) -> Option<TransformModel> {
    let proper = fit_similarity_signed(pairs, false)?;
    let reflected = fit_similarity_signed(pairs, true);

    match reflected {
        Some(refl) => {
            if model_residual(pairs, &refl) < model_residual(pairs, &proper) {
                Some(refl)
            } else {
                Some(proper)
            }
        }
        None => Some(proper),
    }
}

/// Least-squares similarity with a fixed chirality.
///
/// `reflect = false` fits a proper rotation; `reflect = true` fits the
/// orientation-reversing variant `x' = a·x + b·y + tx`, `y' = b·x - a·y + ty`.
fn fit_similarity_signed(pairs: &[Correspondence], reflect: bool) -> Option<TransformModel> {
    let n = pairs.len() as f64;

    // Centroids.
    let (mut sx, mut sy, mut sxp, mut syp) = (0.0, 0.0, 0.0, 0.0);
    for c in pairs {
        sx += c.frame.0;
        sy += c.frame.1;
        sxp += c.reference.0;
        syp += c.reference.1;
    }
    let (cx, cy) = (sx / n, sy / n);
    let (cxp, cyp) = (sxp / n, syp / n);

    // Centred cross terms.
    let (mut sxx, mut sxy, mut syx_, mut syy, mut s_norm) = (0.0, 0.0, 0.0, 0.0, 0.0);
    for c in pairs {
        let x = c.frame.0 - cx;
        let y = c.frame.1 - cy;
        let xp = c.reference.0 - cxp;
        let yp = c.reference.1 - cyp;
        sxx += x * xp;
        sxy += x * yp;
        syx_ += y * xp;
        syy += y * yp;
        s_norm += x * x + y * y;
    }

    if s_norm < f64::EPSILON {
        return None;
    }

    // For a proper rotation: a = (Σ x·x' + y·y') / Σ(x²+y²),
    //                        b = (Σ x·y' - y·x') / Σ(x²+y²).
    // For the reflected variant, flip the y-related signs accordingly.
    let (a, b) = if !reflect {
        ((sxx + syy) / s_norm, (sxy - syx_) / s_norm)
    } else {
        ((sxx - syy) / s_norm, (sxy + syx_) / s_norm)
    };

    let matrix = if !reflect {
        // [ a -b tx ]
        // [ b  a ty ]
        let tx = cxp - (a * cx - b * cy);
        let ty = cyp - (b * cx + a * cy);
        [[a, -b, tx], [b, a, ty], [0.0, 0.0, 1.0]]
    } else {
        // [ a  b tx ]
        // [ b -a ty ]
        let tx = cxp - (a * cx + b * cy);
        let ty = cyp - (b * cx - a * cy);
        [[a, b, tx], [b, -a, ty], [0.0, 0.0, 1.0]]
    };

    Some(TransformModel {
        matrix,
        kind: TransformKind::Similarity,
    })
}

/// Least-squares affine fit (6 DoF) via the normal equations.
///
/// We solve the two independent 3-parameter systems for `(x', y')` from
/// `[x y 1]`. The normal matrix is the same 3×3 `AᵀA` for both rows; we invert
/// it once and apply it to both right-hand sides.
fn fit_affine(pairs: &[Correspondence]) -> Option<TransformModel> {
    // Accumulate AᵀA (symmetric 3×3) and Aᵀb for both target components.
    let mut ata = [[0.0f64; 3]; 3];
    let mut atx = [0.0f64; 3]; // for x'
    let mut aty = [0.0f64; 3]; // for y'

    for c in pairs {
        let row = [c.frame.0, c.frame.1, 1.0];
        for r in 0..3 {
            for col in 0..3 {
                ata[r][col] += row[r] * row[col];
            }
            atx[r] += row[r] * c.reference.0;
            aty[r] += row[r] * c.reference.1;
        }
    }

    let inv = invert_3x3(&ata)?;
    let px = mat3_vec3(&inv, &atx);
    let py = mat3_vec3(&inv, &aty);

    Some(TransformModel {
        matrix: [
            [px[0], px[1], px[2]],
            [py[0], py[1], py[2]],
            [0.0, 0.0, 1.0],
        ],
        kind: TransformKind::Affine,
    })
}

/// Least-squares homography (8 DoF) via the DLT algorithm.
///
/// For each correspondence `(x, y) -> (x', y')` we get two linear equations in
/// the 8 unknown homography parameters (fixing `h33 = 1`). We stack them into a
/// `2N × 8` system and solve the normal equations `AᵀA h = Aᵀb` with an 8×8
/// Gaussian elimination.
fn fit_homography(pairs: &[Correspondence]) -> Option<TransformModel> {
    let mut ata = [[0.0f64; 8]; 8];
    let mut atb = [0.0f64; 8];

    let mut accumulate = |coef: &[f64; 8], rhs: f64| {
        for r in 0..8 {
            for col in 0..8 {
                ata[r][col] += coef[r] * coef[col];
            }
            atb[r] += coef[r] * rhs;
        }
    };

    for c in pairs {
        let (x, y) = c.frame;
        let (xp, yp) = c.reference;

        // x' = (h0 x + h1 y + h2) / (h6 x + h7 y + 1)
        //   => h0 x + h1 y + h2 - h6 x x' - h7 y x' = x'
        let row_x = [x, y, 1.0, 0.0, 0.0, 0.0, -x * xp, -y * xp];
        accumulate(&row_x, xp);

        // y' = (h3 x + h4 y + h5) / (h6 x + h7 y + 1)
        //   => h3 x + h4 y + h5 - h6 x y' - h7 y y' = y'
        let row_y = [0.0, 0.0, 0.0, x, y, 1.0, -x * yp, -y * yp];
        accumulate(&row_y, yp);
    }

    let h = solve_linear_system(&mut ata, &mut atb)?;

    Some(TransformModel {
        matrix: [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1.0]],
        kind: TransformKind::Homography,
    })
}

fn model_residual(pairs: &[Correspondence], model: &TransformModel) -> f64 {
    let residuals: Vec<f64> = pairs
        .iter()
        .map(|c| {
            let (mx, my) = model.apply(c.frame.0, c.frame.1);
            ((mx - c.reference.0).powi(2) + (my - c.reference.1).powi(2)).sqrt()
        })
        .collect();
    rms(&residuals)
}

// Resampling (warp source onto reference grid)

/// Warp `frame` onto the `reference` grid using `model` (source → reference)
/// and `interp`. Output matches the reference dimensions/channels/pixel type.
/// Reference pixels whose inverse-mapped source location falls outside the
/// source frame are zero-filled.
fn warp_frame(
    frame: &ImageData,
    reference: &ImageData,
    model: &TransformModel,
    interp: Interpolator,
) -> ImageData {
    let out_w = reference.width as usize;
    let out_h = reference.height as usize;
    let channels = frame.channels as usize;
    let src_w = frame.width as usize;
    let src_h = frame.height as usize;

    let inverse = match model.inverse() {
        Some(inv) => inv,
        // A non-invertible transform should never reach here (RANSAC rejects
        // collapsed scales), but if it does, return a black aligned frame
        // rather than panic.
        None => {
            return ImageData::new(
                reference.width,
                reference.height,
                frame.channels,
                PixelType::U16,
            )
        }
    };

    let src: Vec<f64> = frame
        .data
        .par_chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]) as f64)
        .collect();

    let stride = src_w * channels;

    let out_pixels: Vec<u16> = (0..out_h)
        .into_par_iter()
        .flat_map(|y| {
            let mut row = vec![0u16; out_w * channels];
            for x in 0..out_w {
                let (sx, sy) = inverse.apply(x as f64, y as f64);
                if !sx.is_finite() || !sy.is_finite() {
                    continue;
                }
                for c in 0..channels {
                    let v = sample(&src, src_w, src_h, channels, stride, c, sx, sy, interp);
                    row[x * channels + c] = v.round().clamp(0.0, 65535.0) as u16;
                }
            }
            row
        })
        .collect();

    ImageData::from_u16(
        reference.width,
        reference.height,
        frame.channels,
        &out_pixels,
    )
}

/// Sample channel `c` at fractional source position `(sx, sy)` with `interp`.
/// Returns 0.0 when the support window leaves the image (no edge replication,
/// to avoid smearing the frame border into the stack).
#[allow(clippy::too_many_arguments)]
fn sample(
    src: &[f64],
    src_w: usize,
    src_h: usize,
    channels: usize,
    stride: usize,
    c: usize,
    sx: f64,
    sy: f64,
    interp: Interpolator,
) -> f64 {
    let px = |ix: i64, iy: i64| -> f64 {
        if ix < 0 || iy < 0 || ix as usize >= src_w || iy as usize >= src_h {
            0.0
        } else {
            src[iy as usize * stride + ix as usize * channels + c]
        }
    };

    match interp {
        Interpolator::Bilinear => {
            let x0 = sx.floor();
            let y0 = sy.floor();
            let ix = x0 as i64;
            let iy = y0 as i64;
            if ix < 0 || iy < 0 || (ix + 1) as usize >= src_w || (iy + 1) as usize >= src_h {
                return 0.0;
            }
            let dx = sx - x0;
            let dy = sy - y0;
            let p00 = px(ix, iy);
            let p10 = px(ix + 1, iy);
            let p01 = px(ix, iy + 1);
            let p11 = px(ix + 1, iy + 1);
            (1.0 - dx) * (1.0 - dy) * p00
                + dx * (1.0 - dy) * p10
                + (1.0 - dx) * dy * p01
                + dx * dy * p11
        }
        Interpolator::CatmullRom => separable_sample(&px, sx, sy, 2, catmull_rom),
        Interpolator::Lanczos3 => separable_sample(&px, sx, sy, 3, lanczos3),
    }
}

/// Sample channel `c` of a channel-interleaved `f64` plane at fractional source
/// position `(sx, sy)` with `interp`, returning `0.0` when the kernel support
/// leaves the image (no edge replication — identical semantics to the private
/// warp sampler).
///
/// This is the public entry point the WCS-driven reprojectors
/// ([`crate::mosaic_stitch`], [`crate::sky_atlas`]) share so they resample with
/// exactly the same Lanczos-3 / Catmull-Rom / bilinear kernels the registration
/// warp uses, rather than re-deriving them. `data` is interleaved
/// (`data[y·stride + x·channels + c]`) with `stride == width·channels`.
#[allow(clippy::too_many_arguments)]
pub fn sample_interleaved(
    data: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    channel: usize,
    sx: f64,
    sy: f64,
    interp: Interpolator,
) -> f64 {
    let stride = width * channels;
    sample(
        data, width, height, channels, stride, channel, sx, sy, interp,
    )
}

/// Separable interpolation with a 1-D kernel of half-width `radius` (taps span
/// `[-radius+1, radius]` around the floor). Used for both Catmull-Rom (radius 2)
/// and Lanczos-3 (radius 3).
fn separable_sample<F, K>(px: &F, sx: f64, sy: f64, radius: i64, kernel: K) -> f64
where
    F: Fn(i64, i64) -> f64,
    K: Fn(f64) -> f64,
{
    let x0 = sx.floor() as i64;
    let y0 = sy.floor() as i64;
    let fx = sx - x0 as f64;
    let fy = sy - y0 as f64;

    // Precompute horizontal and vertical weights.
    let mut wx = [0.0f64; 6];
    let mut wy = [0.0f64; 6];
    let taps = (2 * radius) as usize;
    let start = -(radius - 1);

    let mut sum_wx = 0.0;
    let mut sum_wy = 0.0;
    for t in 0..taps {
        let offset = start + t as i64;
        let kx = kernel(fx - offset as f64);
        let ky = kernel(fy - offset as f64);
        wx[t] = kx;
        wy[t] = ky;
        sum_wx += kx;
        sum_wy += ky;
    }

    // Normalise so the kernel sums to unity (preserves flat-field / flux level
    // even when the analytic kernel weights don't sum to exactly 1 at this
    // fractional offset).
    if sum_wx.abs() < f64::EPSILON || sum_wy.abs() < f64::EPSILON {
        return 0.0;
    }

    let mut acc = 0.0;
    for (ty, &w_y) in wy.iter().enumerate().take(taps) {
        let iy = y0 + start + ty as i64;
        let mut row_acc = 0.0;
        for (tx, &w_x) in wx.iter().enumerate().take(taps) {
            let ix = x0 + start + tx as i64;
            row_acc += w_x * px(ix, iy);
        }
        acc += w_y * row_acc;
    }

    acc / (sum_wx * sum_wy)
}

/// Catmull-Rom cubic kernel (a = -0.5). Interpolating, C¹, mild sharpening.
fn catmull_rom(x: f64) -> f64 {
    let a = -0.5;
    let x = x.abs();
    if x < 1.0 {
        (a + 2.0) * x.powi(3) - (a + 3.0) * x.powi(2) + 1.0
    } else if x < 2.0 {
        a * x.powi(3) - 5.0 * a * x.powi(2) + 8.0 * a * x - 4.0 * a
    } else {
        0.0
    }
}

/// Lanczos kernel with `a = 3` (windowed sinc).
fn lanczos3(x: f64) -> f64 {
    const A: f64 = 3.0;
    if x.abs() < f64::EPSILON {
        1.0
    } else if x.abs() < A {
        let px = std::f64::consts::PI * x;
        (A * px.sin() * (px / A).sin()) / (px * px)
    } else {
        0.0
    }
}

// Small linear-algebra helpers (no nalgebra dependency)

/// Invert a 3×3 matrix; `None` if singular.
fn invert_3x3(m: &[[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

    if det.abs() < 1e-12 {
        return None;
    }
    let inv_det = 1.0 / det;

    let mut inv = [[0.0f64; 3]; 3];
    inv[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * inv_det;
    inv[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv_det;
    inv[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv_det;
    inv[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * inv_det;
    inv[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv_det;
    inv[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv_det;
    inv[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * inv_det;
    inv[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv_det;
    inv[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv_det;
    Some(inv)
}

fn mat3_vec3(m: &[[f64; 3]; 3], v: &[f64; 3]) -> [f64; 3] {
    [
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    ]
}

/// Solve `A x = b` for an 8×8 system by Gaussian elimination with partial
/// pivoting. Mutates `a` and `b`. Returns `None` if the matrix is singular.
///
/// `needless_range_loop` is allowed here: this is textbook Gaussian
/// elimination where each inner loop reads the *pivot* row `a[col]` while
/// mutating row `a[r]`, and the outer loop swaps whole rows. Index arithmetic
/// is the clearest, and the borrow-checker-friendliest, way to express
/// simultaneous cross-row access; an `enumerate()` rewrite would obscure it.
#[allow(clippy::needless_range_loop)]
fn solve_linear_system(a: &mut [[f64; 8]; 8], b: &mut [f64; 8]) -> Option<[f64; 8]> {
    const N: usize = 8;
    for col in 0..N {
        // Partial pivot.
        let mut pivot = col;
        let mut max_abs = a[col][col].abs();
        for r in (col + 1)..N {
            if a[r][col].abs() > max_abs {
                max_abs = a[r][col].abs();
                pivot = r;
            }
        }
        if max_abs < 1e-12 {
            return None;
        }
        a.swap(col, pivot);
        b.swap(col, pivot);

        // Eliminate below.
        let pivot_val = a[col][col];
        for r in (col + 1)..N {
            let factor = a[r][col] / pivot_val;
            if factor != 0.0 {
                for c in col..N {
                    a[r][c] -= factor * a[col][c];
                }
                b[r] -= factor * b[col];
            }
        }
    }

    // Back-substitution.
    let mut x = [0.0f64; N];
    for i in (0..N).rev() {
        let mut sum = b[i];
        for j in (i + 1)..N {
            sum -= a[i][j] * x[j];
        }
        x[i] = sum / a[i][i];
    }
    Some(x)
}

fn rms(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = values.iter().map(|v| v * v).sum();
    (sum_sq / values.len() as f64).sqrt()
}

// Deterministic PRNG for RANSAC sampling

/// SplitMix64 — a tiny, fast, deterministic PRNG. We use a fixed seed so
/// registration is reproducible run-to-run (important for stack determinism and
/// for the tests below), while still giving RANSAC well-distributed samples.
struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    /// Render a synthetic star field: a U16 mono frame with Gaussian PSFs at the
    /// given sub-pixel positions over a flat background with a little noise.
    struct SyntheticField {
        width: u32,
        height: u32,
        stars: Vec<(f64, f64, f64)>, // x, y, peak flux above background
        background: f64,
        sigma: f64,
        /// Peak-to-peak sky noise amplitude in ADU. Kept small (a few ADU) so
        /// the detector's aperture statistics stay tight around the PSFs; set to
        /// 0 for a perfectly flat sky.
        noise_amp: f64,
    }

    impl SyntheticField {
        fn render(&self) -> ImageData {
            let w = self.width as usize;
            let h = self.height as usize;
            let mut pixels = vec![0f64; w * h];

            // Flat background plus zero-mean deterministic noise so the star
            // detector's per-pixel SNR / sharpness statistics behave as on real
            // data (a constant background would make every above-threshold
            // pixel part of a "star"). Centred on zero so background-subtracted
            // sky pixels are negative as often as positive — this keeps the
            // detector's aperture pixel_count tight around the actual PSFs.
            for (i, p) in pixels.iter_mut().enumerate() {
                let n = ((i.wrapping_mul(2654435761) >> 8) % 1000) as f64 / 1000.0; // [0,1)
                *p = self.background + (n - 0.5) * self.noise_amp;
            }

            let two_sigma_sq = 2.0 * self.sigma * self.sigma;
            let radius = (self.sigma * 4.0).ceil() as i64;
            for &(sx, sy, peak) in &self.stars {
                let cx = sx.round() as i64;
                let cy = sy.round() as i64;
                for dy in -radius..=radius {
                    for dx in -radius..=radius {
                        let x = cx + dx;
                        let y = cy + dy;
                        if x < 0 || y < 0 || x as usize >= w || y as usize >= h {
                            continue;
                        }
                        let ddx = x as f64 - sx;
                        let ddy = y as f64 - sy;
                        let g = peak * (-(ddx * ddx + ddy * ddy) / two_sigma_sq).exp();
                        let idx = y as usize * w + x as usize;
                        pixels[idx] += g;
                    }
                }
            }

            let u16data: Vec<u16> = pixels
                .iter()
                .map(|v| v.round().clamp(0.0, 65535.0) as u16)
                .collect();
            ImageData::from_u16(self.width, self.height, 1, &u16data)
        }
    }

    /// Deterministic well-separated star layout for a `size`×`size` frame.
    fn base_stars(size: f64) -> Vec<(f64, f64, f64)> {
        // A spread of bright stars at irregular (non-symmetric) positions so the
        // triangle descriptors are distinctive.
        vec![
            (size * 0.18, size * 0.22, 9000.0),
            (size * 0.72, size * 0.16, 12000.0),
            (size * 0.40, size * 0.55, 15000.0),
            (size * 0.83, size * 0.61, 8000.0),
            (size * 0.27, size * 0.78, 11000.0),
            (size * 0.61, size * 0.84, 10000.0),
            (size * 0.52, size * 0.33, 13000.0),
            (size * 0.12, size * 0.62, 9500.0),
            (size * 0.90, size * 0.40, 7000.0),
            (size * 0.35, size * 0.12, 8500.0),
        ]
    }

    /// Apply a similarity transform (scale, rotation about centre, translation)
    /// to a set of star positions, mapping reference -> frame coordinates.
    fn transform_stars(
        stars: &[(f64, f64, f64)],
        scale: f64,
        theta: f64,
        tx: f64,
        ty: f64,
        size: f64,
    ) -> Vec<(f64, f64, f64)> {
        let (cos, sin) = (theta.cos(), theta.sin());
        let cc = size / 2.0;
        stars
            .iter()
            .map(|&(x, y, flux)| {
                let rx = x - cc;
                let ry = y - cc;
                let nx = scale * (cos * rx - sin * ry) + cc + tx;
                let ny = scale * (sin * rx + cos * ry) + cc + ty;
                (nx, ny, flux)
            })
            .collect()
    }

    fn config() -> RegistrationConfig {
        // The synthetic PSFs are clean, noise-free Gaussians. The production
        // `StarDetectionConfig::default()` is deliberately tuned for *real* CCD
        // frames — its `max_sharpness`/`min_area`/SNR floors reject idealised
        // single-peak Gaussians (the same default detects zero stars on the
        // crate's own `generate_simulated_image`). For the registration
        // *algorithm* tests we relax the detector's hot-pixel/quality
        // heuristics; the geometry/transform/resampling code under test is
        // independent of those thresholds.
        let sd = StarDetectionConfig {
            detection_sigma: 3.0,
            min_area: 1,
            max_area: 1_000_000,
            max_eccentricity: 1.0,
            saturation_limit: 65535,
            hfr_radius: 12,
            min_hfr: 0.5,
            min_snr: 3.0,
            max_sharpness: 1.0,
            noise_model: None,
        };
        RegistrationConfig {
            star_detection: sd,
            ..Default::default()
        }
    }

    #[test]
    fn recovers_pure_translation() {
        let size = 256.0;
        let ref_stars = base_stars(size);
        let frame_stars = transform_stars(&ref_stars, 1.0, 0.0, 11.0, -7.0, size);

        let reference = SyntheticField {
            width: 256,
            height: 256,
            stars: ref_stars,
            background: 600.0,
            sigma: 1.6,
            noise_amp: 5.0,
        }
        .render();
        let frame = SyntheticField {
            width: 256,
            height: 256,
            stars: frame_stars,
            background: 600.0,
            sigma: 1.6,
            noise_amp: 5.0,
        }
        .render();

        let result = register_frame(&reference, &frame, &config()).expect("registration");

        // The fitted transform maps frame -> reference, so it should undo the
        // (+11, -7) shift we applied to the frame: tx ≈ -11, ty ≈ +7.
        assert!(
            result.stats.rms_residual_px < 0.1,
            "RMS residual {} px should be < 0.1",
            result.stats.rms_residual_px
        );
        assert!(result.stats.inlier_count >= 8);

        let (mx, my) = result.transform.apply(size / 2.0 + 11.0, size / 2.0 - 7.0);
        assert!((mx - size / 2.0).abs() < 0.2, "x mapped to {mx}");
        assert!((my - size / 2.0).abs() < 0.2, "y mapped to {my}");
    }

    #[test]
    fn recovers_translation_and_rotation() {
        let size = 320.0;
        let theta = 12.0_f64.to_radians();
        let ref_stars = base_stars(size);
        let frame_stars = transform_stars(&ref_stars, 1.0, theta, 6.0, 9.0, size);

        let reference = SyntheticField {
            width: 320,
            height: 320,
            stars: ref_stars.clone(),
            background: 700.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();
        let frame = SyntheticField {
            width: 320,
            height: 320,
            stars: frame_stars,
            background: 700.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();

        let result = register_frame(&reference, &frame, &config()).expect("registration");

        assert!(
            result.stats.rms_residual_px < 0.1,
            "RMS residual {} px should be < 0.1",
            result.stats.rms_residual_px
        );

        // Spot-check the recovered transform against the known mapping by round
        // tripping every reference star through forward(ref->frame model is the
        // inverse)/ we instead verify frame->ref maps each frame star to its ref.
        for (i, &(rx, ry, _)) in ref_stars.iter().enumerate() {
            let fs = transform_stars(&ref_stars, 1.0, theta, 6.0, 9.0, size)[i];
            let (mx, my) = result.transform.apply(fs.0, fs.1);
            assert!(
                (mx - rx).abs() < 0.3 && (my - ry).abs() < 0.3,
                "star {i} mapped to ({mx},{my}) expected ({rx},{ry})"
            );
        }
    }

    #[test]
    fn recovers_translation_rotation_and_scale_with_affine() {
        let size = 360.0;
        let theta = 8.0_f64.to_radians();
        let scale = 1.05;
        let ref_stars = base_stars(size);
        let frame_stars = transform_stars(&ref_stars, scale, theta, -10.0, 5.0, size);

        let reference = SyntheticField {
            width: 360,
            height: 360,
            stars: ref_stars,
            background: 650.0,
            sigma: 1.8,
            noise_amp: 5.0,
        }
        .render();
        let frame = SyntheticField {
            width: 360,
            height: 360,
            stars: frame_stars,
            background: 650.0,
            sigma: 1.8,
            noise_amp: 5.0,
        }
        .render();

        let mut cfg = config();
        cfg.transform_kind = TransformKind::Affine;
        // Loosen descriptor tolerance slightly for the scaled case.
        cfg.descriptor_tolerance = 0.006;

        let result = register_frame(&reference, &frame, &cfg).expect("registration");

        assert!(
            result.stats.rms_residual_px < 0.15,
            "RMS residual {} px should be < 0.15",
            result.stats.rms_residual_px
        );
        // The recovered transform's scale should undo the 1.05 we applied:
        // frame->ref scale ≈ 1/1.05 ≈ 0.952.
        let s = result.transform.scale();
        assert!(
            (s - 1.0 / scale).abs() < 0.02,
            "recovered scale {s} expected ~{}",
            1.0 / scale
        );
    }

    #[test]
    fn matching_survives_thirty_percent_spurious_stars() {
        let size = 320.0;
        let theta = 6.0_f64.to_radians();
        let true_ref = base_stars(size);
        let true_frame = transform_stars(&true_ref, 1.0, theta, 8.0, -4.0, size);

        // Add ~30% spurious stars to BOTH frames at unrelated positions so they
        // form no congruent triangles with the real set.
        let spurious_ref = vec![
            (size * 0.05, size * 0.95, 6000.0),
            (size * 0.95, size * 0.05, 6500.0),
            (size * 0.48, size * 0.97, 7000.0),
            (size * 0.66, size * 0.45, 5500.0),
        ];
        let spurious_frame = vec![
            (size * 0.30, size * 0.04, 6200.0),
            (size * 0.97, size * 0.70, 6800.0),
            (size * 0.02, size * 0.30, 7200.0),
            (size * 0.55, size * 0.06, 5800.0),
        ];

        let mut ref_all = true_ref.clone();
        ref_all.extend(spurious_ref);
        let mut frame_all = true_frame;
        frame_all.extend(spurious_frame);

        let reference = SyntheticField {
            width: 320,
            height: 320,
            stars: ref_all,
            background: 680.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();
        let frame = SyntheticField {
            width: 320,
            height: 320,
            stars: frame_all,
            background: 680.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();

        let result = register_frame(&reference, &frame, &config()).expect("registration");

        assert!(
            result.stats.rms_residual_px < 0.2,
            "RMS residual {} px should be < 0.2 despite spurious stars",
            result.stats.rms_residual_px
        );
        // The 10 true stars should dominate the inlier set.
        assert!(
            result.stats.inlier_count >= 8,
            "expected >= 8 inliers, got {}",
            result.stats.inlier_count
        );
        // Verify the recovered transform on a true correspondence.
        let fs = transform_stars(&true_ref, 1.0, theta, 8.0, -4.0, size)[2];
        let (mx, my) = result.transform.apply(fs.0, fs.1);
        assert!((mx - true_ref[2].0).abs() < 0.4 && (my - true_ref[2].1).abs() < 0.4);
    }

    #[test]
    fn resampling_preserves_flux() {
        // A single bright Gaussian star; after a pure-translation warp its total
        // integrated flux above background must be preserved to within ~1%.
        let size = 128u32;
        let star = (64.3, 63.7, 20000.0);
        let background = 500.0;
        let reference = SyntheticField {
            width: size,
            height: size,
            stars: vec![star],
            background,
            sigma: 2.0,
            noise_amp: 5.0,
        }
        .render();

        // Frame = reference shifted by a non-integer amount so interpolation is
        // genuinely exercised.
        let shifted = (star.0 + 5.5, star.1 - 3.25, star.2);
        let frame = SyntheticField {
            width: size,
            height: size,
            stars: vec![shifted],
            background,
            sigma: 2.0,
            noise_amp: 5.0,
        }
        .render();

        // Known translation transform (frame -> reference) undoing the shift.
        let model = TransformModel {
            matrix: [[1.0, 0.0, -5.5], [0.0, 1.0, 3.25], [0.0, 0.0, 1.0]],
            kind: TransformKind::Similarity,
        };

        let integrate = |img: &ImageData| -> f64 {
            img.as_u16()
                .unwrap()
                .iter()
                .map(|&v| (v as f64 - background).max(0.0))
                .sum()
        };

        let ref_flux = integrate(&reference);

        for interp in [
            Interpolator::Bilinear,
            Interpolator::CatmullRom,
            Interpolator::Lanczos3,
        ] {
            let aligned = warp_frame(&frame, &reference, &model, interp);
            let flux = integrate(&aligned);
            let rel = (flux - ref_flux).abs() / ref_flux;
            assert!(
                rel < 0.03,
                "{interp:?}: flux drift {rel:.4} (aligned {flux} vs ref {ref_flux}) exceeds 3%"
            );
        }
    }

    #[test]
    fn too_few_stars_fails_closed() {
        let reference = SyntheticField {
            width: 64,
            height: 64,
            stars: vec![(20.0, 20.0, 9000.0)],
            background: 500.0,
            sigma: 1.6,
            noise_amp: 5.0,
        }
        .render();
        let frame = reference.clone();

        let err = register_frame(&reference, &frame, &config()).unwrap_err();
        assert!(matches!(err, RegistrationError::TooFewStars { .. }));
    }

    #[test]
    fn rejects_pixel_type_mismatch() {
        let reference = ImageData::from_u16(8, 8, 1, &[0u16; 64]);
        let frame = ImageData::from_f32(8, 8, 1, &[0f32; 64]);
        let err = register_frame(&reference, &frame, &config()).unwrap_err();
        assert_eq!(
            err,
            RegistrationError::UnsupportedFramePixelType(PixelType::F32)
        );
    }

    #[test]
    fn identity_transform_round_trips() {
        let id = TransformModel::identity();
        let (x, y) = id.apply(12.5, -3.0);
        assert!((x - 12.5).abs() < 1e-12 && (y + 3.0).abs() < 1e-12);
        let inv = id.inverse().unwrap();
        let (x, y) = inv.apply(12.5, -3.0);
        assert!((x - 12.5).abs() < 1e-12 && (y + 3.0).abs() < 1e-12);
    }

    #[test]
    fn homography_fit_is_exact_for_synthetic_projective_points() {
        // Build a known homography and verify the DLT solver recovers it.
        let h = TransformModel {
            matrix: [
                [1.02, 0.01, 5.0],
                [-0.015, 0.99, -3.0],
                [0.0001, -0.00005, 1.0],
            ],
            kind: TransformKind::Homography,
        };
        let src = [
            (10.0, 20.0),
            (200.0, 30.0),
            (50.0, 180.0),
            (220.0, 210.0),
            (120.0, 90.0),
            (75.0, 150.0),
        ];
        let pairs: Vec<Correspondence> = src
            .iter()
            .map(|&(x, y)| {
                let (xp, yp) = h.apply(x, y);
                Correspondence {
                    frame: (x, y),
                    reference: (xp, yp),
                }
            })
            .collect();

        let fit = fit_homography(&pairs).expect("homography fit");
        for &(x, y) in &src {
            let (ex, ey) = h.apply(x, y);
            let (ax, ay) = fit.apply(x, y);
            assert!(
                (ex - ax).abs() < 1e-4 && (ey - ay).abs() < 1e-4,
                "homography mismatch at ({x},{y}): expected ({ex},{ey}) got ({ax},{ay})"
            );
        }
    }

    #[test]
    fn lanczos_kernel_partition_of_unity_at_integer_offsets() {
        // At an exact integer sample location, Lanczos must return the sample
        // itself: kernel(0) = 1, kernel(non-zero integer) = 0.
        assert!((lanczos3(0.0) - 1.0).abs() < 1e-12);
        for k in 1..=3 {
            assert!(lanczos3(k as f64).abs() < 1e-9, "lanczos3({k}) not ~0");
        }
        assert!(lanczos3(3.5).abs() < 1e-12);
    }

    #[test]
    fn full_rotation_ninety_degrees_recovered() {
        // A large 90° rotation is well outside the rigid path's small-angle
        // regime; the geometric matcher must still lock on.
        let size = 300.0;
        let theta = PI / 2.0;
        let ref_stars = base_stars(size);
        let frame_stars = transform_stars(&ref_stars, 1.0, theta, 0.0, 0.0, size);

        let reference = SyntheticField {
            width: 300,
            height: 300,
            stars: ref_stars.clone(),
            background: 620.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();
        let frame = SyntheticField {
            width: 300,
            height: 300,
            stars: frame_stars,
            background: 620.0,
            sigma: 1.7,
            noise_amp: 5.0,
        }
        .render();

        let result = register_frame(&reference, &frame, &config()).expect("registration");
        assert!(
            result.stats.rms_residual_px < 0.15,
            "RMS residual {} px should be < 0.15 for 90° rotation",
            result.stats.rms_residual_px
        );
    }
}
