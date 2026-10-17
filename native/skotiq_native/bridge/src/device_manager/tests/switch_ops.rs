use super::*;

#[tokio::test]
async fn test_switch_methods_require_registered_device() {
    let manager = build_device_manager();
    let device_id = "missing-switch";

    let err = manager.switch_get_max(device_id).await.unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager.switch_get_state(device_id, 0).await.unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager
        .switch_set_state(device_id, 0, true)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager.switch_get_name(device_id, 0).await.unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager
        .switch_get_description(device_id, 0)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager.switch_get_value(device_id, 0).await.unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager
        .switch_set_value(device_id, 0, 1.0)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager
        .switch_get_min_value(device_id, 0)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager
        .switch_get_max_value(device_id, 0)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("Device not found"));

    let err = manager.switch_can_write(device_id, 0).await.unwrap_err();
    assert!(err.to_string().contains("Device not found"));
}

#[tokio::test]
async fn test_switch_get_max_reports_missing_alpaca_device() {
    let manager = build_device_manager();
    let device_id = "alpaca:test-switch";
    let info = build_switch_info(device_id, DriverType::Alpaca);
    manager.register_device(info, false).await;

    let err = manager.switch_get_max(device_id).await.unwrap_err();
    assert!(err.to_string().contains("Alpaca switch"));
}
