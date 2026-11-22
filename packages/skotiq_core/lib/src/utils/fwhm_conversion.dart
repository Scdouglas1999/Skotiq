// Shared PSF-size conversion.

/// FWHM as a multiple of HFR, for a Gaussian PSF.
///
/// HFR is the encircled-energy half-flux RADIUS (the NINA / SGP / PixInsight
/// convention), i.e. sigma * sqrt(2 ln 2) = 1.177 * sigma, while
/// FWHM = 2 * sigma * sqrt(2 ln 2). So FWHM = 2.000 * HFR.
///
/// The native measurement path carries the same value (`FWHM_TO_HFR_RATIO` in
/// `imaging/src/stats.rs`).
const double kFwhmPerHfr = 2.0;
