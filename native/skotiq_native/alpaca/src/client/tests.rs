use super::*;
use std::collections::HashSet;
use std::sync::Arc;
use std::thread;

#[test]
fn decode_put_response_tolerates_missing_value() {
    // ASCOM Alpaca void PUT (e.g. Connected=true, slew): no "Value" field.
    let void_body = serde_json::json!({
        "ClientTransactionID": 1,
        "ServerTransactionID": 2,
        "ErrorNumber": 0,
        "ErrorMessage": ""
    });
    // A void Alpaca PUT response carries no `Value` field: the turbofish pins
    // the decoded type to `()` and `.expect` asserts it decoded.
    decode_put_response::<()>(void_body).expect("void PUT must decode");
}

#[test]
fn decode_void_put_ignores_nonstandard_value() {
    // libindi's Alpaca bridge includes `Value: true` on successful Connected
    // PUTs even though Connected is a void setter in the Alpaca contract.
    let void_body = serde_json::json!({
        "ClientTransactionID": 1,
        "ServerTransactionID": 2,
        "ErrorNumber": 0,
        "ErrorMessage": "",
        "Value": true
    });
    decode_put_response::<()>(void_body).expect("void PUT must ignore Value");
}

#[test]
fn decode_put_response_surfaces_device_error() {
    let err_body = serde_json::json!({
        "ErrorNumber": 1035,
        "ErrorMessage": "SlewToCoordinatesAsync is not allowed when tracking is False"
    });
    let result = decode_put_response::<()>(err_body);
    match result {
        Err(AlpacaError::DeviceError { code, message }) => {
            assert_eq!(code, 1035);
            assert!(message.contains("tracking"));
        }
        other => panic!("expected DeviceError, got {:?}", other),
    }
}

#[test]
fn decode_put_response_still_reads_a_present_value() {
    let valued = serde_json::json!({ "Value": true, "ErrorNumber": 0, "ErrorMessage": "" });
    assert!(decode_put_response::<bool>(valued).expect("decodes value"));
}

#[test]
fn test_transaction_id_uniqueness_single_thread() {
    let device = AlpacaDevice {
        device_type: AlpacaDeviceType::Camera,
        device_number: 0,
        server_name: String::new(),
        manufacturer: String::new(),
        device_name: String::new(),
        unique_id: String::new(),
        base_url: "http://127.0.0.1:11111".to_string(),
    };
    let client = AlpacaClient::new(&device);

    let mut ids = HashSet::new();
    for _ in 0..1000 {
        let (_, tid) = client.client_transaction();
        assert!(ids.insert(tid), "Transaction ID {} was not unique", tid);
    }
    assert_eq!(ids.len(), 1000);
}

#[test]
fn test_transaction_id_uniqueness_multi_thread() {
    use std::sync::Mutex;

    let device = AlpacaDevice {
        device_type: AlpacaDeviceType::Camera,
        device_number: 0,
        server_name: String::new(),
        manufacturer: String::new(),
        device_name: String::new(),
        unique_id: String::new(),
        base_url: "http://127.0.0.1:11111".to_string(),
    };
    let client = Arc::new(AlpacaClient::new(&device));
    let ids = Arc::new(Mutex::new(HashSet::new()));
    let mut handles = vec![];

    // Spawn 10 threads sharing one client — transaction IDs must stay unique.
    for _ in 0..10 {
        let client = Arc::clone(&client);
        let handle = thread::spawn(move || {
            let mut local_ids = Vec::new();
            for _ in 0..100 {
                let (_, tid) = client.client_transaction();
                local_ids.push(tid);
            }
            local_ids
        });
        handles.push(handle);
    }

    // Collect all IDs from all threads
    for handle in handles {
        let local_ids = handle.join().unwrap();
        let mut ids_lock = ids.lock().unwrap();
        for id in local_ids {
            assert!(
                ids_lock.insert(id),
                "Transaction ID {} was not unique across threads",
                id
            );
        }
    }

    // Should have 1000 unique IDs
    let ids_lock = ids.lock().unwrap();
    assert_eq!(
        ids_lock.len(),
        1000,
        "Expected 1000 unique transaction IDs, got {}",
        ids_lock.len()
    );
}

#[test]
fn test_client_id_per_instance() {
    let device = AlpacaDevice {
        device_type: AlpacaDeviceType::Camera,
        device_number: 0,
        server_name: String::new(),
        manufacturer: String::new(),
        device_name: String::new(),
        unique_id: String::new(),
        base_url: "http://127.0.0.1:11111".to_string(),
    };
    let a = AlpacaClient::new(&device);
    let b = AlpacaClient::new(&device);
    assert_ne!(a.client_transaction().0, b.client_transaction().0);
}

#[test]
fn test_transaction_id_atomicity() {
    let device = AlpacaDevice {
        device_type: AlpacaDeviceType::Camera,
        device_number: 0,
        server_name: String::new(),
        manufacturer: String::new(),
        device_name: String::new(),
        unique_id: String::new(),
        base_url: "http://127.0.0.1:11111".to_string(),
    };
    let client = AlpacaClient::new(&device);
    let (_, id1) = client.client_transaction();
    let (_, id2) = client.client_transaction();
    let (_, id3) = client.client_transaction();
    assert_eq!(id2, id1 + 1);
    assert_eq!(id3, id2 + 1);
}

#[test]
fn test_retry_config_delay_calculation() {
    let config = RetryConfig {
        max_attempts: 5,
        initial_delay_ms: 100,
        max_delay_ms: 5000,
        backoff_multiplier: 2.0,
        use_jitter: false, // Disable jitter for deterministic testing
    };

    // Attempt 0: 100ms
    let delay0 = config.delay_for_attempt(0);
    assert_eq!(delay0.as_millis(), 100);

    // Attempt 1: 200ms
    let delay1 = config.delay_for_attempt(1);
    assert_eq!(delay1.as_millis(), 200);

    // Attempt 2: 400ms
    let delay2 = config.delay_for_attempt(2);
    assert_eq!(delay2.as_millis(), 400);

    // Attempt 3: 800ms
    let delay3 = config.delay_for_attempt(3);
    assert_eq!(delay3.as_millis(), 800);

    // Attempt 4: 1600ms
    let delay4 = config.delay_for_attempt(4);
    assert_eq!(delay4.as_millis(), 1600);
}

#[test]
fn test_retry_config_max_delay_cap() {
    let config = RetryConfig {
        max_attempts: 10,
        initial_delay_ms: 1000,
        max_delay_ms: 3000, // Cap at 3 seconds
        backoff_multiplier: 2.0,
        use_jitter: false,
    };

    // Attempt 0: 1000ms
    assert_eq!(config.delay_for_attempt(0).as_millis(), 1000);

    // Attempt 1: 2000ms
    assert_eq!(config.delay_for_attempt(1).as_millis(), 2000);

    // Attempt 2: should be 4000ms but capped to 3000ms
    assert_eq!(config.delay_for_attempt(2).as_millis(), 3000);

    // Attempt 3: would be 8000ms but capped to 3000ms
    assert_eq!(config.delay_for_attempt(3).as_millis(), 3000);
}

#[test]
fn test_retry_after_delta_seconds_parsing() {
    let now = DateTime::parse_from_rfc2822("Sun, 06 Nov 1994 08:49:37 GMT")
        .unwrap()
        .with_timezone(&Utc);

    assert_eq!(
        parse_retry_after_value("7", now),
        Some(Duration::from_secs(7))
    );
    assert_eq!(parse_retry_after_value(" ", now), None);
}

#[test]
fn test_retry_after_http_date_parsing() {
    let now = DateTime::parse_from_rfc2822("Sun, 06 Nov 1994 08:49:37 GMT")
        .unwrap()
        .with_timezone(&Utc);

    assert_eq!(
        parse_retry_after_value("Sun, 06 Nov 1994 08:49:42 GMT", now),
        Some(Duration::from_secs(5))
    );
    assert_eq!(
        parse_retry_after_value("Sun, 06 Nov 1994 08:49:36 GMT", now),
        Some(Duration::ZERO)
    );
}

#[test]
fn test_retry_config_prefers_retry_after_header() {
    let config = RetryConfig {
        max_attempts: 3,
        initial_delay_ms: 100,
        max_delay_ms: 5000,
        backoff_multiplier: 2.0,
        use_jitter: false,
    };
    let error = AlpacaError::HttpError {
        status: 429,
        message: "rate limited".to_string(),
        retry_after: Some(Duration::from_secs(3)),
    };

    assert_eq!(
        config.delay_for_retry_error(&error, 0),
        Duration::from_secs(3)
    );
}

#[test]
fn test_alpaca_error_conversion() {
    let error = AlpacaError::timeout("test_operation", 5000);
    let error_string: String = error.into();
    assert!(error_string.contains("5000ms"));
    assert!(error_string.contains("test_operation"));

    let error = AlpacaError::DeviceError {
        code: 1031,
        message: "Method unavailable".to_string(),
    };
    let error_string: String = error.into();
    assert!(error_string.contains("1031"));
    assert!(error_string.contains("Method unavailable"));
}

#[test]
fn test_alpaca_error_is_retryable() {
    // Retryable errors
    assert!(AlpacaError::timeout("test", 5000).is_retryable());
    assert!(AlpacaError::connection_refused("http://localhost", "refused").is_retryable());
    assert!(AlpacaError::RequestFailed("network error".to_string()).is_retryable());
    assert!(AlpacaError::HttpError {
        status: 500,
        message: "server error".to_string(),
        retry_after: None
    }
    .is_retryable());
    assert!(AlpacaError::HttpError {
        status: 503,
        message: "unavailable".to_string(),
        retry_after: None
    }
    .is_retryable());
    assert!(AlpacaError::HttpError {
        status: 429,
        message: "rate limited".to_string(),
        retry_after: Some(Duration::from_secs(1))
    }
    .is_retryable());

    // Non-retryable errors
    assert!(!AlpacaError::DeviceError {
        code: 1,
        message: "device error".to_string()
    }
    .is_retryable());
    assert!(!AlpacaError::ParseError("parse error".to_string()).is_retryable());
    assert!(!AlpacaError::NotConnected.is_retryable());
    assert!(!AlpacaError::HttpError {
        status: 400,
        message: "bad request".to_string(),
        retry_after: None
    }
    .is_retryable());
    assert!(!AlpacaError::HttpError {
        status: 404,
        message: "not found".to_string(),
        retry_after: None
    }
    .is_retryable());
}

#[test]
fn test_timeout_config_defaults() {
    let config = TimeoutConfig::default();
    assert_eq!(config.quick_query_ms, 5000);
    assert_eq!(config.standard_operation_ms, 30000);
    assert_eq!(config.long_operation_ms, 300000);
    assert_eq!(config.very_long_operation_ms, 600000);
    assert_eq!(config.connect_ms, 10000);
}

#[test]
fn test_timeout_config_for_camera() {
    let config = TimeoutConfig::for_camera();
    assert_eq!(config.quick_query_ms, 5000);
    assert_eq!(config.long_operation_ms, 300000);
    assert_eq!(config.very_long_operation_ms, 900000);
}

#[test]
fn test_timeout_config_for_telescope() {
    let config = TimeoutConfig::for_telescope();
    assert_eq!(config.quick_query_ms, 5000);
    assert_eq!(config.standard_operation_ms, 60000);
    assert_eq!(config.long_operation_ms, 300000);
}

#[test]
fn test_timeout_config_for_dome() {
    let config = TimeoutConfig::for_dome();
    assert_eq!(config.quick_query_ms, 5000);
    assert_eq!(config.long_operation_ms, 300000);
    assert_eq!(config.very_long_operation_ms, 600000);
}

#[test]
fn test_api_version() {
    assert_eq!(ApiVersion::V1.as_str(), "v1");
    assert_eq!(ApiVersion::negotiate(&[2, 1]), Some(ApiVersion::V1));
    assert_eq!(ApiVersion::negotiate(&[2, 3]), None);
}
