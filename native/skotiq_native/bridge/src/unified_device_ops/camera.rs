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
        let native_frame_type = skotiq_native::camera::FrameType::from_str_lenient(frame_type);
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

        // Publish ExposureStarted event
        self.app_state.publish_imaging_event(
            ImagingEvent::ExposureStarted {
                duration_secs,
                frame_type: match native_frame_type {
                    skotiq_native::camera::FrameType::Dark => crate::device::FrameType::Dark,
                    skotiq_native::camera::FrameType::Flat => crate::device::FrameType::Flat,
                    skotiq_native::camera::FrameType::Bias => crate::device::FrameType::Bias,
                    skotiq_native::camera::FrameType::DarkFlat => {
                        crate::device::FrameType::DarkFlat
                    }
                    skotiq_native::camera::FrameType::Light => crate::device::FrameType::Light,
                },
            },
            EventSeverity::Info,
        );

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
            subframe.map(|roi| skotiq_native::camera::SubFrame {
                start_x: roi.start_x,
                start_y: roi.start_y,
                width: roi.width,
                height: roi.height,
            }),
            native_frame_type,
        )
        .await
        .inspect_err(|_e| {
            // Publish failure event
            self.app_state.publish_imaging_event(
                ImagingEvent::ExposureComplete { success: false },
                EventSeverity::Error,
            );
        })
        .map_err(|e| format!("Exposure failed: {}", e))?;

        if let Err(e) = wait_for_camera_exposure_complete(
            camera_id,
            duration_secs,
            exposure_completion_timeout(duration_secs),
            acquisition_generation,
            &self.app_state,
            || async {
                mgr.camera_is_exposure_complete(camera_id)
                    .await
                    .map_err(|e| e.to_string())
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
            self.app_state.publish_imaging_event(
                ImagingEvent::ExposureComplete { success: false },
                EventSeverity::Error,
            );
            return Err(e);
        }

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            self.app_state.publish_imaging_event(
                ImagingEvent::ExposureComplete { success: false },
                EventSeverity::Info,
            );
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
            Ok(inner) => inner.map_err(|e| {
                self.app_state.publish_imaging_event(
                    ImagingEvent::ExposureComplete { success: false },
                    EventSeverity::Error,
                );
                format!("Failed to download image: {}", e)
            })?,
            Err(_) => {
                self.app_state.publish_imaging_event(
                    ImagingEvent::ExposureComplete { success: false },
                    EventSeverity::Error,
                );
                return Err(DeviceError::Timeout(format!(
                    "Image download on {} exceeded the {}s timeout — failing the frame so recovery can run",
                    camera_id,
                    crate::timeout_ops::Timeouts::image_download_large().as_secs()
                )));
            }
        };

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            self.app_state.publish_imaging_event(
                ImagingEvent::ExposureComplete { success: false },
                EventSeverity::Info,
            );
            return Err(DeviceError::Cancelled("Exposure cancelled".to_string()));
        }

        tracing::info!(
            "[EXPOSURE] Download complete: {}x{} ({} pixels)",
            native_image.width,
            native_image.height,
            native_image.data.len()
        );

        // Validate downloaded image data to catch corrupted/bad frames early
        // This prevents cascading failures in autofocus, plate solving, etc.
        {
            // Convert to skotiq_imaging ImageData for validation
            let img_for_validation = skotiq_imaging::ImageData::from_u16(
                native_image.width,
                native_image.height,
                1, // channels
                &native_image.data,
            );

            tracing::debug!("[EXPOSURE] Starting image validation...");

            // Ask the sensor where it clips. Saturation is meaningless without a
            // ceiling, and no constant can supply one: a driver that
            // right-justifies a 12-bit sensor clips at 4095 and an 8-bit
            // container (the SVBony RAW8 connect fallback) at 255, both far
            // under any 16-bit threshold, so without this every clipped frame
            // off those cameras passes in silence. Best-effort by design — a
            // driver that cannot answer its own status must not cost us the
            // frame, so failure just leaves the validator on the frame's own
            // clipping evidence.
            let sensor_max_adu = match api_get_camera_status(camera_id.to_string()).await {
                Ok(status) => Some(status.max_adu).filter(|&max_adu| max_adu > 0),
                Err(e) => {
                    tracing::debug!(
                        "[EXPOSURE] No sensor ceiling from {camera_id} ({e}); \
                         judging saturation from the frame alone"
                    );
                    None
                }
            };

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
                self.app_state.publish_imaging_event(
                    ImagingEvent::ExposureComplete { success: false },
                    EventSeverity::Error,
                );
                return Err(error);
            }
        }
        let (sensor_type, bayer_offset) = match &native_image.bayer_pattern {
            Some(pattern) => {
                let offset = match pattern {
                    skotiq_native::camera::BayerPattern::Rggb => (0, 0),
                    skotiq_native::camera::BayerPattern::Grbg => (1, 0),
                    skotiq_native::camera::BayerPattern::Gbrg => (0, 1),
                    skotiq_native::camera::BayerPattern::Bggr => (1, 1),
                };
                (Some("Color".to_string()), Some(offset))
            }
            None => (Some("Monochrome".to_string()), None),
        };

        // Store image in unified storage for UI access
        // This is critical - the Flutter UI calls api_get_last_image() to display captures
        {
            let is_color = bayer_offset.is_some();

            // Create ImageData for stretching
            let channels = if is_color { 3 } else { 1 };
            let image = skotiq_imaging::ImageData::from_u16(
                native_image.width,
                native_image.height,
                channels,
                &native_image.data,
            );

            // Apply auto-stretch to create display-ready data
            let display_data_raw = if is_color {
                // Color: debayer and stretch
                // Get bayer pattern from offset
                let bayer_pattern = match bayer_offset {
                    Some((0, 0)) => skotiq_imaging::BayerPattern::RGGB,
                    Some((1, 0)) => skotiq_imaging::BayerPattern::GRBG,
                    Some((0, 1)) => skotiq_imaging::BayerPattern::GBRG,
                    Some((1, 1)) => skotiq_imaging::BayerPattern::BGGR,
                    _ => skotiq_imaging::BayerPattern::RGGB, // Default
                };
                let rgb_data = skotiq_imaging::debayer_to_rgb16(
                    &native_image.data,
                    native_image.width,
                    native_image.height,
                    bayer_pattern,
                    skotiq_imaging::DebayerAlgorithm::Bilinear,
                );

                // Auto-stretch RGB
                use rayon::prelude::*;
                let rgb_pixels: Vec<f64> =
                    rgb_data.par_iter().map(|&v| v as f64 / 65535.0).collect();
                let mut sorted = rgb_pixels.clone();
                // Why: f64::partial_cmp is required because
                // f64 is PartialOrd, not Ord (NaN). Pixel data is already
                // bounded to [0.0, 1.0] by the `v / 65535.0` normalisation
                // above, so NaN cannot occur — the fallback is purely a
                // language requirement to satisfy the closure signature.
                sorted.par_sort_unstable_by(|a, b| {
                    a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal)
                });
                if sorted.is_empty() {
                    return Err("Empty image data for median calculation".into());
                }
                let median = median_from_sorted_f64(&sorted)
                    .ok_or_else(|| "Empty image data for median calculation".to_string())?;
                let unified_params = skotiq_imaging::StretchParams {
                    shadows: (median - 0.1).max(0.0),
                    highlights: (median + 0.3).min(1.0),
                    midtones: 0.5,
                };

                skotiq_imaging::apply_stretch_rgb(
                    &rgb_data,
                    native_image.width,
                    native_image.height,
                    &unified_params,
                )
            } else {
                // Grayscale: auto-stretch to u8
                let stretch_params = skotiq_imaging::auto_stretch_stf(&image);
                skotiq_imaging::apply_stretch(&image, &stretch_params)
            };

            // Calculate stats and histogram from pre-RGBA data
            let stats = skotiq_imaging::calculate_stats_u16(&image);
            let stars = skotiq_imaging::detect_stars(
                &image,
                &skotiq_imaging::StarDetectionConfig::default(),
            );
            // The same block the manual exposure paths publish, read out of the
            // stars this frame already detected: HFR, FWHM, eccentricity and the
            // star count all come from one detection, so a sequencer frame
            // answers `/api/camera/last-image` with everything a manual one
            // does. Building the struct here by hand is what published `hfr:
            // null` beside a real star count for every frame of a run.
            let frame_stats = crate::api::imaging::frame_stats_result(&stats, &stars);

            let mut histogram = vec![0u32; 256];
            for &pixel in &display_data_raw {
                histogram[pixel as usize] += 1;
            }

            // Convert to RGBA for Flutter rendering (parallel, fast in Rust)
            let display_data = crate::api::display_data_to_rgba(&display_data_raw, is_color);

            // Create and store the display result
            let display_result = CapturedImageResult {
                width: native_image.width,
                height: native_image.height,
                display_data,
                histogram,
                stats: frame_stats,
                exposure_time: duration_secs,
                timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                is_color,
            };

            let raw_info = RawImageInfo {
                width: native_image.width,
                height: native_image.height,
                data: native_image.data.clone(),
                sensor_type: sensor_type.clone(),
                bayer_offset,
            };

            store_captured_image_atomically(camera_id, display_result, raw_info).await;
            tracing::info!("Stored image in unified storage for UI display");
        }

        // Publish success event
        self.app_state.publish_imaging_event(
            ImagingEvent::ExposureComplete { success: true },
            EventSeverity::Info,
        );

        // Why: log-only formatting; "unknown" when the
        // camera SDK did not surface a sensor-type string matches the UI
        // label used in the Equipment panel.
        tracing::info!(
            "Exposure complete: {}x{} image, {} sensor",
            native_image.width,
            native_image.height,
            sensor_type.as_deref().unwrap_or("unknown")
        );

        // Convert to sequencer ImageData
        Ok(ImageData {
            width: native_image.width,
            height: native_image.height,
            data: native_image.data,
            bits_per_pixel: native_image.bits_per_pixel,
            exposure_secs: if native_image.metadata.exposure_time > 0.0 {
                native_image.metadata.exposure_time
            } else {
                duration_secs
            },
            // Blindly wrapping in Some() meant an unreadable gain/offset (which
            // the Alpaca/INDI paths recorded as a placeholder) presented as a real
            // measurement and short-circuited `image_data.gain.or(config.gain)`
            // downstream, so the placeholder beat the operator's configured value
            // and was written into the frame's FITS header. Mapping the
            // unknown marker back to None restores the intended fallback.
            gain: crate::device_manager::ops::camera::camera_setting_or_unknown(
                native_image.metadata.gain,
            ),
            offset: crate::device_manager::ops::camera::camera_setting_or_unknown(
                native_image.metadata.offset,
            ),
            temperature: native_image.metadata.temperature,
            filter: None,
            timestamp: native_image.metadata.timestamp.timestamp(),
            sensor_type,
            bayer_offset,
        })
    }

    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()> {
        tracing::info!("Aborting exposure on camera {}", camera_id);

        mark_camera_exposure_aborted(camera_id).await;
        get_device_manager()
            .camera_abort_exposure(camera_id)
            .await
            .map_err(|e| format!("Abort failed: {}", e).into())
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
        api_set_camera_cooler(camera_id.to_string(), enabled as u8, Some(target_temp))
            .await
            .map_err(|e| format!("Cooler control failed: {}", e).into())
    }

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;

        status
            .sensor_temp
            .ok_or_else(|| "Temperature not available".into())
    }

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;

        status
            .cooler_power
            .ok_or_else(|| "Cooler power not available".into())
    }

    async fn camera_get_cooler_on(&self, camera_id: &str) -> DeviceResult<Option<bool>> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;
        Ok(Some(status.cooler_on))
    }

    async fn camera_get_pixel_size_um(&self, camera_id: &str) -> DeviceResult<Option<(f64, f64)>> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;

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
