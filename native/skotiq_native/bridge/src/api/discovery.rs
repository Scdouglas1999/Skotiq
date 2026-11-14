//! Device discovery exposed to Dart.

use crate::device::{DeviceInfo, DeviceType};
use crate::discovery;
use crate::error::SkotiqError;

/// Discover Alpaca devices at a specific server address
pub async fn api_discover_alpaca_at_address(
    host: String,
    port: u16,
) -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::alpaca_at_address(host, port).await
}

/// Discover INDI devices at a specific server address
pub async fn api_discover_indi_at_address(
    host: String,
    port: u16,
) -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::indi_at_address(host, port).await
}

/// Auto-discover INDI servers on localhost
pub async fn api_discover_indi_localhost() -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::indi_localhost().await
}

/// Auto-discover INDI servers on common hostnames (localhost, raspberrypi, stellarmate, etc.)
pub async fn api_discover_indi_common_hosts() -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::indi_common_hosts().await
}

/// Auto-discover INDI servers on the local network (scans subnet)
pub async fn api_discover_indi_network() -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::indi_network().await
}

/// Discover available devices of a specific type.
pub async fn api_discover_devices(device_type: DeviceType) -> Result<Vec<DeviceInfo>, SkotiqError> {
    discovery::discover_devices(device_type).await
}

/// Forget every discovery result, so the next discovery asks every backend
/// again.
pub async fn api_invalidate_discovery_cache() {
    discovery::forget().await;
}
