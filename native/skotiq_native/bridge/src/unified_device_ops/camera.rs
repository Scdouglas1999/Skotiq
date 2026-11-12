use super::*;

#[async_trait]
impl CameraOps for UnifiedDeviceOps {
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let ExposureRequest {
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            subframe,
            frame_type,
        } = request;
        let _acquisition = claim_camera_acquisition(camera_id).await?;
        let acquisition_generation = exposure_abort_generation(camera_id).await;
        let native_frame_type = skotiq_device::FrameType::from_str_lenient(frame_type);
        tracing::info!(
            "Starting {:.1}s exposure on camera {}",
            duration_secs,
            camera_id
        );

        let mgr = get_device_manager();

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
                frame_type: match native_frame_type {
                    skotiq_device::FrameType::Dark => crate::device::FrameType::Dark,
                    skotiq_device::FrameType::Flat => crate::device::FrameType::Flat,
                    skotiq_device::FrameType::Bias => crate::device::FrameType::Bias,
                    skotiq_device::FrameType::DarkFlat => crate::device::FrameType::DarkFlat,
                    skotiq_device::FrameType::Light => crate::device::FrameType::Light,
                },
            },
        );

        let started_at = chrono::Utc::now();

        // Start the exposure. gain/offset are Option<i32>; None means "use the
        // camera's current value, don't change it" and is threaded through to
        // each driver branch so the setter is genuinely skipped — an
        // `unwrap_or(0)` here would silently command gain/offset 0.
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
        .inspect_err(|_e| {
            exposure.end(false, EventSeverity::Error);
        })
        .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;

        if let Err(e) = wait_for_camera_exposure_complete(
            camera_id,
            duration_secs,
            exposure_completion_timeout(duration_secs),
            acquisition_generation,
            &self.app_state,
            || async {
                mgr.camera_is_exposure_complete(camera_id)
                    .await
                    .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))
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
            exposure.end(false, EventSeverity::Error);
            return Err(e);
        }

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            exposure.end(false, EventSeverity::Info);
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
                exposure.end(false, EventSeverity::Info);
                return Err(DeviceError::Cancelled("Exposure cancelled".to_string()));
            }
            Ok(Err(e)) => {
                exposure.end(false, EventSeverity::Error);
                return Err(
                    match device_error(skotiq_sequencer::DeviceKind::Camera)(e) {
                        DeviceError::Failed(message) => {
                            DeviceError::Failed(format!("Failed to download image: {message}"))
                        }
                        other => other,
                    },
                );
            }
            Err(_) => {
                exposure.end(false, EventSeverity::Error);
                return Err(DeviceError::Timeout(format!(
                    "Image download on {} exceeded the {}s timeout — failing the frame so recovery can run",
                    camera_id,
                    crate::timeout_ops::Timeouts::image_download_large().as_secs()
                )));
            }
        };

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            exposure.end(false, EventSeverity::Info);
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
        let camera_status = match get_device_manager()
            .camera_get_status(camera_id).await {
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

            // Log validation warnings (don't fail, just inform user via logging)
            for warning in &validation.warnings {
                tracing::warn!("[CAMERA] Image validation warning: {}", warning);
            }

            // Fail on validation errors (corrupted/unusable images)
            if !validation.is_valid {
                let error = DeviceError::InvalidFrame(validation.errors.join("; "));
                tracing::error!("[CAMERA] {error}");
                exposure.end(false, EventSeverity::Error);
                return Err(error);
            }
        }
        let exposure_secs = if native_image.metadata.exposure_time > 0.0 {
            native_image.metadata.exposure_time
        } else {
            duration_secs
        };
        // The frame's gain and offset, decided here once for the file's cards,
        // its database row and the last-frame store alike.
        let gain = crate::device_manager::ops::camera::frame_setting(
            camera_status.as_ref().map(|status| status.can_set_gain),
            native_image.metadata.gain,
            gain,
        );
        let offset = crate::device_manager::ops::camera::frame_setting(
            camera_status.as_ref().map(|status| status.can_set_offset),
            native_image.metadata.offset,
            offset,
        );
        // The display, statistics and stars are ready in the store before the
        // exposure is announced complete, so whoever reacts to the event finds them.
        if let Err(e) = crate::last_frame::store(
            camera_id,
            crate::last_frame::RawFrame {
                width: native_image.width,
                height: native_image.height,
                data: native_image.data.clone(),
                bayer_pattern: native_image.bayer_pattern,
                camera_file: native_image.metadata.camera_file.clone(),
                exposure: crate::last_frame::ExposureRecord {
                    started_at,
                    exposure_secs,
                    gain,
                    offset,
                    temperature: native_image.metadata.temperature,
                    bits_per_pixel: native_image.bits_per_pixel,
                },
            },
            duration_secs,
        )
        .await
        {
            exposure.end(false, EventSeverity::Error);
            return Err(e.to_string().into());
        }

        let sensor_type = crate::last_frame::sensor_type(native_image.bayer_pattern.as_ref());

        exposure.end(true, EventSeverity::Info);

        // Why: log-only formatting; "unknown" when the
        // camera SDK did not surface a sensor-type string matches the UI
        // label used in the Equipment panel.
        tracing::info!(
            "Exposure complete: {}x{} image, {} sensor",
            native_image.width,
            native_image.height,
            sensor_type.as_deref().unwrap_or("unknown")
        );

        Ok(ImageData {
            width: native_image.width,
            height: native_image.height,
            data: native_image.data,
            bits_per_pixel: native_image.bits_per_pixel,
            exposure_secs,
            gain,
            offset,
            temperature: native_image.metadata.temperature,
            filter: None,
            timestamp: native_image.metadata.timestamp.timestamp(),
            sensor_type,
            color_filter: native_image.bayer_pattern,
            camera_file: native_image.metadata.camera_file,
        })
    }

    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()> {
        tracing::info!("Aborting exposure on camera {}", camera_id);

        mark_camera_exposure_aborted(camera_id).await;
        get_device_manager()
            .camera_abort_exposure(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))
    }

    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Camera {} cooler: enabled={}, target={}°C",
            camera_id,
            enabled,
            target_temp
        );

        // `DeviceManager::camera_set_cooler` publishes the cooling event.
        get_device_manager()
            .camera_set_cooler(camera_id, enabled, Some(target_temp))
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))
    }

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;

        status
            .sensor_temp
            .ok_or_else(|| "Temperature not available".into())
    }

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;

        status
            .cooler_power
            .ok_or_else(|| "Cooler power not available".into())
    }

    async fn camera_get_cooler_on(&self, camera_id: &str) -> DeviceResult<Option<bool>> {
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;
        Ok(status.cooler_on)
    }

    async fn camera_get_cooler_setpoint(&self, camera_id: &str) -> DeviceResult<Option<f64>> {
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;
        Ok(status
            .target_temp
            .filter(|_| status.cooler_on == Some(true)))
    }

    async fn camera_get_pixel_size_um(&self, camera_id: &str) -> DeviceResult<Option<(f64, f64)>> {
        let status = get_device_manager()
            .camera_get_status(camera_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Camera))?;

        // A driver with nothing to say reports 0.0 here, which is not a pitch —
        // writing it would tell a solver the sensor has zero-sized pixels.
        Ok(match (status.pixel_size_x, status.pixel_size_y) {
            (x, y) if x > 0.0 && y > 0.0 => Some((x, y)),
            _ => None,
        })
    }

    async fn camera_get_model(&self, camera_id: &str) -> DeviceResult<Option<String>> {
        Ok(connected_camera_label(camera_id).await)
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

    fn end(&mut self, success: bool, severity: EventSeverity) {
        self.ended = true;
        self.app_state
            .publish_imaging_event(ImagingEvent::ExposureComplete { success }, severity);
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
