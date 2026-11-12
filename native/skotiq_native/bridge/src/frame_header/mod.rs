//! The FITS header of every frame Skotiq saves. A sequence's frame and a
//! manual capture both arrive as a `FrameContext` filled by the sequencer's
//! `sample_frame_context`, so their cards differ only in the ones that tie a
//! frame to a run; the temporary frame handed to the plate solver is built
//! here directly. All of them get their cards from
//! [`FrameHeader::fits_header`].
//!
//! A frame records what is known about it: an optional field that is `None`
//! leaves its keyword out rather than writing a placeholder.

use crate::error::SkotiqError;
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_frame_with, FitsHeader, ImageData,
};
use skotiq_sequencer::scheduling::{DefectMapCorrectionRecord, FrameContext};

/// What is known about one frame when it is written to disk.
#[derive(Debug, Clone, Default)]
pub(crate) struct FrameHeader {
    pub object_name: Option<String>,
    pub exposure_time: f64,
    /// UTC start of the exposure, written as `DATE-OBS`.
    pub capture_timestamp: String,
    pub frame_type: String,
    pub filter: Option<String>,
    pub filter_position: Option<i32>,
    pub gain: Option<i32>,
    /// `gain` is an ISO speed, also written as `ISOSPEED` (Siril, PixInsight).
    pub gain_is_iso: bool,
    pub offset: Option<i32>,
    pub ccd_temp: Option<f64>,
    pub set_temp: Option<f64>,
    /// Hours.
    pub ra: Option<f64>,
    pub dec: Option<f64>,
    /// `ra`/`dec` are J2000, and `EQUINOX`/`RADESYS` say so. Every saved
    /// frame's are; the plate solver's temporary frame carries a search hint
    /// and is written without them.
    pub pointing_is_j2000: bool,
    pub altitude: Option<f64>,
    pub telescope: Option<String>,
    pub instrument: Option<String>,
    pub observer: Option<String>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub focal_length: Option<f64>,
    pub aperture: Option<f64>,
    /// Unbinned pitch in microns: `XPIXSZ`/`YPIXSZ` are this times the binning.
    pub pixel_size_x: Option<f64>,
    pub pixel_size_y: Option<f64>,
    pub site_latitude: Option<f64>,
    pub site_longitude: Option<f64>,
    pub site_elevation: Option<f64>,
    pub focuser_position: Option<i32>,
    pub focuser_temperature: Option<f64>,
    pub rotator_angle: Option<f64>,
    pub guide_rms_arcsec: Option<f64>,
    pub solved_ra_hours: Option<f64>,
    pub solved_dec_degrees: Option<f64>,
    pub plate_solve_pixel_scale_arcsec: Option<f64>,
    pub plate_solve_rotation_deg: Option<f64>,
    /// "RGGB", "BGGR", ...
    pub bayer_pattern: Option<String>,
    pub session_id: Option<String>,
    /// 1-based position in the burst.
    pub frame_index: Option<u32>,
    pub total_planned_frames: Option<u32>,
    pub mosaic_name: Option<String>,
    /// 0-based.
    pub mosaic_panel_index: Option<i32>,
    pub mosaic_panel_row: Option<i32>,
    pub mosaic_panel_column: Option<i32>,
    pub mosaic_total_panels: Option<i32>,
    /// Written as a HISTORY card so the cosmetic correction is visible in any
    /// FITS viewer and is not applied twice.
    pub defect_map_correction: Option<DefectMapCorrectionRecord>,
    pub photometry_object_catalog: Option<String>,
    /// Comma-separated catalogue ids.
    pub photometry_reference_stars: Option<String>,
    pub photometry_mjd_obs: Option<f64>,
    pub photometry_instrumental_mag: Option<f64>,
    pub photometry_differential_mag: Option<f64>,
    pub photometry_fwhm_arcsec: Option<f64>,
    pub photometry_snr: Option<f64>,
    /// Optical train of a multi-camera session.
    pub rig_label: Option<String>,
    /// "East" or "West": the field turns by 180 degrees across a flip.
    pub pier_side: Option<String>,
}

impl FrameHeader {
    /// The header of a frame a sequence captured, from the context the
    /// sequencer recorded for it.
    pub(crate) fn from_frame_context(ctx: &FrameContext) -> Self {
        let instrument = match (ctx.camera_make.as_deref(), ctx.camera_model.as_deref()) {
            (Some(make), Some(model)) => Some(format!("{} {}", make, model)),
            (Some(s), None) | (None, Some(s)) => Some(s.to_string()),
            (None, None) => None,
        };

        // Where the telescope was, falling back to where the sequence meant to
        // be. Taken as a pair: half a mount pointing and half a target's is a
        // coordinate that was never true of anything, and the altitude below
        // is derived from the same pair.
        let (ra, dec) = match ctx.recorded_pointing() {
            Some((ra_hours, dec_degrees)) => (Some(ra_hours), Some(dec_degrees)),
            None => (None, None),
        };

        Self {
            object_name: ctx.target_name.clone(),
            exposure_time: ctx.duration_secs,
            // DATE-OBS is the start of the exposure; the clock (which runs
            // after readout here) only when the capture recorded no start.
            capture_timestamp: ctx
                .exposure_started_at
                .unwrap_or_else(chrono::Utc::now)
                .format("%Y-%m-%dT%H:%M:%S")
                .to_string(),
            frame_type: ctx.frame_type.clone(),
            filter: ctx.filter_name.clone(),
            filter_position: ctx.filter_index,
            gain: ctx.gain,
            gain_is_iso: ctx.gain_is_iso,
            offset: ctx.offset,
            ccd_temp: ctx.sensor_temp_c,
            set_temp: ctx.set_temp_c,
            ra,
            dec,
            // The sequencer records the mount's pointing in J2000.
            pointing_is_j2000: true,
            // The altitude of the pointing selected just above — the mount's
            // when it was read, otherwise the target's, computed from the site
            // and the exposure midpoint. `recorded_altitude_deg` keeps OBJCTALT
            // and AIRMASS describing the same direction as the RA/DEC cards by
            // construction, including on a rig imaging without a mount attached.
            altitude: ctx.recorded_altitude_deg(),
            telescope: ctx.telescope_name.clone(),
            instrument,
            observer: ctx.observer_name.clone(),
            bin_x: ctx.binning_x as i32,
            bin_y: ctx.binning_y as i32,
            focal_length: ctx.telescope_focal_length_mm,
            aperture: ctx.telescope_aperture_mm,
            pixel_size_x: ctx.camera_pixel_size_x_um,
            pixel_size_y: ctx.camera_pixel_size_y_um,
            site_latitude: ctx.site_latitude_deg,
            site_longitude: ctx.site_longitude_deg,
            site_elevation: ctx.site_elevation_m,
            focuser_position: ctx.focuser_position,
            focuser_temperature: ctx.focuser_temperature_c,
            rotator_angle: ctx.rotator_angle_deg,
            guide_rms_arcsec: ctx.guide_rms_arcsec,
            solved_ra_hours: ctx.plate_solve_ra_hours,
            solved_dec_degrees: ctx.plate_solve_dec_degrees,
            plate_solve_pixel_scale_arcsec: ctx.plate_solve_pixel_scale_arcsec,
            plate_solve_rotation_deg: ctx.plate_solve_rotation_deg,
            bayer_pattern: ctx.bayer_pattern.clone(),
            session_id: Some(ctx.session_id.clone()).filter(|s| !s.is_empty()),
            frame_index: Some(ctx.frame_index).filter(|index| *index > 0),
            total_planned_frames: ctx.total_planned_frames,
            mosaic_name: ctx.mosaic_panel.as_ref().map(|p| p.mosaic_name.clone()),
            mosaic_panel_index: ctx.mosaic_panel.as_ref().map(|p| p.panel_index),
            mosaic_panel_row: ctx.mosaic_panel.as_ref().map(|p| p.row),
            mosaic_panel_column: ctx.mosaic_panel.as_ref().map(|p| p.column),
            mosaic_total_panels: ctx.mosaic_panel.as_ref().map(|p| p.total_panels),
            defect_map_correction: ctx.defect_map_correction.clone(),
            photometry_object_catalog: ctx.photometry_object_catalog.clone(),
            photometry_reference_stars: ctx
                .photometry_reference_stars
                .as_ref()
                .map(|refs| refs.join(",")),
            photometry_mjd_obs: ctx.photometry_mjd_obs,
            photometry_instrumental_mag: ctx.photometry_instrumental_mag,
            photometry_differential_mag: ctx.photometry_differential_mag,
            photometry_fwhm_arcsec: ctx.photometry_fwhm_arcsec,
            photometry_snr: ctx.photometry_snr,
            rig_label: ctx.rig_label.clone(),
            pier_side: ctx.pier_side.clone(),
        }
    }

    /// The cards this frame's FITS header carries, in the order they are
    /// written.
    pub(crate) fn fits_header(&self) -> FitsHeader {
        let mut header = FitsHeader::new();

        header.set_float("EXPTIME", self.exposure_time);
        header.set_string("DATE-OBS", &self.capture_timestamp);
        set_exposure_time_keywords(
            &mut header,
            &self.capture_timestamp,
            self.exposure_time,
            self.photometry_mjd_obs.is_none(),
        );
        header.set_string("IMAGETYP", &self.frame_type);

        if let Some(name) = &self.object_name {
            header.set_string("OBJECT", name);
        }
        if let Some(filter) = &self.filter {
            header.set_string("FILTER", filter);
        }
        if let Some(pos) = self.filter_position {
            header.set_int("FILTPOS", pos as i64);
        }

        if let Some(gain) = self.gain {
            header.set_int("GAIN", gain as i64);
            if self.gain_is_iso {
                header.set_int("ISOSPEED", gain as i64);
            }
        }
        if let Some(offset) = self.offset {
            header.set_int("OFFSET", offset as i64);
        }
        if let Some(temp) = self.ccd_temp {
            header.set_float("CCD-TEMP", temp);
        }
        if let Some(set_temp) = self.set_temp {
            header.set_float("SET-TEMP", set_temp);
        }

        header.set_int("XBINNING", self.bin_x as i64);
        header.set_int("YBINNING", self.bin_y as i64);

        if let Some(pixel_x) = self.pixel_size_x {
            header.set_float("PIXSIZE1", pixel_x);
            header.set_float("XPIXSZ", pixel_x * self.bin_x as f64);
        }
        if let Some(pixel_y) = self.pixel_size_y {
            header.set_float("PIXSIZE2", pixel_y);
            header.set_float("YPIXSZ", pixel_y * self.bin_y as f64);
        }

        if let Some(bayer) = &self.bayer_pattern {
            header.set_string("BAYERPAT", bayer);
        }

        if let Some(focal_length) = self.focal_length {
            header.set_float("FOCALLEN", focal_length);
        }
        if let Some(aperture) = self.aperture {
            header.set_float("APTDIA", aperture);
        }
        if let Some(telescope) = &self.telescope {
            header.set_string("TELESCOP", telescope);
        }
        if let Some(instrument) = &self.instrument {
            header.set_string("INSTRUME", instrument);
        }

        if let Some(observer) = &self.observer {
            header.set_string("OBSERVER", observer);
        }
        if let Some(lat) = self.site_latitude {
            header.set_float("SITELAT", lat);
        }
        if let Some(long) = self.site_longitude {
            header.set_float("SITELONG", long);
        }
        if let Some(elev) = self.site_elevation {
            header.set_float("SITEELEV", elev);
        }

        set_pointing_keywords(&mut header, self.ra, self.dec);
        set_horizon_keywords(&mut header, self.altitude);

        if self.pointing_is_j2000 && (self.ra.is_some() || self.dec.is_some()) {
            header.set_float("EQUINOX", 2000.0);
            header.set_string("RADESYS", "ICRS");
        }
        if let Some(side) = self.pier_side.as_deref() {
            header.set_string("PIERSIDE", side);
        }

        if let Some(pos) = self.focuser_position {
            header.set_int("FOCUSPOS", pos as i64);
        }
        if let Some(t) = self.focuser_temperature {
            header.set_float("FOCTEMP", t);
        }
        if let Some(angle) = self.rotator_angle {
            header.set_float("ROTATPOS", angle);
        }
        if let Some(rms) = self.guide_rms_arcsec {
            header.set_float("GUIDERMS", rms);
        }

        // Where the field landed, beside where the telescope was pointed.
        // `SOLVRA` is in hours, unlike the `RA` card.
        if let Some(ra) = self.solved_ra_hours {
            header.set_float("SOLVRA", ra);
        }
        if let Some(dec) = self.solved_dec_degrees {
            header.set_float("SOLVDEC", dec);
        }
        if let Some(scale) = self.plate_solve_pixel_scale_arcsec {
            header.set_float("PIXSCALE", scale);
        }
        if let Some(rot) = self.plate_solve_rotation_deg {
            // CROTA1 and CROTA2 are the WCS-standard field-rotation keywords;
            // every stacker reads at least one of them. Setting both follows
            // NINA's convention so PI / APP pick it up without configuration.
            header.set_float("CROTA1", rot);
            header.set_float("CROTA2", rot);
        }

        if let Some(session_id) = &self.session_id {
            header.set_string("SK-SESID", session_id);
        }
        if let Some(idx) = self.frame_index {
            header.set_int("SK-FIDX", idx as i64);
        }
        if let Some(total) = self.total_planned_frames {
            header.set_int("SK-NPLN", total as i64);
        }
        if let Some(name) = &self.mosaic_name {
            // MOSAIC=1 is the boolean "this frame is part of a mosaic"
            // flag, kept as an integer keyword for maximum reader
            // compatibility (some tools refuse BOOLEAN FITS values).
            header.set_int("MOSAIC", 1);
            header.set_string("SK-MOSNM", name);
        }
        if let Some(idx) = self.mosaic_panel_index {
            // 1-based for human readability in viewers (panel 1, 2, 3 ...)
            // while keeping the original 0-based index in SK-PIDX for the
            // re-import path.
            header.set_int("PANELIDX", (idx + 1) as i64);
            header.set_int("SK-PIDX", idx as i64);
        }
        if let Some(row) = self.mosaic_panel_row {
            header.set_int("PANELROW", row as i64);
            header.set_int("SK-PROW", row as i64);
        }
        if let Some(col) = self.mosaic_panel_column {
            header.set_int("PANELCOL", col as i64);
            header.set_int("SK-PCOL", col as i64);
        }
        if let Some(total) = self.mosaic_total_panels {
            header.set_int("SK-NPAN", total as i64);
        }
        if let Some(rig) = &self.rig_label {
            header.set_string("SK-RIG", rig);
        }

        if let Some(record) = &self.defect_map_correction {
            let history = format!(
                "Skotiq applied defect map v1 for camera {}: corrected {} of {} \
             defective pixels with {}x{} kernel using {} replacement.",
                record.camera_id,
                record.corrected_count,
                record.defect_count,
                record.kernel_diameter,
                record.kernel_diameter,
                record.method,
            );
            header.add_history(&history);
        }

        if let Some(catalog) = &self.photometry_object_catalog {
            if !catalog.is_empty() {
                header.set_string("OBJCAT", catalog);
            }
        }
        if let Some(refs) = &self.photometry_reference_stars {
            if !refs.is_empty() {
                // One card holds 68 characters of string value.
                let truncated = if refs.len() > 68 {
                    format!("{}...", &refs[..65])
                } else {
                    refs.clone()
                };
                header.set_string("REFSTARS", &truncated);
            }
        }
        if let Some(mjd) = self.photometry_mjd_obs {
            header.set_float("MJD-OBS", mjd);
        }
        if let Some(mag) = self.photometry_instrumental_mag {
            header.set_float("INSTRMAG", mag);
        }
        if let Some(mag) = self.photometry_differential_mag {
            header.set_float("DIFFMAG", mag);
        }
        if let Some(fwhm) = self.photometry_fwhm_arcsec {
            header.set_float("FWHM", fwhm);
        }
        if let Some(snr) = self.photometry_snr {
            header.set_float("SNR", snr);
        }
        header
    }
}

/// Format a signed sexagesimal angle as `±DD MM SS.SS`, the space-separated
/// form MaxIm DL / N.I.N.A. write for `OBJCTRA` / `OBJCTDEC`.
fn format_sexagesimal(value: f64, signed: bool) -> String {
    let negative = value < 0.0;
    let mut total_seconds = value.abs() * 3600.0;
    // Round to 1/100 s first so a value like 7.9999999 h renders as 08 00 00.00
    // instead of 07 59 60.00.
    total_seconds = (total_seconds * 100.0).round() / 100.0;
    let units = (total_seconds / 3600.0).floor();
    let minutes = ((total_seconds - units * 3600.0) / 60.0).floor();
    let seconds = total_seconds - units * 3600.0 - minutes * 60.0;
    let sign = if signed {
        if negative {
            "-"
        } else {
            "+"
        }
    } else if negative {
        "-"
    } else {
        ""
    };
    format!(
        "{}{:02} {:02} {:05.2}",
        sign, units as i64, minutes as i64, seconds
    )
}

/// Write the pointing keywords for a frame.
///
/// Skotiq carries RA in **hours** everywhere internally (the ASCOM
/// `RightAscension` convention) while Dec is in degrees. The numeric FITS
/// `RA` card, however, is degrees by universal convention — PixInsight,
/// Siril, ASTAP, AstroImageJ and astrometry.net all read it that way — so
/// passing the hour value straight through mis-located every frame by 15x
/// in RA. Convert here, at the one boundary where the unit changes, and
/// also emit the unambiguous sexagesimal `OBJCTRA`/`OBJCTDEC` pair that
/// MaxIm DL and N.I.N.A. write.
fn set_pointing_keywords(header: &mut FitsHeader, ra_hours: Option<f64>, dec_degrees: Option<f64>) {
    if let Some(ra) = ra_hours {
        if ra.is_finite() {
            header.set_float("RA", ra * 15.0);
            header.set_string("OBJCTRA", &format_sexagesimal(ra, false));
        }
    }
    if let Some(dec) = dec_degrees {
        if dec.is_finite() {
            header.set_float("DEC", dec);
            header.set_string("OBJCTDEC", &format_sexagesimal(dec, true));
        }
    }
}

/// The UTC instant a `DATE-OBS` text names. A saved frame's has no zone
/// (`2026-11-11T07:12:06`), as the FITS standard writes it; the plate
/// solver's temporary frame is stamped in RFC 3339.
fn parse_date_obs(date_obs: &str) -> Option<chrono::NaiveDateTime> {
    chrono::NaiveDateTime::parse_from_str(date_obs, "%Y-%m-%dT%H:%M:%S%.f")
        .ok()
        .or_else(|| {
            chrono::DateTime::parse_from_rfc3339(date_obs)
                .ok()
                .map(|instant| instant.naive_utc())
        })
}

/// Write `DATE-END` (DATE-OBS plus EXPTIME) and, when `with_mjd`, `MJD-OBS`
/// (the start, as the FITS standard defines it), both derived from the UTC
/// `DATE-OBS` text. Nothing is written when it does not parse.
fn set_exposure_time_keywords(
    header: &mut FitsHeader,
    date_obs: &str,
    exposure_secs: f64,
    with_mjd: bool,
) {
    let Some(start) = parse_date_obs(date_obs) else {
        return;
    };
    if exposure_secs.is_finite() && exposure_secs >= 0.0 {
        let end = start + chrono::Duration::milliseconds((exposure_secs * 1000.0).round() as i64);
        header.set_string("DATE-END", &end.format("%Y-%m-%dT%H:%M:%S%.3f").to_string());
    }
    if with_mjd {
        // MJD 0 is 1858-11-17T00:00:00 UTC.
        let epoch = chrono::NaiveDate::from_ymd_opt(1858, 11, 17)
            .and_then(|d| d.and_hms_opt(0, 0, 0))
            .expect("valid MJD epoch");
        let mjd = (start - epoch).num_milliseconds() as f64 / 86_400_000.0;
        header.set_float("MJD-OBS", mjd);
    }
}

/// Write the `OBJCTALT` altitude card and the `AIRMASS` derived from it,
/// omitting either when it cannot be stated truthfully.
///
/// The two are gated differently because they are different kinds of number.
/// `OBJCTALT` is the measurement: a parked mount really is at −9.9°, and that
/// is a fact about the frame worth recording. `AIRMASS` is an atmosphere model
/// evaluated at that altitude, and it is undefined below the horizon.
///
/// Recording the altitude and not only the airmass is what makes a frame
/// re-reducible. Airmass is lossy in the direction that matters: the published
/// formulae disagree by ~20% at the horizon (Pickering 38.7 vs Young 31.7 at
/// h=0°), so a photometry pipeline that wants to apply its own extinction
/// model cannot recover the altitude the writer started from. Every mainstream
/// capture app records it for that reason — N.I.N.A. and SGP as `OBJCTALT`,
/// MaxIm DL as `CENTALT` — so a Skotiq file without it is one a
/// photometry workflow can tell apart from every other app's.
///
/// AIRMASS itself is a convenience keyword — every stacker works without it —
/// but [`calculate_airmass`] deliberately refuses sub-horizon altitudes, and
/// darks and flats are by definition taken parked or capped (Alt < 0).
/// Propagating that refusal with `?` aborts the entire FITS write and destroys
/// the frame: the thumbnail lands on disk and the science data does not. Losing
/// an optional keyword is always better than losing the exposure, so warn and
/// skip the card instead.
fn set_horizon_keywords(header: &mut FitsHeader, altitude_degrees: Option<f64>) {
    let Some(altitude) = altitude_degrees else {
        return;
    };
    // A non-finite altitude is a broken read, not a pointing, so neither card
    // is written — same rule `set_pointing_keywords` applies to RA/DEC.
    if !altitude.is_finite() {
        return;
    }
    header.set_float("OBJCTALT", altitude);
    match calculate_airmass(altitude) {
        Ok(airmass) => header.set_float("AIRMASS", airmass),
        Err(e) => tracing::warn!(
            "Omitting AIRMASS from FITS header: cannot compute for altitude {}°: {}. \
             The frame itself, and its OBJCTALT card, are unaffected.",
            altitude,
            e
        ),
    }
}

/// Write a 16-bit mono frame and its header to `file_path`, creating the
/// directory, in the format the path's extension names, encoded as the
/// capture file format setting says. A frame that fails validation is still
/// written: the warnings are logged, the exposure is kept.
pub(crate) async fn write_capture_frame(
    file_path: String,
    width: u32,
    height: u32,
    data: Vec<u16>,
    header: FrameHeader,
) -> Result<(), SkotiqError> {
    tracing::info!("Saving frame to: {}", file_path);

    let image = ImageData::from_u16(width, height, 1, &data);
    let validation = validate_image(&image, Some(width), Some(height));
    if !validation.is_valid {
        tracing::warn!("Image validation failed: {:?}", validation.errors);
    }
    for warning in &validation.warnings {
        tracing::warn!("Image validation warning: {}", warning);
    }

    let header = header.fits_header();
    for warning in &validate_fits_header(&header).warnings {
        tracing::debug!("FITS header warning: {}", warning);
    }

    if let Some(parent) = std::path::Path::new(&file_path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            SkotiqError::OperationFailed(format!("Failed to create directory: {}", e))
        })?;
    }

    let path = std::path::PathBuf::from(file_path);
    let options = skotiq_sequencer::executor_handle()
        .run_config()
        .frame_format
        .write_options();
    tokio::task::spawn_blocking(move || write_frame_with(&path, &image, &header, &options))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {}", e)))?
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to save the frame: {}", e)))?;
    Ok(())
}

#[cfg(test)]
mod golden_tests;
#[cfg(test)]
mod tests;
