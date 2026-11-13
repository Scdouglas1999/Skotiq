use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;

// Switch control

/// Get the number of switches exposed by a switch device
pub async fn api_switch_get_max(device_id: String) -> Result<i32, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_max(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the boolean state of a switch
pub async fn api_switch_get_state(device_id: String, switch_id: i32) -> Result<bool, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_state(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set the boolean state of a switch
pub async fn api_switch_set_state(
    device_id: String,
    switch_id: i32,
    state: bool,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_set_state(&device_id, switch_id, state)
        .await
        .map_err(SkotiqError::from)
}

/// Get the name of a switch
pub async fn api_switch_get_name(device_id: String, switch_id: i32) -> Result<String, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_name(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Get the numeric value of a switch
pub async fn api_switch_get_value(device_id: String, switch_id: i32) -> Result<f64, SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_get_value(&device_id, switch_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set the numeric value of a switch
pub async fn api_switch_set_value(
    device_id: String,
    switch_id: i32,
    value: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.switch_set_value(&device_id, switch_id, value)
        .await
        .map_err(SkotiqError::from)
}
