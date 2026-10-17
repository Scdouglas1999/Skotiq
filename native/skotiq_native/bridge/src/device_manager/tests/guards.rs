use super::*;

#[tokio::test]
async fn test_mount_can_park_requires_registered_device() {
    let manager = build_device_manager();
    let err = manager
        .mount_can_park("missing-mount")
        .await
        .expect_err("missing mount should error");
    assert!(err.to_string().contains("Device not found"));
}

#[test]
fn operation_guard_marks_and_clears_active_operations() {
    let manager = build_device_manager();

    // No operation in flight initially.
    assert!(!manager.is_operation_active("ascom:focuser"));

    {
        let _op = manager.begin_operation("ascom:focuser");
        // The guarded device is marked active...
        assert!(manager.is_operation_active("ascom:focuser"));
        // ...but an unrelated device is not, so a focuser move never
        // suppresses (for example) the mount's heartbeat.
        assert!(!manager.is_operation_active("ascom:mount"));
    }

    // Dropping the guard clears the marker so the heartbeat resumes.
    assert!(!manager.is_operation_active("ascom:focuser"));
}

#[test]
fn operation_guards_are_independent_per_device() {
    let manager = build_device_manager();
    let op_a = manager.begin_operation("focuser:a");
    {
        let _op_b = manager.begin_operation("focuser:b");
        assert!(manager.is_operation_active("focuser:a"));
        assert!(manager.is_operation_active("focuser:b"));
    }
    // Dropping b leaves a's marker intact.
    assert!(manager.is_operation_active("focuser:a"));
    assert!(!manager.is_operation_active("focuser:b"));
    drop(op_a);
    assert!(!manager.is_operation_active("focuser:a"));
}

#[test]
fn usb_contention_guard_marks_and_clears_contention() {
    let manager = build_device_manager();

    // No exposure in flight initially.
    assert!(!manager.is_usb_contended());

    {
        let _contention = manager.begin_usb_contention();
        assert!(
            manager.is_usb_contended(),
            "a live exposure window must mark the rig USB-contended"
        );
    }

    // Dropping the guard clears contention so aux heartbeats resume.
    assert!(!manager.is_usb_contended());
}

#[test]
fn usb_contention_nests_for_overlapping_exposures() {
    let manager = build_device_manager();

    let outer = manager.begin_usb_contention();
    {
        let _inner = manager.begin_usb_contention();
        assert!(manager.is_usb_contended());
    }
    // Inner exposure finished but the outer one is still running: the rig
    // remains contended until the LAST window closes. This is the dual-
    // camera / overlapping-frame case.
    assert!(
        manager.is_usb_contended(),
        "contention must persist while any exposure window is still open"
    );
    drop(outer);
    assert!(
        !manager.is_usb_contended(),
        "contention clears only after the last exposure window closes"
    );
}

#[test]
fn usb_contention_suppresses_only_aux_device_types() {
    // The focuser/filter-wheel/rotator share the camera's USB path and are
    // suppressed during a download window. The camera (which is driving the
    // contention) and the mount (own link, tracking-critical) are not.
    assert!(DeviceManager::device_type_suppressed_by_usb_contention(
        &DeviceType::Focuser
    ));
    assert!(DeviceManager::device_type_suppressed_by_usb_contention(
        &DeviceType::FilterWheel
    ));
    assert!(DeviceManager::device_type_suppressed_by_usb_contention(
        &DeviceType::Rotator
    ));

    for not_suppressed in [
        DeviceType::Camera,
        DeviceType::Mount,
        DeviceType::Dome,
        DeviceType::Weather,
        DeviceType::SafetyMonitor,
        DeviceType::Guider,
        DeviceType::Switch,
        DeviceType::CoverCalibrator,
    ] {
        assert!(
            !DeviceManager::device_type_suppressed_by_usb_contention(&not_suppressed),
            "{:?} must NOT be suppressed by USB contention",
            not_suppressed
        );
    }
}

#[test]
fn escalate_to_disconnect_is_a_per_device_type_property() {
    // Every operational device escalates a sustained heartbeat loss so
    // stale registry state cannot remain advertised as connected.
    for escalating in [
        DeviceType::Camera,
        DeviceType::Mount,
        DeviceType::Focuser,
        DeviceType::FilterWheel,
        DeviceType::Rotator,
        DeviceType::Dome,
        DeviceType::Weather,
        DeviceType::Guider,
        DeviceType::Switch,
        DeviceType::CoverCalibrator,
    ] {
        assert!(
            HeartbeatConfig::for_device_type(&escalating).escalate_to_disconnect,
            "{:?} must escalate a heartbeat loss to disconnect",
            escalating
        );
    }

    // SafetyMonitor heartbeat is only a liveness hint; the independent
    // IsSafe signal owns enclosure safety decisions.
    assert!(!HeartbeatConfig::for_safety_monitor().escalate_to_disconnect);
}

#[tokio::test]
async fn test_mount_stop_requires_registered_device() {
    let manager = build_device_manager();
    let err = manager
        .mount_stop("missing-mount")
        .await
        .expect_err("missing mount should error");
    assert!(err.to_string().contains("Device not found"));
}
