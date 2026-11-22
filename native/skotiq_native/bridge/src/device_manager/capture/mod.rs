//! Taking a camera frame: the one capture path of the host.

pub(crate) mod exposure_wait;

use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EventSeverity;
use crate::event::imaging::ImagingEvent;
use crate::state::SharedAppState;
use exposure_wait::{
    claim_camera_acquisition, exposure_abort_generation, exposure_completion_timeout,
    mark_camera_exposure_aborted, wait_for_camera_exposure_complete,
};
use skotiq_sequencer::{DeviceError, DeviceResult, ExposureRequest, ImageData};

/// What the sequencer is told about a failed operation on its `device`: the
/// same kind of failure, in the device layer's words.
pub(crate) fn sequencer_error<E: Into<DeviceOpError>>(
    device: skotiq_sequencer::DeviceKind,
) -> impl Fn(E) -> DeviceError {
    move |error| {
        let error = error.into();
        let message = error.to_string();
        match error {
            DeviceOpError::NotConnected { .. } => DeviceError::NotConnected { device, message },
            DeviceOpError::Unsupported { .. } => DeviceError::Unsupported(message),
            DeviceOpError::Timeout { .. } => DeviceError::Timeout(message),
            DeviceOpError::DeviceNotFound(_)
            | DeviceOpError::InvalidDeviceId { .. }
            | DeviceOpError::InvalidParameter { .. }
            | DeviceOpError::InvalidState { .. } => DeviceError::Rejected(message),
            DeviceOpError::SessionLost { .. } => DeviceError::SessionLost(message),
            DeviceOpError::Hardware { .. } | DeviceOpError::Message(_) => {
                DeviceError::Failed(message)
            }
        }
    }
}

impl DeviceManager {
    /// One frame from `request.camera_id`, the way every frame taker of the
    /// host gets it: the sensor claimed for the whole frame, the USB guard
    /// held, gain/offset/read mode from the request or the camera's stated
    /// defaults, the exposure announced, waited for, downloaded, validated and
    /// stored as the camera's last frame. When the camera was reopened while
    /// the frame failed (its session broke, [`DeviceManager::reopen_after`]),
    /// the frame is taken once more on the reopened camera.
    pub(crate) async fn capture(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let reopens = self.reopen_count(request.camera_id);
        match self.capture_once(request.clone()).await {
            Err(error) if self.reopen_count(request.camera_id) != reopens => {
                tracing::warn!(
                    "[EXPOSURE] {} was reopened after \"{error}\"; taking the frame again",
                    request.camera_id
                );
                self.capture_once(request).await
            }
            result => result,
        }
    }

    /// Stop the frame `camera_id` is taking. The abort generation moves
    /// first: it is what stops the frame's wait, and some SDKs report a
    /// finished exposure right after the stop, which must not be downloaded
    /// as a frame.
    pub(crate) async fn abort_capture(&self, camera_id: &str) -> Result<(), DeviceOpError> {
        mark_camera_exposure_aborted(camera_id).await;
        self.camera_abort_exposure(camera_id).await
    }

    /// [`Self::capture`] once: start, wait, download, validate.
    async fn capture_once(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let ExposureRequest {
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            subframe,
            frame_type,
            readout_mode,
        } = request;
        let _acquisition = claim_camera_acquisition(camera_id).await?;
        let acquisition_generation = exposure_abort_generation(camera_id).await;
        let native_frame_type = frame_type.taken_as();
        let mgr = self;

        // Gain, offset and read mode have one owner: what the frame names,
        // else what is stated for the camera (its profile's defaults). The
        // camera keeps its own value only where neither gives one, so a
        // frame never takes what an earlier frame left on the camera.
        let stated = mgr.stated_frame_defaults(camera_id);
        let gain = gain.or(stated.gain);
        let offset = offset.or(stated.offset);
        let readout_mode = readout_mode.map(str::to_string).or(stated.readout_mode);
        tracing::info!(
            "Starting {:.1}s exposure on camera {}: gain {}, offset {}, bin {}x{}",
            duration_secs,
            camera_id,
            gain.map_or_else(|| "as the camera has it".to_string(), |g| g.to_string()),
            offset.map_or_else(|| "as the camera has it".to_string(), |o| o.to_string()),
            bin_x,
            bin_y
        );

        // Mark the rig as USB-contended for the whole exposure+download window.
        // On shared-USB rigs (a ZWO EAF/EFW behind an ASI camera) the camera
        // saturates the bus during frame download, so an auxiliary device's
        // liveness poll loses the race and returns a transient failure — the
        // real cause of the spurious focuser/filter-wheel disconnects. While
        // this guard is alive the heartbeat loop SKIPS polls for the
        // focuser/filter-wheel/rotator (see `run_heartbeat_loop` /
        // `is_usb_contended`). The guard clears the marker when this function
        // returns — success, error, or panic — including every `?` early return
        // below, so it can never leak and permanently silence those heartbeats.
        let _usb_contention = mgr.begin_usb_contention();

        let mut exposure = AnnouncedExposure::start(
            &self.app_state,
            ImagingEvent::ExposureStarted {
                duration_secs,
                frame_type: native_frame_type,
            },
        );

        let started_at = chrono::Utc::now();

        if let Some(mode) = readout_mode {
            mgr.camera_use_readout_mode(camera_id, &mode)
                .await
                .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))
                .inspect_err(|e| exposure.fail(e))?;
        }

        // A gain or offset still `None` here is skipped by each driver, never
        // sent as 0.
        mgr.camera_start_exposure_configured(
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            subframe.map(|roi| skotiq_device::SubFrame {
                start_x: roi.start_x,
                start_y: roi.start_y,
                width: roi.width,
                height: roi.height,
            }),
            native_frame_type,
        )
        .await
        .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))
        .inspect_err(|e| exposure.fail(e))?;

        if let Err(e) = wait_for_camera_exposure_complete(
            camera_id,
            duration_secs,
            exposure_completion_timeout(duration_secs),
            acquisition_generation,
            &self.app_state,
            || async {
                mgr.camera_is_exposure_complete(camera_id)
                    .await
                    .map_err(sequencer_error(skotiq_sequencer::DeviceKind::Camera))
            },
        )
        .await
        {
            // The wait failed (status-poll error or the completion deadline)
            // while the camera is still physically exposing. Abort it so the
            // sensor is left idle — otherwise the sequencer's retry races a
            // still-running exposure and fails with "exposure already in
            // progress". Abort is best-effort; the original error is returned.
            let _ = mgr.camera_abort_exposure(camera_id).await;
            exposure.fail(&e);
            return Err(e);
        }

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            exposure.cancel();
            return Err(DeviceError::Cancelled("Exposure cancelled".to_string()));
        }

        // Download image under a hard ceiling so a stalled download cannot
        // hang the whole sequence indefinitely. A USB stall / hub brown-out /
        // contention on the shared vendor SDK mutex makes the download block;
        // bounding it turns "hang until morning" into a recoverable node
        // failure that the disconnect/recovery path can act on.
        //
        // NOTE: tokio's timeout cancels at an await point. It reliably fires
        // for stalls that yield (lock contention, the shared-mutex cascade,
        // late-returning USB calls). A vendor FFI call that blocks the worker
        // thread and literally never returns cannot be force-cancelled here —
        // fully isolating that would require running the blocking SDK call on
        // spawn_blocking inside each vendor driver, which is tracked
        // separately as it needs on-hardware validation per SDK.
        let native_image = match tokio::time::timeout(
            crate::timeout_ops::Timeouts::image_download_large(),
            mgr.camera_download_image(camera_id),
        )
        .await
        {
            Ok(Ok(image)) => image,
            // An abort releases the download at once; that is a cancelled
            // exposure, not a failed one.
            Ok(Err(_)) if exposure_abort_generation(camera_id).await != acquisition_generation => {
                exposure.cancel();
                return Err(DeviceError::Cancelled("Exposure cancelled".to_string()));
            }
            Ok(Err(e)) => {
                let error = match sequencer_error(skotiq_sequencer::DeviceKind::Camera)(e) {
                    error @ (DeviceError::Failed(_) | DeviceError::SessionLost(_)) => {
                        error.context("Failed to download image")
                    }
                    other => other,
                };
                exposure.fail(&error);
                return Err(error);
            }
            Err(_) => {
                let error = DeviceError::Timeout(format!(
                    "Image download on {} exceeded the {}s timeout — failing the frame so recovery can run",
                    camera_id,
                    crate::timeout_ops::Timeouts::image_download_large().as_secs()
                ));
                exposure.fail(&error);
                return Err(error);
            }
        };

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            exposure.cancel();
            return Err(DeviceError::Cancelled("Exposure cancelled".to_string()));
        }

        tracing::info!(
            "[EXPOSURE] Download complete: {}x{} ({} pixels)",
            native_image.width,
            native_image.height,
            native_image.data.len()
        );

        // What the camera says of itself: where it clips, and whether it has
        // gain and offset controls. Best-effort by design: a driver that cannot
        // answer its own status must not cost us the frame.
        let camera_status = match self.camera_get_status(camera_id).await {
            Ok(status) => Some(status),
            Err(e) => {
                tracing::debug!(
                    "[EXPOSURE] No status from {camera_id} ({e}); judging saturation from \
                     the frame alone and keeping its gain and offset as reported"
                );
                None
            }
        };

        // Validate downloaded image data to catch corrupted/bad frames early
        // This prevents cascading failures in autofocus, plate solving, etc.
        {
            let img_for_validation = skotiq_imaging::ImageData::from_u16(
                native_image.width,
                native_image.height,
                1, // channels
                &native_image.data,
            );

            tracing::debug!("[EXPOSURE] Starting image validation...");

            // Saturation is meaningless without a ceiling, and no constant can
            // supply one: a driver that right-justifies a 12-bit sensor clips
            // at 4095 and an 8-bit container (the SVBony RAW8 connect fallback)
            // at 255, both far under any 16-bit threshold, so without this
            // every clipped frame off those cameras passes in silence.
            let sensor_max_adu = camera_status
                .as_ref()
                .map(|status| status.max_adu)
                .filter(|&max_adu| max_adu > 0);

            // Use comprehensive validation - bias frames (very short exposures) are allowed to have uniform data
            let is_bias_frame = duration_secs < 0.1; // Bias frames are typically < 100ms
            let validation = skotiq_imaging::validate_image_comprehensive(
                &img_for_validation,
                skotiq_imaging::ImageValidationOptions {
                    expected_width: Some(native_image.width),
                    expected_height: Some(native_image.height),
                    is_bias_frame,
                    sensor_max_adu,
                    ..Default::default()
                },
            );

            tracing::debug!(
                "[EXPOSURE] Validation complete: valid={}",
                validation.is_valid
            );

            for warning in &validation.warnings {
                tracing::warn!("[CAMERA] Image validation warning: {}", warning);
            }
            // A dark or bias frame is meant to have no signal.
            if matches!(
                native_frame_type,
                skotiq_device::FrameType::Light | skotiq_device::FrameType::Flat
            ) {
                mgr.note_frame_signal(camera_id, duration_secs, validation.below_signal_floor)
                    .await;
            }

            // Fail on validation errors (corrupted/unusable images)
            if !validation.is_valid {
                let error = DeviceError::InvalidFrame(validation.errors.join("; "));
                tracing::error!("[CAMERA] {error}");
                exposure.fail(&error);
                return Err(error);
            }
        }
        // What the camera layer knows of the frame beside the camera's report:
        // when the exposure started, its length where the camera did not say,
        // and the gain and offset, decided here once for the file's cards, its
        // database row and the last-frame store alike.
        let mut frame = native_image;
        frame.metadata.timestamp = started_at;
        if frame.metadata.exposure_time <= 0.0 {
            frame.metadata.exposure_time = duration_secs;
        }
        frame.metadata.gain = crate::device_manager::ops::camera::frame_setting(
            camera_status.as_ref().map(|status| status.can_set_gain),
            frame.metadata.gain,
            gain,
        );
        frame.metadata.offset = crate::device_manager::ops::camera::frame_setting(
            camera_status.as_ref().map(|status| status.can_set_offset),
            frame.metadata.offset,
            offset,
        );
        // The display, statistics and stars are ready in the store before the
        // exposure is announced complete, so whoever reacts to the event finds them.
        if let Err(e) = crate::last_frame::store(camera_id, frame.clone(), duration_secs).await {
            let error: DeviceError = e.to_string().into();
            exposure.fail(&error);
            return Err(error);
        }

        exposure.complete();

        tracing::info!(
            "Exposure complete: {}x{} {} image",
            frame.width,
            frame.height,
            if frame.bayer_pattern.is_some() {
                "color"
            } else {
                "monochrome"
            }
        );

        Ok(frame)
    }
}

/// An exposure whose start was announced on the event stream. It announces
/// the end exactly once: `end` on every path that finishes the frame, and on
/// drop when the caller gave up on it mid-exposure (a stopped run drops the
/// exposure future), so no screen is left showing a camera still exposing.
struct AnnouncedExposure<'a> {
    app_state: &'a SharedAppState,
    ended: bool,
}

impl<'a> AnnouncedExposure<'a> {
    fn start(app_state: &'a SharedAppState, started: ImagingEvent) -> Self {
        app_state.publish_imaging_event(started, EventSeverity::Info);
        Self {
            app_state,
            ended: false,
        }
    }

    /// The frame is downloaded and stored.
    fn complete(&mut self) {
        self.ended = true;
        self.app_state.publish_imaging_event(
            ImagingEvent::ExposureComplete { success: true },
            EventSeverity::Info,
        );
    }

    /// The exposure failed for the reason [`DeviceError`] gives.
    fn fail(&mut self, error: &DeviceError) {
        self.ended = true;
        self.app_state.publish_imaging_event(
            ImagingEvent::ExposureFailed {
                error: error.to_string(),
            },
            EventSeverity::Error,
        );
    }

    /// The operator aborted the exposure.
    fn cancel(&mut self) {
        self.ended = true;
        self.app_state
            .publish_imaging_event(ImagingEvent::ExposureCancelled, EventSeverity::Info);
    }
}

impl Drop for AnnouncedExposure<'_> {
    fn drop(&mut self) {
        if !self.ended {
            self.app_state
                .publish_imaging_event(ImagingEvent::ExposureCancelled, EventSeverity::Info);
        }
    }
}
