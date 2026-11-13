//! The exact header cards a saved frame carries, card by card.
//!
//! The sequence goldens pin what every sequenced frame on disk looks like (key,
//! value text, order), so a change to the header builder that moves one byte
//! of a sequence frame fails here. The manual golden pins what a manual
//! capture carries when no device of the rig answers. The rig test reproduces a real
//! header from the owner's rig (run `refactor1`, 2026-11-11, frame
//! `untangle baseline field_L_0012.fits`): all 45 keys, in order, with the
//! value text the app's header reader returned for it.

use skotiq_sequencer::scheduling::{DefectMapCorrectionRecord, FrameContext};
use skotiq_sequencer::{ImageData as SeqImageData, MosaicPanelInfo};

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "sk_header_golden_{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn file(&self, name: &str) -> String {
        self.0.join(name).to_string_lossy().to_string()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The header's cards up to and including END, trailing blanks trimmed.
fn header_cards(path: &str) -> Vec<String> {
    let bytes = std::fs::read(path).expect("read written FITS");
    let mut cards = Vec::new();
    for card in bytes.chunks(80) {
        let text = String::from_utf8_lossy(card).trim_end().to_string();
        let end = text == "END";
        cards.push(text);
        if end {
            return cards;
        }
    }
    panic!("no END card in {path}");
}

fn card_value_text(path: &str, key: &str) -> String {
    header_cards(path)
        .into_iter()
        .find(|card| card[..card.len().min(8)].trim_end() == key)
        .map(|card| card[10..].trim().to_string())
        .unwrap_or_default()
}

fn assert_cards(path: &str, expected: &[&str]) {
    let actual = header_cards(path);
    if actual != expected {
        panic!(
            "header cards differ.\n--- expected\n{}\n--- actual\n{}",
            expected.join("\n"),
            actual.join("\n")
        );
    }
}

fn seq_frame(width: u32, height: u32) -> SeqImageData {
    SeqImageData {
        width,
        height,
        data: vec![1000; (width * height) as usize],
        bits_per_pixel: 16,
        exposure_secs: 0.0,
        gain: None,
        offset: None,
        temperature: None,
        filter: None,
        timestamp: 0,
        sensor_type: None,
        color_filter: None,
        camera_file: None,
        readout_mode: None,
    }
}

fn at(text: &str) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&chrono::Utc)
}

/// What a sequenced frame's context carries with every field the header
/// builder reads set.
fn full_frame_context() -> FrameContext {
    let mut ctx = FrameContext::new_light("session-uuid-abc", 2, 2, 60.0, 7);
    ctx.exposure_started_at = Some(at("2026-03-14T03:21:09Z"));
    ctx.target_name = Some("M31".to_string());
    ctx.target_ra_hours = Some(0.7123);
    ctx.target_dec_degrees = Some(41.269);
    ctx.mount_ra_hours = Some(0.7125);
    ctx.mount_dec_degrees = Some(41.27);
    ctx.mount_altitude_deg = Some(55.25);
    ctx.pier_side = Some("West".to_string());
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
    ctx.rig_label = Some("Rig B".to_string());
    ctx.defect_map_correction = Some(DefectMapCorrectionRecord {
        camera_id: "native:zwo:ASI2600MM".to_string(),
        defect_count: 120,
        corrected_count: 118,
        kernel_diameter: 5,
        method: "median".to_string(),
    });
    ctx
}

#[tokio::test]
async fn a_sequence_frame_with_every_field_writes_these_cards() {
    let scratch = Scratch::new("sequence_full");
    let path = scratch.file("frame.fits");
    let ops = crate::unified_device_ops::create_unified_device_ops();
    ops.save_fits(&seq_frame(8, 8), &path, &full_frame_context())
        .await
        .expect("sequence save");

    assert_cards(&path, SEQUENCE_FULL);
}

#[tokio::test]
async fn a_photometry_frame_writes_these_cards() {
    let scratch = Scratch::new("sequence_photometry");
    let path = scratch.file("frame.fits");
    let mut ctx = FrameContext::new_light("phot", 1, 1, 120.0, 3);
    ctx.exposure_started_at = Some(at("2026-03-14T03:21:09.250Z"));
    ctx.frame_type = "Light".to_string();
    ctx.target_name = Some("SS Cyg".to_string());
    ctx.photometry_object_catalog = Some("AAVSO 000-BCP-220".to_string());
    ctx.photometry_reference_stars = Some(
        (1..=12)
            .map(|i| format!("000-BCP-{i:03}"))
            .collect::<Vec<_>>(),
    );
    ctx.photometry_mjd_obs = Some(61113.1404);
    ctx.photometry_instrumental_mag = Some(-7.25);
    ctx.photometry_differential_mag = Some(0.125);
    ctx.photometry_fwhm_arcsec = Some(2.4);
    ctx.photometry_snr = Some(180.5);
    let ops = crate::unified_device_ops::create_unified_device_ops();
    ops.save_fits(&seq_frame(4, 4), &path, &ctx)
        .await
        .expect("photometry save");

    assert_cards(&path, SEQUENCE_PHOTOMETRY);
}

/// A target name longer than one card is saved whole, and so is the frame.
#[tokio::test]
async fn a_frame_with_a_90_character_target_name_is_saved_with_the_whole_name() {
    let scratch = Scratch::new("long_object");
    let path = scratch.file("frame.fits");
    let name = "Sh2-155 Cave Nebula and the dark lanes of the Cepheus Bubble, panel 3 of 4 (north-east) #2";
    assert_eq!(name.len(), 90);
    let mut ctx = FrameContext::new_light("long-object", 1, 1, 120.0, 1);
    ctx.exposure_started_at = Some(at("2026-03-14T03:21:09.250Z"));
    ctx.target_name = Some(name.to_string());
    let ops = crate::unified_device_ops::create_unified_device_ops();
    ops.save_fits(&seq_frame(4, 4), &path, &ctx)
        .await
        .expect("a long target name never fails the save");

    let header = skotiq_imaging::read_fits_header(std::path::Path::new(&path)).unwrap();
    assert_eq!(header.get_string("OBJECT"), Some(name));
    let cards = header_cards(&path);
    let object = cards
        .iter()
        .position(|c| c.starts_with("OBJECT  = '"))
        .unwrap();
    assert!(cards[object + 1].starts_with("CONTINUE  '"), "{cards:#?}");
}

/// A manual capture on a rig with nothing but the camera's frame to go on:
/// the devices it names are not connected, so their cards are left out and
/// the save still succeeds. The cards that tie a frame to a run are absent,
/// and the color pattern comes from the frame.
#[tokio::test]
async fn a_manual_frame_with_no_rig_connected_writes_these_cards() {
    let device_id = "golden_last_capture_no_rig";
    crate::last_frame::store(
        device_id,
        crate::last_frame::RawFrame {
            width: 8,
            height: 8,
            data: vec![1000; 64],
            bayer_pattern: Some(skotiq_device::BayerPattern::Gbrg),
            camera_file: None,
            exposure: crate::last_frame::ExposureRecord {
                started_at: at("2026-03-14T03:21:09.250Z"),
                exposure_secs: 60.0,
                gain: Some(100),
                offset: Some(50),
                temperature: Some(-10.5),
                bits_per_pixel: 16,
                readout_mode: None,
            },
        },
        60.0,
    )
    .await
    .expect("store frame");
    let scratch = Scratch::new("manual_no_rig");
    let path = scratch.file("frame.fits");
    let saved = crate::api::imaging::api_save_fits_from_last_capture(
        device_id.to_string(),
        path.clone(),
        crate::api::imaging::FitsWriteHeader {
            object_name: Some("M31".to_string()),
            exposure_time: 60.0,
            frame_type: "Light".to_string(),
            filter: Some("Ha".to_string()),
            gain: Some(90),
            offset: Some(40),
            bin_x: 2,
            bin_y: 2,
            telescope: Some("Askar 65PHQ".to_string()),
            instrument: Some("ZWO ASI2600MM Pro".to_string()),
            observer: Some("Test Observer".to_string()),
            focal_length: Some(416.0),
            aperture: Some(65.0),
            site_latitude: Some(40.7128),
            site_longitude: Some(-74.0060),
            site_elevation: Some(50.0),
            mount_id: Some("golden_absent_mount".to_string()),
            focuser_id: Some("golden_absent_focuser".to_string()),
            filter_wheel_id: Some("golden_absent_wheel".to_string()),
            rotator_id: Some("golden_absent_rotator".to_string()),
        },
        false,
    )
    .await;
    crate::last_frame::clear(device_id).await;
    saved.expect("save from last capture");

    // The device manager is the process's: a mount another test left
    // connected is read for the pointing, as it would be in the app, so the
    // pointing cards are not this test's to pin.
    let pointing = [
        "RA", "OBJCTRA", "DEC", "OBJCTDEC", "OBJCTALT", "AIRMASS", "EQUINOX", "RADESYS",
    ];
    let actual: Vec<String> = header_cards(&path)
        .into_iter()
        .filter(|card| !pointing.contains(&card[..card.len().min(8)].trim_end()))
        .collect();
    assert_eq!(
        actual,
        MANUAL_NO_RIG,
        "header cards differ.\n--- actual\n{}",
        actual.join("\n")
    );
}

/// The values of the rig frame, as `F-sequence.json` recorded them.
const RIG_HEADER: &[(&str, &str)] = &[
    ("SIMPLE", "T"),
    ("BITPIX", "16"),
    ("NAXIS", "2"),
    ("NAXIS1", "4656"),
    ("NAXIS2", "3520"),
    ("BZERO", "32768"),
    ("BSCALE", "1"),
    ("EXPTIME", "30.0"),
    ("DATE-OBS", "2026-11-11T07:12:06"),
    ("DATE-END", "2026-11-11T07:12:36.000"),
    ("MJD-OBS", "6.1355300069E4"),
    ("IMAGETYP", "Light"),
    ("OBJECT", "untangle baseline field"),
    ("FILTER", "L"),
    ("FILTPOS", "0"),
    ("GAIN", "139"),
    ("OFFSET", "21"),
    ("CCD-TEMP", "7.7000000000E0"),
    ("XBINNING", "1"),
    ("YBINNING", "1"),
    ("PIXSIZE1", "3.8000000000E0"),
    ("XPIXSZ", "3.8000000000E0"),
    ("PIXSIZE2", "3.8000000000E0"),
    ("YPIXSZ", "3.8000000000E0"),
    ("FOCALLEN", "1016.0"),
    ("APTDIA", "248.0"),
    ("TELESCOP", "GSO 10\" F4"),
    ("INSTRUME", "ZWO ASI1600MM-Cool"),
    ("SITELAT", "3.9971900000E1"),
    ("SITELONG", "-7.5357600000E1"),
    ("RA", "6.5294629653E1"),
    ("OBJCTRA", "04 21 10.71"),
    ("DEC", "4.4999923091E1"),
    ("OBJCTDEC", "+44 59 59.72"),
    ("OBJCTALT", "7.6233235797E1"),
    ("AIRMASS", "1.0293887740E0"),
    ("EQUINOX", "2000.0"),
    ("RADESYS", "ICRS"),
    ("PIERSIDE", "East"),
    ("FOCUSPOS", "45342"),
    ("FOCTEMP", "1.3880000114E1"),
    ("GUIDERMS", "2.5470085129E1"),
    ("SK-SESID", "c2b6577d-bcd6-4e3c-a9c0-2d70649ba895"),
    ("SK-FIDX", "1"),
    ("SK-NPLN", "1"),
];

#[tokio::test]
async fn a_sequence_frame_header_matches_the_rig_frame() {
    let mut ctx = FrameContext::new_light("c2b6577d-bcd6-4e3c-a9c0-2d70649ba895", 1, 1, 30.0, 1);
    ctx.exposure_started_at = Some(at("2026-11-11T07:12:06Z"));
    ctx.total_planned_frames = Some(1);
    ctx.target_name = Some("untangle baseline field".to_string());
    ctx.filter_name = Some("L".to_string());
    ctx.filter_index = Some(0);
    ctx.gain = Some(139);
    ctx.offset = Some(21);
    ctx.sensor_temp_c = Some(7.7);
    ctx.camera_pixel_size_x_um = Some(3.8);
    ctx.camera_pixel_size_y_um = Some(3.8);
    ctx.telescope_focal_length_mm = Some(1016.0);
    ctx.telescope_aperture_mm = Some(248.0);
    ctx.telescope_name = Some("GSO 10\" F4".to_string());
    ctx.camera_model = Some("ZWO ASI1600MM-Cool".to_string());
    ctx.site_latitude_deg = Some(39.9719);
    ctx.site_longitude_deg = Some(-75.3576);
    ctx.mount_ra_hours = Some(65.294629653 / 15.0);
    ctx.mount_dec_degrees = Some(44.999923091);
    ctx.mount_altitude_deg = Some(76.233235797);
    ctx.pier_side = Some("East".to_string());
    ctx.focuser_position = Some(45342);
    ctx.focuser_temperature_c = Some(f64::from(13.88_f32));
    ctx.guide_rms_arcsec = Some(25.470085129);

    let scratch = Scratch::new("rig");
    let path = scratch.file("rig.fits");
    let ops = crate::unified_device_ops::create_unified_device_ops();
    ops.save_fits(&seq_frame(4656, 3520), &path, &ctx)
        .await
        .expect("rig-shaped save");

    let header =
        skotiq_imaging::read_frame_header(std::path::Path::new(&path)).expect("read rig header");
    let actual: Vec<(String, String)> = header_cards(&path)
        .iter()
        .map(|card| card[..card.len().min(8)].trim_end().to_string())
        .filter(|key| key != "END")
        .map(|key| {
            // BZERO and BSCALE are consumed by the reader, not kept as
            // keywords; their value is the card's own text.
            let value = header
                .get(&key)
                .map(|value| value.to_header_string())
                .unwrap_or_else(|| card_value_text(&path, &key));
            (key, value)
        })
        .collect();
    let expected: Vec<(String, String)> = RIG_HEADER
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    assert_eq!(actual.len(), 45, "the rig frame carries 45 keys");
    assert_eq!(actual, expected);
}

const SEQUENCE_FULL: &[&str] = &[
    "SIMPLE  =                    T",
    "BITPIX  =                   16",
    "NAXIS   =                    2",
    "NAXIS1  =                    8",
    "NAXIS2  =                    8",
    "BZERO   =                32768",
    "BSCALE  =                    1",
    "EXPTIME =                 60.0",
    "DATE-OBS= '2026-03-14T03:21:09'",
    "DATE-END= '2026-03-14T03:22:09.000'",
    "MJD-OBS =       6.1113139687E4",
    "IMAGETYP= 'Light   '",
    "OBJECT  = 'M31     '",
    "FILTER  = 'Ha      '",
    "FILTPOS =                    5",
    "GAIN    =                  100",
    "OFFSET  =                   50",
    "CCD-TEMP=      -1.0500000000E1",
    "SET-TEMP=                -10.0",
    "XBINNING=                    2",
    "YBINNING=                    2",
    "PIXSIZE1=       3.7600000000E0",
    "XPIXSZ  =       7.5200000000E0",
    "PIXSIZE2=       3.7600000000E0",
    "YPIXSZ  =       7.5200000000E0",
    "BAYERPAT= 'RGGB    '",
    "FOCALLEN=                416.0",
    "APTDIA  =                 65.0",
    "TELESCOP= 'Askar 65PHQ'",
    "INSTRUME= 'ZWO ASI2600MM Pro'",
    "OBSERVER= 'Test Observer'",
    "SITELAT =       4.0712800000E1",
    "SITELONG=      -7.4006000000E1",
    "SITEELEV=                 50.0",
    "RA      =       1.0687500000E1",
    "OBJCTRA = '00 42 45.00'",
    "DEC     =       4.1270000000E1",
    "OBJCTDEC= '+41 16 12.00'",
    "OBJCTALT=       5.5250000000E1",
    "AIRMASS =       1.2161798597E0",
    "EQUINOX =               2000.0",
    "RADESYS = 'ICRS    '",
    "PIERSIDE= 'West    '",
    "FOCUSPOS=                25400",
    "FOCTEMP =       1.2300000000E1",
    "ROTATPOS=       1.2370000000E2",
    "GUIDERMS=      7.8000000000E-1",
    "SOLVRA  =      7.1240000000E-1",
    "SOLVDEC =       4.1269100000E1",
    "PIXSCALE=       1.4200000000E0",
    "CROTA1  =      -1.3000000000E0",
    "CROTA2  =      -1.3000000000E0",
    "SK-SESID= 'session-uuid-abc'",
    "SK-FIDX =                    7",
    "SK-NPLN =                   20",
    "MOSAIC  =                    1",
    "SK-MOSNM= 'M31 Wide'",
    "PANELIDX=                    3",
    "SK-PIDX =                    2",
    "PANELROW=                    1",
    "SK-PROW =                    1",
    "PANELCOL=                    2",
    "SK-PCOL =                    2",
    "SK-NPAN =                    9",
    "SK-RIG  = 'Rig B   '",
    "HISTORY Skotiq applied defect map v1 for camera native:zwo:ASI2600MM: &",
    "HISTORY corrected 118 of 120 defective pixels with 5x5 kernel using median &",
    "HISTORY replacement.",
    "END",
];
const SEQUENCE_PHOTOMETRY: &[&str] = &[
    "SIMPLE  =                    T",
    "BITPIX  =                   16",
    "NAXIS   =                    2",
    "NAXIS1  =                    4",
    "NAXIS2  =                    4",
    "BZERO   =                32768",
    "BSCALE  =                    1",
    "LONGSTRN= 'OGIP 1.0' / Long strings continue on CONTINUE cards",
    "EXPTIME =                120.0",
    "DATE-OBS= '2026-03-14T03:21:09'",
    "DATE-END= '2026-03-14T03:23:09.000'",
    "IMAGETYP= 'Light   '",
    "OBJECT  = 'SS Cyg  '",
    "XBINNING=                    1",
    "YBINNING=                    1",
    "SK-SESID= 'phot    '",
    "SK-FIDX =                    3",
    "OBJCAT  = 'AAVSO 000-BCP-220'",
    "REFSTARS= '000-BCP-001,000-BCP-002,000-BCP-003,000-BCP-004,000-BCP-005,000-BCP&'",
    "CONTINUE  '-006,000-BCP-007,000-BCP-008,000-BCP-009,000-BCP-010,000-BCP-011,00&'",
    "CONTINUE  '0-BCP-012'",
    "MJD-OBS =       6.1113140400E4",
    "INSTRMAG=      -7.2500000000E0",
    "DIFFMAG =      1.2500000000E-1",
    "FWHM    =       2.4000000000E0",
    "SNR     =       1.8050000000E2",
    "END",
];

const MANUAL_NO_RIG: &[&str] = &[
    "SIMPLE  =                    T",
    "BITPIX  =                   16",
    "NAXIS   =                    2",
    "NAXIS1  =                    8",
    "NAXIS2  =                    8",
    "BZERO   =                32768",
    "BSCALE  =                    1",
    "EXPTIME =                 60.0",
    "DATE-OBS= '2026-03-14T03:21:09'",
    "DATE-END= '2026-03-14T03:22:09.000'",
    "MJD-OBS =       6.1113139687E4",
    "IMAGETYP= 'Light   '",
    "OBJECT  = 'M31     '",
    "FILTER  = 'Ha      '",
    "GAIN    =                  100",
    "OFFSET  =                   50",
    "CCD-TEMP=      -1.0500000000E1",
    "XBINNING=                    2",
    "YBINNING=                    2",
    "BAYERPAT= 'GBRG    '",
    "FOCALLEN=                416.0",
    "APTDIA  =                 65.0",
    "TELESCOP= 'Askar 65PHQ'",
    "INSTRUME= 'ZWO ASI2600MM Pro'",
    "OBSERVER= 'Test Observer'",
    "SITELAT =       4.0712800000E1",
    "SITELONG=      -7.4006000000E1",
    "SITEELEV=                 50.0",
    "END",
];

/// A frame from a camera that delivers its own file (a DSLR's raw file) is
/// saved as the camera-file setting says. With "both" the FITS file's header
/// is card for card the one a FITS-only save writes, and the camera's file
/// sits beside it byte for byte; with "camera" only the camera's file is
/// written and it is the path the frame is recorded by.
#[tokio::test]
async fn a_camera_file_is_kept_beside_an_identical_fits_file() {
    let device_id = "golden_camera_file";
    let camera_bytes = b"II*\0 bytes exactly as the camera wrote them".to_vec();
    let store = || async {
        crate::last_frame::store(
            device_id,
            crate::last_frame::RawFrame {
                width: 8,
                height: 8,
                data: vec![1000; 64],
                bayer_pattern: Some(skotiq_device::BayerPattern::Rggb),
                camera_file: Some(skotiq_device::CameraFile {
                    file_name: "IMG_0042.CR3".to_string(),
                    bytes: std::sync::Arc::new(camera_bytes.clone()),
                }),
                exposure: crate::last_frame::ExposureRecord {
                    started_at: at("2026-03-14T03:21:09.250Z"),
                    exposure_secs: 30.0,
                    gain: Some(800),
                    offset: None,
                    temperature: Some(21.0),
                    bits_per_pixel: 14,
                    readout_mode: None,
                },
            },
            30.0,
        )
        .await
        .expect("store frame");
    };
    let header = || crate::api::imaging::FitsWriteHeader {
        object_name: Some("M31".to_string()),
        exposure_time: 30.0,
        frame_type: "Light".to_string(),
        filter: None,
        gain: Some(800),
        offset: None,
        bin_x: 1,
        bin_y: 1,
        telescope: None,
        instrument: Some("Canon EOS R6".to_string()),
        observer: None,
        focal_length: None,
        aperture: None,
        site_latitude: None,
        site_longitude: None,
        site_elevation: None,
        mount_id: Some("golden_absent_mount".to_string()),
        focuser_id: None,
        filter_wheel_id: None,
        rotator_id: None,
    };
    let save = |path: String, keeper: bool| async move {
        crate::api::imaging::api_save_fits_from_last_capture(device_id.to_string(), path, header(), keeper)
            .await
    };
    let saving = |choice| async move {
        skotiq_sequencer::executor_handle()
            .update_run_config(|config| config.camera_file_saving = choice)
            .await
            .expect("the setting applies");
    };
    let scratch = Scratch::new("camera_file");
    let fits_only = scratch.file("fits_only.fits");
    let both = scratch.file("both.fits");
    let camera_only = scratch.file("camera_only.fits");
    let live_view = scratch.file("live_view.fits");

    store().await;
    saving(skotiq_sequencer::CameraFileSaving::Converted).await;
    let recorded_fits_only = save(fits_only.clone(), true).await;
    saving(skotiq_sequencer::CameraFileSaving::Both).await;
    let recorded_both = save(both.clone(), true).await;
    // A live-view or loop frame is no keeper: FITS only, whatever the setting.
    let recorded_live_view = save(live_view.clone(), false).await;
    saving(skotiq_sequencer::CameraFileSaving::CameraFile).await;
    let recorded_camera_only = save(camera_only.clone(), true).await;
    saving(skotiq_sequencer::CameraFileSaving::Converted).await;
    crate::last_frame::clear(device_id).await;

    assert_eq!(recorded_fits_only.unwrap(), fits_only);
    assert!(!std::path::Path::new(&fits_only.replace(".fits", ".CR3")).exists());

    assert_eq!(recorded_both.unwrap(), both);
    assert_eq!(std::fs::read(both.replace(".fits", ".CR3")).unwrap(), camera_bytes);
    // DATE is when the file was written; the pointing is whatever mount the
    // process has, read at each save.
    let varying = ["DATE", "RA", "OBJCTRA", "DEC", "OBJCTDEC", "OBJCTALT", "AIRMASS", "EQUINOX", "RADESYS"];
    let cards = |path: &str| -> Vec<String> {
        header_cards(path)
            .into_iter()
            .filter(|card| !varying.contains(&card[..card.len().min(8)].trim_end()))
            .collect()
    };
    assert_eq!(cards(&both), cards(&fits_only));
    assert!(cards(&both).iter().any(|card| card.starts_with("BAYERPAT= 'RGGB")));

    assert_eq!(recorded_live_view.unwrap(), live_view);
    assert!(!std::path::Path::new(&live_view.replace(".fits", ".CR3")).exists());

    let camera_path = camera_only.replace(".fits", ".CR3");
    assert_eq!(recorded_camera_only.unwrap(), camera_path);
    assert_eq!(std::fs::read(&camera_path).unwrap(), camera_bytes);
    assert!(!std::path::Path::new(&camera_only).exists());
}
