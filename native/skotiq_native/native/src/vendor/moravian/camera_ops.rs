//! `CameraDriver` implementation for `MoravianCamera`.

use super::*;

#[async_trait]
impl CameraDriver for MoravianCamera {
    fn capabilities(&self) -> CameraCapabilities {
        self.core.capabilities.clone()
    }

    fn get_sensor_info(&self) -> SensorInfo {
        self.core.sensor_info.clone()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        self.core.require_connected()?;
        let sdk = self.library.lock().await?;
        self.status(sdk.api())
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = self.library.lock().await?;
        self.begin(sdk.api(), &params)
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = self.library.lock().await?;
        self.abort(sdk.api());
        Ok(())
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        self.core.require_connected()?;
        self.wait_and_read().await
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.core.require_connected()?;
        if self.exposure.is_none() {
            return Ok(true);
        }
        let sdk = self.library.lock().await?;
        self.poll_complete(sdk.api())
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_cool {
            return Err(DriverError::NotSupported);
        }
        let sdk = self.library.lock().await?;
        self.cooler(sdk.api(), enabled, target_temp)
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        let sdk = self.library.lock().await?;
        let session = self.session(sdk.api());
        session
            .value(GV_CHIP_TEMPERATURE)
            .map(f64::from)
            .ok_or_else(|| self.failure(&session, "read the sensor temperature"))
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.core.require_connected()?;
        let sdk = self.library.lock().await?;
        let session = self.session(sdk.api());
        cooler_percent(&session).ok_or_else(|| self.failure(&session, "read the cooler power"))
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if !self.core.capabilities.can_set_gain {
            return Err(DriverError::NotSupported);
        }
        let sdk = self.library.lock().await?;
        let session = self.session(sdk.api());
        self.apply_gain(&session, gain)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Kept for the next exposure, which applies the binning its own
    /// parameters name (as for every native camera).
    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let caps = &self.core.capabilities;
        if bin_x < 1 || bin_y < 1 || bin_x > caps.max_bin_x || bin_y > caps.max_bin_y {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' bins from 1x1 to {}x{}, not {}x{}",
                self.core.name, caps.max_bin_x, caps.max_bin_y, bin_x, bin_y
            )));
        }
        if bin_x != bin_y && !self.limits.asymmetric_binning {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' cannot bin {}x{}: its horizontal and vertical binning must match",
                self.core.name, bin_x, bin_y
            )));
        }
        self.core.bin_x = bin_x;
        self.core.bin_y = bin_y;
        Ok(())
    }

    /// Kept for metadata until the next exposure, which reads the region its
    /// own parameters name. Binned pixels, like `ExposureParams::subframe`.
    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        self.core.require_connected()?;
        if let Some(sf) = &subframe {
            if !self.core.capabilities.can_subframe {
                return Err(DriverError::NotSupported);
            }
            sdk_roi(
                self.core.sensor_info.width,
                self.core.sensor_info.height,
                self.core.bin_x as u32,
                self.core.bin_y as u32,
                Some(sf),
                false,
            )
            .map_err(|reason| {
                DriverError::InvalidParameter(format!(
                    "Moravian camera '{}': {}",
                    self.core.name, reason
                ))
            })?;
        }
        self.core.subframe = subframe;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(self.core.gain)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((self.core.bin_x, self.core.bin_y))
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        self.core.require_connected()?;
        if self.read_modes.is_empty() {
            return Ok(vec![ReadoutMode {
                name: "Normal".to_string(),
                description: "Standard readout mode".to_string(),
                index: 0,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            }]);
        }
        Ok(self
            .read_modes
            .iter()
            .enumerate()
            .map(|(index, name)| ReadoutMode {
                name: name.clone(),
                description: name.clone(),
                index: index as i32,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            })
            .collect())
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let index = u32::try_from(mode.index).map_err(|_| {
            DriverError::InvalidParameter(format!("read mode index {} is not valid", mode.index))
        })?;
        let sdk = self.library.lock().await?;
        let session = self.session(sdk.api());
        self.apply_read_mode(&session, index)?;
        if let Some(max_adu) = full_scale(&session) {
            self.core.sensor_info.max_adu = max_adu;
            self.core.sensor_info.bit_depth = bits_for(max_adu);
        }
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        match self.limits.max_gain {
            Some(max) => Ok((0, i32::from(max))),
            None => Err(DriverError::NotSupported),
        }
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        self.core.require_connected()?;
        Err(DriverError::NotSupported)
    }
}
