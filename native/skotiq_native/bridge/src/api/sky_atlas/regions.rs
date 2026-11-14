/// Summarise a circular region of the atlas (the tiles a cone covers): aggregate
/// integration time, frame count, coverage depth, and tile tally — the numbers a
/// "Your Sky" region card shows.
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9,
///   "centerRa": 83.6, "centerDec": -5.4, "radiusDeg": 0.5 }
/// // -> { "ok": true, "tilesInRegion": 7, "tilesWithData": 5,
/// //      "totalFrames": 120, "integrationSeconds": 36000.0,
/// //      "meanCoverage": 11.3, "maxCoverage": 30.0,
/// //      "contributors": ["", "alice"], "lastFoldIso": "2026-06-19" }
/// ```
pub fn api_sky_atlas_region_info(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::regions::sky_atlas_region_info(args_json)
}

/// Report a deepening **growth curve** for a region: per-fold cumulative frame
/// count and integration time, oldest fold first, summed across the region's
/// tiles. This is the "your sky is getting deeper" timeline the dashboard plots.
///
/// ```jsonc
/// { "atlasRoot": "/…", "order": 9,
///   "centerRa": 83.6, "centerDec": -5.4, "radiusDeg": 0.5 }
/// // -> { "ok": true, "points": [
/// //        { "label": "2026-06-01", "framesAdded": 30, "secondsAdded": 9000.0,
/// //          "cumulativeFrames": 30, "cumulativeSeconds": 9000.0,
/// //          "contributor": "" }, … ],
/// //      "totalFrames": 120, "totalSeconds": 36000.0 }
/// ```
pub fn api_sky_atlas_growth(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::regions::sky_atlas_growth(args_json)
}

/// Merge a contributor delta accumulator into a base accumulator (or retract it),
/// the linear-additive federation operation the keystone proves exact:
///
/// ```jsonc
/// { "basePath": "/…/hub/tiles/9/42.skt", "deltaPath": "/…/delta_42.skt",
///   "trust": 0.85, "subtract": false, "outPath": "/…/hub/tiles/9/42.skt" }
/// // -> { "ok": true, "tileId": 42, "totalFramesAfter": 130,
/// //      "integrationSecondsAfter": 39000.0, "contributorsAfter": 7 }
/// ```
pub fn api_sky_atlas_merge_delta(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::regions::sky_atlas_merge_delta(args_json)
}
