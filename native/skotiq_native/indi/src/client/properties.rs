//! Property read/write API and high-level device control.

use super::*;

impl IndiClient {
    /// Get the list of discovered devices
    pub async fn get_devices(&self) -> Vec<IndiDevice> {
        self.devices.read().await.values().cloned().collect()
    }

    /// Get properties for a device
    pub async fn get_properties(&self, device_name: &str) -> Vec<IndiProperty> {
        self.properties
            .read()
            .await
            .iter()
            .filter(|((device, _), _)| device == device_name)
            .map(|(_, prop)| prop.clone())
            .collect()
    }

    /// Get a property
    pub async fn get_property(&self, device: &str, property: &str) -> Option<IndiProperty> {
        let props = self.properties.read().await;
        map_get_2(&props, device, property).cloned()
    }

    /// Get a property value
    pub async fn get_property_value(
        &self,
        device: &str,
        property: &str,
        element: &str,
    ) -> Option<String> {
        let vals = self.property_values.read().await;
        map_get_3(&vals, device, property, element).cloned()
    }

    /// Get number limits for a property element
    pub async fn get_number_limits(
        &self,
        device: &str,
        property: &str,
        element: &str,
    ) -> Option<NumberLimits> {
        let limits = self.number_limits.read().await;
        map_get_3(&limits, device, property, element).cloned()
    }

    /// Get a number property value
    pub async fn get_number(&self, device: &str, property: &str, element: &str) -> Option<f64> {
        self.get_property_value(device, property, element)
            .await
            .and_then(|v| parse_indi_number_value(device, property, element, &v))
    }

    /// Get a switch property value
    pub async fn get_switch(&self, device: &str, property: &str, element: &str) -> Option<bool> {
        self.get_property_value(device, property, element)
            .await
            .map(|v| v.eq_ignore_ascii_case("on"))
    }

    /// Get property state
    pub async fn get_property_state(
        &self,
        device: &str,
        property: &str,
    ) -> Option<IndiPropertyState> {
        let props = self.properties.read().await;
        map_get_2(&props, device, property).map(|p| p.state)
    }

    /// Get property permission
    pub async fn get_property_permission(
        &self,
        device: &str,
        property: &str,
    ) -> Option<IndiPermission> {
        let props = self.properties.read().await;
        map_get_2(&props, device, property).map(|p| p.perm)
    }

    /// Check if a property is in the busy state
    pub async fn is_property_busy(&self, device: &str, property: &str) -> bool {
        self.get_property_state(device, property)
            .await
            .map(|s| s == IndiPropertyState::Busy)
            // Why: `get_property_state` returns Option<IndiPropertyState>;
            // None means the property has not yet been defined on the device. An undefined
            // property cannot be busy — `false` is the correct sentinel.
            .unwrap_or(false)
    }

    /// Check if a property exists for a device
    pub async fn has_property(&self, device: &str, property: &str) -> bool {
        let props = self.properties.read().await;
        map_contains_2(&props, device, property)
    }

    /// Get a light property state value (0=Idle, 1=Ok, 2=Busy, 3=Alert)
    pub async fn get_light_state(
        &self,
        device: &str,
        property: &str,
        element: &str,
    ) -> Option<i32> {
        self.get_property_value(device, property, element)
            .await
            .and_then(|v| match v.as_str() {
                "Idle" => Some(0),
                "Ok" => Some(1),
                "Busy" => Some(2),
                "Alert" => Some(3),
                _ => parse_indi_light_state_value(device, property, element, &v),
            })
    }

    /// Enable BLOB mode for a device
    pub async fn enable_blob(&mut self, device: &str) -> IndiResult<()> {
        let cmd = format!(
            "<enableBLOB device=\"{}\" name=\"\">Also</enableBLOB>",
            device
        );
        self.send_command(&cmd).await
    }

    /// Check property permission before write
    pub(super) fn check_write_permission(
        &self,
        perm: IndiPermission,
        property: &str,
    ) -> IndiResult<()> {
        match perm {
            IndiPermission::ReadOnly => Err(IndiError::PermissionDenied(format!(
                "Property '{}' is read-only",
                property
            ))),
            IndiPermission::WriteOnly | IndiPermission::ReadWrite => Ok(()),
        }
    }

    /// Validate number value against limits
    pub(super) async fn validate_number_limits(
        &self,
        device: &str,
        property: &str,
        element: &str,
        value: f64,
    ) -> IndiResult<()> {
        if let Some(limits) = self.get_number_limits(device, property, element).await {
            if let (Some(min), Some(max)) = (limits.min, limits.max) {
                if value < min || value > max {
                    return Err(IndiError::ValueOutOfRange {
                        device: device.to_string(),
                        property: property.to_string(),
                        element: element.to_string(),
                        value,
                        min,
                        max,
                    });
                }
            }
        }
        Ok(())
    }

    /// Milliseconds since UNIX epoch when the driver last sent a `set*Vector` for this property.
    pub async fn get_property_last_update_ms(&self, device: &str, property: &str) -> Option<u64> {
        let updated = self.property_updated_ms.read().await;
        map_get_2(&updated, device, property).copied()
    }

    /// Switch rule advertised by the driver for this property.
    pub async fn get_switch_rule(&self, device: &str, property: &str) -> Option<IndiSwitchRule> {
        self.get_property(device, property)
            .await
            .and_then(|p| p.switch_rule)
    }

    /// Set a switch property with permission check.
    ///
    /// For `OneOfMany` / `AtMostOne` rules, turning a switch **on** sends a full vector with
    /// sibling switches forced off (audit ND-).
    pub async fn set_switch(
        &mut self,
        device: &str,
        property: &str,
        element: &str,
        state: bool,
    ) -> IndiResult<()> {
        if state
            && switch_rule_requires_exclusive_vector(self.get_switch_rule(device, property).await)
        {
            return self.set_switch_exclusive(device, property, element).await;
        }

        // Check permission
        if let Some(perm) = self.get_property_permission(device, property).await {
            self.check_write_permission(perm, property)?;
        }

        let state_str = if state { "On" } else { "Off" };
        let cmd = format!(
            "<newSwitchVector device=\"{}\" name=\"{}\">\
             <oneSwitch name=\"{}\">{}</oneSwitch>\
             </newSwitchVector>",
            device, property, element, state_str
        );
        self.send_command(&cmd).await
    }

    /// Set exactly one switch on within a vector; all other elements are forced off.
    pub async fn set_switch_exclusive(
        &mut self,
        device: &str,
        property: &str,
        active_element: &str,
    ) -> IndiResult<()> {
        if let Some(perm) = self.get_property_permission(device, property).await {
            self.check_write_permission(perm, property)?;
        }

        let elements = self
            .get_property(device, property)
            .await
            .map(|p| p.elements)
            .unwrap_or_default();

        if elements.is_empty() {
            return Err(IndiError::PropertyNotFound {
                device: device.to_string(),
                property: property.to_string(),
            });
        }
        if !elements.iter().any(|name| name == active_element) {
            return Err(IndiError::ProtocolError(format!(
                "Switch element '{}.{}' not found on device '{}'",
                property, active_element, device
            )));
        }

        let switches: String = elements
            .iter()
            .map(|name| {
                let state = if name == active_element { "On" } else { "Off" };
                format!("<oneSwitch name=\"{name}\">{state}</oneSwitch>")
            })
            .collect();

        let cmd = format!(
            "<newSwitchVector device=\"{device}\" name=\"{property}\">{switches}</newSwitchVector>"
        );
        self.send_command(&cmd).await
    }

    /// Set a number property with permission and limits check
    pub async fn set_number(
        &mut self,
        device: &str,
        property: &str,
        element: &str,
        value: f64,
    ) -> IndiResult<()> {
        // Check permission
        if let Some(perm) = self.get_property_permission(device, property).await {
            self.check_write_permission(perm, property)?;
        }

        // Validate against limits
        self.validate_number_limits(device, property, element, value)
            .await?;

        let cmd = format!(
            "<newNumberVector device=\"{}\" name=\"{}\">\
             <oneNumber name=\"{}\">{}</oneNumber>\
             </newNumberVector>",
            device, property, element, value
        );
        self.send_command(&cmd).await
    }

    /// Set multiple number properties at once with validation
    pub async fn set_numbers(
        &mut self,
        device: &str,
        property: &str,
        values: &[(&str, f64)],
    ) -> IndiResult<()> {
        // Check permission
        if let Some(perm) = self.get_property_permission(device, property).await {
            self.check_write_permission(perm, property)?;
        }

        // Validate all values
        for (element, value) in values {
            self.validate_number_limits(device, property, element, *value)
                .await?;
        }

        let elements: String = values
            .iter()
            .map(|(name, value)| format!("<oneNumber name=\"{}\">{}</oneNumber>", name, value))
            .collect();
        let cmd = format!(
            "<newNumberVector device=\"{}\" name=\"{}\">{}</newNumberVector>",
            device, property, elements
        );
        self.send_command(&cmd).await
    }

    /// Set a text property with permission check
    pub async fn set_text(
        &mut self,
        device: &str,
        property: &str,
        element: &str,
        value: &str,
    ) -> IndiResult<()> {
        // Check permission
        if let Some(perm) = self.get_property_permission(device, property).await {
            self.check_write_permission(perm, property)?;
        }

        let cmd = format!(
            "<newTextVector device=\"{}\" name=\"{}\">\
             <oneText name=\"{}\">{}</oneText>\
             </newTextVector>",
            device, property, element, value
        );
        self.send_command(&cmd).await
    }

    // High-level device control methods

    /// Connect to a device (turn on CONNECTION switch)
    pub async fn connect_device(&mut self, device: &str) -> IndiResult<()> {
        self.set_switch(device, "CONNECTION", "CONNECT", true).await
    }

    /// Disconnect from a device
    pub async fn disconnect_device(&mut self, device: &str) -> IndiResult<()> {
        self.set_switch(device, "CONNECTION", "DISCONNECT", true)
            .await
    }

    /// Check if a device is connected
    pub async fn is_device_connected(&self, device: &str) -> bool {
        self.get_switch(device, "CONNECTION", "CONNECT")
            .await
            // Why: `CONNECTION` is the universal INDI device-connection
            // property. None means the device has not yet streamed it (the reader has not
            // yet seen `defSwitchVector CONNECTION` after `getProperties`). Treating
            // "not yet streamed" as "not connected" is correct — the caller must
            // re-poll after the initial property-discovery handshake completes.
            .unwrap_or(false)
    }

    /// Get filter names for a filter wheel device
    pub async fn get_filter_names(&self, device: &str) -> Result<Vec<String>, String> {
        let props = self.get_properties(device).await;

        // Look for the FILTER_NAME property
        if let Some(prop) = props.iter().find(|p| p.name == "FILTER_NAME") {
            let mut names = Vec::new();
            for elem in &prop.elements {
                if let Some(val) = self.get_property_value(device, "FILTER_NAME", elem).await {
                    names.push(val);
                } else {
                    names.push(elem.clone());
                }
            }
            if !names.is_empty() {
                return Ok(names);
            }
        }

        // Fallback: the driver published no FILTER_NAME property (optional in
        // INDI) or an empty one. Synthesize generic names from the FILTER_SLOT
        // count so a fresh install (no saved profile) still shows the wheel's
        // slots instead of an empty list (see IndiFilterWheel::get_names).
        if let Some(limits) = self
            .get_number_limits(device, "FILTER_SLOT", "FILTER_SLOT_VALUE")
            .await
        {
            if let (Some(min), Some(max)) = (limits.min, limits.max) {
                let count = (max - min + 1.0).max(0.0) as usize;
                if (1..=64).contains(&count) {
                    return Ok((1..=count).map(|i| format!("Filter {i}")).collect());
                }
            }
        }

        Ok(Vec::new())
    }

    // Timeout and reliability methods

    /// Wait for a property to reach a specific state with timeout
    pub async fn wait_for_property_state(
        &self,
        device: &str,
        property: &str,
        expected_state: IndiPropertyState,
        timeout_duration: Duration,
    ) -> Result<(), IndiTimeoutError> {
        let start = Instant::now();
        let poll_interval = Duration::from_millis(self.timeout_config.property_poll_interval_ms);
        let mut last_state = None;

        loop {
            // Check timeout
            if start.elapsed() >= timeout_duration {
                return Err(IndiTimeoutError {
                    device: device.to_string(),
                    property: property.to_string(),
                    context: format!(
                        "Timed out waiting for state {:?} after {:?}",
                        expected_state, timeout_duration
                    ),
                    last_state,
                });
            }

            // Check current state
            if let Some(state) = self.get_property_state(device, property).await {
                last_state = Some(state);

                if state == expected_state {
                    return Ok(());
                }

                // If state is Alert, return early with error
                if state == IndiPropertyState::Alert {
                    return Err(IndiTimeoutError {
                        device: device.to_string(),
                        property: property.to_string(),
                        context: format!(
                            "Property entered Alert state while waiting for {:?}",
                            expected_state
                        ),
                        last_state: Some(state),
                    });
                }
            }

            // Wait before polling again
            sleep(poll_interval).await;
        }
    }

    /// Wait for a property to no longer be busy (Ok or Idle state)
    pub async fn wait_for_property_not_busy(
        &self,
        device: &str,
        property: &str,
        timeout_duration: Duration,
    ) -> Result<(), IndiTimeoutError> {
        let start = Instant::now();
        let poll_interval = Duration::from_millis(self.timeout_config.property_poll_interval_ms);
        let mut last_state = None;

        loop {
            // Check timeout
            if start.elapsed() >= timeout_duration {
                return Err(IndiTimeoutError {
                    device: device.to_string(),
                    property: property.to_string(),
                    context: format!(
                        "Timed out waiting for property to finish (not Busy) after {:?}",
                        timeout_duration
                    ),
                    last_state,
                });
            }

            // Check current state
            if let Some(state) = self.get_property_state(device, property).await {
                last_state = Some(state);

                // Success if Ok or Idle
                if state == IndiPropertyState::Ok || state == IndiPropertyState::Idle {
                    return Ok(());
                }

                // Alert is an error condition
                if state == IndiPropertyState::Alert {
                    return Err(IndiTimeoutError {
                        device: device.to_string(),
                        property: property.to_string(),
                        context: "Property entered Alert state".to_string(),
                        last_state: Some(state),
                    });
                }
            }

            // Wait before polling again
            sleep(poll_interval).await;
        }
    }
}
