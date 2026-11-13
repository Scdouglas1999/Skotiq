//! INDI driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide INDI-only logic: the shared server connections, device discovery,
//! connection and the per-device health check.

use crate::device::{DeviceInfo, DeviceType, DriverType, TrackingRate};
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::DeviceManager;
use skotiq_indi::names as indi;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// How every INDI discovery path lists a device: id, names and the kind the
/// INDI crate's classifier gave it.
pub(crate) fn indi_device_info(
    host: &str,
    port: u16,
    device: skotiq_indi::IndiDeviceInfo,
    serial_number: Option<String>,
) -> DeviceInfo {
    DeviceInfo {
        id: format!("indi:{}:{}:{}", host, port, device.name),
        name: device.name.clone(),
        device_type: DeviceType::from(device.kind),
        driver_type: DriverType::Indi,
        description: format!("INDI device on {}:{}", host, port),
        driver_version: "INDI".to_string(),
        unique_id: serial_number.clone(),
        serial_number,
        display_name: device.name,
    }
}

/// The handle for an INDI device, `None` for the device types that have none.
fn handle(
    info: &DeviceInfo,
    client: Arc<RwLock<skotiq_indi::IndiClient>>,
    device_name: &str,
) -> Option<DeviceHandle> {
    use crate::device_manager::rig::camera::indi::IndiCameraHandle;
    use crate::device_manager::rig::filter_wheel::IndiWheel;
    use crate::device_manager::rig::focuser::IndiFocuserHandle;
    use crate::device_manager::rig::mount::indi::IndiMountHandle;
    use skotiq_indi::{
        IndiCoverCalibrator, IndiDome, IndiFilterWheel, IndiRotator, IndiSafetyMonitor,
        IndiSwitchDevice, IndiWeather,
    };
    Some(match info.device_type {
        DeviceType::Camera => DeviceHandle::Camera(Arc::new(IndiCameraHandle::new(
            &info.id,
            client,
            device_name,
        ))),
        DeviceType::Mount => DeviceHandle::Mount(Arc::new(IndiMountHandle::new(
            &info.id,
            client,
            device_name,
        ))),
        DeviceType::Focuser => DeviceHandle::Focuser(Arc::new(IndiFocuserHandle::new(
            &info.id,
            client,
            device_name,
        ))),
        DeviceType::FilterWheel => DeviceHandle::FilterWheel(Arc::new(IndiWheel::new(
            &info.id,
            IndiFilterWheel::new(client, device_name),
        ))),
        DeviceType::Dome => DeviceHandle::Dome(Arc::new(IndiDome::new(client, device_name))),
        DeviceType::Rotator => {
            DeviceHandle::Rotator(Arc::new(IndiRotator::new(client, device_name)))
        }
        DeviceType::Switch => {
            DeviceHandle::Switch(Arc::new(IndiSwitchDevice::new(client, device_name)))
        }
        DeviceType::Weather => {
            DeviceHandle::Weather(Arc::new(IndiWeather::new(client, device_name)))
        }
        DeviceType::SafetyMonitor => {
            DeviceHandle::SafetyMonitor(Arc::new(IndiSafetyMonitor::new(client, device_name)))
        }
        DeviceType::CoverCalibrator => {
            DeviceHandle::CoverCalibrator(Arc::new(IndiCoverCalibrator::new(client, device_name)))
        }
        _ => return None,
    })
}

impl DeviceManager {
    pub(crate) fn parse_indi_device_id(device_id: &str) -> Result<(String, u16, String), String> {
        let parsed = crate::device_id::cache::parse_device_id_cached(device_id)
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
            .get_property(device_name, indi::TELESCOPE_TRACK_RATE)
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
                .get_switch(device_name, indi::TELESCOPE_TRACK_RATE, &element)
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

    pub(crate) async fn connect_indi(&self, info: &DeviceInfo) -> Result<(), String> {
        // Parse INDI device ID: indi:host:port:device_name
        let (host, port, device_name) = Self::parse_indi_device_id(&info.id)?;
        let server_key = format!("{host}:{port}");
        let client = self
            .indi_server(&host, port)
            .await
            .map_err(|e| e.to_string())?;

        // Use the client to connect the device
        let mut locked_client = client.write().await;

        // Enable BLOB for cameras
        if info.device_type == DeviceType::Camera {
            if let Err(e) = locked_client.enable_blob(&device_name).await {
                tracing::warn!("Failed to enable BLOB for {}: {}", device_name, e);
            }
        }

        locked_client
            .connect_and_confirm(&device_name)
            .await
            .map_err(|e| e.to_string())?;

        drop(locked_client);
        if let Some(handle) = handle(info, client, &device_name) {
            self.handles.insert(&info.id, handle);
        }

        tracing::info!(
            "Connected to INDI device: {} at {}",
            device_name,
            server_key
        );
        Ok(())
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

    /// The shared connection to the INDI server at `host:port`, opened on
    /// first use. Every device on one server goes through one connection.
    pub(crate) async fn indi_server(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Arc<RwLock<skotiq_indi::IndiClient>>, skotiq_indi::IndiError> {
        let server_key = format!("{host}:{port}");
        let mut clients = self.indi_clients.write().await;
        if let Some(client) = clients.get(&server_key) {
            return Ok(client.clone());
        }
        let mut client = skotiq_indi::IndiClient::new(host, Some(port));
        client.connect().await?;
        let client = Arc::new(RwLock::new(client));
        clients.insert(server_key, client.clone());
        Ok(client)
    }

    /// Discover INDI devices at a specific address
    pub async fn discover_indi_devices(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Vec<DeviceInfo>, String> {
        let client = self
            .indi_server(host, port)
            .await
            .map_err(|e| e.to_string())?;
        skotiq_indi::wait_for_definitions(&client, Duration::from_secs(5)).await;
        let devices = skotiq_indi::list_devices(&*client.read().await).await;
        Ok(devices
            .into_iter()
            .map(|device| indi_device_info(host, port, device, None))
            .collect())
    }

    /// Every device on the INDI servers already connected, without waiting
    /// for more definitions.
    pub async fn get_all_indi_devices(&self) -> Vec<DeviceInfo> {
        let clients: Vec<_> = self.indi_clients.read().await.values().cloned().collect();
        let mut all_devices = Vec::new();
        for client in clients {
            let client = client.read().await;
            let devices = skotiq_indi::list_devices(&client).await;
            all_devices.extend(
                devices
                    .into_iter()
                    .map(|device| indi_device_info(client.host(), client.port(), device, None)),
            );
        }
        all_devices
    }

    /// The shared server connection an INDI device id names, and the device's
    /// name on that server.
    async fn indi_device(
        &self,
        device_id: &str,
    ) -> Result<(Arc<RwLock<skotiq_indi::IndiClient>>, String), String> {
        let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
        let server_key = format!("{}:{}", host, port);
        let client = self
            .indi_clients
            .read()
            .await
            .get(&server_key)
            .cloned()
            .ok_or_else(|| format!("INDI client for {} not found", server_key))?;
        Ok((client, device_name))
    }

    /// The heartbeat of an INDI device that has no handle (camera, mount).
    pub(crate) async fn perform_indi_health_check(&self, device_id: &str) -> Result<bool, String> {
        let (client, device_name) = self.indi_device(device_id).await?;
        let healthy = client
            .write()
            .await
            .check_device(&device_name)
            .await
            .map_err(|e| e.to_string())?;
        Ok(healthy)
    }

    /// Disconnects an INDI device that has no handle (camera, mount) and
    /// waits for the driver to confirm it.
    pub(crate) async fn release_indi_device(&self, device_id: &str) -> Result<(), String> {
        let (client, device_name) = self.indi_device(device_id).await?;
        let released = client
            .write()
            .await
            .disconnect_and_confirm(&device_name)
            .await;
        released.map_err(|e| format!("Failed to disconnect INDI device {}: {}", device_name, e))
    }
}
