//! FFI entry point for stitching mosaic panels.
//!
//! The work is in [`skotiq_processing::mosaic`].

/// Stitch N plate-solved panel masters into one mosaic master.
///
/// Each panel is read from FITS; its WCS is taken from the explicit `wcs` block
/// when supplied, else parsed from the header CD matrix (with a `CDELT`/`CROTA`
/// fallback). The panels are projected onto a common gnomonic canvas, optionally
/// photometrically normalized over their overlaps, and feather-blended into one
/// `F32` master via [`stitch_mosaic`]. The master is written to
/// `output.mosaicFitsPath` with the output canvas WCS stamped in the header;
/// when `coverageFitsPath` / `previewPngPath` are given the coverage plane /
/// stretched preview are written too.
///
/// `args_json` is a [`StitchMosaicArgs`]; the result is a [`StitchMosaicResult`].
/// Every failure surfaces as `Err(String)` rather than a partial mosaic.
pub fn api_stitch_mosaic(args_json: String) -> Result<String, String> {
    skotiq_processing::mosaic::stitch_mosaic(args_json)
}
