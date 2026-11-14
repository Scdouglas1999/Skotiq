use crate::device::DomeStatus;
use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;

// Dome control

/// Get dome status
pub async fn api_get_dome_status(device_id: String) -> Result<DomeStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Open dome shutter
pub async fn api_dome_open_shutter(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_open_shutter(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Close dome shutter
pub async fn api_dome_close_shutter(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_close_shutter(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Slew dome to azimuth
pub async fn api_dome_slew_to_azimuth(device_id: String, azimuth: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_slew_to_azimuth(&device_id, azimuth)
        .await
        .map_err(SkotiqError::from)
}

/// Park dome
pub async fn api_dome_park(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_park(&device_id).await.map_err(SkotiqError::from)
}

/// Enable or disable dome slaving to the mount
pub async fn api_dome_set_slaved(device_id: String, slaved: bool) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_set_slaved(&device_id, slaved)
        .await
        .map_err(SkotiqError::from)
}

/// Find the dome home position
pub async fn api_dome_find_home(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_find_home(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Abort dome slew / shutter motion
pub async fn api_dome_abort_slew(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.dome_abort_slew(&device_id)
        .await
        .map_err(SkotiqError::from)
}
