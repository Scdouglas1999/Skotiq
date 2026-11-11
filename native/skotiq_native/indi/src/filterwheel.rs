//! INDI Filter Wheel wrapper
//!
//! Provides high-level filter wheel control via INDI protocol.

use crate::client::IndiClient;
use crate::error::{IndiError, IndiResult};
use crate::protocol::standard_properties::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

pub struct IndiFilterWheel {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiFilterWheel {
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    pub fn device_name(&self) -> &str {
        &self.device_name
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

    /// Move to a **0-based** slot and return once the wheel reports it is
    /// there.
    ///
    /// INDI accepts the new slot before the wheel turns, and the property only
    /// goes Busy once the driver's reply arrives, so neither the slot value nor
    /// the Busy state read right after the send says where the wheel is: a
    /// caller that read back at once saw the old slot, not moving, and took the
    /// move for a stall. This waits for the slot reading to equal the target
    /// with the property no longer Busy, and fails when the property goes
    /// Alert or after the filter-change timeout.
    pub async fn move_to_position(&self, zero_based: i32) -> IndiResult<()> {
        let target = self.wire_slot_from_zero_based(zero_based).await;
        let (timeout, poll) = {
            let client = self.client.read().await;
            let config = client.timeout_config();
            (
                Duration::from_secs(config.filter_change_timeout_secs),
                Duration::from_millis(config.property_poll_interval_ms.clamp(50, 500)),
            )
        };
        self.set_slot(target).await?;
        let start = std::time::Instant::now();
        loop {
            let (state, slot) = {
                let client = self.client.read().await;
                (
                    client
                        .get_property_state(&self.device_name, FILTER_SLOT)
                        .await,
                    client
                        .get_number(&self.device_name, FILTER_SLOT, "FILTER_SLOT_VALUE")
                        .await,
                )
            };
            if state == Some(crate::IndiPropertyState::Alert) {
                return Err(IndiError::Incomplete(format!(
                    "Filter wheel {} reported an alert moving to slot {}",
                    self.device_name, target
                )));
            }
            // Why: INDI wire f64 -> i32 slot (bounded 1..wheel_size).
            let at_target = slot.map(|s| s as i32) == Some(target);
            if at_target && state != Some(crate::IndiPropertyState::Busy) {
                return Ok(());
            }
            if start.elapsed() >= timeout {
                return Err(IndiError::Incomplete(format!(
                    "Filter wheel {} did not reach slot {} within {:?}",
                    self.device_name, target, timeout
                )));
            }
            tokio::time::sleep(poll).await;
        }
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

    /// Set filter slot with timeout (driver-native slot index).
    pub async fn set_slot_with_timeout(
        &self,
        slot: i32,
        timeout: Option<Duration>,
    ) -> IndiResult<()> {
        let timeout_duration = match timeout {
            Some(timeout) => timeout,
            None => {
                let client = self.client.read().await;
                Duration::from_secs(client.timeout_config().filter_change_timeout_secs)
            }
        };

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

        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, FILTER_SLOT, timeout_duration)
            .await
            .map_err(|e| IndiError::Failed {
                what: format!("Filter wheel change to slot {}", slot),
                cause: Box::new(e),
            })
    }

    /// Get current filter position as a **0-based** index (Skotiq convention).
    pub async fn get_position(&self) -> IndiResult<i32> {
        let wire = self.get_slot().await?;
        Ok(self.zero_based_from_wire_slot(wire).await)
    }

    /// Get current filter slot in driver-native numbering (typically 1-based).
    pub async fn get_slot(&self) -> IndiResult<i32> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, FILTER_SLOT, "FILTER_SLOT_VALUE")
            .await
            // Why: INDI wire f64 -> i32 slot (bounded 1..wheel_size); saturates per Rust 1.45.
            .map(|s| s as i32)
            .ok_or_else(|| IndiError::Unavailable("Filter slot not available".to_string()))
    }

    pub async fn get_names(&self) -> IndiResult<Vec<String>> {
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
            assert!(
                e.to_string().contains("slot 3")
                    || e.to_string().to_lowercase().contains("not connected")
            );
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

        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().filter_change_timeout_secs
        };
        assert_eq!(timeout_secs, 120);
    }
}
