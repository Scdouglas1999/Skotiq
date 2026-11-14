//! FFI entry points for background extraction, deconvolution and star reduction.
//!
//! The work is in [`skotiq_processing::finishing::enhance`].

/// Fit a star-masked, low-order polynomial background model and write the
/// background-subtracted (flattened) frame as a linear `F32` FITS master.
///
/// `args_json` is an [`ExtractBackgroundArgs`]; the result is an
/// [`ExtractBackgroundResult`] carrying the fitted polynomial degree, channel
/// count, and per-channel mean level (the pedestal preserved when
/// `preserveMean` is set). Wraps
/// [`background_extraction::extract_and_subtract`]. Every failure — unreadable
/// input, an empty frame, an unsupported polynomial degree, too few clean
/// background samples, a singular fit, or a write error — surfaces as
/// `Err(String)`.
pub fn api_extract_background(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::enhance::extract_background(args_json)
}

/// Estimate (or accept) a PSF and run bounded, regularized Richardson–Lucy
/// deconvolution, writing the restored frame.
///
/// `args_json` is a [`DeconvolvePreviewArgs`]; the result is a
/// [`DeconvolvePreviewResult`] reporting the PSF actually used (kind, FWHM,
/// Moffat β, kernel side). When `estimatePsf` is true (the default) the PSF is
/// derived from the frame's own stars via [`deconvolution::estimate_psf`];
/// otherwise a [`PsfModel`] is rendered from the supplied analytic parameters.
/// Wraps [`deconvolution::richardson_lucy`]. The output preserves the input
/// pixel type. Every failure — unreadable input, an empty frame, too few usable
/// stars for estimation, a malformed PSF, or a write error — surfaces as
/// `Err(String)`.
pub fn api_deconvolve_preview(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::enhance::deconvolve_preview(args_json)
}

/// Mask-confined star-size reduction preview, writing the reduced frame.
///
/// `args_json` is a [`ReduceStarsPreviewArgs`]; the result is a
/// [`ReduceStarsPreviewResult`] with the output path. Wraps
/// [`star_reduction::reduce_stars`] (morphological erosion or screened
/// residual, confined to a soft star mask that leaves the background
/// byte-identical). The output preserves the input pixel type. Every failure —
/// unreadable input, an empty frame, an out-of-range strength, or a write
/// error — surfaces as `Err(String)`.
pub fn api_reduce_stars_preview(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::enhance::reduce_stars_preview(args_json)
}
