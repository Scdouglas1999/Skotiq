//! Alpaca Rotator API implementation

use crate::{AlpacaClient, AlpacaDevice, AlpacaDeviceType, AlpacaError};

/// Rotator status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct RotatorStatus {
    pub connected: bool,
    pub position: f64,
    pub mechanical_position: f64,
    pub is_moving: bool,
}

/// Rotator capabilities
#[derive(Debug, Clone)]
pub struct RotatorCapabilities {
    pub can_reverse: bool,
    pub step_size: f64,
}

/// Alpaca Rotator client
pub struct AlpacaRotator {
    client: AlpacaClient,
}

impl AlpacaRotator {
    /// Create a new Alpaca rotator client
    pub fn new(device: &AlpacaDevice) -> Self {
        assert_eq!(device.device_type, AlpacaDeviceType::Rotator);
        Self {
            client: AlpacaClient::new(device),
        }
    }

    /// Create from server details
    pub fn from_server(base_url: &str, device_number: u32) -> Self {
        let device = AlpacaDevice::from_server(AlpacaDeviceType::Rotator, base_url, device_number);
        Self::new(&device)
    }

    /// Get access to the underlying client
    pub fn client(&self) -> &AlpacaClient {
        &self.client
    }

    /// Get the base URL for this device
    pub fn base_url(&self) -> &str {
        self.client.base_url()
    }

    /// Get the device number for this device
    pub fn device_number(&self) -> u32 {
        self.client.device_number()
    }

    // Connection methods

    pub async fn connect(&self) -> Result<(), AlpacaError> {
        self.client.connect().await
    }

    pub async fn disconnect(&self) -> Result<(), AlpacaError> {
        self.client.disconnect().await
    }

    pub async fn is_connected(&self) -> Result<bool, AlpacaError> {
        self.client.is_connected().await
    }

    /// Validate connection is alive
    pub async fn validate_connection(&self) -> Result<bool, AlpacaError> {
        self.client.validate_connection().await
    }

    /// Send heartbeat and get round-trip time
    pub async fn heartbeat(&self) -> Result<u64, AlpacaError> {
        self.client.heartbeat().await
    }

    // Rotator information

    pub async fn name(&self) -> Result<String, AlpacaError> {
        self.client.get_name().await
    }

    pub async fn description(&self) -> Result<String, AlpacaError> {
        self.client.get_description().await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, AlpacaError> {
        self.client.get_driver_version().await
    }

    /// Get the driver info string
    pub async fn driver_info(&self) -> Result<String, AlpacaError> {
        self.client.get_driver_info().await
    }

    /// Get the interface version number
    pub async fn interface_version(&self) -> Result<i32, AlpacaError> {
        self.client.get_interface_version().await
    }

    /// Get the list of supported custom actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, AlpacaError> {
        self.client.get_supported_actions().await
    }

    // Position

    /// Get the current rotator position (degrees, 0-360)
    /// This is the synced/offset position
    pub async fn position(&self) -> Result<f64, AlpacaError> {
        self.client.get("position").await
    }

    /// Get the mechanical position (degrees, 0-360)
    /// This is the actual physical position without sync offset
    pub async fn mechanical_position(&self) -> Result<f64, AlpacaError> {
        self.client.get("mechanicalposition").await
    }

    /// Get the target position (degrees)
    pub async fn target_position(&self) -> Result<f64, AlpacaError> {
        self.client.get("targetposition").await
    }

    /// Get the step size in degrees
    pub async fn step_size(&self) -> Result<f64, AlpacaError> {
        self.client.get("stepsize").await
    }

    // Status

    /// Check if rotator is currently moving
    pub async fn is_moving(&self) -> Result<bool, AlpacaError> {
        self.client.get("ismoving").await
    }

    // Reversal

    /// Check if rotator can reverse direction
    pub async fn can_reverse(&self) -> Result<bool, AlpacaError> {
        self.client.get("canreverse").await
    }

    /// Get the current reverse setting
    pub async fn reverse(&self) -> Result<bool, AlpacaError> {
        self.client.get("reverse").await
    }

    /// Set the reverse direction
    pub async fn set_reverse(&self, reverse: bool) -> Result<(), AlpacaError> {
        self.client
            .put("reverse", &[("Reverse", &reverse.to_string())])
            .await
    }

    // Movement commands

    /// Move to an absolute position (degrees, 0-360)
    pub async fn move_absolute(&self, position: f64) -> Result<(), AlpacaError> {
        self.client
            .put("moveabsolute", &[("Position", &position.to_string())])
            .await
    }

    /// Move relative from current position (degrees)
    pub async fn move_relative(&self, offset: f64) -> Result<(), AlpacaError> {
        self.client
            .put("move", &[("Position", &offset.to_string())])
            .await
    }

    /// Move to the mechanical position (degrees)
    pub async fn move_mechanical(&self, position: f64) -> Result<(), AlpacaError> {
        self.client
            .put("movemechanical", &[("Position", &position.to_string())])
            .await
    }

    /// Halt any rotator motion
    pub async fn halt(&self) -> Result<(), AlpacaError> {
        self.client.put("halt", &[]).await
    }

    /// Sync the rotator position to a new value
    /// This sets the offset between mechanical and synced positions
    pub async fn sync(&self, position: f64) -> Result<(), AlpacaError> {
        self.client
            .put("sync", &[("Position", &position.to_string())])
            .await
    }

    // Parallel status methods

    /// Get comprehensive rotator status in a single parallel query
    pub async fn get_status(&self) -> Result<RotatorStatus, AlpacaError> {
        let (connected, position, mechanical_position, is_moving) = tokio::join!(
            self.is_connected(),
            self.position(),
            self.mechanical_position(),
            self.is_moving(),
        );

        Ok(RotatorStatus {
            connected: connected?,
            position: position?,
            mechanical_position: mechanical_position?,
            is_moving: is_moving?,
        })
    }

    /// Get rotator capabilities in a single parallel query
    pub async fn get_capabilities(&self) -> Result<RotatorCapabilities, AlpacaError> {
        let (can_reverse, step_size) = tokio::join!(self.can_reverse(), self.step_size(),);

        Ok(RotatorCapabilities {
            can_reverse: can_reverse?,
            step_size: step_size?,
        })
    }
}
