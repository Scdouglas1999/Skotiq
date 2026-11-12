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
    camera.detect_sensor_dimensions();
    camera
}

#[test]
fn max_adu_falls_back_to_model_table_before_any_frame_is_decoded() {
    // Tabulated 12-bit body: the estimate must be the 12-bit ceiling.
    let rebel_xs = camera_with_model_table("Canon EOS 1000D");
    let info = rebel_xs.get_sensor_info();
    assert_eq!(info.bit_depth, 12);
    assert_eq!(info.max_adu, 4095);

    // Untabulated body: falls back to the table's 14-bit guess. This is the
    // estimate the decoder is expected to correct on the first frame.
    let untabulated = camera_with_model_table("Canon EOS 450D");
    let info = untabulated.get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);
}

#[test]
fn measured_12bit_white_level_overrides_the_14bit_estimate() {
    // A body that is NOT in the model table gets the 14-bit guess, but its
    // frames really top out at 4095. Publishing 16383 would put a 50% flat
    // target (8191) above anything the sensor can physically reach.
    let mut camera = camera_with_model_table("Nikon D3200");
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

fn widget(name: &str, label: &str, kind: CameraWidgetType, value: &str, choices: &[&str]) -> ConfigWidget {
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

#[test]
fn iso_speeds_are_the_numbers_the_body_lists_without_auto() {
    // Canon EOS lists Auto first and the extended speeds as numbers.
    let canon = iso_choices(&strings(&["Auto", "100", "125", "160", "25600", "51200", "102400"]));
    let speeds: Vec<i32> = canon.iter().map(|s| s.speed).collect();
    assert_eq!(speeds, vec![100, 125, 160, 25600, 51200, 102400]);
    assert_eq!(canon[0].choice, "100");

    // Step names carry no number and are not offered.
    let nikon = iso_choices(&strings(&["Hi 1", "64", "Lo 1", "32", "Auto ISO"]));
    assert_eq!(nikon.iter().map(|s| s.speed).collect::<Vec<_>>(), vec![32, 64]);
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
                widget("highisonr", "High ISO NR", CameraWidgetType::Radio, "Normal", &["Off", "Low", "Normal", "High"]),
                widget("longexpnr", "Long Exp Noise Reduction", CameraWidgetType::Radio, "On", &["Off", "On"]),
            ],
        )],
    );
    let found = long_exposure_nr_widget(&tree).expect("longexpnr");
    assert_eq!(found.name, "longexpnr");
    assert_eq!(noise_reduction_off(found), NoiseReductionOff::Choose("Off".to_string()));
    assert!(!reads_off(found));
}

#[test]
fn long_exposure_nr_already_off_toggle_or_without_an_off_choice() {
    let off = widget("longexpnr", "Long Exp Noise Reduction", CameraWidgetType::Radio, "Off", &["Off", "On"]);
    assert_eq!(noise_reduction_off(&off), NoiseReductionOff::AlreadyOff);
    assert!(reads_off(&off));

    let toggle = widget("longexposurenr", "Long Exposure NR", CameraWidgetType::Toggle, "1", &[]);
    assert_eq!(noise_reduction_off(&toggle), NoiseReductionOff::ClearToggle);

    let stuck = widget("lexpnr", "Long exposure noise reduction", CameraWidgetType::Menu, "Auto", &["Auto", "On"]);
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
                widget("highisonr", "High ISO speed NR", CameraWidgetType::Radio, "Off", &["Off", "On"]),
                widget("customfuncex", "Custom Functions Ex", CameraWidgetType::Text, "b4,2,1,...", &[]),
            ],
        )],
    );
    assert!(long_exposure_nr_widget(&tree).is_none());
}
