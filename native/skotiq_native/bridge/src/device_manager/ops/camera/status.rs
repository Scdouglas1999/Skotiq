use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

impl DeviceManager {
    /// Read the camera's status. A reading whose sensor temperature or
    /// cooler power moved since the last one published for this camera goes
    /// out as `CameraTemperatureChanged` (see
    /// [`Self::publish_camera_temperature`]), so the host's own cooler poll
    /// is what every UI and linked client shows.
    pub async fn camera_get_status(
        &self,
        device_id: &str,
    ) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let result = self.camera_get_status_dispatch(device_id).await;
        self.note_status_read(device_id, &result);
        let status = result?;
        if let Some(temperature) = status.sensor_temp {
            self.publish_camera_temperature(device_id, temperature, status.cooler_power);
        }
        Ok(status)
    }

    /// Publish `CameraTemperatureChanged` when the reading differs from the
    /// last one published for the camera by 0.1 C or 1 % power (or power
    /// appears or goes away). A camera read many times a second (an exposure
    /// wait, the guider's loop) whose last digit flickers is published at
    /// most every 2 s unless it moved by 0.5 C. Non-finite readings are not
    /// published.
    pub(crate) fn publish_camera_temperature(
        &self,
        device_id: &str,
        temperature: f64,
        cooler_power: Option<f64>,
    ) {
        if !temperature.is_finite() {
            return;
        }
        let cooler_power = cooler_power.filter(|p| p.is_finite());
        {
            let mut published = self
                .published_temperatures
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            let now = std::time::Instant::now();
            if let Some((last_temp, last_power, at)) = published.get(device_id) {
                let temp_change = (last_temp - temperature).abs();
                let power_presence_changed = last_power.is_some() != cooler_power.is_some();
                let power_same = match (last_power, cooler_power) {
                    (Some(a), Some(b)) => (a - b).abs() < 1.0,
                    (None, None) => true,
                    _ => false,
                };
                if temp_change < 0.1 && power_same {
                    return;
                }
                let recent = now.duration_since(*at) < std::time::Duration::from_secs(2);
                if recent && temp_change < 0.5 && !power_presence_changed {
                    return;
                }
            }
            published.insert(device_id.to_string(), (temperature, cooler_power, now));
        }
        self.publish_state_event(EquipmentEvent::CameraTemperatureChanged {
            device_id: device_id.to_string(),
            temperature,
            cooler_power,
        });
    }

    async fn camera_get_status_dispatch(
        &self,
        device_id: &str,
    ) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let camera = self.camera(device_id).await?;

        camera.status().await
    }

    /// Query the camera's SDK for manufacturer-recommended gain/offset values.
    ///
    /// Only native vendor SDKs are queried — ASCOM/Alpaca/INDI do not expose
    /// per-camera unity gain through their protocols (ASCOM's
    /// `IntegerListSetting`-style enumeration only lists allowed values, not
    /// which one is "recommended"). For non-native drivers this returns an
    /// empty struct (all fields `None`).
    ///
    /// On native cameras, propagates the per-vendor implementation in
    /// [`skotiq_device::CameraDriver::get_recommended_settings`].
    /// A query failure is logged and reported up — callers must treat it as
    /// "no recommendation" rather than swallowing it.
    pub async fn camera_get_recommended_settings(
        &self,
        device_id: &str,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        let camera = self.camera(device_id).await?;

        camera.recommended_settings().await
    }
}
