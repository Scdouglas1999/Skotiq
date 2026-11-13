use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

impl DeviceManager {
    pub async fn mount_set_tracking(
        &self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), DeviceOpError> {
        let result = self.mount_set_tracking_dispatch(device_id, enabled).await;

        // Record the commanded tracking state so an unplanned reconnect (USB /
        // serial yank mid-run) can re-apply it. A mount that comes back from a
        // reconnect is parked / not tracking; without this the sequence would
        // "resume" while the mount sits still. Only record on success so a
        // failed command does not clobber the last known good desired state.
        if result.is_ok() {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.desired_tracking = Some(enabled);
            }
            drop(devices);
            // The state change every UI shows (see `state_events`).
            let device_id = device_id.to_string();
            self.publish_state_event(if enabled {
                EquipmentEvent::MountTrackingStarted { device_id }
            } else {
                EquipmentEvent::MountTrackingStopped { device_id }
            });
        }

        result
    }

    /// Driver dispatch for `mount_set_tracking`. Split out so the public method
    /// can record the desired tracking state (for reconnect re-application)
    /// without holding the `devices` read lock across the per-driver calls.
    async fn mount_set_tracking_dispatch(
        &self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.set_tracking(enabled).await
    }

    pub async fn mount_pulse_guide(
        &self,
        device_id: &str,
        direction: String,
        duration_ms: u32,
    ) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        let direction_lower = direction.to_lowercase();
        let dir = match direction_lower.as_str() {
            "north" | "n" => skotiq_device::GuideDirection::North,
            "south" | "s" => skotiq_device::GuideDirection::South,
            "east" | "e" => skotiq_device::GuideDirection::East,
            "west" | "w" => skotiq_device::GuideDirection::West,
            _ => {
                return Err(DeviceOpError::invalid_parameter(format!(
                    "Invalid direction: {}",
                    direction
                )))
            }
        };

        mount.pulse_guide(dir, duration_ms).await
    }

    pub async fn mount_set_tracking_rate(
        &self,
        device_id: &str,
        rate: i32,
    ) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.set_tracking_rate(rate).await
    }

    pub async fn mount_get_tracking_rate(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.tracking_rate().await
    }
}
