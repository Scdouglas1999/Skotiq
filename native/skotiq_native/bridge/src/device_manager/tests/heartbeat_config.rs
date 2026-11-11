use super::*;
use crate::device_manager::policy::policy;

#[test]
fn test_heartbeat_config_for_camera() {
    let config = policy(DeviceType::Camera).heartbeat;
    assert_eq!(config.base_interval_secs, 10);
    // Failed probes must not delay the next check by 20 then 40 seconds.
    assert_eq!(config.backoff_multiplier, 1.0);
    assert_eq!(config.failure_threshold, 3);
    assert!(!config.auto_reconnect);
}

#[test]
fn test_heartbeat_config_for_mount() {
    let config = policy(DeviceType::Mount).heartbeat;
    // Mounts should have more frequent monitoring
    assert_eq!(config.base_interval_secs, 5);
    // Three misses (each double-probed) before teardown — one transient
    // STA-queue timeout must not drop a tracking mount.
    assert_eq!(config.failure_threshold, 3);
    // Mounts should auto-reconnect to maintain tracking
    assert!(config.auto_reconnect);
}

#[test]
fn test_heartbeat_config_for_safety_monitor() {
    let config = policy(DeviceType::SafetyMonitor).heartbeat;
    // A safety monitor's heartbeat is only a LIVENESS ping — the real IsSafe
    // signal is read on separate paths — so it is treated like the auxiliary
    // devices: tolerate transient misses and NEVER escalate to a disconnect,
    // which on a flaky network hub would flood the UI with disconnect toasts.
    // See the SafetyMonitor policy.
    assert_eq!(config.base_interval_secs, 15);
    assert_eq!(config.failure_threshold, 4);
    assert!(!config.auto_reconnect);
    assert!(!config.escalate_to_disconnect);
}

#[test]
fn test_heartbeat_config_for_accessory_device_types() {
    let guider = policy(DeviceType::Guider).heartbeat;
    assert_eq!(guider.base_interval_secs, 5);
    assert!(guider.auto_reconnect);

    let switch = policy(DeviceType::Switch).heartbeat;
    assert_eq!(switch.base_interval_secs, 20);
    // Raised to 5 to tolerate transient single-client USB contention.
    assert_eq!(switch.failure_threshold, 5);
    assert!(!switch.auto_reconnect);

    let cover = policy(DeviceType::CoverCalibrator).heartbeat;
    assert_eq!(cover.base_interval_secs, 10);
    assert!(cover.auto_reconnect);
}

#[test]
fn test_heartbeat_config_non_critical_failure_thresholds_raised() {
    // Why: non-critical accessories tolerate transient single-client USB
    // contention (e.g. NINA briefly holding the device). Five double-probed
    // misses provide debounce; fixed polling cadence still disconnects a
    // genuinely unresponsive accessory promptly enough for recovery.
    let focuser = policy(DeviceType::Focuser).heartbeat;
    assert_eq!(focuser.failure_threshold, 5);
    assert_eq!(focuser.base_interval_secs, 15);
    assert_eq!(focuser.backoff_multiplier, 1.0);
    assert!(focuser.escalate_to_disconnect);

    let filter_wheel = policy(DeviceType::FilterWheel).heartbeat;
    assert_eq!(filter_wheel.failure_threshold, 5);
    assert_eq!(filter_wheel.base_interval_secs, 20);
    assert_eq!(filter_wheel.backoff_multiplier, 1.0);
    assert!(filter_wheel.escalate_to_disconnect);

    let rotator = policy(DeviceType::Rotator).heartbeat;
    assert_eq!(rotator.failure_threshold, 5);
    assert_eq!(rotator.base_interval_secs, 15);
    assert_eq!(rotator.backoff_multiplier, 1.0);
    assert!(rotator.escalate_to_disconnect);

    let switch = policy(DeviceType::Switch).heartbeat;
    assert_eq!(switch.failure_threshold, 5);
    assert_eq!(switch.base_interval_secs, 20);

    // Safety monitors are non-escalating liveness (see the SafetyMonitor policy):
    // four missed pings tolerated, and never a teardown.
    assert_eq!(
        policy(DeviceType::SafetyMonitor)
            .heartbeat
            .failure_threshold,
        4
    );

    // Critical/auto-reconnecting device types. The mount threshold is 3: its
    // ASCOM probe is a COM round-trip on the shared STA worker, so one
    // transient timeout pair must not disconnect a tracking mount.
    assert_eq!(policy(DeviceType::Camera).heartbeat.failure_threshold, 3);
    assert_eq!(policy(DeviceType::Mount).heartbeat.failure_threshold, 3);
    assert_eq!(policy(DeviceType::Guider).heartbeat.failure_threshold, 2);
    assert_eq!(policy(DeviceType::Dome).heartbeat.failure_threshold, 4);
    assert_eq!(policy(DeviceType::Weather).heartbeat.failure_threshold, 5);
    assert_eq!(
        policy(DeviceType::CoverCalibrator)
            .heartbeat
            .failure_threshold,
        3
    );
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
        let config = policy(device_type).heartbeat;
        // All configs should have reasonable values
        assert!(config.base_interval_secs > 0);
        assert!(config.base_interval_secs <= config.max_interval_secs);
        assert!(config.failure_threshold > 0);
        assert!(config.backoff_multiplier >= 1.0);
    }
}

#[test]
fn heartbeat_retry_and_backstop_cover_the_slow_auxiliaries() {
    for device_type in [
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
    ] {
        let p = policy(device_type);
        assert_eq!(
            p.retry_heartbeat,
            matches!(
                device_type,
                DeviceType::Mount | DeviceType::Focuser | DeviceType::FilterWheel
            ),
            "{device_type:?} heartbeat retry"
        );
        assert_eq!(
            p.backstop_polled,
            matches!(
                device_type,
                DeviceType::Focuser | DeviceType::FilterWheel | DeviceType::Rotator
            ),
            "{device_type:?} backstop poll"
        );
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

/// A focuser whose heartbeat held off every poll during a run's exposures
/// (shared-USB download windows) read "Unhealthy" on System health while it
/// moved fine (reverify RV-05). A deferred poll after a healthy one is not a
/// failure.
#[tokio::test]
async fn a_deferred_heartbeat_poll_keeps_a_healthy_device_healthy() {
    let manager = build_device_manager();
    let id = "sim_focuser_deferred_health";
    super::mount_home::register_mount(&manager, id, DriverType::Simulator).await;
    let a_minute_ago = chrono::Utc::now().timestamp_millis() - 60_000;
    manager
        .devices
        .write()
        .await
        .get_mut(id)
        .unwrap()
        .last_successful_comm = Some(a_minute_ago);
    assert_eq!(
        manager.get_device_health(id).await.unwrap(),
        (a_minute_ago, false)
    );

    manager.note_heartbeat_deferred(id).await;
    assert_eq!(
        manager.get_device_health(id).await.unwrap(),
        (a_minute_ago, true)
    );
}
