//! `DeviceDriver` / `CameraDriver` / `Drop` implementations for `GPhoto2Camera`.

use super::exposure::{exposure_range, plan_exposure, ExposurePlan, MadeExposure};
use super::*;

/// The files of a finished capture, waited for until the camera wrote them.
async fn finished_capture(
    capture: tokio::task::JoinHandle<Result<CameraFilePath, DriverError>>,
) -> Result<CameraFilePath, DriverError> {
    capture.await.unwrap_or_else(|stopped| {
        Err(DriverError::SdkError(format!(
            "gPhoto2: the capture stopped: {stopped}"
        )))
    })
}

#[async_trait]
impl DeviceDriver for GPhoto2Camera {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.model_name
    }

    fn vendor(&self) -> Vendor {
        Vendor::GPhoto2
    }

    fn serial_number(&self) -> Option<String> {
        self.facts.serial.clone()
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        tracing::info!(
            "Connecting to gPhoto2 camera: {} on {}",
            self.model_name,
            self.port_path
        );

        let sdk = GPhoto2Sdk::installed().inspect_err(|_| {
            tracing::error!("Cannot connect to DSLR camera: libgphoto2 not loaded");
        })?;
        let sdk = sdk.lock().await;
        self.open(&sdk)?;

        self.connected = true;
        tracing::info!(
            "Successfully connected to gPhoto2 camera: {} on {} ({}x{}, {} um)",
            self.model_name,
            self.port_path,
            self.sensor_width,
            self.sensor_height,
            self.pixel_size
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }
        let exposure = std::mem::take(&mut self.exposure);
        // A timed capture holds the camera until it has written its frame.
        if let ExposureState::Timed { capture, .. } = exposure {
            let _ = finished_capture(capture).await;
            let sdk = GPhoto2Sdk::lock().await?;
            self.close(&sdk);
        } else {
            let sdk = GPhoto2Sdk::lock().await?;
            if let ExposureState::Bulb { opened, .. } = exposure {
                if let Err(e) = self.close_bulb(&sdk, opened) {
                    tracing::warn!("gPhoto2: {}", e);
                }
            }
            self.close(&sdk);
        }
        self.connected = false;
        tracing::info!("Disconnected from gPhoto2 camera: {}", self.model_name);
        Ok(())
    }
}

#[async_trait]
impl CameraDriver for GPhoto2Camera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: false,                           // DSLRs don't have coolers
            can_set_gain: !self.iso_speeds.is_empty(), // ISO, as the gain number
            can_set_offset: false,                     // DSLRs don't have offset control
            can_set_binning: false,                    // DSLRs don't support binning
            can_subframe: false,                       // DSLRs capture full frame only
            has_shutter: true,                         // DSLRs have mechanical shutters
            has_guider_port: false,                    // DSLRs don't have ST-4 ports
            max_bin_x: 1,
            max_bin_y: 1,
            supports_readout_modes: false,
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let (state, exposure_remaining) = match &self.exposure {
            ExposureState::Idle => {
                self.probe()?;
                (CameraState::Idle, None)
            }
            ExposureState::Timed { start, seconds, .. } => {
                let remaining = seconds - start.elapsed().as_secs_f64();
                if remaining > 0.0 {
                    (CameraState::Exposing, Some(remaining))
                } else {
                    (CameraState::Downloading, Some(0.0))
                }
            }
            ExposureState::Bulb { opened, requested } => (
                CameraState::Exposing,
                Some((requested - opened.elapsed().as_secs_f64()).max(0.0)),
            ),
        };

        Ok(CameraStatus {
            state,
            sensor_temp: None, // a body reports its temperature only in its raw files
            cooler_power: None,
            target_temp: None,
            cooler_on: Some(false),
            gain: self.current_iso,
            offset: 0,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if !matches!(self.exposure, ExposureState::Idle) {
            return Err(DriverError::SdkError(format!(
                "gPhoto2: {} is still taking the last exposure",
                self.model_name
            )));
        }

        let sdk = GPhoto2Sdk::lock().await?;
        self.discard_stray_events(&sdk)?;
        if let Some(iso) = params.gain {
            self.apply_iso(&sdk, iso)?;
        }
        // Skotiq always decodes the raw file, so a body left on JPEG is
        // switched to RAW (best effort; the read checks the file).
        self.apply_raw_format(&sdk);
        self.refresh_shutter_speeds(&sdk)?;

        let requested = params.duration_secs;
        match plan_exposure(
            &self.model_name,
            &self.shutter,
            self.bulb_widget.is_some(),
            requested,
        )? {
            ExposurePlan::Timed(speed) => {
                if ((speed.seconds - requested) / requested).abs() > 0.01 {
                    tracing::info!(
                        "gPhoto2: {} s is not one of the camera's shutter speeds; using {} ({} s)",
                        requested,
                        speed.choice,
                        speed.seconds
                    );
                }
                self.start_timed(sdk, &speed)?;
                tracing::info!("gPhoto2: timed exposure {} started", speed.choice);
            }
            ExposurePlan::Bulb => self.open_bulb(&sdk, requested)?,
        }
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        // A timed speed cannot be cut short; its frame is discarded when the
        // camera has written it (as the INDI driver does,
        // gphoto_driver.cpp:817-819, 1011-1018).
        let first = match std::mem::take(&mut self.exposure) {
            ExposureState::Idle => return Ok(()),
            ExposureState::Timed { capture, .. } => match finished_capture(capture).await {
                Ok(path) => Some(path),
                Err(e) => {
                    tracing::warn!("gPhoto2: the aborted capture failed: {}", e);
                    return Ok(());
                }
            },
            ExposureState::Bulb { opened, requested } => {
                let sdk = GPhoto2Sdk::lock().await?;
                self.close_bulb(&sdk, opened)?;
                let files =
                    self.collect_files(&sdk, Duration::from_secs(10), Duration::from_millis(1500))?;
                self.discard_files(&sdk, &files);
                tracing::info!("gPhoto2: bulb exposure of {:.1}s aborted", requested);
                return Ok(());
            }
        };
        let sdk = GPhoto2Sdk::lock().await?;
        if let Some(first) = first {
            let files = self.rest_of_capture(&sdk, first)?;
            self.discard_files(&sdk, &files);
        }
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        Ok(match &self.exposure {
            ExposureState::Idle => true,
            ExposureState::Timed { capture, .. } => capture.is_finished(),
            ExposureState::Bulb { opened, requested } => {
                opened.elapsed().as_secs_f64() >= *requested
            }
        })
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let (sdk, files, made) = match std::mem::take(&mut self.exposure) {
            ExposureState::Idle => {
                return Err(DriverError::SdkError(
                    "gPhoto2: No completed exposure to download".to_string(),
                ))
            }
            ExposureState::Timed {
                capture, seconds, ..
            } => {
                let first = finished_capture(capture).await?;
                let sdk = GPhoto2Sdk::lock().await?;
                let files = self.rest_of_capture(&sdk, first)?;
                (sdk, files, MadeExposure::Timed(seconds))
            }
            ExposureState::Bulb { opened, requested } => {
                let left = requested - opened.elapsed().as_secs_f64();
                if left > 0.0 {
                    tokio::time::sleep(Duration::from_secs_f64(left)).await;
                }
                let sdk = GPhoto2Sdk::lock().await?;
                let open = self.close_bulb(&sdk, opened)?;
                let files = self.bulb_files(&sdk)?;
                (sdk, files, MadeExposure::Bulb(open))
            }
        };

        let names: Vec<String> = files.iter().map(|f| cstr_from_array(&f.name)).collect();
        let read = raw_file_index(&names);
        // A file that could not be read stays on the camera; one left in its
        // memory goes before the next exposure.
        let bytes = self.download_file(&sdk, &files[read])?;
        for file in &files {
            self.delete_file(&sdk, file);
        }
        if matches!(made, MadeExposure::Timed(_)) && self.facts.needs_session_reset_after_capture()
        {
            // SAFETY: the SDK lock is held and the camera is open; libgphoto2
            // opens the session again on the next call.
            unsafe {
                (sdk.camera_exit)(self.gp_camera, self.gp_context);
            }
        }
        drop(sdk);

        self.decode_raw_to_image_data(
            skotiq_device::CameraFile {
                file_name: names[read].clone(),
                bytes: std::sync::Arc::new(bytes),
            },
            made,
        )
    }

    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = GPhoto2Sdk::lock().await?;
        self.apply_iso(&sdk, gain)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        Ok(self.current_iso)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        Ok(0) // DSLRs don't have offset control
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        Ok((1, 1))
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: self.sensor_width,
            height: self.sensor_height,
            pixel_size_x: self.pixel_size,
            pixel_size_y: self.pixel_size,
            max_adu: resolve_max_adu(self.measured_white_level, self.bit_depth),
            bit_depth: self.bit_depth,
            color: true,
            bayer_pattern: self.color_filter,
            saturation_adu: self.measured_saturation_level,
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(vec![ReadoutMode {
            name: "Standard".to_string(),
            description: "Standard DSLR readout".to_string(),
            index: 0,
            gain_min: self.iso_speeds.first().map(|s| s.speed),
            gain_max: self.iso_speeds.last().map(|s| s.speed),
            offset_min: None,
            offset_max: None,
        }])
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        // DSLRs only have one readout mode
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        let mut custom = std::collections::HashMap::new();
        custom.insert(
            "camera_model".to_string(),
            serde_json::Value::String(self.model_name.clone()),
        );
        custom.insert("iso".to_string(), serde_json::json!(self.current_iso));
        custom.insert(
            "can_bulb".to_string(),
            serde_json::Value::Bool(self.bulb_widget.is_some()),
        );
        custom.insert(
            "can_preview".to_string(),
            serde_json::Value::Bool(self.can_preview),
        );
        if let Some(battery) = &self.facts.battery {
            custom.insert("battery_level".to_string(), serde_json::json!(battery));
        }
        if let Some(target) = &self.facts.capture_target {
            custom.insert("capture_target".to_string(), serde_json::json!(target));
        }
        Ok(VendorFeatures {
            custom_data: custom,
            ..Default::default()
        })
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        match (self.iso_speeds.first(), self.iso_speeds.last()) {
            (Some(low), Some(high)) => Ok((low.speed, high.speed)),
            _ => Err(DriverError::NotSupported),
        }
    }

    async fn get_iso_speeds(&self) -> Result<Vec<i32>, DriverError> {
        Ok(self.iso_speeds.iter().map(|s| s.speed).collect())
    }

    fn long_exposure_noise_reduction(&self) -> LongExposureNoiseReduction {
        self.long_exposure_nr
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        Ok(exposure_range(&self.shutter, self.bulb_widget.is_some()))
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if !self.can_preview {
            return Err(DriverError::NotSupported);
        }

        let sdk = GPhoto2Sdk::lock().await?;

        // SAFETY: gp_camera/gp_context valid while connected.
        // gp_file is stack-allocated out-pointer freed on every exit path.
        unsafe {
            let mut gp_file: *mut CameraFile = std::ptr::null_mut();
            let ret = (sdk.file_new)(&mut gp_file);
            check_gp_error(ret, "file_new")?;

            let ret = (sdk.camera_capture_preview)(self.gp_camera, gp_file, self.gp_context);
            if ret < GP_OK {
                (sdk.file_free)(gp_file);
                return Err(gp_error(ret, "capture_preview"));
            }

            let mut data_ptr: *const c_char = std::ptr::null();
            let mut data_size: c_ulong = 0;
            let ret = (sdk.file_get_data_and_size)(gp_file, &mut data_ptr, &mut data_size);
            if ret < GP_OK || data_ptr.is_null() || data_size == 0 {
                (sdk.file_free)(gp_file);
                return Err(DriverError::SdkError(format!(
                    "gPhoto2: Failed to read preview data: code {}",
                    ret
                )));
            }

            let data = std::slice::from_raw_parts(data_ptr as *const u8, data_size as usize);
            let jpeg = data.to_vec();
            (sdk.file_free)(gp_file);
            Ok(jpeg)
        }
    }
}

impl Drop for GPhoto2Camera {
    fn drop(&mut self) {
        if !self.connected {
            return;
        }
        // The capture thread still uses the camera: leave it to the process.
        if let ExposureState::Timed { capture, .. } = &self.exposure {
            if !capture.is_finished() {
                tracing::warn!(
                    "gPhoto2: {} dropped during a capture; its handle is not closed",
                    self.model_name
                );
                return;
            }
        }
        if let Ok(sdk) = GPhoto2Sdk::installed() {
            // Unlocked on purpose; the SAFETY note below says why.
            let sdk = sdk.unlocked();
            // SAFETY: Drop is best-effort cleanup. We do NOT take the SDK lock
            // here because (a) Drop cannot await, and (b) Drop only runs when the
            // last owner is releasing the camera and no capture thread holds it
            // (checked above), so no other thread is touching
            // `gp_camera`/`gp_context`. Each pointer is non-null-checked before
            // its corresponding free/unref.
            unsafe {
                if !self.gp_camera.is_null() {
                    let _ = (sdk.camera_exit)(self.gp_camera, self.gp_context);
                    (sdk.camera_free)(self.gp_camera);
                }
                if !self.gp_context.is_null() {
                    (sdk.context_unref)(self.gp_context);
                }
            }
        }
    }
}
