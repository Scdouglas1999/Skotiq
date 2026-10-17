//! The photometry the caller lends a render.
//!
//! Nothing photometric ships in a form the native side can read on its own: the
//! HYG catalogue is downloaded on demand and the APASS query is a Dart service.
//! A render therefore takes its stars from the caller, already resolved, and
//! attaches them as the render's catalogue. When the caller has none,
//! `color_calibrate` finds no catalogue and records itself as explicitly
//! skipped with that reason — the fresh-install case, stated rather than passed
//! through as if the calibration had run.

use std::sync::Arc;

use skotiq_imaging::recipe::{fingerprint_hex, CatalogError, CatalogStar, PhotometryCatalog};

use super::args::CatalogStarArgs;

/// A catalogue over a fixed star list supplied with the render request.
pub(crate) struct SuppliedCatalog {
    /// Stars in a fixed order: sorted by right ascension, then declination, then
    /// V magnitude. The order is part of the determinism contract, so it is
    /// established here rather than inherited from the caller's list order.
    stars: Vec<CatalogStar>,
}

impl SuppliedCatalog {
    /// The catalogue for `stars`, or `None` when the caller supplied none.
    ///
    /// A star whose coordinates, magnitude or colour is not finite is left out:
    /// a non-finite sample reaching the colour fit is indistinguishable from a
    /// measurement, and the fit would carry it into every pixel.
    pub(crate) fn new(stars: &[CatalogStarArgs]) -> Option<Self> {
        let mut usable: Vec<CatalogStar> = stars
            .iter()
            .filter(|star| {
                star.ra_deg.is_finite()
                    && star.dec_deg.is_finite()
                    && star.v_mag.is_finite()
                    && star.b_minus_v.is_finite()
            })
            .map(|star| CatalogStar {
                ra_deg: star.ra_deg,
                dec_deg: star.dec_deg,
                v_mag: star.v_mag,
                b_minus_v: star.b_minus_v,
            })
            .collect();
        if usable.is_empty() {
            return None;
        }
        usable.sort_by(|a, b| {
            a.ra_deg
                .total_cmp(&b.ra_deg)
                .then_with(|| a.dec_deg.total_cmp(&b.dec_deg))
                .then_with(|| a.v_mag.total_cmp(&b.v_mag))
        });
        Some(Self { stars: usable })
    }

    /// The catalogue as the handle an [`OpContext`](skotiq_imaging::recipe::OpContext)
    /// carries.
    pub(crate) fn into_handle(self) -> Arc<dyn PhotometryCatalog> {
        Arc::new(self)
    }

    /// Number of usable stars the catalogue holds.
    pub(crate) fn len(&self) -> usize {
        self.stars.len()
    }
}

impl PhotometryCatalog for SuppliedCatalog {
    /// A digest of every star this catalogue would answer with, in the fixed
    /// order [`SuppliedCatalog::new`] established.
    ///
    /// The engine folds it into the render cache key, so a request that carries
    /// a different star list cannot be served a boundary the previous one
    /// produced — the mistake that would otherwise show the first render's
    /// colours under the second render's photometry.
    fn identity(&self) -> String {
        let mut text = String::with_capacity(self.stars.len() * 48);
        for star in &self.stars {
            text.push_str(&format!(
                "{},{},{},{};",
                star.ra_deg, star.dec_deg, star.v_mag, star.b_minus_v
            ));
        }
        fingerprint_hex(text.as_bytes())
    }

    fn cone_search(
        &self,
        ra_deg: f64,
        dec_deg: f64,
        radius_deg: f64,
        mag_limit: f64,
    ) -> Result<Vec<CatalogStar>, CatalogError> {
        if !ra_deg.is_finite() || !dec_deg.is_finite() || !radius_deg.is_finite() {
            return Err(CatalogError::QueryFailed {
                reason: format!(
                    "cone search asked for a non-finite field: ra={ra_deg}, dec={dec_deg}, radius={radius_deg}"
                ),
            });
        }
        let matched: Vec<CatalogStar> = self
            .stars
            .iter()
            .filter(|star| {
                star.v_mag <= mag_limit
                    && angular_separation_deg(ra_deg, dec_deg, star.ra_deg, star.dec_deg)
                        <= radius_deg
            })
            .cloned()
            .collect();
        Ok(matched)
    }
}

/// Great-circle separation in degrees, by the haversine form, which stays
/// accurate for the small separations a frame subtends.
fn angular_separation_deg(ra_a: f64, dec_a: f64, ra_b: f64, dec_b: f64) -> f64 {
    let ra_a = ra_a.to_radians();
    let dec_a = dec_a.to_radians();
    let ra_b = ra_b.to_radians();
    let dec_b = dec_b.to_radians();
    let d_ra = (ra_b - ra_a) / 2.0;
    let d_dec = (dec_b - dec_a) / 2.0;
    let h = d_dec.sin().powi(2) + dec_a.cos() * dec_b.cos() * d_ra.sin().powi(2);
    (2.0 * h.sqrt().clamp(-1.0, 1.0).asin()).to_degrees()
}
