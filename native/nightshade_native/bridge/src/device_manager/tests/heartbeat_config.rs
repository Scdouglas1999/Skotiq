use super::*;

#[test]
fn test_heartbeat_config_default() {
    let config = HeartbeatConfig::default();
    assert_eq!(config.base_interval_secs, 10);
    assert_eq!(config.max_interval_secs, 60);
    assert_eq!(config.failure_threshold, 3);
    // 1.0 = FIXED cadence. The default deliberately does not back off;
    // exponential backoff is opted into by the device-specific constructors
    // (see HeartbeatConfig::default and the per-device `for_*` builders),
    // so a default multiplier of 2.0 here would silently stretch every
    // device's poll interval that had not chosen a policy.
    assert!((config.backoff_multiplier - 1.0).abs() < f64::EPSILON);
    assert!(!config.auto_reconnect);
    assert_eq!(config.max_reconnect_attempts, 3);
    assert_eq!(config.reconnect_delay_secs, 5);
}

#[test]
fn test_heartbeat_config_for_camera() {
    let config = HeartbeatConfig::for_camera();
    assert_eq!(config.base_interval_secs, 10);
    // Failed probes must not delay the next check by 20 then 40 seconds.
    assert_eq!(config.backoff_multiplier, 1.0);
    assert_eq!(config.failure_threshold, 3);
    assert!(!config.auto_reconnect);
}

#[test]
fn test_heartbeat_config_for_mount() {
    let config = HeartbeatConfig::for_mount();
    // Mounts should have more frequent monitoring
    assert_eq!(config.base_interval_secs, 5);
    // Three misses (each double-probed) before teardown — one transient
    // STA-queue timeout must not drop a tracking mount.
    assert_eq!(config.failure_threshold, 3);
    // Mounts should auto-reconnect to maintain tracking
    assert!(config.auto_reconnect);
    assert_eq!(config.max_reconnect_attempts, 5);
}

#[test]
fn test_heartbeat_config_for_safety_monitor() {
    let config = HeartbeatConfig::for_safety_monitor();
    // A safety monitor's heartbeat is only a LIVENESS ping — the real IsSafe
    // signal is read on separate paths — so it is treated like the auxiliary
    // devices: tolerate transient misses and NEVER escalate to a disconnect,
    // which on a flaky network hub would flood the UI with disconnect toasts.
    // See for_safety_monitor().
    assert_eq!(config.base_interval_secs, 15);
    assert_eq!(config.failure_threshold, 4);
    assert!(!config.auto_reconnect);
    assert!(!config.escalate_to_disconnect);
}

#[test]
fn test_heartbeat_config_for_accessory_device_types() {
    let guider = HeartbeatConfig::for_device_type(&DeviceType::Guider);
    assert_eq!(guider.base_interval_secs, 5);
    assert!(guider.auto_reconnect);

    let switch = HeartbeatConfig::for_device_type(&DeviceType::Switch);
    assert_eq!(switch.base_interval_secs, 20);
    // Raised to 5 to tolerate transient single-client USB contention.
    assert_eq!(switch.failure_threshold, 5);
    assert!(!switch.auto_reconnect);

    let cover = HeartbeatConfig::for_device_type(&DeviceType::CoverCalibrator);
    assert_eq!(cover.base_interval_secs, 10);
    assert!(cover.auto_reconnect);
}

#[test]
fn test_heartbeat_config_non_critical_failure_thresholds_raised() {
    // Why: non-critical accessories tolerate transient single-client USB
    // contention (e.g. NINA briefly holding the device). Five double-probed
    // misses provide debounce; fixed polling cadence still disconnects a
    // genuinely unresponsive accessory promptly enough for recovery.
    let focuser = HeartbeatConfig::for_focuser();
    assert_eq!(focuser.failure_threshold, 5);
    assert_eq!(focuser.base_interval_secs, 15);
    assert_eq!(focuser.backoff_multiplier, 1.0);
    assert!(focuser.escalate_to_disconnect);

    let filter_wheel = HeartbeatConfig::for_filter_wheel();
    assert_eq!(filter_wheel.failure_threshold, 5);
    assert_eq!(filter_wheel.base_interval_secs, 20);
    assert_eq!(filter_wheel.backoff_multiplier, 1.0);
    assert!(filter_wheel.escalate_to_disconnect);

    let rotator = HeartbeatConfig::for_rotator();
    assert_eq!(rotator.failure_threshold, 5);
    assert_eq!(rotator.base_interval_secs, 15);
    assert_eq!(rotator.backoff_multiplier, 1.0);
    assert!(rotator.escalate_to_disconnect);

    let switch = HeartbeatConfig::for_switch();
    assert_eq!(switch.failure_threshold, 5);
    assert_eq!(switch.base_interval_secs, 20);

    // Safety monitors are non-escalating liveness (see for_safety_monitor):
    // four missed pings tolerated, and never a teardown.
    assert_eq!(HeartbeatConfig::for_safety_monitor().failure_threshold, 4);

    // Critical/auto-reconnecting device types. The mount threshold is 3: its
    // ASCOM probe is a COM round-trip on the shared STA worker, so one
    // transient timeout pair must not disconnect a tracking mount.
    assert_eq!(HeartbeatConfig::for_camera().failure_threshold, 3);
    assert_eq!(HeartbeatConfig::for_mount().failure_threshold, 3);
    assert_eq!(HeartbeatConfig::for_guider().failure_threshold, 2);
    assert_eq!(HeartbeatConfig::for_dome().failure_threshold, 4);
    assert_eq!(HeartbeatConfig::for_weather().failure_threshold, 5);
    assert_eq!(HeartbeatConfig::for_cover_calibrator().failure_threshold, 3);
}

#[test]
fn test_heartbeat_config_for_device_type() {
    // Test that for_device_type delegates to correct methods
    let camera_config = HeartbeatConfig::for_device_type(&DeviceType::Camera);
    assert_eq!(
        camera_config.base_interval_secs,
        HeartbeatConfig::for_camera().base_interval_secs
    );

    let mount_config = HeartbeatConfig::for_device_type(&DeviceType::Mount);
    assert!(mount_config.auto_reconnect);

    let safety_config = HeartbeatConfig::for_device_type(&DeviceType::SafetyMonitor);
    assert!(!safety_config.escalate_to_disconnect);
    assert_eq!(safety_config.max_reconnect_attempts, 2);
}

#[test]
fn test_heartbeat_config_with_interval() {
    let config = HeartbeatConfig::with_interval(30);
    assert_eq!(config.base_interval_secs, 30);
    // Other fields should be default
    assert_eq!(config.failure_threshold, 3);
}

#[test]
fn test_heartbeat_config_builder_pattern() {
    let config = HeartbeatConfig::with_interval(20)
        .with_auto_reconnect(true)
        .with_failure_threshold(5)
        .with_max_reconnect_attempts(10);

    assert_eq!(config.base_interval_secs, 20);
    assert!(config.auto_reconnect);
    assert_eq!(config.failure_threshold, 5);
    assert_eq!(config.max_reconnect_attempts, 10);
}

#[test]
fn test_heartbeat_config_device_type_variations() {
    // All device types should return valid configurations
    let device_types = vec![
        DeviceType::Camera,
        DeviceType::Mount,
        DeviceType::Focuser,
        DeviceType::FilterWheel,
        DeviceType::Dome,
        DeviceType::Rotator,
        DeviceType::Weather,
        DeviceType::SafetyMonitor,
        DeviceType::Guider,
        DeviceType::Switch,
        DeviceType::CoverCalibrator,
    ];

    for device_type in device_types {
        let config = HeartbeatConfig::for_device_type(&device_type);
        // All configs should have reasonable values
        assert!(config.base_interval_secs > 0);
        assert!(config.base_interval_secs <= config.max_interval_secs);
        assert!(config.failure_threshold > 0);
        assert!(config.backoff_multiplier >= 1.0);
        assert!(config.reconnect_delay_secs > 0);
    }
}

#[test]
fn test_reconnect_config_default() {
    let config = ReconnectConfig::default();
    assert!(config.enabled);
    assert_eq!(config.max_attempts, 10);
    assert_eq!(config.initial_delay_secs, 2);
    assert_eq!(config.max_delay_secs, 60);
    assert!((config.backoff_multiplier - 1.5).abs() < f64::EPSILON);
}
