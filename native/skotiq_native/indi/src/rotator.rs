//! INDI Rotator wrapper
//!
//! Provides high-level rotator control via INDI protocol.

use crate::client::IndiClient;
use crate::error::{IndiError, IndiResult};
use crate::protocol::standard_properties::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

pub struct IndiRotator {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiRotator {
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// The shared server connection this device is reached through.
    pub fn client(&self) -> &Arc<RwLock<IndiClient>> {
        &self.client
    }

    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    pub async fn move_to(&self, angle: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, "ABS_ROTATOR_ANGLE", "ANGLE", angle)
            .await
    }

    pub async fn move_to_with_timeout(
        &self,
        angle: f64,
        timeout: Option<Duration>,
    ) -> IndiResult<()> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            Duration::from_secs(client.timeout_config().rotator_move_timeout_secs)
        };

        {
            let mut client = self.client.write().await;
            client
                .set_number(&self.device_name, "ABS_ROTATOR_ANGLE", "ANGLE", angle)
                .await?;
        }

        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, "ABS_ROTATOR_ANGLE", timeout_duration)
            .await
            .map_err(|e| IndiError::Failed {
                what: format!("Rotator move to angle {:.1} degrees", angle),
                cause: Box::new(e),
            })
    }

    pub async fn get_angle(&self) -> IndiResult<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "ABS_ROTATOR_ANGLE", "ANGLE")
            .await
            .ok_or_else(|| IndiError::Unavailable("Angle not available".to_string()))
    }

    pub async fn abort_motion(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, "ROTATOR_ABORT_MOTION", "ABORT", true)
            .await
    }

    pub async fn is_moving(&self) -> bool {
        let client = self.client.read().await;
        client
            .is_property_busy(&self.device_name, "ABS_ROTATOR_ANGLE")
            .await
    }

    /// Sync reported sky angle to `angle` without moving (INDI `SYNC_ROTATOR_ANGLE`).
    pub async fn sync(&self, angle: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, SYNC_ROTATOR_ANGLE, "ANGLE", angle)
            .await
    }

    /// Mechanical / encoder angle when the driver publishes it.
    pub async fn get_mechanical_position(&self) -> IndiResult<f64> {
        let client = self.client.read().await;
        for (property, element) in [
            (ROTATOR_RAW_ANGLE, "ANGLE"),
            ("ROTATOR_POSITION", "POSITION"),
            ("MECHANICAL_POSITION", "POSITION"),
        ] {
            if let Some(angle) = client
                .get_number(&self.device_name, property, element)
                .await
            {
                return Ok(angle);
            }
        }
        Err(IndiError::Unavailable(
            "Mechanical position not available".to_string(),
        ))
    }

    pub async fn set_reverse(&self, reverse: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        if reverse {
            client
                .set_switch(&self.device_name, "ROTATOR_REVERSE", "INDI_ENABLED", true)
                .await
        } else {
            client
                .set_switch(&self.device_name, "ROTATOR_REVERSE", "INDI_DISABLED", true)
                .await
        }
    }
}

indi_accessory!(IndiRotator);

#[async_trait::async_trait]
impl skotiq_device::RotatorDriver for IndiRotator {
    async fn move_absolute(&self, position_deg: f64) -> Result<(), skotiq_device::DriverError> {
        let mut client = self.client.write().await;
        Ok(client
            .set_number(
                &self.device_name,
                "ABS_ROTATOR_ANGLE",
                "ANGLE",
                position_deg,
            )
            .await?)
    }

    /// A rotator that has not published its angle answers as not connected.
    async fn position(&self) -> Result<f64, skotiq_device::DriverError> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, "ABS_ROTATOR_ANGLE", "ANGLE")
            .await
            .ok_or(skotiq_device::DriverError::NotConnected)
    }

    async fn is_moving(&self) -> Result<bool, skotiq_device::DriverError> {
        let client = self.client.read().await;
        Ok(client
            .is_property_busy(&self.device_name, "ABS_ROTATOR_ANGLE")
            .await)
    }

    async fn halt(&self) -> Result<(), skotiq_device::DriverError> {
        let mut client = self.client.write().await;
        Ok(client
            .set_switch(&self.device_name, "ROTATOR_ABORT_MOTION", "ABORT", true)
            .await?)
    }

    async fn sync(&self, position_deg: f64) -> Result<(), skotiq_device::DriverError> {
        let mut client = self.client.write().await;
        Ok(client
            .set_number(
                &self.device_name,
                "SYNC_ROTATOR_ANGLE",
                "ANGLE",
                position_deg,
            )
            .await?)
    }

    async fn set_reverse(&self, reverse: bool) -> Result<(), skotiq_device::DriverError> {
        let element = if reverse {
            "INDI_ENABLED"
        } else {
            "INDI_DISABLED"
        };
        let mut client = self.client.write().await;
        Ok(client
            .set_switch(&self.device_name, "ROTATOR_REVERSE", element, true)
            .await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;

    #[tokio::test]
    async fn test_rotator_creation() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let rotator = IndiRotator::new(client, "TestRotator");
        assert_eq!(rotator.device_name(), "TestRotator");
    }

    #[tokio::test]
    async fn test_move_to_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let rotator = IndiRotator::new(client, "TestRotator");

        // This will fail since we're not connected
        let result = rotator
            .move_to_with_timeout(90.0, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention the angle or that we're not connected
            assert!(
                e.to_string().contains("90")
                    || e.to_string().to_lowercase().contains("not connected")
            );
        }
    }

    #[tokio::test]
    async fn test_rotator_timeout_uses_config() {
        let config = crate::IndiTimeoutConfig {
            rotator_move_timeout_secs: 240, // Custom timeout
            ..Default::default()
        };

        let client = Arc::new(RwLock::new(IndiClient::with_timeout_config(
            "localhost",
            Some(7624),
            config,
        )));
        let _rotator = IndiRotator::new(client.clone(), "TestRotator");

        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().rotator_move_timeout_secs
        };
        assert_eq!(timeout_secs, 240);
    }
}
