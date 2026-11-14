//! FFI entry points for night analysis, star photometry and color calibration.
//!
//! The work is in [`skotiq_processing::finishing::analyze`].

/// Predict the marginal-SNR integration curve and a keep/cull subset
/// recommendation from per-sub quality descriptors + weights.
///
/// This wraps [`optimizer::integration_curve`](skotiq_imaging::optimizer::integration_curve)
/// and [`optimizer::recommend_subset`](skotiq_imaging::optimizer::recommend_subset):
/// it is a *pure analytic predictor* — no pixels are integrated. The only hard
/// error is a `qualities`/`weights` length mismatch (the project idiom: refuse
/// inconsistent parallel arrays rather than best-effort on them).
///
/// `args_json` is an [`AnalyzeNightArgs`]; the result is an
/// [`AnalyzeNightResult`].
pub fn api_analyze_night(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::analyze::analyze_night(args_json)
}

/// Detect stars on a master and measure each one's per-channel background-
/// subtracted aperture flux.
///
/// Pipeline: read the master → derive a mono U16 detection plane (the star
/// detector is single-channel: for an RGB master it averages the channels into a
/// luminance plane, mirroring `post_session::aligned_quality`) → `detect_stars`
/// with the production [`StarDetectionConfig`] defaults → for every detection,
/// measure aperture flux in *each* original channel of the master (sum inside a
/// small circular aperture minus a local-median background, evaluated on the
/// native pixel buffer so the photometry is faithful to the linear master).
///
/// The per-channel flux vector is what the Dart side cross-matches against a
/// photometric catalogue; this function deliberately does **not** know the
/// catalogue.
///
/// `args_json` is a [`DetectStarsPhotometryArgs`]; the result is a
/// [`DetectStarsPhotometryResult`].
pub fn api_detect_stars_photometry(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::analyze::detect_stars_photometry(args_json)
}

/// Solve a per-channel white balance from the Dart-matched colour-indexed stars
/// and apply it to a master, writing the rebalanced linear FITS.
///
/// Wraps [`solve_color_calibration`](skotiq_imaging::color_calibration::solve_color_calibration)
/// (Theil–Sen + Tukey-biweight robust per-channel colour-vs-flux fit) then
/// [`apply_color_calibration`](skotiq_imaging::color_calibration::apply_color_calibration).
/// All solver errors (too few stars, channel mismatch, degenerate fit) surface
/// as `Err(String)` — a confidently-wrong white balance is never silently
/// applied, since it would tint every downstream frame.
///
/// `args_json` is a [`ColorCalibrateArgs`]; the result is a
/// [`ColorCalibrateResult`].
pub fn api_color_calibrate(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::analyze::color_calibrate(args_json)
}
