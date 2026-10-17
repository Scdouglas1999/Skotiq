use super::{
    altitude_degrees, build_rich_header, context_altitude_pointing, MountPointing, UnifiedDeviceOps,
};
use skotiq_imaging::read_fits;
use skotiq_sequencer::scheduling::FrameContext;
use skotiq_sequencer::ImageData;
use std::path::{Path, PathBuf};

/// Scratch directory that removes itself even when a test panics.
struct TempDir(PathBuf);

impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_scratch_dir(tag: &str) -> TempDir {
    let p = std::env::temp_dir().join(format!(
        "sk_unifiedops_{}_{}_{}",
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

fn tiny_frame() -> ImageData {
    ImageData {
        width: 4,
        height: 4,
        data: vec![0u16; 16],
        bits_per_pixel: 16,
        exposure_secs: 3.0,
        gain: Some(100),
        offset: Some(10),
        temperature: Some(20.0),
        filter: None,
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

/// The reported repro: a sequence with NO Target group (Slew to Target with
/// custom coordinates) captured four lights whose FITS headers carried no
/// RA, DEC, OBJCTRA or OBJCTDEC card at all — the night left no record of
/// where the telescope was aimed. The mount's own report must fill them.
#[tokio::test]
async fn untargeted_frame_carries_the_mount_pointing() {
    let ctx = FrameContext::new_light("sess-untargeted", 1, 1, 3.0, 1);
    assert!(
        ctx.target_ra_hours.is_none() && ctx.target_dec_degrees.is_none(),
        "precondition: an untargeted run has no target coordinates to fall back on"
    );

    let header = build_rich_header(
        &tiny_frame(),
        &ctx,
        Some(MountPointing {
            ra_hours: 17.0,
            dec_degrees: 30.0,
            altitude_deg: Some(52.0),
        }),
    );

    let scratch = temp_scratch_dir("untargeted");
    let path = scratch.as_ref().join("untargeted_0001.fits");
    crate::api::save_fits_file_rich(
        path.to_string_lossy().to_string(),
        4,
        4,
        vec![0u16; 16],
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&path).expect("FITS read-back should succeed");

    // The numeric RA card is degrees by universal convention; internal RA
    // is hours.
    let ra_deg = parsed.get_float("RA").expect("RA card must be present");
    assert!(
        (ra_deg - 17.0 * 15.0).abs() < 1e-6,
        "RA card should be the mount's 17h in degrees, got {ra_deg}"
    );
    assert_eq!(parsed.get_float("DEC"), Some(30.0));
    assert_eq!(parsed.get_string("OBJCTRA"), Some("17 00 00.00"));
    assert_eq!(parsed.get_string("OBJCTDEC"), Some("+30 00 00.00"));
    // Altitude rides along with the pointing, which is what makes AIRMASS
    // computable for sequenced frames.
    assert!(
        parsed.get_float("AIRMASS").is_some(),
        "AIRMASS should be derivable once the pointing carries an altitude"
    );
}

/// The rig frame, at the layer that actually wrote it.
///
/// `Polaris_1_0001.fits` came out of `save_fits`, which is
/// `build_rich_header` plus a mount read — not `from_frame_context` alone.
/// When no mount answers, `read_mount_pointing` returns `None` and NEITHER
/// pointing branch below runs, so whatever `from_frame_context` derived is
/// what reaches the file. That makes this function, not the constructor,
/// the place where "a mountless frame keeps its altitude" is either true or
/// silently undone by a later assignment.
///
/// Dec 90° is deliberate: the celestial pole sits at the observer's
/// latitude for every hour angle, at every longitude, for ever, so the
/// expected altitude is a constant that cannot drift with the clock.
#[tokio::test]
async fn mountless_sequencer_frame_keeps_its_altitude_through_the_save_path() {
    const SITE_LAT: f64 = 39.9719;

    let mut ctx = FrameContext::new_light("sess-mountless", 1, 1, 3.0, 1);
    ctx.target_ra_hours = Some(2.5303);
    ctx.target_dec_degrees = Some(90.0);
    ctx.site_latitude_deg = Some(SITE_LAT);
    ctx.site_longitude_deg = Some(-75.3576);
    ctx.exposure_started_at = Some(chrono::Utc::now());
    assert!(
        ctx.mount_ra_hours.is_none() && ctx.mount_altitude_deg.is_none(),
        "precondition: no mount answered for this frame"
    );

    // `None` is exactly what `read_mount_pointing` returns with no mount
    // connected — the state the rig was in.
    let header = build_rich_header(&tiny_frame(), &ctx, None);

    let scratch = temp_scratch_dir("mountless_save_path");
    let path = scratch.as_ref().join("mountless_0001.fits");
    crate::api::save_fits_file_rich(
        path.to_string_lossy().to_string(),
        4,
        4,
        vec![0u16; 16],
        header,
    )
    .await
    .expect("FITS save should succeed");

    let (_image, parsed) = read_fits(&path).expect("FITS read-back should succeed");

    let alt = parsed
        .get_float("OBJCTALT")
        .expect("a mountless sequencer frame must still record its altitude");
    assert!(
        (alt - SITE_LAT).abs() < 0.05,
        "the pole sits at the observer's latitude {SITE_LAT}, got OBJCTALT {alt}"
    );
    // Physics, not a second run of the formula: a refracting atmosphere is
    // always a slightly shorter path than the plane-parallel sec z.
    let airmass = parsed
        .get_float("AIRMASS")
        .expect("AIRMASS follows from a recorded altitude");
    let plane_parallel = 1.0 / (90.0 - SITE_LAT).to_radians().cos();
    assert!(
        airmass < plane_parallel && plane_parallel - airmass < 0.02,
        "AIRMASS {airmass} is not just below the plane-parallel ceiling {plane_parallel}"
    );
    // ...and it describes the direction the file is labelled with.
    let ra_deg = parsed.get_float("RA").expect("RA card must be present");
    assert!(
        (ra_deg - 2.5303 * 15.0).abs() < 1e-6,
        "RA card should be the target's 2.5303h in degrees, got {ra_deg}"
    );
    assert_eq!(parsed.get_float("DEC"), Some(90.0));
}

/// The mount's reported pointing wins over the target's nominal coordinates,
/// even when a Target group is present: an unedited "New Target" carries
/// 0h/0°, which would stamp that onto frames the mount took 17h away.
#[tokio::test]
async fn mount_pointing_wins_over_nominal_target_coordinates() {
    let mut ctx = FrameContext::new_light("sess-targeted", 1, 1, 3.0, 1);
    ctx.target_name = Some("New Target".to_string());
    ctx.target_ra_hours = Some(0.0);
    ctx.target_dec_degrees = Some(0.0);

    let header = build_rich_header(
        &tiny_frame(),
        &ctx,
        Some(MountPointing {
            ra_hours: 17.0,
            dec_degrees: 30.0,
            altitude_deg: None,
        }),
    );

    assert_eq!(header.ra, Some(17.0), "RA must come from the mount");
    assert_eq!(header.dec, Some(30.0), "DEC must come from the mount");
    // OBJECT still names the target — only the coordinates change source.
    assert_eq!(header.object_name.as_deref(), Some("New Target"));
}

/// The reported defect: a sequenced frame landed in `captured_images` with
/// no gain, offset, sensor temperature, pointing, focuser position or
/// rotator angle, while the FITS file written microseconds earlier from the
/// same exposure had all of them — the database and the file disagreeing
/// about one frame.
///
/// This asserts the collapse. One `FrameContext` is built, the real FITS
/// file is written from it and read back off disk, and every card is
/// checked against the `FrameCaptureMetadata` the frame event carries —
/// which is exactly what the Dart listener writes the row from. If the two
/// surfaces ever get separate sources again, this fails.
#[tokio::test]
async fn database_row_and_fits_header_agree_for_the_same_frame() {
    let mut ctx = FrameContext::new_light("sess-agree", 2, 2, 120.0, 7);
    ctx.frame_type = "Dark".to_string();
    ctx.target_id = Some("tgt-agree".to_string());
    ctx.gain = Some(139);
    ctx.offset = Some(21);
    ctx.sensor_temp_c = Some(-9.5);
    ctx.cooler_power_percent = Some(63.5);
    ctx.focuser_position = Some(31_705);
    ctx.focuser_temperature_c = Some(4.25);
    ctx.rotator_angle_deg = Some(212.5);
    ctx.mount_ra_hours = Some(5.5);
    ctx.mount_dec_degrees = Some(-5.25);
    ctx.mount_altitude_deg = Some(48.5);
    ctx.mount_azimuth_deg = Some(171.25);
    ctx.pier_side = Some("West".to_string());

    // What the database row is written from.
    let capture = skotiq_sequencer::scheduling::FrameCaptureMetadata::from(&ctx);

    // What the file on disk is written from. `tiny_frame()` deliberately
    // reports a DIFFERENT gain/offset/temperature/exposure than the
    // context: the header must not quietly prefer a second source.
    let header = build_rich_header(&tiny_frame(), &ctx, None);
    let scratch = temp_scratch_dir("agree");
    let path = scratch.as_ref().join("agree_0007.fits");
    crate::api::save_fits_file_rich(
        path.to_string_lossy().to_string(),
        4,
        4,
        vec![0u16; 16],
        header,
    )
    .await
    .expect("FITS save should succeed");
    let (_image, parsed) = read_fits(&path).expect("FITS read-back should succeed");

    assert_eq!(
        parsed.get_int("GAIN").map(|g| g as i32),
        capture.gain,
        "GAIN card and the row's gain must be the same number"
    );
    assert_eq!(
        parsed.get_int("OFFSET").map(|o| o as i32),
        capture.offset,
        "OFFSET card and the row's offset must be the same number"
    );
    assert_eq!(
        parsed.get_float("CCD-TEMP"),
        capture.sensor_temp_c,
        "CCD-TEMP card and the row's sensor_temp must be the same number"
    );
    assert_eq!(
        parsed.get_float("EXPTIME"),
        Some(capture.exposure_secs),
        "EXPTIME card and the row's exposure_duration must be the same number"
    );
    assert_eq!(
        parsed.get_int("XBINNING").map(|b| b as u32),
        Some(capture.bin_x),
        "XBINNING card and the row's bin_x must be the same number"
    );
    assert_eq!(
        parsed.get_int("YBINNING").map(|b| b as u32),
        Some(capture.bin_y),
        "YBINNING card and the row's bin_y must be the same number"
    );
    assert_eq!(
        parsed.get_string("IMAGETYP"),
        Some(capture.frame_type.as_str()),
        "IMAGETYP card and the row's frame_type must describe the same frame"
    );
    assert_eq!(
        parsed.get_int("FOCUSPOS").map(|p| p as i32),
        capture.focuser_position,
        "FOCUSPOS card and the row's focuser_position must be the same number"
    );
    assert_eq!(
        parsed.get_float("FOCTEMP"),
        capture.focuser_temperature_c,
        "FOCTEMP card and the row's focuser_temp must be the same number"
    );
    assert_eq!(
        parsed.get_float("ROTATPOS"),
        capture.rotator_angle_deg,
        "ROTATPOS card and the row's rotator_angle must be the same number"
    );
    // The numeric RA card is degrees by universal convention while both
    // the row and the context carry hours, so this is the one field where
    // agreement means "the same pointing", not "the same number".
    let ra_deg = parsed.get_float("RA").expect("RA card must be present");
    assert!(
        (ra_deg / 15.0 - capture.mount_ra_hours.expect("row carries the pointing")).abs() < 1e-9,
        "RA card ({ra_deg}°) and the row's mount_ra must be the same pointing"
    );
    assert_eq!(
        parsed.get_float("DEC"),
        capture.mount_dec_degrees,
        "DEC card and the row's mount_dec must be the same number"
    );

    // Columns with no FITS card of their own still have to come off the
    // same struct, or they are back to being invented somewhere else.
    assert_eq!(capture.cooler_power_percent, Some(63.5));
    assert_eq!(capture.mount_altitude_deg, Some(48.5));
    assert_eq!(capture.mount_azimuth_deg, Some(171.25));
    assert_eq!(capture.pier_side.as_deref(), Some("West"));
    assert_eq!(capture.target_id.as_deref(), Some("tgt-agree"));
}

/// No connected mount (or a driver that will not answer) must not make the
/// header worse than it was: the target coordinates remain the fallback,
/// and nothing is invented.
#[test]
fn missing_mount_falls_back_to_target_coordinates() {
    let mut ctx = FrameContext::new_light("sess-nomount", 1, 1, 3.0, 1);
    ctx.target_ra_hours = Some(20.967);
    ctx.target_dec_degrees = Some(44.333);

    let header = build_rich_header(&tiny_frame(), &ctx, None);

    assert_eq!(header.ra, Some(20.967));
    assert_eq!(header.dec, Some(44.333));
    assert_eq!(header.altitude, None);
}

// AIRMASS: the site the sequencer was seeded with vs the site app settings
// knows about.

/// A run whose executor never received a location produces pointing with no
/// altitude. Skipping the mount read (correct — the pointing is already
/// here) must not also skip resolving the altitude, or the frame loses
/// AIRMASS while the app has the site sitting in settings.
#[test]
fn context_pointing_without_altitude_resolves_it_from_app_settings() {
    let mut ctx = FrameContext::new_light("sess-nosite", 1, 1, 3.0, 1);
    ctx.mount_ra_hours = Some(17.0);
    ctx.mount_dec_degrees = Some(30.0);
    assert!(
        ctx.mount_altitude_deg.is_none(),
        "precondition: an unseeded executor derives no altitude"
    );

    let when = chrono::DateTime::parse_from_rfc3339("2026-08-02T04:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let resolved = context_altitude_pointing(&ctx, Some((40.0, -75.0)), when)
        .expect("app settings knows the site, so the altitude is derivable");

    // The coordinates are the CONTEXT's own — the point of the fallback is
    // that it adds geometry, not a second mount read.
    assert_eq!(resolved.ra_hours, 17.0);
    assert_eq!(resolved.dec_degrees, 30.0);
    let altitude = resolved.altitude_deg.expect("altitude derived");
    assert!(
        (altitude - altitude_degrees(17.0, 30.0, 40.0, -75.0, when)).abs() < 1e-9,
        "altitude must be the same geometry the mount-read path uses"
    );

    // ... and it has to actually reach the card.
    let header = build_rich_header(&tiny_frame(), &ctx, Some(resolved));
    assert_eq!(header.ra, Some(17.0));
    assert_eq!(header.altitude, Some(altitude));
}

#[test]
fn context_altitude_wins_and_no_site_stays_absent() {
    let mut ctx = FrameContext::new_light("sess-site", 1, 1, 3.0, 1);
    ctx.mount_ra_hours = Some(17.0);
    ctx.mount_dec_degrees = Some(30.0);
    let when = chrono::Utc::now();

    // Nothing to add when the sequencer already derived the altitude: its
    // value was computed at capture time, which is closer to the truth than
    // anything recomputed at save time.
    ctx.mount_altitude_deg = Some(52.0);
    assert!(context_altitude_pointing(&ctx, Some((40.0, -75.0)), when).is_none());
    assert_eq!(
        build_rich_header(&tiny_frame(), &ctx, None).altitude,
        Some(52.0)
    );

    // No site anywhere: AIRMASS stays absent rather than being computed
    // from a guessed location.
    ctx.mount_altitude_deg = None;
    assert!(context_altitude_pointing(&ctx, None, when).is_none());
    assert_eq!(build_rich_header(&tiny_frame(), &ctx, None).altitude, None);
}

/// `save_fits` is the only place that decides WHICH context the header gets
/// built from and what fallback pointing rides along with it. Both are
/// invisible to every test that calls `build_rich_header` directly, so this
/// one drives the real method: hand `build_rich_header` anything but the
/// context `save_fits` received, or drop the altitude fallback, and the
/// file on disk changes.
#[tokio::test]
async fn save_fits_writes_the_header_from_its_own_frame_context() {
    let app_state = crate::state::AppState::new();
    app_state
        .set_observer_location(Some(crate::storage::ObserverLocation {
            latitude: 40.0,
            longitude: -75.0,
            elevation: 200.0,
        }))
        .expect("observer location");
    let ops = UnifiedDeviceOps::new(app_state);

    let mut ctx = FrameContext::new_light("sess-savefits", 3, 3, 90.0, 1);
    ctx.mount_ra_hours = Some(17.0);
    // Circumpolar from 40 N (min altitude 35 deg), so this assertion does not
    // depend on the wall clock. At Dec +30 the target is below the horizon for
    // part of every day and AIRMASS is CORRECTLY omitted, which made this test
    // pass or fail depending on the time of day it was run.
    ctx.mount_dec_degrees = Some(85.0);
    // Deliberately unset: this is the seeded-site gap the AIRMASS fallback
    // exists for.
    ctx.mount_altitude_deg = None;
    // Every value below differs from `tiny_frame()`'s, so a header built
    // from anything other than THIS struct is visible in the file.
    ctx.gain = Some(139);
    ctx.offset = Some(21);
    ctx.sensor_temp_c = Some(-9.5);
    ctx.focuser_position = Some(31_705);
    ctx.rotator_angle_deg = Some(212.5);
    ctx.camera_pixel_size_x_um = Some(3.76);
    ctx.camera_pixel_size_y_um = Some(3.76);

    let scratch = temp_scratch_dir("save_fits_ctx");
    let path = scratch.as_ref().join("save_fits_ctx_0001.fits");
    skotiq_sequencer::DeviceOps::save_fits(&ops, &tiny_frame(), &path.to_string_lossy(), &ctx)
        .await
        .expect("save should succeed");

    let (_image, parsed) = read_fits(&path).expect("FITS read-back should succeed");

    assert_eq!(parsed.get_int("GAIN").map(|g| g as i32), Some(139));
    assert_eq!(parsed.get_int("OFFSET").map(|o| o as i32), Some(21));
    assert_eq!(parsed.get_float("CCD-TEMP"), Some(-9.5));
    assert_eq!(parsed.get_float("EXPTIME"), Some(90.0));
    assert_eq!(parsed.get_int("XBINNING").map(|b| b as u32), Some(3));
    assert_eq!(parsed.get_int("FOCUSPOS").map(|p| p as i32), Some(31_705));
    assert_eq!(parsed.get_float("ROTATPOS"), Some(212.5));
    let ra_deg = parsed.get_float("RA").expect("RA card must be present");
    assert!((ra_deg - 17.0 * 15.0).abs() < 1e-6, "RA card was {ra_deg}");

    // The plate scale a stacker needs. This card was absent from every
    // sequenced frame because the header builder hardcoded the pitch to
    // None; 3.76 um binned 3x3 reads out as 11.28 um pixels.
    let xpixsz = parsed.get_float("XPIXSZ").expect("XPIXSZ card");
    assert!(
        (xpixsz - 11.28).abs() < 1e-6,
        "XPIXSZ must be the binned pitch, got {xpixsz}"
    );

    assert!(
        parsed.get_float("AIRMASS").is_some(),
        "a sequenced frame must keep AIRMASS when app settings knows the \
         site, even though the sequencer's own location seed did not"
    );
}

/// OBJCTALT/AIRMASS describe the light the frame integrated, so they are
/// evaluated at the exposure midpoint — not at the moment the file is
/// written.
///
/// `save_fits` runs after readout, so deriving the altitude from
/// `Utc::now()` here dated it by the whole exposure plus download. The rig
/// below makes that error unmissable and, deliberately, clock-independent:
/// the mount is pointed at whatever is culminating RIGHT NOW, so the
/// save-time answer is the target's maximum altitude while the midpoint —
/// six hours earlier — is measurably lower, whatever time of day the suite
/// runs. Dec +85 keeps it circumpolar from 40 N so both instants are above
/// the horizon and AIRMASS exists either way.
#[tokio::test]
async fn save_fits_derives_the_altitude_at_the_exposure_midpoint() {
    const LAT: f64 = 40.0;
    const LON: f64 = -75.0;

    let app_state = crate::state::AppState::new();
    app_state
        .set_observer_location(Some(crate::storage::ObserverLocation {
            latitude: LAT,
            longitude: LON,
            elevation: 200.0,
        }))
        .expect("observer location");
    let ops = UnifiedDeviceOps::new(app_state);

    let now = chrono::Utc::now();
    let ra_hours = skotiq_sequencer::meridian::local_sidereal_time(
        skotiq_sequencer::meridian::julian_day(&now),
        LON,
    )
    .rem_euclid(24.0);

    let mut ctx = FrameContext::new_light("sess-midpoint", 1, 1, 7200.0, 1);
    ctx.mount_ra_hours = Some(ra_hours);
    ctx.mount_dec_degrees = Some(85.0);
    // The seeded-site gap: the sequencer derived no altitude, so this save
    // is the one that decides which instant the geometry belongs to.
    ctx.mount_altitude_deg = None;
    // Shutter opened 7 h ago and stayed open 2 h, so the midpoint is 6 h
    // back while `Utc::now()` is culmination.
    ctx.exposure_started_at = Some(now - chrono::Duration::hours(7));

    let scratch = temp_scratch_dir("save_fits_midpoint");
    let path = scratch.as_ref().join("midpoint_0001.fits");
    skotiq_sequencer::DeviceOps::save_fits(&ops, &tiny_frame(), &path.to_string_lossy(), &ctx)
        .await
        .expect("save should succeed");

    let (_image, parsed) = read_fits(&path).expect("FITS read-back should succeed");
    let recorded = parsed
        .get_float("OBJCTALT")
        .expect("OBJCTALT card must be present");

    let at_midpoint = altitude_degrees(ra_hours, 85.0, LAT, LON, now - chrono::Duration::hours(6));
    let at_save_time = altitude_degrees(ra_hours, 85.0, LAT, LON, now);
    assert!(
        (at_save_time - at_midpoint).abs() > 1.0,
        "test rig is not discriminating: save-time {at_save_time:.4} deg vs \
         midpoint {at_midpoint:.4} deg"
    );
    assert!(
        (recorded - at_midpoint).abs() < 0.01,
        "OBJCTALT was {recorded:.4} deg; the exposure midpoint is \
         {at_midpoint:.4} deg and save time is {at_save_time:.4} deg"
    );
}
