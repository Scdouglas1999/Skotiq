/// Fold a single plate-solved capture into the atlas. A thin convenience over the
/// `"fold"` action for the common one-frame case — the same JSON shape minus the
/// `frames` array wrapper:
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9, "contributor": "", "interp": "lanczos3",
///   "label": "2026-06-19", "framePath": "/…/light_001.fits",
///   "weight": 1.0, "exposureSec": 300.0, "wcs": <SipWcs JSON>,
///   "onlineClipLow": 4.0, "onlineClipHigh": 4.0 /* optional */ }
/// ```
/// Returns the same [`FoldResult`] JSON as the dispatcher's `"fold"` action.
pub fn api_sky_atlas_add_frame(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::frames::sky_atlas_add_frame(args_json)
}

/// Co-add a cone of the atlas into a finalized, sharable cutout (FITS + optional
/// PNG) and report its statistics:
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9,
///   "centerRa": 83.6, "centerDec": -5.4, "radiusDeg": 0.5,
///   "channels": 1, "outPixels": 2048, "interp": "lanczos3",
///   "fitsPath": "/…/cutout.fits", "pngPath": "/…/cutout.png" /* optional */ }
/// // -> { "ok": true, "fitsPath": "…", "pngPath": "…", "width": …, "height": …,
/// //      "channels": …, "coveredFraction": 0.97, "meanCoverage": 11.3,
/// //      "maxCoverage": 30.0, "tilesUsed": 7 }
/// ```
pub fn api_sky_atlas_query_cutout(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::frames::sky_atlas_query_cutout(args_json)
}
