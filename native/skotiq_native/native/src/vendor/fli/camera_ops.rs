//! `CameraDriver` implementation for `FliCamera`.

use super::*;
use crate::camera_core::{unpack_samples, Frame, SampleLayout};

/// The set-point that stands for "cooler off": libfli has no off switch and
/// takes -55 to 45 C (libfli.c FLISetTemperature). NINA parks it at 40 C;
/// a lower park keeps the cooler working on a warm night.
const FLI_COOLER_OFF_SETPOINT_C: f64 = 40.0;

#[async_trait]
impl CameraDriver for FliCamera {
    fn exposure_abort(&self) -> Option<std::sync::Arc<dyn skotiq_device::ExposureAbort>> {
        Some(self.core.abort_handle())
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        // The heartbeat reads this. A camera that answered the temperature at
        // connect and stops answering is gone (unplugged, powered off).
        let sensor_temp = {
            let mut temp: c_double = 0.0;
            // SAFETY: self.handle is valid (connection checked at entry); `temp` is a valid stack pointer.
            match unsafe { (sdk.get_temperature)(self.handle, &mut temp) } {
                0 => Some(temp),
                code if self.core.capabilities.can_cool => {
                    return Err(DriverError::SdkError(format!(
                        "FLI camera '{}' stopped answering: {}",
                        self.core.name,
                        fli_error_text(code)
                    )));
                }
                _ => None,
            }
        };

        let cooler_power = {
            let mut power: c_double = 0.0;
            // SAFETY: self.handle is valid (connection checked at entry); `power` is a valid stack pointer.
            if unsafe { (sdk.get_cooler_power)(self.handle, &mut power) } == 0 {
                Some(power)
            } else {
                None
            }
        };

        let exposure_remaining = if self.core.state == CameraState::Exposing {
            let mut timeleft: c_long = 0;
            // SAFETY: self.handle is valid; `timeleft` is a valid stack pointer.
            if unsafe { (sdk.get_exposure_status)(self.handle, &mut timeleft) } == 0 {
                Some(timeleft as f64 / 1000.0) // Convert from ms to seconds
            } else {
                None
            }
        } else {
            None
        };

        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp,
            cooler_power,
            // libfli has no cooler switch and no getter for the set-point
            // FLISetTemperature writes (libfli.h), so both are known only once
            // this connection has set them; the power above is the camera's.
            target_temp: self.core.cooler().target_c,
            cooler_on: if self.core.capabilities.can_cool {
                self.core.cooler().enabled
            } else {
                Some(false)
            },
            gain: self.core.gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;
        self.core.clear_abort();

        let area = image_area(
            self.visible,
            params.subframe.as_ref(),
            params.bin_x,
            params.bin_y,
        )?;
        let exposure_ms = exposure_ms(params.duration_secs)?;

        let sdk = FliSdk::lock().await?;

        self.write_binning(&sdk, params.bin_x, params.bin_y)?;
        self.core.bin_x = params.bin_x;
        self.core.bin_y = params.bin_y;
        self.write_image_area(&sdk, area)?;
        self.core.subframe = params.subframe.clone();

        // Dark/bias frames must keep the mechanical shutter CLOSED
        // (FLI_FRAME_TYPE_DARK); light/flat frames open it (FLI_FRAME_TYPE_NORMAL).
        // A dark exposed as NORMAL is light-contaminated, and the calibration
        // master built from it is worthless.
        let fli_frame_type = if params.frame_type.opens_shutter() {
            FLI_FRAME_TYPE_NORMAL
        } else {
            FLI_FRAME_TYPE_DARK
        };
        // SAFETY: self.handle is valid (connection checked at entry); frame type is a valid FLI frame-type constant.
        let result = unsafe { (sdk.set_frame_type)(self.handle, fli_frame_type) };
        check_fli_error(result, "set frame type")?;

        // SAFETY: self.handle is valid; `exposure_ms` is a pass-by-value c_long.
        let result = unsafe { (sdk.set_exposure_time)(self.handle, exposure_ms) };
        check_fli_error(result, "set exposure time")?;

        // SAFETY: self.handle is valid; FLIExposeFrame takes only the device handle.
        let result = unsafe { (sdk.expose_frame)(self.handle) };
        check_fli_error(result, "expose frame")?;

        // The frame records what the camera was given, in whole milliseconds.
        self.core.exposure_duration = exposure_ms as f64 / 1000.0;
        self.core.state = CameraState::Exposing;

        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        // SAFETY: self.handle is valid (connection checked at entry).
        let result = unsafe { (sdk.cancel_exposure)(self.handle) };
        check_fli_error(result, "cancel exposure")?;

        self.core.state = CameraState::Idle;
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        let mut status: c_long = 0;
        // SAFETY: self.handle is valid (connection checked at entry); `status` is a valid stack pointer.
        let result = unsafe { (sdk.get_device_status)(self.handle, &mut status) };
        check_fli_error(result, "get device status")?;

        let mut time_left: c_long = 0;
        // SAFETY: self.handle is valid; `time_left` is a valid stack pointer.
        let result = unsafe { (sdk.get_exposure_status)(self.handle, &mut time_left) };
        check_fli_error(result, "get exposure status")?;

        Ok(frame_is_complete(status, time_left))
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        self.core.state = CameraState::Downloading;

        let area = self.image_area;
        let width = area.width as usize;
        let height = area.height as usize;

        // FLIGrabRow writes `width` 16-bit pixels in host byte order (libfli
        // converts the camera's big-endian words); every supported host is
        // little-endian.
        let row_bytes = width * 2;
        let mut byte_buffer: Vec<u8> = vec![0u8; row_bytes * height];

        for row in 0..height {
            if self.core.abort_requested() {
                // The rest of the frame is discarded, as after a failed row.
                // SAFETY: self.handle is valid.
                let _ = unsafe { (sdk.cancel_exposure)(self.handle) };
                self.core.state = CameraState::Idle;
                return Err(self.core.read_given_up());
            }
            let row_offset = row * row_bytes;
            // SAFETY: row < height, so row_offset + row_bytes <= byte_buffer.len(); the pointer stays inside the allocation.
            let row_ptr = unsafe { byte_buffer.as_mut_ptr().add(row_offset) };
            // SAFETY: self.handle is valid (connection checked at entry); `row_ptr` points to `row_bytes` bytes inside byte_buffer. FLIGrabRow's third argument is a PIXEL count (fli_ccd.cpp:667 passes the pixel width), so it writes exactly `width` u16 = `row_bytes` bytes.
            let result = unsafe { (sdk.grab_row)(self.handle, row_ptr, width) };
            if result != 0 {
                let text = fli_error_text(result);
                tracing::error!(
                    "FLIGrabRow failed for camera '{}' at row {} of {} ({} pixels): {}",
                    self.core.name,
                    row + 1,
                    height,
                    width,
                    text
                );
                // Discard the rest of the frame so the camera is ready for the
                // next exposure (NINA FLICamera.DownloadExposure).
                // SAFETY: self.handle is valid.
                let _ = unsafe { (sdk.cancel_exposure)(self.handle) };
                self.core.state = CameraState::Error;
                return Err(DriverError::SdkError(format!(
                    "Download from FLI camera '{}' stopped at row {} of {}: {}",
                    self.core.name,
                    row + 1,
                    height,
                    text
                )));
            }
        }

        let data = unpack_samples(&byte_buffer, SampleLayout::U16Little);

        let temperature = {
            let mut temp: c_double = 0.0;
            // SAFETY: self.handle is valid; `temp` is a valid stack pointer.
            if unsafe { (sdk.get_temperature)(self.handle, &mut temp) } == 0 {
                Some(temp)
            } else {
                None
            }
        };

        self.core.state = CameraState::Idle;

        Ok(Frame {
            temperature,
            ..self.core.frame(
                area.width,
                area.height,
                data,
                self.core.sensor_info.bit_depth,
                self.core.sensor_info.bayer_pattern,
            )
        }
        .into_image())
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        // FLISetTemperature *is* the enable on this SDK: cooling needs a
        // setpoint, so when the caller names none, the one this connection
        // last set, never an invented temperature.
        let setpoint_c = if enabled {
            target_temp.or(self.core.cooler().target_c).ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "FLI camera '{}' needs a target temperature to cool: \
                     the camera cannot report the one it holds",
                    self.core.name
                ))
            })?
        } else {
            FLI_COOLER_OFF_SETPOINT_C
        };

        // SAFETY: self.handle is valid (connection checked at entry); `setpoint_c` is a pass-by-value c_double.
        let result = unsafe { (sdk.set_temperature)(self.handle, setpoint_c) };
        check_fli_error(result, "set temperature")?;

        self.core.update_cooler(|cooler| {
            cooler.enabled = Some(enabled);
            if enabled {
                cooler.target_c = Some(setpoint_c);
            }
        });
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        let mut temp: c_double = 0.0;

        // SAFETY: self.handle is valid (connection checked at entry); `temp` is a valid stack pointer.
        let result = unsafe { (sdk.get_temperature)(self.handle, &mut temp) };
        check_fli_error(result, "get temperature")?;

        Ok(temp)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;

        let sdk = FliSdk::lock().await?;

        let mut power: c_double = 0.0;

        // SAFETY: self.handle is valid (connection checked at entry); `power` is a valid stack pointer.
        let result = unsafe { (sdk.get_cooler_power)(self.handle, &mut power) };
        check_fli_error(result, "get cooler power")?;

        Ok(power)
    }

    async fn set_gain(&mut self, _gain: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;

        // The image area's lower-right corner depends on the binning.
        let area = image_area(self.visible, self.core.subframe.as_ref(), bin_x, bin_y)?;
        let sdk = FliSdk::lock().await?;
        self.write_binning(&sdk, bin_x, bin_y)?;
        self.core.bin_x = bin_x;
        self.core.bin_y = bin_y;
        self.write_image_area(&sdk, area)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;

        let area = image_area(
            self.visible,
            subframe.as_ref(),
            self.core.bin_x,
            self.core.bin_y,
        )?;
        let sdk = FliSdk::lock().await?;
        self.write_image_area(&sdk, area)?;
        self.core.subframe = subframe;
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // libfli exposes no gain control and no gain bounds to report.
        Err(DriverError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;

        // libfli exposes no offset control and no offset bounds to report.
        Err(DriverError::NotSupported)
    }
}
