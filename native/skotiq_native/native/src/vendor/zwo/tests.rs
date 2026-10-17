use super::*;

// Raw-frame diagnostic statistics

#[test]
fn frame_buffer_stats_match_the_four_pass_definition() {
    // Parity guard for the single-pass rewrite: min/max/mean/non-zero must
    // still be exactly what four separate iterator passes produced.
    let data: Vec<u16> = vec![0, 7, 65535, 0, 1234, 9, 0, 65535];
    let stats = FrameBufferStats::of(&data).expect("non-empty buffer");

    let sum: u64 = data.iter().map(|&x| x as u64).sum();
    assert_eq!(stats.min, data.iter().copied().min().unwrap());
    assert_eq!(stats.max, data.iter().copied().max().unwrap());
    assert_eq!(stats.mean, sum / data.len() as u64);
    assert_eq!(stats.non_zero, data.iter().filter(|&&x| x != 0).count());
}

#[test]
fn frame_buffer_stats_of_a_flat_frame_report_equal_bounds() {
    let stats = FrameBufferStats::of(&[4096; 16]).expect("non-empty buffer");
    assert_eq!(stats.min, stats.max);
    assert_eq!(stats.mean, 4096);
    assert_eq!(stats.non_zero, 16);
}

#[test]
fn frame_buffer_stats_of_an_empty_buffer_is_none() {
    // An empty buffer answers `None` rather than making the caller guard with
    // `if !data.is_empty()` before an `.expect("non-empty data")`.
    assert_eq!(FrameBufferStats::of(&[]), None);
}

// Pixel-container full scale (no hardware required)

/// The container ceiling must be reported in the units the pixels arrive in.
/// `(1 << bit_depth) - 1` is the ADC range and is 16x/4x too small for the
/// 12/14-bit sensors that make up most of the ZWO line.
#[test]
fn raw16_container_max_adu_accounts_for_left_justification() {
    // 12-bit ASI1600MM/ASI183/ASI294: 4095 << 4.
    assert_eq!(raw16_container_max_adu(12), 65520);
    // 14-bit ASI2600/ASI6200: 16383 << 2.
    assert_eq!(raw16_container_max_adu(14), 65532);
    // 10-bit: 1023 << 6.
    assert_eq!(raw16_container_max_adu(10), 65472);
    // 8-bit sensor read out in Raw16: 255 << 8.
    assert_eq!(raw16_container_max_adu(8), 65280);
    // A true 16-bit sensor needs no shift.
    assert_eq!(raw16_container_max_adu(16), 65535);
}

// Reported model (no hardware required)

/// Fill an `ASICameraInfo` as the SDK would, with just the fields the model
/// accessor reads.
fn camera_info_named(model: &str, camera_id: c_int) -> ASICameraInfo {
    // SAFETY: `ASICameraInfo` is `#[repr(C)]` POD; zeroed is exactly the
    // state the real code hands to `ASIGetCameraProperty`.
    let mut info: ASICameraInfo = unsafe { std::mem::zeroed() };
    info.camera_id = camera_id;
    for (slot, byte) in info.name.iter_mut().zip(model.as_bytes()) {
        *slot = *byte as c_char;
    }
    info
}

/// `NativeDevice::name()` must report the model, never the enumeration id.
///
/// This is the live-rig defect in one assertion. `native:zwo:1` is the ASI
/// enumeration index and it swapped from the ASI1600MM-Cool to the ASI178MM
/// across a replug; the device-identity check and the FITS `INSTRUME`
/// keyword both read `name()` expecting the model, so returning the id
/// labelled frames — and the connected-device list — with a number that
/// means a different camera tomorrow.
#[test]
fn name_reports_the_model_once_camera_info_is_loaded() {
    let mut camera = ZwoCamera::new(1);
    assert_eq!(
        camera.name(),
        "native:zwo:1",
        "before the SDK answers there is no model to report"
    );

    camera.camera_info = Some(camera_info_named("ZWO ASI1600MM-Cool", 1));
    camera.model_name = camera.camera_name();

    assert_eq!(camera.name(), "ZWO ASI1600MM-Cool");
    assert_ne!(
        camera.name(),
        camera.id(),
        "the model must not be the positional device id"
    );
}

/// Every reported ceiling must be reachable inside a u16 and be an exact
/// multiple of the left-shift step, which is what makes frame statistics from
/// these cameras land on multiples of 16 (12-bit) or 4 (14-bit).
#[test]
fn raw16_container_max_adu_is_a_reachable_u16_sample() {
    for bit_depth in 1..=16u32 {
        let max = raw16_container_max_adu(bit_depth);
        assert!(
            max <= u16::MAX as u32,
            "bit_depth {bit_depth} produced {max}, outside the u16 container"
        );
        let step = 1u32 << (16 - bit_depth.min(16));
        assert_eq!(
            max % step,
            0,
            "bit_depth {bit_depth}: {max} is not a multiple of the {step}-ADU sample step"
        );
    }
}

/// A bit depth the SDK never populated must not collapse the range to 0 —
/// that would publish "this camera cannot produce any signal" and make every
/// percent-of-full-scale target 0.
#[test]
fn raw16_container_max_adu_unknown_bit_depth_falls_back_to_container() {
    assert_eq!(raw16_container_max_adu(0), 65535);
    assert_eq!(raw16_container_max_adu(32), 65535);
}

/// The saturation threshold the imaging pipeline ships (65024 = 4064 << 4)
/// must sit just under, not above, the 12-bit container ceiling — otherwise
/// saturation could never be detected on the most common astro sensor class.
#[test]
fn raw16_container_max_adu_agrees_with_pipeline_saturation_threshold() {
    let twelve_bit_ceiling = raw16_container_max_adu(12);
    assert!(
        65024 < twelve_bit_ceiling,
        "pipeline threshold 65024 must be below the 12-bit ceiling {twelve_bit_ceiling}"
    );
    // The live ASI1600MM clips at 4094 << 4; that must still be flagged.
    assert!(65024 <= 65504 && 65504 <= twelve_bit_ceiling);
}

// Connected-device registry (no hardware required)

/// Insert an EAF entry, verify it can be read back, then remove it.
#[test]
fn eaf_registry_insert_lookup_remove() {
    // Use an id unlikely to collide with any real hardware in CI.
    let id: i32 = 0xDEAD;

    // Insert
    {
        let mut reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        reg.insert(
            id,
            ConnectedEafEntry {
                focuser_id: id,
                name: "Test EAF".to_string(),
                serial_number: Some("AABBCCDD".to_string()),
                sdk_version: Some("ZWO EAF SDK v1.0".to_string()),
            },
        );
    }

    // Lookup — must be present with correct data
    {
        let reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        let entry = reg.get(&id).expect("entry must be present after insert");
        assert_eq!(entry.focuser_id, id);
        assert_eq!(entry.name, "Test EAF");
        assert_eq!(entry.serial_number.as_deref(), Some("AABBCCDD"));
    }

    // Remove
    {
        let mut reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        let removed = reg.remove(&id);
        assert!(removed.is_some(), "remove must return the entry");
    }

    // Verify gone
    {
        let reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        assert!(
            reg.get(&id).is_none(),
            "entry must not be present after remove"
        );
    }
}

/// Insert an EFW entry, verify it can be read back, then remove it.
#[test]
fn efw_registry_insert_lookup_remove() {
    let id: i32 = 0xBEEF;

    {
        let mut reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        reg.insert(
            id,
            ConnectedEfwEntry {
                filterwheel_id: id,
                name: "Test EFW".to_string(),
                slot_count: 7,
                serial_number: Some("11223344".to_string()),
                sdk_version: Some("ZWO EFW SDK v2.0".to_string()),
            },
        );
    }

    {
        let reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        let entry = reg.get(&id).expect("entry must be present after insert");
        assert_eq!(entry.filterwheel_id, id);
        assert_eq!(entry.name, "Test EFW");
        assert_eq!(entry.slot_count, 7);
        assert_eq!(entry.serial_number.as_deref(), Some("11223344"));
    }

    {
        let mut reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        let removed = reg.remove(&id);
        assert!(removed.is_some(), "remove must return the entry");
    }

    {
        let reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        assert!(
            reg.get(&id).is_none(),
            "entry must not be present after remove"
        );
    }
}

/// Discovery skip predicate: if the enumerated id is in the connected-EAF
/// registry, the cached name must match what was inserted (simulates the
/// check inside the discover_focusers loop without calling any SDK).
#[test]
fn eaf_discovery_skip_returns_cached_metadata() {
    let id: i32 = 0x1234;
    let expected_name = "ZWO EAF-S";

    // Pre-populate as if connect() had run.
    {
        let mut reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        reg.insert(
            id,
            ConnectedEafEntry {
                focuser_id: id,
                name: expected_name.to_string(),
                serial_number: None,
                sdk_version: None,
            },
        );
    }

    // Simulate what the discovery loop does: check registry and clone entry.
    let maybe_entry: Option<ConnectedEafEntry> = {
        let reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
        reg.get(&id).cloned()
    };

    let entry = maybe_entry.expect("discovery loop must find the connected entry");
    assert_eq!(entry.name, expected_name, "cached name must match");
    // In the real loop this would `continue` without any SDK call.

    // Cleanup
    connected_eaf()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
}

/// Discovery skip predicate for EFW: same verification as EAF above.
#[test]
fn efw_discovery_skip_returns_cached_metadata() {
    let id: i32 = 0x5678;
    let expected_name = "ZWO EFW 7-slot";

    {
        let mut reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        reg.insert(
            id,
            ConnectedEfwEntry {
                filterwheel_id: id,
                name: expected_name.to_string(),
                slot_count: 7,
                serial_number: Some("DEADBEEF".to_string()),
                sdk_version: None,
            },
        );
    }

    let maybe_entry: Option<ConnectedEfwEntry> = {
        let reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
        reg.get(&id).cloned()
    };

    let entry = maybe_entry.expect("discovery loop must find the connected entry");
    assert_eq!(entry.name, expected_name);
    assert_eq!(entry.slot_count, 7);

    connected_efw()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
}

#[test]
fn zwo_cached_setting_updates_after_success_only() {
    let mut cached = 10;

    commit_zwo_cached_setting(&mut cached, 42, Ok(())).unwrap();
    assert_eq!(cached, 42);

    let err = commit_zwo_cached_setting(
        &mut cached,
        99,
        Err(NativeError::SdkError("rejected".to_string())),
    )
    .unwrap_err();

    assert!(matches!(err, NativeError::SdkError(_)));
    assert_eq!(cached, 42);
}

#[test]
fn zwo_eaf_target_validation_rejects_clamped_positions() {
    assert_eq!(validate_zwo_eaf_target(0, 100).unwrap(), 0);
    assert_eq!(validate_zwo_eaf_target(100, 100).unwrap(), 100);

    assert!(matches!(
        validate_zwo_eaf_target(-1, 100),
        Err(NativeError::InvalidParameter(_))
    ));
    assert!(matches!(
        validate_zwo_eaf_target(101, 100),
        Err(NativeError::InvalidParameter(_))
    ));
}

/// The disconnected guard must short-circuit before any SDK call. We can
/// only assert the guard here — the live SDK path (`get_control_caps_async`)
/// requires real ASI hardware/driver, mirroring how `get_recommended_settings`
/// is unit-tested. This is the real-probe path's verifiable contract.
#[tokio::test]
async fn zwo_cooler_temp_range_requires_connection() {
    let camera = ZwoCamera::new(0);
    // Freshly constructed camera is disconnected.
    assert!(matches!(
        camera.get_cooler_temp_range().await,
        Err(NativeError::NotConnected)
    ));
}
