use super::exposure::*;
use super::models::*;
use super::*;

#[test]
fn eos_bulb_choices_prefer_press_full_mf_and_plain_release() {
    // Canon 600D-style ordering: plain "Release" is present and must win
    // over "Release Full"; "Press Full MF" must win over "Press Full".
    let choices: Vec<String> = [
        "None",
        "Press Half",
        "Press Full",
        "Press Full MF",
        "Release Half",
        "Release Full",
        "Release",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let (press, release) = pick_eos_bulb_choices(&choices);
    assert_eq!(press, "Press Full MF");
    assert_eq!(release, "Release");
}

#[test]
fn eos_bulb_choices_fall_back_when_variants_absent() {
    let choices: Vec<String> = ["None", "Press Full", "Release Full"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let (press, release) = pick_eos_bulb_choices(&choices);
    assert_eq!(press, "Press Full");
    assert_eq!(release, "Release Full");

    // Nothing matches -> canonical defaults.
    let (p, r) = pick_eos_bulb_choices(&["None".to_string()]);
    assert_eq!(p, "Press Full");
    assert_eq!(r, "Release Full");
}

#[test]
fn raw_format_choice_prefers_pure_raw() {
    // Canon imageformat.
    let canon: Vec<String> = ["Large Fine JPEG", "RAW + Large Fine JPEG", "RAW"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(pick_raw_format_choice(&canon).as_deref(), Some("RAW"));

    // Nikon imagequality (NEF).
    let nikon: Vec<String> = ["JPEG Fine", "NEF+Fine", "NEF (Raw)"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(pick_raw_format_choice(&nikon).as_deref(), Some("NEF (Raw)"));

    // Only RAW+JPEG available -> accept it.
    let sony: Vec<String> = ["Fine", "RAW+JPEG"].iter().map(|s| s.to_string()).collect();
    assert_eq!(pick_raw_format_choice(&sony).as_deref(), Some("RAW+JPEG"));

    // No RAW at all -> None.
    let jpeg_only: Vec<String> = ["Fine", "Normal", "Basic"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(pick_raw_format_choice(&jpeg_only), None);
}

#[test]
fn gphoto2_version_from_array_reads_first_short_version() {
    let version = b"2.5.33\0";
    let versions = [version.as_ptr() as *const c_char, std::ptr::null()];

    // SAFETY: versions is a live, NULL-terminated array of valid C strings.
    let parsed = unsafe { gphoto2_version_from_array(versions.as_ptr()) };

    assert_eq!(parsed.as_deref(), Some("libgphoto2 v2.5.33"));
}

/// Build a disconnected camera and seed it from the model table, exactly as
/// `connect()` does before any frame has been decoded.
fn camera_with_model_table(model: &str) -> GPhoto2Camera {
    let mut camera = GPhoto2Camera::new(0, model, "usb:001,002");
    camera.adopt_model_table();
    camera
}

#[test]
fn max_adu_falls_back_to_model_table_before_any_frame_is_decoded() {
    // Tabulated 12-bit body: the estimate must be the 12-bit ceiling.
    let rebel_xs = camera_with_model_table("Canon EOS 1000D");
    let info = rebel_xs.get_sensor_info();
    assert_eq!(info.bit_depth, 12);
    assert_eq!(info.max_adu, 4095);

    // Untabulated body: the 14-bit guess. This is the estimate the decoder is
    // expected to correct on the first frame.
    let untabulated = camera_with_model_table("Canon EOS 40D");
    let info = untabulated.get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);
}

#[test]
fn measured_12bit_white_level_overrides_the_14bit_estimate() {
    // A body that is NOT in the model table gets the 14-bit guess, but its
    // frames really top out at 4095. Publishing 16383 would put a 50% flat
    // target (8191) above anything the sensor can physically reach.
    let mut camera = camera_with_model_table("Nikon DSC D3100");
    assert_eq!(camera.get_sensor_info().max_adu, 16383);

    camera.adopt_decoded_depth(12, 4095);

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 4095, "measured white level must win");
    assert_ne!(
        info.max_adu, 16383,
        "the model-table guess must not survive"
    );
    assert_eq!(info.bit_depth, 12);
}

#[test]
fn measured_16bit_white_level_is_published_verbatim() {
    let mut camera = camera_with_model_table("Canon EOS 5D Mark IV");
    camera.adopt_decoded_depth(16, 65535);

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 65535);
    assert_eq!(info.bit_depth, 16);
}

#[test]
fn measured_white_level_is_never_container_scaled() {
    // GUARD: LibRaw hands back a RIGHT-JUSTIFIED mosaic (unpack + raw2image,
    // never dcraw_process — imaging/src/raw.rs:1097-1108), so a 14-bit frame
    // saturates at 16383. Left-shifting it into a 16-bit container (16383<<2
    // = 65532), which is the correct fix for a left-justifying astro-CMOS
    // SDK, would be a 4x OVERstatement on this path.
    let mut camera = camera_with_model_table("Canon EOS R6");
    camera.adopt_decoded_depth(14, 16383);

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 16383);
    assert_ne!(info.max_adu, 65532, "this path must not left-justify");
    assert_eq!(info.bit_depth, 14);
}

#[test]
fn resolve_max_adu_ignores_an_unmeasured_white_level() {
    // LibRaw leaves color.maximum at 0 for a few bodies; a 0 ceiling would
    // be unreachable, so the bit-depth estimate is used instead.
    assert_eq!(resolve_max_adu(Some(0), 12), 4095);
    assert_eq!(resolve_max_adu(None, 14), 16383);
    assert_eq!(resolve_max_adu(Some(4095), 14), 4095);
    assert_eq!(resolve_max_adu(None, 16), 65535);
    // A corrupt depth must neither panic the shift nor publish nonsense.
    assert_eq!(resolve_max_adu(None, 0), 255);
    assert_eq!(resolve_max_adu(None, 64), 65535);
}

#[test]
fn adopt_decoded_depth_rejects_implausible_measurements() {
    let mut camera = camera_with_model_table("Canon EOS R6");

    // Out-of-range depth and a zero white level are both ignored, leaving
    // the model-table estimate in place rather than corrupting it.
    camera.adopt_decoded_depth(0, 0);
    let info = camera.get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);
}

#[test]
fn gphoto2_version_from_array_rejects_null_inputs() {
    // SAFETY: the function's contract is to reject NULL explicitly.
    assert!(unsafe { gphoto2_version_from_array(std::ptr::null()) }.is_none());

    let versions = [std::ptr::null()];
    // SAFETY: versions is a live array whose first entry is the NULL terminator.
    assert!(unsafe { gphoto2_version_from_array(versions.as_ptr()) }.is_none());
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn widget(
    name: &str,
    label: &str,
    kind: CameraWidgetType,
    value: &str,
    choices: &[&str],
) -> ConfigWidget {
    ConfigWidget {
        name: name.to_string(),
        label: label.to_string(),
        kind,
        value: Some(value.to_string()),
        choices: strings(choices),
        children: Vec::new(),
    }
}

fn section(name: &str, children: Vec<ConfigWidget>) -> ConfigWidget {
    ConfigWidget {
        name: name.to_string(),
        label: name.to_string(),
        kind: CameraWidgetType::Section,
        value: None,
        choices: Vec::new(),
        children,
    }
}

fn camera_file(name: &str, bytes: Vec<u8>) -> skotiq_device::CameraFile {
    skotiq_device::CameraFile {
        file_name: name.to_string(),
        bytes: std::sync::Arc::new(bytes),
    }
}

#[test]
fn a_jpeg_download_is_refused_with_a_plain_reason() {
    let mut camera = camera_with_model_table("Canon EOS 1000D");
    let jpeg = vec![
        0xFF, 0xD8, 0xFF, 0xE1, 0, 0x10, b'E', b'x', b'i', b'f', 0, 0,
    ];
    let err = camera
        .decode_raw_to_image_data(camera_file("IMG_0001.JPG", jpeg), MadeExposure::Timed(1.0))
        .unwrap_err();
    assert!(err.to_string().contains("appears to be JPEG"), "{err}");
}

/// Every maker's capture is decoded, Olympus/OM System and Panasonic included
/// (their TIFF variants were once taken for JPEG), and a Canon body's
/// per-ISO saturation level reaches the sensor info. Needs the public raw
/// samples (`SKOTIQ_RAW_SAMPLES`, see imaging/tests/camera_raw.rs).
#[test]
fn every_makers_download_decodes() {
    let Ok(dir) = std::env::var("SKOTIQ_RAW_SAMPLES") else {
        eprintln!("SKOTIQ_RAW_SAMPLES is not set; the camera downloads were not checked");
        return;
    };
    for (sample, model) in [
        ("om1.orf", "OM System OM-1"),
        ("olympus_em10.orf", "Olympus E-M10"),
        ("panasonic_gh4.rw2", "Panasonic DMC-GH4"),
        ("nikon_d7000_lossless14.nef", "Nikon D7000"),
        ("sony_a7m4_lossless.arw", "Sony ILCE-7M4"),
        ("pentax_k5.pef", "Pentax K-5"),
        ("canon_m50_raw.cr3", "Canon EOS M50"),
    ] {
        let bytes = std::fs::read(std::path::Path::new(&dir).join(sample)).unwrap();
        let mut camera = camera_with_model_table(model);
        // A body that names no file gets one in the format its bytes are in.
        let image = camera
            .decode_raw_to_image_data(camera_file("", bytes), MadeExposure::Timed(1.0))
            .unwrap_or_else(|e| panic!("{sample}: {e}"));
        let extension = sample.rsplit('.').next().unwrap();
        let saved = image.metadata.camera_file.expect("camera file kept");
        assert_eq!(saved.file_name, format!("frame.{extension}"), "{sample}");
        let saturation = camera.get_sensor_info().saturation_adu;
        let expected = match sample {
            "canon_m50_raw.cr3" => Some(11892),
            "sony_a7m4_lossless.arw" => Some(15360),
            "olympus_em10.orf" => Some(4093),
            "panasonic_gh4.rw2" => Some(4079),
            "pentax_k5.pef" => Some(16316),
            _ => None,
        };
        assert_eq!(saturation, expected, "{sample}");
    }
}

#[test]
fn iso_speeds_are_the_numbers_the_body_lists_without_auto() {
    // Canon EOS lists Auto first and the extended speeds as numbers.
    let canon = iso_choices(&strings(&[
        "Auto", "100", "125", "160", "25600", "51200", "102400",
    ]));
    let speeds: Vec<i32> = canon.iter().map(|s| s.speed).collect();
    assert_eq!(speeds, vec![100, 125, 160, 25600, 51200, 102400]);
    assert_eq!(canon[0].choice, "100");

    // Step names carry no number and are not offered.
    let nikon = iso_choices(&strings(&["Hi 1", "64", "Lo 1", "32", "Auto ISO"]));
    assert_eq!(
        nikon.iter().map(|s| s.speed).collect::<Vec<_>>(),
        vec![32, 64]
    );
}

#[test]
fn a_requested_iso_goes_to_the_nearest_offered_speed() {
    let speeds = iso_choices(&strings(&["100", "200", "400", "800", "1600"]));
    assert_eq!(nearest_iso(&speeds, 800).map(|s| s.speed), Some(800));
    assert_eq!(nearest_iso(&speeds, 850).map(|s| s.speed), Some(800));
    assert_eq!(nearest_iso(&speeds, 1300).map(|s| s.speed), Some(1600));
    // An ISO-list position from an older Skotiq lands on the lowest speed.
    assert_eq!(nearest_iso(&speeds, 3).map(|s| s.speed), Some(100));
    assert_eq!(nearest_iso(&[], 800), None);
}

#[test]
fn nikon_long_exposure_nr_is_found_and_switched_to_off() {
    let tree = section(
        "main",
        vec![section(
            "capturesettings",
            vec![
                widget(
                    "highisonr",
                    "High ISO NR",
                    CameraWidgetType::Radio,
                    "Normal",
                    &["Off", "Low", "Normal", "High"],
                ),
                widget(
                    "longexpnr",
                    "Long Exp Noise Reduction",
                    CameraWidgetType::Radio,
                    "On",
                    &["Off", "On"],
                ),
            ],
        )],
    );
    let found = long_exposure_nr_widget(&tree).expect("longexpnr");
    assert_eq!(found.name, "longexpnr");
    assert_eq!(
        noise_reduction_off(found),
        NoiseReductionOff::Choose("Off".to_string())
    );
    assert!(!reads_off(found));
}

#[test]
fn long_exposure_nr_already_off_toggle_or_without_an_off_choice() {
    let off = widget(
        "longexpnr",
        "Long Exp Noise Reduction",
        CameraWidgetType::Radio,
        "Off",
        &["Off", "On"],
    );
    assert_eq!(noise_reduction_off(&off), NoiseReductionOff::AlreadyOff);
    assert!(reads_off(&off));

    let toggle = widget(
        "longexposurenr",
        "Long Exposure NR",
        CameraWidgetType::Toggle,
        "1",
        &[],
    );
    assert_eq!(noise_reduction_off(&toggle), NoiseReductionOff::ClearToggle);

    let stuck = widget(
        "lexpnr",
        "Long exposure noise reduction",
        CameraWidgetType::Menu,
        "Auto",
        &["Auto", "On"],
    );
    assert!(long_exposure_nr_widget(&stuck).is_some());
    assert_eq!(noise_reduction_off(&stuck), NoiseReductionOff::NoOffChoice);
}

#[test]
fn a_body_without_the_setting_shows_none() {
    // Canon EOS keeps it among the custom functions libgphoto2 does not break out.
    let tree = section(
        "main",
        vec![section(
            "settings",
            vec![
                widget(
                    "highisonr",
                    "High ISO speed NR",
                    CameraWidgetType::Radio,
                    "Off",
                    &["Off", "On"],
                ),
                widget(
                    "customfuncex",
                    "Custom Functions Ex",
                    CameraWidgetType::Text,
                    "b4,2,1,...",
                    &[],
                ),
            ],
        )],
    );
    assert!(long_exposure_nr_widget(&tree).is_none());
}

/// Canon EOS `shutterspeed` in M mode (libgphoto2 2.5): bulb first, whole and
/// decimal seconds, then fractions.
const CANON_SPEEDS: &[&str] = &[
    "bulb", "30", "25", "20", "15", "13", "10", "8", "6", "5", "4", "3.2", "2.5", "2", "1.6",
    "1.3", "1", "0.8", "0.6", "0.5", "0.4", "0.3", "1/4", "1/5", "1/6", "1/8", "1/10", "1/250",
    "1/4000",
];

/// Nikon `shutterspeed` (ExposureTime in 1/10000 s) and `shutterspeed2`.
const NIKON_SPEEDS: &[&str] = &[
    "0.0002s", "0.0040s", "0.5000s", "1.0000s", "30.0000s", "Bulb", "Time",
];
const NIKON_SPEEDS2: &[&str] = &[
    "1/8000", "1/250", "1/2", "1", "15", "30", "Bulb", "Time", "x 200",
];

fn speeds(widget: &str, choices: &[&str]) -> ShutterSpeeds {
    ShutterSpeeds::from_choices(widget, &strings(choices))
}

#[test]
fn shutter_choices_of_every_maker_read_as_seconds() {
    for (choice, seconds) in [
        ("30", 30.0),
        ("0.3", 0.3),
        ("1/4000", 0.00025),
        ("0.0040s", 0.004),
        ("30.0000s", 30.0),
        ("1/250s", 0.004),
        ("1 1/3", 4.0 / 3.0),
        ("1/3.2", 1.0 / 3.2),
        ("30\"", 30.0),
        ("2m", 120.0),
        ("1.5m", 90.0),
    ] {
        let read = shutter_seconds(choice).unwrap_or_else(|| panic!("{choice} not read"));
        assert!((read - seconds).abs() < 1e-9, "{choice}: {read}");
    }
    for not_timed in [
        "bulb",
        "Bulb",
        "Time",
        "x 200",
        "Auto",
        "65535/65535",
        "60'",
        "",
    ] {
        assert_eq!(shutter_seconds(not_timed), None, "{not_timed}");
    }
    let nikon = speeds("shutterspeed", NIKON_SPEEDS);
    assert_eq!(
        nikon.timed.len(),
        5,
        "Nikon's seconds-suffixed speeds are all read"
    );
    assert_eq!(nikon.bulb_choice.as_deref(), Some("Bulb"));
    assert_eq!(nikon.longest(), Some(30.0));
}

#[test]
fn an_exposure_uses_a_timed_speed_only_when_it_lasts_as_long() {
    let canon = speeds("shutterspeed", CANON_SPEEDS);
    let timed = |seconds| match plan_exposure("Canon EOS 6D", &canon, true, seconds).unwrap() {
        ExposurePlan::Timed(speed) => Some(speed.choice),
        ExposurePlan::Bulb => None,
    };
    assert_eq!(timed(30.0).as_deref(), Some("30"));
    assert_eq!(timed(0.004).as_deref(), Some("1/250"));
    assert_eq!(timed(2.5).as_deref(), Some("2.5"));
    // Not one of the speeds: bulb for exactly the request, never the
    // nearest speed recorded as the request (7 s was shot at 8 s before).
    assert_eq!(timed(7.0), None);
    assert_eq!(timed(45.0), None);
    assert_eq!(timed(300.0), None);
    // Under a second bulb cannot be timed: the nearest speed, which the
    // frame then records.
    assert_eq!(timed(0.7).as_deref(), Some("0.8"));
}

#[test]
fn a_timed_speed_over_30_s_is_made_as_bulb_when_the_body_can() {
    // libgphoto2 2.5.34's Fujifilm list (config.c fuji_new_shutterspeed).
    let fuji = speeds(
        "shutterspeed",
        &[
            "bulb", "60m", "4m", "2m", "60s", "30s", "1s", "1/2", "1/250",
        ],
    );
    assert_eq!(
        plan_exposure("Fuji Fujifilm X-T5", &fuji, true, 240.0).unwrap(),
        ExposurePlan::Bulb
    );
    assert_eq!(
        plan_exposure("Fuji Fujifilm X-T5", &fuji, true, 60.0).unwrap(),
        ExposurePlan::Bulb
    );
    match plan_exposure("Fuji Fujifilm X-T5", &fuji, true, 30.0).unwrap() {
        ExposurePlan::Timed(speed) => assert_eq!(speed.choice, "30s"),
        other => panic!("{other:?}"),
    }
    // Without bulb the listed speed is the only way to make the frame.
    match plan_exposure("Fuji Fujifilm X-T5", &fuji, false, 240.0).unwrap() {
        ExposurePlan::Timed(speed) => assert_eq!(speed.choice, "4m"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_body_without_bulb_takes_the_nearest_speed_and_refuses_longer_exposures() {
    let nikon = speeds("shutterspeed2", NIKON_SPEEDS2);
    match plan_exposure("Nikon Z6", &nikon, false, 20.0).unwrap() {
        ExposurePlan::Timed(speed) => assert_eq!(speed.choice, "15"),
        other => panic!("{other:?}"),
    }
    let err = plan_exposure("Nikon Z6", &nikon, false, 120.0).unwrap_err();
    assert!(
        err.to_string().contains("longest shutter speed is 30 s"),
        "{err}"
    );
    assert!(plan_exposure("Nikon Z6", &nikon, false, 0.0).is_err());
    let none = ShutterSpeeds::default();
    assert!(plan_exposure("Nikon Z6", &none, false, 10.0).is_err());
    assert_eq!(
        plan_exposure("Nikon Z6", &none, true, 0.5).unwrap(),
        ExposurePlan::Bulb
    );
}

#[test]
fn the_exposure_range_follows_the_speeds_and_bulb() {
    let canon = speeds("shutterspeed", CANON_SPEEDS);
    assert_eq!(exposure_range(&canon, true), Some((0.00025, 3600.0)));
    assert_eq!(exposure_range(&canon, false), Some((0.00025, 30.0)));
    assert_eq!(
        exposure_range(&ShutterSpeeds::default(), true),
        Some((1.0, 3600.0))
    );
    assert_eq!(exposure_range(&ShutterSpeeds::default(), false), None);
}

#[test]
fn a_frame_records_the_exposure_the_camera_made() {
    // A timed speed: the camera's own record wins (a mode dial on Av would
    // show here), else the speed.
    assert_eq!(
        recorded_exposure(&MadeExposure::Timed(30.0), Some(30.0)),
        30.0
    );
    assert_eq!(
        recorded_exposure(&MadeExposure::Timed(30.0), Some(1.0 / 60.0)),
        1.0 / 60.0
    );
    assert_eq!(recorded_exposure(&MadeExposure::Timed(0.3), None), 0.3);
    // Bulb: the measured open time, not the raw file's whole seconds.
    assert_eq!(
        recorded_exposure(&MadeExposure::Bulb(120.04), Some(120.0)),
        120.04
    );
}

fn detected(index: usize, model: &str, port: &str) -> DetectedGPhoto2Camera {
    DetectedGPhoto2Camera {
        model: model.to_string(),
        port: port.to_string(),
        index,
        device_id: build_device_id(index, model, port),
        sdk_version: None,
    }
}

#[test]
fn each_of_two_attached_bodies_opens_as_itself() {
    let attached = [
        detected(0, "Canon EOS 6d Mark II", "usb:001,004"),
        detected(1, "Nikon Z6_2", "usb:001,007"),
    ];
    let nikon = select_camera(&attached, "nikon_z6_2", "usb:001,007").unwrap();
    assert_eq!(nikon.port, "usb:001,007");
    let canon = select_camera(&attached, "canon_eos_6d_mark_ii", "usb:001,004").unwrap();
    assert_eq!(canon.port, "usb:001,004");
}

#[test]
fn a_replugged_body_is_found_on_its_new_port() {
    let attached = [
        detected(0, "Canon EOS 6d Mark II", "usb:001,004"),
        detected(1, "Nikon Z6_2", "usb:001,009"),
    ];
    assert_eq!(
        select_camera(&attached, "nikon_z6_2", "usb:001,007")
            .unwrap()
            .port,
        "usb:001,009"
    );
    // Its old port now holds another body: still found by model.
    let swapped = [
        detected(0, "Canon EOS 6d Mark II", "usb:001,007"),
        detected(1, "Nikon Z6_2", "usb:001,009"),
    ];
    assert_eq!(
        select_camera(&swapped, "nikon_z6_2", "usb:001,007")
            .unwrap()
            .port,
        "usb:001,009"
    );
    // Gone, or two of the model and neither on the port: no guess.
    assert!(matches!(
        select_camera(&attached, "sony_alpha-a7_iii__pc_control_", "usb:001,003"),
        Err(DriverError::DeviceNotFound(_))
    ));
    let twins = [
        detected(0, "Nikon Z6_2", "usb:001,010"),
        detected(1, "Nikon Z6_2", "usb:001,011"),
    ];
    assert!(matches!(
        select_camera(&twins, "nikon_z6_2", "usb:001,007"),
        Err(DriverError::InvalidDevice(_))
    ));
    assert_eq!(
        select_camera(&twins, "nikon_z6_2", "usb:001,011")
            .unwrap()
            .index,
        1
    );
}

#[test]
fn pixel_pitch_comes_from_the_body_libgphoto2_names() {
    let pitch = |model: &str| sensor_spec(model).map(|s| s.pixel_um);
    // Each of these took another body's numbers by substring before.
    assert_eq!(pitch("Canon EOS R6m2"), Some(5.98));
    assert_eq!(pitch("Canon EOS R6"), Some(6.56));
    assert_eq!(pitch("Canon EOS R7"), Some(3.21));
    assert_eq!(pitch("Canon EOS R50"), Some(3.72));
    assert_eq!(pitch("Canon EOS 760D"), Some(3.72));
    assert_eq!(pitch("Nikon DSC D7500"), Some(4.22));
    assert_eq!(pitch("Nikon DSC D750"), Some(5.95));
    assert_eq!(pitch("Nikon Z50"), Some(4.22));
    assert_eq!(pitch("Pentax K10D"), Some(6.05));
    // Generation marks in libgphoto2's spellings.
    assert_eq!(pitch("Canon EOS 6d Mark II"), Some(5.67));
    assert_eq!(pitch("Nikon Z6_2"), Some(5.94));
    assert_eq!(pitch("Sony Alpha-A7III (Control)"), Some(5.93));
    assert_eq!(pitch("Sony Alpha-A7 III (PC Control)"), Some(5.93));
    assert_eq!(pitch("Sony Alpha-A7r II (Control)"), Some(4.51));
    assert_eq!(pitch("Olympus E-M1 MII"), Some(3.32));
    assert_eq!(pitch("Olympus E-M1 Mark II"), Some(3.32));
    // Fujifilm bodies from the Fujifilm driver's table.
    assert_eq!(pitch("Fuji Fujifilm X-T5"), Some(3.04));
    assert_eq!(pitch("Fuji Fujifilm X-T20"), None);
    // A body Skotiq does not list has no pitch (no fabricated 5.9 um).
    assert_eq!(pitch("Canon EOS 40D"), None);
    assert_eq!(pitch("Canon EOS 5D (normal mode)"), None);
}

fn canon_tree() -> ConfigWidget {
    section(
        "main",
        vec![
            section(
                "actions",
                vec![
                    widget(
                        "eosremoterelease",
                        "Canon EOS Remote Release",
                        CameraWidgetType::Radio,
                        "None",
                        &[
                            "None",
                            "Press Half",
                            "Press Full",
                            "Release Half",
                            "Release Full",
                            "Immediate",
                        ],
                    ),
                    widget("bulb", "Bulb Mode", CameraWidgetType::Toggle, "0", &[]),
                ],
            ),
            section(
                "status",
                vec![
                    widget(
                        "serialnumber",
                        "Serial Number",
                        CameraWidgetType::Text,
                        "112233445566",
                        &[],
                    ),
                    widget(
                        "manufacturer",
                        "Camera Manufacturer",
                        CameraWidgetType::Text,
                        "Canon Inc.",
                        &[],
                    ),
                    widget(
                        "cameramodel",
                        "Camera Model",
                        CameraWidgetType::Text,
                        "Canon EOS 6D Mark II",
                        &[],
                    ),
                    widget(
                        "batterylevel",
                        "Battery Level",
                        CameraWidgetType::Text,
                        "15%",
                        &[],
                    ),
                ],
            ),
            section(
                "settings",
                vec![widget(
                    "capturetarget",
                    "Capture Target",
                    CameraWidgetType::Radio,
                    "Internal RAM",
                    &["Internal RAM", "Memory card"],
                )],
            ),
            section(
                "capturesettings",
                vec![widget(
                    "shutterspeed",
                    "Shutter Speed",
                    CameraWidgetType::Radio,
                    "30",
                    CANON_SPEEDS,
                )],
            ),
        ],
    )
}

#[test]
fn a_body_says_what_it_is_and_how_it_opens_for_bulb() {
    let tree = canon_tree();
    let facts = body_facts(&tree);
    assert_eq!(facts.serial.as_deref(), Some("112233445566"));
    assert_eq!(facts.battery_percent(), Some(15));
    assert!(facts.captures_to_ram());
    assert!(!facts.needs_session_reset_after_capture());
    assert!(matches!(
        bulb_control(&tree),
        Some(BulbWidget::EosRemoteRelease { ref press, ref release })
            if press == "Press Full" && release == "Release Full"
    ));
    assert_eq!(shutter_speeds(&tree).unwrap().widget, "shutterspeed");

    let nikon = section(
        "main",
        vec![
            widget("bulb", "Bulb Mode", CameraWidgetType::Toggle, "0", &[]),
            widget(
                "serialnumber",
                "Serial Number",
                CameraWidgetType::Text,
                "0000000000",
                &[],
            ),
            widget(
                "shutterspeed",
                "Shutter Speed",
                CameraWidgetType::Radio,
                "1.0000s",
                NIKON_SPEEDS,
            ),
            widget(
                "shutterspeed2",
                "Shutter Speed 2",
                CameraWidgetType::Radio,
                "1",
                NIKON_SPEEDS2,
            ),
            widget(
                "capturetarget",
                "Capture Target",
                CameraWidgetType::Radio,
                "Memory card",
                &["Internal RAM", "Memory card"],
            ),
        ],
    );
    let facts = body_facts(&nikon);
    assert_eq!(facts.serial, None, "an unset serial is no serial");
    assert!(!facts.captures_to_ram());
    assert_eq!(bulb_control(&nikon), Some(BulbWidget::BulbToggle));
    assert_eq!(shutter_speeds(&nikon).unwrap().widget, "shutterspeed2");

    let neither = section("main", vec![]);
    assert_eq!(bulb_control(&neither), None);

    let sony = |model: &str| BodyFacts {
        manufacturer: Some("Sony Corporation".into()),
        model: Some(model.into()),
        ..Default::default()
    };
    assert!(sony("ILCE-7M3").needs_session_reset_after_capture());
    assert!(!sony("ILCE-7RM4").needs_session_reset_after_capture());
}

#[test]
fn of_a_raw_and_jpeg_pair_the_raw_file_is_read() {
    assert_eq!(
        raw_file_index(&strings(&["IMG_0001.JPG", "IMG_0001.CR2"])),
        1
    );
    assert_eq!(
        raw_file_index(&strings(&["DSC_0001.NEF", "DSC_0001.JPG"])),
        0
    );
    assert_eq!(raw_file_index(&strings(&["capt0000.jpg"])), 0);
}

#[test]
fn libgphoto2_results_read_as_the_header_defines_them() {
    assert!(matches!(gp_error(-6, "x"), DriverError::NotSupported));
    assert!(matches!(gp_error(-5, "x"), DriverError::DeviceNotFound(_)));
    assert!(matches!(gp_error(-52, "x"), DriverError::Disconnected));
    assert!(gp_error(-53, "opening").to_string().contains("gvfs"));
    assert!(gp_error(-7, "capture").to_string().contains("lost contact"));
    // CameraOperation bits as gphoto2-abilities-list.h numbers them.
    assert_eq!(
        [
            GP_OPERATION_CAPTURE_IMAGE,
            GP_OPERATION_CAPTURE_PREVIEW,
            GP_OPERATION_CONFIG,
            GP_OPERATION_TRIGGER_CAPTURE
        ],
        [1, 8, 16, 32]
    );
}

/// The installed libgphoto2 opens each of two "Directory Browse" cameras
/// (folders on `disk:` ports) by its port, reads and deletes its own file, and
/// answers an unsupported capture with GP_ERROR_NOT_SUPPORTED. No USB device is
/// opened. Run with `--ignored` where libgphoto2 is installed.
#[tokio::test]
#[ignore = "needs the installed libgphoto2"]
async fn the_installed_libgphoto2_opens_each_camera_on_its_port() {
    let root = std::env::temp_dir().join(format!("skotiq-gphoto2-{}", std::process::id()));
    let mut ports = Vec::new();
    for body in ["a", "b"] {
        let folder = root.join(body).join("DCIM");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join(format!("{body}.CR2")),
            format!("frame of {body}"),
        )
        .unwrap();
        ports.push(format!("disk:{}", root.join(body).display()));
    }
    let sdk = GPhoto2Sdk::lock().await.expect("libgphoto2 is installed");
    for (body, port) in ["a", "b"].iter().zip(&ports) {
        let (camera, context) = open_camera(&sdk, "Directory Browse", port).expect("open by port");
        let mut opened = GPhoto2Camera::new(0, "Directory Browse", port);
        opened.gp_camera = camera;
        opened.gp_context = context;
        let mut path = CameraFilePath::default();
        // Folders are named from the port's root.
        for (dst, b) in path.folder.iter_mut().zip("/DCIM".bytes()) {
            *dst = b as c_char;
        }
        for (dst, b) in path.name.iter_mut().zip(format!("{body}.CR2").bytes()) {
            *dst = b as c_char;
        }
        let bytes = opened.download_file(&sdk, &path).expect("download");
        assert_eq!(bytes, format!("frame of {body}").into_bytes(), "{port}");
        opened.delete_file(&sdk, &path);
        assert!(!root
            .join(body)
            .join("DCIM")
            .join(format!("{body}.CR2"))
            .exists());
        let capture = capture_image(&sdk, opened.handles());
        assert!(
            matches!(capture, Err(DriverError::NotSupported)),
            "{capture:?}"
        );
        opened.close(&sdk);
    }
    let unknown = open_camera(&sdk, "No Such Camera", &ports[0]);
    assert!(matches!(unknown, Err(DriverError::DeviceNotFound(_))));
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_device_address_names_the_body_by_its_model_key_and_port() {
    // The app registers a device found in a scan under a name made from its
    // id, so the model comes from the address, not the name.
    let id = build_device_id(1, "Nikon Z6_2", "usb:001,007");
    let address = id.strip_prefix("native:gphoto2:").unwrap();
    let camera = GPhoto2Camera::from_address(address, &format!("gPhoto2 {address}")).unwrap();
    assert_eq!(camera.model_key, "nikon_z6_2");
    assert_eq!(camera.port_path, "usb:001,007");
    assert_eq!(camera.camera_index, 1);
    assert_eq!(camera.device_id, id);
    let attached = [
        detected(0, "Canon EOS 6d Mark II", "usb:001,004"),
        detected(1, "Nikon Z6_2", "usb:001,007"),
    ];
    assert_eq!(
        select_camera(&attached, &camera.model_key, &camera.port_path)
            .unwrap()
            .model,
        "Nikon Z6_2"
    );

    // An address from before the port and model were recorded.
    let old = GPhoto2Camera::from_address("0", "Canon EOS 6d Mark II").unwrap();
    assert_eq!(
        (old.port_path.as_str(), old.model_key.as_str()),
        ("", "canon_eos_6d_mark_ii")
    );
    assert!(GPhoto2Camera::from_address("x:00", "any").is_err());
}
