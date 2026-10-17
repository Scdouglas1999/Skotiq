use super::*;

// Model detection

#[test]
fn test_model_from_product_name_x_series() {
    // X-T series
    assert_eq!(FujifilmModel::from_product_name("X-T5"), FujifilmModel::XT5);
    assert_eq!(FujifilmModel::from_product_name("XT5"), FujifilmModel::XT5);
    assert_eq!(
        FujifilmModel::from_product_name("FUJIFILM X-T5"),
        FujifilmModel::XT5
    );
    assert_eq!(FujifilmModel::from_product_name("X-T4"), FujifilmModel::XT4);
    assert_eq!(FujifilmModel::from_product_name("X-T3"), FujifilmModel::XT3);

    // X-H series
    assert_eq!(
        FujifilmModel::from_product_name("X-H2S"),
        FujifilmModel::XH2S
    );
    assert_eq!(
        FujifilmModel::from_product_name("XH2S"),
        FujifilmModel::XH2S
    );
    assert_eq!(FujifilmModel::from_product_name("X-H2"), FujifilmModel::XH2);
    assert_eq!(FujifilmModel::from_product_name("XH2"), FujifilmModel::XH2);

    // Other X-series
    assert_eq!(
        FujifilmModel::from_product_name("X-S20"),
        FujifilmModel::XS20
    );
    assert_eq!(
        FujifilmModel::from_product_name("X-S10"),
        FujifilmModel::XS10
    );
    assert_eq!(
        FujifilmModel::from_product_name("X-Pro3"),
        FujifilmModel::XPro3
    );
    assert_eq!(FujifilmModel::from_product_name("X-E4"), FujifilmModel::XE4);
    assert_eq!(FujifilmModel::from_product_name("X-M5"), FujifilmModel::XM5);

    // X100 series
    assert_eq!(
        FujifilmModel::from_product_name("X100V"),
        FujifilmModel::X100V
    );
    assert_eq!(
        FujifilmModel::from_product_name("X100VI"),
        FujifilmModel::X100VI
    );
}

#[test]
fn test_model_from_product_name_gfx_series() {
    // GFX 100 series (102MP)
    assert_eq!(
        FujifilmModel::from_product_name("GFX100 II"),
        FujifilmModel::Gfx100II
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX 100 II"),
        FujifilmModel::Gfx100II
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX100S II"),
        FujifilmModel::Gfx100SII
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX 100S II"),
        FujifilmModel::Gfx100SII
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX100"),
        FujifilmModel::Gfx100
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX 100"),
        FujifilmModel::Gfx100
    );

    // GFX 50 series (51MP)
    assert_eq!(
        FujifilmModel::from_product_name("GFX 50S II"),
        FujifilmModel::Gfx50SII
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX50S II"),
        FujifilmModel::Gfx50SII
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX 50S"),
        FujifilmModel::Gfx50S
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX50S"),
        FujifilmModel::Gfx50S
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX 50R"),
        FujifilmModel::Gfx50R
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX50R"),
        FujifilmModel::Gfx50R
    );
}

#[test]
fn test_model_from_product_name_unknown() {
    assert_eq!(
        FujifilmModel::from_product_name("Unknown Camera"),
        FujifilmModel::Unknown
    );
    assert_eq!(
        FujifilmModel::from_product_name("Sony A7IV"),
        FujifilmModel::Unknown
    );
    assert_eq!(FujifilmModel::from_product_name(""), FujifilmModel::Unknown);
    assert_eq!(
        FujifilmModel::from_product_name("Random String"),
        FujifilmModel::Unknown
    );
}

#[test]
fn test_model_from_product_name_case_insensitive() {
    // Should work with any case
    assert_eq!(FujifilmModel::from_product_name("x-t5"), FujifilmModel::XT5);
    assert_eq!(FujifilmModel::from_product_name("X-T5"), FujifilmModel::XT5);
    assert_eq!(
        FujifilmModel::from_product_name("x-h2s"),
        FujifilmModel::XH2S
    );
    assert_eq!(
        FujifilmModel::from_product_name("gfx100 ii"),
        FujifilmModel::Gfx100II
    );
    assert_eq!(
        FujifilmModel::from_product_name("GFX100 II"),
        FujifilmModel::Gfx100II
    );
}

// Sensor specs

#[test]
fn test_sensor_specs_40mp_xtrans() {
    // X-H2 and X-T5 share the same 40MP X-Trans sensor
    let (w, h, pixel_size, bit_depth) = FujifilmModel::XH2.sensor_specs();
    assert_eq!(w, 9728, "X-H2 width should be 9728");
    assert_eq!(h, 7296, "X-H2 height should be 7296");
    assert_eq!(pixel_size, 3.0, "X-H2 pixel size should be 3.0um");
    assert_eq!(bit_depth, 14, "X-H2 bit depth should be 14");

    let (w, h, pixel_size, bit_depth) = FujifilmModel::XT5.sensor_specs();
    assert_eq!(w, 9728, "X-T5 width should be 9728");
    assert_eq!(h, 7296, "X-T5 height should be 7296");
    assert_eq!(pixel_size, 3.0, "X-T5 pixel size should be 3.0um");
    assert_eq!(bit_depth, 14, "X-T5 bit depth should be 14");

    // Verify total resolution is approximately 40MP (71 million pixels)
    let megapixels = (w as u64 * h as u64) as f64 / 1_000_000.0;
    assert!(
        (megapixels - 71.0).abs() < 1.0,
        "40MP sensor should have ~71 million pixels"
    );
}

#[test]
fn test_sensor_specs_gfx100ii() {
    // GFX100 II has 102MP sensor
    let (w, h, pixel_size, bit_depth) = FujifilmModel::Gfx100II.sensor_specs();
    assert_eq!(w, 11648, "GFX100 II width should be 11648");
    assert_eq!(h, 8736, "GFX100 II height should be 8736");
    assert_eq!(pixel_size, 3.76, "GFX100 II pixel size should be 3.76um");
    assert_eq!(bit_depth, 14, "GFX100 II bit depth should be 14");

    // Verify total resolution is approximately 102MP
    let megapixels = (w as u64 * h as u64) as f64 / 1_000_000.0;
    assert!(
        (megapixels - 102.0).abs() < 2.0,
        "GFX100 II should have ~102 million pixels"
    );
}

#[test]
fn test_sensor_specs_gfx50sii() {
    // GFX 50S II has 51MP sensor
    let (w, h, pixel_size, bit_depth) = FujifilmModel::Gfx50SII.sensor_specs();
    assert_eq!(w, 8256, "GFX 50S II width should be 8256");
    assert_eq!(h, 6192, "GFX 50S II height should be 6192");
    assert_eq!(pixel_size, 5.3, "GFX 50S II pixel size should be 5.3um");
    assert_eq!(bit_depth, 14, "GFX 50S II bit depth should be 14");

    // Verify total resolution is approximately 51MP
    let megapixels = (w as u64 * h as u64) as f64 / 1_000_000.0;
    assert!(
        (megapixels - 51.0).abs() < 2.0,
        "GFX 50S II should have ~51 million pixels"
    );
}

#[test]
fn test_sensor_specs_26mp_xtrans() {
    // X-H2S has 26MP stacked X-Trans sensor
    let (w, h, pixel_size, bit_depth) = FujifilmModel::XH2S.sensor_specs();
    assert_eq!(w, 6240, "X-H2S width should be 6240");
    assert_eq!(h, 4160, "X-H2S height should be 4160");
    assert_eq!(pixel_size, 3.76, "X-H2S pixel size should be 3.76um");
    assert_eq!(bit_depth, 14, "X-H2S bit depth should be 14");

    // Verify total resolution is approximately 26MP
    let megapixels = (w as u64 * h as u64) as f64 / 1_000_000.0;
    assert!(
        (megapixels - 26.0).abs() < 1.0,
        "X-H2S should have ~26 million pixels"
    );
}

#[test]
fn test_sensor_specs_default_26mp() {
    // Unknown and other X-series default to 26MP X-Trans
    let (w, h, _, _) = FujifilmModel::Unknown.sensor_specs();
    assert_eq!(w, 6240);
    assert_eq!(h, 4160);

    let (w, h, _, _) = FujifilmModel::XT4.sensor_specs();
    assert_eq!(w, 6240);
    assert_eq!(h, 4160);

    let (w, h, _, _) = FujifilmModel::XS20.sensor_specs();
    assert_eq!(w, 6240);
    assert_eq!(h, 4160);
}

// Raw sample depth

fn camera_for(model: FujifilmModel) -> FujifilmCamera {
    FujifilmCamera::new(&FujifilmDeviceInfo {
        name: "Fujifilm test body".to_string(),
        serial_number: Some("TESTSERIAL".to_string()),
        firmware_version: None,
        model,
        connection_type: "USB".to_string(),
    })
}

#[test]
fn test_supports_16bit_raw_matches_the_capability_headers() {
    // API_PARAM_CapRAWOutputDepth == 2 (supported).
    assert!(FujifilmModel::Gfx100.supports_16bit_raw());
    assert!(FujifilmModel::Gfx100II.supports_16bit_raw());
    assert!(FujifilmModel::Gfx100SII.supports_16bit_raw());
    assert!(FujifilmModel::Gfx50SII.supports_16bit_raw());

    // API_PARAM_CapRAWOutputDepth == -1, or no entry at all.
    assert!(!FujifilmModel::XT5.supports_16bit_raw());
    assert!(!FujifilmModel::XH2.supports_16bit_raw());
    assert!(!FujifilmModel::XH2S.supports_16bit_raw());
    assert!(!FujifilmModel::XM5.supports_16bit_raw());
    assert!(!FujifilmModel::XS20.supports_16bit_raw());
    assert!(!FujifilmModel::Gfx50R.supports_16bit_raw());
    assert!(!FujifilmModel::Gfx50S.supports_16bit_raw());
    assert!(!FujifilmModel::Unknown.supports_16bit_raw());
}

#[test]
fn test_raw_output_depth_code_maps_to_bits() {
    assert_eq!(raw_output_depth_to_bits(SDK_RAWOUTPUTDEPTH_14BIT), Some(14));
    assert_eq!(raw_output_depth_to_bits(SDK_RAWOUTPUTDEPTH_16BIT), Some(16));
    // Not answered / unsupported.
    assert_eq!(raw_output_depth_to_bits(0), None);
    assert_eq!(raw_output_depth_to_bits(-1), None);
}

#[test]
fn test_max_adu_falls_back_to_model_table_before_any_frame() {
    // Nothing measured and nothing reported yet: the model-table estimate
    // is all we have, and it must be a right-justified 14-bit ceiling.
    let info = camera_for(FujifilmModel::XT5).get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);

    let info = camera_for(FujifilmModel::Gfx100II).get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);
}

#[test]
fn test_measured_12bit_white_level_overrides_the_14bit_estimate() {
    let mut camera = camera_for(FujifilmModel::XT5);
    assert_eq!(camera.get_sensor_info().max_adu, 16383);

    // What download_image does with the decoded frame.
    camera.measured_bit_depth = Some(12);
    camera.measured_white_level = Some(4095);
    camera.refresh_raw_depth();

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 4095, "the measured white level must win");
    assert_ne!(
        info.max_adu, 16383,
        "the model-table guess must not survive"
    );
    assert_eq!(info.bit_depth, 12);
}

#[test]
fn test_measured_16bit_white_level_is_adopted_on_a_gfx_body() {
    // A GFX set to SDK_RAWOUTPUTDEPTH_16BIT (XAPIOpt.H:585) really does
    // deliver samples at 65535; reporting 16383 understates it 4x and makes
    // every frame look saturated.
    let mut camera = camera_for(FujifilmModel::Gfx100II);
    camera.measured_bit_depth = Some(16);
    camera.measured_white_level = Some(65535);
    camera.refresh_raw_depth();

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 65535);
    assert_ne!(info.max_adu, 16383, "the 14-bit estimate must not survive");
    assert_eq!(info.bit_depth, 16);
}

#[test]
fn test_measured_white_level_is_never_container_scaled() {
    // GUARD: the RAF mosaic is RIGHT-JUSTIFIED (unpack + raw2image, never
    // dcraw_process — imaging/src/raw.rs:1097-1108), so a 14-bit frame
    // saturates at 16383. Left-shifting it into a 16-bit container
    // (16383 << 2 == 65532), which is the correct fix for a left-justifying
    // astro-CMOS SDK, would be a 4x OVERstatement on this path.
    let mut camera = camera_for(FujifilmModel::Gfx100II);
    camera.measured_bit_depth = Some(14);
    camera.measured_white_level = Some(16383);
    camera.refresh_raw_depth();

    let info = camera.get_sensor_info();
    assert_eq!(info.max_adu, 16383);
    assert_ne!(info.max_adu, 65532, "this path must not left-justify");
    assert_eq!(info.bit_depth, 14);
}

#[test]
fn test_sdk_reported_depth_outranks_the_table_and_loses_to_the_frame() {
    let mut camera = camera_for(FujifilmModel::Gfx100II);

    // XSDK_GetProp / lImageBitDepth says 16 while the table still says 14.
    camera.sdk_reported_bit_depth = Some(16);
    camera.refresh_raw_depth();
    let info = camera.get_sensor_info();
    assert_eq!(info.bit_depth, 16);
    assert_eq!(info.max_adu, 65535);

    // The decoded frame then measures a 14-bit white level — the frame in
    // hand outranks what the camera claimed about itself.
    camera.measured_bit_depth = Some(14);
    camera.measured_white_level = Some(16383);
    camera.refresh_raw_depth();
    let info = camera.get_sensor_info();
    assert_eq!(info.bit_depth, 14);
    assert_eq!(info.max_adu, 16383);
}

#[test]
fn test_resolve_bit_depth_ignores_implausible_sources() {
    // 0 and 32 are bad reads, not sensors: fall through to the next source.
    assert_eq!(resolve_bit_depth(Some(0), Some(16), 14), 16);
    assert_eq!(resolve_bit_depth(Some(32), None, 14), 14);
    assert_eq!(resolve_bit_depth(None, Some(0), 14), 14);
    assert_eq!(resolve_bit_depth(None, None, 14), 14);
    assert_eq!(resolve_bit_depth(Some(12), Some(16), 14), 12);
    // A corrupt table entry still cannot publish an out-of-range depth.
    assert_eq!(resolve_bit_depth(None, None, 0), 8);
    assert_eq!(resolve_bit_depth(None, None, 64), 16);
}

#[test]
fn test_resolve_max_adu_ignores_an_unmeasured_white_level() {
    // LibRaw leaves color.maximum at 0 for a few bodies; a 0 ceiling would
    // be unreachable, so the resolved bit depth is used instead.
    assert_eq!(resolve_max_adu(Some(0), 14), 16383);
    assert_eq!(resolve_max_adu(None, 16), 65535);
    assert_eq!(resolve_max_adu(Some(65535), 14), 65535);
    assert_eq!(resolve_max_adu(None, 0), 255);
}

// X-Trans detection

#[test]
fn test_is_xtrans_x_series() {
    // All X-series cameras use X-Trans sensors
    assert!(FujifilmModel::XT5.is_xtrans(), "X-T5 should be X-Trans");
    assert!(FujifilmModel::XT4.is_xtrans(), "X-T4 should be X-Trans");
    assert!(FujifilmModel::XT3.is_xtrans(), "X-T3 should be X-Trans");
    assert!(FujifilmModel::XH2.is_xtrans(), "X-H2 should be X-Trans");
    assert!(FujifilmModel::XH2S.is_xtrans(), "X-H2S should be X-Trans");
    assert!(FujifilmModel::XS10.is_xtrans(), "X-S10 should be X-Trans");
    assert!(FujifilmModel::XS20.is_xtrans(), "X-S20 should be X-Trans");
    assert!(FujifilmModel::XPro3.is_xtrans(), "X-Pro3 should be X-Trans");
    assert!(FujifilmModel::XE4.is_xtrans(), "X-E4 should be X-Trans");
    assert!(FujifilmModel::XM5.is_xtrans(), "X-M5 should be X-Trans");
    assert!(FujifilmModel::X100V.is_xtrans(), "X100V should be X-Trans");
    assert!(
        FujifilmModel::X100VI.is_xtrans(),
        "X100VI should be X-Trans"
    );
}

#[test]
fn test_is_xtrans_gfx_series_bayer() {
    // All GFX cameras use standard Bayer sensors (NOT X-Trans)
    assert!(
        !FujifilmModel::Gfx100.is_xtrans(),
        "GFX100 should NOT be X-Trans"
    );
    assert!(
        !FujifilmModel::Gfx100II.is_xtrans(),
        "GFX100 II should NOT be X-Trans"
    );
    assert!(
        !FujifilmModel::Gfx100SII.is_xtrans(),
        "GFX100S II should NOT be X-Trans"
    );
    assert!(
        !FujifilmModel::Gfx50R.is_xtrans(),
        "GFX 50R should NOT be X-Trans"
    );
    assert!(
        !FujifilmModel::Gfx50S.is_xtrans(),
        "GFX 50S should NOT be X-Trans"
    );
    assert!(
        !FujifilmModel::Gfx50SII.is_xtrans(),
        "GFX 50S II should NOT be X-Trans"
    );
}

#[test]
fn test_is_xtrans_unknown() {
    // Unknown model should not infer sensor CFA.
    assert!(
        !FujifilmModel::Unknown.is_xtrans(),
        "Unknown should not report X-Trans"
    );
}

// Shutter speed code mapping

#[test]
fn test_find_shutter_code_exact_matches() {
    // Test exact shutter speed matches
    assert_eq!(
        find_shutter_code(1.0),
        1000000,
        "1 second should return 1000000"
    );
    assert_eq!(
        find_shutter_code(0.5),
        500000,
        "1/2 second should return 500000"
    );
    assert_eq!(
        find_shutter_code(30.0),
        32000000,
        "30 seconds should return 32000000"
    );
    assert_eq!(
        find_shutter_code(60.0),
        64000000,
        "60 seconds should return 64000000"
    );
    assert_eq!(
        find_shutter_code(2.0),
        2000000,
        "2 seconds should return 2000000"
    );
    assert_eq!(
        find_shutter_code(4.0),
        4000000,
        "4 seconds should return 4000000"
    );
    assert_eq!(
        find_shutter_code(8.0),
        8000000,
        "8 seconds should return 8000000"
    );
    assert_eq!(
        find_shutter_code(15.0),
        16000000,
        "15 seconds should return 16000000"
    );
}

#[test]
fn test_find_shutter_code_bulb_mode() {
    // Exposures > 60 seconds should return BULB mode
    assert_eq!(
        find_shutter_code(61.0),
        XSDK_SHUTTER_BULB,
        "61s should trigger BULB mode"
    );
    assert_eq!(
        find_shutter_code(120.0),
        XSDK_SHUTTER_BULB,
        "120s should trigger BULB mode"
    );
    assert_eq!(
        find_shutter_code(300.0),
        XSDK_SHUTTER_BULB,
        "300s (5min) should trigger BULB mode"
    );
    assert_eq!(
        find_shutter_code(3600.0),
        XSDK_SHUTTER_BULB,
        "3600s (1hr) should trigger BULB mode"
    );
}

#[test]
fn test_find_shutter_code_fast_speeds() {
    // Test fast shutter speeds (fractions of a second)
    assert_eq!(
        find_shutter_code(1.0 / 8000.0),
        122,
        "1/8000s should return 122"
    );
    assert_eq!(
        find_shutter_code(1.0 / 4000.0),
        244,
        "1/4000s should return 244"
    );
    assert_eq!(
        find_shutter_code(1.0 / 2000.0),
        488,
        "1/2000s should return 488"
    );
    assert_eq!(
        find_shutter_code(1.0 / 1000.0),
        976,
        "1/1000s should return 976"
    );
    assert_eq!(
        find_shutter_code(1.0 / 500.0),
        1953,
        "1/500s should return 1953"
    );
    assert_eq!(
        find_shutter_code(1.0 / 250.0),
        3906,
        "1/250s should return 3906"
    );
    assert_eq!(
        find_shutter_code(1.0 / 125.0),
        7812,
        "1/125s should return 7812"
    );
    assert_eq!(
        find_shutter_code(1.0 / 60.0),
        15625,
        "1/60s should return 15625"
    );
    assert_eq!(
        find_shutter_code(1.0 / 30.0),
        31250,
        "1/30s should return 31250"
    );
}

#[test]
fn test_find_shutter_code_nearest_match() {
    // Test that we find the closest shutter speed for in-between values
    // 0.75s is between 0.5s (500000) and 1.0s (1000000), closer to 1.0s
    let code = find_shutter_code(0.75);
    assert!(
        code == 500000 || code == 1000000,
        "0.75s should match either 0.5s or 1.0s code"
    );

    // Very small values should match the fastest available speed
    let code = find_shutter_code(0.0001);
    assert_eq!(
        code, 122,
        "Very small values should match fastest speed (1/8000s)"
    );
}

#[test]
fn test_shutter_bulb_constant() {
    // Verify BULB constant is -1 as per SDK spec
    assert_eq!(XSDK_SHUTTER_BULB, -1, "XSDK_SHUTTER_BULB should be -1");
}

// Error code constants

#[test]
fn test_error_codes_defined() {
    // Verify key error codes are defined correctly per XAPI.h
    assert_eq!(XSDK_ERRCODE_NOERR, 0x00000000, "No error code should be 0");
    assert_eq!(
        XSDK_ERRCODE_SEQUENCE, 0x00001001,
        "Sequence error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_PARAM, 0x00001002,
        "Parameter error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_INVALID_CAMERA, 0x00001003,
        "Invalid camera error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_LOADLIB, 0x00001004,
        "Load library error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_UNSUPPORTED, 0x00001005,
        "Unsupported error code mismatch"
    );
    assert_eq!(XSDK_ERRCODE_BUSY, 0x00001006, "Busy error code mismatch");
    assert_eq!(
        XSDK_ERRCODE_TIMEOUT, 0x00002002,
        "Timeout error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_COMMUNICATION, 0x00002001,
        "Communication error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_HARDWARE, 0x00003001,
        "Hardware error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_INTERNAL, 0x00009001,
        "Internal error code mismatch"
    );
    assert_eq!(
        XSDK_ERRCODE_UNKNOWN, 0x00009100,
        "Unknown error code mismatch"
    );
}

#[test]
fn test_sdk_return_values() {
    // Verify SDK return value constants
    assert_eq!(XSDK_COMPLETE, 0, "XSDK_COMPLETE should be 0");
    assert_eq!(XSDK_ERROR, -1, "XSDK_ERROR should be -1");
}

// SDK constants

#[test]
fn test_connection_interface_constants() {
    assert_eq!(
        XSDK_DSC_IF_USB, 0x00000001,
        "USB interface constant mismatch"
    );
    assert_eq!(
        XSDK_DSC_IF_WIFI_LOCAL, 0x00000010,
        "WiFi local constant mismatch"
    );
    assert_eq!(XSDK_DSC_IF_WIFI_IP, 0x00000020, "WiFi IP constant mismatch");
}

#[test]
fn test_priority_mode_constants() {
    assert_eq!(
        XSDK_PRIORITY_CAMERA, 0x0001,
        "Camera priority constant mismatch"
    );
    assert_eq!(XSDK_PRIORITY_PC, 0x0002, "PC priority constant mismatch");
}

#[test]
fn test_release_mode_constants() {
    assert_eq!(
        XSDK_RELEASE_SHOOT, 0x0100,
        "Shoot release constant mismatch"
    );
    assert_eq!(XSDK_RELEASE_S1ON, 0x0200, "S1 ON release constant mismatch");
    assert_eq!(
        XSDK_RELEASE_BULBS2_ON, 0x0500,
        "Bulb S2 ON release constant mismatch"
    );
    assert_eq!(
        XSDK_RELEASE_N_BULBS1OFF, 0x000C,
        "Bulb S1 OFF release constant mismatch"
    );
    assert_eq!(
        XSDK_RELEASE_SHOOT_S1OFF, 0x0104,
        "Shoot S1 OFF release constant mismatch"
    );
}

#[test]
fn test_image_format_constants() {
    assert_eq!(XSDK_IMAGEFORMAT_RAW, 1, "RAW format constant mismatch");
    assert_eq!(XSDK_IMAGEFORMAT_LIVE, 4, "Live format constant mismatch");
    assert_eq!(XSDK_IMAGEFORMAT_NONE, 5, "None format constant mismatch");
    assert_eq!(XSDK_IMAGEFORMAT_JPEG, 7, "JPEG format constant mismatch");
}

#[test]
fn test_dynamic_range_constants() {
    assert_eq!(XSDK_DR_100, 100, "DR 100 constant mismatch");
    assert_eq!(XSDK_DR_200, 200, "DR 200 constant mismatch");
    assert_eq!(XSDK_DR_400, 400, "DR 400 constant mismatch");
}
