//! A device layer with no devices behind it, for simulated runs and tests.

use super::*;
use async_trait::async_trait;

/// A null implementation for testing without real devices
pub struct NullDeviceOps;

#[async_trait]
impl MountOps for NullDeviceOps {
    async fn mount_slew_to_coordinates(
        &self,
        _mount_id: &str,
        ra: f64,
        dec: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Slew to RA={:.4}h, Dec={:.4}°", ra, dec);
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn mount_abort_slew(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Aborting mount slew");
        Ok(())
    }

    async fn mount_get_coordinates(&self, _mount_id: &str) -> DeviceResult<(f64, f64)> {
        Ok((12.0, 45.0))
    }

    async fn mount_sync(&self, _mount_id: &str, _ra: f64, _dec: f64) -> DeviceResult<()> {
        Ok(())
    }

    async fn mount_park(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Parking mount");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn mount_unpark(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Unparking mount");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn mount_find_home(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Homing mount");
        Ok(())
    }

    async fn mount_is_at_home(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(true)
    }

    async fn mount_is_slewing(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn mount_is_parked(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn mount_can_flip(&self, _mount_id: &str) -> DeviceResult<bool> {
        tracing::info!("[NULL] Mount supports flipping");
        Ok(true)
    }

    async fn mount_side_of_pier(&self, _mount_id: &str) -> DeviceResult<crate::meridian::PierSide> {
        Ok(crate::meridian::PierSide::East)
    }

    async fn mount_is_tracking(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(true)
    }

    async fn mount_set_tracking(&self, _mount_id: &str, enabled: bool) -> DeviceResult<()> {
        tracing::info!("[NULL] Set tracking: {}", enabled);
        Ok(())
    }
}

#[async_trait]
impl CameraOps for NullDeviceOps {
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData> {
        let ExposureRequest {
            duration_secs,
            gain,
            offset,
            subframe,
            ..
        } = request;
        if subframe.is_some() {
            return Err(DeviceError::unsupported(
                "Camera subframes are not supported by this device backend",
            ));
        }
        tracing::info!("[NULL] Starting {:.1}s exposure", duration_secs);
        tokio::time::sleep(std::time::Duration::from_secs_f64(duration_secs)).await;

        Ok(ImageData {
            width: 4144,
            height: 2822,
            data: vec![0u16; 4144 * 2822],
            bits_per_pixel: 16,
            exposure_secs: duration_secs,
            gain,
            offset,
            temperature: Some(-10.0),
            filter: None,
            timestamp: chrono::Utc::now().timestamp(),
            sensor_type: Some("Monochrome".to_string()), // Default to Mono
            color_filter: None,
            camera_file: None,
        })
    }

    async fn camera_abort_exposure(&self, _camera_id: &str) -> DeviceResult<()> {
        Ok(())
    }

    async fn camera_set_cooler(
        &self,
        _camera_id: &str,
        enabled: bool,
        target: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Cooler: enabled={}, target={}°C", enabled, target);
        Ok(())
    }

    async fn camera_get_temperature(&self, _camera_id: &str) -> DeviceResult<f64> {
        Ok(-10.0)
    }

    async fn camera_get_cooler_power(&self, _camera_id: &str) -> DeviceResult<f64> {
        Ok(50.0)
    }
}

#[async_trait]
impl FocuserOps for NullDeviceOps {
    async fn focuser_move_to(&self, _focuser_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("[NULL] Moving focuser to {}", position);
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn focuser_get_position(&self, _focuser_id: &str) -> DeviceResult<i32> {
        Ok(25000)
    }

    async fn focuser_is_moving(&self, _focuser_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn focuser_get_temperature(&self, _focuser_id: &str) -> DeviceResult<Option<f64>> {
        Ok(Some(15.0))
    }

    async fn focuser_halt(&self, _focuser_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting focuser");
        Ok(())
    }
}

#[async_trait]
impl FilterWheelOps for NullDeviceOps {
    async fn filterwheel_set_position(&self, _fw_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("[NULL] Setting filter to position {}", position);
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn filterwheel_get_position(&self, _fw_id: &str) -> DeviceResult<i32> {
        Ok(1)
    }

    async fn filterwheel_get_names(&self, _fw_id: &str) -> DeviceResult<Vec<String>> {
        Ok(vec![
            "L".into(),
            "R".into(),
            "G".into(),
            "B".into(),
            "Ha".into(),
            "OIII".into(),
            "SII".into(),
        ])
    }

    async fn filterwheel_set_filter_by_name(&self, _fw_id: &str, name: &str) -> DeviceResult<i32> {
        let pos = match name.to_uppercase().as_str() {
            "L" | "LUMINANCE" => 1,
            "R" | "RED" => 2,
            "G" | "GREEN" => 3,
            "B" | "BLUE" => 4,
            "HA" | "H-ALPHA" => 5,
            "OIII" | "O3" => 6,
            "SII" | "S2" => 7,
            _ => 1,
        };
        self.filterwheel_set_position(_fw_id, pos).await?;
        Ok(pos)
    }
}

#[async_trait]
impl RotatorOps for NullDeviceOps {
    async fn rotator_move_to(&self, _rotator_id: &str, angle: f64) -> DeviceResult<()> {
        tracing::info!("[NULL] Rotating to {}°", angle);
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        let current = self.rotator_get_angle(rotator_id).await?;
        self.rotator_move_to(rotator_id, current + delta).await
    }

    async fn rotator_get_angle(&self, _rotator_id: &str) -> DeviceResult<f64> {
        Ok(0.0)
    }

    async fn rotator_halt(&self, _rotator_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting rotator");
        Ok(())
    }
}

#[async_trait]
impl GuiderOps for NullDeviceOps {
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        _settle_timeout: f64,
        _ra_only: bool,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NULL] Dithering {} pixels, settle <{} px in {}s",
            pixels,
            settle_pixels,
            settle_time
        );
        tokio::time::sleep(std::time::Duration::from_secs_f64(settle_time.min(5.0))).await;
        Ok(())
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        Ok(GuidingStatus {
            is_guiding: true,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        // Synthetic well-calibrated mount (axes 90° apart) so simulation
        // mode doesn't fail post-start validation.
        Ok(GuidingCalibration {
            is_calibrated: true,
            ra_angle_deg: Some(0.0),
            dec_angle_deg: Some(90.0),
        })
    }

    async fn guider_start(
        &self,
        _settle_pixels: f64,
        settle_time: f64,
        _settle_timeout: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Starting guiding");
        tokio::time::sleep(std::time::Duration::from_secs_f64(settle_time.min(5.0))).await;
        Ok(())
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        tracing::info!("[NULL] Stopping guiding");
        Ok(())
    }
}

#[async_trait]
impl DomeOps for NullDeviceOps {
    async fn dome_open(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Opening dome shutter");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_close(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Closing dome shutter");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_park(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Parking dome");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_get_shutter_status(&self, _dome_id: &str) -> DeviceResult<String> {
        Ok("Open".to_string())
    }
}

#[async_trait]
impl CoverCalibratorOps for NullDeviceOps {
    async fn cover_calibrator_open_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Opening cover");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn cover_calibrator_close_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Closing cover");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn cover_calibrator_halt_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting cover");
        Ok(())
    }

    async fn cover_calibrator_calibrator_on(
        &self,
        _device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Turning calibrator on at brightness {}", brightness);
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        Ok(())
    }

    async fn cover_calibrator_calibrator_off(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Turning calibrator off");
        Ok(())
    }

    async fn cover_calibrator_get_cover_state(&self, _device_id: &str) -> DeviceResult<i32> {
        // ASCOM CoverState::Open == 3; the pre-flip cover check treats
        // anything ≠ Closed as "ok to slew", so Open is the safe stub default.
        Ok(3)
    }

    async fn cover_calibrator_get_calibrator_state(&self, _device_id: &str) -> DeviceResult<i32> {
        // ASCOM CalibratorState::Ready == 3 — the "no-wait" state, so the flat
        // wizard does not loop waiting for the panel to warm up in tests.
        Ok(3)
    }

    async fn cover_calibrator_get_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
        Ok(128)
    }

    async fn cover_calibrator_get_max_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
        Ok(255)
    }
}

#[async_trait]
impl SafetyOps for NullDeviceOps {
    async fn safety_is_safe(&self, _safety_id: Option<&str>) -> DeviceResult<bool> {
        // Tests using NullDeviceOps need WeatherUnsafe to never fire; returning
        // true unconditionally is the simplest contract for that.
        tracing::info!("[NULL] Safety check: safe");
        Ok(true)
    }
}

#[async_trait]
impl PlateSolveOps for NullDeviceOps {
    async fn plate_solve(
        &self,
        _image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        _hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        tracing::info!("[NULL] Plate solving");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        let ra_degrees = hint_ra.ok_or_else(|| {
            "NullDeviceOps plate_solve requires hint_ra in simulation mode".to_string()
        })?;
        let dec_degrees = hint_dec.ok_or_else(|| {
            "NullDeviceOps plate_solve requires hint_dec in simulation mode".to_string()
        })?;

        Ok(PlateSolveResult {
            ra_degrees,
            dec_degrees,
            pixel_scale: 1.5,
            rotation: 0.0,
            up_position_angle_deg: 0.0,
            success: true,
            wcs: None,
        })
    }
}

#[async_trait]
impl FrameStoreOps for NullDeviceOps {
    async fn save_fits(
        &self,
        _image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NULL] Saving FITS to {} ({})",
            file_path,
            frame_ctx.log_label()
        );
        Ok(())
    }

    async fn measure_light_frame(
        &self,
        _image_data: &ImageData,
    ) -> DeviceResult<LightFrameMeasurement> {
        // A plausible random HFR (1.5-3.0 px) and star count, so tests that
        // grade frames see a varying, non-trivial measurement without a real
        // star detector.
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let hfr = rng.gen_range(1.5..3.0);
        let star_count = rng.gen_range(10..50);
        tracing::debug!("[NULL] Measured HFR {:.2} over {} stars", hfr, star_count);
        Ok(LightFrameMeasurement {
            hfr: Some(hfr),
            star_count: Some(star_count),
            ..LightFrameMeasurement::default()
        })
    }
}

#[async_trait]
impl OperatorNotifyOps for NullDeviceOps {
    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        match explicit_transports {
            Some(t) if !t.is_empty() => tracing::info!(
                "[NOTIFICATION][{}] {}: {} (transports: {})",
                level,
                title,
                message,
                t.join(",")
            ),
            _ => tracing::info!("[NOTIFICATION][{}] {}: {}", level, title, message),
        }
        Ok(())
    }

    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Polar Align Update: {:?}", result);
        Ok(())
    }
}

impl ConnectionOps for NullDeviceOps {}

impl SiteOps for NullDeviceOps {
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        None
    }
}
