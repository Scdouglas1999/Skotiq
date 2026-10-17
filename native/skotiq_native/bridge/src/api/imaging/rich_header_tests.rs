use super::{save_fits_file_rich, FitsWriteHeaderRich};
use skotiq_imaging::read_fits;
use skotiq_sequencer::scheduling::FrameContext;
use skotiq_sequencer::MosaicPanelInfo;
use std::path::{Path, PathBuf};

/// A scratch directory that deletes itself when the test ends. Cleanup runs
/// from `Drop`, so it happens even while a panic unwinds out of a failing test.
struct TempDir(PathBuf);

impl std::ops::Deref for TempDir {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

// Deref alone does not satisfy a generic `AsRef<Path>` bound, which several
// call sites here rely on.
impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        // Best-effort: a test asserting on a half-removed tree should fail
        // on its own assertion, not on cleanup.
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_scratch_dir(tag: &str) -> TempDir {
    let p = std::env::temp_dir().join(format!(
        "ns_rich_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&p).unwrap();
    TempDir(p)
}

/// End-to-end: build a FrameContext with every meaningful field set,
/// route it through `save_fits_file_rich`, then read the FITS back from
/// disk and assert every keyword survived.
///
/// The gate is what a reader sees: open the file and every keyword the context
/// carried is populated.
#[tokio::test]
async fn fits_round_trip_preserves_all_frame_context_keywords() {
    // 8x8 image with arbitrary pixel data so the FITS writer has
    // something to write. Pixel data is not what we're testing.
    let width = 8u32;
    let height = 8u32;
    let pixels = (0..(width * height) as u16).collect::<Vec<u16>>();

    let scratch = temp_scratch_dir("round_trip");
    let temp_path = scratch.join("frame.fits");

    // Build a FrameContext with every field set so we can
    // verify each one survives the round-trip.
    let mut ctx = FrameContext::new_light("session-uuid-abc", 2, 2, 60.0, 7);
    ctx.target_id = Some("tgt-42".to_string());
    ctx.target_name = Some("M31".to_string());
    ctx.target_ra_hours = Some(0.7123);
    ctx.target_dec_degrees = Some(41.269);
    ctx.filter_name = Some("Ha".to_string());
    ctx.filter_index = Some(5);
    ctx.gain = Some(100);
    ctx.offset = Some(50);
    ctx.total_planned_frames = Some(20);
    ctx.sensor_temp_c = Some(-10.5);
    ctx.set_temp_c = Some(-10.0);
    ctx.focuser_position = Some(25_400);
    ctx.focuser_temperature_c = Some(12.3);
    ctx.rotator_angle_deg = Some(123.7);
    ctx.guide_rms_arcsec = Some(0.78);
    ctx.plate_solve_ra_hours = Some(0.7124);
    ctx.plate_solve_dec_degrees = Some(41.2691);
    ctx.plate_solve_pixel_scale_arcsec = Some(1.42);
    ctx.plate_solve_rotation_deg = Some(-1.3);
    ctx.bayer_pattern = Some("RGGB".to_string());
    ctx.mosaic_panel = Some(MosaicPanelInfo {
        mosaic_name: "M31 Wide".to_string(),
        panel_index: 2,
        total_panels: 9,
        row: 1,
        column: 2,
    });
    ctx.observer_name = Some("Test Observer".to_string());
    ctx.site_latitude_deg = Some(40.7128);
    ctx.site_longitude_deg = Some(-74.0060);
    ctx.site_elevation_m = Some(50.0);
    ctx.camera_make = Some("ZWO".to_string());
    ctx.camera_model = Some("ASI2600MM Pro".to_string());
    ctx.telescope_name = Some("Askar 65PHQ".to_string());
    ctx.telescope_focal_length_mm = Some(416.0);
    ctx.telescope_aperture_mm = Some(65.0);
    ctx.camera_pixel_size_x_um = Some(3.76);
    ctx.camera_pixel_size_y_um = Some(3.76);

    let header = FitsWriteHeaderRich::from_frame_context(&ctx);

    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("rich FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back should succeed");

    // Core observation metadata.
    assert_eq!(parsed.get_string("OBJECT"), Some("M31"));
    assert_eq!(parsed.get_string("FILTER"), Some("Ha"));
    assert_eq!(parsed.get_int("FILTPOS"), Some(5));
    assert_eq!(parsed.get_string("IMAGETYP"), Some("Light"));
    assert_eq!(parsed.get_float("EXPTIME"), Some(60.0));
    // Bayer pattern.
    assert_eq!(parsed.get_string("BAYERPAT"), Some("RGGB"));

    // Camera settings.
    assert_eq!(parsed.get_int("GAIN"), Some(100));
    assert_eq!(parsed.get_int("OFFSET"), Some(50));
    assert_eq!(parsed.get_int("XBINNING"), Some(2));
    assert_eq!(parsed.get_int("YBINNING"), Some(2));
    assert_eq!(parsed.get_float("SET-TEMP"), Some(-10.0));
    // CCD-TEMP set from ctx.sensor_temp_c.
    assert_eq!(parsed.get_float("CCD-TEMP"), Some(-10.5));

    // Telescope / equipment.
    assert_eq!(parsed.get_string("TELESCOP"), Some("Askar 65PHQ"));
    // INSTRUME is "<make> <model>" when both are present.
    assert_eq!(parsed.get_string("INSTRUME"), Some("ZWO ASI2600MM Pro"));
    assert_eq!(parsed.get_float("FOCALLEN"), Some(416.0));
    assert_eq!(parsed.get_float("APTDIA"), Some(65.0));
    // Pixel pitch, scaled by the binning this frame was taken at — FOCALLEN
    // without it is not enough for a stacker to derive the plate scale, and
    // these were hardcoded absent on every sequenced frame.
    let xpixsz = parsed.get_float("XPIXSZ").expect("XPIXSZ card");
    let ypixsz = parsed.get_float("YPIXSZ").expect("YPIXSZ card");
    assert!(
        (xpixsz - 7.52).abs() < 1e-6 && (ypixsz - 7.52).abs() < 1e-6,
        "a 3.76 um sensor binned 2x2 has 7.52 um effective pixels, \
             got {xpixsz} x {ypixsz}"
    );

    // Observer + site.
    assert_eq!(parsed.get_string("OBSERVER"), Some("Test Observer"));
    assert_eq!(parsed.get_float("SITELAT"), Some(40.7128));
    assert_eq!(parsed.get_float("SITELONG"), Some(-74.0060));
    assert_eq!(parsed.get_float("SITEELEV"), Some(50.0));

    // Target coordinates. `target_ra_hours` is hours; the numeric FITS
    // RA card is degrees, so the writer multiplies by 15.
    let ra_deg = parsed.get_float("RA").expect("RA card");
    assert!(
        (ra_deg - 0.7123 * 15.0).abs() < 1e-6,
        "RA must be written in degrees, got {ra_deg}"
    );
    assert_eq!(parsed.get_float("DEC"), Some(41.269));
    // Unambiguous sexagesimal pair (MaxIm / N.I.N.A. convention).
    assert_eq!(parsed.get_string("OBJCTRA"), Some("00 42 44.28"));
    assert_eq!(parsed.get_string("OBJCTDEC"), Some("+41 16 08.40"));

    // Live device telemetry.
    assert_eq!(parsed.get_int("FOCUSPOS"), Some(25_400));
    assert_eq!(parsed.get_float("FOCTEMP"), Some(12.3));
    assert_eq!(parsed.get_float("ROTATPOS"), Some(123.7));
    assert_eq!(parsed.get_float("GUIDERMS"), Some(0.78));

    // Plate-solve results. FITS keywords are capped at 8 chars so we
    // use SOLVRA/SOLVDEC.
    assert_eq!(parsed.get_float("SOLVRA"), Some(0.7124));
    assert_eq!(parsed.get_float("SOLVDEC"), Some(41.2691));
    assert_eq!(parsed.get_float("PIXSCALE"), Some(1.42));
    assert_eq!(parsed.get_float("CROTA1"), Some(-1.3));
    assert_eq!(parsed.get_float("CROTA2"), Some(-1.3));

    // Skotiq-specific session / frame accounting.
    assert_eq!(parsed.get_string("NS-SESID"), Some("session-uuid-abc"));
    assert_eq!(parsed.get_int("NS-FIDX"), Some(7));
    assert_eq!(parsed.get_int("NS-NPLN"), Some(20));

    // Mosaic: the panel a frame belongs to has to reach the FITS header, not
    // just the sequence config.
    assert_eq!(parsed.get_int("MOSAIC"), Some(1));
    assert_eq!(parsed.get_string("NS-MOSNM"), Some("M31 Wide"));
    // PANELIDX is 1-based for human readability; NS-PIDX preserves
    // the 0-based form for re-import.
    assert_eq!(parsed.get_int("PANELIDX"), Some(3));
    assert_eq!(parsed.get_int("NS-PIDX"), Some(2));
    assert_eq!(parsed.get_int("PANELROW"), Some(1));
    assert_eq!(parsed.get_int("NS-PROW"), Some(1));
    assert_eq!(parsed.get_int("PANELCOL"), Some(2));
    assert_eq!(parsed.get_int("NS-PCOL"), Some(2));
    assert_eq!(parsed.get_int("NS-NPAN"), Some(9));
}

/// A monochrome capture should NOT emit a BAYERPAT keyword (writing
/// one would tell PixInsight to debayer the mono frame as if it were
/// OSC, producing colour artefacts on what is just a luminance frame).
#[tokio::test]
async fn monochrome_capture_omits_bayer_pattern() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![0u16; (width * height) as usize];

    let scratch = temp_scratch_dir("mono");
    let temp_path = scratch.join("frame.fits");

    let mut ctx = FrameContext::new_light("s", 1, 1, 30.0, 1);
    ctx.target_name = Some("FocusTest".to_string());
    // bayer_pattern is None — mono camera.
    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("mono FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
    assert_eq!(
        parsed.get_string("BAYERPAT"),
        None,
        "monochrome captures must NOT emit BAYERPAT"
    );
}

/// Absent optional fields must be omitted, not stamped with sentinel values:
/// writing CCD-TEMP=-273.15 for "no temperature" lies to downstream tools.
#[tokio::test]
async fn missing_optional_fields_are_omitted_not_zeroed() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![0u16; (width * height) as usize];

    let scratch = temp_scratch_dir("omit");
    let temp_path = scratch.join("frame.fits");

    let ctx = FrameContext::new_light("sess", 1, 1, 10.0, 1);
    // Nothing else set — every optional field stays None.
    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
    // Every optional keyword must be absent.
    for absent_key in &[
        "OBJECT", "FILTER", "FILTPOS", "GAIN", "OFFSET", "CCD-TEMP", "SET-TEMP", "FOCUSPOS",
        "ROTATPOS", "GUIDERMS", "SOLVRA", "SOLVDEC", "PIXSCALE", "CROTA1", "BAYERPAT", "MOSAIC",
        "PANELIDX", "NS-MOSNM", "OBSERVER", "SITELAT", "TELESCOP", "INSTRUME", "FOCALLEN",
        "APTDIA",
    ] {
        let s = parsed.get_string(absent_key);
        let i = parsed.get_int(absent_key);
        let f = parsed.get_float(absent_key);
        assert!(
                s.is_none() && i.is_none() && f.is_none(),
                "{} should be absent for an unset FrameContext field (got string={:?} int={:?} float={:?})",
                absent_key,
                s,
                i,
                f
            );
    }

    // SESSIONID is also omitted when session_id is the empty string
    // (the rich-header builder maps empty -> None).
    let mut empty_ctx = FrameContext::new_light("", 1, 1, 10.0, 1);
    empty_ctx.session_id = String::new();
    let header_empty = FitsWriteHeaderRich::from_frame_context(&empty_ctx);
    assert!(
        header_empty.session_id.is_none(),
        "empty session_id should be normalised to None"
    );
}

/// AIRMASS is optional: a below-horizon altitude omits the card and still writes
/// the frame. Darks and flats are taken parked/capped (Alt < 0) by definition, so
/// failing the write on `calculate_airmass` would cost entire calibration runs.
#[tokio::test]
async fn below_horizon_altitude_still_writes_the_frame() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![7u16; (width * height) as usize];

    let scratch = temp_scratch_dir("below_horizon");
    let temp_path = scratch.join("parked.fits");

    let ctx = FrameContext::new_light("sess", 1, 1, 3.0, 1);
    let mut header = FitsWriteHeaderRich::from_frame_context(&ctx);
    // Mount parked: the exact altitude the sim mount reports.
    header.altitude = Some(-9.9);

    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("a parked mount must not stop the frame from being saved");

    assert!(
        temp_path.exists(),
        "FITS file must exist on disk for a below-horizon capture"
    );
    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
    assert_eq!(
        parsed.get_float("AIRMASS"),
        None,
        "AIRMASS must be omitted (not faked) when it cannot be computed"
    );
    // The altitude is a measurement, not a model output: the mount really
    // was at -9.9°, and a dark that records where the scope was parked is
    // more useful than one that records nothing. Only the derived quantity
    // is undefined down there.
    let recorded = parsed
        .get_float("OBJCTALT")
        .expect("OBJCTALT records the altitude even below the horizon");
    assert!(
        (recorded - (-9.9)).abs() < 0.01,
        "OBJCTALT should be -9.9, got {recorded}"
    );
}

/// Above the horizon the AIRMASS card is still written, so omission is
/// genuinely conditional rather than a blanket removal.
#[tokio::test]
async fn above_horizon_altitude_writes_airmass() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![1u16; (width * height) as usize];

    let scratch = temp_scratch_dir("above_horizon");
    let temp_path = scratch.join("high.fits");

    let ctx = FrameContext::new_light("sess", 1, 1, 3.0, 1);
    let mut header = FitsWriteHeaderRich::from_frame_context(&ctx);
    header.altitude = Some(78.98);

    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
    let airmass = parsed.get_float("AIRMASS").expect("AIRMASS card");
    assert!(
        (airmass - 1.0185).abs() < 0.001,
        "AIRMASS at Alt 78.98° should be ~1.0185, got {airmass}"
    );
}

/// A sequenced frame has to record where in the sky it was taken, not just
/// where the mount was pointed.
///
/// This drives the production line: a `FrameContext` carrying exactly the
/// telemetry the sequencer stamps onto one (`instructions.rs` reads the
/// mount's coordinates and derives alt/az from the site in the same
/// breath), through the real `from_frame_context` and the real writer, and
/// reads the cards back off disk. OBJCTALT and AIRMASS have to be on the frame
/// the sequencer writes through `real_device_ops` / `unified_device_ops`:
/// extinction correction has nothing to work from without them, and the altitude
/// cannot be reconstructed later, because the file does not otherwise say when,
/// where, and at what it was pointed all at once.
#[tokio::test]
async fn sequenced_frame_records_where_in_the_sky_it_was_taken() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![3u16; (width * height) as usize];

    let scratch = temp_scratch_dir("horizon_coords");
    let temp_path = scratch.join("sequenced.fits");

    let mut ctx = FrameContext::new_light("sess", 1, 1, 120.0, 1);
    // Where the sequence MEANT to be...
    ctx.target_ra_hours = Some(5.5);
    ctx.target_dec_degrees = Some(-5.4);
    // ...and where the mount actually was when the shutter opened, with
    // the altitude the sequencer derived from that pointing and the site.
    ctx.mount_ra_hours = Some(5.4917);
    ctx.mount_dec_degrees = Some(-5.39);
    ctx.mount_altitude_deg = Some(30.0);

    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");

    let recorded_alt = parsed
        .get_float("OBJCTALT")
        .expect("a sequenced frame must record the altitude it was taken at");
    assert!(
        (recorded_alt - 30.0).abs() < 0.01,
        "OBJCTALT should be the mount's 30.0°, got {recorded_alt}"
    );

    // Physics, not a re-run of the formula: at 30° altitude the zenith
    // angle is 60°, so the plane-parallel path is sec 60° = 2.0 exactly.
    // A real (curved, refracting) atmosphere is always a slightly SHORTER
    // path than that, by a few tenths of a percent at this altitude.
    let airmass = parsed
        .get_float("AIRMASS")
        .expect("AIRMASS follows from a recorded altitude");
    let plane_parallel = 1.0 / (60.0_f64).to_radians().cos();
    assert!(
        airmass < plane_parallel,
        "AIRMASS {airmass} at 30° altitude is not below the plane-parallel \
             ceiling {plane_parallel}"
    );
    assert!(
        plane_parallel - airmass < 0.02,
        "AIRMASS {airmass} at 30° altitude is {:.4} below sec z — far more \
             curvature than a real atmosphere has",
        plane_parallel - airmass
    );

    // The pointing cards describe the same instant as the altitude: the
    // mount's coordinates, not the target's nominal ones. RA leaves in
    // degrees.
    let ra_deg = parsed.get_float("RA").expect("RA card");
    assert!(
        (ra_deg - 5.4917 * 15.0).abs() < 1e-6,
        "RA should be the mount's 5.4917h in degrees, got {ra_deg}"
    );
    let dec_deg = parsed.get_float("DEC").expect("DEC card");
    assert!(
        (dec_deg - (-5.39)).abs() < 1e-6,
        "DEC should be the mount's -5.39°, got {dec_deg}"
    );
}

/// A frame taken with no mount attached still has an altitude, and the
/// file must carry it.
///
/// `FrameContext::mount_altitude_deg` is set only when a mount is connected and
/// answers the coordinate read, so reading it directly would write `RA`/`DEC`
/// from the target and drop the `OBJCTALT` and `AIRMASS` derived from that same
/// pointing. Altitude is pure geometry: pointing, site, and time are all already
/// in this struct.
///
/// The geometry is chosen so the expected altitude needs no sidereal-time
/// calculation and cannot drift with the clock: the celestial pole sits at
/// an altitude equal to the observer's latitude for every hour angle, at
/// every longitude, for ever.
#[tokio::test]
async fn mountless_frame_still_records_altitude_and_airmass() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![7u16; (width * height) as usize];

    let scratch = temp_scratch_dir("mountless_horizon");
    let temp_path = scratch.join("mountless.fits");

    const SITE_LAT: f64 = 39.9719;

    let mut ctx = FrameContext::new_light("sess", 1, 1, 120.0, 1);
    // No mount: `mount_ra_hours`, `mount_dec_degrees` and
    // `mount_altitude_deg` all stay None, exactly as the capture path
    // leaves them when `ExecutionContext::mount_id` is None.
    ctx.target_ra_hours = Some(2.5303);
    ctx.target_dec_degrees = Some(90.0);
    ctx.site_latitude_deg = Some(SITE_LAT);
    ctx.site_longitude_deg = Some(-75.3576);
    ctx.exposure_started_at = Some(
        chrono::DateTime::parse_from_rfc3339("2026-08-10T00:06:02Z")
            .unwrap()
            .with_timezone(&chrono::Utc),
    );
    assert!(
        ctx.mount_altitude_deg.is_none(),
        "precondition: no mount telemetry was recorded for this frame"
    );

    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");

    let recorded_alt = parsed
        .get_float("OBJCTALT")
        .expect("a mountless frame must still record the altitude it was taken at");
    assert!(
        (recorded_alt - SITE_LAT).abs() < 0.05,
        "the pole sits at the observer's latitude {SITE_LAT}°, got OBJCTALT {recorded_alt}"
    );

    // Physics, not a re-run of the formula: at ~40° altitude the
    // plane-parallel path is sec 50° = 1.5557, and a real refracting
    // atmosphere is always a slightly shorter path than that.
    let airmass = parsed
        .get_float("AIRMASS")
        .expect("AIRMASS follows from a recorded altitude");
    let plane_parallel = 1.0 / (90.0 - SITE_LAT).to_radians().cos();
    assert!(
        airmass < plane_parallel,
        "AIRMASS {airmass} is not below the plane-parallel ceiling {plane_parallel}"
    );
    assert!(
        plane_parallel - airmass < 0.02,
        "AIRMASS {airmass} is {:.4} below sec z — far more curvature than a \
             real atmosphere has",
        plane_parallel - airmass
    );

    // ...and it describes the SAME pointing the file was labelled with.
    // An altitude derived from one direction beside RA/DEC cards naming
    // another would be worse than no altitude at all.
    let ra_deg = parsed.get_float("RA").expect("RA card");
    assert!(
        (ra_deg - 2.5303 * 15.0).abs() < 1e-6,
        "RA should be the target's 2.5303h in degrees, got {ra_deg}"
    );
    let dec_deg = parsed.get_float("DEC").expect("DEC card");
    assert!(
        (dec_deg - 90.0).abs() < 1e-6,
        "DEC should be the target's 90.0°, got {dec_deg}"
    );
}

/// No site, no altitude — the one case where withholding it is right.
///
/// Guards the rule above from turning into "always emit something": with no
/// observer location the altitude could only come from a guessed site, and
/// a guessed `AIRMASS` silently corrupts an extinction correction in a way
/// a missing one cannot.
#[tokio::test]
async fn no_site_means_no_altitude_rather_than_a_guessed_one() {
    let mut ctx = FrameContext::new_light("sess", 1, 1, 60.0, 1);
    ctx.target_ra_hours = Some(2.5303);
    ctx.target_dec_degrees = Some(90.0);
    ctx.exposure_started_at = Some(chrono::Utc::now());
    // site_latitude_deg / site_longitude_deg left unset.

    let header = FitsWriteHeaderRich::from_frame_context(&ctx);
    assert_eq!(
        header.altitude, None,
        "altitude must be omitted, not computed from a guessed site"
    );
}

/// Hardie (1962), for cross-checking the AIRMASS card against a formula
/// this codebase does not implement. A polynomial in sec z, from different
/// data and a different era than either Pickering or Young, and the
/// reduction every photoelectric photometry paper used for three decades:
///
///   X = sec z − 0.0018167(sec z − 1) − 0.002875(sec z − 1)²
///              − 0.0008083(sec z − 1)³
///
/// Hardie, R. H. 1962. "Photoelectric Reductions", in *Astronomical
/// Techniques*, ed. W. A. Hiltner (University of Chicago Press), p. 180.
/// Stated valid to z ≈ 80° (h ≥ 10°); it diverges rapidly below that.
fn hardie_1962_airmass(altitude_degrees: f64) -> f64 {
    let sec_z = 1.0 / (90.0 - altitude_degrees).to_radians().cos();
    let d = sec_z - 1.0;
    sec_z - 0.0018167 * d - 0.002875 * d * d - 0.0008083 * d * d * d
}

/// Pin the AIRMASS card against a published formula rather than against
/// itself.
///
/// This value goes into files users publish and hand to other people's
/// reduction pipelines, so the thing worth asserting is not "Pickering was
/// transcribed correctly" — a typo'd Pickering is still self-consistent —
/// but "an outside reducer computing airmass their own way gets our
/// number". Hardie is that outside reducer: a different functional form
/// fitted to different data, agreeing here to better than 0.02 airmass
/// (0.005 mag at a typical k = 0.25) across its whole validity range.
///
/// This is the shape of check that catches a formula that has quietly
/// stopped being the one it is named after — a copy that adds Pickering's
/// refraction term to sin(h) instead of to h is wrong by a factor of nearly
/// three at 10° altitude while still looking like Pickering's formula on the
/// page.
#[test]
fn airmass_agrees_with_hardie_1962_over_its_published_range() {
    let mut worst = (0.0_f64, 0.0_f64);
    let mut h = 10.0_f64;
    while h <= 90.0 {
        let ours = skotiq_imaging::calculate_airmass(h).expect("above the horizon");
        let delta = (ours - hardie_1962_airmass(h)).abs();
        if delta > worst.1 {
            worst = (h, delta);
        }
        h += 0.25;
    }
    assert!(
        worst.1 < 0.02,
        "AIRMASS disagrees with Hardie 1962 by {:.4} airmass at h={:.2}° \
             (ours {:.5}, Hardie {:.5}); the card no longer means what an \
             outside photometry reduction will assume it means",
        worst.1,
        worst.0,
        skotiq_imaging::calculate_airmass(worst.0).unwrap(),
        hardie_1962_airmass(worst.0),
    );
}

/// The properties any airmass must have, over the whole sky, independent
/// of which formula produced it:
///
///   * ≥ 1 — the zenith is the shortest path through the atmosphere, so
///     nothing can be shorter.
///   * strictly increasing toward the horizon — a lower target looks
///     through more air, always.
///   * ≤ sec z — a curved atmosphere is a shorter path than the flat one
///     the plane-parallel approximation assumes, so sec z is a hard
///     ceiling.
///
/// The hand-rolled copy this consolidation deleted from the photometry
/// gate violated the first two: it peaked at 2.02 near 10° altitude, then
/// *decreased* toward the horizon, and reported 0.86 at 1°. Nothing
/// checked shape, so it survived for as long as it existed.
#[test]
fn airmass_is_physical_over_the_whole_sky() {
    let mut previous: Option<(f64, f64)> = None;
    let mut h = 0.0_f64;
    while h <= 89.75 {
        let x = skotiq_imaging::calculate_airmass(h).expect("h >= 0 is above the horizon");
        assert!(
            x >= 1.0,
            "airmass {x} at h={h}° is below 1.0 — shorter than the zenith path"
        );
        let sec_z = 1.0 / (90.0 - h).to_radians().cos();
        assert!(
            x <= sec_z,
            "airmass {x} at h={h}° exceeds the plane-parallel ceiling sec z = {sec_z}"
        );
        if let Some((prev_h, prev_x)) = previous {
            assert!(
                x < prev_x,
                "airmass rose with altitude: {prev_x} at {prev_h}° -> {x} at {h}°"
            );
        }
        previous = Some((h, x));
        h += 0.25;
    }
}

/// Bound the one place the implementation is not continuous.
///
/// `calculate_airmass` hands over from Young 1994 to Pickering 2002 at
/// exactly 10° altitude, and the two disagree there, so airmass takes a
/// small step UP as altitude increases across the seam — a local violation
/// of the monotonicity the sweep above checks, invisible at that sweep's
/// 0.25° resolution because the real gradient (0.13/0.25°) is four times
/// larger than the step.
///
/// It is left in place rather than smoothed away: 0.035 airmass is 0.009
/// mag at a typical k = 0.25, at an altitude no photometry gate admits
/// (the default cut-off is 2.5 airmass, ~24°), and the alternative is
/// changing the AIRMASS of every frame the app has ever written. What is
/// not acceptable is for it to grow silently, so it is measured here.
#[test]
fn young_to_pickering_handover_step_stays_small() {
    let below = skotiq_imaging::calculate_airmass(9.9999).expect("above the horizon");
    let at = skotiq_imaging::calculate_airmass(10.0).expect("above the horizon");
    let step = at - below;
    assert!(
        (0.0..0.05).contains(&step),
        "the Young/Pickering handover at 10° now steps by {step:.4} airmass \
             ({below} just below, {at} at the seam)"
    );
}

/// The AIRMASS a frame records and the airmass the scheduler used to pick
/// its target must be one number.
///
/// Read off disk on one side, called live on the other, so this fails if either
/// the writer or `scheduling::astronomy` grows its own formula. Below 10°
/// altitude the writer switches to Young 1994, and a private copy that does not
/// gives 38.7 at the horizon against the writer's 31.7 — either of which could
/// end up in a file somebody publishes.
#[tokio::test]
async fn airmass_card_agrees_with_the_scheduler_that_chose_the_target() {
    let width = 2u32;
    let height = 2u32;
    let scratch = temp_scratch_dir("airmass_parity");

    for altitude in [80.0_f64, 45.0, 24.0, 12.0, 6.0, 1.0] {
        let temp_path = scratch.join(format!("alt_{altitude}.fits"));
        let ctx = FrameContext::new_light("sess", 1, 1, 5.0, 1);
        let mut header = FitsWriteHeaderRich::from_frame_context(&ctx);
        header.altitude = Some(altitude);

        save_fits_file_rich(
            temp_path.to_string_lossy().to_string(),
            width,
            height,
            vec![0u16; (width * height) as usize],
            header,
        )
        .await
        .expect("FITS save should succeed");

        let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
        let written = parsed.get_float("AIRMASS").expect("AIRMASS card");
        let scheduled = skotiq_sequencer::scheduling::airmass(altitude);
        assert!(
            (written - scheduled).abs() < 1e-9,
            "at {altitude}° the file records airmass {written} but the scheduler \
                 scored the target at {scheduled}"
        );
    }
}

/// Unit pin: RA is carried internally in hours but the numeric FITS RA
/// card is degrees. Without this conversion every frame pointed
/// PixInsight / Siril / ASTAP / astrometry.net 15x off in RA.
#[tokio::test]
async fn ra_is_written_in_degrees_not_hours() {
    let width = 4u32;
    let height = 4u32;
    let pixels = vec![0u16; (width * height) as usize];

    let scratch = temp_scratch_dir("ra_units");
    let temp_path = scratch.join("pointing.fits");

    let mut ctx = FrameContext::new_light("sess", 1, 1, 3.0, 1);
    // A pointing whose hour and degree values cannot be confused: 08h00m / +40°.
    ctx.target_ra_hours = Some(8.0);
    ctx.target_dec_degrees = Some(40.0);
    let header = FitsWriteHeaderRich::from_frame_context(&ctx);

    save_fits_file_rich(
        temp_path.to_string_lossy().to_string(),
        width,
        height,
        pixels,
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&temp_path).expect("FITS read-back");
    assert_eq!(
        parsed.get_float("RA"),
        Some(120.0),
        "RA(deg) must equal 15 x mount hours"
    );
    assert_eq!(parsed.get_float("DEC"), Some(40.0));
    assert_eq!(parsed.get_string("OBJCTRA"), Some("08 00 00.00"));
    assert_eq!(parsed.get_string("OBJCTDEC"), Some("+40 00 00.00"));
}

/// Negative declinations must keep their sign in the sexagesimal card.
#[test]
fn sexagesimal_formatting_handles_sign_and_rounding() {
    assert_eq!(super::format_sexagesimal(8.0, false), "08 00 00.00");
    assert_eq!(super::format_sexagesimal(40.0, true), "+40 00 00.00");
    assert_eq!(
        super::format_sexagesimal(-5.5083333333, true),
        "-05 30 30.00"
    );
    // 7.99999999 h must not render as 07 59 60.00.
    assert_eq!(
        super::format_sexagesimal(7.999_999_99, false),
        "08 00 00.00"
    );
}
