//! INDI driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide INDI-only logic: device discovery, connection, API version query,
//! switch helpers, and the per-device health check. Two free helper functions
//! that map INDI properties / names to a `DeviceType` also live here. They are
//! invoked from dispatcher methods in `crate::device_manager`. No behavior or
//! signature has changed relative to the previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// Whether a CONNECTION readback proves that it was produced after the
/// command we just sent.  Merely finding CONNECT=On in the cache is not enough:
/// during an Alpaca -> INDI handover that value can belong to the displaced
/// client, whose pending disconnect may arrive a moment later and undo the new
/// connection.
fn fresh_connected_readback(
    before_command_ms: Option<u64>,
    after_command_ms: Option<u64>,
    connected: bool,
) -> bool {
    if !connected {
        return false;
    }
    match (before_command_ms, after_command_ms) {
        (None, Some(_)) => true,
        (Some(before), Some(after)) => after > before,
        _ => false,
    }
}

/// Heuristically classify an INDI device from its property list. Returned to
/// the discovery helpers as a `DeviceType`, or `None` if no match is found.
pub(crate) fn infer_indi_device_type_from_properties(
    properties: &[skotiq_indi::IndiProperty],
) -> Option<DeviceType> {
    let has = |name: &str| properties.iter().any(|p| p.name == name);

    if has("CCD_EXPOSURE") || has("CCD_INFO") || has("CCD_FRAME") || has("CCD1") {
        return Some(DeviceType::Camera);
    }
    if has("EQUATORIAL_EOD_COORD")
        || has("ON_COORD_SET")
        || has("TELESCOPE_TRACK_MODE")
        || has("TELESCOPE_MOTION_NS")
        || has("TELESCOPE_MOTION_WE")
    {
        return Some(DeviceType::Mount);
    }
    if has("ABS_FOCUS_POSITION") || has("REL_FOCUS_POSITION") || has("FOCUS_MOTION") {
        return Some(DeviceType::Focuser);
    }
    if has("FILTER_SLOT") || has("FILTER_NAME") {
        return Some(DeviceType::FilterWheel);
    }
    if has("DOME_SHUTTER") || has("DOME_MOTION") || has("ABS_DOME_POSITION") {
        return Some(DeviceType::Dome);
    }
    if has("ABS_ROTATOR_ANGLE") || has("ROTATOR_ANGLE") {
        return Some(DeviceType::Rotator);
    }
    if has("TELESCOPE_TIMED_GUIDE_NS") || has("TELESCOPE_TIMED_GUIDE_WE") {
        return Some(DeviceType::Guider);
    }
    if has("SAFETY_STATUS") || has("AUX_SAFETY") {
        return Some(DeviceType::SafetyMonitor);
    }
    if has("WEATHER_STATUS") || has("WEATHER_PARAMETERS") {
        return Some(DeviceType::Weather);
    }
    if has("CAP_PARK")
        || has("FLAT_LIGHT_CONTROL")
        || has("FLAT_LIGHT_INTENSITY")
        || has("DUSTCAP_CONTROL")
        || has("LIGHTBOX_BRIGHTNESS")
    {
        return Some(DeviceType::CoverCalibrator);
    }
    if properties
        .iter()
        .any(|p| matches!(p.property_type, skotiq_indi::IndiPropertyType::Switch))
    {
        return Some(DeviceType::Switch);
    }

    None
}

/// Fallback INDI device classifier when property inspection didn't match a
/// known shape — uses the device name + driver string supplied by the server.
/// Classify an INDI device from its properties + name/driver.
///
/// Precedence matters: a SPECIFIC property match (camera/mount/focuser/...) is
/// authoritative, but the property inference's final "any Switch vector ->
/// Switch" catch-all is unreliable — EVERY INDI device carries a mandatory
/// CONNECTION switch vector, and during discovery the device-specific
/// properties (CCD_EXPOSURE, EQUATORIAL_EOD_COORD, ...) often haven't streamed
/// in yet. So take a specific property match first, then fall back to
/// name/driver, and only then accept the Switch catch-all — otherwise a
/// still-loading mount or camera is misreported as a "switch", which breaks the
/// entire INDI equipment workflow (the standard Raspberry Pi setup).
pub(crate) fn classify_indi_device(
    properties: &[skotiq_indi::IndiProperty],
    name: &str,
    driver: &str,
) -> Option<DeviceType> {
    let by_props = infer_indi_device_type_from_properties(properties);
    by_props
        .filter(|t| *t != DeviceType::Switch)
        .or_else(|| infer_indi_device_type_from_name_driver(name, driver))
        .or(by_props)
}

pub(crate) fn infer_indi_device_type_from_name_driver(
    name: &str,
    driver: &str,
) -> Option<DeviceType> {
    let name_upper = name.to_uppercase();
    let driver_upper = driver.to_uppercase();

    let has_mount = name_upper.contains("TELESCOPE")
        || name_upper.contains("MOUNT")
        || driver_upper.contains("TELESCOPE")
        || driver_upper.contains("MOUNT");
    let has_camera = name_upper.contains("CCD")
        || name_upper.contains("CAMERA")
        || driver_upper.contains("CCD")
        || driver_upper.contains("CAMERA");

    if has_mount {
        return Some(DeviceType::Mount);
    }
    if has_camera {
        return Some(DeviceType::Camera);
    }
    if name_upper.contains("FOCUSER") || driver_upper.contains("FOCUSER") {
        return Some(DeviceType::Focuser);
    }
    // Filter wheels are frequently named without "wheel" — INDI's simulator is
    // "Filter Simulator", and real units are commonly "...EFW" (electronic
    // filter wheel) or "...Filter...". Match those too.
    if name_upper.contains("WHEEL")
        || driver_upper.contains("WHEEL")
        || name_upper.contains("FILTER")
        || driver_upper.contains("FILTER")
        || name_upper.contains("EFW")
        || driver_upper.contains("EFW")
    {
        return Some(DeviceType::FilterWheel);
    }
    if name_upper.contains("ROTATOR") || driver_upper.contains("ROTATOR") {
        return Some(DeviceType::Rotator);
    }
    if name_upper.contains("DOME") || driver_upper.contains("DOME") {
        return Some(DeviceType::Dome);
    }
    if name_upper.contains("WEATHER") || driver_upper.contains("WEATHER") {
        return Some(DeviceType::Weather);
    }
    if name_upper.contains("SAFETY") || driver_upper.contains("SAFETY") {
        return Some(DeviceType::SafetyMonitor);
    }

    None
}

impl DeviceManager {
    pub(crate) fn parse_indi_device_id(device_id: &str) -> Result<(String, u16, String), String> {
        let parsed = crate::device_id::parse_device_id_cached(device_id)
            .map_err(|e| format!("Invalid INDI device ID format: {}", e))?;
        match parsed.connection_info {
            crate::device_id::ConnectionInfo::Indi {
                host,
                port,
                device_name,
            } => Ok((host, port, device_name)),
            _ => Err(format!("Invalid INDI device ID format: {}", device_id)),
        }
    }

    pub(crate) async fn indi_mount_tracking_rate(
        client: &skotiq_indi::IndiClient,
        device_name: &str,
    ) -> (TrackingRate, bool) {
        let Some(prop) = client
            .get_property(device_name, "TELESCOPE_TRACK_RATE")
            .await
        else {
            return (TrackingRate::Sidereal, false);
        };

        let can_set_tracking_rate = prop.perm != skotiq_indi::IndiPermission::ReadOnly;
        for element in prop.elements {
            // Why: `IndiClient::get_switch` returns
            // `Option<bool>` — `None` means "INDI client has not yet received
            // a definition for this device.property.element pair" (the
            // background reader publishes asynchronously). We are looping
            // every element of TELESCOPE_TRACK_RATE looking for the one
            // currently set to ON; a not-yet-streamed element is by
            // definition not-currently-active, so `unwrap_or(false)` correctly
            // tells the loop to skip ahead and check the next candidate.
            // If NO element ever resolves to On the function falls through to
            // the post-loop default of (Sidereal, false), matching the INDI
            // convention that an absent state implies the default sidereal
            // rate.
            if !client
                .get_switch(device_name, "TELESCOPE_TRACK_RATE", &element)
                .await
                .unwrap_or(false)
            {
                continue;
            }

            let upper = element.to_ascii_uppercase();
            let rate = if upper.contains("SIDEREAL") {
                Some(TrackingRate::Sidereal)
            } else if upper.contains("LUNAR") {
                Some(TrackingRate::Lunar)
            } else if upper.contains("SOLAR") {
                Some(TrackingRate::Solar)
            } else if upper.contains("KING") {
                Some(TrackingRate::King)
            } else if upper.contains("CUSTOM") {
                Some(TrackingRate::Custom)
            } else {
                None
            };

            if let Some(rate) = rate {
                return (rate, can_set_tracking_rate);
            }
        }

        (TrackingRate::Sidereal, can_set_tracking_rate)
    }

    /// Connect to an INDI device
    pub(crate) async fn connect_indi(&self, info: &DeviceInfo) -> Result<(), String> {
        use skotiq_indi::IndiClient;

        // Parse INDI device ID: indi:host:port:device_name
        let (host, port, device_name) = Self::parse_indi_device_id(&info.id)?;
        let server_key = format!("{host}:{port}");

        // Check if client exists
        let client = {
            let mut clients = self.indi_clients.write().await;
            if let Some(client) = clients.get(&server_key) {
                client.clone()
            } else {
                // Create new client
                let mut new_client = IndiClient::new(&host, Some(port));
                new_client.connect().await?;
                let client_arc = Arc::new(RwLock::new(new_client));
                clients.insert(server_key.clone(), client_arc.clone());
                client_arc
            }
        };

        // Use the client to connect the device
        let mut locked_client = client.write().await;

        // Enable BLOB for cameras
        if info.device_type == DeviceType::Camera {
            if let Err(e) = locked_client.enable_blob(&device_name).await {
                tracing::warn!("Failed to enable BLOB for {}: {}", device_name, e);
            }
        }

        // Capture the last CONNECTION vector before writing.  A cached On
        // from the backend being displaced must not count as confirmation of
        // this command.
        let connection_update_before = locked_client
            .get_property_last_update_ms(&device_name, "CONNECTION")
            .await;

        // Connect to the specific device.
        locked_client.connect_device(&device_name).await?;

        // INDI switch writes are asynchronous: `send_command` returning only
        // means the XML reached the socket. Do not publish a connected device
        // until the driver confirms CONNECTION.CONNECT=On, otherwise a rapid
        // cross-backend handover can race the previous disconnect.  Reassert
        // CONNECT while waiting: some Alpaca bridges acknowledge their own
        // disconnect before the shared INDI driver's Off vector arrives.  A
        // later idempotent CONNECT then deterministically wins that ordering.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut last_connect_write = tokio::time::Instant::now();
        loop {
            let connected = locked_client.is_device_connected(&device_name).await;
            let connection_update_after = locked_client
                .get_property_last_update_ms(&device_name, "CONNECTION")
                .await;
            if fresh_connected_readback(
                connection_update_before,
                connection_update_after,
                connected,
            ) {
                break;
            }

            if tokio::time::Instant::now() >= deadline {
                return Err(format!(
                    "Timed out waiting for INDI device {} to confirm a fresh connection readback",
                    device_name
                ));
            }

            if last_connect_write.elapsed() >= Duration::from_millis(250) {
                locked_client.connect_device(&device_name).await?;
                last_connect_write = tokio::time::Instant::now();
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        tracing::info!(
            "Connected to INDI device: {} at {}",
            device_name,
            server_key
        );
        Ok(())
    }

    /// Query and cache API version for an INDI device
    pub async fn query_indi_api_version(
        &self,
        device_id: &str,
    ) -> Result<DeviceApiVersion, String> {
        // Get the device info
        let device_info = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.clone())
        };

        let info = device_info.ok_or_else(|| format!("Device not found: {}", device_id))?;

        if info.driver_type != DriverType::Indi {
            return Err(format!("Device {} is not an INDI device", device_id));
        }

        // Parse INDI connection info from device ID
        let parsed = crate::device_id::parse_device_id_cached(device_id)
            .map_err(|e| format!("Failed to parse device ID: {}", e))?;

        let (host, port) = match &parsed.connection_info {
            crate::device_id::ConnectionInfo::Indi { host, port, .. } => (host.clone(), *port),
            _ => return Err("Invalid INDI device ID".to_string()),
        };

        let client_key = format!("{}:{}", host, port);

        // Get protocol version from INDI client
        let indi_clients = self.indi_clients.read().await;
        let protocol_version = if let Some(client) = indi_clients.get(&client_key) {
            let client_guard = client.read().await;
            client_guard.get_server_version().await.ok()
        } else {
            None
        };

        let version = DeviceApiVersion::from_indi(device_id.to_string(), protocol_version);

        // Cache the version
        self.set_device_api_version(device_id, version.clone())
            .await;
        tracing::info!(
            "Queried API version for {}: protocol_version={:?}",
            device_id,
            version.protocol_version
        );

        Ok(version)
    }

    pub async fn get_indi_client(
        &self,
        device_id: &str,
    ) -> Option<Arc<RwLock<skotiq_indi::IndiClient>>> {
        // Parse INDI device ID: indi:host:port:device_name
        if !device_id.starts_with("indi:") {
            return None;
        }

        let (host, port, _device_name) = Self::parse_indi_device_id(device_id).ok()?;
        let server_key = format!("{host}:{port}");

        let clients = self.indi_clients.read().await;
        clients.get(&server_key).cloned()
    }

    /// Discover INDI devices at a specific address
    pub async fn discover_indi_devices(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Vec<DeviceInfo>, String> {
        use skotiq_indi::IndiClient;

        let server_key = format!("{}:{}", host, port);

        // Get or create client
        let client = {
            let mut clients = self.indi_clients.write().await;
            if let Some(client) = clients.get(&server_key) {
                client.clone()
            } else {
                // Create new client
                let mut new_client = IndiClient::new(host, Some(port));
                new_client.connect().await.map_err(|e| e.to_string())?;
                let client_arc = Arc::new(RwLock::new(new_client));
                clients.insert(server_key.clone(), client_arc.clone());
                client_arc
            }
        };

        // INDI announces a device's NAME before its full property set streams
        // in. Classification keys off device-specific properties (CCD_EXPOSURE,
        // EQUATORIAL_EOD_COORD, ...), so breaking out the instant a device name
        // appears races the property stream and sees only the mandatory
        // CONNECTION switch vector — making every device look like a "switch".
        // Wait (up to 5 s) until every announced device classifies to a
        // specific type via its properties OR a self-describing name, so real
        // mounts/cameras/domes aren't misreported as switches.
        let start = std::time::Instant::now();
        loop {
            {
                let locked_client = client.read().await;
                let devices = locked_client.get_devices().await;
                if !devices.is_empty() {
                    let mut all_classified = true;
                    for d in &devices {
                        let props = locked_client.get_properties(&d.name).await;
                        let specific_by_props = infer_indi_device_type_from_properties(&props)
                            .is_some_and(|t| t != DeviceType::Switch);
                        let by_name =
                            infer_indi_device_type_from_name_driver(&d.name, &d.driver).is_some();
                        if !specific_by_props && !by_name {
                            all_classified = false;
                            break;
                        }
                    }
                    if all_classified {
                        break;
                    }
                }
            }

            if start.elapsed().as_secs() >= 5 {
                break;
            }

            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        // Get devices and convert to DeviceInfo
        let locked_client = client.read().await;
        let indi_devices = locked_client.get_devices().await;

        let mut devices = Vec::new();
        for dev in indi_devices {
            let properties = locked_client.get_properties(&dev.name).await;
            let device_type = classify_indi_device(&properties, &dev.name, &dev.driver);
            let Some(device_type) = device_type else {
                tracing::warn!(
                    "Skipping INDI device '{}' with unrecognized type (driver='{}')",
                    dev.name,
                    dev.driver
                );
                continue;
            };

            // Serial number is not consistently exposed by INDI discovery; leave unset.
            devices.push(DeviceInfo {
                id: format!("indi:{}:{}:{}", host, port, dev.name),
                name: dev.name.clone(),
                device_type,
                driver_type: DriverType::Indi,
                description: format!("INDI device on {}:{}", host, port),
                driver_version: "INDI".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: dev.name.clone(),
            });
        }

        Ok(devices)
    }

    /// Get all discovered INDI devices from all connected clients
    pub async fn get_all_indi_devices(&self) -> Vec<DeviceInfo> {
        let clients = self.indi_clients.read().await;
        let mut all_devices = Vec::new();

        for (server_key, client_arc) in clients.iter() {
            let client = client_arc.read().await;
            let indi_devices = client.get_devices().await;

            for dev in indi_devices {
                let properties = client.get_properties(&dev.name).await;
                let device_type = infer_indi_device_type_from_properties(&properties)
                    .or_else(|| infer_indi_device_type_from_name_driver(&dev.name, &dev.driver));
                let Some(device_type) = device_type else {
                    tracing::warn!(
                        "Skipping INDI device '{}' with unrecognized type (driver='{}')",
                        dev.name,
                        dev.driver
                    );
                    continue;
                };

                // Serial number is not consistently exposed by INDI discovery; leave unset.
                all_devices.push(DeviceInfo {
                    id: format!("indi:{}:{}", server_key, dev.name),
                    name: dev.name.clone(),
                    device_type,
                    driver_type: DriverType::Indi,
                    description: format!("INDI device on {}", server_key),
                    driver_version: "INDI".to_string(),
                    serial_number: None,
                    unique_id: None,
                    display_name: dev.name.clone(),
                });
            }
        }

        all_devices
    }

    /// Perform health check for INDI devices
    pub(crate) async fn perform_indi_health_check(&self, device_id: &str) -> Result<bool, String> {
        let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
        let server_key = format!("{}:{}", host, port);

        let client = {
            let clients = self.indi_clients.read().await;
            clients
                .get(&server_key)
                .cloned()
                .ok_or_else(|| format!("INDI client for {} not found", server_key))?
        };

        let mut client_guard = client.write().await;
        Self::recover_indi_client_for_health_check(&mut client_guard, &server_key).await?;

        let is_connected = client_guard.is_connected().await;
        if is_connected {
            // Check if the device is still responding by verifying its
            // universal CONNECTION switch, after the server-level keepalive
            // and recovery path have had a chance to run.
            let mut is_device_connected = client_guard.is_device_connected(&device_name).await;
            if !is_device_connected {
                tracing::warn!(
                    "INDI {} heartbeat found device '{}' disconnected; reissuing CONNECT",
                    server_key,
                    device_name
                );
                client_guard
                    .connect_device(&device_name)
                    .await
                    .map_err(|connect_error| {
                        format!(
                            "INDI {} server is connected but device '{}' reconnect failed: {}",
                            server_key, device_name, connect_error
                        )
                    })?;
                is_device_connected = client_guard.is_device_connected(&device_name).await;
            }
            tracing::trace!(
                "INDI {} heartbeat: server_connected={}, device_connected={}",
                device_id,
                is_connected,
                is_device_connected
            );
            Ok(is_device_connected)
        } else {
            tracing::debug!("INDI {} heartbeat: server not connected", device_id);
            Ok(false)
        }
    }

    async fn recover_indi_client_for_health_check(
        client: &mut skotiq_indi::IndiClient,
        server_key: &str,
    ) -> Result<(), String> {
        if client.is_connected().await {
            if let Err(keepalive_error) = client.check_keepalive().await {
                tracing::warn!(
                    "INDI {} keepalive failed; tearing down stale connection before reconnect: {}",
                    server_key,
                    keepalive_error
                );

                if let Err(disconnect_error) = client.disconnect().await {
                    tracing::warn!(
                        "INDI {} disconnect during keepalive recovery failed: {}",
                        server_key,
                        disconnect_error
                    );
                }

                client
                    .reconnect_with_backoff()
                    .await
                    .map_err(|reconnect_error| {
                        format!(
                            "INDI {} keepalive failed ({}) and reconnect failed: {}",
                            server_key, keepalive_error, reconnect_error
                        )
                    })?;
            }
            return Ok(());
        }

        if client.can_reconnect().await {
            tracing::warn!(
                "INDI {} reader is disconnected; attempting reader recovery",
                server_key
            );
            client.recover_reader().await.map_err(|recovery_error| {
                format!(
                    "INDI {} server not connected and reader recovery failed: {}",
                    server_key, recovery_error
                )
            })?;
            return Ok(());
        }

        Err(format!(
            "INDI {} server not connected and no reconnect is currently allowed \
             (reader_status={:?}, consecutive_failures={}, reconnecting={})",
            server_key,
            client.reader_status().await,
            client.reader_consecutive_failures(),
            client.is_reconnecting()
        ))
    }

    pub(crate) async fn indi_get_all_switches(
        &self,
        device_id: &str,
    ) -> Result<Vec<skotiq_indi::IndiSwitchInfo>, String> {
        let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
        let server_key = format!("{host}:{port}");

        let clients = self.indi_clients.read().await;
        if let Some(client) = clients.get(&server_key) {
            let switch_dev = skotiq_indi::IndiSwitchDevice::new(client.clone(), &device_name);
            return Ok(switch_dev.get_all_switches().await);
        }
        Err("INDI switch device not connected".to_string())
    }

    /// Get the Nth INDI switch element (0-indexed).
    pub(crate) async fn indi_get_switch_at(
        &self,
        device_id: &str,
        index: i32,
    ) -> Result<skotiq_indi::IndiSwitchInfo, String> {
        let switches = self.indi_get_all_switches(device_id).await?;
        // Why: a negative i32 wraps to a huge usize which
        // would trip the immediate `idx >= switches.len()` check below; the
        // structured "out of range" error replaces what would otherwise be
        // a buffer-overrun-fault, so the cast is bounded by the next line.
        let idx = usize::try_from(index).unwrap_or(usize::MAX);
        if idx >= switches.len() {
            return Err(format!(
                "Switch index {} out of range (device has {} switches)",
                index,
                switches.len()
            ));
        }
        Ok(switches
            .into_iter()
            .nth(idx)
            .ok_or_else(|| format!("Switch index {} out of range", index))?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connected_readback_must_be_newer_than_the_connect_command() {
        assert!(!fresh_connected_readback(Some(100), Some(100), true));
        assert!(!fresh_connected_readback(Some(100), Some(101), false));
        assert!(fresh_connected_readback(Some(100), Some(101), true));
        assert!(fresh_connected_readback(None, Some(1), true));
        assert!(!fresh_connected_readback(None, None, true));
    }

    #[test]
    fn infer_indi_name_driver_prefers_mount_over_embedded_camera_word() {
        let inferred =
            infer_indi_device_type_from_name_driver("Avalon Mount Camera Mount", "Avalon");

        assert_eq!(inferred, Some(DeviceType::Mount));
    }

    #[test]
    fn infer_indi_name_driver_still_detects_camera_without_mount_terms() {
        let inferred = infer_indi_device_type_from_name_driver("ASI294MM Camera", "ZWO CCD");

        assert_eq!(inferred, Some(DeviceType::Camera));
    }

    #[test]
    fn infer_indi_name_driver_detects_filter_wheel_without_wheel_word() {
        // INDI's simulator is "Filter Simulator"; real units are often "...EFW".
        assert_eq!(
            infer_indi_device_type_from_name_driver("Filter Simulator", "indi_simulator_wheel"),
            Some(DeviceType::FilterWheel)
        );
        assert_eq!(
            infer_indi_device_type_from_name_driver("ASI EFW", "ASI EFW"),
            Some(DeviceType::FilterWheel)
        );
    }

    fn switch_prop(name: &str) -> skotiq_indi::IndiProperty {
        skotiq_indi::IndiProperty {
            device: "dev".to_string(),
            name: name.to_string(),
            label: name.to_string(),
            group: String::new(),
            property_type: skotiq_indi::IndiPropertyType::Switch,
            state: skotiq_indi::IndiPropertyState::Ok,
            perm: skotiq_indi::IndiPermission::ReadWrite,
            elements: vec![],
            switch_rule: None,
        }
    }

    #[test]
    fn classify_does_not_let_connection_switch_preempt_name() {
        // Every INDI device exposes a CONNECTION switch vector before its
        // device-specific properties stream in, so property inference alone
        // returns Switch and masks the real type. A telescope/camera with only a
        // CONNECTION switch loaded must classify by name, not as a switch.
        let props = vec![switch_prop("CONNECTION"), switch_prop("DEBUG")];
        assert_eq!(
            classify_indi_device(&props, "Telescope Simulator", "indi_simulator_telescope"),
            Some(DeviceType::Mount),
        );
        assert_eq!(
            classify_indi_device(&props, "CCD Simulator", "indi_simulator_ccd"),
            Some(DeviceType::Camera),
        );
        assert_eq!(
            classify_indi_device(&props, "Dome Simulator", "indi_simulator_dome"),
            Some(DeviceType::Dome),
        );
    }

    #[test]
    fn classify_still_returns_switch_for_a_genuine_switch_device() {
        // A device with only switch vectors AND no type-identifying name should
        // still fall through to Switch (the catch-all is valid as a last resort).
        let props = vec![switch_prop("CONNECTION"), switch_prop("OUTLET_1")];
        assert_eq!(
            classify_indi_device(&props, "Pegasus Powerbox", "indi_pegasus_upb"),
            Some(DeviceType::Switch),
        );
    }
}
