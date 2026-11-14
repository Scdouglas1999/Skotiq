//! FFI entry point for drizzle integration.
//!
//! The work is in [`skotiq_processing::finishing::combine`].

/// Drizzle (variable-pixel linear reconstruction) a population of registered
/// frames onto a `scale`× output grid.
///
/// Each frame is read from FITS, its 3×3 source→reference transform is rebuilt
/// into a [`TransformModel`], and its pixels are deposited as `pixfrac`-shrunk
/// drops via [`drizzle_integrate`] (RGB / mono) or [`bayer_drizzle_integrate`]
/// (raw CFA mosaic → 3-channel RGB, when `bayer == true`). The reconstructed
/// `F32` master is written to `output_fits`; when `coverage_fits` is given the
/// per-pixel drizzle-weight map is written there too.
///
/// `args_json` is a [`DrizzleIntegrateArgs`]; the result is a
/// [`DrizzleIntegrateResult`]. Every failure surfaces as `Err(String)` rather
/// than a partial stack.
pub fn api_drizzle_integrate(args_json: String) -> Result<String, String> {
    skotiq_processing::finishing::combine::drizzle_integrate(args_json)
}
