use crate::device_capabilities::driver::{camera_capabilities, mount_capabilities};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_id::cache::parse_device_id_cached;
use crate::error::SkotiqError;
use skotiq_device::{CameraDriver, DeviceKind, MountDriver};
use skotiq_indi::{IndiCamera, IndiMount};

/// Capabilities of an INDI camera or mount that has no handle, read through
/// its server's shared connection.
pub(crate) async fn get_indi_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    let parsed = parse_device_id_cached(device_id)?;
    let (host, port, device_name) = match &parsed.connection_info {
        crate::device_id::ConnectionInfo::Indi {
            host,
            port,
            device_name,
        } => (host.clone(), *port, device_name.clone()),
        _ => {
            return Err(SkotiqError::invalid_device_id(
                device_id,
                "Not an INDI device",
            ))
        }
    };

    let client = crate::device_manager::get_device_manager()
        .indi_server(&host, port)
        .await
        .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
    let kind = client.read().await.describe_device(&device_name).await.kind();
    match kind {
        Some(DeviceKind::Camera) => Ok(DeviceCapabilities::Camera(camera_capabilities(
            IndiCamera::new(client, &device_name).describe().await,
            None,
        ))),
        Some(DeviceKind::Mount) => {
            let mount = IndiMount::new(client, &device_name);
            let tracking = mount.get_tracking().await.ok();
            Ok(DeviceCapabilities::Mount(mount_capabilities(
                mount.describe().await,
                tracking,
            )))
        }
        // A focuser, wheel, rotator or dome answers through its handle once
        // connected (`read_capabilities`); an id that reaches here was never
        // registered.
        _ => Err(SkotiqError::not_supported(
            device_id,
            "Could not determine INDI device type from properties",
        )),
    }
}
