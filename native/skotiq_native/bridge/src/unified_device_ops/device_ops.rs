use super::*;

#[async_trait]
impl DeviceOps for UnifiedDeviceOps {
    // Connection / recovery
    //
    // These two overrides are what make device-disconnect recovery actually
    // work on the live path. Without them the trait defaults
    // (`device_ops.rs`) return `Err("not supported")`, so the
    // `DeviceDisconnected` recovery loop fails instantly on every driver and a
    // USB/comms blip aborts the night. They delegate straight to the
    // `DeviceManager` primitives.

    async fn device_is_connected(&self, device_id: &str) -> DeviceResult<bool> {
        Ok(get_device_manager().is_connected(device_id).await)
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        // Mark the device auto-reconnectable so the background reconnection
        // loop keeps retrying it too (camera/focuser/filter-wheel default to
        // false), then drive an immediate connect attempt. Both together make
        // recovery actively reconnect instead of waiting out the budget.
        get_device_manager()
            .set_auto_reconnect(device_id, true)
            .await;
        get_device_manager().connect_device(device_id).await
    }

    // Mount operations

    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Slewing mount {} to RA={:.4}h Dec={:.4}°",
            mount_id,
            ra_hours,
            dec_degrees
        );

        // Emit slew started event
        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::Equipment(EquipmentEvent::MountSlewStarted {
                ra: ra_hours,
                dec: dec_degrees,
            }),
        ));

        let result = get_device_manager()
            .mount_slew(mount_id, ra_hours, dec_degrees)
            .await
            .map_err(|e| format!("Slew failed: {}", e));

        // The driver returning means the slew has started, not finished: the
        // completion event waits for the mount to arrive.
        if result.is_ok() {
            spawn_slew_completion_watch(
                self.app_state.clone(),
                mount_id.to_string(),
                ra_hours,
                dec_degrees,
            )
            .await;
        }

        result
    }

    async fn mount_slew_state(&self, mount_id: &str) -> skotiq_sequencer::slew_arrival::SlewSample {
        match get_device_manager().mount_get_status(mount_id).await {
            Ok(status) => skotiq_sequencer::slew_arrival::SlewSample {
                slewing: Some(status.slewing),
                position: Some((status.right_ascension, status.declination)),
            },
            Err(e) => {
                tracing::debug!("Slew status read for {} failed: {}", mount_id, e);
                skotiq_sequencer::slew_arrival::SlewSample {
                    slewing: None,
                    position: None,
                }
            }
        }
    }

    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Aborting slew for mount {}", mount_id);

        get_device_manager()
            .mount_abort(mount_id)
            .await
            .map_err(|e| format!("Abort slew failed: {}", e))
    }

    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok((status.right_ascension, status.declination))
    }

    async fn mount_readback_frame(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        // Mirror `DeviceManager::mount_slew`/`mount_sync` exactly — the same
        // `epoch::j2000_to_mount_frame` decision, simulator frame included:
        // whatever transform is applied on the way TO the mount has to be
        // applied to a target before it is compared with what the mount reads
        // BACK. If these two ever disagree, a correct slew reports as a miss by
        // the precession offset.
        let driver_type = get_device_manager()
            .get_device(mount_id)
            .await
            .map(|device| device.info.driver_type);

        Ok(match driver_type {
            // An unknown device id is not a licence to guess: report the target
            // unchanged and let the caller's own error path say the mount is
            // missing, rather than inventing a precessed position for it.
            None => (ra_hours, dec_degrees),
            Some(driver_type) => crate::device_manager::epoch::j2000_to_mount_frame(
                driver_type,
                ra_hours,
                dec_degrees,
            ),
        })
    }

    async fn mount_readback_to_j2000(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        let driver_type = get_device_manager()
            .get_device(mount_id)
            .await
            .map(|device| device.info.driver_type)
            .ok_or_else(|| format!("mount {mount_id} is not registered"))?;
        Ok(crate::device_manager::epoch::mount_frame_to_j2000(
            driver_type,
            ra_hours,
            dec_degrees,
        ))
    }

    async fn mount_sync(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Syncing mount {} to RA={:.4}h Dec={:.4}°",
            mount_id,
            ra_hours,
            dec_degrees
        );

        get_device_manager()
            .mount_sync(mount_id, ra_hours, dec_degrees)
            .await
            .map_err(|e| format!("Sync failed: {}", e))
    }

    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Parking mount {}", mount_id);

        // Emit park started event
        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::Equipment(EquipmentEvent::MountParkStarted),
        ));

        let result = get_device_manager()
            .mount_park(mount_id)
            .await
            .map_err(|e| format!("Park failed: {}", e));

        if result.is_ok() {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::MountParkCompleted),
            ));
        }

        result
    }

    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Unparking mount {}", mount_id);

        let result = get_device_manager()
            .mount_unpark(mount_id)
            .await
            .map_err(|e| format!("Unpark failed: {}", e));

        if result.is_ok() {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::MountUnparked),
            ));
        }

        result
    }

    async fn mount_find_home(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Homing mount {}", mount_id);

        get_device_manager()
            .mount_find_home(mount_id)
            .await
            .map_err(|e| format!("Home failed: {}", e))
    }

    async fn mount_is_at_home(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        status
            .at_home
            .ok_or_else(|| "Mount does not report whether it is at home".to_string())
    }

    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(status.slewing)
    }

    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        parked_from_status(mount_id, &status)
    }

    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        if !status.can_slew {
            return Ok(false);
        }
        // None (couldn't read or unsupported) collapses to Unknown — both
        // prevent the sequencer from issuing a meridian flip.
        match status.side_of_pier {
            None | Some(crate::device::PierSide::Unknown) => Err(
                "Mount does not report side-of-pier state; flip capability cannot be determined"
                    .to_string(),
            ),
            Some(_) => Ok(true),
        }
    }

    async fn mount_side_of_pier(
        &self,
        mount_id: &str,
    ) -> DeviceResult<skotiq_sequencer::meridian::PierSide> {
        // Get pier side from mount status. None collapses to Unknown so the
        // meridian module receives a single "indeterminate" signal.
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(match status.side_of_pier {
            Some(crate::device::PierSide::East) => skotiq_sequencer::meridian::PierSide::East,
            Some(crate::device::PierSide::West) => skotiq_sequencer::meridian::PierSide::West,
            Some(crate::device::PierSide::Unknown) | None => {
                skotiq_sequencer::meridian::PierSide::Unknown
            }
        })
    }

    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(status.tracking)
    }

    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()> {
        tracing::info!(
            "Setting tracking {} for mount {}",
            if enabled { "on" } else { "off" },
            mount_id
        );

        get_device_manager()
            .mount_set_tracking(mount_id, enabled)
            .await
            .map_err(|e| format!("Set tracking failed: {}", e))
    }

    // Camera operations

    async fn camera_start_exposure(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
    ) -> DeviceResult<ImageData> {
        // Frame-type-agnostic entry point → Light (shutter open). Dark/bias is
        // carried by the frame-type-aware method below (shared body).
        self.camera_start_exposure_configured(
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            None,
            "Light",
        )
        .await
    }

    async fn camera_start_exposure_with_frame_type(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        frame_type: &str,
    ) -> DeviceResult<ImageData> {
        self.camera_start_exposure_configured(
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            None,
            frame_type,
        )
        .await
    }

    async fn camera_start_exposure_configured(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<CameraSubframe>,
        frame_type: &str,
    ) -> DeviceResult<ImageData> {
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
            return Err("Exposure cancelled".to_string());
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
                return Err(format!(
                    "Image download on {} exceeded the {}s timeout — failing the frame so recovery can run",
                    camera_id,
                    crate::timeout_ops::Timeouts::image_download_large().as_secs()
                ));
            }
        };

        if exposure_abort_generation(camera_id).await != acquisition_generation {
            self.app_state.publish_imaging_event(
                ImagingEvent::ExposureComplete { success: false },
                EventSeverity::Info,
            );
            return Err("Exposure cancelled".to_string());
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
                let error_msg = validation.errors.join("; ");
                tracing::error!("[CAMERA] {IMAGE_VALIDATION_FAILED_PREFIX}{error_msg}");
                self.app_state.publish_imaging_event(
                    ImagingEvent::ExposureComplete { success: false },
                    EventSeverity::Error,
                );
                return Err(format!("{IMAGE_VALIDATION_FAILED_PREFIX}{error_msg}"));
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
                    return Err("Empty image data for median calculation".to_string());
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
            .map_err(|e| format!("Abort failed: {}", e))
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

        // Emit cooling event
        if enabled {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::CameraCoolingStarted { target_temp }),
            ));
        } else {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::CameraWarmingStarted),
            ));
        }

        api_set_camera_cooler(camera_id.to_string(), enabled as u8, Some(target_temp))
            .await
            .map_err(|e| format!("Cooler control failed: {}", e))
    }

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;

        status
            .sensor_temp
            .ok_or_else(|| "Temperature not available".to_string())
    }

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        let status = api_get_camera_status(camera_id.to_string())
            .await
            .map_err(|e| format!("Failed to get camera status: {}", e))?;

        status
            .cooler_power
            .ok_or_else(|| "Cooler power not available".to_string())
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

    // Focuser operations

    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("Moving focuser {} to position {}", focuser_id, position);

        // Emit focuser move started event
        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::Equipment(EquipmentEvent::FocuserMoveStarted {
                target_position: position,
            }),
        ));

        let result = api_focuser_move_to(focuser_id.to_string(), position)
            .await
            .map_err(|e| format!("Focuser move failed: {}", e));

        if result.is_ok() {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::FocuserMoveCompleted { position }),
            ));
        }

        result
    }

    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .focuser_get_position(focuser_id)
            .await
            .map_err(|e| format!("Get position failed: {}", e))
    }

    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool> {
        get_device_manager()
            .focuser_is_moving(focuser_id)
            .await
            .map_err(|e| format!("Is moving failed: {}", e))
    }

    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>> {
        get_device_manager()
            .focuser_get_temp(focuser_id)
            .await
            .map_err(|e| format!("Get temperature failed: {}", e))
    }

    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()> {
        get_device_manager()
            .focuser_halt(focuser_id)
            .await
            .map_err(|e| format!("Halt failed: {}", e))
    }

    // Filter wheel operations

    async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> DeviceResult<()> {
        // Get current position for the event
        // Why: from_position is purely informational
        // for the FilterChanging event payload. If the current position
        // read fails (filter wheel mid-move, or wheel just reconnected
        // and hasn't homed yet), `-1` is the documented "position unknown"
        // sentinel consumed by the UI. The actual move-to-position call
        // below propagates its own errors via `.map_err`.
        let from_position = get_device_manager()
            .filter_wheel_get_position(fw_id)
            .await
            .unwrap_or(-1);

        // Emit filter changing event
        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::Equipment(EquipmentEvent::FilterChanging {
                from_position,
                to_position: position,
                filter_name: None, // Will be populated by UI if available
            }),
        ));

        let result = get_device_manager()
            .filter_wheel_set_position(fw_id, position)
            .await
            .map_err(|e| format!("Set position failed: {}", e));

        if result.is_ok() {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::FilterChanged {
                    position,
                    filter_name: None,
                }),
            ));
        }

        result
    }

    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .filter_wheel_get_position(fw_id)
            .await
            .map_err(|e| format!("Get position failed: {}", e))
    }

    async fn filterwheel_get_names(&self, fw_id: &str) -> DeviceResult<Vec<String>> {
        let (_, names) = get_device_manager()
            .filter_wheel_get_config(fw_id)
            .await
            .map_err(|e| format!("Get names failed: {}", e))?;
        Ok(names)
    }

    async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> DeviceResult<i32> {
        let names = self.filterwheel_get_names(fw_id).await?;

        // Find the filter position by name (case-insensitive)
        let index = find_filter_match(&names, name)
            .ok_or_else(|| format!("Filter '{}' not found", name))?;

        // Pass Skotiq's canonical 0-based index for EVERY driver. The INDI
        // path (DeviceManager::filter_wheel_set_position -> IndiFilterWheel::
        // set_position) already takes a 0-based index and converts it to the
        // driver's native wire slot (0- or 1-based, auto-detected). The previous
        // INDI-only `index + 1` therefore double-counted the slot base, shifting
        // every filter by one and running the last filter off the end of the wheel.
        let position = index as i32;

        self.filterwheel_set_position(fw_id, position).await?;
        Ok(position)
    }

    // Rotator operations

    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} to {}°", rotator_id, angle);

        // Emit rotator move started event
        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::Equipment,
            EventPayload::Equipment(EquipmentEvent::RotatorMoveStarted {
                target_angle: angle,
            }),
        ));

        let result = api_rotator_move_to(rotator_id.to_string(), angle)
            .await
            .map_err(|e| format!("Rotator move failed: {}", e));

        if result.is_ok() {
            self.app_state.publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::Equipment,
                EventPayload::Equipment(EquipmentEvent::RotatorMoveCompleted { angle }),
            ));
        }

        result
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        tracing::info!("Moving rotator {} by {}°", rotator_id, delta);

        api_rotator_move_relative(rotator_id.to_string(), delta)
            .await
            .map_err(|e| format!("Rotator move relative failed: {}", e))
    }

    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64> {
        let status = api_get_rotator_status(rotator_id.to_string())
            .await
            .map_err(|e| format!("Failed to get rotator status: {}", e))?;

        Ok(status.position)
    }

    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()> {
        tracing::info!("Halting rotator {}", rotator_id);

        api_rotator_halt(rotator_id.to_string())
            .await
            .map_err(|e| format!("Halt failed: {}", e))
    }

    // Guiding / PHD2 operations

    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Dithering {} pixels (settle: <{}px in {}s)",
            pixels,
            settle_pixels,
            settle_time
        );

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        api_guider_dither(
            guider_id,
            pixels,
            ra_only as u8,
            settle_pixels,
            settle_time,
            settle_timeout,
        )
        .await
        .map_err(|e| format!("Dither failed: {}", e))
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(|e| format!("Failed to get guiding status: {}", e))?;

        Ok(GuidingStatus {
            is_guiding: status.state == "Guiding",
            rms_ra: status.rms_ra,
            rms_dec: status.rms_dec,
            rms_total: status.rms_total,
        })
    }

    async fn guider_is_active(&self) -> DeviceResult<bool> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(|e| format!("Failed to get guiding status: {}", e))?;
        Ok(guider_state_may_move_mount(&status.state))
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        let calib = crate::api::phd2::api_guider_get_calibration(guider_id)
            .await
            .map_err(|e| format!("Failed to get guider calibration: {}", e))?;
        Ok(GuidingCalibration {
            is_calibrated: calib.is_calibrated,
            ra_angle_deg: calib.ra_angle,
            dec_angle_deg: calib.dec_angle,
        })
    }

    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()> {
        tracing::info!("Starting guiding");

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        api_guider_start_guiding(guider_id, settle_pixels, settle_time, settle_timeout)
            .await
            .map_err(|e| format!("Start guiding failed: {}", e))
    }

    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        crate::api::phd2::select_fresh_guide_star(&guider_id, None)
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn guider_select_fresh_star_above(
        &self,
        floor: skotiq_sequencer::GuideStarFloor,
    ) -> DeviceResult<()> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        crate::api::phd2::select_fresh_guide_star(&guider_id, Some(floor))
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    async fn guider_star_quality(
        &self,
    ) -> DeviceResult<Option<skotiq_sequencer::GuideStarQuality>> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(|e| format!("Failed to get guiding status: {}", e))?;
        Ok((status.snr > 0.0 && status.star_mass > 0.0).then_some(
            skotiq_sequencer::GuideStarQuality {
                snr: status.snr,
                star_mass: status.star_mass,
            },
        ))
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        tracing::info!("Stopping guiding");

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or_else(|| "No active guider configured".to_string())?;
        crate::api::phd2::guider_stop_for_run(guider_id)
            .await
            .map_err(|e| format!("Stop guiding failed: {}", e))
    }

    async fn guider_note_stop_reason(&self, reason: Option<skotiq_sequencer::GuidingStopReason>) {
        crate::api::phd2::set_guiding_stop_reason(reason);
    }

    // Plate solving

    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        tracing::info!("Plate solving image");

        let temp_file = create_unique_temp_fits_path("skotiq_platesolve_temp");
        let temp_path = temp_file.to_string_lossy().to_string();

        // The optics, so the solver is told the field scale instead of hunting
        // for it. With `focal_length` and the pixel pitch left as None, ASTAP
        // gets a header with no scale information and falls back to sweeping
        // the field of view downward from ~9.5°. Observed live on a 0.37°
        // field: one run reached the bottom rung and solved in 0.3 s (still
        // warning "scale was inaccurate"), and the next three never converged
        // and exited non-zero on all five centering attempts. Same code, same
        // catalogs, same sensor — the only variable was whether the blind
        // sweep happened to land.
        //
        // Gathered by the shared helper so this is the same header every other
        // production solve path writes.
        let scale = crate::api::plate_solve::gather_solve_hints().await;
        scale.log_scale("Plate solve");
        let focal_length_mm = scale.hints.focal_length_mm;
        let pixel_size = scale.hints.pixel_size_um;
        let binning = scale.hints.binning;
        // The header is written for ASTAP to read; the same number also goes
        // out as an explicit `-fov` argument, because a header card is a hope
        // and an argument is an instruction. `hint_scale` from the caller wins
        // when it is a real measurement.
        let scale_hint = hint_scale
            .filter(|s| s.is_finite() && *s > 0.0)
            .or_else(|| scale.arcsec_per_px());

        // Save the image data to the temp file first
        let header = FitsWriteHeader {
            object_name: Some("Plate Solve".to_string()),
            exposure_time: image_data.exposure_secs,
            capture_timestamp: chrono::Utc::now()
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            frame_type: "Light".to_string(),
            filter: image_data.filter.clone(),
            gain: image_data.gain,
            offset: image_data.offset,
            ccd_temp: image_data.temperature,
            ra: hint_ra.map(|r| r / 15.0),
            dec: hint_dec,
            altitude: None,
            telescope: None,
            instrument: None,
            observer: None,
            bin_x: binning.0,
            bin_y: binning.1,
            focal_length: focal_length_mm,
            aperture: None,
            pixel_size_x: pixel_size.map(|(x, _)| x),
            pixel_size_y: pixel_size.map(|(_, y)| y),
            site_latitude: None,
            site_longitude: None,
            site_elevation: None,
        };

        api_save_fits_file(
            temp_path.clone(),
            image_data.width,
            image_data.height,
            image_data.data.clone(),
            header,
        )
        .await
        .map_err(|e| format!("Failed to save temp FITS for plate solve: {}", e))?;

        let mount_id = self
            .app_state
            .get_profile_device_id(DeviceType::Mount)
            .await;
        let mount_before_solve = if let Some(id) = mount_id.as_ref() {
            match tokio::time::timeout(
                std::time::Duration::from_secs(2),
                get_device_manager().mount_get_status(id),
            )
            .await
            {
                Ok(Ok(status)) => serde_json::json!(status),
                other => serde_json::json!({"unavailable": format!("{other:?}")}),
            }
        } else {
            serde_json::Value::Null
        };
        let solve_started_at = chrono::Utc::now();

        // Use the near solve if we have a position, otherwise blind — and
        // either way send the field scale.
        //
        // The 5.0° search radius is the Skotiq default for a near solve
        // and matches the plate-solve UI slider default. It is a literal, not
        // `hint_scale`: degrees of search radius and arcsec/pixel of sampling
        // are not interchangeable, and feeding either a field scale or a solve
        // timeout through this slot silently sets an absurd radius.
        const SEARCH_RADIUS_DEG: f64 = 5.0;
        let result = if let (Some(ra), Some(dec)) = (hint_ra, hint_dec) {
            crate::api::plate_solve::plate_solve_near_scaled(
                temp_path.clone(),
                ra,
                dec,
                SEARCH_RADIUS_DEG,
                None,
                scale_hint,
                None,
            )
            .await
        } else {
            crate::api::plate_solve::plate_solve_blind_scaled(
                temp_path.clone(),
                None,
                scale_hint,
                None,
            )
            .await
        };

        let failure = match &result {
            Ok(solved) if solved.success => None,
            Ok(solved) => Some(solved.error.clone().unwrap_or_else(|| "No solution".into())),
            Err(error) => Some(error.to_string()),
        };
        if let Some(error) = failure {
            super::solve_diagnostics::retain_failed_solve(
                temp_file.clone(),
                serde_json::json!({
                "solve_started_at": solve_started_at.to_rfc3339(),
                "capture_timestamp_unix_seconds": image_data.timestamp,
                "exposure_secs": image_data.exposure_secs,
                "width": image_data.width, "height": image_data.height,
                "gain": image_data.gain, "offset": image_data.offset,
                "temperature_c": image_data.temperature, "filter": image_data.filter,
                "binning": binning, "hint_ra_degrees": hint_ra,
                "hint_dec_degrees": hint_dec, "hint_scale_arcsec_per_px": scale_hint,
                "search_radius_degrees": SEARCH_RADIUS_DEG,
                "mount_id": mount_id, "mount_sample_before_solve": mount_before_solve,
                "solver_path": crate::api::plate_solve::api_get_plate_solver_path(),
                "error": error,
                }),
            )
            .await;
        }
        let _ = std::fs::remove_file(&temp_path);

        // What this rig's own optics measure, remembered for the next solve.
        // A run whose profile carries no focal length gets exactly one blind
        // sweep and is hinted from then on — which is the difference between
        // the drift-recenter that timed out on 2026-09-15 and one that solves
        // in under a second. Recorded only from a solve that reported success
        // AND a usable scale; a failed solve measures nothing.
        if let Ok(solved) = result.as_ref() {
            if solved.success {
                scale.record_measured_scale(solved.pixel_scale);
            }
        }

        result
            .map(|r| PlateSolveResult {
                ra_degrees: r.ra,
                dec_degrees: r.dec,
                pixel_scale: r.pixel_scale,
                rotation: r.rotation,
                up_position_angle_deg: skotiq_sequencer::up_position_angle_deg(
                    r.cd1_2, r.cd2_2, r.rotation,
                ),
                success: r.success,
            })
            .map_err(|e| format!("Plate solve failed: {}", e))
    }

    // Image saving

    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &skotiq_sequencer::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Saving FITS image to: {} ({})",
            file_path,
            frame_ctx.log_label()
        );

        // Only ask the mount when the caller did not already sample it. A
        // sequencer frame arrives with the pointing on its `FrameContext`, and
        // re-reading here would both cost a driver round-trip per saved frame
        // and re-open the gap this whole path exists to close — two reads of a
        // moving mount, taken at different instants, disagreeing about one
        // frame. What such a frame CAN still be missing is the derived
        // altitude, which app settings can supply even when the sequencer's own
        // location seed could not.
        // The horizon frame is evaluated at the EXPOSURE MIDPOINT, not at save
        // time: this runs after readout, so `Utc::now()` here dated the
        // altitude — and therefore AIRMASS — by the whole exposure plus
        // download. See `FrameContext::exposure_midpoint`. Frames that never
        // recorded a shutter-open instant fall back to the clock, which is no
        // worse than before.
        let sky_epoch = frame_ctx
            .exposure_midpoint()
            .unwrap_or_else(chrono::Utc::now);
        let pointing = if frame_ctx.mount_ra_hours.is_some() {
            context_altitude_pointing(frame_ctx, self.get_observer_location(), sky_epoch)
        } else {
            self.read_mount_pointing(sky_epoch).await
        };
        let header = build_rich_header(image_data, frame_ctx, pointing);

        crate::api::save_fits_file_rich(
            file_path.to_string(),
            image_data.width,
            image_data.height,
            image_data.data.clone(),
            header,
        )
        .await
        .map_err(|e| format!("Save FITS failed: {}", e))
    }

    // Notifications

    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NOTIFICATION][{}] {}: {}",
            level.to_uppercase(),
            title,
            message
        );

        // Publish as event to the event bus
        let severity = match level {
            "error" => EventSeverity::Error,
            "warning" => EventSeverity::Warning,
            _ => EventSeverity::Info,
        };

        self.app_state.publish_event(create_event_auto_id(
            severity,
            EventCategory::System,
            EventPayload::System(SystemEvent::Notification {
                title: title.to_string(),
                message: message.to_string(),
                level: level.to_string(),
                explicit_transports: explicit_transports.map(|s| s.to_vec()),
            }),
        ));

        Ok(())
    }

    async fn polar_align_update(&self, result: &PolarAlignResult) -> DeviceResult<()> {
        tracing::info!(
            "Polar Align Update: Alt {:.1}', Az {:.1}'",
            result.altitude_error,
            result.azimuth_error
        );

        let event = PolarAlignmentEvent {
            azimuth_error: result.azimuth_error,
            altitude_error: result.altitude_error,
            total_error: result.total_error,
            current_ra: result.current_ra,
            current_dec: result.current_dec,
            target_ra: result.target_ra,
            target_dec: result.target_dec,
        };

        self.app_state.publish_event(create_event_auto_id(
            EventSeverity::Info,
            EventCategory::PolarAlignment,
            EventPayload::PolarAlignment(event),
        ));

        Ok(())
    }

    // Dome operations

    /// The sequencer's dome/cover role slots are never populated (see
    /// `DeviceOps::active_dome_id`), so answer with whatever is connected —
    /// the same first-connected lookup `resolve_safety_device_id` uses.
    async fn active_dome_id(&self) -> Option<String> {
        get_device_manager()
            .first_connected_device_id(DeviceType::Dome)
            .await
    }

    async fn active_cover_calibrator_id(&self) -> Option<String> {
        get_device_manager()
            .first_connected_device_id(DeviceType::CoverCalibrator)
            .await
    }

    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Opening dome shutter {}", dome_id);

        get_device_manager()
            .dome_open_shutter(dome_id)
            .await
            .map_err(|e| format!("Open dome shutter failed: {}", e))
    }

    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Closing dome shutter {}", dome_id);

        get_device_manager()
            .dome_close_shutter(dome_id)
            .await
            .map_err(|e| format!("Close dome shutter failed: {}", e))
    }

    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Parking dome {}", dome_id);

        get_device_manager()
            .dome_park(dome_id)
            .await
            .map_err(|e| format!("Park dome failed: {}", e))
    }

    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String> {
        let status = get_device_manager()
            .dome_get_shutter_status(dome_id)
            .await
            .map_err(|e| format!("Get dome shutter status failed: {}", e))?;

        // Convert i32 status to string
        // ASCOM ShutterStatus: 0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error
        Ok(match status {
            0 => "Open".to_string(),
            1 => "Closed".to_string(),
            2 => "Opening".to_string(),
            3 => "Closing".to_string(),
            _ => "Error".to_string(),
        })
    }

    // Utility

    fn calculate_altitude(&self, ra_hours: f64, dec_degrees: f64, lat: f64, lon: f64) -> f64 {
        // Calculate Local Sidereal Time
        let now = chrono::Utc::now();
        let jd = julian_day(&now);
        let lst = local_sidereal_time(jd, lon);

        // Calculate hour angle
        let ha = lst - ra_hours;
        let ha_rad = (ha * 15.0_f64).to_radians();
        let dec_rad = dec_degrees.to_radians();
        let lat_rad = lat.to_radians();

        // Calculate altitude
        let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();
        sin_alt.asin().to_degrees()
    }

    fn get_observer_location(&self) -> Option<(f64, f64)> {
        // Get observer location from app settings
        match self.app_state.get_observer_location() {
            Ok(Some(location)) => {
                tracing::debug!(
                    "Observer location retrieved: lat={}, lon={}",
                    location.latitude,
                    location.longitude
                );
                Some((location.latitude, location.longitude))
            }

            Ok(None) => {
                tracing::debug!("Observer location not set in settings, will retry");
                None
            }

            Err(e) => {
                tracing::warn!("Failed to get observer location: {}", e);
                None
            }
        }
    }

    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool> {
        // Prefer a connected SafetyMonitor device. Equipment profiles still
        // only store weather_id, so weather remains a fallback rather than the
        // primary safety source.
        let device_id = self.resolve_safety_device_id(safety_id).await?;

        tracing::debug!("Checking safety status for device: {}", device_id);

        // Use DeviceManager which handles all driver types (ASCOM, Alpaca, INDI, Native)
        match get_device_manager().safety_is_safe(&device_id).await {
            Ok(is_safe) => {
                tracing::info!(
                    "Safety monitor {} reports: {}",
                    device_id,
                    if is_safe { "SAFE" } else { "UNSAFE" }
                );
                Ok(is_safe)
            }

            Err(e) => {
                tracing::error!("Failed to check safety monitor {}: {} - returning error for fail-mode handling", device_id, e);
                Err(format!("Safety check failed for {}: {}", device_id, e))
            }
        }
    }

    /// Feed HumidityThreshold triggers from the configured weather device.
    /// See the trait rustdoc for `Ok(None)` vs `Err` semantics.
    async fn weather_get_humidity(&self, weather_id: Option<&str>) -> DeviceResult<Option<f64>> {
        let device_id = match weather_id {
            Some(id) => id.to_string(),
            None => {
                let profile = self.app_state.get_profile().await;
                match profile.and_then(|p| p.weather_id) {
                    Some(id) => id,
                    None => return Ok(None),
                }
            }
        };

        match get_device_manager()
            .weather_get_conditions(&device_id)
            .await
        {
            Ok(conditions) => Ok(conditions.humidity),
            Err(e) => Err(format!("Humidity poll failed for {}: {}", device_id, e)),
        }
    }

    // Image analysis

    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>> {
        // The grading and HFR-trigger metric. Not the mean of every
        // detection's HFR: on a real frame most detections are faint, and the
        // detector's clipped 41x41 box reads them at 15-16 px, so the 09-14
        // run graded an in-focus frame (HFR ~1.9 px by an independent fit) at
        // 13.22 px and rejected every frame of the night.
        Ok(frame_shape(image_data).map(|shape| shape.hfr))
    }

    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        use skotiq_imaging::{detect_stars, StarDetectionConfig};

        // Convert to skotiq_imaging::ImageData
        let img = skotiq_imaging::ImageData::from_u16(
            image_data.width,
            image_data.height,
            1,
            &image_data.data,
        );

        let config = StarDetectionConfig::default();
        let stars = detect_stars(&img, &config);

        // Convert to (x, y, hfr) tuples
        let result: Vec<(f64, f64, f64)> = stars.iter().map(|s| (s.x, s.y, s.hfr)).collect();

        Ok(result)
    }

    async fn measure_frame_eccentricity(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<f64>> {
        // Adaptive moments over isolated, unsaturated stars. The detector's
        // own moments include the round seeing halo and its clipped noise
        // floor, which read three trailed 09-14 frames (0.83-0.98 by a PSF
        // fit) at 0.52-0.74, under the 0.7 gate. `None` when fewer than five
        // stars can be measured, never a fabricated value.
        Ok(frame_shape(image_data).map(|shape| shape.eccentricity))
    }

    async fn measure_frame_trail(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<skotiq_imaging::FrameTrail>> {
        let img = skotiq_imaging::ImageData::from_u16(
            image_data.width,
            image_data.height,
            1,
            &image_data.data,
        );
        Ok(skotiq_imaging::measure_frame_trail(&img))
    }

    async fn measure_frame_star_shape(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<skotiq_sequencer::FrameStarShape>> {
        Ok(
            frame_shape(image_data).map(|shape| skotiq_sequencer::FrameStarShape {
                eccentricity: shape.eccentricity,
                elongation: Some((shape.elongation_angle_deg, shape.elongation_consistency)),
            }),
        )
    }

    // Cover calibrator (flat panel) operations

    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()> {
        api_cover_calibrator_open_cover(device_id.to_string())
            .await
            .map_err(|e| format!("Open cover failed: {}", e))
    }

    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()> {
        api_cover_calibrator_close_cover(device_id.to_string())
            .await
            .map_err(|e| format!("Close cover failed: {}", e))
    }

    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()> {
        api_cover_calibrator_halt_cover(device_id.to_string())
            .await
            .map_err(|e| format!("Halt cover failed: {}", e))
    }

    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        api_cover_calibrator_calibrator_on(device_id.to_string(), brightness)
            .await
            .map_err(|e| format!("Calibrator on failed: {}", e))
    }

    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()> {
        api_cover_calibrator_calibrator_off(device_id.to_string())
            .await
            .map_err(|e| format!("Calibrator off failed: {}", e))
    }

    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32> {
        api_cover_calibrator_get_cover_state(device_id.to_string())
            .await
            .map_err(|e| format!("Get cover state failed: {}", e))
    }

    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32> {
        api_cover_calibrator_get_calibrator_state(device_id.to_string())
            .await
            .map_err(|e| format!("Get calibrator state failed: {}", e))
    }

    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        api_cover_calibrator_get_brightness(device_id.to_string())
            .await
            .map_err(|e| format!("Get brightness failed: {}", e))
    }

    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        api_cover_calibrator_get_max_brightness(device_id.to_string())
            .await
            .map_err(|e| format!("Get max brightness failed: {}", e))
    }
}

/// Star size and shape for one frame, the grader's view of it.
fn frame_shape(image_data: &ImageData) -> Option<skotiq_imaging::FrameShape> {
    let img = skotiq_imaging::ImageData::from_u16(
        image_data.width,
        image_data.height,
        1,
        &image_data.data,
    );
    skotiq_imaging::measure_frame_shape(&img)
}

/// Decisions-verify refutation D4 (2026-08-14, corrected by the focused
/// re-refute): a mount that cannot READ park state (the LX200 family without
/// a cached park entry) reaches the status layer as a fabricated
/// `parked=false`, marked by `availability[PARKED] = Unsupported`. Surface
/// that unknowability as an error so callers take their read-failed path
/// (the sequencer's unpark gate falls through and issues the unpark) instead
/// of trusting a value the mount never produced.
///
/// `can_park=false` alone is NOT the signal: ASCOM mandates `AtPark` be
/// readable regardless of `CanPark`, and Alpaca can lose `can_park` to a
/// transient capabilities hiccup while reading `parked` genuinely — erroring
/// on those would fail every autopilot run at its head `Unpark` node on
/// mounts that simply cannot park.
fn parked_from_status(mount_id: &str, status: &crate::device::MountStatus) -> DeviceResult<bool> {
    use crate::device::{mount_status_field, FieldAvailability};
    match status.availability.get(mount_status_field::PARKED) {
        Some(FieldAvailability::Unsupported) | Some(FieldAvailability::Error(_)) => {
            Err(format!("Mount {} cannot report park state", mount_id))
        }
        _ => Ok(status.parked),
    }
}

#[cfg(test)]
mod parked_from_status_tests {
    use super::parked_from_status;
    use crate::device::MountStatus;
    use std::collections::HashMap;

    fn status(parked: bool, can_park: bool) -> MountStatus {
        MountStatus {
            connected: true,
            tracking: false,
            slewing: false,
            parked,
            at_home: None,
            side_of_pier: None,
            right_ascension: 0.0,
            declination: 0.0,
            altitude: None,
            azimuth: None,
            sidereal_time: None,
            tracking_rate: None,
            can_park,
            can_slew: true,
            can_sync: true,
            can_pulse_guide: false,
            can_set_tracking_rate: false,
            availability: HashMap::new(),
        }
    }

    #[test]
    fn a_trustworthy_report_passes_through() {
        assert!(parked_from_status("m", &status(true, true)).unwrap());
        assert!(!parked_from_status("m", &status(false, true)).unwrap());
    }

    fn unreadable(mut s: MountStatus) -> MountStatus {
        s.availability.insert(
            crate::device::mount_status_field::PARKED.to_string(),
            crate::device::FieldAvailability::Unsupported,
        );
        s
    }

    /// ASCOM mandates AtPark be readable regardless of CanPark: an honest
    /// "this mount cannot park" with a genuine parked=false must pass
    /// through, or every autopilot run fails at its head Unpark node.
    #[test]
    fn cannot_park_with_a_readable_state_is_not_an_error() {
        assert!(!parked_from_status("m", &status(false, false)).unwrap());
    }

    /// Only a park state the backend could not READ (Native NotSupported,
    /// marked via availability) refuses to serve the fabricated bool.
    #[test]
    fn an_unreadable_park_state_is_an_error_not_a_fabricated_false() {
        let err = parked_from_status("m", &unreadable(status(false, false))).unwrap_err();
        assert!(err.to_string().contains("cannot report park state"));
    }
}

/// Whether a guider in `state` (PHD2's app state, or the built-in guider's)
/// may move the mount: anything but connected-and-idle, looping or paused.
/// PHD2 in LostLock keeps searching and guides again the moment it finds the
/// star; settling and calibrating move the mount; a state this build does not
/// know is treated as active.
pub(crate) fn guider_state_may_move_mount(state: &str) -> bool {
    !matches!(
        state,
        "Disconnected" | "Connected" | "Stopped" | "Selected" | "Looping" | "Paused"
    )
}

#[cfg(test)]
mod guider_state_tests {
    use super::guider_state_may_move_mount;

    #[test]
    fn a_guider_that_may_move_the_mount_is_any_but_idle_looping_or_paused() {
        for state in [
            "Guiding",
            "Calibrating",
            "Settling",
            "LostLock",
            "GuidingPaused",
        ] {
            assert!(guider_state_may_move_mount(state), "{state}");
        }
        for state in [
            "Disconnected",
            "Connected",
            "Stopped",
            "Selected",
            "Looping",
            "Paused",
        ] {
            assert!(!guider_state_may_move_mount(state), "{state}");
        }
    }
}

/// Publish `MountSlewCompleted` once a slew the sequencer commanded has
/// actually arrived, watched in the background so the instruction's own wait
/// is not held up. A slew that stops short, is aborted or times out publishes
/// nothing: the mount's status events already say it stopped.
async fn spawn_slew_completion_watch(
    app_state: SharedAppState,
    mount_id: String,
    ra_hours: f64,
    dec_degrees: f64,
) {
    use skotiq_sequencer::slew_arrival::{wait_for_slew_arrival, SlewArrivalTimings, SlewSample};

    let Some(device) = get_device_manager().get_device(&mount_id).await else {
        return;
    };
    let target = crate::device_manager::epoch::j2000_to_mount_frame(
        device.info.driver_type,
        ra_hours,
        dec_degrees,
    );
    tokio::spawn(async move {
        // Once a second: this runs beside the instruction's own watch and
        // every read is a driver round trip.
        let timings = SlewArrivalTimings {
            poll_interval: std::time::Duration::from_secs(1),
            max_consecutive_failures: 10,
            ..SlewArrivalTimings::goto(crate::timeout_ops::Timeouts::long_slew())
        };
        let result = wait_for_slew_arrival(
            Some(target),
            &timings,
            || {
                let mount_id = mount_id.clone();
                async move {
                    match get_device_manager().mount_get_status(&mount_id).await {
                        Ok(status) => SlewSample {
                            slewing: Some(status.slewing),
                            position: Some((status.right_ascension, status.declination)),
                        },
                        Err(_) => SlewSample {
                            slewing: None,
                            position: None,
                        },
                    }
                }
            },
            || false,
            |_| {},
        )
        .await;
        match result {
            Ok(progress) if progress.near_target => {
                app_state.publish_event(create_event_auto_id(
                    EventSeverity::Info,
                    EventCategory::Equipment,
                    EventPayload::Equipment(EquipmentEvent::MountSlewCompleted {
                        ra: ra_hours,
                        dec: dec_degrees,
                    }),
                ));
            }
            Ok(progress) => tracing::info!(
                "Mount {} stopped {} from the slew target",
                mount_id,
                progress.remaining_deg.map_or_else(
                    || "an unknown distance".to_string(),
                    skotiq_sequencer::slew_arrival::format_arc
                )
            ),
            Err(e) => tracing::info!("Mount {} slew did not complete: {}", mount_id, e),
        }
    });
}
