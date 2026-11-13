use super::*;

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

#[test]
fn test_sensor_specs_40mp_xtrans() {
    // X-H2, X-T5 and X100VI share the 40MP X-Trans 5 HR sensor: 7728 x 5152
    // effective pixels on 23.5 mm, 3.04 um (the owner's FujiCOM model files).
    for model in [
        FujifilmModel::XH2,
        FujifilmModel::XT5,
        FujifilmModel::X100VI,
    ] {
        let (w, h, pixel_size, bit_depth) = model.sensor_specs();
        assert_eq!((w, h), (7728, 5152), "{model:?}");
        assert_eq!(pixel_size, 3.04, "{model:?}");
        assert_eq!(bit_depth, 14, "{model:?}");
        let megapixels = (w as u64 * h as u64) as f64 / 1_000_000.0;
        assert!(
            (megapixels - 40.0).abs() < 1.0,
            "{model:?}: {megapixels} MP"
        );
    }
}

#[test]
fn test_x_t2_is_a_24mp_x_trans_body_and_the_x_t20_is_not_it() {
    assert_eq!(FujifilmModel::from_product_name("X-T2"), FujifilmModel::XT2);
    assert_eq!(
        FujifilmModel::from_product_name("FUJIFILM X-T2"),
        FujifilmModel::XT2
    );
    assert_eq!(
        FujifilmModel::from_product_name("X-T20"),
        FujifilmModel::Unknown
    );
    assert_eq!(
        FujifilmModel::from_product_name("X-T200"),
        FujifilmModel::Unknown
    );
    assert_eq!(FujifilmModel::XT2.sensor_specs(), (6000, 4000, 3.93, 14));
    assert!(FujifilmModel::XT2.is_xtrans());
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

/// Tests of the SDK-facing camera and the FFI constants, which build only
/// on Windows.
#[cfg(target_os = "windows")]
mod sdk {
    use super::*;

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

    #[test]
    fn test_shutter_bulb_constant() {
        // Verify BULB constant is -1 as per SDK spec
        assert_eq!(XSDK_SHUTTER_BULB, -1, "XSDK_SHUTTER_BULB should be -1");
    }

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
        assert_eq!(XSDK_COMPLETE, 0, "XSDK_COMPLETE should be 0");
        assert_eq!(XSDK_ERROR, -1, "XSDK_ERROR should be -1");
    }

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
}

/// The lens halt answered `Ok` although the X SDK has no call that stops
/// the lens: a caller was told a move had been stopped that ran on.
#[cfg(target_os = "windows")]
#[tokio::test]
async fn a_lens_cannot_be_halted_and_says_so() {
    use crate::vendor::fujifilm::FujifilmLens;
    use skotiq_device::{DriverError, FocuserDriver};
    let mut lens = FujifilmLens::new("FUJI-TEST-0001", "Test lens");
    assert!(!lens.can_halt().await);
    assert!(matches!(lens.halt().await, Err(DriverError::NotSupported)));
}
