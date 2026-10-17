// Shared PSF-size conversion.

/// FWHM as a multiple of HFR, for a Gaussian PSF.
///
/// HFR is the encircled-energy half-flux RADIUS (the NINA / SGP / PixInsight
/// convention), i.e. sigma * sqrt(2 ln 2) = 1.177 * sigma, while
/// FWHM = 2 * sigma * sqrt(2 ln 2). So FWHM = 2.000 * HFR.
///
/// This was 2.3548 in four places, which is the sigma -> FWHM factor applied to
/// a radius: it overstated every derived FWHM by 17.7%. The native measurement
/// path already carries the correct value (`FWHM_TO_HFR_RATIO` in
/// `imaging/src/stats.rs`), so the exported number disagreed with the measured
/// one written into the same session's FITS headers.
const double kFwhmPerHfr = 2.0;
