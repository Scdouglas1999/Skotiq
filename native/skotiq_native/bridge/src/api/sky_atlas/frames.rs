use super::*;

// Named convenience wrappers over the api_sky_atlas actions

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
    let one: AddFrameArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid addFrame args: {e}"))?;
    let fold = FoldArgs {
        atlas_root: one.atlas_root,
        order: one.order,
        contributor: one.contributor,
        interp: one.interp,
        label: one.label,
        online_clip_low: one.online_clip_low,
        online_clip_high: one.online_clip_high,
        frames: vec![FoldFrameArgs {
            frame_path: one.frame_path,
            weight: one.weight,
            exposure_sec: one.exposure_sec,
            wcs: one.wcs,
        }],
    };
    let result = fold_impl(fold)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct AddFrameArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    #[serde(default)]
    pub(crate) contributor: String,
    #[serde(default)]
    pub(crate) interp: String,
    #[serde(default)]
    pub(crate) label: String,
    #[serde(default)]
    pub(crate) online_clip_low: Option<f64>,
    #[serde(default)]
    pub(crate) online_clip_high: Option<f64>,
    pub(crate) frame_path: String,
    #[serde(default = "default_weight")]
    pub(crate) weight: f64,
    #[serde(default)]
    pub(crate) exposure_sec: f64,
    pub(crate) wcs: SipWcs,
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
    let args: QueryCutoutArgs =
        serde_json::from_str(&args_json).map_err(|e| format!("invalid queryCutout args: {e}"))?;
    let result = query_cutout_impl(args)?;
    serde_json::to_string(&result).map_err(|e| format!("failed to encode result: {e}"))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct QueryCutoutArgs {
    pub(crate) atlas_root: String,
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    pub(crate) center_ra: f64,
    pub(crate) center_dec: f64,
    pub(crate) radius_deg: f64,
    #[serde(default = "default_channels")]
    pub(crate) channels: u32,
    #[serde(default = "default_out_pixels")]
    pub(crate) out_pixels: u32,
    #[serde(default)]
    pub(crate) interp: String,
    /// Output FITS path for the co-added `F32` cutout (required).
    pub(crate) fits_path: String,
    /// Optional stretched preview PNG path.
    #[serde(default)]
    pub(crate) png_path: Option<String>,
}

pub(crate) fn default_channels() -> u32 {
    1
}

pub(crate) fn default_out_pixels() -> u32 {
    2048
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct QueryCutoutResult {
    pub(crate) ok: bool,
    pub(crate) fits_path: String,
    pub(crate) png_path: Option<String>,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) channels: u32,
    /// Fraction of output pixels with any coverage.
    pub(crate) covered_fraction: f64,
    /// Mean coverage depth over covered pixels.
    pub(crate) mean_coverage: f64,
    /// Maximum coverage depth seen.
    pub(crate) max_coverage: f64,
    /// Number of tiles that contributed to the cutout.
    pub(crate) tiles_used: usize,
}

pub(crate) fn query_cutout_impl(args: QueryCutoutArgs) -> Result<QueryCutoutResult, String> {
    if args.fits_path.trim().is_empty() {
        return Err("queryCutout requires fitsPath".to_string());
    }
    if args.radius_deg <= 0.0 {
        return Err("queryCutout requires a positive radiusDeg".to_string());
    }
    let atlas = open_atlas(&args.atlas_root, args.order)?;
    let interp = parse_interp(&args.interp)?;

    let (cutout, coverage) = atlas
        .query_cone(
            args.center_ra,
            args.center_dec,
            args.radius_deg,
            args.channels,
            args.out_pixels,
            interp,
        )
        .map_err(|e| describe_atlas_error(&e))?;

    // Coverage statistics over the output grid.
    let cov = coverage
        .as_f32()
        .ok_or_else(|| "coverage map is not F32".to_string())?;
    let mut covered = 0usize;
    let mut sum_cov = 0.0f64;
    let mut max_cov = 0.0f64;
    for &c in &cov {
        if c > 0.0 {
            covered += 1;
            sum_cov += c as f64;
            if (c as f64) > max_cov {
                max_cov = c as f64;
            }
        }
    }
    let covered_fraction = if cov.is_empty() {
        0.0
    } else {
        covered as f64 / cov.len() as f64
    };
    let mean_coverage = if covered > 0 {
        sum_cov / covered as f64
    } else {
        0.0
    };

    // Build the cutout's output WCS for the FITS header (same TAN grid the query
    // co-adds onto: centred on the cone, spanning 2·radius + margin).
    let out_w = args.out_pixels.max(1) as f64;
    let span_deg = 2.0 * args.radius_deg * 1.08;
    let scale_deg = span_deg / out_w;
    let crpix = out_w / 2.0 + 0.5;
    let out_wcs = WcsInfo {
        crval1: args.center_ra,
        crval2: args.center_dec,
        crpix1: crpix,
        crpix2: crpix,
        cd1_1: -scale_deg,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: scale_deg,
    };

    let path = Path::new(&args.fits_path);
    ensure_parent_dir(path)?;
    let mut header = FitsHeader::new();
    header.set_string("IMAGETYP", "MASTER_LIGHT");
    header.set_string("CALSTAT", "Skotiq sky-atlas cutout");
    add_wcs_headers(&mut header, &out_wcs);
    header.add_history(&format!(
        "Sky-atlas cone cutout: RA {:.4} Dec {:.4} radius {:.4}deg, mean coverage {:.2}",
        args.center_ra, args.center_dec, args.radius_deg, mean_coverage
    ));
    write_fits(path, &cutout, &header)
        .map_err(|e| format!("failed to write cutout FITS: {e:?}"))?;

    let png_path = match args.png_path.as_ref() {
        Some(p) if !p.trim().is_empty() => {
            let pp = Path::new(p);
            ensure_parent_dir(pp)?;
            write_preview_png(&cutout, pp)?;
            Some(p.clone())
        }
        _ => None,
    };

    // Tile count that intersected the cone (the same enumeration the query used).
    let tiles_used = skotiq_imaging::sky_atlas::tile_ids_for_cone(
        args.center_ra,
        args.center_dec,
        args.radius_deg,
        args.order,
    )
    .into_iter()
    .filter(|&tid| {
        atlas
            .load_tile(tid)
            .ok()
            .flatten()
            .is_some_and(|t| t.coverage_mean() > 0.0)
    })
    .count();

    Ok(QueryCutoutResult {
        ok: true,
        fits_path: args.fits_path,
        png_path,
        width: cutout.width,
        height: cutout.height,
        channels: cutout.channels,
        covered_fraction,
        mean_coverage,
        max_coverage: max_cov,
        tiles_used,
    })
}
