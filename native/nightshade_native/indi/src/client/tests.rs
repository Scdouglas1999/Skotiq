use super::*;
use crate::IndiPropertyState;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn test_timeout_config_default() {
    let config = IndiTimeoutConfig::default();
    assert_eq!(config.connection_timeout_secs, 30);
    assert_eq!(config.message_timeout_secs, 60);
    assert_eq!(config.blob_timeout_secs, 300);
    assert_eq!(config.property_timeout_secs, 30);
    assert_eq!(config.mount_slew_timeout_secs, 300);
    assert_eq!(config.focuser_move_timeout_secs, 120);
    assert_eq!(config.filter_change_timeout_secs, 60);
    assert_eq!(config.dome_slew_timeout_secs, 300);
    assert_eq!(config.rotator_move_timeout_secs, 120);
    assert_eq!(config.camera_exposure_buffer_secs, 60);
    assert_eq!(config.property_poll_interval_ms, 500);
    assert_eq!(config.keepalive_interval_secs, 30);
    assert_eq!(config.reconnect_base_delay_secs, 1);
    assert_eq!(config.reconnect_max_delay_secs, 30);
    assert_eq!(config.reconnect_max_attempts, 5);
}

#[tokio::test]
async fn test_client_creation_with_timeout_config() {
    let custom_config = IndiTimeoutConfig {
        connection_timeout_secs: 60,
        message_timeout_secs: 120,
        blob_timeout_secs: 600,
        property_timeout_secs: 60,
        mount_slew_timeout_secs: 600,
        focuser_move_timeout_secs: 240,
        filter_change_timeout_secs: 120,
        dome_slew_timeout_secs: 600,
        rotator_move_timeout_secs: 240,
        camera_exposure_buffer_secs: 120,
        property_poll_interval_ms: 1000,
        keepalive_interval_secs: 60,
        reconnect_base_delay_secs: 2,
        reconnect_max_delay_secs: 60,
        reconnect_max_attempts: 10,
    };

    let client = IndiClient::with_timeout_config("localhost", Some(7624), custom_config.clone());
    assert_eq!(client.timeout_config().mount_slew_timeout_secs, 600);
    assert_eq!(client.timeout_config().message_timeout_secs, 120);
    assert_eq!(client.timeout_config().reconnect_max_attempts, 10);
}

#[tokio::test]
async fn test_timeout_error_display() {
    let error = IndiTimeoutError {
        device: "TestMount".to_string(),
        property: "EQUATORIAL_EOD_COORD".to_string(),
        context: "Slew operation exceeded timeout".to_string(),
        last_state: Some(IndiPropertyState::Busy),
    };

    let error_msg = format!("{}", error);
    assert!(error_msg.contains("TestMount"));
    assert!(error_msg.contains("EQUATORIAL_EOD_COORD"));
    assert!(error_msg.contains("Slew operation exceeded timeout"));
}

#[tokio::test]
async fn test_wait_for_property_state_timeout() {
    let client = IndiClient::new("localhost", Some(7624));

    // This should timeout immediately since we're not connected
    let result = client
        .wait_for_property_state(
            "TestDevice",
            "TestProperty",
            IndiPropertyState::Ok,
            Duration::from_millis(100),
        )
        .await;

    assert!(result.is_err());
    if let Err(e) = result {
        assert_eq!(e.device, "TestDevice");
        assert_eq!(e.property, "TestProperty");
    }
}

#[tokio::test]
async fn test_exponential_backoff_with_jitter() {
    let config = ReconnectionConfig {
        base_delay_secs: 1,
        max_delay_secs: 30,
        max_attempts: 5,
        use_jitter: false, // Disable jitter for predictable testing
        jitter_factor: 0.0,
    };
    let rng = make_jitter_rng("test", 7624);

    // Test exponential growth without jitter
    let delay1 = config.calculate_delay(1, &rng);
    assert_eq!(delay1, Duration::from_secs(1));

    let delay2 = config.calculate_delay(2, &rng);
    assert_eq!(delay2, Duration::from_secs(2));

    let delay3 = config.calculate_delay(3, &rng);
    assert_eq!(delay3, Duration::from_secs(4));

    let delay4 = config.calculate_delay(4, &rng);
    assert_eq!(delay4, Duration::from_secs(8));

    let delay5 = config.calculate_delay(5, &rng);
    assert_eq!(delay5, Duration::from_secs(16));

    // Test capping at max
    let delay6 = config.calculate_delay(6, &rng);
    assert_eq!(delay6, Duration::from_secs(30)); // Capped at max
}

#[tokio::test]
async fn test_jitter_produces_variation() {
    let config = ReconnectionConfig {
        base_delay_secs: 10,
        max_delay_secs: 100,
        max_attempts: 5,
        use_jitter: true,
        jitter_factor: 0.3,
    };
    let rng = make_jitter_rng("test", 7624);

    // With jitter, delays should vary somewhat
    let delay1 = config.calculate_delay(1, &rng);
    let delay2 = config.calculate_delay(1, &rng);

    // Both should be close to 10 seconds (within 30% jitter)
    assert!(delay1.as_secs_f64() >= 8.5 && delay1.as_secs_f64() <= 11.5);
    assert!(delay2.as_secs_f64() >= 8.5 && delay2.as_secs_f64() <= 11.5);
}

/// Two clients constructed back-to-back must produce uncorrelated jitter
/// streams. A process-global PRNG seeded from system time on first use gives
/// two clients created in the same nanosecond identical reconnect schedules,
/// which thunder-herds the INDI server; per-instance seeding prevents that.
#[tokio::test]
async fn test_per_instance_jitter_uncorrelated_across_clients() {
    let client_a = IndiClient::new("localhost", Some(7624));
    let client_b = IndiClient::new("localhost", Some(7624));

    // Draw 8 jitter samples from each client and require at least one
    // disagreement. We pull the unit samples directly from the per-
    // instance PRNG so the assertion does not depend on backoff scaling
    // or rounding; the property under test is "the underlying RNG
    // streams differ", which is what fixes the thundering-herd bug.
    let mut samples_a = [0.0_f64; 8];
    let mut samples_b = [0.0_f64; 8];
    for i in 0..8 {
        samples_a[i] = jitter_sample(&client_a.jitter_rng);
        samples_b[i] = jitter_sample(&client_b.jitter_rng);
    }

    assert_ne!(
        samples_a, samples_b,
        "Two IndiClients constructed back-to-back produced identical \
         jitter sequences ({:?} == {:?}); per-instance seeding regressed.",
        samples_a, samples_b
    );

    // Sanity: samples must be in [0, 1) per fastrand::Rng::f64 contract.
    for s in samples_a.iter().chain(samples_b.iter()) {
        assert!((0.0..1.0).contains(s), "jitter sample {} outside [0, 1)", s);
    }
}

#[tokio::test]
async fn test_reconnect_attempts_tracking() {
    let client = IndiClient::new("localhost", Some(7624));
    assert_eq!(client.reconnect_attempts().await, 0);
}

#[tokio::test]
async fn test_send_command_error_messages() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Try to send without connecting
    let result = client.send_command("<getProperties/>").await;
    assert!(result.is_err());
    if let Err(e) = result {
        assert!(matches!(e, IndiError::NotConnected));
    }
}

async fn capture_switch_command(rule: &str, element: &str, state: bool) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake INDI server");
    let port = listener.local_addr().expect("read listener address").port();
    let rule = rule.to_string();

    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept INDI client");
        let mut buf = vec![0_u8; 4096];
        let _ = socket
            .read(&mut buf)
            .await
            .expect("read initial getProperties");

        let definition = format!(
            r#"
<defSwitchVector device="SwitchBox" name="POWER" state="Ok" perm="rw" rule="{rule}">
  <defSwitch name="PORT_A">Off</defSwitch>
  <defSwitch name="PORT_B">Off</defSwitch>
  <defSwitch name="PORT_C">Off</defSwitch>
</defSwitchVector>
"#
        );
        socket
            .write_all(definition.as_bytes())
            .await
            .expect("write switch definition");

        loop {
            buf.fill(0);
            let n = socket.read(&mut buf).await.expect("read switch command");
            assert!(n > 0, "client disconnected before sending switch command");
            let command = String::from_utf8_lossy(&buf[..n]).to_string();
            if command.contains("<newSwitchVector") && command.contains("name=\"POWER\"") {
                return command;
            }
        }
    });

    let timeout_config = IndiTimeoutConfig {
        connection_timeout_secs: 1,
        ..Default::default()
    };
    let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
    client.connect().await.expect("connect fake INDI client");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while client.get_property("SwitchBox", "POWER").await.is_none() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "fake INDI switch property was not parsed in time"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    client
        .set_switch("SwitchBox", "POWER", element, state)
        .await
        .expect("send switch command");

    tokio::time::timeout(Duration::from_secs(2), server)
        .await
        .expect("fake INDI server should receive switch command")
        .expect("fake INDI server task should finish")
}

#[tokio::test]
async fn test_one_of_many_switch_command_forces_siblings_off() {
    let command = capture_switch_command("OneOfMany", "PORT_B", true).await;

    assert!(
        command.contains("<oneSwitch name=\"PORT_A\">Off</oneSwitch>"),
        "exclusive command must force PORT_A off: {}",
        command
    );
    assert!(
        command.contains("<oneSwitch name=\"PORT_B\">On</oneSwitch>"),
        "exclusive command must turn requested port on: {}",
        command
    );
    assert!(
        command.contains("<oneSwitch name=\"PORT_C\">Off</oneSwitch>"),
        "exclusive command must force PORT_C off: {}",
        command
    );
}

#[tokio::test]
async fn test_any_of_many_switch_command_preserves_single_element_write() {
    let command = capture_switch_command("AnyOfMany", "PORT_B", true).await;

    assert!(
        command.contains("<oneSwitch name=\"PORT_B\">On</oneSwitch>"),
        "AnyOfMany command must include requested element: {}",
        command
    );
    assert!(
        !command.contains("PORT_A") && !command.contains("PORT_C"),
        "AnyOfMany command must not force unrelated siblings: {}",
        command
    );
}

#[tokio::test]
async fn test_timeout_config_modification() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Check default
    assert_eq!(client.timeout_config().mount_slew_timeout_secs, 300);

    // Modify
    let mut new_config = client.timeout_config().clone();
    new_config.mount_slew_timeout_secs = 600;
    client.set_timeout_config(new_config);

    // Verify change
    assert_eq!(client.timeout_config().mount_slew_timeout_secs, 600);
}

#[tokio::test]
async fn test_property_state_alert_detection() {
    let client = IndiClient::new("localhost", Some(7624));

    let result = client
        .wait_for_property_not_busy("TestDevice", "TestProperty", Duration::from_millis(100))
        .await;

    // Should timeout since device doesn't exist
    assert!(result.is_err());
}

#[tokio::test]
async fn test_client_default_creation() {
    let client = IndiClient::default();
    assert_eq!(client.host, "localhost");
    assert_eq!(client.port, INDI_DEFAULT_PORT);
}

#[test]
fn test_version_compatibility() {
    assert!(is_version_compatible("1.7", "1.7"));
    assert!(is_version_compatible("1.8", "1.7"));
    assert!(is_version_compatible("1.9", "1.7"));
    assert!(is_version_compatible("2.0", "1.7"));
    assert!(!is_version_compatible("1.6", "1.7"));
    assert!(!is_version_compatible("1.0", "1.7"));
}

#[test]
fn test_blob_format_validation() {
    // FITS format detection
    let fits_data = b"SIMPLE  =                    T";
    assert_eq!(validate_blob_format(".fits", fits_data), ".fits");

    // PNG format detection
    let png_data = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0];
    assert_eq!(validate_blob_format(".fits", &png_data), ".png");

    // JPEG format detection
    let jpeg_data = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0];
    assert_eq!(validate_blob_format(".fits", &jpeg_data), ".jpeg");

    // Unknown format uses declared
    let unknown_data = [0x00, 0x01, 0x02, 0x03];
    assert_eq!(validate_blob_format(".raw", &unknown_data), ".raw");

    // Missing declared format is inferred from magic bytes, not defaulted to FITS.
    assert_eq!(resolve_blob_format(None, &jpeg_data), ".jpeg");
    assert_eq!(resolve_blob_format(None, &unknown_data), ".blob");
}

#[tokio::test]
async fn test_protocol_config() {
    let protocol_config = ProtocolConfig {
        preferred_version: "1.8".to_string(),
        auto_detect: true,
        min_version: Some("1.7".to_string()),
    };

    let client = IndiClient::with_full_config(
        "localhost",
        Some(7624),
        IndiTimeoutConfig::default(),
        protocol_config.clone(),
        ReconnectionConfig::default(),
    );

    assert_eq!(client.protocol_config().preferred_version, "1.8");
    assert!(client.protocol_config().auto_detect);
}

#[tokio::test]
async fn test_number_limits() {
    let client = IndiClient::new("localhost", Some(7624));

    // Should return None for non-existent property
    let limits = client
        .get_number_limits("TestDevice", "TestProperty", "TestElement")
        .await;
    assert!(limits.is_none());
}

#[test]
fn malformed_indi_number_parse_returns_none_with_context() {
    assert_eq!(
        parse_indi_number_value("Device", "Property", "Element", "not-a-number"),
        None
    );
    assert_eq!(
        parse_indi_number_attribute("min", "Device", "Property", "Element", "bad"),
        None
    );
    assert_eq!(
        parse_indi_usize_attribute("size", "Device", "Property", "Element", "-1"),
        None
    );
    assert_eq!(
        parse_indi_light_state_value("Device", "Property", "Element", "bogus"),
        None
    );
}

#[tokio::test]
async fn test_reader_status() {
    let client = IndiClient::new("localhost", Some(7624));

    // Should be stopped initially
    let status = client.reader_status().await;
    assert_eq!(status, ReaderStatus::Stopped);
}

// Reader supervision tests

#[tokio::test]
async fn test_reader_task_config_default() {
    let config = ReaderTaskConfig::default();
    assert_eq!(config.max_consecutive_failures, 5);
    assert_eq!(config.restart_base_delay_secs, 1);
    assert_eq!(config.restart_max_delay_secs, 60);
    assert!(config.auto_restart);
    assert!(config.use_jitter);
    assert!((config.jitter_factor - 0.3).abs() < 0.01);
}

#[tokio::test]
async fn test_reader_task_config_delay_calculation() {
    let config = ReaderTaskConfig {
        max_consecutive_failures: 5,
        restart_base_delay_secs: 1,
        restart_max_delay_secs: 60,
        auto_restart: true,
        use_jitter: false, // Disable jitter for predictable testing
        jitter_factor: 0.0,
    };
    let rng = make_jitter_rng("test", 7624);

    // Test exponential growth
    assert_eq!(
        config.calculate_restart_delay(1, &rng),
        Duration::from_secs(1)
    );
    assert_eq!(
        config.calculate_restart_delay(2, &rng),
        Duration::from_secs(2)
    );
    assert_eq!(
        config.calculate_restart_delay(3, &rng),
        Duration::from_secs(4)
    );
    assert_eq!(
        config.calculate_restart_delay(4, &rng),
        Duration::from_secs(8)
    );
    assert_eq!(
        config.calculate_restart_delay(5, &rng),
        Duration::from_secs(16)
    );
    assert_eq!(
        config.calculate_restart_delay(6, &rng),
        Duration::from_secs(32)
    );
    // Should cap at max
    assert_eq!(
        config.calculate_restart_delay(7, &rng),
        Duration::from_secs(60)
    );
    assert_eq!(
        config.calculate_restart_delay(10, &rng),
        Duration::from_secs(60)
    );
}

#[tokio::test]
async fn test_reader_task_config_with_jitter() {
    let config = ReaderTaskConfig {
        max_consecutive_failures: 5,
        restart_base_delay_secs: 10,
        restart_max_delay_secs: 100,
        auto_restart: true,
        use_jitter: true,
        jitter_factor: 0.3,
    };
    let rng = make_jitter_rng("test", 7624);

    // With 30% jitter, delay should be within +/- 15% of base
    let delay = config.calculate_restart_delay(1, &rng);
    let expected = 10.0;
    let tolerance = expected * 0.15;
    assert!(
        delay.as_secs_f64() >= expected - tolerance && delay.as_secs_f64() <= expected + tolerance,
        "Delay {} not within expected range [{}, {}]",
        delay.as_secs_f64(),
        expected - tolerance,
        expected + tolerance
    );
}

#[tokio::test]
async fn test_is_reader_healthy_initial_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Initially not connected, so not healthy
    assert!(!client.is_reader_healthy());
    assert_eq!(client.reader_consecutive_failures(), 0);
    assert!(!client.is_reader_failed_permanently());
}

#[tokio::test]
async fn test_reader_consecutive_failures_tracking() {
    let client = IndiClient::new("localhost", Some(7624));

    // Initially zero
    assert_eq!(client.reader_consecutive_failures(), 0);

    // Simulate failures (normally done by supervised_reader_task)
    client
        .reader_consecutive_failures
        .store(3, Ordering::SeqCst);
    assert_eq!(client.reader_consecutive_failures(), 3);

    // Reset
    client.reset_reader_failures();
    assert_eq!(client.reader_consecutive_failures(), 0);
}

#[tokio::test]
async fn test_is_reader_failed_permanently() {
    let client = IndiClient::new("localhost", Some(7624));
    let max_failures = client.reader_task_config().max_consecutive_failures;

    // Not failed initially
    assert!(!client.is_reader_failed_permanently());

    // Simulate failures below threshold
    client
        .reader_consecutive_failures
        .store(max_failures - 1, Ordering::SeqCst);
    assert!(!client.is_reader_failed_permanently());

    // At threshold
    client
        .reader_consecutive_failures
        .store(max_failures, Ordering::SeqCst);
    assert!(client.is_reader_failed_permanently());

    // Above threshold
    client
        .reader_consecutive_failures
        .store(max_failures + 1, Ordering::SeqCst);
    assert!(client.is_reader_failed_permanently());
}

#[tokio::test]
async fn test_can_reconnect_initial_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Initially not connected and not restarting, so can reconnect
    assert!(client.can_reconnect().await);
}

#[tokio::test]
async fn test_can_reconnect_when_restarting() {
    let client = IndiClient::new("localhost", Some(7624));

    // Set status to Restarting
    *client.reader_status.write().await = ReaderStatus::Restarting;

    // Should not be able to reconnect while restarting
    assert!(!client.can_reconnect().await);
}

#[tokio::test]
async fn test_can_reconnect_when_connected() {
    let client = IndiClient::new("localhost", Some(7624));

    // Simulate connected state
    client.connected.store(true, Ordering::SeqCst);

    // Should not be able to reconnect when already connected
    assert!(!client.can_reconnect().await);
}

#[tokio::test]
async fn test_reader_status_enum_values() {
    // Test that all enum variants exist and are distinct
    let running = ReaderStatus::Running;
    let stopped = ReaderStatus::Stopped;
    let crashed = ReaderStatus::Crashed;
    let restarting = ReaderStatus::Restarting;

    assert_ne!(running, stopped);
    assert_ne!(running, crashed);
    assert_ne!(running, restarting);
    assert_ne!(stopped, crashed);
    assert_ne!(stopped, restarting);
    assert_ne!(crashed, restarting);
}

#[tokio::test]
async fn test_reader_task_config_getter_setter() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Check default
    assert_eq!(client.reader_task_config().max_consecutive_failures, 5);

    // Modify
    let mut new_config = client.reader_task_config().clone();
    new_config.max_consecutive_failures = 10;
    new_config.auto_restart = false;
    client.set_reader_task_config(new_config);

    // Verify change
    assert_eq!(client.reader_task_config().max_consecutive_failures, 10);
    assert!(!client.reader_task_config().auto_restart);
}

#[tokio::test]
async fn test_with_all_config_constructor() {
    let timeout_config = IndiTimeoutConfig::default();
    let protocol_config = ProtocolConfig::default();
    let reconnection_config = ReconnectionConfig::default();
    let reader_task_config = ReaderTaskConfig {
        max_consecutive_failures: 10,
        restart_base_delay_secs: 2,
        restart_max_delay_secs: 120,
        auto_restart: false,
        use_jitter: false,
        jitter_factor: 0.0,
    };

    let client = IndiClient::with_all_config(
        "192.168.1.100",
        Some(7625),
        timeout_config,
        protocol_config,
        reconnection_config,
        reader_task_config,
    );

    assert_eq!(client.host, "192.168.1.100");
    assert_eq!(client.port, 7625);
    assert_eq!(client.reader_task_config().max_consecutive_failures, 10);
    assert!(!client.reader_task_config().auto_restart);
}

#[tokio::test]
async fn test_recover_reader_when_failed_permanently() {
    let mut client = IndiClient::new("localhost", Some(7624));
    let max_failures = client.reader_task_config().max_consecutive_failures;

    // Simulate exceeding max failures
    client
        .reader_consecutive_failures
        .store(max_failures, Ordering::SeqCst);

    // Recovery should fail
    let result = client.recover_reader().await;
    assert!(result.is_err());
    if let Err(IndiError::ReconnectionFailed {
        attempts,
        last_error,
    }) = result
    {
        assert_eq!(attempts, max_failures);
        assert!(last_error.contains("Exceeded maximum"));
    } else {
        panic!("Expected ReconnectionFailed error");
    }
}

#[tokio::test]
async fn test_disconnect_resets_failure_counter() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Simulate some failures
    client
        .reader_consecutive_failures
        .store(3, Ordering::SeqCst);
    assert_eq!(client.reader_consecutive_failures(), 3);

    // Disconnect should reset
    let _ = client.disconnect().await;
    assert_eq!(client.reader_consecutive_failures(), 0);
}

// Keepalive race condition prevention tests

#[tokio::test]
async fn test_keepalive_in_progress_flag_initial_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Should not be in progress initially
    assert!(!client.is_keepalive_in_progress());
}

#[tokio::test]
async fn test_keepalive_in_progress_prevents_concurrent_checks() {
    let client = IndiClient::new("localhost", Some(7624));

    // Simulate a keepalive in progress
    client.keepalive_in_progress.store(true, Ordering::SeqCst);
    assert!(client.is_keepalive_in_progress());

    // This should not allow another keepalive to start
    let result = client.keepalive_in_progress.compare_exchange(
        false,
        true,
        Ordering::SeqCst,
        Ordering::SeqCst,
    );
    assert!(result.is_err()); // Should fail because already in progress
}

#[tokio::test]
async fn test_reconnecting_flag_initial_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Should not be reconnecting initially
    assert!(!client.is_reconnecting());
}

#[tokio::test]
async fn test_check_keepalive_skips_during_reconnection() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Set reconnecting flag
    client.reconnecting.store(true, Ordering::SeqCst);
    assert!(client.is_reconnecting());

    // check_keepalive should succeed but skip sending
    let result = client.check_keepalive().await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_check_keepalive_skips_when_not_connected() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Client is not connected by default
    assert!(!client.connected.load(Ordering::SeqCst));

    // check_keepalive should succeed but skip sending
    let result = client.check_keepalive().await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_time_since_last_keepalive_response() {
    let client = IndiClient::new("localhost", Some(7624));

    // Should be close to 0 initially (within a few ms of creation)
    let time_since = client.time_since_last_keepalive_response_ms();
    assert!(
        time_since < 100,
        "Expected time since last response to be < 100ms, got {}",
        time_since
    );

    // Simulate old response
    let old_time = current_time_ms() - 10000; // 10 seconds ago
    client
        .last_keepalive_response_ms
        .store(old_time, Ordering::SeqCst);

    let time_since = client.time_since_last_keepalive_response_ms();
    assert!(
        (9900..=11000).contains(&time_since),
        "Expected time since last response to be ~10000ms, got {}",
        time_since
    );
}

#[tokio::test]
async fn test_is_connection_healthy_initial_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Not connected, so not healthy
    assert!(!client.is_connection_healthy());
}

#[tokio::test]
async fn test_is_connection_healthy_when_connected() {
    let client = IndiClient::new("localhost", Some(7624));

    // Simulate connected state with recent keepalive response
    client.connected.store(true, Ordering::SeqCst);
    client
        .last_keepalive_response_ms
        .store(current_time_ms(), Ordering::SeqCst);

    // Should be healthy
    assert!(client.is_connection_healthy());
}

#[tokio::test]
async fn test_is_connection_healthy_when_stale() {
    let client = IndiClient::new("localhost", Some(7624));

    // Simulate connected state with old keepalive response
    client.connected.store(true, Ordering::SeqCst);
    let keepalive_interval_ms = client.timeout_config.keepalive_interval_secs * 1000;
    let old_time = current_time_ms() - (keepalive_interval_ms * 3); // 3x interval ago
    client
        .last_keepalive_response_ms
        .store(old_time, Ordering::SeqCst);

    // Should not be healthy (stale response)
    assert!(!client.is_connection_healthy());
}

#[tokio::test]
async fn test_disconnect_resets_keepalive_state() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Simulate various keepalive states
    client.keepalive_in_progress.store(true, Ordering::SeqCst);
    client.reconnecting.store(true, Ordering::SeqCst);
    client.reconnect_attempts.store(3, Ordering::SeqCst);

    // Verify states are set
    assert!(client.is_keepalive_in_progress());
    assert!(client.is_reconnecting());

    // Disconnect should reset
    let _ = client.disconnect().await;

    // Verify reset
    assert!(!client.is_keepalive_in_progress());
    assert!(!client.is_reconnecting());
    assert_eq!(client.reconnect_attempts.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn test_can_reconnect_when_reconnecting() {
    let client = IndiClient::new("localhost", Some(7624));

    // Initially can reconnect
    assert!(client.can_reconnect().await);

    // Set reconnecting flag
    client.reconnecting.store(true, Ordering::SeqCst);

    // Should not be able to reconnect
    assert!(!client.can_reconnect().await);
}

#[tokio::test]
async fn test_keepalive_response_timeout_detection() {
    let mut client = IndiClient::new("localhost", Some(7624));

    // Simulate connected state with very old keepalive response
    client.connected.store(true, Ordering::SeqCst);
    let keepalive_interval_ms = client.timeout_config.keepalive_interval_secs * 1000;
    let timeout_ms = keepalive_interval_ms * 2;
    let old_time = current_time_ms() - (timeout_ms + 1000); // Beyond timeout
    client
        .last_keepalive_response_ms
        .store(old_time, Ordering::SeqCst);

    // check_keepalive should detect the timeout
    let result = client.check_keepalive().await;
    assert!(result.is_err());
    if let Err(IndiError::OperationTimeout { operation, .. }) = result {
        assert_eq!(operation, "keepalive");
    } else {
        panic!("Expected OperationTimeout error");
    }
}

#[tokio::test]
async fn test_connect_resets_keepalive_state() {
    let client = IndiClient::new("localhost", Some(7624));

    // Verify initial state has keepalive timestamps set
    let last_sent = client.last_keepalive_ms.load(Ordering::SeqCst);
    let last_response = client.last_keepalive_response_ms.load(Ordering::SeqCst);

    // Both timestamps should be close to current time
    let now = current_time_ms();
    assert!(
        now.saturating_sub(last_sent) < 100,
        "last_keepalive_ms should be recent"
    );
    assert!(
        now.saturating_sub(last_response) < 100,
        "last_keepalive_response_ms should be recent"
    );

    // Keepalive in progress should be false
    assert!(!client.is_keepalive_in_progress());
}

#[tokio::test]
async fn test_keepalive_atomic_guard_acquire_release() {
    let client = IndiClient::new("localhost", Some(7624));

    // Acquire the lock
    let acquired = client
        .keepalive_in_progress
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok();
    assert!(acquired);
    assert!(client.is_keepalive_in_progress());

    // Try to acquire again (should fail)
    let acquired_again = client
        .keepalive_in_progress
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok();
    assert!(!acquired_again);

    // Release the lock
    client.keepalive_in_progress.store(false, Ordering::SeqCst);
    assert!(!client.is_keepalive_in_progress());

    // Should be able to acquire again
    let acquired_after_release = client
        .keepalive_in_progress
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok();
    assert!(acquired_after_release);
}

// XML depth-stack parser tests

#[test]
fn test_classify_indi_tag_dispatches_each_kind() {
    assert_eq!(
        classify_indi_tag(b"defNumberVector"),
        XmlContextKind::DefVector
    );
    assert_eq!(
        classify_indi_tag(b"defSwitchVector"),
        XmlContextKind::DefVector
    );
    assert_eq!(
        classify_indi_tag(b"setNumberVector"),
        XmlContextKind::SetOrNewVector
    );
    assert_eq!(
        classify_indi_tag(b"newSwitchVector"),
        XmlContextKind::SetOrNewVector
    );
    assert_eq!(classify_indi_tag(b"defNumber"), XmlContextKind::DefElement);
    assert_eq!(classify_indi_tag(b"defSwitch"), XmlContextKind::DefElement);
    assert_eq!(classify_indi_tag(b"oneNumber"), XmlContextKind::OneElement);
    assert_eq!(classify_indi_tag(b"oneSwitch"), XmlContextKind::OneElement);
    assert_eq!(classify_indi_tag(b"oneBLOB"), XmlContextKind::OneBlob);
    assert_eq!(classify_indi_tag(b"getProperties"), XmlContextKind::Other);
    assert_eq!(classify_indi_tag(b"message"), XmlContextKind::Other);
}

#[test]
fn test_refresh_xml_context_mirrors_walks_full_stack() {
    let stack = vec![
        XmlContext {
            kind: XmlContextKind::DefVector,
            tag: b"defNumberVector".to_vec(),
            device: Some("MountSim".to_string()),
            property: Some("EQUATORIAL_EOD_COORD".to_string()),
            element: None,
        },
        XmlContext {
            kind: XmlContextKind::DefElement,
            tag: b"defNumber".to_vec(),
            device: None,
            property: None,
            element: Some("RA".to_string()),
        },
    ];
    let mut device = String::new();
    let mut property = String::new();
    let mut element = String::new();
    refresh_xml_context_mirrors(&stack, &mut device, &mut property, &mut element);
    assert_eq!(device, "MountSim");
    assert_eq!(property, "EQUATORIAL_EOD_COORD");
    assert_eq!(element, "RA");
}

#[test]
fn test_refresh_xml_context_mirrors_clears_on_empty_stack() {
    let mut device = "stale".to_string();
    let mut property = "stale".to_string();
    let mut element = "stale".to_string();
    refresh_xml_context_mirrors(&[], &mut device, &mut property, &mut element);
    assert!(device.is_empty());
    assert!(property.is_empty());
    assert!(element.is_empty());
}

/// Build a minimum reader-task fixture and run the XML parser over `xml`.
/// Returns the populated `property_values` map, per-property update timestamps,
/// plus the events that were broadcast during parsing. `&[]` after the payload
/// triggers EOF, which breaks the parser's main loop cleanly.
async fn drive_parser_with_updates(
    xml: &str,
) -> (PropertyValueMap, PropertyUpdateMap, Vec<IndiEvent>) {
    let (values, updates, _blobs, events) = drive_parser_full(xml).await;
    (values, updates, events)
}

/// Same fixture as `drive_parser_with_updates`, exposing the decoded-BLOB cache.
async fn drive_parser_blobs(xml: &str) -> BlobMap {
    let (_values, _updates, blobs, _events) = drive_parser_full(xml).await;
    blobs
}

async fn drive_parser_full(
    xml: &str,
) -> (PropertyValueMap, PropertyUpdateMap, BlobMap, Vec<IndiEvent>) {
    let devices = Arc::new(RwLock::new(HashMap::new()));
    let properties = Arc::new(RwLock::new(HashMap::new()));
    let property_values = Arc::new(RwLock::new(HashMap::new()));
    let property_updated_ms = Arc::new(RwLock::new(HashMap::new()));
    let number_limits = Arc::new(RwLock::new(HashMap::new()));
    let latest_blobs = Arc::new(RwLock::new(HashMap::new()));
    let connected = Arc::new(AtomicBool::new(true));
    let (event_tx, mut event_rx) = broadcast::channel::<IndiEvent>(1024);
    let server_version = Arc::new(RwLock::new(None));
    let last_keepalive_response_ms = Arc::new(AtomicU64::new(current_time_ms()));

    // The reader is a Cursor; reading past the end returns 0 bytes which
    // quick-xml surfaces as `Event::Eof`, and the parser loop then breaks.
    let cursor = std::io::Cursor::new(xml.as_bytes().to_vec());
    let reader = tokio::io::BufReader::new(cursor);

    // Put a separate clone of property_values into the parser so the test
    // can read the final state without contention.
    let pv_clone = property_values.clone();
    let updated_clone = property_updated_ms.clone();
    let blobs = latest_blobs.clone();
    let result = IndiClient::reader_task_with_timeout(
        reader,
        devices,
        properties,
        pv_clone,
        updated_clone,
        number_limits,
        latest_blobs,
        connected,
        event_tx,
        server_version,
        last_keepalive_response_ms,
        IndiTimeoutConfig::default(),
    )
    .await;
    assert!(result.is_ok(), "parser returned error: {:?}", result);

    let mut events = Vec::new();
    while let Ok(ev) = event_rx.try_recv() {
        events.push(ev);
    }
    let pv_snapshot = property_values.read().await.clone();
    let updated_snapshot = property_updated_ms.read().await.clone();
    let blob_snapshot = blobs.read().await.clone();
    (pv_snapshot, updated_snapshot, blob_snapshot, events)
}

async fn drive_parser(xml: &str) -> (PropertyValueMap, Vec<IndiEvent>) {
    let (values, _updated, events) = drive_parser_with_updates(xml).await;
    (values, events)
}

#[tokio::test]
async fn test_parser_attributes_nested_def_number_correctly() {
    // Why: well-formed nested defNumberVector with multiple defNumber children must
    // attribute each text body to (device, property, element) of THAT element, not
    // bleed values across siblings.
    let xml = r#"
        <defNumberVector device="MountSim" name="EQUATORIAL_EOD_COORD" state="Idle" perm="rw">
            <defNumber name="RA" min="0" max="24">12.5</defNumber>
            <defNumber name="DEC" min="-90" max="90">-30.25</defNumber>
        </defNumberVector>
    "#;
    let (values, _events) = drive_parser(xml).await;
    let ra = values
        .get(&(
            "MountSim".to_string(),
            "EQUATORIAL_EOD_COORD".to_string(),
            "RA".to_string(),
        ))
        .expect("RA value missing");
    assert_eq!(ra, "12.5");
    let dec = values
        .get(&(
            "MountSim".to_string(),
            "EQUATORIAL_EOD_COORD".to_string(),
            "DEC".to_string(),
        ))
        .expect("DEC value missing");
    assert_eq!(dec, "-30.25");
}

#[tokio::test]
async fn test_parser_infers_missing_blob_format_from_payload() {
    let xml = r#"
        <setBLOBVector device="CCD" name="CCD1">
            <oneBLOB name="Image" size="6">/9j/4AAA</oneBLOB>
        </setBLOBVector>
    "#;

    let (_values, events) = drive_parser(xml).await;
    let blob_event = events
        .into_iter()
        .find_map(|event| match event {
            IndiEvent::BlobReceived { format, size, .. } => Some((format, size)),
            _ => None,
        })
        .expect("BlobReceived event missing");

    assert_eq!(blob_event, (".jpeg".to_string(), 6));
}

#[tokio::test]
async fn test_parser_handles_self_closing_def_switch() {
    // Why: INDI servers may emit `<defSwitch name="X" />` with no body for switches
    // whose state is "Off" by default. quick-xml delivers this as `Event::Empty`,
    // which our parser must treat as a push+pop in one event so the depth stack does
    // not leak and the element gets registered against the right property.
    let xml = r#"
        <defSwitchVector device="MountSim" name="CONNECTION" state="Idle" perm="rw">
            <defSwitch name="CONNECT" />
            <defSwitch name="DISCONNECT" />
        </defSwitchVector>
        <setSwitchVector device="MountSim" name="CONNECTION" state="Ok">
            <oneSwitch name="CONNECT">On</oneSwitch>
            <oneSwitch name="DISCONNECT">Off</oneSwitch>
        </setSwitchVector>
    "#;
    let (values, events) = drive_parser(xml).await;
    let connect = values
        .get(&(
            "MountSim".to_string(),
            "CONNECTION".to_string(),
            "CONNECT".to_string(),
        ))
        .expect("CONNECT value missing — self-closing defSwitch leaked frame state");
    assert_eq!(connect, "On");
    let disconnect = values
        .get(&(
            "MountSim".to_string(),
            "CONNECTION".to_string(),
            "DISCONNECT".to_string(),
        ))
        .expect("DISCONNECT value missing");
    assert_eq!(disconnect, "Off");

    // Why: a `setSwitchVector` close emits PropertyUpdated; verify it's there so we
    // know the depth stack survived the self-closing children.
    assert!(
        events.iter().any(|e| matches!(
            e,
            IndiEvent::PropertyUpdated(d, p)
                if d == "MountSim" && p == "CONNECTION"
        )),
        "PropertyUpdated event missing after self-closing children: {:?}",
        events
    );
}

#[tokio::test]
async fn test_parser_tracks_independent_property_update_timestamps() {
    let xml = r#"
        <setNumberVector device="WeatherSim" name="WEATHER_PARAMETERS" state="Ok">
            <oneNumber name="WEATHER_TEMPERATURE">12.5</oneNumber>
        </setNumberVector>
        <setSwitchVector device="MountSim" name="CONNECTION" state="Ok">
            <oneSwitch name="CONNECT">On</oneSwitch>
        </setSwitchVector>
    "#;
    let (_values, updates, events) = drive_parser_with_updates(xml).await;

    assert!(
        updates.contains_key(&("WeatherSim".to_string(), "WEATHER_PARAMETERS".to_string())),
        "weather update timestamp missing: {:?}",
        updates
    );
    assert!(
        updates.contains_key(&("MountSim".to_string(), "CONNECTION".to_string())),
        "mount update timestamp missing: {:?}",
        updates
    );
    assert!(
        events.iter().any(|e| matches!(
            e,
            IndiEvent::PropertyUpdated(device, property)
                if device == "WeatherSim" && property == "WEATHER_PARAMETERS"
        )),
        "weather PropertyUpdated event missing: {:?}",
        events
    );
}

#[tokio::test]
async fn test_parser_recovers_from_unbalanced_end_tag() {
    // Why: malformed streams (lossy proxy, mid-message reconnect, buggy server) may
    // produce mismatched closing tags. The parser must NOT panic, must emit a
    // diagnostic Error event, and must still process surrounding well-formed
    // elements correctly.
    let xml = r#"
        <defNumberVector device="DevA" name="PropA" state="Idle" perm="rw">
            <defNumber name="X">1.0</defNumber>
        </defNumberVector>
        <defNumberVector device="DevB" name="PropB" state="Idle" perm="rw">
            <defNumber name="Y">2.0</defSwitch>
        </defNumberVector>
        <defNumberVector device="DevC" name="PropC" state="Idle" perm="rw">
            <defNumber name="Z">3.0</defNumber>
        </defNumberVector>
    "#;
    // The second block contains </defSwitch> where </defNumber> was expected.
    // We must not crash; the well-formed surrounding blocks must still parse.
    let (values, events) = drive_parser(xml).await;

    // First block parses cleanly.
    assert_eq!(
        values
            .get(&("DevA".to_string(), "PropA".to_string(), "X".to_string()))
            .map(String::as_str),
        Some("1.0")
    );
    // Second block's element value lands before the bad close; either way the
    // parser must not poison the stream.
    let saw_unbalanced_warning = events.iter().any(|e| {
        matches!(e, IndiEvent::Error(msg) if msg.contains("Unbalanced") || msg.contains("XML parse error"))
    });
    assert!(
        saw_unbalanced_warning,
        "expected an Error event reporting the malformed nesting; got {:?}",
        events
    );

    // The third (well-formed) block must still parse — proves the parser recovered.
    // Quick-xml may treat the malformed block as a hard parse error and bail through
    // the recovery branch, which is acceptable; the recovery branch resets the stack
    // and continues. Either path must yield DevC's value.
    assert_eq!(
        values
            .get(&("DevC".to_string(), "PropC".to_string(), "Z".to_string()))
            .map(String::as_str),
        Some("3.0"),
        "parser failed to recover after malformed block; events={:?}",
        events
    );
}

#[tokio::test]
async fn test_parser_does_not_retain_blob_base64_in_property_values() {
    // Why: `property_values` is only cleared on disconnect, so storing the
    // base64 body of a BLOB there pins ~1.33x the frame size for the whole
    // session on top of the decoded copy in `latest_blobs`.
    let xml = r#"
        <setBLOBVector device="CCD" name="CCD1">
            <oneBLOB name="Image" size="6" format=".fits">/9j/4AAA</oneBLOB>
        </setBLOBVector>
    "#;

    let (values, updated, events) = drive_parser_with_updates(xml).await;

    assert!(
        !values.contains_key(&("CCD".to_string(), "CCD1".to_string(), "Image".to_string())),
        "BLOB base64 payload was retained in property_values: {:?}",
        values
    );
    assert!(
        updated.contains_key(&("CCD".to_string(), "CCD1".to_string())),
        "BLOB arrival must still refresh the property update timestamp"
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, IndiEvent::BlobReceived { .. })),
        "BLOB must still be delivered as an event"
    );
}

#[tokio::test]
async fn test_parser_caches_decoded_blob_for_late_subscribers() {
    let xml = r#"
        <setBLOBVector device="CCD" name="CCD1">
            <oneBLOB name="Image" size="6" format=".fits">/9j/4AAA</oneBLOB>
        </setBLOBVector>
    "#;

    let blobs = drive_parser_blobs(xml).await;
    let cached = blobs
        .get(&("CCD".to_string(), "CCD1".to_string(), "Image".to_string()))
        .expect("decoded BLOB missing from cache");
    assert_eq!(cached, &BASE64.decode("/9j/4AAA").unwrap());
}

#[tokio::test]
async fn test_disconnect_clears_cached_blobs_and_update_timestamps() {
    // Why: R6.1 — a decoded frame (tens to hundreds of MB) survived
    // `disconnect()`, and stale `property_updated_ms` entries made every
    // staleness check read pre-disconnect values as fresh after reconnect.
    let mut client = IndiClient::new("localhost", None);
    client.latest_blobs.write().await.insert(
        ("CCD".to_string(), "CCD1".to_string(), "Image".to_string()),
        vec![1u8, 2, 3],
    );
    client
        .property_updated_ms
        .write()
        .await
        .insert(("CCD".to_string(), "CCD1".to_string()), 1234);

    client.disconnect().await.expect("disconnect failed");

    assert!(
        client.take_blob("CCD", "CCD1", "Image").await.is_none(),
        "cached BLOB survived disconnect"
    );
    assert!(
        client
            .get_property_last_update_ms("CCD", "CCD1")
            .await
            .is_none(),
        "stale property update timestamp survived disconnect"
    );
}

#[tokio::test]
async fn test_writer_task_marks_disconnected_on_write_error() {
    // Why: R6.2 — the writer task broke out of its loop on a socket write
    // error without touching `connected`, so a half-open connection left
    // `is_connected()` reporting true while every send failed.
    use std::io::ErrorKind;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    struct FailingWriter;
    impl AsyncWrite for FailingWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            Poll::Ready(Err(std::io::Error::new(ErrorKind::BrokenPipe, "closed")))
        }
        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    let connected = Arc::new(AtomicBool::new(true));
    let (event_tx, mut event_rx) = broadcast::channel::<IndiEvent>(16);
    let (tx, rx) = mpsc::channel::<String>(4);
    tx.send("<getProperties/>".to_string()).await.unwrap();
    drop(tx);

    IndiClient::writer_task(FailingWriter, rx, connected.clone(), event_tx).await;

    assert!(
        !connected.load(Ordering::SeqCst),
        "writer task died without clearing the connected flag"
    );
    let mut saw_disconnect_event = false;
    while let Ok(ev) = event_rx.try_recv() {
        if matches!(ev, IndiEvent::ConnectionStateChanged(false)) {
            saw_disconnect_event = true;
        }
    }
    assert!(
        saw_disconnect_event,
        "writer task died without announcing the connection state change"
    );
}

#[tokio::test]
async fn test_writer_task_clean_shutdown_leaves_connected_untouched() {
    // A closed command channel is the ordinary `disconnect()` path; it must
    // not masquerade as a write failure.
    let connected = Arc::new(AtomicBool::new(true));
    let (event_tx, mut event_rx) = broadcast::channel::<IndiEvent>(16);
    let (tx, rx) = mpsc::channel::<String>(4);
    drop(tx);

    IndiClient::writer_task(tokio::io::sink(), rx, connected.clone(), event_tx).await;

    assert!(connected.load(Ordering::SeqCst));
    assert!(event_rx.try_recv().is_err());
}

/// A port that refuses connections: bind, read the port, drop the listener.
async fn refusing_port() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

#[tokio::test]
async fn a_failed_reconnect_with_backoff_does_not_forbid_the_next_recovery() {
    let port = refusing_port().await;
    let mut client = IndiClient::new("127.0.0.1", Some(port));
    client.set_reconnection_config(ReconnectionConfig {
        base_delay_secs: 1,
        max_delay_secs: 1,
        max_attempts: 2,
        use_jitter: false,
        jitter_factor: 0.0,
    });

    assert!(client.reconnect_with_backoff().await.is_err());

    // The server may come back a minute later; the heartbeat's next pass must
    // still be allowed to try.
    assert!(
        client.can_reconnect().await,
        "a failed reconnect must not forbid the next one (reconnect_attempts={})",
        client.reconnect_attempts().await
    );
}

#[tokio::test]
async fn an_aborted_reader_recovery_does_not_wedge_the_client() {
    let port = refusing_port().await;
    let client = Arc::new(tokio::sync::RwLock::new(IndiClient::new(
        "127.0.0.1",
        Some(port),
    )));
    // One prior failure makes recover_reader sleep its restart delay first,
    // which is where a heartbeat stop or restart can abort it.
    client
        .read()
        .await
        .reader_consecutive_failures
        .store(1, Ordering::SeqCst);

    let task = {
        let client = client.clone();
        tokio::spawn(async move {
            let _ = client.write().await.recover_reader().await;
        })
    };
    tokio::time::sleep(Duration::from_millis(100)).await;
    task.abort();
    let _ = task.await;

    let guard = client.read().await;
    assert!(
        !guard.is_reconnecting(),
        "an aborted recovery left the reconnecting flag set"
    );
    assert!(
        guard.can_reconnect().await,
        "an aborted recovery left the client unable to recover (reader_status={:?})",
        guard.reader_status().await
    );
}
