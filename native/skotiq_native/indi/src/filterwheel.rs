//! INDI Filter Wheel wrapper
//!
//! Provides high-level filter wheel control via INDI protocol.

use crate::client::IndiClient;
use crate::error::IndiResult;
use crate::protocol::standard_properties::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// INDI Filter Wheel device wrapper
pub struct IndiFilterWheel {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiFilterWheel {
    /// Create a new INDI filter wheel wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Connect to the filter wheel
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the filter wheel
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    /// Detect whether this driver numbers filter slots from 0 or 1 using `FILTER_SLOT` min.
    async fn slot_index_base(&self) -> i32 {
        let client = self.client.read().await;
        if let Some(limits) = client
            .get_number_limits(&self.device_name, FILTER_SLOT, "FILTER_SLOT_VALUE")
            .await
        {
            if limits.min.is_some_and(|m| m < 1.0) {
                return 0;
            }
        }
        1
    }

    async fn wire_slot_from_zero_based(&self, zero_based: i32) -> i32 {
        let base = self.slot_index_base().await;
        zero_based + base
    }

    async fn zero_based_from_wire_slot(&self, wire: i32) -> i32 {
        let base = self.slot_index_base().await;
        wire - base
    }

    /// Set filter position using Skotiq's **0-based** index (ASCOM/Alpaca convention).
    pub async fn set_position(&self, zero_based: i32) -> IndiResult<()> {
        let wire = self.wire_slot_from_zero_based(zero_based).await;
        self.set_slot(wire).await
    }

    /// Set filter slot using the driver's native slot numbering (usually 1-based per INDI).
    pub async fn set_slot(&self, slot: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(
                &self.device_name,
                FILTER_SLOT,
                "FILTER_SLOT_VALUE",
                // Why: i32 slot -> f64 (INDI wire); lossless.
                f64::from(slot),
            )
            .await
    }

    /// Set filter position (0-based) with timeout.
    pub async fn set_position_with_timeout(
        &self,
        zero_based: i32,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        let wire = self.wire_slot_from_zero_based(zero_based).await;
        self.set_slot_with_timeout(wire, timeout).await
    }

    /// Set filter slot with timeout (driver-native slot index).
    pub async fn set_slot_with_timeout(
        &self,
        slot: i32,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        let timeout_duration = match timeout {
            Some(timeout) => timeout,
            None => {
                let client = self.client.read().await;
                Duration::from_secs(client.timeout_config().filter_change_timeout_secs)
            }
        };

        // Start the filter change
        {
            let mut client = self.client.write().await;
            client
                .set_number(
                    &self.device_name,
                    FILTER_SLOT,
                    "FILTER_SLOT_VALUE",
                    // Why: i32 slot -> f64 (INDI wire); lossless.
                    f64::from(slot),
                )
                .await?;
        }

        // Wait for filter change to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, FILTER_SLOT, timeout_duration)
            .await
            .map_err(|e| format!("Filter wheel change to slot {} failed: {}", slot, e))
    }

    /// Get current filter position as a **0-based** index (Skotiq convention).
    pub async fn get_position(&self) -> Result<i32, String> {
        let wire = self.get_slot().await?;
        Ok(self.zero_based_from_wire_slot(wire).await)
    }

    /// Get current filter slot in driver-native numbering (typically 1-based).
    pub async fn get_slot(&self) -> Result<i32, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, FILTER_SLOT, "FILTER_SLOT_VALUE")
            .await
            // Why: INDI wire f64 -> i32 slot (bounded 1..wheel_size); saturates per Rust 1.45.
            .map(|s| s as i32)
            .ok_or_else(|| "Filter slot not available".to_string())
    }

    /// Get filter names
    /// Get filter names
    pub async fn get_names(&self) -> Result<Vec<String>, String> {
        let client = self.client.read().await;
        let props = client.get_properties(&self.device_name).await;

        if let Some(prop) = props.iter().find(|p| p.name == FILTER_NAME) {
            let mut names = Vec::new();
            for elem in &prop.elements {
                if let Some(val) = client
                    .get_property_value(&self.device_name, FILTER_NAME, elem)
                    .await
                {
                    names.push(val);
                } else {
                    names.push(elem.clone());
                }
            }
            if !names.is_empty() {
                return Ok(names);
            }
        }

        // Fallback: the driver did not publish a FILTER_NAME property (it is
        // OPTIONAL in INDI) or published it empty. Synthesize generic names from
        // the physical slot count reported by FILTER_SLOT's numeric limits,
        // mirroring the native vendor drivers (ZWO/QHY). Without this, a filter
        // wheel on a fresh install (no saved profile to fall back on) shows an
        // EMPTY filter list even though the wheel's slot count is known.
        if let Some(limits) = client
            .get_number_limits(&self.device_name, FILTER_SLOT, "FILTER_SLOT_VALUE")
            .await
        {
            if let (Some(min), Some(max)) = (limits.min, limits.max) {
                // FILTER_SLOT is inclusive [min, max] (1-based on most drivers,
                // 0-based on some); the slot count is max - min + 1. Guard against
                // a driver reporting an absurd range (real wheels are small).
                let count = (max - min + 1.0).max(0.0) as usize;
                if (1..=64).contains(&count) {
                    return Ok((1..=count).map(|i| format!("Filter {i}")).collect());
                }
            }
        }

        Ok(Vec::new())
    }

    /// Check if filter wheel is currently moving
    pub async fn is_moving(&self) -> bool {
        let client = self.client.read().await;
        client
            .is_property_busy(&self.device_name, FILTER_SLOT)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;

    #[tokio::test]
    async fn test_filterwheel_creation() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let fw = IndiFilterWheel::new(client, "TestFilterWheel");
        assert_eq!(fw.device_name(), "TestFilterWheel");
    }

    #[tokio::test]
    async fn test_set_slot_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let fw = IndiFilterWheel::new(client, "TestFilterWheel");

        // This will fail since we're not connected
        let result = fw
            .set_slot_with_timeout(3, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention either the slot or that we're not connected
            assert!(e.contains("slot 3") || e.to_lowercase().contains("not connected"));
        }
    }

    #[test]
    fn zero_based_slot_conversion_with_one_based_driver() {
        // wire 3 -> zero-based 2 when base is 1
        let wire = 3_i32;
        let base = 1_i32;
        assert_eq!(wire - base, 2);
        assert_eq!(2 + base, wire);
    }

    #[tokio::test]
    async fn test_filterwheel_timeout_uses_config() {
        let config = crate::IndiTimeoutConfig {
            filter_change_timeout_secs: 120, // Custom timeout
            ..Default::default()
        };

        let client = Arc::new(RwLock::new(IndiClient::with_timeout_config(
            "localhost",
            Some(7624),
            config,
        )));
        let _fw = IndiFilterWheel::new(client.clone(), "TestFilterWheel");

        // Verify the timeout config is accessible
        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().filter_change_timeout_secs
        };
        assert_eq!(timeout_secs, 120);
    }
}
