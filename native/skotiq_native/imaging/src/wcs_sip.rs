//! SIP-aware gnomonic (TAN) astrometry for one frame.
//!
//! [`SipWcs`] is the crate's one astrometry type: a CD matrix plus full forward
//! and inverse SIP (`A`/`B`, `AP`/`BP`), ported from the Dart reference
//! (`gnomonic_projection.dart`). The mosaic stitcher, the sky atlas, DepthLock
//! and the Darkroom all project through it. A CD-only solution leaves the SIP
//! orders at zero ([`SipWcs::tan_only`]).
//!
//! SIP matters because at the >1° fields most amateur astrographs work at,
//! focal-plane distortion is several pixels at the corners, far more than the
//! sub-pixel accuracy needed to fold many nights of frames onto one grid
//! without smearing stars.
//!
//! This module also owns how a WCS is carried in a FITS header: reading
//! ([`SipWcs::from_header`]), writing ([`SipWcs::write_to_header`]) and
//! keeping the cards right when the pixel grid is cropped
//! ([`crop_header_wcs`]) or resampled ([`rescale_header_wcs`]).
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
//! `i * (order + 1) + j`, matching [`PlateSolveResult`] and
//! `gnomonic_projection.dart`. All trig is in radians; the public interface is
//! degrees in / degrees out and **0-based** pixels (matching the resampler and
//! [`crate::ImageData`] indexing).

use crate::fits::{FitsHeader, WcsInfo};
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

/// One solve, referenced at the frame center: `ra`/`dec` are the solution's
/// reference point (`CRVAL`) with the center pixel as its reference pixel, and
/// the CD matrix and SIP polynomials are those about that pixel. Every solver
/// output is brought to this form where it is parsed, so centering, the
/// frame's WCS ([`crate::SipWcs::from_plate_solve`]) and the app read one
/// solution.
#[derive(Debug, Clone, Default)]
pub struct PlateSolveResult {
    /// RA of the frame center in degrees
    pub ra: f64,
    /// Dec of the frame center in degrees
    pub dec: f64,
    /// Image scale in arcsec/pixel
    pub pixel_scale: f64,
    /// Rotation angle in degrees (East of North)
    pub rotation: f64,
    /// Field width in degrees
    pub field_width: f64,
    /// Field height in degrees
    pub field_height: f64,
    pub success: bool,
    pub error: Option<String>,
    /// Time taken to solve in seconds
    pub solve_time_secs: f64,
    /// Raw CD matrix (deg/pixel) as read from the WCS — the full anisotropic
    /// transform. `pixel_scale`/`rotation` above are the isotropic collapse
    /// kept for backward compatibility. Zero when no WCS was parsed.
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    /// SIP forward distortion order (`A_ORDER`/`B_ORDER`). Zero when absent.
    pub a_order: u32,
    pub b_order: u32,
    /// SIP forward coefficients in row-major `(i, j)` order: the slot for term
    /// `A_i_j` is at index `i * (order + 1) + j` (likewise `B_i_j`). Empty when
    /// no SIP keywords were present.
    pub a_coeffs: Vec<f64>,
    pub b_coeffs: Vec<f64>,
    /// SIP inverse distortion order (`AP_ORDER`/`BP_ORDER`). Zero when absent.
    pub ap_order: u32,
    pub bp_order: u32,
    /// SIP inverse coefficients, same row-major `(i, j)` layout as the forward
    /// terms. Empty when the inverse keywords were not present.
    pub ap_coeffs: Vec<f64>,
    pub bp_coeffs: Vec<f64>,
}

impl SipWcs {
    /// The WCS of a solve of a `width` × `height` frame: the solved position
    /// (the solver's reference point, which the result reports for the
    /// frame's centre pixel), the solver's own CD matrix (it carries any skew
    /// and mirroring) and its SIP polynomials. A solver that gave no usable CD
    /// matrix gets one from its scale and rotation ([`Self::from_pointing`]).
    ///
    /// `None` for a failed solve, or one whose astrometry cannot be inverted,
    /// so no caller stamps or folds a frame by a projection that is not one.
    pub fn from_plate_solve(r: &PlateSolveResult, width: u32, height: u32) -> Option<Self> {
        if !r.success || width == 0 || height == 0 {
            return None;
        }
        let pointing = Self::from_pointing(r.ra, r.dec, r.rotation, r.pixel_scale, width, height);
        let solved = Self {
            cd1_1: r.cd1_1,
            cd1_2: r.cd1_2,
            cd2_1: r.cd2_1,
            cd2_2: r.cd2_2,
            ..pointing.clone()
        };
        let linear = if solved.is_invertible() {
            solved
        } else {
            pointing
        };
        let wcs = Self {
            a_order: r.a_order,
            b_order: r.b_order,
            a_coeffs: r.a_coeffs.clone(),
            b_coeffs: r.b_coeffs.clone(),
            ap_order: r.ap_order,
            bp_order: r.bp_order,
            ap_coeffs: r.ap_coeffs.clone(),
            bp_coeffs: r.bp_coeffs.clone(),
            ..linear
        };
        wcs.is_invertible().then_some(wcs)
    }

    /// A distortion-free WCS for a `width` × `height` frame centred on
    /// `(ra, dec)` degrees, at `scale_arcsec` per pixel, rotated by
    /// `rotation_deg` east of north, with the sky's own parity (east left of
    /// north).
    pub fn from_pointing(
        ra: f64,
        dec: f64,
        rotation_deg: f64,
        scale_arcsec: f64,
        width: u32,
        height: u32,
    ) -> Self {
        let scale_deg = scale_arcsec / 3600.0;
        let (sin, cos) = rotation_deg.to_radians().sin_cos();
        // The centre of an N-pixel axis is (N + 1) / 2 in 1-based FITS pixels.
        Self::tan_only(
            ra,
            dec,
            (f64::from(width) + 1.0) / 2.0,
            (f64::from(height) + 1.0) / 2.0,
            -scale_deg * cos,
            scale_deg * sin,
            scale_deg * sin,
            scale_deg * cos,
        )
    }

    /// The astrometry a FITS header carries, or `None` when it carries none.
    ///
    /// * `CRVAL1/2` are required.
    /// * `CRPIX1/2` default to the image centre, `(NAXIS + 1) / 2`.
    /// * The linear part is read as wcslib reads it (WCS Papers I and II):
    ///   a `PC` matrix scaled by `CDELT` when any `PCi_j` card is present,
    ///   otherwise the `CD` matrix when any `CDi_j` card is, otherwise
    ///   `CDELT` rotated by `CROTA2`. Absent cards take the standard defaults
    ///   (`PC` the identity, `CD` terms zero, `CDELT` one, `CROTA2` zero). A
    ///   header with none of `PC`, `CD` or `CDELT` carries no WCS.
    /// * SIP polynomials are read when their `*_ORDER` cards are present.
    ///
    /// The result is what the header says, not a judgment of it: a caller that
    /// will invert the projection checks [`Self::is_invertible`]. A header
    /// with an astrometry card that should hold a number and does not
    /// ([`unreadable_astrometry_card`]) carries no WCS: reading the rest
    /// would default that card and describe another sky.
    pub fn from_header(header: &FitsHeader) -> Option<Self> {
        if unreadable_astrometry_card(header).is_some() {
            return None;
        }
        let crval1 = header.get_float("CRVAL1")?;
        let crval2 = header.get_float("CRVAL2")?;
        let centre = |axis: &str| header.get_int(axis).unwrap_or(0) as f64 / 2.0 + 0.5;
        let crpix1 = header
            .get_float("CRPIX1")
            .unwrap_or_else(|| centre("NAXIS1"));
        let crpix2 = header
            .get_float("CRPIX2")
            .unwrap_or_else(|| centre("NAXIS2"));
        let [cd1_1, cd1_2, cd2_1, cd2_2] = linear_part(header)?;

        let order = |key: &str| header.get_int(key).unwrap_or(0).max(0) as u32;
        let (a_order, b_order) = (order("A_ORDER"), order("B_ORDER"));
        let (ap_order, bp_order) = (order("AP_ORDER"), order("BP_ORDER"));
        Some(Self {
            crval1,
            crval2,
            crpix1,
            crpix2,
            cd1_1,
            cd1_2,
            cd2_1,
            cd2_2,
            a_order,
            b_order,
            a_coeffs: read_sip_coeffs(header, "A", a_order),
            b_coeffs: read_sip_coeffs(header, "B", b_order),
            ap_order,
            bp_order,
            ap_coeffs: read_sip_coeffs(header, "AP", ap_order),
            bp_coeffs: read_sip_coeffs(header, "BP", bp_order),
        })
    }

    /// Write this astrometry into `header` as a celestial TAN solution in
    /// ICRS: `CRVAL`, `CRPIX`, the `CD` matrix, `CTYPE`/`CUNIT`, and the SIP
    /// cards when it carries distortion. Every astrometry card the header
    /// held before goes first, so no earlier `PC` matrix or SIP polynomial
    /// is read on top of this solution.
    pub fn write_to_header(&self, header: &mut FitsHeader) {
        crate::fits::remove_astrometry_headers(header);
        header.set_float("CRVAL1", self.crval1);
        header.set_float("CRVAL2", self.crval2);
        header.set_float("CRPIX1", self.crpix1);
        header.set_float("CRPIX2", self.crpix2);
        header.set_float("CD1_1", self.cd1_1);
        header.set_float("CD1_2", self.cd1_2);
        header.set_float("CD2_1", self.cd2_1);
        header.set_float("CD2_2", self.cd2_2);

        let polynomials = [
            ("A", self.a_order, &self.a_coeffs),
            ("B", self.b_order, &self.b_coeffs),
            ("AP", self.ap_order, &self.ap_coeffs),
            ("BP", self.bp_order, &self.bp_coeffs),
        ];
        let distorted = polynomials
            .iter()
            .any(|(_, order, coeffs)| *order > 0 && !coeffs.is_empty());
        let (ctype1, ctype2) = if distorted {
            ("RA---TAN-SIP", "DEC--TAN-SIP")
        } else {
            ("RA---TAN", "DEC--TAN")
        };
        header.set_string("CTYPE1", ctype1);
        header.set_string("CTYPE2", ctype2);
        header.set_string("CUNIT1", "deg");
        header.set_string("CUNIT2", "deg");
        header.set_float("EQUINOX", 2000.0);
        header.set_string("RADESYS", "ICRS");

        for (prefix, order, coeffs) in polynomials {
            let n = (order + 1) as usize;
            if order == 0 || coeffs.len() < n * n {
                continue;
            }
            header.set_int(&format!("{prefix}_ORDER"), i64::from(order));
            for i in 0..n {
                for j in 0..n {
                    let coeff = coeffs[i * n + j];
                    if coeff != 0.0 {
                        header.set_float(&format!("{prefix}_{i}_{j}"), coeff);
                    }
                }
            }
        }
    }

    /// The same astrometry referenced at another pixel: `CRPIX` moved to the
    /// 1-based pixel `(crpix1, crpix2)` of a `width` × `height` frame, with
    /// `CRVAL` the sky position this solution gives that pixel.
    ///
    /// A plate solve is reported at the frame center
    /// ([`PlateSolveResult`]); astrometry.net by default
    /// anchors its solution on a matched star pattern anywhere in the frame.
    /// Moving the tangent point is a projective map of the tangent plane, not
    /// a polynomial one, so the CD matrix and the forward SIP polynomials are
    /// fitted again over the frame, one order above the solution's own (at
    /// least third): the first term left out is below a microarcsecond on a
    /// degree-wide field. The inverse polynomials are left to the forward
    /// ones ([`Self::world_to_pixel`] inverts those when it has no `AP`/`BP`).
    ///
    /// `None` when this solution cannot be inverted or the fit has no answer.
    pub fn rereferenced(&self, crpix1: f64, crpix2: f64, width: f64, height: f64) -> Option<Self> {
        if !self.is_invertible() || !(width >= 1.0 && height >= 1.0) {
            return None;
        }
        let (x0, y0) = (crpix1 - 1.0, crpix2 - 1.0);
        let (crval1, crval2) = self.pixel_to_world(x0, y0);
        let own_order = if self.has_forward_sip() {
            self.a_order.max(self.b_order)
        } else {
            1
        };
        let order = (own_order.max(2) + 1) as usize;
        if order + 1 > MAX_SIP_TERMS {
            return None;
        }
        let terms: Vec<(usize, usize)> = (0..=order)
            .flat_map(|i| (0..=order - i).map(move |j| (i, j)))
            .collect();

        // Offsets are fitted in units of the frame's longer side so the
        // powers stay near one.
        let unit = width.max(height);
        let steps = 2 * order + 3;
        let n = terms.len();
        let mut normal = vec![vec![0.0; n]; n];
        let (mut rhs_xi, mut rhs_eta) = (vec![0.0; n], vec![0.0; n]);
        for row in 0..steps {
            for col in 0..steps {
                let x = (width - 1.0) * col as f64 / (steps - 1) as f64;
                let y = (height - 1.0) * row as f64 / (steps - 1) as f64;
                let (ra, dec) = self.pixel_to_world(x, y);
                let (xi, eta) = tan_project(crval1, crval2, ra, dec)?;
                let (s, t) = ((x - x0) / unit, (y - y0) / unit);
                let basis: Vec<f64> = terms
                    .iter()
                    .map(|&(i, j)| s.powi(i as i32) * t.powi(j as i32))
                    .collect();
                for a in 0..n {
                    for b in 0..n {
                        normal[a][b] += basis[a] * basis[b];
                    }
                    rhs_xi[a] += basis[a] * xi;
                    rhs_eta[a] += basis[a] * eta;
                }
            }
        }
        let solve = crate::background_extraction::solve_linear_system;
        let xi = solve(normal.clone(), rhs_xi)?;
        let eta = solve(normal, rhs_eta)?;
        // Per-pixel coefficient of term (i, j) on each tangent-plane axis.
        let per_pixel = |k: usize| {
            let (i, j) = terms[k];
            let scale = unit.powi((i + j) as i32);
            (xi[k] / scale, eta[k] / scale)
        };
        let index = |i: usize, j: usize| terms.iter().position(|&t| t == (i, j));
        let (cd1_1, cd2_1) = per_pixel(index(1, 0)?);
        let (cd1_2, cd2_2) = per_pixel(index(0, 1)?);
        let det = cd1_1 * cd2_2 - cd1_2 * cd2_1;
        if !det.is_finite() || det.abs() < 1e-18 {
            return None;
        }

        // xi = CD (u + A, v + B): everything but the linear terms, taken
        // through the inverse of CD, is the SIP polynomial pair.
        let stride = order + 1;
        let mut a_coeffs = vec![0.0; stride * stride];
        let mut b_coeffs = vec![0.0; stride * stride];
        for (k, &(i, j)) in terms.iter().enumerate() {
            if i + j == 1 {
                continue;
            }
            let (c_xi, c_eta) = per_pixel(k);
            a_coeffs[i * stride + j] = (cd2_2 * c_xi - cd1_2 * c_eta) / det;
            b_coeffs[i * stride + j] = (-cd2_1 * c_xi + cd1_1 * c_eta) / det;
        }
        Some(Self {
            crval1,
            crval2,
            crpix1,
            crpix2,
            cd1_1,
            cd1_2,
            cd2_1,
            cd2_2,
            a_order: order as u32,
            b_order: order as u32,
            a_coeffs,
            b_coeffs,
            ap_order: 0,
            bp_order: 0,
            ap_coeffs: Vec::new(),
            bp_coeffs: Vec::new(),
        })
    }

    /// The linear (CD-only) part.
    pub fn cd_only(&self) -> WcsInfo {
        WcsInfo {
            crval1: self.crval1,
            crval2: self.crval2,
            crpix1: self.crpix1,
            crpix2: self.crpix2,
            cd1_1: self.cd1_1,
            cd1_2: self.cd1_2,
            cd2_1: self.cd2_1,
            cd2_2: self.cd2_2,
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
    /// `world_to_pixel` would have no inverse. `1e-18 deg² ≈ (3.6e-6 arcsec)²`,
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
    pub fn has_forward_sip(&self) -> bool {
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
    /// CD column norms.
    pub fn pixel_scale_arcsec(&self) -> f64 {
        let s1 = (self.cd1_1 * self.cd1_1 + self.cd2_1 * self.cd2_1).sqrt();
        let s2 = (self.cd1_2 * self.cd1_2 + self.cd2_2 * self.cd2_2).sqrt();
        (s1 * s2).sqrt() * 3600.0
    }

    /// 0-based pixel `(x, y)` → `(ra_deg in [0, 360), dec_deg)`. Applies forward
    /// SIP before the CD matrix, then deprojects through the TAN tangent plane.
    pub fn pixel_to_world(&self, x: f64, y: f64) -> (f64, f64) {
        let (xi_deg, eta_deg) = self.pixel_to_plane(x, y);
        tan_deproject(self.crval1, self.crval2, xi_deg, eta_deg)
    }

    /// 0-based pixel `(x, y)` → intermediate world coordinates `(ξ, η)` in
    /// degrees on the plane tangent at `CRVAL`: forward SIP, then the CD
    /// matrix.
    pub fn pixel_to_plane(&self, x: f64, y: f64) -> (f64, f64) {
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
        (
            self.cd1_1 * up + self.cd1_2 * vp,
            self.cd2_1 * up + self.cd2_2 * vp,
        )
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

impl From<&WcsInfo> for SipWcs {
    fn from(wcs: &WcsInfo) -> Self {
        Self::tan_only(
            wcs.crval1, wcs.crval2, wcs.crpix1, wcs.crpix2, wcs.cd1_1, wcs.cd1_2, wcs.cd2_1,
            wcs.cd2_2,
        )
    }
}

/// The first astrometry card ([`crate::fits::is_astrometry_keyword`]) that
/// should hold a number and holds something else, with that value as text.
/// Only the axis types, units and reference system are words.
pub fn unreadable_astrometry_card(header: &FitsHeader) -> Option<(&str, String)> {
    let is_word = |key: &str| {
        key.starts_with("CTYPE")
            || key.starts_with("CUNIT")
            || matches!(key, "RADESYS" | "RADECSYS")
    };
    header.cards().find_map(|(key, value, _)| {
        (crate::fits::is_astrometry_keyword(key) && !is_word(key) && value.as_f64().is_none()).then(
            || {
                let text = match value {
                    crate::FitsValue::String(text) => text.clone(),
                    other => crate::fits::value_card_text(other),
                };
                (key, text)
            },
        )
    })
}

/// The CD matrix `[cd1_1, cd1_2, cd2_1, cd2_2]` of the header's linear
/// transformation, in the precedence and with the defaults of
/// [`SipWcs::from_header`].
fn linear_part(header: &FitsHeader) -> Option<[f64; 4]> {
    let cards = |keys: [&str; 4]| keys.map(|key| header.get_float(key));
    let pc = cards(["PC1_1", "PC1_2", "PC2_1", "PC2_2"]);
    let cd = cards(["CD1_1", "CD1_2", "CD2_1", "CD2_2"]);
    let cdelt = [header.get_float("CDELT1"), header.get_float("CDELT2")];
    let [cdelt1, cdelt2] = cdelt.map(|v| v.unwrap_or(1.0));
    if pc.iter().any(Option::is_some) {
        let [pc1_1, pc1_2, pc2_1, pc2_2] = [
            pc[0].unwrap_or(1.0),
            pc[1].unwrap_or(0.0),
            pc[2].unwrap_or(0.0),
            pc[3].unwrap_or(1.0),
        ];
        Some([
            cdelt1 * pc1_1,
            cdelt1 * pc1_2,
            cdelt2 * pc2_1,
            cdelt2 * pc2_2,
        ])
    } else if cd.iter().any(Option::is_some) {
        Some(cd.map(|v| v.unwrap_or(0.0)))
    } else if cdelt.iter().any(Option::is_some) {
        let (sin, cos) = header
            .get_float("CROTA2")
            .unwrap_or(0.0)
            .to_radians()
            .sin_cos();
        Some([cdelt1 * cos, -cdelt2 * sin, cdelt1 * sin, cdelt2 * cos])
    } else {
        None
    }
}

/// SIP coefficients for one polynomial, packed row-major as `i*(order+1)+j`.
/// Absent terms are zero, which is the FITS convention for an omitted card.
fn read_sip_coeffs(header: &FitsHeader, prefix: &str, order: u32) -> Vec<f64> {
    if order == 0 {
        return Vec::new();
    }
    let n = (order + 1) as usize;
    let mut coeffs = vec![0.0_f64; n * n];
    for i in 0..n {
        for j in 0..n {
            if let Some(v) = header.get_float(&format!("{prefix}_{i}_{j}")) {
                coeffs[i * n + j] = v;
            }
        }
    }
    coeffs
}

/// Move the reference pixel of the WCS in `header` for a crop whose origin is
/// `(x0, y0)` pixels into the image, so the cropped image keeps pointing at
/// the same sky. A header without `CRPIX` is left alone.
pub fn crop_header_wcs(header: &mut FitsHeader, x0: f64, y0: f64) {
    for (key, origin) in [("CRPIX1", x0), ("CRPIX2", y0)] {
        if let Some(crpix) = header.get_float(key) {
            header.set_float(key, crpix - origin);
        }
    }
}

/// A change of pixel grid by a whole factor about the image corner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridScale {
    /// Each output pixel covers `n × n` input pixels (binning, a pyramid
    /// level).
    Coarser(u32),
    /// Each input pixel becomes `n × n` output pixels (drizzle).
    Finer(u32),
}

/// Rewrite the WCS cards in `header` for a resampled pixel grid: the
/// reference pixel, the `CD` matrix or `CDELT` pair, and every SIP
/// polynomial. Cards that are absent stay absent.
///
/// A SIP polynomial maps pixel offsets to pixel offsets, so term `(i, j)`
/// scales by the pixel-size ratio to the power `i + j − 1`.
pub fn rescale_header_wcs(header: &mut FitsHeader, scale: GridScale) {
    // Pixel centres are at whole 1-based coordinates, so the corner the grid
    // scales about is at 0.5.
    for key in ["CRPIX1", "CRPIX2"] {
        if let Some(crpix) = header.get_float(key) {
            let moved = match scale {
                GridScale::Coarser(n) => (crpix + 0.5 * (f64::from(n) - 1.0)) / f64::from(n),
                GridScale::Finer(n) => (crpix - 0.5) * f64::from(n) + 0.5,
            };
            header.set_float(key, moved);
        }
    }
    for key in ["CD1_1", "CD1_2", "CD2_1", "CD2_2", "CDELT1", "CDELT2"] {
        if let Some(value) = header.get_float(key) {
            let scaled = match scale {
                GridScale::Coarser(n) => value * f64::from(n),
                GridScale::Finer(n) => value / f64::from(n),
            };
            header.set_float(key, scaled);
        }
    }
    for prefix in ["A", "B", "AP", "BP"] {
        let order = header
            .get_int(&format!("{prefix}_ORDER"))
            .unwrap_or(0)
            .max(0) as usize;
        if order == 0 {
            continue;
        }
        for i in 0..=order {
            for j in 0..=order {
                let key = format!("{prefix}_{i}_{j}");
                if let Some(coeff) = header.get_float(&key) {
                    let exponent = (i + j) as i32 - 1;
                    let factor = match scale {
                        GridScale::Coarser(n) => f64::from(n).powi(exponent),
                        GridScale::Finer(n) => f64::from(n).powi(-exponent),
                    };
                    header.set_float(&key, coeff * factor);
                }
            }
        }
    }
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

    /// A representative CD matrix: ~2 arcsec/px, ~12° rotation, RA-flipped (the
    /// sign convention of `SipWcs::from_pointing`). Reference pixel at the
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

    /// A garbled number in an astrometry card is no solution, not a
    /// solution with that term at its default.
    #[test]
    fn a_header_with_a_garbled_astrometry_number_carries_no_wcs() {
        let mut header = FitsHeader::new();
        header.set_string("CTYPE1", "RA---TAN");
        header.set_string("CTYPE2", "DEC--TAN");
        header.set_string("RADESYS", "ICRS");
        for (key, value) in [
            ("CRVAL1", 10.0),
            ("CRVAL2", 41.0),
            ("CD1_1", -2.8e-4),
            ("CD1_2", 0.0),
            ("CD2_2", 2.8e-4),
        ] {
            header.set_float(key, value);
        }
        header.set_string("CD2_1", "1.0e-6x");
        assert_eq!(
            unreadable_astrometry_card(&header),
            Some(("CD2_1", "1.0e-6x".to_string()))
        );
        assert!(SipWcs::from_header(&header).is_none());
        header.set_float("CD2_1", 0.0);
        assert_eq!(unreadable_astrometry_card(&header), None);
        assert!(SipWcs::from_header(&header).is_some());
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
    fn a_wcs_written_to_a_header_reads_back_the_same() {
        let order = 3u32;
        let mut wcs = sample_wcs();
        wcs.a_order = order;
        wcs.b_order = order;
        wcs.a_coeffs = sip_coeffs(order as usize);
        wcs.b_coeffs = sip_coeffs(order as usize);
        wcs.ap_order = order;
        wcs.bp_order = order;
        wcs.ap_coeffs = sip_coeffs(order as usize).iter().map(|c| -c).collect();
        wcs.bp_coeffs = sip_coeffs(order as usize).iter().map(|c| -c).collect();

        let mut header = FitsHeader::new();
        wcs.write_to_header(&mut header);
        assert_eq!(header.get_string("CTYPE1"), Some("RA---TAN-SIP"));
        assert_eq!(header.get_int("A_ORDER"), Some(3));
        assert!(
            header.get_float("A_0_0").is_none(),
            "zero terms are omitted"
        );
        assert_eq!(SipWcs::from_header(&header), Some(wcs));

        let plain = sample_wcs();
        let mut header = FitsHeader::new();
        plain.write_to_header(&mut header);
        assert_eq!(header.get_string("CTYPE2"), Some("DEC--TAN"));
        assert!(header.get("A_ORDER").is_none());
        assert_eq!(SipWcs::from_header(&header), Some(plain.clone()));
        assert_eq!(SipWcs::from(&plain.cd_only()), plain);
    }

    #[test]
    fn a_wcs_written_over_another_replaces_it_whole() {
        let mut earlier = sample_wcs();
        earlier.a_order = 2;
        earlier.b_order = 2;
        earlier.a_coeffs = sip_coeffs(2);
        earlier.b_coeffs = sip_coeffs(2);
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", "M 42");
        earlier.write_to_header(&mut header);
        for (key, value) in [
            ("PC1_1", 0.5),
            ("PC2_2", 0.5),
            ("CDELT1", 1e-3),
            ("PV2_1", 0.1),
        ] {
            header.set_float(key, value);
        }

        let later = SipWcs::tan_only(84.0, -5.0, 10.5, 20.5, -1e-4, 0.0, 0.0, 1e-4);
        later.write_to_header(&mut header);
        assert_eq!(SipWcs::from_header(&header), Some(later));
        for key in [
            "A_ORDER", "A_2_0", "B_ORDER", "PC1_1", "PC2_2", "CDELT1", "PV2_1",
        ] {
            assert!(header.get(key).is_none(), "{key} outlived the new solution");
        }
        assert_eq!(header.get_string("CTYPE1"), Some("RA---TAN"));
        assert_eq!(header.get_string("OBJECT"), Some("M 42"));
    }

    #[test]
    fn a_header_without_a_cd_matrix_is_read_from_cdelt_and_crota() {
        let mut header = FitsHeader::new();
        header.set_int("NAXIS1", 100);
        header.set_int("NAXIS2", 60);
        header.set_float("CRVAL1", 10.0);
        header.set_float("CRVAL2", 20.0);
        header.set_float("CDELT1", -0.001);
        header.set_float("CDELT2", 0.002);
        let wcs = SipWcs::from_header(&header).expect("CDELT pair is enough");
        assert_eq!((wcs.crpix1, wcs.crpix2), (50.5, 30.5), "centre by default");
        assert_eq!(
            [wcs.cd1_1, wcs.cd1_2, wcs.cd2_1, wcs.cd2_2],
            [-0.001, 0.0, 0.0, 0.002]
        );

        header.set_float("CROTA2", 90.0);
        let rotated = SipWcs::from_header(&header).expect("rotated");
        assert!(rotated.cd1_1.abs() < 1e-15 && (rotated.cd1_2 + 0.002).abs() < 1e-15);
        assert!((rotated.cd2_1 + 0.001).abs() < 1e-15 && rotated.cd2_2.abs() < 1e-15);

        // A CD matrix wins over CDELT, and a missing off-diagonal term is zero.
        header.set_float("CD1_1", -0.003);
        header.set_float("CD2_2", 0.003);
        let cd = SipWcs::from_header(&header).expect("cd");
        assert_eq!(
            [cd.cd1_1, cd.cd1_2, cd.cd2_1, cd.cd2_2],
            [-0.003, 0.0, 0.0, 0.003]
        );

        let mut bare = FitsHeader::new();
        bare.set_float("CRVAL1", 10.0);
        bare.set_float("CRVAL2", 20.0);
        assert!(SipWcs::from_header(&bare).is_none(), "no linear terms");
        assert!(SipWcs::from_header(&FitsHeader::new()).is_none());
    }

    #[test]
    fn cropping_and_rescaling_a_header_keeps_it_on_the_same_sky() {
        let order = 2u32;
        let mut wcs = sample_wcs();
        wcs.a_order = order;
        wcs.b_order = order;
        wcs.a_coeffs = sip_coeffs(order as usize);
        wcs.b_coeffs = sip_coeffs(order as usize);
        let mut header = FitsHeader::new();
        wcs.write_to_header(&mut header);
        let sky = wcs.pixel_to_world(700.0, 300.0);

        let mut cropped = header.clone();
        crop_header_wcs(&mut cropped, 100.0, 40.0);
        let cropped = SipWcs::from_header(&cropped).unwrap();
        let moved = cropped.pixel_to_world(600.0, 260.0);
        assert!((moved.0 - sky.0).abs() < 1e-12 && (moved.1 - sky.1).abs() < 1e-12);

        // Pixel (700, 300) lies in the 2x2 block whose centre is the coarse
        // pixel (349.75, 149.75), and at (1400.5, 600.5) on a 2x finer grid.
        for (scale, x, y) in [
            (GridScale::Coarser(2), 349.75, 149.75),
            (GridScale::Finer(2), 1400.5, 600.5),
        ] {
            let mut scaled = header.clone();
            rescale_header_wcs(&mut scaled, scale);
            let scaled = SipWcs::from_header(&scaled).unwrap();
            let at = scaled.pixel_to_world(x, y);
            assert!(
                (at.0 - sky.0).abs() < 1e-9 && (at.1 - sky.1).abs() < 1e-9,
                "{scale:?}: {at:?} vs {sky:?}"
            );
        }

        let mut cdelt = FitsHeader::new();
        cdelt.set_float("CDELT1", -0.001);
        rescale_header_wcs(&mut cdelt, GridScale::Coarser(2));
        assert_eq!(cdelt.get_float("CDELT1"), Some(-0.002));
        assert!(cdelt.get("CRPIX1").is_none(), "absent cards stay absent");
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

    /// A solution referenced on one side of the frame, moved to the frame
    /// center, is the same map from pixels to the sky and back.
    #[test]
    fn a_rereferenced_solution_is_the_same_projection() {
        let (width, height) = (4656.0, 3520.0);
        let solved = SipWcs {
            a_order: 2,
            b_order: 2,
            a_coeffs: vec![0.0, 0.0, -5.5e-9, 0.0, -2.0e-7, 0.0, -2.7e-7, 0.0, 0.0],
            b_coeffs: vec![0.0, 0.0, -2.1e-7, 0.0, -1.9e-7, 0.0, -4.0e-8, 0.0, 0.0],
            ..SipWcs::tan_only(
                14.6945, 61.1617, 3387.77, 2486.09, -1.49e-5, -1.705e-4, 1.705e-4, -1.5e-5,
            )
        };
        let centered = solved
            .rereferenced((width + 1.0) / 2.0, (height + 1.0) / 2.0, width, height)
            .expect("a solvable fit");
        assert_eq!((centered.crpix1, centered.crpix2), (2328.5, 1760.5));
        let center = solved.pixel_to_world(2327.5, 1759.5);
        assert_eq!((centered.crval1, centered.crval2), center);
        // The tangent point moved 13', so the CD matrix is not the old one.
        assert!((centered.cd1_1 - solved.cd1_1).abs() > 1e-8);
        for &(x, y) in &[
            (0.0, 0.0),
            (4655.0, 0.0),
            (0.0, 3519.0),
            (4655.0, 3519.0),
            (2327.5, 1759.5),
            (1000.0, 3000.0),
        ] {
            let (ra, dec) = solved.pixel_to_world(x, y);
            let (got_ra, got_dec) = centered.pixel_to_world(x, y);
            let arcsec = ((got_ra - ra) * dec.to_radians().cos()).hypot(got_dec - dec) * 3600.0;
            assert!(arcsec < 1e-6, "({x}, {y}): {arcsec:e}\"");
            let (px, py) = centered.world_to_pixel(ra, dec).expect("on the frame");
            assert!(
                (px - x).hypot(py - y) < 1e-6,
                "({x}, {y}) back as ({px}, {py})"
            );
        }
        assert!(SipWcs::tan_only(0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0)
            .rereferenced(5.0, 5.0, 10.0, 10.0)
            .is_none());
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
        let wcs = SipWcs::from_plate_solve(&r, 2000, 1500).expect("buildable");
        assert_eq!(wcs.a_order, 2);
        assert_eq!(wcs.a_coeffs, sip_coeffs(2));
        assert_eq!(
            (wcs.crpix1, wcs.crpix2),
            (1000.5, 750.5),
            "the frame's centre"
        );
        assert_eq!((wcs.cd1_1, wcs.cd2_2), (-scale_deg, scale_deg));

        // A solver that gave no CD matrix is placed by its scale and rotation.
        let scalar = PlateSolveResult {
            cd1_1: 0.0,
            cd2_2: 0.0,
            rotation: 30.0,
            ..r.clone()
        };
        let rebuilt = SipWcs::from_plate_solve(&scalar, 2000, 1500).expect("buildable");
        let pointing = SipWcs::from_pointing(200.0, 30.0, 30.0, scale, 2000, 1500);
        assert_eq!(
            [rebuilt.cd1_1, rebuilt.cd1_2, rebuilt.cd2_1, rebuilt.cd2_2],
            [
                pointing.cd1_1,
                pointing.cd1_2,
                pointing.cd2_1,
                pointing.cd2_2
            ]
        );
        assert!((rebuilt.pixel_scale_arcsec() - scale).abs() < 1e-9);

        let failed = PlateSolveResult {
            success: false,
            ..r.clone()
        };
        assert!(SipWcs::from_plate_solve(&failed, 2000, 1500).is_none());
        assert!(SipWcs::from_plate_solve(&r, 0, 1500).is_none());
        let nothing = PlateSolveResult {
            pixel_scale: 0.0,
            ..scalar
        };
        assert!(SipWcs::from_plate_solve(&nothing, 2000, 1500).is_none());
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
