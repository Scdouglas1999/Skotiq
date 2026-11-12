use super::*;

impl DeviceManager {
    // Camera control

    /// Start a camera exposure
    pub async fn camera_start_exposure(
        &self,
        device_id: &str,
        duration: f64,
        // `None` means "leave the camera's current gain/offset unchanged" — the
        // node did not specify one. It stays optional end-to-end so each driver
        // branch can skip the setter; collapsing `None` to `0` both masks the
        // real value and, on drivers that honor it, sets gain/offset to 0.
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError> {
        self.camera_start_exposure_configured(
            device_id, duration, gain, offset, bin_x, bin_y, None, frame_type,
        )
        .await
    }

    /// Start an exposure while preserving the complete per-frame acquisition
    /// contract, including a binned-pixel ROI when one was requested.
    #[allow(clippy::too_many_arguments)]
    pub async fn camera_start_exposure_configured(
        &self,
        device_id: &str,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<SubFrame>,
        frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "DeviceManager: camera_start_exposure for {} duration={}",
            device_id,
            duration
        );

        let camera = self.camera(device_id).await?;

        camera
            .start_exposure(duration, gain, offset, bin_x, bin_y, subframe, frame_type)
            .await
    }

    pub async fn camera_is_exposure_complete(
        &self,
        device_id: &str,
    ) -> Result<bool, DeviceOpError> {
        let camera = self.camera(device_id).await?;

        camera.is_exposure_complete().await
    }

    pub async fn camera_abort_exposure(&self, device_id: &str) -> Result<(), DeviceOpError> {
        tracing::info!("DeviceManager: camera_abort_exposure for {}", device_id);

        let camera = self.camera(device_id).await?;

        rig::camera::abort(camera.as_ref()).await
    }
}
