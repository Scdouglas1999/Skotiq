//! Header cards an exported master carries so PixInsight and other tools can
//! use it without re-entering the optics or re-solving the field.

use skotiq_imaging::{
    copy_header_cards, is_instrument_keyword, read_frame_header, replace_astrometry_headers,
    FitsHeader,
};
use std::path::Path;

/// The typed header of `path` in any format the app reads, or `None` for a
/// file that is no frame or cannot be read.
pub(crate) fn fits_header_of(path: &str) -> Option<FitsHeader> {
    let p = Path::new(path.trim());
    skotiq_imaging::is_frame_path(p)
        .then(|| read_frame_header(p).ok())
        .flatten()
}

/// Copy onto `header` the cards of `source` that stay true of a master or
/// composite made from it: the instrument and site, where the field is, and
/// when its first frame was taken.
pub(crate) fn copy_optics_cards(header: &mut FitsHeader, source: &FitsHeader) {
    copy_header_cards(header, source, |key| {
        is_instrument_keyword(key)
            || matches!(key, "OBJCTRA" | "OBJCTDEC" | "RA" | "DEC" | "DATE-OBS")
    });
}

/// Whether `header` holds a celestial WCS.
pub(crate) fn has_wcs(header: &FitsHeader) -> bool {
    header
        .get_string("CTYPE1")
        .is_some_and(|t| t.contains("RA"))
        && header.get_float("CRVAL1").is_some()
        && header.get_float("CRVAL2").is_some()
}

pub(crate) struct WcsAttachment {
    pub(crate) description: String,
    pub(crate) inherited: bool,
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
) -> Option<WcsAttachment> {
    if let Some(grid) = fits_header_of(grid_path).filter(has_wcs) {
        replace_astrometry_headers(header, &grid);
        return Some(WcsAttachment {
            description: format!("WCS of the grid reference {}", grid_path.trim()),
            inherited: true,
        });
    }
    let sidecar = Path::new(grid_path.trim()).with_extension("wcs");
    if let Some(solve) = read_frame_header(&sidecar).ok().filter(has_wcs) {
        replace_astrometry_headers(header, &solve);
        return Some(WcsAttachment {
            description: format!("WCS from {}", sidecar.display()),
            inherited: true,
        });
    }
    let solver = skotiq_platesolve::AstapSolver::with_default_config()?;
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
    skotiq_imaging::SipWcs::from_plate_solve(&result, w, h)?.write_to_header(header);
    Some(WcsAttachment {
        description: "ASTAP solve of the integrated master".to_string(),
        inherited: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A master on a solved reference's grid takes the reference's whole
    /// solution, reference system and projection parameters included, and
    /// none of an earlier one.
    #[test]
    fn a_master_takes_the_whole_solution_of_its_reference() {
        let mut reference = FitsHeader::new();
        reference.set_int("WCSAXES", 2);
        reference.set_string("CTYPE1", "RA---TAN");
        reference.set_string("CTYPE2", "DEC--TAN");
        reference.set_string("RADECSYS", "FK5");
        for (key, value) in [
            ("CRVAL1", 10.0),
            ("CRVAL2", 41.0),
            ("CRPIX1", 2072.5),
            ("CRPIX2", 1411.5),
            ("CD1_1", -2.8e-4),
            ("CD1_2", 0.0),
            ("CD2_1", 0.0),
            ("CD2_2", 2.8e-4),
            ("PV1_1", 0.0),
        ] {
            reference.set_float(key, value);
        }
        reference.set_string("TELESCOP", "Esprit 100");
        reference.set_float("XPIXSZ", 3.76);
        reference.set_float("AIRMASS", 1.2);
        reference.set_float("EXPOSURE", 300.0);

        let mut master = FitsHeader::new();
        master.set_float("PC1_1", 1.0);
        master.set_float("A_2_0", 1e-6);
        master.set_float("EXPTIME", 7200.0);
        copy_optics_cards(&mut master, &reference);
        replace_astrometry_headers(&mut master, &reference);

        for key in ["WCSAXES", "RADECSYS", "PV1_1", "CD1_1", "TELESCOP", "XPIXSZ"] {
            assert!(master.get(key).is_some(), "{key}");
        }
        for key in ["PC1_1", "A_2_0", "AIRMASS", "EXPOSURE"] {
            assert!(master.get(key).is_none(), "{key}");
        }
        assert_eq!(master.get_float("EXPTIME"), Some(7200.0));
    }
}
