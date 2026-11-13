use crate::device_capabilities::driver::{camera_capabilities, mount_capabilities};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_id::cache::parse_device_id_cached;
use crate::error::SkotiqError;
use skotiq_device::{CameraDriver, MountDriver};

/// Capabilities of an Alpaca camera or mount that has no handle (it is not
/// connected through Skotiq), read through a client of its own. A device the
/// probe finds not connected is connected for the read and released after it;
/// one it finds connected, or cannot ask, is left as it is.
pub(crate) async fn get_alpaca_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    // Use cached parsing for better performance
    let parsed = parse_device_id_cached(device_id)?;
    let (_, _, _, device_type, device_num) = parsed
        .alpaca_info()
        .ok_or_else(|| SkotiqError::invalid_device_id(device_id, "Not an Alpaca device"))?;
    let base_url = parsed
        .alpaca_base_url()
        .ok_or_else(|| SkotiqError::invalid_device_id(device_id, "Missing base URL"))?;

    match device_type {
        "telescope" | "mount" => {
            let telescope = skotiq_alpaca::AlpacaTelescope::from_server(base_url, device_num);

            // probe-and-restore. If the driver is already connected
            // (e.g. the UI has the mount open), reuse the connection rather
            // than connect/disconnect-ing around the property reads, which
            // would kick the active session. `is_connected()` Err → assume
            // connected (fail-safe: never disconnect a session we can't prove
            // we opened).
            let was_connected = telescope.is_connected().await.unwrap_or(true);
            if !was_connected {
                telescope
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            }

            let mount = skotiq_alpaca::AlpacaMount::new(telescope);
            let caps = mount_capabilities(
                mount.describe().await,
                mount.telescope().tracking().await.ok(),
            );

            if !was_connected {
                mount.telescope().disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Mount(caps))
        }
        "camera" => {
            let camera = skotiq_alpaca::AlpacaCamera::from_server(base_url, device_num);

            // see top-level docblock. Reuse existing connection if
            // the driver already has it open.
            let was_connected = camera.is_connected().await.unwrap_or(true);
            if !was_connected {
                camera
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            }

            let camera = skotiq_alpaca::AlpacaCameraDriver::new(camera);
            let caps = camera_capabilities(camera.describe().await, None);

            if !was_connected {
                camera.camera().disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Camera(caps))
        }
        // These have a handle and answer through it once connected
        // (`read_capabilities`); an id that reaches here was never registered.
        "focuser" | "filterwheel" | "rotator" | "dome" | "covercalibrator"
        | "observingconditions" | "safetymonitor" | "switch" => {
            Err(SkotiqError::DeviceNotFound(device_id.to_string()))
        }
        _ => Err(SkotiqError::not_supported(device_id, "get_capabilities")),
    }
}
