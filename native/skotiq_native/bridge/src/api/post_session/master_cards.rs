//! Header cards an exported master carries so PixInsight and other tools can
//! use it without re-entering the optics or re-solving the field.

use super::*;
use skotiq_imaging::FitsValue;

/// Acquisition and optics cards copied from a sub of the master's own filter.
const OPTICS_CARDS: &[&str] = &[
    "TELESCOP", "INSTRUME", "FOCALLEN", "APTDIA", "APTAREA", "XPIXSZ", "YPIXSZ", "PIXSIZE",
    "XBINNING", "YBINNING", "GAIN", "EGAIN", "OFFSET", "CCD-TEMP", "SET-TEMP", "SITELAT",
    "SITELONG", "SITEELEV", "OBJCTRA", "OBJCTDEC", "RA", "DEC", "DATE-OBS", "OBSERVER",
];

/// Linear WCS cards, valid for every master on the reference grid.
const WCS_CARDS: &[&str] = &[
    "CTYPE1", "CTYPE2", "CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD1_2", "CD2_1", "CD2_2",
    "CDELT1", "CDELT2", "CROTA1", "CROTA2", "PC1_1", "PC1_2", "PC2_1", "PC2_2", "CUNIT1", "CUNIT2",
    "EQUINOX", "RADESYS", "LONPOLE", "LATPOLE",
];

fn copy_card(to: &mut FitsHeader, from: &FitsHeader, key: &str) -> bool {
    match from.get(key) {
        Some(FitsValue::String(v)) => to.set_string(key, v),
        Some(FitsValue::Integer(v)) => to.set_int(key, *v),
        Some(FitsValue::Float(v)) => to.set_float(key, *v),
        Some(FitsValue::Boolean(v)) => to.set_bool(key, *v),
        _ => return false,
    }
    true
}

/// The typed FITS header of `path`, or `None` for a non-FITS or unreadable file.
pub(crate) fn fits_header_of(path: &str) -> Option<FitsHeader> {
    let p = Path::new(path.trim());
    let ext = p.extension()?.to_str()?.to_ascii_lowercase();
    matches!(ext.as_str(), "fits" | "fit" | "fts")
        .then(|| read_fits_header(p).ok())
        .flatten()
}

/// Copy the optics and site cards of `source` onto `header`.
pub(crate) fn copy_optics_cards(header: &mut FitsHeader, source: &FitsHeader) {
    for key in OPTICS_CARDS {
        copy_card(header, source, key);
    }
}

/// Whether `header` holds a celestial WCS.
pub(crate) fn has_wcs(header: &FitsHeader) -> bool {
    header
        .get_string("CTYPE1")
        .is_some_and(|t| t.contains("RA"))
        && header.get_float("CRVAL1").is_some()
        && header.get_float("CRVAL2").is_some()
}

/// Copy the WCS of `source`, including any SIP distortion terms.
pub(crate) fn copy_wcs(header: &mut FitsHeader, source: &FitsHeader) {
    for key in WCS_CARDS {
        copy_card(header, source, key);
    }
    let sip: Vec<String> = source
        .keywords
        .keys()
        .filter(|k| {
            let mut parts = k.splitn(2, '_');
            matches!(parts.next(), Some("A" | "B" | "AP" | "BP"))
                && parts.next().is_some_and(|rest| {
                    rest == "ORDER" || rest.split('_').all(|n| n.parse::<u32>().is_ok())
                })
        })
        .cloned()
        .collect();
    for key in sip {
        copy_card(header, source, &key);
    }
}

/// Give a master on the grid of `grid_path` a WCS, and say where it came from.
///
/// Every master is resampled onto the grid reference, so the reference's own
/// solve describes it: from the reference's header, or from the `.wcs` file
/// ASTAP writes beside a solved frame. Failing both, the written master is
/// solved with ASTAP when it is installed. `None` when no WCS could be found.
pub(crate) fn attach_wcs(
    header: &mut FitsHeader,
    grid_path: &str,
    master_path: &Path,
    size: (u32, u32),
) -> Option<String> {
    if let Some(grid) = fits_header_of(grid_path).filter(has_wcs) {
        copy_wcs(header, &grid);
        return Some(format!("WCS of the grid reference {}", grid_path.trim()));
    }
    let sidecar = Path::new(grid_path.trim()).with_extension("wcs");
    if let Some(solve) = read_fits_header(&sidecar).ok().filter(has_wcs) {
        copy_wcs(header, &solve);
        return Some(format!("WCS from {}", sidecar.display()));
    }
    let solver = skotiq_imaging::AstapSolver::with_default_config()?;
    let hint = |key: &str| header.get_float(key);
    let result = solver.solve(master_path, hint("RA"), hint("DEC"), None);
    if !result.success || result.cd1_1 == 0.0 {
        tracing::info!(
            "no WCS for '{}': ASTAP could not solve it ({})",
            master_path.display(),
            result.error.unwrap_or_default()
        );
        return None;
    }
    let (w, h) = size;
    let mut wcs = WcsInfo::from_plate_solve(
        result.ra,
        result.dec,
        result.rotation,
        result.pixel_scale,
        w,
        h,
    );
    wcs.cd1_1 = result.cd1_1;
    wcs.cd1_2 = result.cd1_2;
    wcs.cd2_1 = result.cd2_1;
    wcs.cd2_2 = result.cd2_2;
    add_wcs_headers(header, &wcs);
    Some("ASTAP solve of the integrated master".to_string())
}
