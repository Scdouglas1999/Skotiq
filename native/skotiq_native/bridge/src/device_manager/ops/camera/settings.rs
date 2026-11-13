use crate::device::DeviceType;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

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

    pub async fn camera_set_binning(
        &self,
        device_id: &str,
        bin_x: i32,
        bin_y: i32,
    ) -> Result<(), DeviceOpError> {
        self.camera_set_binning_dispatch(device_id, bin_x, bin_y)
            .await?;
        if !self.publish_camera_settings(device_id).await {
            self.publish_property_changed(
                DeviceType::Camera,
                device_id,
                property::BINNING,
                format!("{bin_x}x{bin_y}"),
            );
        }
        Ok(())
    }

    /// Set the camera readout mode by index.
    pub async fn camera_set_readout_mode(
        &self,
        device_id: &str,
        mode_index: i32,
    ) -> Result<(), DeviceOpError> {
        self.camera_set_readout_mode_dispatch(device_id, mode_index)
            .await?;
        self.publish_property_changed(
            DeviceType::Camera,
            device_id,
            property::READOUT_MODE,
            mode_index.to_string(),
        );
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

    async fn camera_set_binning_dispatch(
        &self,
        device_id: &str,
        bin_x: i32,
        bin_y: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_binning for {} bin={}x{}",
            device_id,
            bin_x,
            bin_y
        );

        if bin_x < 1 || bin_y < 1 {
            return Err(DeviceOpError::invalid_parameter(format!(
                "Invalid binning values: {}x{} (must be >= 1)",
                bin_x, bin_y
            )));
        }

        let camera = self.camera(device_id).await?;

        camera.set_binning(bin_x, bin_y).await
    }

    /// Set camera readout mode by index
    ///
    /// ASCOM: Sets the ReadoutMode property (integer index)
    /// Alpaca: Sets the readoutmode property (integer index)
    /// INDI: Sets the CCD_READ_MODE switch to the element at the given index
    /// Native: Delegates to CameraDriver::set_readout_mode with a synthetic ReadoutMode
    async fn camera_set_readout_mode_dispatch(
        &self,
        device_id: &str,
        mode_index: i32,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_set_readout_mode for {} mode_index={}",
            device_id,
            mode_index
        );

        let camera = self.camera(device_id).await?;

        camera.set_readout_mode(mode_index).await
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
