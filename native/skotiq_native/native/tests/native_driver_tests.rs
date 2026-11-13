//! Native Driver Tests
//!
//! Tests for the native driver implementations.
//! Some tests require hardware to be connected, others can run without hardware.
//!
//! # `unwrap_or` policy
//!
//! Two patterns appear in this test file:
//!
//! 1. Polling loops: `while device.is_moving().await.unwrap_or(false) { ... }`
//!    and `while !camera.is_exposure_complete().await.unwrap_or(true) { ... }`.
//!    These are integration tests against real or fake hardware. A transient
//!    poll error must NOT block the test forever — defaulting `is_moving`
//!    to `false` exits the wait loop and lets the next assertion surface the
//!    underlying problem with the actual driver error message rather than a
//!    spurious timeout. The complementary `is_exposure_complete` defaults to
//!    `true` (assume done on error) for the same reason. Test failure mode
//!    is preserved because the next call (e.g. `download_image`) will
//!    re-trigger the same error path with full context.
//!
//! 2. Environment-restore helpers: `env::var("PATH").unwrap_or_default()` and
//!    `env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string())`. Tests
//!    save+restore PATH around SDK-discovery experiments; an empty `PATH`
//!    is a valid restore target (the test invalidates `PATH` *deliberately*),
//!    and the `rustc` fallback is the platform-conventional executable name
//!    used for the bindgen self-check.

#[cfg(windows)]
use skotiq_device::ExposureParams;
use skotiq_device::{CameraDriver, DeviceDriver, FilterWheelDriver, FocuserDriver, MountDriver};
#[cfg(windows)]
use skotiq_native::vendor::atik;
#[cfg(windows)]
use skotiq_native::vendor::fli;
#[cfg(windows)]
use skotiq_native::vendor::fujifilm;
use skotiq_native::vendor::ioptron;
use skotiq_native::vendor::lx200;
#[cfg(windows)]
use skotiq_native::vendor::moravian;
#[cfg(windows)]
use skotiq_native::vendor::player_one;
use skotiq_native::vendor::qhy;
use skotiq_native::vendor::skywatcher;
use skotiq_native::vendor::svbony;
#[cfg(windows)]
use skotiq_native::vendor::touptek;
use skotiq_native::vendor::zwo;

// SDK loading (no hardware required)

/// Test that ZWO ASI Camera SDK status can be checked
#[test]
fn test_zwo_camera_sdk_status() {
    let (available, message) = zwo::get_sdk_status();
    println!(
        "ZWO Camera SDK: available={}, message={}",
        available, message
    );
    // We don't assert availability since SDK may not be installed
    assert!(!message.is_empty());
}

/// Test that ZWO EAF SDK status can be checked
#[test]
fn test_zwo_eaf_sdk_status() {
    let (available, message) = zwo::get_eaf_sdk_status();
    println!("ZWO EAF SDK: available={}, message={}", available, message);
    assert!(!message.is_empty());
}

/// Test that ZWO EFW SDK status can be checked
#[test]
fn test_zwo_efw_sdk_status() {
    let (available, message) = zwo::get_efw_sdk_status();
    println!("ZWO EFW SDK: available={}, message={}", available, message);
    assert!(!message.is_empty());
}

/// Test that SVBony Camera SDK status can be checked
#[test]
fn test_svbony_camera_sdk_status() {
    let (available, message) = svbony::get_sdk_status();
    println!(
        "SVBony Camera SDK: available={}, message={}",
        available, message
    );
    // We don't assert availability since SDK may not be installed
    assert!(!message.is_empty());
}

// Discovery (no hardware required; returns empty when no devices are present)

/// Test that camera discovery doesn't crash even without hardware
#[tokio::test]
async fn test_zwo_camera_discovery_no_crash() {
    let result = zwo::discover_devices().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let devices = result.unwrap();
    println!("Found {} ZWO cameras", devices.len());
    for dev in &devices {
        println!(
            "  - {} (ID: {}, index: {})",
            dev.name, dev.camera_id, dev.discovery_index
        );
    }
}

/// Test that focuser discovery doesn't crash even without hardware
#[tokio::test]
async fn test_zwo_focuser_discovery_no_crash() {
    let result = zwo::discover_focusers().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let devices = result.unwrap();
    println!("Found {} ZWO EAF focusers", devices.len());
    for dev in &devices {
        println!(
            "  - {} (ID: {}, SN: {:?})",
            dev.name, dev.focuser_id, dev.serial_number
        );
    }
}

/// Test that filter wheel discovery doesn't crash even without hardware
#[tokio::test]
async fn test_zwo_filter_wheel_discovery_no_crash() {
    let result = zwo::discover_filter_wheels().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let devices = result.unwrap();
    println!("Found {} ZWO EFW filter wheels", devices.len());
    for dev in &devices {
        println!(
            "  - {} (ID: {}, slots: {}, SN: {:?})",
            dev.name, dev.filterwheel_id, dev.slot_count, dev.serial_number
        );
    }
}

/// Test that SVBony camera discovery doesn't crash even without hardware
#[tokio::test]
async fn test_svbony_camera_discovery_no_crash() {
    let result = svbony::discover_devices().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let devices = result.unwrap();
    println!("Found {} SVBony cameras", devices.len());
    for dev in &devices {
        println!(
            "  - {} (ID: {}, SN: {:?}, index: {})",
            dev.name, dev.camera_id, dev.serial_number, dev.discovery_index
        );
    }
}

// Hardware integration (requires ZWO devices connected)
// These tests are ignored by default and can be run with:
// cargo test --test native_driver_tests -- --ignored

/// Test connecting to a ZWO camera (requires hardware)
#[tokio::test]
#[ignore = "Requires ZWO camera connected"]
async fn test_zwo_camera_connect_disconnect() {
    let devices = zwo::discover_devices()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No ZWO cameras found - connect a camera to run this test");
    }

    let first_device = &devices[0];
    println!(
        "Testing with camera: {} (ID: {})",
        first_device.name, first_device.camera_id
    );

    let mut camera = zwo::ZwoCamera::new(first_device.camera_id);

    camera.connect().await.expect("Should connect successfully");
    assert!(camera.is_connected(), "Should be connected");

    let name = camera.name();
    let vendor = camera.vendor();
    println!("Connected to: {} ({})", name, vendor.as_str());

    camera
        .disconnect()
        .await
        .expect("Should disconnect successfully");
    assert!(!camera.is_connected(), "Should be disconnected");
}

/// Test ZWO EAF focuser operations (requires hardware)
#[tokio::test]
#[ignore = "Requires ZWO EAF focuser connected"]
async fn test_zwo_focuser_operations() {
    let devices = zwo::discover_focusers()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No ZWO EAF focusers found - connect a focuser to run this test");
    }

    let first_device = &devices[0];
    println!(
        "Testing with focuser: {} (ID: {})",
        first_device.name, first_device.focuser_id
    );

    let mut focuser = zwo::ZwoFocuser::new(first_device.focuser_id);

    focuser
        .connect()
        .await
        .expect("Should connect successfully");
    assert!(focuser.is_connected(), "Should be connected");

    let position = focuser.get_position().await.expect("Should get position");
    println!("Current position: {}", position);

    let temp = focuser
        .get_temperature()
        .await
        .expect("Should get temperature");
    println!("Temperature: {:?}", temp);

    // Test movement (move 100 steps and back)
    let target = position + 100;
    let max_pos = focuser.get_max_position().await;
    if target < max_pos {
        println!("Moving to position {}...", target);
        focuser.move_to(target).await.expect("Should move");

        while focuser.is_moving().await.unwrap_or(false) {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }

        let new_position = focuser.get_position().await.expect("Should get position");
        println!("New position: {}", new_position);
        assert!(
            (new_position - target).abs() <= 5,
            "Should be at target position (within tolerance)"
        );

        println!("Moving back to position {}...", position);
        focuser.move_to(position).await.expect("Should move back");
        while focuser.is_moving().await.unwrap_or(false) {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
        }
    } else {
        println!(
            "Skipping movement test - position {} would exceed max {}",
            target, max_pos
        );
    }

    focuser
        .disconnect()
        .await
        .expect("Should disconnect successfully");
}

/// Test ZWO EFW filter wheel operations (requires hardware)
#[tokio::test]
#[ignore = "Requires ZWO EFW filter wheel connected"]
async fn test_zwo_filter_wheel_operations() {
    let devices = zwo::discover_filter_wheels()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No ZWO EFW filter wheels found - connect a filter wheel to run this test");
    }

    let first_device = &devices[0];
    println!(
        "Testing with filter wheel: {} (ID: {}, {} slots)",
        first_device.name, first_device.filterwheel_id, first_device.slot_count
    );

    let mut fw = zwo::ZwoFilterWheel::new(first_device.filterwheel_id);

    fw.connect().await.expect("Should connect successfully");
    assert!(fw.is_connected(), "Should be connected");

    let position = fw.get_position().await.expect("Should get position");
    println!("Current position: {}", position);

    let names = fw
        .get_filter_names()
        .await
        .expect("Should get filter names");
    println!("Filter names: {:?}", names);

    let count = fw.get_filter_count().await;
    println!("Filter count: {}", count);
    assert!(count > 0, "Should have at least one filter slot");

    // Test movement to next position (with wraparound)
    let target = (position + 1) % count;
    println!("Moving to position {}...", target);
    fw.move_to_position(target).await.expect("Should move");

    while fw.is_moving().await.unwrap_or(false) {
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    }

    let new_position = fw.get_position().await.expect("Should get position");
    println!("New position: {}", new_position);
    assert_eq!(new_position, target, "Should be at target position");

    println!("Moving back to position {}...", position);
    fw.move_to_position(position)
        .await
        .expect("Should move back");
    while fw.is_moving().await.unwrap_or(false) {
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    }

    fw.disconnect()
        .await
        .expect("Should disconnect successfully");
}

// SVBony hardware integration (requires SVBony devices connected)
// These tests are ignored by default and can be run with:
// cargo test --test native_driver_tests -- --ignored

/// Test connecting to a SVBony camera (requires hardware)
#[tokio::test]
#[ignore = "Requires SVBony camera connected"]
async fn test_svbony_camera_connect_disconnect() {
    let devices = svbony::discover_devices()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No SVBony cameras found - connect a camera to run this test");
    }

    let first_device = &devices[0];
    println!(
        "Testing with camera: {} (ID: {})",
        first_device.name, first_device.camera_id
    );

    let mut camera = svbony::SvbonyCamera::new(first_device.camera_id);

    camera.connect().await.expect("Should connect successfully");
    assert!(camera.is_connected(), "Should be connected");

    let name = camera.name();
    let vendor = camera.vendor();
    println!("Connected to: {} ({})", name, vendor.as_str());

    let caps = camera.capabilities();
    println!(
        "Capabilities: can_cool={}, can_set_gain={}, max_bin={}x{}",
        caps.can_cool, caps.can_set_gain, caps.max_bin_x, caps.max_bin_y
    );

    let sensor = camera.get_sensor_info();
    println!(
        "Sensor: {}x{}, {}-bit, color={}, pixel size={:.2}um",
        sensor.width, sensor.height, sensor.bit_depth, sensor.color, sensor.pixel_size_x
    );

    camera
        .disconnect()
        .await
        .expect("Should disconnect successfully");
    assert!(!camera.is_connected(), "Should be disconnected");
}

/// Test SVBony camera exposure (requires hardware)
#[tokio::test]
#[ignore = "Requires SVBony camera connected"]
async fn test_svbony_camera_exposure() {
    use skotiq_device::ExposureParams;

    let devices = svbony::discover_devices()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No SVBony cameras found - connect a camera to run this test");
    }

    let first_device = &devices[0];
    let mut camera = svbony::SvbonyCamera::new(first_device.camera_id);

    camera.connect().await.expect("Should connect successfully");

    let params = ExposureParams {
        duration_secs: 0.1, // 100ms exposure
        gain: Some(100),
        offset: Some(10),
        bin_x: 1,
        bin_y: 1,
        subframe: None,
        readout_mode: None,
        frame_type: skotiq_device::FrameType::Light,
    };

    println!("Starting 0.1s exposure...");
    camera
        .start_exposure(params)
        .await
        .expect("Should start exposure");

    while !camera.is_exposure_complete().await.unwrap_or(true) {
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }

    println!("Downloading image...");
    let image = camera
        .download_image()
        .await
        .expect("Should download image");
    println!(
        "Image: {}x{}, {}-bit, {} pixels",
        image.width,
        image.height,
        image.bits_per_pixel,
        image.data.len()
    );

    assert!(
        image.metadata.exposure_time > 0.0,
        "Should have exposure time"
    );
    println!(
        "Metadata: exposure={:.3}s, gain={}, offset={}",
        image.metadata.exposure_time, image.metadata.gain, image.metadata.offset
    );

    camera
        .disconnect()
        .await
        .expect("Should disconnect successfully");
}

// QHY CFW filter wheel

/// Test that QHY CFW discovery doesn't crash even without hardware
#[tokio::test]
async fn test_qhy_cfw_discovery_no_crash() {
    let result = qhy::discover_filter_wheels().await;
    // QHY filter wheel discovery requires opening cameras, so may fail if SDK not installed
    // We just ensure it doesn't panic
    match result {
        Ok(devices) => {
            println!("Found {} QHY CFW filter wheels", devices.len());
            for dev in &devices {
                println!(
                    "  - {} (camera: {}, {} slots)",
                    dev.name, dev.camera_id, dev.slot_count
                );
            }
        }
        Err(e) => {
            println!(
                "QHY CFW discovery returned error (SDK may not be installed): {}",
                e
            );
        }
    }
}

/// Test QHY CFW filter wheel operations (requires hardware)
#[tokio::test]
#[ignore = "Requires QHY camera with CFW connected"]
async fn test_qhy_cfw_operations() {
    let devices = qhy::discover_filter_wheels()
        .await
        .expect("Discovery should work");
    if devices.is_empty() {
        panic!("No QHY CFW filter wheels found - connect a QHY camera with CFW to run this test");
    }

    let first_device = &devices[0];
    println!(
        "Testing with filter wheel: {} (camera: {}, {} slots)",
        first_device.name, first_device.camera_id, first_device.slot_count
    );

    let mut fw = qhy::QhyFilterWheel::new(first_device.camera_id.clone());

    fw.connect().await.expect("Should connect successfully");
    assert!(fw.is_connected(), "Should be connected");

    let position = fw.get_position().await.expect("Should get position");
    println!("Current position: {}", position);

    let count = fw.get_filter_count().await;
    println!("Filter count: {}", count);
    assert!(count > 0, "Should have at least one filter slot");

    let names = fw
        .get_filter_names()
        .await
        .expect("Should get filter names");
    println!("Filter names: {:?}", names);

    // Test movement to next position (with wraparound)
    let target = (position + 1) % count;
    println!("Moving to position {}...", target);
    fw.move_to_position(target).await.expect("Should move");

    let new_position = fw.get_position().await.expect("Should get position");
    println!("New position: {}", new_position);
    assert_eq!(new_position, target, "Should be at target position");

    println!("Moving back to position {}...", position);
    fw.move_to_position(position)
        .await
        .expect("Should move back");

    fw.disconnect()
        .await
        .expect("Should disconnect successfully");
}

// Unified discovery

/// Test that the unified discovery finds all device types
#[tokio::test]
async fn test_unified_discovery() {
    use skotiq_device::DeviceKind as DeviceType;
    use skotiq_native::discovery::discover_all_devices;

    let devices = discover_all_devices().await.expect("Discovery should work");
    println!("Unified discovery found {} total devices:", devices.len());

    let cameras: Vec<_> = devices
        .iter()
        .filter(|d| d.device_type == DeviceType::Camera)
        .collect();
    let focusers: Vec<_> = devices
        .iter()
        .filter(|d| d.device_type == DeviceType::Focuser)
        .collect();
    let filter_wheels: Vec<_> = devices
        .iter()
        .filter(|d| d.device_type == DeviceType::FilterWheel)
        .collect();

    println!("  Cameras: {}", cameras.len());
    println!("  Focusers: {}", focusers.len());
    println!("  Filter Wheels: {}", filter_wheels.len());

    for dev in &devices {
        println!(
            "  - {} ({:?}, {})",
            dev.display_name,
            dev.device_type,
            dev.vendor.as_str()
        );
    }
}

// Mount discovery (no hardware required; scans serial ports)

/// Test that Sky-Watcher mount discovery doesn't crash
#[tokio::test]
async fn test_skywatcher_mount_discovery_no_crash() {
    let result = skywatcher::discover_mounts().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let mounts = result.unwrap();
    println!("Found {} Sky-Watcher mounts:", mounts.len());
    for mount in &mounts {
        println!("  - {} (port: {})", mount.name, mount.port);
    }
}

/// Test that iOptron mount discovery doesn't crash
#[tokio::test]
async fn test_ioptron_mount_discovery_no_crash() {
    let result = ioptron::discover_mounts().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let mounts = result.unwrap();
    println!("Found {} iOptron mounts:", mounts.len());
    for mount in &mounts {
        println!("  - {} (port: {})", mount.name, mount.port);
    }
}

/// Test that LX200 mount discovery doesn't crash
#[tokio::test]
async fn test_lx200_mount_discovery_no_crash() {
    let result = lx200::discover_mounts().await;
    assert!(
        result.is_ok(),
        "Discovery should not error even without devices"
    );
    let mounts = result.unwrap();
    println!("Found {} LX200-compatible mounts:", mounts.len());
    for mount in &mounts {
        println!(
            "  - {} (port: {}, type: {:?})",
            mount.name, mount.port, mount.mount_type
        );
    }
}

/// Test that unified discovery includes mounts
#[tokio::test]
async fn test_unified_discovery_includes_mounts() {
    use skotiq_device::DeviceKind as DeviceType;
    use skotiq_native::discovery::discover_all_devices;

    let devices = discover_all_devices().await.expect("Discovery should work");
    let mounts: Vec<_> = devices
        .iter()
        .filter(|d| d.device_type == DeviceType::Mount)
        .collect();

    println!("Unified discovery found {} mounts:", mounts.len());
    for mount in &mounts {
        println!(
            "  - {} ({}, id: {})",
            mount.display_name,
            mount.vendor.as_str(),
            mount.id
        );
    }
}

// Mount hardware integration (requires mounts connected)
// These tests are ignored by default and can be run with:
// cargo test --test native_driver_tests -- --ignored

/// The site a Sky-Watcher hardware test points with, from
/// `SKYWATCHER_TEST_SITE=<latitude>,<longitude east>`: the motor controller
/// keeps none of its own.
fn skywatcher_test_site() -> skotiq_device::SiteSource {
    let text = std::env::var("SKYWATCHER_TEST_SITE")
        .expect("set SKYWATCHER_TEST_SITE=<latitude>,<longitude east> for the Sky-Watcher tests");
    let (lat, lon) = text
        .split_once(',')
        .expect("SKYWATCHER_TEST_SITE is <latitude>,<longitude east>");
    let site = skotiq_device::MountSiteInfo {
        latitude_deg: lat.trim().parse().expect("latitude"),
        longitude_deg: lon.trim().parse().expect("longitude"),
        elevation_m: None,
    };
    std::sync::Arc::new(move || Some(site))
}

/// Test connecting to a Sky-Watcher mount (requires hardware)
#[tokio::test]
#[ignore = "Requires Sky-Watcher mount connected"]
async fn test_skywatcher_mount_connect_disconnect() {
    let mounts = skywatcher::discover_mounts()
        .await
        .expect("Discovery should work");
    if mounts.is_empty() {
        panic!("No Sky-Watcher mounts found - connect a mount to run this test");
    }

    let first_mount = &mounts[0];
    println!(
        "Testing with mount: {} (port: {})",
        first_mount.name, first_mount.port
    );

    let mut mount = skywatcher::SkyWatcherMount::new_serial(
        first_mount.port.clone(),
        Some(first_mount.baud_rate),
        skywatcher_test_site(),
    );

    mount.connect().await.expect("Should connect successfully");
    assert!(mount.is_connected(), "Should be connected");

    let name = mount.name();
    let vendor = mount.vendor();
    println!("Connected to: {} ({})", name, vendor.as_str());

    match mount.get_coordinates().await {
        Ok((ra, dec)) => println!("Current position: RA={:.4}h, Dec={:.4}°", ra, dec),
        Err(e) => println!("Could not get coordinates: {}", e),
    }

    match mount.get_tracking().await {
        Ok(tracking) => println!("Tracking: {}", tracking),
        Err(e) => println!("Could not get tracking: {}", e),
    }
    match mount.is_slewing().await {
        Ok(slewing) => println!("Slewing: {}", slewing),
        Err(e) => println!("Could not get slewing: {}", e),
    }
    match mount.is_parked().await {
        Ok(parked) => println!("Parked: {}", parked),
        Err(e) => println!("Could not get parked: {}", e),
    }

    mount
        .disconnect()
        .await
        .expect("Should disconnect successfully");
    assert!(!mount.is_connected(), "Should be disconnected");
}

/// Test connecting to an iOptron mount (requires hardware)
#[tokio::test]
#[ignore = "Requires iOptron mount connected"]
async fn test_ioptron_mount_connect_disconnect() {
    let mounts = ioptron::discover_mounts()
        .await
        .expect("Discovery should work");
    if mounts.is_empty() {
        panic!("No iOptron mounts found - connect a mount to run this test");
    }

    let first_mount = &mounts[0];
    println!(
        "Testing with mount: {} (port: {})",
        first_mount.name, first_mount.port
    );

    let mut mount = ioptron::IOptronMount::new(
        first_mount.port.clone(),
        None, // Use default baud rate
    );

    mount.connect().await.expect("Should connect successfully");
    assert!(mount.is_connected(), "Should be connected");

    let name = mount.name();
    let vendor = mount.vendor();
    println!("Connected to: {} ({})", name, vendor.as_str());

    match mount.get_coordinates().await {
        Ok((ra, dec)) => println!("Current position: RA={:.4}h, Dec={:.4}°", ra, dec),
        Err(e) => println!("Could not get coordinates: {}", e),
    }

    match mount.get_tracking().await {
        Ok(tracking) => println!("Tracking: {}", tracking),
        Err(e) => println!("Could not get tracking status: {}", e),
    }

    mount
        .disconnect()
        .await
        .expect("Should disconnect successfully");
    assert!(!mount.is_connected(), "Should be disconnected");
}

/// Test connecting to an LX200-compatible mount (requires hardware)
#[tokio::test]
#[ignore = "Requires LX200-compatible mount connected"]
async fn test_lx200_mount_connect_disconnect() {
    let mounts = lx200::discover_mounts()
        .await
        .expect("Discovery should work");
    if mounts.is_empty() {
        panic!("No LX200-compatible mounts found - connect a mount to run this test");
    }

    let first_mount = &mounts[0];
    println!(
        "Testing with mount: {} (port: {}, type: {:?})",
        first_mount.name, first_mount.port, first_mount.mount_type
    );

    let mut mount = lx200::Lx200Mount::new(
        first_mount.port.clone(),
        first_mount.mount_type.clone(),
        None, // Use default baud rate
    );

    mount.connect().await.expect("Should connect successfully");
    assert!(mount.is_connected(), "Should be connected");

    let name = mount.name();
    let vendor = mount.vendor();
    println!("Connected to: {} ({})", name, vendor.as_str());

    match mount.get_coordinates().await {
        Ok((ra, dec)) => println!("Current position: RA={:.4}h, Dec={:.4}°", ra, dec),
        Err(e) => println!("Could not get coordinates: {}", e),
    }

    match mount.get_tracking().await {
        Ok(tracking) => println!("Tracking: {}", tracking),
        Err(e) => println!("Could not get tracking status: {}", e),
    }

    mount
        .disconnect()
        .await
        .expect("Should disconnect successfully");
    assert!(!mount.is_connected(), "Should be disconnected");
}

/// Test Sky-Watcher mount slewing (requires hardware)
#[tokio::test]
#[ignore = "Requires Sky-Watcher mount connected - WILL MOVE MOUNT"]
async fn test_skywatcher_mount_slew() {
    let mounts = skywatcher::discover_mounts()
        .await
        .expect("Discovery should work");
    if mounts.is_empty() {
        panic!("No Sky-Watcher mounts found - connect a mount to run this test");
    }

    let first_mount = &mounts[0];
    let mut mount = skywatcher::SkyWatcherMount::new_serial(
        first_mount.port.clone(),
        Some(first_mount.baud_rate),
        skywatcher_test_site(),
    );

    mount.connect().await.expect("Should connect successfully");

    let (start_ra, start_dec) = mount
        .get_coordinates()
        .await
        .expect("Should get coordinates");
    println!("Start position: RA={:.4}h, Dec={:.4}°", start_ra, start_dec);

    // Slew to a nearby position (add 0.01 hours to RA)
    let target_ra = start_ra + 0.01;
    let target_dec = start_dec;
    println!("Slewing to: RA={:.4}h, Dec={:.4}°", target_ra, target_dec);

    mount
        .slew_to_coordinates(target_ra, target_dec)
        .await
        .expect("Should start slew");

    // Wait for slew to complete (with timeout)
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(30);
    loop {
        if start.elapsed() > timeout {
            println!("Slew timeout - aborting");
            mount.abort_slew().await.ok();
            break;
        }
        let is_slewing = mount.is_slewing().await.unwrap_or(false);
        if !is_slewing {
            break;
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
    }

    let (end_ra, end_dec) = mount
        .get_coordinates()
        .await
        .expect("Should get coordinates");
    println!("End position: RA={:.4}h, Dec={:.4}°", end_ra, end_dec);

    mount
        .disconnect()
        .await
        .expect("Should disconnect successfully");
}

#[cfg(windows)]
mod fake_sdk_contract {
    use super::*;
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_fake_sdk_shims_exercise_camera_focuser_filterwheel() {
        let shim_dir = build_fake_sdks();
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));

        let cameras = zwo::discover_devices().await.expect("camera discovery");
        assert_eq!(cameras.len(), 3);
        assert_eq!(cameras[0].name, "Skotiq Fake ASI2600MM Pro");
        assert_eq!(
            cameras[0].sdk_version.as_deref(),
            Some("ZWO ASI SDK vfake-asi-1.0")
        );

        let mut camera = zwo::ZwoCamera::new(cameras[0].camera_id);
        camera.connect().await.expect("camera connect");
        assert!(camera.is_connected());
        assert!(camera.capabilities().can_cool);
        camera.set_gain(42).await.expect("set gain");
        camera.set_offset(8).await.expect("set offset");
        camera.set_binning(2, 2).await.expect("set binning");
        camera
            .set_cooler(true, Some(-12.0))
            .await
            .expect("set cooler");
        let status = camera.get_status().await.expect("camera status");
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.gain, 42);
        assert_eq!(status.offset, 8);
        camera
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(55),
                offset: Some(9),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("start exposure");
        assert!(camera
            .is_exposure_complete()
            .await
            .expect("exposure complete"));
        let image = camera.download_image().await.expect("download image");
        assert_eq!((image.width, image.height), (32, 24));
        assert_eq!(image.bits_per_pixel, 16);
        assert_eq!(image.data[0], 1000);
        camera
            .start_exposure(ExposureParams {
                duration_secs: 10.0,
                gain: None,
                offset: None,
                bin_x: 1,
                bin_y: 1,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("start exposure before abort");
        camera.abort_exposure().await.expect("abort exposure");
        assert!(matches!(
            camera.get_status().await.expect("status after abort").state,
            skotiq_device::CameraState::Idle
        ));
        camera.disconnect().await.expect("camera disconnect");

        let focusers = zwo::discover_focusers().await.expect("focuser discovery");
        assert_eq!(focusers.len(), 1);
        assert_eq!(
            focusers[0].sdk_version.as_deref(),
            Some("ZWO EAF SDK vfake-eaf-1.0")
        );
        let mut focuser = zwo::ZwoFocuser::new(focusers[0].focuser_id);
        focuser.connect().await.expect("focuser connect");
        assert_eq!(focuser.get_max_position().await, 60_000);
        focuser.move_to(12_345).await.expect("focuser move");
        assert_eq!(
            focuser.get_position().await.expect("focuser position"),
            12_345
        );
        assert!(!focuser.is_moving().await.expect("focuser moving"));
        assert_eq!(
            focuser.get_temperature().await.expect("focuser temp"),
            Some(21.5)
        );
        focuser.halt().await.expect("focuser halt");
        focuser.disconnect().await.expect("focuser disconnect");

        // Persisted profiles connect by hardware ID before a discovery scan.
        // The driver must prime the EFW SDK's ID table itself.
        let mut wheel = zwo::ZwoFilterWheel::new(0);
        wheel
            .connect()
            .await
            .expect("direct filter wheel connect before discovery");
        let wheels = zwo::discover_filter_wheels()
            .await
            .expect("connected filter wheel discovery");
        assert_eq!(wheels.len(), 1);
        assert_eq!(
            wheels[0].sdk_version.as_deref(),
            Some("ZWO EFW SDK vfake-efw-1.0")
        );
        assert_eq!(wheel.get_filter_count().await, 7);
        wheel.move_to_position(3).await.expect("move filter");
        assert_eq!(wheel.get_position().await.expect("moved filter"), 3);
        wheel.disconnect().await.expect("filter wheel disconnect");

        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_atik_fake_sdk_shim_exercises_camera_flow() {
        let shim_dir =
            build_single_fake_sdk("atik", "atik_fake.rs", "AtikCameras.dll", ATIK_FAKE_SDK);
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));

        let devices = atik::discover_devices().await.expect("Atik discovery");
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].name, "Skotiq Fake Atik Horizon II");
        assert_eq!(devices[0].sdk_version.as_deref(), Some("Atik SDK v66000"));

        let mut camera = atik::AtikCamera::new(devices[0].device_index);
        camera.connect().await.expect("Atik connect");
        assert!(camera.is_connected());
        assert!(camera.capabilities().can_cool);
        // The CFA published for the session comes from the SDK's
        // ARTEMISCOLOURTYPE answer, not from a default: the shim reports RGGB,
        // so the sensor must read as colour and carry the RGGB pattern that
        // becomes each frame's BAYERPAT card.
        let sensor = camera.get_sensor_info();
        assert!(
            sensor.color,
            "RGGB colour type must publish a colour sensor"
        );
        assert_eq!(
            sensor.bayer_pattern,
            Some(skotiq_device::BayerPattern::Rggb)
        );
        camera.set_gain(17).await.expect("Atik set gain");
        camera.set_offset(4).await.expect("Atik set offset");
        camera.set_binning(2, 2).await.expect("Atik set binning");
        camera
            .set_cooler(true, Some(-10.0))
            .await
            .expect("Atik set cooler");
        assert!(camera
            .is_exposure_complete()
            .await
            .expect("Atik initial ready"));
        camera
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(21),
                offset: Some(5),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("Atik start exposure");
        assert!(camera
            .is_exposure_complete()
            .await
            .expect("Atik exposure complete"));
        let image = camera.download_image().await.expect("Atik image download");
        assert_eq!((image.width, image.height), (16, 12));
        assert_eq!(image.bits_per_pixel, 16);
        assert_eq!(image.data[0], 2000);
        camera.abort_exposure().await.expect("Atik abort");
        camera.disconnect().await.expect("Atik disconnect");

        let wheels = atik::discover_filter_wheels()
            .await
            .expect("Atik EFW discovery");
        assert_eq!(wheels.len(), 1);
        assert_eq!(wheels[0].name, "Atik EFW2/EFW3");
        assert_eq!(wheels[0].sdk_version.as_deref(), Some("Atik SDK v66000"));
        assert_eq!(
            wheels[0].serial_number.as_deref(),
            Some("ATIK-EFW-FAKE-0001")
        );

        let mut wheel = atik::AtikFilterWheel::new(wheels[0].device_index);
        wheel.connect().await.expect("Atik EFW connect");
        assert_eq!(wheel.get_filter_count().await, 7);
        wheel.move_to_position(4).await.expect("Atik EFW move");
        assert_eq!(wheel.get_position().await.expect("Atik EFW position"), 4);
        assert!(!wheel.is_moving().await.expect("Atik EFW moving"));
        wheel.disconnect().await.expect("Atik EFW disconnect");

        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_svbony_fake_sdk_shim_exercises_camera_flow() {
        let shim_dir = build_single_fake_sdk(
            "svbony",
            "svbony_fake.rs",
            "SVBCameraSDK.dll",
            SVBONY_FAKE_SDK,
        );
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));

        let devices = svbony::discover_devices().await.expect("SVBONY discovery");
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].name, "SVBONY SV405CC");
        assert_eq!(
            devices[0].sdk_version.as_deref(),
            Some("SVBony SDK vfake-svbony-1.13")
        );

        let mut camera = svbony::SvbonyCamera::new(devices[0].camera_id);
        camera.connect().await.expect("SVBONY connect");
        assert!(camera.is_connected());
        assert!(camera.capabilities().can_cool);
        camera.set_gain(33).await.expect("SVBONY set gain");
        camera.set_offset(6).await.expect("SVBONY set offset");
        camera.set_binning(2, 2).await.expect("SVBONY set binning");
        camera
            .set_cooler(true, Some(-8.0))
            .await
            .expect("SVBONY set cooler");
        camera
            .start_exposure(ExposureParams {
                duration_secs: 0.0,
                gain: Some(44),
                offset: Some(7),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("SVBONY start exposure");
        assert_eq!(camera.get_gain().await.expect("SVBONY read gain"), 44);
        assert_eq!(camera.get_offset().await.expect("SVBONY read offset"), 7);
        let status = camera.get_status().await.expect("SVBONY status");
        assert_eq!(status.gain, 44);
        assert_eq!(status.offset, 7);
        assert!(camera
            .is_exposure_complete()
            .await
            .expect("SVBONY exposure complete"));
        let image = camera
            .download_image()
            .await
            .expect("SVBONY image download");
        assert_eq!((image.width, image.height), (24, 14));
        assert_eq!(image.bits_per_pixel, 14);
        assert_eq!(image.data[0], 1001);
        assert_eq!(image.metadata.gain, 44);
        assert_eq!(image.metadata.offset, 7);
        camera.abort_exposure().await.expect("SVBONY abort");
        camera.disconnect().await.expect("SVBONY disconnect");

        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_player_one_fake_sdk_shim_exercises_model_and_edge_flows() {
        let shim_dir = build_single_fake_sdk(
            "player-one",
            "player_one_fake.rs",
            "PlayerOneCamera.dll",
            PLAYER_ONE_FAKE_SDK,
        );
        compile_cdylib(
            &shim_dir,
            "player_one_pw_fake.rs",
            "PlayerOnePW.dll",
            PLAYER_ONE_PW_FAKE_SDK,
        );
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        let old_not_ready = env::var("SK_POA_NOT_READY").ok();
        let old_start_error = env::var("SK_POA_START_ERROR").ok();
        let old_image_error = env::var("SK_POA_IMAGE_ERROR").ok();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));
        env::remove_var("SK_POA_NOT_READY");
        env::remove_var("SK_POA_START_ERROR");
        env::remove_var("SK_POA_IMAGE_ERROR");

        let devices = player_one::discover_devices()
            .await
            .expect("Player One discovery");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "Skotiq Fake Poseidon-M Pro");
        assert_eq!(devices[1].name, "Skotiq Fake Neptune-C II");
        assert_eq!(
            devices[0].sdk_version.as_deref(),
            Some("Player One SDK vfake-playerone-camera-1.0")
        );
        assert_eq!(
            devices[1].sdk_version.as_deref(),
            Some("Player One SDK vfake-playerone-camera-1.0")
        );

        let mut cooled = player_one::PlayerOneCamera::new(devices[0].camera_id);
        cooled.connect().await.expect("Player One cooled connect");
        assert!(cooled.is_connected());
        assert!(cooled.capabilities().can_cool);
        assert!(cooled.capabilities().has_guider_port);
        let sensor = cooled.get_sensor_info();
        assert_eq!((sensor.width, sensor.height), (64, 48));
        assert_eq!(sensor.bit_depth, 16);
        assert!(!sensor.color);
        cooled.set_gain(73).await.expect("Player One set gain");
        cooled.set_offset(11).await.expect("Player One set offset");
        cooled
            .set_binning(2, 2)
            .await
            .expect("Player One set binning");
        cooled
            .set_cooler(true, Some(-14.0))
            .await
            .expect("Player One set cooler");
        let status = cooled.get_status().await.expect("Player One status");
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.gain, 73);
        assert_eq!(status.offset, 11);

        env::set_var("SK_POA_NOT_READY", "1");
        assert!(!cooled
            .is_exposure_complete()
            .await
            .expect("Player One not-ready poll"));
        env::remove_var("SK_POA_NOT_READY");

        env::set_var("SK_POA_START_ERROR", "1");
        let start_error = cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(74),
                offset: Some(12),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect_err("undocumented Player One SDK error should propagate");
        assert!(format!("{start_error}").contains("Unknown POA error code"));
        env::remove_var("SK_POA_START_ERROR");

        cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(75),
                offset: Some(13),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("Player One start exposure");
        assert!(cooled
            .is_exposure_complete()
            .await
            .expect("Player One exposure complete"));

        env::set_var("SK_POA_IMAGE_ERROR", "1");
        cooled
            .download_image()
            .await
            .expect_err("Player One image transfer error should propagate");
        env::remove_var("SK_POA_IMAGE_ERROR");

        let image = cooled
            .download_image()
            .await
            .expect("Player One image download");
        assert_eq!((image.width, image.height), (32, 24));
        assert_eq!(image.bits_per_pixel, 16);
        assert_eq!(image.metadata.vendor_data.usb_bandwidth, Some(68.0));
        assert_eq!(image.data[0], 5000);
        cooled.abort_exposure().await.expect("Player One abort");
        cooled
            .disconnect()
            .await
            .expect("Player One cooled disconnect");

        let mut planetary = player_one::PlayerOneCamera::new(devices[1].camera_id);
        planetary
            .connect()
            .await
            .expect("Player One planetary connect");
        assert!(!planetary.capabilities().can_cool);
        let planetary_sensor = planetary.get_sensor_info();
        assert!(planetary_sensor.color);
        assert_eq!(planetary_sensor.bit_depth, 12);
        planetary
            .set_cooler(true, Some(-5.0))
            .await
            .expect_err("uncooled Player One camera should reject cooler control");
        planetary
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: None,
                offset: None,
                bin_x: 1,
                bin_y: 1,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("Player One planetary start exposure");
        let planetary_image = planetary
            .download_image()
            .await
            .expect("Player One planetary image download");
        assert_eq!(planetary_image.bits_per_pixel, 12);
        planetary
            .disconnect()
            .await
            .expect("Player One planetary disconnect");

        let wheels = player_one::discover_filter_wheels()
            .await
            .expect("Player One PW discovery");
        assert_eq!(wheels.len(), 1);
        assert_eq!(wheels[0].name, "Skotiq Fake Phoenix Wheel");
        assert_eq!(wheels[0].serial_number.as_deref(), Some("PW-FAKE-0001"));
        assert_eq!(
            wheels[0].sdk_version.as_deref(),
            Some("Player One PW SDK vfake-playerone-pw-1.0")
        );
        assert_eq!(wheels[0].position_count, 7);

        let mut wheel = player_one::PlayerOneFilterWheel::new(wheels[0].handle);
        wheel.connect().await.expect("Player One PW connect");
        assert_eq!(wheel.get_filter_count().await, 7);
        wheel.move_to_position(3).await.expect("Player One PW move");
        assert_eq!(
            wheel.get_position().await.expect("Player One PW position"),
            -1,
            "a turning wheel reads -1"
        );
        let mut position = -1;
        for _ in 0..10 {
            position = wheel.get_position().await.expect("Player One PW position");
            if position != -1 {
                break;
            }
        }
        assert_eq!(position, 3);
        assert!(!wheel.is_moving().await.expect("Player One PW moving"));
        wheel
            .set_filter_name(3, "Ha".to_string())
            .await
            .expect("Player One PW set alias");
        let names = wheel
            .get_filter_names()
            .await
            .expect("Player One PW filter names");
        assert_eq!(names[3], "Ha");
        wheel.disconnect().await.expect("Player One PW disconnect");

        restore_env_var("SK_POA_NOT_READY", old_not_ready);
        restore_env_var("SK_POA_START_ERROR", old_start_error);
        restore_env_var("SK_POA_IMAGE_ERROR", old_image_error);
        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_qhy_fake_sdk_shim_exercises_camera_filterwheel_and_model_flows() {
        let shim_dir = build_single_fake_sdk("qhy", "qhy_fake.rs", "qhyccd.dll", QHY_FAKE_SDK);
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        let old_exposure_error = env::var("SK_QHY_EXPOSURE_ERROR").ok();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));
        env::remove_var("SK_QHY_EXPOSURE_ERROR");

        let devices = qhy::discover_devices().await.expect("QHY discovery");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "QHY268M");
        assert_eq!(devices[1].name, "QHY5III462C");
        assert_eq!(
            devices[0].sdk_version.as_deref(),
            Some("QHY SDK v2026.05.25.1")
        );
        assert_eq!(
            devices[1].sdk_version.as_deref(),
            Some("QHY SDK v2026.05.25.1")
        );

        let mut cooled = qhy::QhyCamera::new(devices[0].camera_id.clone());
        cooled.connect().await.expect("QHY cooled connect");
        assert!(cooled.is_connected());
        assert!(cooled.capabilities().can_cool);
        assert!(cooled.capabilities().has_guider_port);
        let sensor = cooled.get_sensor_info();
        assert_eq!((sensor.width, sensor.height), (64, 48));
        assert_eq!(sensor.bit_depth, 16);
        assert!(!sensor.color);
        let modes = cooled.get_readout_modes().await.expect("QHY read modes");
        assert_eq!(modes.len(), 2);
        cooled
            .set_readout_mode(&modes[1])
            .await
            .expect("QHY set readout mode");
        cooled.set_gain(81).await.expect("QHY set gain");
        cooled.set_offset(14).await.expect("QHY set offset");
        cooled.set_binning(2, 2).await.expect("QHY set binning");
        cooled
            .set_cooler(true, Some(-18.0))
            .await
            .expect("QHY set cooler");
        let status = cooled.get_status().await.expect("QHY status");
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.target_temp, Some(-18.0));
        assert_eq!(status.gain, 81);
        assert_eq!(status.offset, 14);

        env::set_var("SK_QHY_EXPOSURE_ERROR", "1");
        cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(82),
                offset: Some(15),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect_err("QHY SDK exposure failure should propagate");
        env::remove_var("SK_QHY_EXPOSURE_ERROR");

        cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: Some(83),
                offset: Some(16),
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("QHY start exposure");
        let image = cooled.download_image().await.expect("QHY image download");
        assert_eq!((image.width, image.height), (32, 24));
        assert_eq!(image.bits_per_pixel, 16);
        assert_eq!(image.metadata.vendor_data.usb_bandwidth, Some(40.0));
        assert_eq!(image.data[0], 6000);
        cooled.abort_exposure().await.expect("QHY abort");
        cooled.disconnect().await.expect("QHY cooled disconnect");

        let wheels = qhy::discover_filter_wheels()
            .await
            .expect("QHY CFW discovery");
        assert_eq!(wheels.len(), 1);
        assert_eq!(wheels[0].slot_count, 7);
        assert_eq!(
            wheels[0].sdk_version.as_deref(),
            Some("QHY SDK v2026.05.25.1")
        );
        let mut wheel = qhy::QhyFilterWheel::new(wheels[0].camera_id.clone());
        wheel.connect().await.expect("QHY CFW connect");
        assert_eq!(wheel.get_filter_count().await, 7);
        wheel.move_to_position(2).await.expect("QHY CFW move");
        assert_eq!(wheel.get_position().await.expect("QHY CFW position"), 2);
        wheel.disconnect().await.expect("QHY CFW disconnect");

        let mut guide = qhy::QhyCamera::new(devices[1].camera_id.clone());
        guide.connect().await.expect("QHY guide connect");
        assert!(!guide.capabilities().can_cool);
        let guide_sensor = guide.get_sensor_info();
        assert!(guide_sensor.color);
        assert_eq!(
            guide_sensor.bayer_pattern,
            Some(skotiq_device::BayerPattern::Bggr)
        );
        guide
            .set_cooler(true, Some(-5.0))
            .await
            .expect_err("uncooled QHY guide camera should reject cooler control");
        guide.disconnect().await.expect("QHY guide disconnect");

        restore_env_var("SK_QHY_EXPOSURE_ERROR", old_exposure_error);
        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_touptek_fake_sdk_shim_exercises_white_label_model_flows() {
        let shim_dir = build_single_fake_sdk(
            "touptek",
            "touptek_fake.rs",
            "ogmacam.dll",
            TOUPTEK_FAKE_SDK,
        );
        let old_dir = env::current_dir().expect("read current dir");
        let old_path = env::var("PATH").unwrap_or_default();
        let old_pull_error = env::var("SK_TOUPTEK_PULL_ERROR").ok();
        env::set_current_dir(&shim_dir).expect("switch to fake SDK dir");
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));
        env::remove_var("SK_TOUPTEK_PULL_ERROR");

        let devices = touptek::discover_devices_for_brand("OGMA")
            .await
            .expect("OGMA/ToupTek discovery");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "OGMA AP26CC");
        assert_eq!(devices[1].name, "OGMA GP2000M");
        assert_eq!(
            devices[0].sdk_version.as_deref(),
            Some("OGMA SDK vfake-ogma-1.0")
        );
        assert_eq!(
            devices[1].sdk_version.as_deref(),
            Some("OGMA SDK vfake-ogma-1.0")
        );

        let mut cooled = touptek::TouptekCamera::new(0, "OGMA");
        cooled.connect().await.expect("ToupTek cooled connect");
        assert!(cooled.capabilities().can_cool);
        assert!(cooled.capabilities().can_subframe);
        assert!(cooled.capabilities().can_set_binning);
        let sensor = cooled.get_sensor_info();
        assert_eq!((sensor.width, sensor.height), (80, 60));
        assert!(sensor.color);
        assert_eq!(sensor.bit_depth, 12);
        cooled
            .set_cooler(true, Some(-12.5))
            .await
            .expect("ToupTek set cooler");
        cooled.set_gain(250).await.expect("ToupTek set gain");
        assert_eq!(cooled.get_gain().await.expect("ToupTek read gain"), 250);
        let exposure = |duration_secs: f64| ExposureParams {
            duration_secs,
            gain: Some(260),
            offset: None,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            readout_mode: None,
            frame_type: skotiq_device::FrameType::Light,
        };

        env::set_var("SK_TOUPTEK_PULL_ERROR", "1");
        cooled
            .start_exposure(exposure(0.01))
            .await
            .expect("ToupTek start exposure");
        let status = cooled.get_status().await.expect("ToupTek status");
        assert_eq!(status.gain, 260);
        cooled
            .download_image()
            .await
            .expect_err("ToupTek camera error event should propagate");
        env::remove_var("SK_TOUPTEK_PULL_ERROR");

        cooled
            .start_exposure(exposure(0.2))
            .await
            .expect("ToupTek start exposure");
        assert!(!cooled
            .is_exposure_complete()
            .await
            .expect("ToupTek exposure status"));
        let image = cooled
            .download_image()
            .await
            .expect("ToupTek image download");
        assert_eq!((image.width, image.height), (80, 60));
        assert_eq!(image.bits_per_pixel, 12);
        // The fake's top-left sensor pixel of its second frame: on Windows the SDK
        // starts bottom row first, so this also proves the driver asked for top first.
        assert_eq!(image.data[0], 102);
        assert_eq!(image.metadata.gain, 260);
        // 200 ms in the fake's whole 15 us lines.
        assert!((image.metadata.exposure_time - 0.199995).abs() < 1e-9);
        cooled
            .disconnect()
            .await
            .expect("ToupTek cooled disconnect");

        let mut uncooled = touptek::TouptekCamera::new(1, "OGMA");
        uncooled.connect().await.expect("ToupTek uncooled connect");
        assert!(!uncooled.capabilities().can_cool);
        assert!(!uncooled.get_sensor_info().color);
        uncooled
            .set_cooler(true, Some(-5.0))
            .await
            .expect_err("uncooled ToupTek camera should reject cooler control");
        uncooled
            .disconnect()
            .await
            .expect("ToupTek uncooled disconnect");

        restore_env_var("SK_TOUPTEK_PULL_ERROR", old_pull_error);
        env::set_current_dir(old_dir).expect("restore current dir");
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_fli_fake_sdk_shim_exercises_camera_focuser_and_filterwheel_flows() {
        let shim_dir = build_single_fake_sdk("fli", "fli_fake.rs", "libfli.dll", FLI_FAKE_SDK);
        let old_path = env::var("PATH").unwrap_or_default();
        let old_grab_error = env::var("SK_FLI_GRAB_ERROR").ok();
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));
        env::remove_var("SK_FLI_GRAB_ERROR");

        let cameras = fli::discover_cameras().await.expect("FLI camera discovery");
        let focusers = fli::discover_focusers()
            .await
            .expect("FLI focuser discovery");
        let wheels = fli::discover_filter_wheels()
            .await
            .expect("FLI filter wheel discovery");
        assert_eq!(cameras.len(), 1);
        assert_eq!(focusers.len(), 1);
        assert_eq!(wheels.len(), 1);
        assert_eq!(
            cameras[0].sdk_version.as_deref(),
            Some("FLI libfli vfake-libfli-1.0")
        );
        assert_eq!(
            focusers[0].sdk_version.as_deref(),
            Some("FLI libfli vfake-libfli-1.0")
        );
        assert_eq!(
            wheels[0].sdk_version.as_deref(),
            Some("FLI libfli vfake-libfli-1.0")
        );

        let mut camera = fli::FliCamera::new(cameras[0].device_path.clone());
        camera.connect().await.expect("FLI camera connect");
        assert!(camera.capabilities().can_cool);
        assert!(camera.capabilities().can_subframe);
        assert_eq!(
            (
                camera.get_sensor_info().width,
                camera.get_sensor_info().height
            ),
            (64, 48)
        );
        camera
            .set_cooler(true, Some(-20.0))
            .await
            .expect("FLI cooler");
        camera
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: None,
                offset: None,
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("FLI start exposure");
        async fn wait_for_frame(camera: &fli::FliCamera) -> bool {
            for _ in 0..200 {
                if camera
                    .is_exposure_complete()
                    .await
                    .expect("FLI exposure complete")
                {
                    return true;
                }
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
            false
        }
        assert!(wait_for_frame(&camera).await);

        env::set_var("SK_FLI_GRAB_ERROR", "1");
        camera
            .download_image()
            .await
            .expect_err("FLI row grab failure should propagate");
        env::remove_var("SK_FLI_GRAB_ERROR");
        // The failed download discarded the frame; take another.
        camera
            .start_exposure(ExposureParams {
                duration_secs: 0.01,
                gain: None,
                offset: None,
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("FLI start exposure after a failed download");
        assert!(wait_for_frame(&camera).await);
        let image = camera.download_image().await.expect("FLI image download");
        assert_eq!((image.width, image.height), (32, 24));
        assert_eq!(image.data[0], 1000);
        camera.disconnect().await.expect("FLI camera disconnect");

        let mut focuser = fli::FliFocuser::new(focusers[0].device_path.clone());
        focuser.connect().await.expect("FLI focuser connect");
        assert_eq!(focuser.get_max_position().await, 50000);
        focuser.move_relative(120).await.expect("FLI focuser move");
        assert_eq!(focuser.get_position().await.expect("FLI focuser pos"), 120);
        assert!(!focuser.is_moving().await.expect("FLI focuser moving"));
        focuser.disconnect().await.expect("FLI focuser disconnect");

        let mut wheel = fli::FliFilterWheel::new(wheels[0].device_path.clone());
        wheel.connect().await.expect("FLI wheel connect");
        assert_eq!(wheel.get_filter_count().await, 5);
        wheel.move_to_position(3).await.expect("FLI wheel move");
        assert_eq!(wheel.get_position().await.expect("FLI wheel pos"), 3);
        assert_eq!(
            wheel
                .get_filter_names()
                .await
                .expect("FLI filter names")
                .len(),
            5
        );
        wheel.disconnect().await.expect("FLI wheel disconnect");

        restore_env_var("SK_FLI_GRAB_ERROR", old_grab_error);
        env::set_var("PATH", old_path);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_moravian_fake_sdk_shim_exercises_camera_model_and_edge_flows() {
        let shim_dir = build_single_fake_sdk(
            "moravian",
            "moravian_cxusb_fake.rs",
            "cXusb.dll",
            MORAVIAN_CXUSB_FAKE_SDK,
        );
        let old_path = env::var("PATH").unwrap_or_default();
        let old_begin_error = env::var("SK_MORAVIAN_BEGIN_ERROR").ok();
        env::set_var("PATH", format!("{};{}", shim_dir.display(), old_path));
        env::remove_var("SK_MORAVIAN_BEGIN_ERROR");

        let devices = moravian::discover_devices()
            .await
            .expect("Moravian discovery");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "C3-61000 Pro");
        assert_eq!(devices[1].name, "C1-3000");

        assert_eq!(devices[0].address(), "cx:1");
        let mut cooled =
            moravian::MoravianCamera::from_address(&devices[0].address()).expect("a cXusb address");
        cooled.connect().await.expect("Moravian cooled connect");
        assert!(cooled.capabilities().can_cool);
        assert!(cooled.capabilities().can_set_binning);
        assert!(cooled.capabilities().has_shutter);
        let sensor = cooled.get_sensor_info();
        assert_eq!((sensor.width, sensor.height), (72, 54));
        assert!(!sensor.color);
        cooled.set_gain(7).await.expect("Moravian set gain");
        cooled
            .set_binning(2, 2)
            .await
            .expect("Moravian set binning");
        cooled
            .set_cooler(true, Some(-15.0))
            .await
            .expect("Moravian set cooler");

        env::set_var("SK_MORAVIAN_BEGIN_ERROR", "1");
        cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.0,
                gain: None,
                offset: None,
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect_err("Moravian begin exposure failure should propagate");
        env::remove_var("SK_MORAVIAN_BEGIN_ERROR");

        cooled
            .start_exposure(ExposureParams {
                duration_secs: 0.0,
                gain: None,
                offset: None,
                bin_x: 2,
                bin_y: 2,
                subframe: None,
                readout_mode: None,
                frame_type: skotiq_device::FrameType::Light,
            })
            .await
            .expect("Moravian start exposure");
        let image = cooled
            .download_image()
            .await
            .expect("Moravian image download");
        assert_eq!((image.width, image.height), (36, 27));
        assert_eq!(image.data[0], 9000);
        cooled
            .disconnect()
            .await
            .expect("Moravian cooled disconnect");

        let mut color =
            moravian::MoravianCamera::from_address(&devices[1].address()).expect("a cXusb address");
        color.connect().await.expect("Moravian color connect");
        assert!(!color.capabilities().can_cool);
        assert!(color.get_sensor_info().color);
        color
            .set_cooler(true, Some(-5.0))
            .await
            .expect_err("uncooled Moravian camera should reject cooler control");
        color.disconnect().await.expect("Moravian color disconnect");

        restore_env_var("SK_MORAVIAN_BEGIN_ERROR", old_begin_error);
        env::set_var("PATH", old_path);
    }

    /// The fake XAPI.dll, built once: the driver keeps the SDK it loaded for
    /// the life of the process, and a loaded DLL cannot be rebuilt in place.
    /// Holding the returned guard keeps the Fujifilm tests, which share the
    /// fake's state, the process's current directory and PATH, apart.
    async fn fujifilm_fake_sdk() -> tokio::sync::MutexGuard<'static, PathBuf> {
        static FAKE: tokio::sync::OnceCell<tokio::sync::Mutex<PathBuf>> =
            tokio::sync::OnceCell::const_new();
        let guard = FAKE
            .get_or_init(|| async {
                let dir = build_single_fake_sdk(
                    "fujifilm",
                    "fujifilm_fake.rs",
                    "XAPI.dll",
                    FUJIFILM_FAKE_SDK,
                );
                env::set_current_dir(&dir).expect("switch to fake SDK dir");
                let path = env::var("PATH").unwrap_or_default();
                env::set_var("PATH", format!("{};{}", dir.display(), path));
                tokio::sync::Mutex::new(dir)
            })
            .await
            .lock()
            .await;
        fujifilm_fake(&guard, FAKE_RESET);
        guard
    }

    const FAKE_RESET: i32 = 0;
    const FAKE_OPEN: i32 = 1;
    const FAKE_LIVE: i32 = 2;
    const FAKE_LIVE_STARTS: i32 = 3;
    const FAKE_LIVE_QUALITY: i32 = 4;
    const FAKE_LIVE_SIZE: i32 = 5;
    const FAKE_DELETES: i32 = 6;
    const FAKE_FOCUS_MODE: i32 = 7;
    const FAKE_FOCUS_TARGET: i32 = 8;
    const FAKE_RELEASES: i32 = 9;

    /// One counter of the fake SDK's state (`SkotiqFake` in the fake source).
    fn fujifilm_fake(dir: &Path, which: i32) -> i32 {
        // SAFETY: the fake XAPI.dll built by `fujifilm_fake_sdk` exports `SkotiqFake(c_long) -> c_long`. Loading it by its full path returns the module the driver already loaded, so the counters are the ones the driver's calls changed.
        unsafe {
            let library =
                libloading::Library::new(dir.join("XAPI.dll")).expect("load fake XAPI.dll");
            let read: libloading::Symbol<unsafe extern "C" fn(i32) -> i32> =
                library.get(b"SkotiqFake\0").expect("SkotiqFake export");
            read(which)
        }
    }

    fn short_exposure() -> ExposureParams {
        ExposureParams {
            duration_secs: 0.01,
            gain: Some(800),
            offset: None,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            readout_mode: None,
            frame_type: skotiq_device::FrameType::Light,
        }
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_fujifilm_fake_sdk_shim_exercises_session_release_and_model_flows() {
        let _fake = fujifilm_fake_sdk().await;
        let old_release_error = env::var("SK_FUJIFILM_RELEASE_ERROR").ok();
        env::remove_var("SK_FUJIFILM_RELEASE_ERROR");

        let devices = fujifilm::discover_devices()
            .await
            .expect("Fujifilm discovery");
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "GFX100 II");
        assert_eq!(devices[1].name, "X-T5");

        let mut gfx = fujifilm::FujifilmCamera::new(&devices[0]);
        gfx.connect().await.expect("Fujifilm connect");
        assert!(gfx.capabilities().can_set_gain);
        assert!(!gfx.capabilities().can_cool);
        assert!(gfx.get_sensor_info().color);
        gfx.set_gain(1600).await.expect("Fujifilm ISO set");
        assert_eq!(gfx.get_gain().await.expect("Fujifilm ISO get"), 1600);
        gfx.set_cooler(true, Some(-5.0))
            .await
            .expect_err("Fujifilm cooler unsupported");

        env::set_var("SK_FUJIFILM_RELEASE_ERROR", "1");
        gfx.start_exposure(ExposureParams {
            duration_secs: 0.01,
            gain: Some(800),
            offset: None,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            readout_mode: None,
            frame_type: skotiq_device::FrameType::Light,
        })
        .await
        .expect_err("Fujifilm release SDK failure should propagate");
        env::remove_var("SK_FUJIFILM_RELEASE_ERROR");

        gfx.start_exposure(ExposureParams {
            duration_secs: 0.01,
            gain: Some(800),
            offset: None,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            readout_mode: None,
            frame_type: skotiq_device::FrameType::Light,
        })
        .await
        .expect("Fujifilm start exposure");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert!(gfx
            .is_exposure_complete()
            .await
            .expect("Fujifilm exposure status"));
        gfx.disconnect().await.expect("Fujifilm disconnect");

        // The device information may leave the serial out; the opened body is
        // then recognized by its product name.
        env::set_var("SK_FUJIFILM_INFO_NO_SERIAL", "1");
        let connected = gfx.connect().await;
        env::remove_var("SK_FUJIFILM_INFO_NO_SERIAL");
        connected.expect("connect when the device information has no serial");
        gfx.disconnect().await.expect("Fujifilm disconnect");

        restore_env_var("SK_FUJIFILM_RELEASE_ERROR", old_release_error);
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_fujifilm_fake_sdk_live_view_runs_while_previews_are_asked_for() {
        let fake = fujifilm_fake_sdk().await;
        let devices = fujifilm::discover_devices()
            .await
            .expect("Fujifilm discovery");
        let mut camera = fujifilm::FujifilmCamera::new(&devices[0]);
        camera.connect().await.expect("Fujifilm connect");
        assert_eq!(
            fujifilm_fake(&fake, FAKE_LIVE),
            0,
            "connect leaves live view off"
        );

        let frame = camera.capture_preview().await.expect("first preview");
        assert_eq!(
            &frame[..2],
            &[0xFF, 0xD8],
            "a preview is the live view JPEG"
        );
        assert_eq!(fujifilm_fake(&fake, FAKE_LIVE), 1);
        assert_eq!(fujifilm_fake(&fake, FAKE_LIVE_QUALITY), 0x0001, "Fine");
        assert_eq!(fujifilm_fake(&fake, FAKE_LIVE_SIZE), 0x0001, "Large");
        // The fake reports three frames waiting: the two older ones are
        // dropped and the newest is read.
        assert_eq!(fujifilm_fake(&fake, FAKE_DELETES), 2);

        let next = camera.capture_preview().await.expect("second preview");
        assert_ne!(frame, next, "each preview is a new frame");
        assert_eq!(
            fujifilm_fake(&fake, FAKE_LIVE_STARTS),
            1,
            "live view started once"
        );

        // The fake refuses to release the shutter while live view runs.
        camera
            .start_exposure(short_exposure())
            .await
            .expect("an exposure stops live view first");
        assert_eq!(fujifilm_fake(&fake, FAKE_LIVE), 0);
        assert_eq!(fujifilm_fake(&fake, FAKE_RELEASES), 1);
        let refused = camera
            .capture_preview()
            .await
            .expect_err("no preview during an exposure");
        assert!(refused.to_string().contains("pauses"), "{refused}");
        camera.abort_exposure().await.expect("abort");

        camera.capture_preview().await.expect("live view resumes");
        assert_eq!(fujifilm_fake(&fake, FAKE_LIVE_STARTS), 2);
        camera.disconnect().await.expect("Fujifilm disconnect");
        assert_eq!(
            fujifilm_fake(&fake, FAKE_LIVE),
            0,
            "disconnect stops live view"
        );
        assert_eq!(
            fujifilm_fake(&fake, FAKE_OPEN),
            0,
            "disconnect closes the body"
        );
    }

    #[tokio::test]
    #[ignore = "software-only fake SDK contract; run explicitly from compatibility matrix"]
    async fn test_fujifilm_fake_sdk_lens_focuser_shares_the_camera_session() {
        let fake = fujifilm_fake_sdk().await;
        let devices = fujifilm::discover_devices()
            .await
            .expect("Fujifilm discovery");
        let mut camera = fujifilm::FujifilmCamera::new(&devices[0]);
        camera.connect().await.expect("Fujifilm connect");

        // The fake refuses a second open of an open body, as the SDK does.
        let mut lens = fujifilm::FujifilmLens::new("FUJI-GFX-0001", "GFX100 II lens");
        lens.connect()
            .await
            .expect("lens connect joins the camera's session");
        assert_eq!(fujifilm_fake(&fake, FAKE_OPEN), 1);
        assert_eq!(
            fujifilm_fake(&fake, FAKE_FOCUS_MODE),
            0x0001,
            "held in manual focus"
        );
        // The fake lens: infinity 100, close 900, 40 and 20 pulses of
        // over-search, smallest move 3.
        assert_eq!(lens.get_max_position().await, 860);
        assert_eq!(lens.get_position().await.expect("position"), 100);

        lens.move_to(400).await.expect("move");
        assert_eq!(fujifilm_fake(&fake, FAKE_FOCUS_TARGET), 460);
        let started = std::time::Instant::now();
        while lens.is_moving().await.expect("is_moving") {
            assert!(
                started.elapsed() < std::time::Duration::from_secs(5),
                "the move ends"
            );
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        // The fake lens rests 30 pulses short; the focuser reports its target.
        assert_eq!(lens.get_position().await.expect("position"), 400);
        lens.move_relative(-50).await.expect("relative move");
        assert_eq!(fujifilm_fake(&fake, FAKE_FOCUS_TARGET), 410);
        while lens.is_moving().await.expect("is_moving") {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        match lens.move_to(861).await {
            Err(skotiq_device::DriverError::InvalidParameter(text)) => {
                assert!(text.contains("0 to 860"), "{text}")
            }
            other => panic!("a position past the travel is refused, got {other:?}"),
        }

        camera.disconnect().await.expect("camera disconnect");
        assert_eq!(
            fujifilm_fake(&fake, FAKE_OPEN),
            1,
            "the lens still holds the body"
        );
        lens.get_position().await.expect("the lens keeps working");
        lens.disconnect().await.expect("lens disconnect");
        assert_eq!(
            fujifilm_fake(&fake, FAKE_OPEN),
            0,
            "the last one closes the body"
        );
        assert_eq!(
            fujifilm_fake(&fake, FAKE_FOCUS_MODE),
            0x8001,
            "AF-S restored"
        );

        env::set_var("SK_FUJIFILM_NO_LENS", "1");
        let mut adapter = fujifilm::FujifilmLens::new("FUJI-GFX-0001", "GFX100 II lens");
        let refused = adapter.connect().await.expect_err("no electronic lens");
        env::remove_var("SK_FUJIFILM_NO_LENS");
        assert!(
            refused.to_string().contains("no electronic focus"),
            "{refused}"
        );
        assert_eq!(
            fujifilm_fake(&fake, FAKE_OPEN),
            0,
            "a refused lens leaves the body closed"
        );

        // A focus switch on S or C keeps the body in autofocus.
        env::set_var("SK_FUJIFILM_FOCUS_SWITCH_AF", "1");
        let mut lens = fujifilm::FujifilmLens::new("FUJI-GFX-0001", "GFX100 II lens");
        let refused = lens.connect().await.expect_err("no focus range in AF-S");
        env::remove_var("SK_FUJIFILM_FOCUS_SWITCH_AF");
        assert!(
            refused.to_string().contains("focus mode switch to M"),
            "{refused}"
        );
    }

    fn build_fake_sdks() -> PathBuf {
        let root = env::temp_dir().join(format!("skotiq-zwo-fake-sdk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create fake SDK dir");
        compile_cdylib(&root, "asi_fake.rs", "ASICamera2.dll", ASI_FAKE_SDK);
        compile_cdylib(&root, "eaf_fake.rs", "EAF_focuser.dll", EAF_FAKE_SDK);
        compile_cdylib(&root, "efw_fake.rs", "EFW_filter.dll", EFW_FAKE_SDK);
        root
    }

    fn build_single_fake_sdk(
        vendor: &str,
        source_name: &str,
        output_name: &str,
        source: &str,
    ) -> PathBuf {
        let root =
            env::temp_dir().join(format!("skotiq-{}-fake-sdk-{}", vendor, std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("create fake SDK dir");
        compile_cdylib(&root, source_name, output_name, source);
        root
    }

    fn restore_env_var(name: &str, value: Option<String>) {
        if let Some(value) = value {
            env::set_var(name, value);
        } else {
            env::remove_var(name);
        }
    }

    fn compile_cdylib(root: &Path, source_name: &str, output_name: &str, source: &str) {
        let source_path = root.join(source_name);
        let output_path = root.join(output_name);
        fs::write(&source_path, source).expect("write fake SDK source");
        let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
        let output = Command::new(rustc)
            .arg("--crate-type")
            .arg("cdylib")
            .arg("--edition")
            .arg("2021")
            .arg(&source_path)
            .arg("-o")
            .arg(&output_path)
            .output()
            .expect("run rustc for fake SDK");
        assert!(
            output.status.success(),
            "fake SDK build failed for {}:\nstdout:\n{}\nstderr:\n{}",
            output_name,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    const ASI_FAKE_SDK: &str = include_str!("fake_sdk/asi.rs");

    const EAF_FAKE_SDK: &str = include_str!("fake_sdk/eaf.rs");

    const EFW_FAKE_SDK: &str = include_str!("fake_sdk/efw.rs");

    // Models the PlayerOneCamera.h / PlayerOnePW.h contracts the drivers rely on:
    // camera ids exist once POAGetCameraCount has scanned; POAStartExposure(id,
    // POA_FALSE) is video mode, which keeps the camera exposing after a frame and
    // refuses another start with POA_ERROR_EXPOSING; POASetImageBin resets the ROI
    // to the binned full frame; ROI width is a multiple of 4 and height of 2;
    // POA_EXPOSURE takes 10..2e9 us and POA_EXP 0.00001..7200 s. The wheel homes
    // for a moment after POAOpenPW and answers POAGetCurrentPosition with
    // PW_ERROR_IS_MOVING while it turns.
    const PLAYER_ONE_FAKE_SDK: &str = include_str!("fake_sdk/player_one.rs");

    const PLAYER_ONE_PW_FAKE_SDK: &str = include_str!("fake_sdk/player_one_pw.rs");

    const QHY_FAKE_SDK: &str = include_str!("fake_sdk/qhy.rs");

    const ATIK_FAKE_SDK: &str = include_str!("fake_sdk/atik.rs");

    const SVBONY_FAKE_SDK: &str = include_str!("fake_sdk/svbony.rs");

    const TOUPTEK_FAKE_SDK: &str = include_str!("fake_sdk/touptek.rs");

    const FLI_FAKE_SDK: &str = include_str!("fake_sdk/fli.rs");

    /// The same two cameras through the Windows driver API (cxusb.h): one-byte
    /// TRUE on success, string lengths passed as the highest index.
    const MORAVIAN_CXUSB_FAKE_SDK: &str = include_str!("fake_sdk/moravian_cxusb.rs");

    const FUJIFILM_FAKE_SDK: &str = include_str!("fake_sdk/fujifilm.rs");
}

/// Test mount tracking control (requires hardware)
#[tokio::test]
#[ignore = "Requires Sky-Watcher mount connected"]
async fn test_skywatcher_mount_tracking() {
    let mounts = skywatcher::discover_mounts()
        .await
        .expect("Discovery should work");
    if mounts.is_empty() {
        panic!("No Sky-Watcher mounts found");
    }

    let first_mount = &mounts[0];
    let mut mount = skywatcher::SkyWatcherMount::new_serial(
        first_mount.port.clone(),
        Some(first_mount.baud_rate),
        skywatcher_test_site(),
    );

    mount.connect().await.expect("Should connect successfully");

    let tracking = mount.get_tracking().await.expect("Should get tracking");
    println!("Initial tracking state: {}", tracking);

    mount
        .set_tracking(false)
        .await
        .expect("Should stop tracking");
    tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
    let tracking = mount.get_tracking().await.expect("Should get tracking");
    println!("After stop: tracking={}", tracking);

    // Toggle tracking on (sidereal)
    mount
        .set_tracking(true)
        .await
        .expect("Should start tracking");
    tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
    let tracking = mount.get_tracking().await.expect("Should get tracking");
    println!("After start: tracking={}", tracking);

    mount
        .disconnect()
        .await
        .expect("Should disconnect successfully");
}
