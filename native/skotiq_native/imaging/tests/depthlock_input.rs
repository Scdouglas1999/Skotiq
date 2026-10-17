//! DepthLock ingestion helpers: the file-facing checks in
//! `depthlock::input` that turn a saved frame into admissible evidence.

use skotiq_imaging::depthlock::input::{
    calibrate_signed, check_compatible, date_obs_ms, light_identity, light_settings, reference_wcs,
    registered_wcs, source_mask, validate_master, AcquisitionSettings, CompatibilityPolicy,
    MasterKind, ReferenceGeometry, SATURATION_ADU,
};
use skotiq_imaging::registration::{RegistrationStats, TransformKind, TransformModel};
use skotiq_imaging::{FitsHeader, ImageData, SipWcs};

fn u16_image(width: u32, height: u32, fill: u16) -> ImageData {
    ImageData::from_u16(width, height, 1, &vec![fill; (width * height) as usize])
}

fn f32_image(width: u32, height: u32, fill: f32) -> ImageData {
    ImageData::from_f32(width, height, 1, &vec![fill; (width * height) as usize])
}

fn reference() -> SipWcs {
    // 1.5"/px, 12° rotation, flipped x — an ordinary refractor frame.
    let s = 1.5 / 3600.0;
    let a = 12f64.to_radians();
    SipWcs::tan_only(
        83.8221,
        -5.3911,
        512.5,
        384.5,
        -s * a.cos(),
        s * a.sin(),
        s * a.sin(),
        s * a.cos(),
    )
}

fn good_stats() -> RegistrationStats {
    RegistrationStats {
        reference_star_count: 40,
        frame_star_count: 38,
        correspondence_count: 30,
        inlier_count: 28,
        inlier_fraction: 28.0 / 30.0,
        rms_residual_px: 0.21,
        rms_residual_arcsec: None,
    }
}

fn similarity(theta_deg: f64, scale: f64, tx: f64, ty: f64, flip: bool) -> TransformModel {
    let t = theta_deg.to_radians();
    let (c, s) = (t.cos() * scale, t.sin() * scale);
    let fx = if flip { -1.0 } else { 1.0 };
    TransformModel {
        matrix: [[c * fx, -s, tx], [s * fx, c, ty], [0.0, 0.0, 1.0]],
        kind: TransformKind::Similarity,
    }
}

/// The composed frame WCS must send every frame pixel to the same sky
/// position the reference WCS assigns to that pixel's registered location —
/// for a dither (translation), a flip, and a reframe (rotation + shift).
#[test]
fn registered_wcs_agrees_with_reference_through_the_transform() {
    let reference = reference();
    for (label, transform) in [
        ("dither", similarity(0.0, 1.0, 13.7, -8.2, false)),
        (
            "meridian flip",
            similarity(180.0, 1.0, 1027.3, 771.9, false),
        ),
        ("mirror", similarity(0.0, 1.0, 1024.0, 0.0, true)),
        ("reframe", similarity(37.0, 1.0, -210.4, 55.1, false)),
        ("scale drift", similarity(-4.0, 1.004, 3.0, 2.0, false)),
    ] {
        let frame = registered_wcs(&reference, &transform, &good_stats())
            .unwrap_or_else(|e| panic!("{label}: {e}"));
        for (x, y) in [(0.0, 0.0), (100.0, 700.0), (900.0, 50.0), (512.0, 384.0)] {
            let (rx, ry) = transform.apply(x, y);
            let (ra_ref, dec_ref) = reference.pixel_to_world(rx, ry);
            let (ra, dec) = frame.pixel_to_world(x, y);
            assert!(
                (ra - ra_ref).abs() < 1e-9 && (dec - dec_ref).abs() < 1e-9,
                "{label} at ({x},{y}): frame ({ra},{dec}) vs reference ({ra_ref},{dec_ref})"
            );
        }
    }
}

#[test]
fn registered_wcs_refuses_loose_or_wrong_fits() {
    let reference = reference();
    let ok = similarity(0.0, 1.0, 5.0, 5.0, false);
    assert!(registered_wcs(&reference, &ok, &good_stats()).is_ok());

    let scaled = similarity(0.0, 1.02, 5.0, 5.0, false);
    assert!(registered_wcs(&reference, &scaled, &good_stats()).is_err());

    let mut affine = ok;
    affine.kind = TransformKind::Affine;
    assert!(registered_wcs(&reference, &affine, &good_stats()).is_err());

    let mut few = good_stats();
    few.inlier_count = 7;
    assert!(registered_wcs(&reference, &ok, &few).is_err());

    let mut loose = good_stats();
    loose.rms_residual_px = 0.8;
    assert!(registered_wcs(&reference, &ok, &loose).is_err());

    let mut disagreeing = good_stats();
    disagreeing.inlier_fraction = 0.6;
    assert!(registered_wcs(&reference, &ok, &disagreeing).is_err());
}

#[test]
fn reference_geometry_freezes_and_validates_a_wcs() {
    let geometry = ReferenceGeometry::from_wcs(&reference(), 1024, 768).unwrap();
    assert!((geometry.pixel_scale_arcsec() - 1.5).abs() < 1e-9);
    let back = geometry.wcs();
    let (ra, dec) = back.pixel_to_world(10.0, 20.0);
    let (ra_ref, dec_ref) = reference().pixel_to_world(10.0, 20.0);
    assert!((ra - ra_ref).abs() < 1e-12 && (dec - dec_ref).abs() < 1e-12);

    let singular = SipWcs::tan_only(83.0, -5.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);
    assert!(ReferenceGeometry::from_wcs(&singular, 1024, 768).is_err());
    let polar = SipWcs::tan_only(83.0, 88.0, 1.0, 1.0, 1e-4, 0.0, 0.0, 1e-4);
    assert!(ReferenceGeometry::from_wcs(&polar, 1024, 768).is_err());
    assert!(ReferenceGeometry::from_wcs(&reference(), 8, 8).is_err());
}

fn tan_header() -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("CTYPE1", "RA---TAN");
    h.set_string("CTYPE2", "DEC--TAN");
    h.set_string("RADESYS", "ICRS");
    h.set_float("CRVAL1", 83.8221);
    h.set_float("CRVAL2", -5.3911);
    h.set_float("CRPIX1", 512.5);
    h.set_float("CRPIX2", 384.5);
    h
}

#[test]
fn reference_wcs_reads_cd_and_cdelt_forms_and_refuses_sip() {
    let mut cd = tan_header();
    cd.set_float("CD1_1", -4e-4);
    cd.set_float("CD1_2", 1e-5);
    cd.set_float("CD2_1", 1e-5);
    cd.set_float("CD2_2", 4e-4);
    let wcs = reference_wcs(&cd).unwrap();
    assert_eq!(wcs.cd1_1, -4e-4);

    let mut cdelt = tan_header();
    cdelt.set_float("CDELT1", -4e-4);
    cdelt.set_float("CDELT2", 4e-4);
    cdelt.set_float("CROTA2", 0.0);
    let wcs = reference_wcs(&cdelt).unwrap();
    assert!((wcs.cd1_1 + 4e-4).abs() < 1e-12 && (wcs.cd2_2 - 4e-4).abs() < 1e-12);

    let mut sip = cd.clone();
    sip.set_int("A_ORDER", 2);
    assert!(reference_wcs(&sip).is_err());

    let mut unstated = cd.clone();
    unstated.set_string("RADESYS", "FK4");
    assert!(reference_wcs(&unstated).is_err());

    let mut fk5 = cd.clone();
    fk5.set_string("RADESYS", "FK5");
    fk5.set_float("EQUINOX", 2000.0);
    assert!(reference_wcs(&fk5).is_ok());
}

#[test]
fn calibration_accepts_both_master_encodings_and_marks_bad_pixels() {
    let mut light = u16_image(16, 16, 1_020);
    let pixels: Vec<u16> = light
        .as_u16()
        .unwrap()
        .iter()
        .enumerate()
        .map(|(i, v)| match i {
            0 => 65_000, // saturated
            _ => *v,
        })
        .collect();
    light = ImageData::from_u16(16, 16, 1, &pixels);
    let dark = u16_image(16, 16, 1_000);

    // Skotiq F32 flat: unit mean, one vignetted pixel and one dead pixel.
    let mut f32_flat: Vec<f32> = vec![1.0; 256];
    f32_flat[1] = 0.8;
    f32_flat[2] = 0.1;
    let flat_f32 = ImageData::from_f32(16, 16, 1, &f32_flat);
    // The same flat in Skotiq's U16 encoding (mean 32768).
    let flat_u16: Vec<u16> = f32_flat.iter().map(|v| (v * 32768.0) as u16).collect();
    let flat_u16 = ImageData::from_u16(16, 16, 1, &flat_u16);

    let a = calibrate_signed(&light, &dark, &flat_f32).unwrap();
    let b = calibrate_signed(&light, &dark, &flat_u16).unwrap();
    assert!(a[0].is_nan(), "saturated light pixel");
    assert!(
        (a[1] - 25.0).abs() < 1e-5,
        "vignetted pixel is corrected: {}",
        a[1]
    );
    assert!(a[2].is_nan(), "dead flat pixel is unusable, not zero");
    assert!((a[3] - 20.0).abs() < 1e-9);
    for (x, y) in a.iter().zip(&b).skip(3) {
        assert!((x - y).abs() < 1e-3, "encodings agree: {x} vs {y}");
    }

    let f32_light = f32_image(16, 16, 1.0);
    assert!(
        calibrate_signed(&f32_light, &dark, &flat_f32).is_err(),
        "lights must be camera-native U16"
    );
    let small_dark = u16_image(8, 8, 1_000);
    assert!(calibrate_signed(&light, &small_dark, &flat_f32).is_err());
    let dead_flat = f32_image(16, 16, 0.0);
    assert!(calibrate_signed(&light, &dark, &dead_flat).is_err());
}

#[test]
fn source_mask_covers_saturated_pixels_with_a_disk() {
    let mut pixels = vec![500u16; 64 * 64];
    pixels[32 * 64 + 32] = SATURATION_ADU as u16;
    let light = ImageData::from_u16(64, 64, 1, &pixels);
    let mask = source_mask(&light).unwrap();
    assert!(mask[32 * 64 + 32]);
    assert!(mask[32 * 64 + 40], "12 px disk around a saturated pixel");
    assert!(!mask[0]);
    assert!(!mask[32 * 64 + 50]);
}

fn light_header() -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "Light");
    h.set_string("INSTRUME", "ZWO ASI2600MM Pro");
    h.set_string("FILTER", "L");
    h.set_float("EXPTIME", 120.0);
    h.set_int("GAIN", 100);
    h.set_int("OFFSET", 50);
    h.set_int("XBINNING", 1);
    h.set_int("YBINNING", 1);
    h.set_float("CCD-TEMP", -10.2);
    h.set_string("DATE-OBS", "2026-09-11T03:14:15.926");
    h
}

#[test]
fn identity_prefers_skotiq_session_cards_and_is_stable_on_reprocessing() {
    let light = u16_image(16, 16, 900);
    let mut h = light_header();
    let plain = light_identity(&h, &light).unwrap();
    assert!(plain.frame_id.starts_with("px:"));
    assert_eq!(
        plain.acquired_at_ms,
        date_obs_ms("2026-09-11T03:14:15.926").unwrap()
    );
    assert_eq!(
        light_identity(&h, &light).unwrap(),
        plain,
        "same bytes, same identity"
    );

    let other = u16_image(16, 16, 901);
    assert_ne!(light_identity(&h, &other).unwrap().frame_id, plain.frame_id);

    h.set_string("SK-SESID", "7f1c2a");
    h.set_int("SK-FIDX", 12);
    let id = light_identity(&h, &light).unwrap();
    assert_eq!(id.frame_id, "sk:7f1c2a:12");

    // Pre-rename frames carry NS-SESID/NS-FIDX and land on the same identity.
    let mut legacy = light_header();
    legacy.set_string("NS-SESID", "7f1c2a");
    legacy.set_int("NS-FIDX", 12);
    assert_eq!(
        light_identity(&legacy, &light).unwrap().frame_id,
        "sk:7f1c2a:12"
    );

    h.set_string("DATE-OBS", "not a date");
    assert!(light_identity(&h, &light).is_err());
    let mut no_date = light_header();
    no_date.keywords.remove("DATE-OBS");
    assert!(light_identity(&no_date, &light).is_err());
}

#[test]
fn date_obs_accepts_fractional_and_whole_seconds() {
    assert_eq!(
        date_obs_ms("2026-09-11T03:14:15").unwrap() + 926,
        date_obs_ms("2026-09-11T03:14:15.926").unwrap()
    );
    assert_eq!(
        date_obs_ms("2026-09-11T03:14:15Z").unwrap(),
        date_obs_ms("2026-09-11T03:14:15").unwrap()
    );
}

#[test]
fn light_settings_reads_the_acquisition_and_refuses_processed_or_colour_frames() {
    let settings = light_settings(&light_header()).unwrap();
    assert_eq!(
        settings,
        AcquisitionSettings {
            instrument: "ZWO ASI2600MM Pro".into(),
            filter: "L".into(),
            exposure_secs: 120.0,
            gain: Some(100),
            offset: Some(50),
            bin_x: 1,
            bin_y: 1,
            ccd_temp_c: Some(-10.2),
        }
    );
    let mut calibrated = light_header();
    calibrated.set_string("CALSTAT", "calibrated by Skotiq");
    assert!(light_settings(&calibrated).is_err());
    let mut colour = light_header();
    colour.set_string("BAYERPAT", "RGGB");
    assert!(light_settings(&colour).is_err());
    let mut dark = light_header();
    dark.set_string("IMAGETYP", "Dark");
    assert!(light_settings(&dark).is_err());
    let mut nameless = light_header();
    nameless.keywords.remove("INSTRUME");
    assert!(light_settings(&nameless).is_err());
}

#[test]
fn compatibility_refuses_a_changed_acquisition_and_tolerates_small_temperature_drift() {
    let goal = light_settings(&light_header()).unwrap();
    let policy = CompatibilityPolicy::default();
    assert!(check_compatible(&goal, &goal, &policy).is_ok());

    let mut warmer = goal.clone();
    warmer.ccd_temp_c = Some(-9.5);
    assert!(check_compatible(&goal, &warmer, &policy).is_ok());
    warmer.ccd_temp_c = Some(-8.0);
    assert!(check_compatible(&goal, &warmer, &policy)
        .unwrap_err()
        .contains("temperature"));

    let mut other_filter = goal.clone();
    other_filter.filter = "Ha".into();
    assert!(check_compatible(&goal, &other_filter, &policy)
        .unwrap_err()
        .contains("Filter"));

    let mut longer = goal.clone();
    longer.exposure_secs = 180.0;
    assert!(check_compatible(&goal, &longer, &policy)
        .unwrap_err()
        .contains("scale darks"));

    let mut binned = goal.clone();
    binned.bin_x = 2;
    assert!(check_compatible(&goal, &binned, &policy).is_err());

    let mut gainless_light = goal.clone();
    gainless_light.gain = None;
    assert!(check_compatible(&goal, &gainless_light, &policy).is_err());
    let mut gainless_goal = goal.clone();
    gainless_goal.gain = None;
    assert!(check_compatible(&gainless_goal, &gainless_light, &policy).is_ok());
}

fn master_header(kind: &str, frames: i64) -> FitsHeader {
    // Exactly what `api_combine_master_frames` writes.
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", kind);
    h.set_string("FRAMETYP", "MASTER");
    h.set_string("CALSTAT", &format!("Skotiq master {kind}"));
    h.set_int("NFRAMES", frames);
    h.set_string("COMBMETH", "SIGMA_CLIP");
    h.set_string("MASTRTYP", "F32");
    h
}

#[test]
fn skotiq_masters_are_accepted_and_mismatches_are_named() {
    let goal = light_settings(&light_header()).unwrap();
    let geometry = ReferenceGeometry::from_wcs(&reference(), 64, 48).unwrap();
    let dark = f32_image(64, 48, 1_000.0);
    let flat = f32_image(64, 48, 1.0);

    assert!(validate_master(
        MasterKind::Dark,
        &master_header("DARK", 20),
        &dark,
        &goal,
        &geometry
    )
    .is_ok());
    assert!(validate_master(
        MasterKind::Flat,
        &master_header("FLAT", 20),
        &flat,
        &goal,
        &geometry
    )
    .is_ok());
    assert!(
        validate_master(
            MasterKind::Flat,
            &master_header("Master Flat", 20),
            &flat,
            &goal,
            &geometry
        )
        .is_ok(),
        "third-party spellings that still name the kind"
    );

    let err = validate_master(
        MasterKind::Dark,
        &master_header("DARK", 5),
        &dark,
        &goal,
        &geometry,
    )
    .unwrap_err();
    assert!(err.contains("5 frames"), "{err}");
    let err = validate_master(
        MasterKind::Dark,
        &master_header("FLAT", 20),
        &dark,
        &goal,
        &geometry,
    )
    .unwrap_err();
    assert!(err.contains("not a dark"), "{err}");
    let mut raw = master_header("DARK", 20);
    raw.keywords.remove("FRAMETYP");
    assert!(validate_master(MasterKind::Dark, &raw, &dark, &goal, &geometry).is_err());
    let wrong_size = f32_image(32, 48, 1_000.0);
    let err = validate_master(
        MasterKind::Dark,
        &master_header("DARK", 20),
        &wrong_size,
        &goal,
        &geometry,
    )
    .unwrap_err();
    assert!(err.contains("32x48"), "{err}");

    // Acquisition cards, when a master carries them, must agree.
    let mut long_dark = master_header("DARK", 20);
    long_dark.set_float("EXPTIME", 300.0);
    assert!(validate_master(MasterKind::Dark, &long_dark, &dark, &goal, &geometry).is_err());
    let mut ha_flat = master_header("FLAT", 20);
    ha_flat.set_string("FILTER", "Ha");
    assert!(validate_master(MasterKind::Flat, &ha_flat, &flat, &goal, &geometry).is_err());
    let mut other_gain = master_header("DARK", 20);
    other_gain.set_int("GAIN", 200);
    assert!(validate_master(MasterKind::Dark, &other_gain, &dark, &goal, &geometry).is_err());
    let mut same_gain = master_header("DARK", 20);
    same_gain.set_int("GAIN", 100);
    same_gain.set_string("INSTRUME", "zwo asi2600mm pro");
    assert!(validate_master(MasterKind::Dark, &same_gain, &dark, &goal, &geometry).is_ok());
    let u16_dark = u16_image(64, 48, 1_000);
    assert!(validate_master(
        MasterKind::Dark,
        &master_header("DARK", 20),
        &u16_dark,
        &goal,
        &geometry
    )
    .is_ok());
}

/// The suggested floor is the masters' own pixel noise, averaged over the
/// aperture: a noisier dark or flat raises it, a bigger aperture lowers it,
/// and a smooth pattern in the master (amp glow, vignetting) does not count
/// as noise.
#[test]
fn suggested_floor_follows_master_noise_and_aperture() {
    use skotiq_imaging::depthlock::input::suggest_floor;
    let (w, h) = (128u32, 96u32);
    let n = (w * h) as usize;
    let mut seed = 42u64;
    let mut gauss = || {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let u = ((seed >> 11) as f64 / (1u64 << 53) as f64).max(1e-12);
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let v = (seed >> 11) as f64 / (1u64 << 53) as f64;
        (-2.0 * u.ln()).sqrt() * (2.0 * std::f64::consts::PI * v).cos()
    };
    // Dark: 500 ADU pedestal + smooth glow gradient + 2 ADU pixel noise.
    let dark: Vec<f32> = (0..n)
        .map(|i| (500.0 + 0.5 * (i % w as usize) as f64 + 2.0 * gauss()) as f32)
        .collect();
    let dark = ImageData::from_f32(w, h, 1, &dark);
    // Flat: unit mean with 0.5% pixel noise.
    let flat: Vec<f32> = (0..n).map(|_| (1.0 + 0.005 * gauss()) as f32).collect();
    let flat = ImageData::from_f32(w, h, 1, &flat);
    // Light: dark + 1000 ADU sky + 20 ADU noise.
    let light: Vec<u16> = (0..n)
        .map(|_| (1500.0 + 20.0 * gauss()).round() as u16)
        .collect();
    let light = ImageData::from_u16(w, h, 1, &light);

    let five = suggest_floor(&dark, &flat, &light, 5.0).unwrap();
    assert!((five.dark_noise_adu - 2.0).abs() < 0.4, "{five:?}");
    assert!((five.flat_relative_noise - 0.005).abs() < 0.001, "{five:?}");
    assert!((five.sky_adu - 1000.0).abs() < 60.0, "{five:?}");
    // hypot(2, 0.005 * 1000 = 5) ≈ 5.4 ADU per pixel, / 5 ≈ 1.08.
    assert!((five.floor_adu - 1.08).abs() < 0.2, "{five:?}");
    let ten = suggest_floor(&dark, &flat, &light, 10.0).unwrap();
    assert!((ten.floor_adu * 2.0 - five.floor_adu).abs() < 0.05);
    assert!(five.source.contains("Derived from the masters"));

    let quiet_dark = ImageData::from_f32(w, h, 1, &vec![500.0; n]);
    let quiet = suggest_floor(&quiet_dark, &flat, &light, 5.0).unwrap();
    assert!(quiet.floor_adu < five.floor_adu);
    assert!(suggest_floor(&dark, &flat, &light, 0.5).is_err());
}
