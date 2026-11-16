use crate::device::DeviceType;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

/// What a camera takes its frames at when a frame does not name it: its
/// equipment profile's defaults. `None` leaves that control as the camera
/// has it, which happens only where the profile states no value or the
/// camera has no such control.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CameraFrameDefaults {
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    /// By the name the camera lists.
    pub readout_mode: Option<String>,
}

impl DeviceManager {
    // Each setter publishes the camera's settings once it accepted the value
    // (`CameraSettingsChanged`, see `state_events`), so every UI shows the new
    // setting without waiting for its next status poll.

    /// Set camera gain
    pub async fn camera_set_gain(&self, device_id: &str, gain: i32) -> Result<(), DeviceOpError> {
        self.camera_set_gain_dispatch(device_id, gain).await?;
        if !self.publish_camera_settings(device_id).await {
            self.publish_property_changed(
                DeviceType::Camera,
                device_id,
                property::GAIN,
                gain.to_string(),
            );
        }
        Ok(())
    }

    /// Set camera offset
    pub async fn camera_set_offset(
        &self,
        device_id: &str,
        offset: i32,
    ) -> Result<(), DeviceOpError> {
        self.camera_set_offset_dispatch(device_id, offset).await?;
        if !self.publish_camera_settings(device_id).await {
            self.publish_property_changed(
                DeviceType::Camera,
                device_id,
                property::OFFSET,
                offset.to_string(),
            );
        }
        Ok(())
    }

    /// State what `device_id` takes its frames at when the frame does not
    /// name it: the equipment profile's default gain, offset and read mode
    /// (by the name the camera lists), each `None` where the profile states
    /// none or the camera has no such control. Nothing is written to the
    /// camera here; each exposure sets them.
    pub fn camera_state_frame_defaults(&self, device_id: &str, defaults: CameraFrameDefaults) {
        let defaults = CameraFrameDefaults {
            readout_mode: defaults
                .readout_mode
                .map(|m| m.trim().to_string())
                .filter(|m| !m.is_empty()),
            ..defaults
        };
        tracing::info!(
            "Frame defaults stated for {device_id}: gain {:?}, offset {:?}, read mode {:?}",
            defaults.gain,
            defaults.offset,
            defaults.readout_mode
        );
        self.stated_frame_defaults
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(device_id.to_string(), defaults);
    }

    /// What is stated for `device_id`; nothing when no profile stated any.
    pub(crate) fn stated_frame_defaults(&self, device_id: &str) -> CameraFrameDefaults {
        self.stated_frame_defaults
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(device_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Before a frame: put the camera in the read mode named `mode`. The
    /// camera is written to only when it is in another mode. A mode the
    /// camera does not list is told to the user once and the frame is taken
    /// in the camera's own mode, which the frame records.
    pub(crate) async fn camera_use_readout_mode(
        &self,
        device_id: &str,
        mode: &str,
    ) -> Result<(), DeviceOpError> {
        use crate::device_manager::rig::camera::ReadModeUse;
        let camera = self.camera(device_id).await?;
        match camera.use_readout_mode(mode).await? {
            ReadModeUse::AlreadyIn | ReadModeUse::NoModes => {}
            ReadModeUse::Switched => {
                tracing::info!("Camera {device_id} switched to read mode {mode}");
                self.publish_property_changed(
                    DeviceType::Camera,
                    device_id,
                    property::READOUT_MODE,
                    mode.to_string(),
                );
            }
            ReadModeUse::NotListed(listed) => {
                let first = self
                    .unlisted_read_mode_notices
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert((device_id.to_string(), mode.to_ascii_lowercase()));
                if first {
                    let camera_name = self
                        .devices
                        .read()
                        .await
                        .get(device_id)
                        .map_or_else(|| device_id.to_string(), |d| d.info.shown_name());
                    self.publish_notice(
                        "Read mode not available",
                        format!(
                            "{camera_name} has no read mode named {mode}; it lists {}. Frames \
                             are taken in the mode the camera is in, which each frame records. \
                             Choose one of the camera's read modes in the equipment profile \
                             or in the exposure step.",
                            listed.join(", ")
                        ),
                    );
                }
            }
        }
        Ok(())
    }

    async fn camera_set_gain_dispatch(
        &self,
        device_id: &str,
        gain: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_gain for {} gain={}",
            device_id,
            gain
        );

        let camera = self.camera(device_id).await?;

        camera.set_gain(gain).await
    }

    async fn camera_set_offset_dispatch(
        &self,
        device_id: &str,
        offset: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_offset for {} offset={}",
            device_id,
            offset
        );

        let camera = self.camera(device_id).await?;

        camera.set_offset(offset).await
    }

    /// The setpoint that may accompany a cooler command.
    ///
    /// Switching a cooler **off** carries no setpoint: the TEC stops, and no
    /// temperature needs naming to make that happen. End-of-night warm-up and
    /// the `safe_rig` shutdown path are both `enabled = false` with no target,
    /// so this is the shape that matters.
    pub(crate) fn cooler_setpoint_to_command(
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Option<f64> {
        if enabled {
            target_temp
        } else {
            None
        }
    }

    /// Set camera cooler
    pub async fn camera_set_cooler(
        &self,
        device_id: &str,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let target_temp = Self::cooler_setpoint_to_command(enabled, target_temp);
        let result = self
            .camera_set_cooler_dispatch(device_id, enabled, target_temp)
            .await;

        // Record the commanded cooler state so an unplanned reconnect (USB yank
        // mid-run) can re-apply it. The driver comes back from a reconnect with
        // the cooler off and the setpoint cleared; without this the sensor
        // silently warms up while the sequence "resumes". Only record on a
        // successful command — a failed set must not overwrite the last known
        // good desired state.
        if result.is_ok() {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.desired_cooler = Some((enabled, target_temp));
            }
        }

        if result.is_ok() {
            if enabled {
                // A cooler switched on without a setpoint keeps the one the
                // camera holds; with neither there is no target to announce.
                let target = match target_temp {
                    Some(t) => Some(t),
                    None => self
                        .camera_get_status(device_id)
                        .await
                        .ok()
                        .and_then(|status| status.target_temp),
                };
                if let Some(target_temp) = target {
                    self.publish_state_event(EquipmentEvent::CameraCoolingStarted {
                        device_id: device_id.to_string(),
                        target_temp,
                    });
                }
            } else {
                self.publish_state_event(EquipmentEvent::CameraWarmingStarted {
                    device_id: device_id.to_string(),
                });
            }
        }

        result
    }

    /// Driver dispatch for `camera_set_cooler`. Split out so the public method
    /// can record the desired cooler state (for reconnect re-application)
    /// around the per-driver calls without threading the bookkeeping through
    /// every early-return arm.
    async fn camera_set_cooler_dispatch(
        &self,
        device_id: &str,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let camera = self.camera(device_id).await?;

        camera.set_cooler(enabled, target_temp).await
    }
}
