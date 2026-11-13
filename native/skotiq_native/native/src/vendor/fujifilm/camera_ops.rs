//! `DeviceDriver` / `CameraDriver` implementations for `FujifilmCamera`.

use super::*;

#[async_trait]
impl DeviceDriver for FujifilmCamera {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Fujifilm
    }

    fn serial_number(&self) -> Option<String> {
        self.serial_number.clone()
    }

    fn is_connected(&self) -> bool {
        self.session.is_some()
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }
        let sdk = FujifilmSdk::lock().await?;
        let session = session::join(&sdk, &self.address).await?;
        let camera_handle = session.handle();
        self.firmware_version = session.firmware().to_string();
        let actual_name = session.product().to_string();

        // 1. CRITICAL: Set dynamic range to 100 BEFORE ISO operations
        // SAFETY: `camera_handle` valid; XSDK_SetDynamicRange takes (handle, c_long) POD per XAPI.h. Must precede ISO operations per the module header's SDK behavior §1.
        unsafe { (sdk.set_dynamic_range)(camera_handle, XSDK_DR_100) };
        std::thread::sleep(Duration::from_millis(100));

        if !actual_name.is_empty() {
            self.model = FujifilmModel::from_product_name(&actual_name);
            // Depth deliberately dropped here: `refresh_raw_depth` below picks
            // it from the highest-authority source available.
            let (width, height, pixel_size, _) = self.model.sensor_specs();
            self.sensor_info.width = width;
            self.sensor_info.height = height;
            self.sensor_info.pixel_size_x = pixel_size;
            self.sensor_info.pixel_size_y = pixel_size;
        }

        // 2. Ask the body which RAW output depth it is set to. A GFX switched
        //    to SDK_RAWOUTPUTDEPTH_16BIT (XAPIOpt.H:585) delivers samples that
        //    reach 65535, four times the model table's 16383 estimate, and a
        //    max_adu that low makes every such frame look saturated. Only the
        //    bodies whose capability header declares support are asked; the
        //    rest answer XSDK_ERRCODE_API_NOTFOUND, and we keep the estimate.
        if self.model.supports_16bit_raw() {
            let mut raw_output_depth: c_long = 0;
            // SAFETY: `camera_handle` is the session's open handle; `&mut raw_output_depth` is a valid stack out-pointer to a c_long. API_PARAM_GetRAWOutputDepth is 1 (one out-pointer) in every model header that defines it.
            let result = unsafe {
                (sdk.get_prop)(
                    camera_handle,
                    API_CODE_GET_RAW_OUTPUT_DEPTH,
                    API_PARAM_ONE_VALUE,
                    &mut raw_output_depth,
                )
            };

            if result == XSDK_COMPLETE {
                self.sdk_reported_bit_depth = raw_output_depth_to_bits(raw_output_depth);
                tracing::info!(
                    "Fujifilm: camera reports RAW output depth code {} -> {:?} bits",
                    raw_output_depth,
                    self.sdk_reported_bit_depth
                );
            } else {
                tracing::debug!(
                    "Fujifilm: XSDK_GetProp(GetRAWOutputDepth) returned {}; keeping the model-table depth estimate",
                    result
                );
            }
        }

        self.refresh_raw_depth();

        // 3. Long exposure noise reduction makes the body shoot a dark of the
        //    same length after every frame and subtract it: twice the time per
        //    frame, a calibration nobody chose, and a frame that arrives long
        //    after the download stops waiting. The owner's NINA plugin turns it
        //    off by default; so does this driver, and says so.
        self.long_exposure_nr = switch_off_long_exposure_nr(camera_handle, &sdk, &self.id);

        // 4. Query ISO capabilities
        let mut iso_count: c_long = 0;
        // SAFETY: `camera_handle` valid; a NULL value buffer asks only for the count (SDK Programming Reference 4.1.9.13); `&mut iso_count` is a valid stack out-pointer.
        let result =
            unsafe { (sdk.cap_sensitivity)(camera_handle, &mut iso_count, std::ptr::null_mut()) };
        self.supported_isos = if result == XSDK_COMPLETE && iso_count > 0 {
            let mut iso_values: Vec<c_long> = vec![0; iso_count as usize];
            // SAFETY: `iso_values` holds exactly the `iso_count` entries the first call reported, and `iso_count` tells the SDK that capacity.
            let result = unsafe {
                (sdk.cap_sensitivity)(camera_handle, &mut iso_count, iso_values.as_mut_ptr())
            };
            iso_values.truncate(iso_count.max(0) as usize);
            if result == XSDK_COMPLETE {
                fixed_sensitivities(&iso_values)
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        // 5. Get current ISO
        let mut current_iso: c_long = 0;
        // SAFETY: `camera_handle` valid; `&mut current_iso` is a valid stack out-pointer to c_long; XSDK_GetSensitivity writes the current ISO value per XAPI.h.
        unsafe { (sdk.get_sensitivity)(camera_handle, &mut current_iso) };
        self.current_iso = current_iso as i32;

        // 6. Frames left from before this session would be downloaded as ours.
        discard_buffered_frames(camera_handle, &sdk);

        self.session = Some(session);
        tracing::info!(
            "Connected to Fujifilm {} ({})",
            self.name,
            self.firmware_version
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        let Some(session) = self.session.clone() else {
            return Ok(());
        };

        let sdk = FujifilmSdk::lock().await?;

        // Stop any ongoing exposure. The session is released even if this fails,
        // but a failed bulb stop means the shutter may be
        // left open on a camera we are about to stop talking to, which the operator
        // has to be told about.
        if self.is_bulb_mode {
            if let Err(e) = self.stop_bulb_exposure(&sdk).await {
                tracing::error!(
                    "Fujifilm {}: failed to close the bulb shutter before disconnect: {}. The shutter may still be open; power-cycle the camera if the exposure does not end.",
                    self.id,
                    e
                );
            }
        }

        self.end_live_view(&sdk).await;
        self.session = None;
        session::leave(&sdk, &session);
        self.is_exposing = false;
        self.is_bulb_mode = false;

        tracing::info!("Disconnected from Fujifilm {}", self.name);

        Ok(())
    }
}

/// Switch long exposure noise reduction off if it is on. Returns whether it is
/// still on.
fn switch_off_long_exposure_nr(handle: XsdkHandle, sdk: &FujifilmSdk, id: &str) -> bool {
    let read = || {
        let mut setting: c_long = 0;
        // SAFETY: `handle` is the open XSDK handle; API_PARAM_GetLongExposureNR is 1 (one out-pointer) in every model header; `&mut setting` is a valid stack c_long.
        let result = unsafe {
            (sdk.get_prop)(
                handle,
                API_CODE_GET_LONG_EXPOSURE_NR,
                API_PARAM_ONE_VALUE,
                &mut setting,
            )
        };
        (result == XSDK_COMPLETE).then_some(setting)
    };
    if read() != Some(SDK_ON) {
        return false;
    }
    // SAFETY: `handle` is the open XSDK handle; API_PARAM_SetLongExposureNR is 1 (one value) in every model header.
    unsafe {
        (sdk.set_prop)(
            handle,
            API_CODE_SET_LONG_EXPOSURE_NR,
            API_PARAM_ONE_VALUE,
            SDK_OFF,
        )
    };
    let still_on = read() == Some(SDK_ON);
    if still_on {
        tracing::warn!(
            "Fujifilm {id}: long exposure noise reduction is on and the camera refused to turn it off. \
             Each frame takes twice its exposure, and the camera subtracts its own dark. \
             Turn LONG EXPOSURE NR off in the camera's menu."
        );
    } else {
        tracing::warn!(
            "Fujifilm {id}: turned the camera's long exposure noise reduction off. With it on, \
             the camera shoots and subtracts its own dark after every frame."
        );
    }
    still_on
}

impl FujifilmCamera {
    /// Wait for the exposure's RAW frame and download it, discarding the JPEG
    /// or HEIF companions of a RAW+JPEG shot. Returns the RAF bytes and the
    /// bit depth the SDK reported for them.
    async fn wait_for_raw_frame(&self) -> Result<(Vec<u8>, c_long), DriverError> {
        let wait = frame_wait(self.exposure_duration.as_secs_f64(), self.long_exposure_nr);
        let deadline = Instant::now() + wait;
        let mut skipped = 0;
        loop {
            {
                let sdk = FujifilmSdk::lock().await?;
                let mut img_info = XsdkImageInformation::default();
                // SAFETY: `self.handle()` valid; `&mut img_info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkImageInformation that the SDK populates per XAPI.h. Packed fields are copied into locals before use (misaligned references would be UB).
                let result = unsafe { (sdk.read_image_info)(self.handle(), &mut img_info) };
                let (format, data_size, bit_depth) = (
                    img_info.l_format,
                    img_info.l_data_size,
                    img_info.l_image_bit_depth,
                );
                if result == XSDK_COMPLETE && data_size > 0 {
                    if BufferedImage::from_format(format) == BufferedImage::Raw {
                        let mut buffer = vec![0u8; data_size as usize];
                        // SAFETY: `buffer` holds exactly `data_size` bytes and that size is passed, so XSDK_ReadImage cannot write past it.
                        let result = unsafe {
                            (sdk.read_image)(
                                self.handle(),
                                buffer.as_mut_ptr(),
                                data_size as c_ulong,
                            )
                        };
                        if result != XSDK_COMPLETE {
                            let error = sdk_error(self.handle(), &sdk, "downloading the RAW frame");
                            // SAFETY: as above; the failed frame is removed so it cannot be read as the next one.
                            unsafe { (sdk.delete_image)(self.handle()) };
                            return Err(error);
                        }
                        // XSDK_ReadImage removed the frame from the buffer.
                        return Ok((buffer, bit_depth));
                    }
                    // The JPEG or HEIF of a RAW+JPEG shot: the RAW is next.
                    skipped += 1;
                    // SAFETY: `self.handle()` valid; XSDK_DeleteImage takes only the handle.
                    if unsafe { (sdk.delete_image)(self.handle()) } == XSDK_COMPLETE {
                        continue;
                    }
                }
            }
            if Instant::now() >= deadline {
                let reason = if skipped > 0 {
                    format!(
                        "the camera sent {skipped} JPEG or HEIF frame(s) and no RAW. Set IMAGE \
                         QUALITY to RAW or RAW+JPEG"
                    )
                } else if self.long_exposure_nr {
                    "long exposure noise reduction is on, so the camera is still taking its \
                     own dark. Turn LONG EXPOSURE NR off in the camera's menu"
                        .to_string()
                } else {
                    "check that IMAGE QUALITY is RAW or RAW+JPEG and the USB cable is connected"
                        .to_string()
                };
                return Err(DriverError::Timeout(format!(
                    "Fujifilm camera: no RAW frame arrived {:.0} s after the exposure ended: {reason}.",
                    wait.as_secs_f64()
                )));
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}

#[async_trait]
impl CameraDriver for FujifilmCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_cool: false,        // No cooling in mirrorless
            can_set_gain: true,     // ISO control
            can_set_offset: false,  // No offset control
            can_set_binning: false, // No binning in DSLR/mirrorless
            can_subframe: false,    // Full sensor only
            has_shutter: true,      // Mechanical shutter
            has_guider_port: false, // No ST-4
            max_bin_x: 1,
            max_bin_y: 1,
            supports_readout_modes: false,
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }
        // Between exposures, ask the camera something, so a body that was
        // unplugged or switched off shows up as lost: the SDK reports that
        // only as the error of the next call it gets (SDK Programming
        // Reference 4.1.2.2, Note).
        if !self.is_exposing {
            let sdk = FujifilmSdk::lock().await?;
            frames_in_buffer(self.handle(), &sdk)?;
        }

        let state = if self.is_exposing {
            CameraState::Exposing
        } else {
            CameraState::Idle
        };

        let exposure_remaining = if self.is_exposing {
            self.exposure_start.map(|start| {
                let elapsed = start.elapsed();
                (self.exposure_duration.as_secs_f64() - elapsed.as_secs_f64()).max(0.0)
            })
        } else {
            None
        };

        Ok(CameraStatus {
            state,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: Some(false),
            gain: self.current_iso,
            offset: self.current_offset,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let sdk = FujifilmSdk::lock().await?;
        self.end_live_view(&sdk).await;

        if let Some(gain) = params.gain {
            self.apply_iso(&sdk, gain).await?;
        }

        // A frame already waiting would be downloaded as this exposure's.
        let stale = discard_buffered_frames(self.handle(), &sdk);
        if stale > 0 {
            tracing::warn!(
                "Fujifilm {}: discarded {} frame(s) left in the camera before the exposure",
                self.id,
                stale
            );
        }

        // The offered codes depend on the ISO and the dials, so they are read
        // for each exposure.
        let shutter = self
            .shutter_speeds(&sdk)
            .choose(params.duration_secs)
            .map_err(DriverError::InvalidParameter)?;
        let (code, seconds) = match shutter {
            Shutter::Bulb { seconds } => return self.start_bulb_exposure(&sdk, seconds).await,
            Shutter::Timed { code, seconds } => (code as c_long, seconds),
        };
        if (seconds - params.duration_secs).abs() > f64::EPSILON {
            tracing::info!(
                "Fujifilm {}: {} s requested; the nearest shutter speed is {} s, which the frame records",
                self.id,
                params.duration_secs,
                seconds
            );
        }

        self.set_shutter(&sdk, code, 0, seconds).await?;
        tokio::time::sleep(Duration::from_millis(100)).await;

        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;
        // SAFETY: `self.handle()` valid; out-pointers reference distinct c_long stack locals; XSDK_RELEASE_SHOOT_S1OFF is the documented "one-shot full-press-and-release" trigger flag from XAPI.h for non-bulb exposures.
        let result = unsafe {
            (sdk.release)(
                self.handle(),
                XSDK_RELEASE_SHOOT_S1OFF,
                &mut shot_opt,
                &mut af_status,
            )
        };

        if result != XSDK_COMPLETE {
            return Err(sdk_error(self.handle(), &sdk, "releasing the shutter"));
        }

        self.exposure_start = Some(Instant::now());
        self.exposure_duration = Duration::from_secs_f64(seconds);
        self.is_exposing = true;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.end_exposure_and_discard_frame().await
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        if !self.is_exposing {
            return Ok(true);
        }

        if let Some(start) = self.exposure_start {
            Ok(start.elapsed() >= self.exposure_duration)
        } else {
            Ok(true)
        }
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        if self.is_bulb_mode {
            let sdk = FujifilmSdk::lock().await?;
            self.stop_bulb_exposure(&sdk).await?;
        }

        let downloaded = self.wait_for_raw_frame().await;
        self.is_exposing = false;
        let (buffer, sdk_bit_depth) = downloaded?;

        // The SDK fills lImageBitDepth (XAPI.H:123) on every XSDK_ReadImageInfo
        // and it tracks the body's live RAW output depth, so a GFX switched to
        // SDK_RAWOUTPUTDEPTH_16BIT reports 16 here while the model table still
        // says 14. Read only for a RAW frame: a live-view or JPEG frame
        // describes a different pipeline and must not redefine the sensor's
        // container. Implausible values are ignored, not adopted.
        if (8..=16).contains(&sdk_bit_depth) {
            self.sdk_reported_bit_depth = Some(sdk_bit_depth as u32);
            self.refresh_raw_depth();
        }

        // Decode the RAF into its native linear CFA mosaic (single channel).
        let frame = process_raf_buffer(&buffer)?;

        // Adopt the decoder's ground truth — the highest-authority source.
        // `white_level` IS LibRaw's `color.maximum` (the saturation level) and
        // `bits_per_pixel` is derived from it. The mosaic is RIGHT-JUSTIFIED at
        // its native depth: the white level is already the container full scale
        // and must not be scaled up into 16 bits.
        if (8..=16).contains(&frame.bits_per_pixel) {
            self.measured_bit_depth = Some(frame.bits_per_pixel);
        }
        if frame.white_level > 0 {
            self.measured_white_level = Some(frame.white_level);
        }
        self.refresh_raw_depth();

        let bayer_pattern = Some(crate::camera_core::mosaic_bayer_pattern(&frame.cfa));

        let metadata = ImageMetadata {
            exposure_time: self.exposure_duration.as_secs_f64(),
            gain: self.current_iso,
            offset: self.current_offset,
            bin_x: 1,
            bin_y: 1,
            temperature: frame.metadata.temperature.map(|t| t.celsius as f64),
            timestamp: chrono::Utc::now(),
            subframe: None,
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
            camera_file: Some(skotiq_device::CameraFile {
                file_name: "frame.RAF".to_string(),
                bytes: std::sync::Arc::new(buffer),
            }),
        };

        Ok(ImageData {
            width: frame.width,
            height: frame.height,
            bits_per_pixel: frame.bits_per_pixel,
            data: frame.data,
            bayer_pattern,
            metadata,
        })
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
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let sdk = FujifilmSdk::lock().await?;
        self.apply_iso(&sdk, gain).await
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(self.current_iso)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(0)
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.sensor_info.clone()
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((1, 1)) // Fujifilm cameras don't support binning
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Err(DriverError::NotSupported) // Full frame only
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(vec![])
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        match (self.supported_isos.first(), self.supported_isos.last()) {
            (Some(&min), Some(&max)) => Ok((min, max)),
            // Default Fujifilm ISO range if not queried
            _ => Ok((100, 12800)),
        }
    }

    async fn get_iso_speeds(&self) -> Result<Vec<i32>, DriverError> {
        Ok(self.supported_isos.clone())
    }

    fn long_exposure_noise_reduction(&self) -> LongExposureNoiseReduction {
        if self.long_exposure_nr {
            LongExposureNoiseReduction::StaysOn
        } else {
            LongExposureNoiseReduction::Off
        }
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported) // Fujifilm cameras don't support offset
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DriverError> {
        self.live_view_frame().await
    }
}
