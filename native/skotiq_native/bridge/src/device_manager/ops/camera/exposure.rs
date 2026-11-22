use crate::device_manager::{rig, DeviceManager};
use crate::dispatch::error::DeviceOpError;
use skotiq_device::SubFrame;

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

        // A camera whose session broke refuses the start; it is reopened
        // and the start sent once more (`device_reopen`). Every exposure,
        // whoever asks for it, starts here.
        self.with_reopen(device_id, || async {
            let camera = self.camera(device_id).await?;
            let started = camera
                .start_exposure(
                    duration,
                    gain,
                    offset,
                    bin_x,
                    bin_y,
                    subframe.clone(),
                    frame_type,
                )
                .await;
            self.relay_camera_reports(device_id, camera.as_ref()).await;
            started
        })
        .await
    }

    /// Whether the exposure is done. A camera whose session broke during it
    /// (the ZWO SDK reports the exposure failed) is reopened before the
    /// failure is returned, so the caller's next exposure finds it whole.
    pub async fn camera_is_exposure_complete(
        &self,
        device_id: &str,
    ) -> Result<bool, DeviceOpError> {
        let camera = self.camera(device_id).await?;
        let result = camera.is_exposure_complete().await;
        if let Err(error) = &result {
            self.note_operation_failure(device_id, error);
            let failure = crate::device_manager::failure::DeviceFailure::from(error);
            if let Err(e) = Box::pin(self.reopen_after(device_id, &failure)).await {
                tracing::warn!("Reopen of {device_id} failed: {e}");
            }
        }
        result
    }

    pub async fn camera_abort_exposure(&self, device_id: &str) -> Result<(), DeviceOpError> {
        tracing::info!("DeviceManager: camera_abort_exposure for {}", device_id);

        let camera = self.camera(device_id).await?;

        rig::camera::abort(camera.as_ref()).await
    }
}
