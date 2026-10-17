//! SIP-aware gnomonic (TAN) astrometry for one frame.
//!
//! # Why this module exists
//!
//! [`crate::mosaic_stitch::WcsProjection`] gives an exact gnomonic forward /
//! inverse projection from a bare CD matrix, but it is **CD-only**: it cannot
//! represent the polynomial focal-plane distortion the plate solver measures and
//! records as SIP (`A`/`B` forward, `AP`/`BP` inverse). At the >1° fields most
//! amateur astrographs work at, that distortion is several pixels at the corners
//! — far more than the sub-pixel accuracy the sky atlas needs to fold many
//! nights of frames onto one shared grid without smearing stars.
//!
//! [`SipWcs`] is the generalisation: CD **plus** full forward and inverse SIP,
//! ported from the Dart reference (`gnomonic_projection.dart`). It is the single
//! projection both the mosaic stitcher and the [`crate::sky_atlas`] reproject the
//! sky through. The CD-only path is recovered exactly by leaving the SIP orders
//! at zero (or via [`SipWcs::tan_only`]), so existing CD-only callers behave
//! identically.
//!
//! # The FITS SIP pipeline (Shupe et al. 2005)
//!
//! With 0-based pixels and a 0-based reference pixel `(crpix1-1, crpix2-1)`:
//!
//! ```text
//!   forward (pixel -> world):
//!     u = x - crpix1_0,  v = y - crpix2_0
//!     u' = u + Σ A_ij u^i v^j        (A_0_0 = A_1_0 = A_0_1 = 0 by convention)
//!     v' = v + Σ B_ij u^i v^j
//!     (ξ, η) = CD · (u', v')         intermediate world coords, degrees
//!     (ξ, η) --TAN deproject--> (ra, dec)
//!
//!   inverse (world -> pixel):
//!     (ra, dec) --TAN project--> (ξ, η)
//!     (U, V) = CD^-1 · (ξ, η)
//!     x = crpix1_0 + U + Σ AP_ij U^i V^j   (AP/BP present)
//!     y = crpix2_0 + V + Σ BP_ij U^i V^j
//!     -- or, when AP/BP are absent, Newton-iterate the forward A/B polynomials
//!        to recover (u, v) from (U, V), exactly as the Dart reference does.
//! ```
//!
//! Coefficients are packed **row-major**: the term `(i, j)` lives at index
//! `i * (order + 1) + j`, matching [`crate::platesolve::PlateSolveResult`] and
//! `gnomonic_projection.dart`. All trig is in radians; the public interface is
//! degrees in / degrees out and **0-based** pixels (matching the resampler and
//! [`crate::ImageData`] indexing).

use serde::{Deserialize, Serialize};

/// Number of Newton iterations used to invert the forward SIP polynomials when
/// no `AP`/`BP` inverse coefficients are present. The Dart reference uses 8; the
/// fixed-point map converges geometrically for the small (sub-pixel-per-pixel)
/// distortions real solvers produce, so 8 reaches f64 round-off in practice.
const SIP_NEWTON_ITERS: usize = 8;

/// CD + full SIP astrometry for one frame, ported from `gnomonic_projection.dart`.
///
/// Field names are the wire contract (camelCase via serde rename) shared with the
/// bridge JSON and the Dart `SolvedWcs`; do not rename. The CD-only behaviour is
/// recovered by leaving every SIP order at `0`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SipWcs {
    /// Reference RA (deg, CRVAL1).
    pub crval1: f64,
    /// Reference Dec (deg, CRVAL2).
    pub crval2: f64,
    /// 1-based reference pixel x (FITS CRPIX1 convention).
    pub crpix1: f64,
    /// 1-based reference pixel y (FITS CRPIX2 convention).
    pub crpix2: f64,
    #[serde(rename = "cd1_1")]
    pub cd1_1: f64,
    #[serde(rename = "cd1_2")]
    pub cd1_2: f64,
    #[serde(rename = "cd2_1")]
    pub cd2_1: f64,
    #[serde(rename = "cd2_2")]
    pub cd2_2: f64,
    /// Forward SIP order for the `A` polynomial; `0` = no forward distortion.
    #[serde(rename = "aOrder")]
    pub a_order: u32,
    /// Forward SIP order for the `B` polynomial.
    #[serde(rename = "bOrder")]
    pub b_order: u32,
    /// Forward `A` coefficients, row-major `i*(order+1)+j`.
    #[serde(rename = "aCoeffs")]
    pub a_coeffs: Vec<f64>,
    /// Forward `B` coefficients, row-major.
    #[serde(rename = "bCoeffs")]
    pub b_coeffs: Vec<f64>,
    /// Inverse SIP order for `AP`; `0` (or empty coeffs) -> Newton fallback.
    #[serde(rename = "apOrder")]
    pub ap_order: u32,
    /// Inverse SIP order for `BP`.
    #[serde(rename = "bpOrder")]
    pub bp_order: u32,
    /// Inverse `AP` coefficients, row-major; empty -> Newton fallback.
    #[serde(rename = "apCoeffs")]
    pub ap_coeffs: Vec<f64>,
    /// Inverse `BP` coefficients, row-major.
    #[serde(rename = "bpCoeffs")]
    pub bp_coeffs: Vec<f64>,
}

impl SipWcs {
    /// Build from the plate solver's result. The CD matrix and every SIP
    /// coefficient list carry straight over (same row-major packing); the
    /// reference pixel is the image centre, matching
    /// [`crate::WcsInfo::from_plate_solve`]. Returns `None` if the solve failed
    /// or the CD matrix is degenerate (so the caller never folds a frame whose
    /// astrometry cannot be inverted).
    pub fn from_plate_solve(r: &crate::platesolve::PlateSolveResult) -> Option<Self> {
        if !r.success {
            return None;
        }
        // The solver records the CD matrix directly; if it is zero (no WCS was
        // parsed) reconstruct the isotropic CD from ra/dec/scale/rotation exactly
        // as `WcsInfo::from_plate_solve` does, so a solve with only scalar
        // astrometry still yields a usable (CD-only) projection.
        let (cd1_1, cd1_2, cd2_1, cd2_2) =
            if r.cd1_1 == 0.0 && r.cd1_2 == 0.0 && r.cd2_1 == 0.0 && r.cd2_2 == 0.0 {
                let scale_deg = r.pixel_scale / 3600.0;
                let rot = r.rotation.to_radians();
                let (c, s) = (rot.cos(), rot.sin());
                (-scale_deg * c, scale_deg * s, scale_deg * s, scale_deg * c)
            } else {
                (r.cd1_1, r.cd1_2, r.cd2_1, r.cd2_2)
            };
        // CRPIX is the image centre. `field_width / pixel_scale` recovers the
        // pixel width from the solved field; fall back to a finite guard so a
        // bogus solve produces `None` rather than a NaN reference pixel.
        let scale_arcsec = r.pixel_scale;
        let (crpix1, crpix2) = if scale_arcsec.is_finite() && scale_arcsec > 0.0 {
            let w = (r.field_width * 3600.0 / scale_arcsec).round();
            let h = (r.field_height * 3600.0 / scale_arcsec).round();
            (w / 2.0, h / 2.0)
        } else {
            // No usable scale -> a CRPIX of zero is wrong; refuse rather than lie.
            return None;
        };
        let candidate = Self {
            crval1: r.ra,
            crval2: r.dec,
            crpix1: crpix1 + 0.5,
            crpix2: crpix2 + 0.5,
            cd1_1,
            cd1_2,
            cd2_1,
            cd2_2,
            a_order: r.a_order,
            b_order: r.b_order,
            a_coeffs: r.a_coeffs.clone(),
            b_coeffs: r.b_coeffs.clone(),
            ap_order: r.ap_order,
            bp_order: r.bp_order,
            ap_coeffs: r.ap_coeffs.clone(),
            bp_coeffs: r.bp_coeffs.clone(),
        };
        if candidate.is_invertible() {
            Some(candidate)
        } else {
            None
        }
    }

    /// CD-only (no distortion) astrometry — the canonical grid for atlas tiles.
    #[allow(clippy::too_many_arguments)]
    pub fn tan_only(
        crval1: f64,
        crval2: f64,
        crpix1: f64,
        crpix2: f64,
        cd1_1: f64,
        cd1_2: f64,
        cd2_1: f64,
        cd2_2: f64,
    ) -> Self {
        Self {
            crval1,
            crval2,
            crpix1,
            crpix2,
            cd1_1,
            cd1_2,
            cd2_1,
            cd2_2,
            a_order: 0,
            b_order: 0,
            a_coeffs: Vec::new(),
            b_coeffs: Vec::new(),
            ap_order: 0,
            bp_order: 0,
            ap_coeffs: Vec::new(),
            bp_coeffs: Vec::new(),
        }
    }

    /// Determinant of the CD matrix (deg²).
    #[inline]
    fn cd_det(&self) -> f64 {
        self.cd1_1 * self.cd2_2 - self.cd1_2 * self.cd2_1
    }

    /// False if the CD matrix is singular (`|det| < 1e-18`) or non-finite, so
    /// `world_to_pixel` would have no inverse. The threshold matches
    /// [`crate::mosaic_stitch::WcsProjection`]: `1e-18 deg² ≈ (3.6e-6 arcsec)²`,
    /// far below any real plate scale.
    pub fn is_invertible(&self) -> bool {
        let det = self.cd_det();
        det.is_finite()
            && det.abs() >= 1e-18
            && self.crval1.is_finite()
            && self.crval2.is_finite()
            && self.crpix1.is_finite()
            && self.crpix2.is_finite()
    }

    /// True iff forward SIP coefficients are present (both orders > 0 with
    /// non-empty coefficient lists), matching the Dart `hasForwardSip`.
    #[inline]
    fn has_forward_sip(&self) -> bool {
        self.a_order > 0
            && self.b_order > 0
            && !self.a_coeffs.is_empty()
            && !self.b_coeffs.is_empty()
    }

    /// True iff inverse SIP coefficients are present, matching `hasInverseSip`.
    #[inline]
    fn has_inverse_sip(&self) -> bool {
        self.ap_order > 0
            && self.bp_order > 0
            && !self.ap_coeffs.is_empty()
            && !self.bp_coeffs.is_empty()
    }

    /// Approximate isotropic plate scale (arcsec/px) — the geometric mean of the
    /// CD column norms, identical to
    /// [`crate::mosaic_stitch::WcsProjection::pixel_scale_arcsec`].
    pub fn pixel_scale_arcsec(&self) -> f64 {
        let s1 = (self.cd1_1 * self.cd1_1 + self.cd2_1 * self.cd2_1).sqrt();
        let s2 = (self.cd1_2 * self.cd1_2 + self.cd2_2 * self.cd2_2).sqrt();
        (s1 * s2).sqrt() * 3600.0
    }

    /// 0-based pixel `(x, y)` → `(ra_deg in [0, 360), dec_deg)`. Applies forward
    /// SIP before the CD matrix, then deprojects through the TAN tangent plane.
    pub fn pixel_to_world(&self, x: f64, y: f64) -> (f64, f64) {
        let crpix1_0 = self.crpix1 - 1.0;
        let crpix2_0 = self.crpix2 - 1.0;
        // Pixel offsets from the reference pixel.
        let u = x - crpix1_0;
        let v = y - crpix2_0;
        // Apply the forward SIP correction (A/B) in the CRPIX-relative frame.
        let (up, vp) = if self.has_forward_sip() {
            (
                u + sip_poly(self.a_order, &self.a_coeffs, u, v),
                v + sip_poly(self.b_order, &self.b_coeffs, u, v),
            )
        } else {
            (u, v)
        };
        // CD maps the (distortion-corrected) pixel offsets to intermediate world
        // coords (degrees).
        let xi_deg = self.cd1_1 * up + self.cd1_2 * vp;
        let eta_deg = self.cd2_1 * up + self.cd2_2 * vp;
        tan_deproject(self.crval1, self.crval2, xi_deg, eta_deg)
    }

    /// `(ra_deg, dec_deg)` → 0-based pixel `(x, y)`. `None` on the far hemisphere
    /// (behind the tangent plane, where the gnomonic projection diverges).
    /// Applies inverse SIP (AP/BP if present, else Newton iteration on the
    /// forward A/B polynomials), exactly like the Dart reference.
    pub fn world_to_pixel(&self, ra: f64, dec: f64) -> Option<(f64, f64)> {
        let det = self.cd_det();
        if !det.is_finite() || det.abs() < 1e-18 {
            return None;
        }
        let (xi_deg, eta_deg) = tan_project(self.crval1, self.crval2, ra, dec)?;
        // Inverse CD: intermediate world coords -> distortion-corrected pixel
        // offsets (U, V).
        let inv = 1.0 / det;
        let big_u = (self.cd2_2 * xi_deg - self.cd1_2 * eta_deg) * inv;
        let big_v = (-self.cd2_1 * xi_deg + self.cd1_1 * eta_deg) * inv;
        // Undo the forward SIP to recover the raw pixel offsets (u, v).
        let (u, v) = self.undistort(big_u, big_v);
        let crpix1_0 = self.crpix1 - 1.0;
        let crpix2_0 = self.crpix2 - 1.0;
        Some((u + crpix1_0, v + crpix2_0))
    }

    /// Recover the raw pixel offset `(u, v)` from the distortion-corrected offset
    /// `(U, V)`: `U = u + A(u, v)`, `V = v + B(u, v)`. Uses the AP/BP inverse SIP
    /// when present; otherwise a fixed-point Newton iteration against the forward
    /// A/B polynomials (the Dart `_undistortIntermediate` fallback).
    fn undistort(&self, big_u: f64, big_v: f64) -> (f64, f64) {
        if self.has_inverse_sip() {
            return (
                big_u + sip_poly(self.ap_order, &self.ap_coeffs, big_u, big_v),
                big_v + sip_poly(self.bp_order, &self.bp_coeffs, big_u, big_v),
            );
        }
        if !self.has_forward_sip() {
            return (big_u, big_v);
        }
        // Fixed-point: u_{n+1} = u_n - (u_n + A(u_n,v_n) - U), likewise for v.
        let mut u = big_u;
        let mut v = big_v;
        for _ in 0..SIP_NEWTON_ITERS {
            let fu = u + sip_poly(self.a_order, &self.a_coeffs, u, v);
            let fv = v + sip_poly(self.b_order, &self.b_coeffs, u, v);
            u -= fu - big_u;
            v -= fv - big_v;
        }
        (u, v)
    }
}

/// Evaluate a row-major SIP polynomial `Σ coeff[i,j] · u^i · v^j` where the
/// coefficient for term `(i, j)` is at index `i*(order+1)+j` (the native /
/// `PlateSolveResult` / Dart packing). Terms with `i + j > order` are skipped,
/// and zero coefficients are short-circuited.
fn sip_poly(order: u32, coeffs: &[f64], u: f64, v: f64) -> f64 {
    let order = order as usize;
    // An order beyond the fixed power-table capacity is not a real SIP solution
    // (ASTAP / astrometry.net emit order <= 7); treat it as malformed and apply
    // no distortion rather than indexing the stack tables out of bounds. Without
    // this guard a corrupt sidecar or hostile bridge JSON carrying `aOrder >= 16`
    // would panic in the power-table fill below.
    if order >= MAX_SIP_TERMS {
        return 0.0;
    }
    let stride = order + 1;
    if coeffs.len() < stride * stride {
        // A malformed (too-short) coefficient list contributes no distortion
        // rather than panicking on an out-of-bounds index.
        return 0.0;
    }
    let mut acc = 0.0;
    // Precompute powers of u and v up to `order` so the inner loop is cheap.
    let mut up = [0.0f64; MAX_SIP_TERMS];
    let mut vp = [0.0f64; MAX_SIP_TERMS];
    up[0] = 1.0;
    vp[0] = 1.0;
    for k in 1..=order {
        up[k] = up[k - 1] * u;
        vp[k] = vp[k - 1] * v;
    }
    for i in 0..=order {
        for j in 0..=(order - i) {
            let c = coeffs[i * stride + j];
            if c == 0.0 {
                continue;
            }
            acc += c * up[i] * vp[j];
        }
    }
    acc
}

/// Upper bound on `order + 1` for the fixed-size power tables in [`sip_poly`].
/// Real SIP orders from ASTAP / astrometry.net are ≤ 7; 16 leaves generous
/// headroom while keeping the tables on the stack.
const MAX_SIP_TERMS: usize = 16;

/// Gnomonic (TAN) forward projection: celestial `(ra, dec)` deg → intermediate
/// world coords `(ξ, η)` in **degrees**, relative to the tangent point
/// `(crval1, crval2)`. `None` on the far hemisphere (`cos_c ≤ 0`).
fn tan_project(crval1: f64, crval2: f64, ra: f64, dec: f64) -> Option<(f64, f64)> {
    let ra0 = crval1.to_radians();
    let dec0 = crval2.to_radians();
    let ra_r = ra.to_radians();
    let dec_r = dec.to_radians();
    let (sin_dec0, cos_dec0) = (dec0.sin(), dec0.cos());
    let sin_dec = dec_r.sin();
    let cos_dec = dec_r.cos();
    let dra = ra_r - ra0;
    let cos_dra = dra.cos();
    let sin_dra = dra.sin();
    let cos_c = sin_dec0 * sin_dec + cos_dec0 * cos_dec * cos_dra;
    if cos_c <= 1e-12 {
        return None;
    }
    let xi = (cos_dec * sin_dra) / cos_c;
    let eta = (cos_dec0 * sin_dec - sin_dec0 * cos_dec * cos_dra) / cos_c;
    Some((xi.to_degrees(), eta.to_degrees()))
}

/// Gnomonic (TAN) inverse projection: intermediate world coords `(ξ, η)` deg →
/// celestial `(ra, dec)` deg, relative to the tangent point. `ra` is normalised
/// to `[0, 360)`.
fn tan_deproject(crval1: f64, crval2: f64, xi_deg: f64, eta_deg: f64) -> (f64, f64) {
    let ra0 = crval1.to_radians();
    let dec0 = crval2.to_radians();
    let (sin_dec0, cos_dec0) = (dec0.sin(), dec0.cos());
    let xi = xi_deg.to_radians();
    let eta = eta_deg.to_radians();
    let r = (xi * xi + eta * eta).sqrt();
    if r < 1e-15 {
        return (normalize_deg(ra0.to_degrees()), dec0.to_degrees());
    }
    let rho = r.atan();
    let sin_rho = rho.sin();
    let cos_rho = rho.cos();
    let sin_dec = cos_rho * sin_dec0 + (eta * sin_rho * cos_dec0) / r;
    let dec = sin_dec.clamp(-1.0, 1.0).asin();
    let y_term = xi * sin_rho;
    let x_term = r * cos_dec0 * cos_rho - eta * sin_dec0 * sin_rho;
    let ra = ra0 + y_term.atan2(x_term);
    (normalize_deg(ra.to_degrees()), dec.to_degrees())
}

/// Normalise an angle in degrees to `[0, 360)`.
fn normalize_deg(d: f64) -> f64 {
    let mut v = d % 360.0;
    if v < 0.0 {
        v += 360.0;
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platesolve::PlateSolveResult;

    /// A representative CD matrix: ~2 arcsec/px, ~12° rotation, RA-flipped (the
    /// sign convention of `WcsInfo::from_plate_solve`). Reference pixel at the
    /// centre of a 2048×2048 frame (1-based FITS CRPIX).
    fn sample_wcs() -> SipWcs {
        let scale = 2.0 / 3600.0; // deg/px
        let rot = 12.0_f64.to_radians();
        let (c, s) = (rot.cos(), rot.sin());
        SipWcs::tan_only(
            83.633, // ~M42 RA
            -5.391, // ~M42 Dec
            1024.5, // 1-based centre of a 2048-wide frame
            1024.5,
            -scale * c,
            scale * s,
            scale * s,
            scale * c,
        )
    }

    /// A 3rd-order forward+inverse SIP pair. The AP/BP terms are the leading
    /// linear inverse of the A/B terms, good enough that the round-trip exercises
    /// the AP/BP code path; the Newton path is exercised separately by dropping
    /// them.
    fn sip_coeffs(order: usize) -> Vec<f64> {
        // Row-major (order+1)² with a tiny quadratic + cubic distortion.
        let stride = order + 1;
        let mut v = vec![0.0; stride * stride];
        v[2 * stride] = 1.2e-6; // A_2_0
        v[stride + 1] = -8.0e-7; // A_1_1
        v[2] = 5.0e-7; // A_0_2
        if order >= 3 {
            v[3 * stride] = 4.0e-10; // A_3_0 (only valid at order >= 3)
        }
        v
    }

    #[test]
    fn cd_only_round_trip_sub_pixel() {
        // pixel -> world -> pixel must return the original pixel to << 1e-6 px
        // across the whole frame, including the corners where TAN curvature bites.
        let wcs = sample_wcs();
        for &(x, y) in &[
            (0.0, 0.0),
            (2047.0, 0.0),
            (0.0, 2047.0),
            (2047.0, 2047.0),
            (1023.5, 1023.5),
            (512.0, 1536.0),
            (1700.0, 300.0),
        ] {
            let (ra, dec) = wcs.pixel_to_world(x, y);
            let (rx, ry) = wcs.world_to_pixel(ra, dec).expect("on-sky");
            assert!(
                (rx - x).abs() < 1e-6 && (ry - y).abs() < 1e-6,
                "cd-only round trip failed at ({x},{y}) -> ({rx},{ry})"
            );
        }
    }

    #[test]
    fn cd_only_matches_mosaic_wcs_projection() {
        // The SIP-free projection must agree with the established CD-only
        // WcsProjection (the stitcher) to round-off, proving the generalisation
        // does not break existing CD-only callers.
        let wcs = sample_wcs();
        let info = crate::WcsInfo {
            crval1: wcs.crval1,
            crval2: wcs.crval2,
            crpix1: wcs.crpix1,
            crpix2: wcs.crpix2,
            cd1_1: wcs.cd1_1,
            cd1_2: wcs.cd1_2,
            cd2_1: wcs.cd2_1,
            cd2_2: wcs.cd2_2,
        };
        let proj = crate::mosaic_stitch::WcsProjection::new(&info).expect("invertible");
        for &(x, y) in &[(0.0, 0.0), (2047.0, 2047.0), (731.0, 1290.0)] {
            let (a_ra, a_dec) = wcs.pixel_to_world(x, y);
            let (b_ra, b_dec) = proj.pixel_to_world(x, y);
            assert!((a_ra - b_ra).abs() < 1e-9, "ra {a_ra} != {b_ra}");
            assert!((a_dec - b_dec).abs() < 1e-9, "dec {a_dec} != {b_dec}");

            let (a_x, a_y) = wcs.world_to_pixel(a_ra, a_dec).unwrap();
            let (b_x, b_y) = proj.world_to_pixel(b_ra, b_dec).unwrap();
            assert!((a_x - b_x).abs() < 1e-7, "x {a_x} != {b_x}");
            assert!((a_y - b_y).abs() < 1e-7, "y {a_y} != {b_y}");
        }
    }

    #[test]
    fn forward_sip_round_trip_via_newton() {
        // With forward A/B only (no AP/BP) the inverse must Newton-iterate back to
        // the original pixel within sub-pixel tolerance everywhere on the frame.
        let order = 3u32;
        let mut wcs = sample_wcs();
        wcs.a_order = order;
        wcs.b_order = order;
        wcs.a_coeffs = sip_coeffs(order as usize);
        // B distortion: a different small set so x and y distort independently.
        let mut b = vec![0.0; ((order + 1) * (order + 1)) as usize];
        let stride = (order + 1) as usize;
        b[2 * stride] = -6.0e-7; // B_2_0
        b[stride + 1] = 9.0e-7; // B_1_1
        b[2] = -1.1e-6; // B_0_2
        wcs.b_coeffs = b;

        assert!(wcs.has_forward_sip());
        for &(x, y) in &[
            (0.0, 0.0),
            (2047.0, 0.0),
            (0.0, 2047.0),
            (2047.0, 2047.0),
            (1024.0, 1024.0),
            (400.0, 1700.0),
        ] {
            let (ra, dec) = wcs.pixel_to_world(x, y);
            let (rx, ry) = wcs.world_to_pixel(ra, dec).expect("on-sky");
            assert!(
                (rx - x).abs() < 1e-4 && (ry - y).abs() < 1e-4,
                "SIP Newton round trip failed at ({x},{y}) -> ({rx},{ry})"
            );
        }
    }

    #[test]
    fn forward_sip_changes_the_mapping() {
        // Sanity: a non-trivial forward SIP must actually move the projected
        // coordinate vs. the CD-only mapping (otherwise the round-trip test is
        // vacuously satisfied by an identity distortion).
        let mut wcs = sample_wcs();
        let plain = wcs.pixel_to_world(2047.0, 2047.0);
        wcs.a_order = 3;
        wcs.b_order = 3;
        wcs.a_coeffs = sip_coeffs(3);
        wcs.b_coeffs = sip_coeffs(3);
        let distorted = wcs.pixel_to_world(2047.0, 2047.0);
        let dr = (plain.0 - distorted.0).abs();
        let dd = (plain.1 - distorted.1).abs();
        assert!(dr + dd > 1e-7, "SIP did not change the corner mapping");
    }

    #[test]
    fn world_to_pixel_none_on_far_hemisphere() {
        // The antipode of the tangent point is behind the plane -> no pixel.
        let wcs = sample_wcs();
        let anti_ra = (wcs.crval1 + 180.0) % 360.0;
        let anti_dec = -wcs.crval2;
        assert!(wcs.world_to_pixel(anti_ra, anti_dec).is_none());
    }

    #[test]
    fn pixel_scale_and_invertibility() {
        let wcs = sample_wcs();
        assert!((wcs.pixel_scale_arcsec() - 2.0).abs() < 1e-9);
        assert!(wcs.is_invertible());

        // A singular CD matrix is not invertible and world_to_pixel returns None.
        let bad = SipWcs::tan_only(10.0, 20.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);
        assert!(!bad.is_invertible());
        assert!(bad.world_to_pixel(10.0, 20.0).is_none());
    }

    #[test]
    fn from_plate_solve_carries_cd_and_sip() {
        let scale = 1.5; // arcsec/px
        let scale_deg = scale / 3600.0;
        let r = PlateSolveResult {
            ra: 200.0,
            dec: 30.0,
            pixel_scale: scale,
            rotation: 0.0,
            field_width: 2000.0 * scale_deg,
            field_height: 1500.0 * scale_deg,
            success: true,
            cd1_1: -scale_deg,
            cd1_2: 0.0,
            cd2_1: 0.0,
            cd2_2: scale_deg,
            a_order: 2,
            b_order: 2,
            a_coeffs: sip_coeffs(2),
            b_coeffs: sip_coeffs(2),
            ..Default::default()
        };
        let wcs = SipWcs::from_plate_solve(&r).expect("buildable");
        assert_eq!(wcs.a_order, 2);
        assert_eq!(wcs.a_coeffs, sip_coeffs(2));
        // CRPIX is the (1-based) image centre derived from the field size.
        assert!((wcs.crpix1 - 1000.5).abs() < 1.0);
        assert!((wcs.crpix2 - 750.5).abs() < 1.0);
        assert!(wcs.is_invertible());
        // A failed solve yields None.
        let failed = PlateSolveResult {
            success: false,
            ..r.clone()
        };
        assert!(SipWcs::from_plate_solve(&failed).is_none());
    }

    #[test]
    fn inverse_sip_path_round_trips() {
        // When AP/BP are present they (not Newton) drive world_to_pixel. Build a
        // forward SIP and derive a matching first-order inverse so the AP/BP path
        // round-trips to the same sub-pixel tolerance.
        let order = 2u32;
        let stride = (order + 1) as usize;
        let mut a = vec![0.0; stride * stride];
        let mut b = vec![0.0; stride * stride];
        a[2 * stride] = 1.0e-6; // A_2_0
        b[2] = 1.0e-6; // B_0_2
                       // First-order inverse: AP ≈ -A, BP ≈ -B for these leading terms.
        let mut ap = vec![0.0; stride * stride];
        let mut bp = vec![0.0; stride * stride];
        ap[2 * stride] = -1.0e-6;
        bp[2] = -1.0e-6;

        let mut wcs = sample_wcs();
        wcs.a_order = order;
        wcs.b_order = order;
        wcs.a_coeffs = a;
        wcs.b_coeffs = b;
        wcs.ap_order = order;
        wcs.bp_order = order;
        wcs.ap_coeffs = ap;
        wcs.bp_coeffs = bp;
        assert!(wcs.has_inverse_sip());

        for &(x, y) in &[(100.0, 100.0), (1900.0, 200.0), (1024.0, 1024.0)] {
            let (ra, dec) = wcs.pixel_to_world(x, y);
            let (rx, ry) = wcs.world_to_pixel(ra, dec).unwrap();
            // The leading-order inverse is approximate; tolerance is looser than
            // the Newton path but still well under a pixel for these terms.
            assert!(
                (rx - x).abs() < 0.05 && (ry - y).abs() < 0.05,
                "AP/BP round trip at ({x},{y}) -> ({rx},{ry})"
            );
        }
    }

    #[test]
    fn pathological_sip_order_does_not_panic() {
        // A corrupt sidecar / hostile bridge JSON can carry an order far beyond
        // any real solver's. It must apply no distortion, not panic the power
        // tables. (`aOrder = 32` with a long enough coeff list to pass the
        // length guard would, before the order clamp, index past MAX_SIP_TERMS.)
        let order = 32u32;
        let stride = (order + 1) as usize;
        let mut wcs = sample_wcs();
        wcs.a_order = order;
        wcs.b_order = order;
        wcs.a_coeffs = vec![1e-9; stride * stride];
        wcs.b_coeffs = vec![1e-9; stride * stride];
        // Forward + inverse must both run cleanly and ignore the bogus SIP.
        let plain = SipWcs::tan_only(
            wcs.crval1, wcs.crval2, wcs.crpix1, wcs.crpix2, wcs.cd1_1, wcs.cd1_2, wcs.cd2_1,
            wcs.cd2_2,
        );
        let (ra, dec) = wcs.pixel_to_world(1500.0, 600.0);
        let (pra, pdec) = plain.pixel_to_world(1500.0, 600.0);
        assert!((ra - pra).abs() < 1e-12 && (dec - pdec).abs() < 1e-12);
        let _ = wcs.world_to_pixel(ra, dec).expect("on-sky, no panic");
    }

    #[test]
    fn serde_round_trip_camel_case_keys() {
        let wcs = sample_wcs();
        let json = serde_json::to_string(&wcs).unwrap();
        // The wire keys are the contract's camelCase names.
        assert!(json.contains("\"cd1_1\""));
        assert!(json.contains("\"aOrder\""));
        assert!(json.contains("\"apCoeffs\""));
        let back: SipWcs = serde_json::from_str(&json).unwrap();
        assert_eq!(back, wcs);
    }
}
