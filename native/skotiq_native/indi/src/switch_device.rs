//! INDI Switch device wrapper
//!
//! Provides switch/relay/power control via INDI protocol.
//!
//! Unlike ASCOM which uses a simple indexed MaxSwitch model, INDI switches
//! are grouped into named switch properties. Each property can contain
//! multiple elements. This wrapper provides discovery and control of
//! all switch-type properties on a device.
//!
//! Common INDI switch devices include:
//! - USB power hubs (Pegasus, Deep Sky Dad)
//! - Dew heaters
//! - Flat panel controllers
//! - Custom relay boards

use crate::client::IndiClient;
use crate::error::IndiResult;
use crate::{IndiPermission, IndiProperty, IndiPropertyType};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Information about a single switch element
#[derive(Debug, Clone)]
pub struct IndiSwitchInfo {
    /// Property name this switch belongs to
    pub property_name: String,
    /// Element name within the property
    pub element_name: String,
    /// Human-readable label
    pub label: String,
    /// Current state (true = On)
    pub state: bool,
    /// Whether this switch can be written
    pub writable: bool,
}

/// INDI Switch device wrapper
pub struct IndiSwitchDevice {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiSwitchDevice {
    /// Create a new INDI switch device wrapper
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

    // Connection

    /// Connect to the switch device
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the switch device
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    // Switch discovery

    /// Get all switch-type properties on this device
    ///
    /// Returns properties that are of type Switch, excluding internal
    /// INDI properties like CONNECTION and DEBUG.
    pub async fn get_switch_properties(&self) -> Vec<IndiProperty> {
        let client = self.client.read().await;
        let all_props = client.get_properties(&self.device_name).await;

        all_props
            .into_iter()
            .filter(|p| {
                matches!(p.property_type, IndiPropertyType::Switch)
                    && !is_internal_switch_property(&p.name)
            })
            .collect()
    }

    /// Get the total number of user-facing switch properties
    pub async fn get_switch_count(&self) -> usize {
        self.get_switch_properties().await.len()
    }

    /// Get all switches with their current state
    pub async fn get_all_switches(&self) -> Vec<IndiSwitchInfo> {
        let client = self.client.read().await;
        let all_props = client.get_properties(&self.device_name).await;
        let mut switches = Vec::new();

        for prop in all_props {
            if !matches!(prop.property_type, IndiPropertyType::Switch) {
                continue;
            }
            if is_internal_switch_property(&prop.name) {
                continue;
            }

            let writable = prop.perm != IndiPermission::ReadOnly;

            for element in &prop.elements {
                let state = client
                    .get_switch(&self.device_name, &prop.name, element)
                    .await
                    // Why: enumeration over every switch element of
                    // every published property. None means the element exists in the
                    // device definition but its current value has not been streamed yet
                    // by the background reader. `false` is the correct UI/discovery
                    // sentinel — the element will appear as off and refresh on the
                    // next `defSwitchVector`. Matches `bridge/src/dispatch/indi.rs:148`.
                    .unwrap_or(false);

                switches.push(IndiSwitchInfo {
                    property_name: prop.name.clone(),
                    element_name: element.clone(),
                    label: prop.label.clone(),
                    state,
                    writable,
                });
            }
        }

        switches
    }

    // Switch control

    /// Get the state of a specific switch element
    pub async fn get_switch_state(&self, property_name: &str, element: &str) -> Option<bool> {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, property_name, element)
            .await
    }

    /// Set the state of a specific switch element.
    ///
    /// Honors INDI switch rules (`OneOfMany`, `AtMostOne`) via [`IndiClient::set_switch`].
    pub async fn set_switch_state(
        &self,
        property_name: &str,
        element: &str,
        on: bool,
    ) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, property_name, element, on)
            .await
    }

    /// Switch rule advertised for a property (`OneOfMany`, `AnyOfMany`, etc.).
    pub async fn get_switch_rule(&self, property_name: &str) -> Option<crate::IndiSwitchRule> {
        let client = self.client.read().await;
        client
            .get_switch_rule(&self.device_name, property_name)
            .await
    }

    /// Get a numeric value associated with a switch (e.g., PWM duty cycle for dew heaters)
    pub async fn get_switch_value(&self, property_name: &str, element: &str) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, property_name, element)
            .await
    }

    /// Set a numeric value for a switch (e.g., PWM duty cycle)
    pub async fn set_switch_value(
        &self,
        property_name: &str,
        element: &str,
        value: f64,
    ) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, property_name, element, value)
            .await
    }

    /// Check if a switch property is read-only
    pub async fn is_switch_read_only(&self, property_name: &str) -> bool {
        let client = self.client.read().await;
        match client.get_property(&self.device_name, property_name).await {
            Some(property) => property.perm == IndiPermission::ReadOnly,
            None => true,
        }
    }
}

/// Check if a switch property is an internal INDI property that should be hidden
/// from the user-facing switch list.
fn is_internal_switch_property(name: &str) -> bool {
    matches!(
        name,
        "CONNECTION"
            | "DEBUG"
            | "DEBUG_LEVEL"
            | "SIMULATION"
            | "CONFIG_PROCESS"
            | "DEVICE_PORT_SCAN"
            | "ACTIVE_DEVICES"
            | "UPLOAD_MODE"
            | "LOG_OUTPUT"
            | "LOG_LEVEL"
    ) || name.starts_with("TELESCOPE_")
        || name.starts_with("CCD_")
        || name.starts_with("FILTER_")
        || name.starts_with("FOCUS_")
        || name.starts_with("DOME_")
        || name.starts_with("CAP_")
        || name.starts_with("ROTATOR_")
    // These prefixes belong to other device type interfaces, not switch-specific functionality
}
