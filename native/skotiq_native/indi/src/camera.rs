//! INDI Camera wrapper
//!
//! Provides high-level camera control via INDI protocol.
//!
//! # `unwrap_or(false)` policy
//!
//! Each `get_switch(...).unwrap_or(false)` in this module is reading an
//! optional INDI CCD switch (`CCD_COOLER`, `CCD_FRAME_TYPE`) where `None`
//! means the property has not yet been streamed by the background reader
//! OR the driver does not implement that frame-type alternative (e.g.
//! Bias-less cameras). The wrappers fall through to a documented sentinel:
//! `is_cooler_on` → `false`, `get_frame_type` → `CcdFrameType::Light`
//! (the safe ASCOM-equivalent default). Exposure-state probes return
//! "not exposing" if the property is absent, which is correct because the
//! driver cannot be holding state we did not see streamed.

use crate::client::IndiClient;
use crate::error::{IndiError, IndiResult};
use crate::protocol::{standard_properties::*, CcdFrameType};

/// Bayer / CFA pattern parsed from INDI `CCD_CFA`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndiBayerPattern {
    pub pattern: String,
    pub offset_x: Option<i32>,
    pub offset_y: Option<i32>,
}

/// Active CCD readout mode (element name + on-state).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndiReadoutMode {
    pub element: String,
    pub label: String,
}

use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// INDI Camera device wrapper
pub struct IndiCamera {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
}

impl IndiCamera {
    /// Create a new INDI camera wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Connect to the camera
    pub async fn connect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.connect_device(&self.device_name).await
    }

    /// Disconnect from the camera
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.disconnect_device(&self.device_name).await
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    /// Start an exposure
    pub async fn start_exposure(&self, duration_secs: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(
                &self.device_name,
                CCD_EXPOSURE,
                "CCD_EXPOSURE_VALUE",
                duration_secs,
            )
            .await
    }

    /// Abort the current exposure
    pub async fn abort_exposure(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, CCD_ABORT_EXPOSURE, "ABORT", true)
            .await
    }

    /// Set binning
    pub async fn set_binning(&self, bin_x: i32, bin_y: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_numbers(
                &self.device_name,
                CCD_BINNING,
                // Why: i32 binning values -> f64 (INDI wire format); lossless.
                &[("HOR_BIN", f64::from(bin_x)), ("VER_BIN", f64::from(bin_y))],
            )
            .await
    }

    /// Get current binning if `CCD_BINNING` has been defined.
    ///
    /// Returns:
    /// * `Ok(Some((x, y)))` — both binning elements are defined.
    /// * `Ok(None)` — `CCD_BINNING` (or one of its elements) has not been
    ///   defined yet. Caller must decide whether to wait, retry, or treat as
    ///   "unknown".
    /// * `Err(_)` — reserved for richer future error reporting; current
    ///   implementation never errors.
    ///
    /// Why: the previous bool-fallback path silently substituted `(1, 1)` for
    /// any driver that hadn't sent `defNumberVector` for `CCD_BINNING`,
    /// producing wrong-but-plausible values.
    pub async fn try_get_binning(&self) -> Result<Option<(i32, i32)>, IndiError> {
        let client = self.client.read().await;
        let bin_x = client
            .get_number(&self.device_name, CCD_BINNING, "HOR_BIN")
            .await;
        let bin_y = client
            .get_number(&self.device_name, CCD_BINNING, "VER_BIN")
            .await;
        match (bin_x, bin_y) {
            // Why: INDI wire format is f64; binning is small (1..16). f64 -> i32
            // saturates per Rust 1.45 spec, so a driver-bug huge value caps at
            // i32::MAX rather than wrapping.
            (Some(x), Some(y)) => Ok(Some((x as i32, y as i32))),
            _ => Ok(None),
        }
    }

    /// Get current binning, waiting up to `timeout` for the property to be
    /// defined before falling back to `(1, 1)` with a logged warning.
    ///
    /// Why: drivers may publish `CCD_BINNING` shortly after the device is
    /// reported as connected. Bridge dispatch needs *some* value to return,
    /// but the substitution must be visible — hence
    /// `tracing::warn!`. Use [`Self::try_get_binning`] for the strict variant.
    pub async fn get_binning_or_default(&self, timeout: Duration) -> Result<(i32, i32), IndiError> {
        if let Some(value) = wait_for_optional(timeout, || self.try_get_binning()).await? {
            return Ok(value);
        }
        tracing::warn!(
            device = %self.device_name,
            // Why: Duration::as_millis() returns u128 wall-clock duration; in
            // practice a tracing timeout is seconds-scale and fits in u64.
            // u128 -> u64 saturates per Rust 1.45 spec.
            timeout_ms = timeout.as_millis() as u64,
            "INDI camera CCD_BINNING was not defined within timeout; falling back to (1, 1). \
             Downstream binning-dependent calculations may be incorrect until the property arrives."
        );
        Ok((1, 1))
    }

    /// Set frame (ROI)
    pub async fn set_frame(&self, x: i32, y: i32, width: i32, height: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_numbers(
                &self.device_name,
                CCD_FRAME,
                // Why: i32 ROI values -> f64 (INDI wire format); lossless.
                &[
                    ("X", f64::from(x)),
                    ("Y", f64::from(y)),
                    ("WIDTH", f64::from(width)),
                    ("HEIGHT", f64::from(height)),
                ],
            )
            .await
    }

    /// Get frame (ROI) if `CCD_FRAME` is fully defined.
    ///
    /// Returns:
    /// * `Ok(Some((x, y, w, h)))` — all four elements are defined.
    /// * `Ok(None)` — `CCD_FRAME` is not (yet) defined or any element is
    ///   missing. A partially-defined frame is meaningless and is treated as
    ///   undefined.
    /// * `Err(_)` — reserved for future error reporting.
    ///
    /// Why: defaulting to `(0, 0, 0, 0)` would be a valid-looking but
    /// completely wrong ROI.
    pub async fn try_get_frame(&self) -> Result<Option<(i32, i32, i32, i32)>, IndiError> {
        let client = self.client.read().await;
        let x = client.get_number(&self.device_name, CCD_FRAME, "X").await;
        let y = client.get_number(&self.device_name, CCD_FRAME, "Y").await;
        let width = client
            .get_number(&self.device_name, CCD_FRAME, "WIDTH")
            .await;
        let height = client
            .get_number(&self.device_name, CCD_FRAME, "HEIGHT")
            .await;
        match (x, y, width, height) {
            // Why: INDI wire format is f64; ROI is bounded by sensor extent.
            // f64 -> i32 saturates per Rust 1.45 spec on driver-bug overflow.
            (Some(x), Some(y), Some(w), Some(h)) => {
                Ok(Some((x as i32, y as i32, w as i32, h as i32)))
            }
            _ => Ok(None),
        }
    }

    /// Get frame, waiting up to `timeout`. If `CCD_FRAME` is still undefined,
    /// fall back to the full sensor extent (with a logged warning); if the
    /// sensor dimensions are also unknown, return `IndiError::PropertyNotFound`
    /// rather than fabricating a 1×1 default.
    ///
    /// Why: a silent 0×0 ROI crashes downstream image-pipeline math.
    pub async fn get_frame_or_default(
        &self,
        timeout: Duration,
    ) -> Result<(i32, i32, i32, i32), IndiError> {
        if let Some(value) = wait_for_optional(timeout, || self.try_get_frame()).await? {
            return Ok(value);
        }
        let sensor_w = self.get_sensor_width().await;
        let sensor_h = self.get_sensor_height().await;
        match (sensor_w, sensor_h) {
            (Some(w), Some(h)) => {
                tracing::warn!(
                        device = %self.device_name,
                        // Why: Duration::as_millis() returns u128 wall-clock duration; in
                // practice a tracing timeout is seconds-scale and fits in u64.
                // u128 -> u64 saturates per Rust 1.45 spec.
                timeout_ms = timeout.as_millis() as u64,
                        sensor_w = w,
                        sensor_h = h,
                        "INDI camera CCD_FRAME was not defined within timeout; falling back to full sensor extent."
                    );
                Ok((0, 0, w, h))
            }
            _ => Err(IndiError::PropertyNotFound {
                device: self.device_name.clone(),
                property: CCD_FRAME.to_string(),
            }),
        }
    }

    /// Set cooler target temperature
    pub async fn set_temperature(&self, temp_celsius: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_number(
                &self.device_name,
                CCD_TEMPERATURE,
                "CCD_TEMPERATURE_VALUE",
                temp_celsius,
            )
            .await
    }

    /// Get current temperature
    pub async fn get_temperature(&self) -> Result<f64, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_TEMPERATURE, "CCD_TEMPERATURE_VALUE")
            .await
            .ok_or_else(|| "Temperature not available".to_string())
    }

    /// Enable/disable cooler
    pub async fn set_cooler(&self, enabled: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        if enabled {
            client
                .set_switch(&self.device_name, CCD_COOLER, "COOLER_ON", true)
                .await
        } else {
            client
                .set_switch(&self.device_name, CCD_COOLER, "COOLER_OFF", true)
                .await
        }
    }

    /// Check if cooler is on
    pub async fn is_cooler_on(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, CCD_COOLER, "COOLER_ON")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false / Light.
            .unwrap_or(false)
    }

    /// Set gain
    pub async fn set_gain(&self, gain: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            // Why: i32 gain -> f64 (INDI wire); lossless.
            .set_number(&self.device_name, CCD_GAIN, "GAIN", f64::from(gain))
            .await
    }

    /// Get gain
    pub async fn get_gain(&self) -> Result<i32, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_GAIN, "GAIN")
            .await
            // Why: INDI wire f64 -> i32. Gain is bounded by sensor (typically
            // 0..600); f64 -> i32 saturates per Rust 1.45 spec on driver bug.
            .map(|g| g as i32)
            .ok_or_else(|| "Gain not available".to_string())
    }

    /// Set offset
    pub async fn set_offset(&self, offset: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            // Why: i32 offset -> f64 (INDI wire); lossless.
            .set_number(&self.device_name, CCD_OFFSET, "OFFSET", f64::from(offset))
            .await
    }

    /// Get offset
    pub async fn get_offset(&self) -> Result<i32, String> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_OFFSET, "OFFSET")
            .await
            // Why: INDI wire f64 -> i32; offset bounded by sensor (typically 0..255).
            // f64 -> i32 saturates per Rust 1.45 spec.
            .map(|o| o as i32)
            .ok_or_else(|| "Offset not available".to_string())
    }

    /// Enable BLOB transfer for image data
    pub async fn enable_blob(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client.enable_blob(&self.device_name).await
    }
    // Sensor information (CCD_INFO property)

    /// Get sensor width in pixels
    pub async fn get_sensor_width(&self) -> Option<i32> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_MAX_X")
            .await
            // Why: INDI wire f64 -> i32 sensor width. Real sensors are <= 65k.
            // f64 -> i32 saturates per Rust 1.45 spec on driver-bug overflow.
            .map(|v| v as i32)
    }

    /// Get sensor height in pixels
    pub async fn get_sensor_height(&self) -> Option<i32> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_MAX_Y")
            .await
            // Why: INDI wire f64 -> i32 sensor height. Same bounds as width.
            .map(|v| v as i32)
    }

    /// Get pixel size X in microns
    pub async fn get_pixel_size_x(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_PIXEL_SIZE_X")
            .await
    }

    /// Get pixel size Y in microns
    pub async fn get_pixel_size_y(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_PIXEL_SIZE_Y")
            .await
    }

    /// Get bits per pixel
    pub async fn get_bits_per_pixel(&self) -> Option<i32> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_BITSPERPIXEL")
            .await
            // Why: INDI wire f64 -> i32 bit depth (typically 8/10/12/14/16/32).
            // f64 -> i32 saturates per Rust 1.45 spec.
            .map(|v| v as i32)
    }

    // Binning limits

    /// Default maximum-bin used when the driver does not advertise one.
    ///
    /// 4× is chosen because it is the most common ceiling across CMOS and CCD
    /// drivers in the field. This value is *only* applied via
    /// `get_max_bin_*_or_default`, which logs a `warn!` so the substitution
    /// is auditable.
    pub const DEFAULT_MAX_BIN: i32 = 4;

    /// Get maximum horizontal binning if `CCD_INFO/CCD_MAX_BIN_X` is defined.
    ///
    /// Returns:
    /// * `Ok(Some(n))` — driver advertises the property.
    /// * `Ok(None)` — driver has not (yet) defined that element. Caller must
    ///   decide whether to wait or apply a logged-default.
    ///
    /// Why: substituting `4` for a driver that does not expose the property
    /// would be a value pulled from thin air and indistinguishable from a
    /// real `4`.
    pub async fn try_get_max_bin_x(&self) -> Result<Option<i32>, IndiError> {
        let client = self.client.read().await;
        Ok(client
            .get_number(&self.device_name, CCD_INFO, "CCD_MAX_BIN_X")
            .await
            // Why: INDI wire f64 -> i32 max bin (typically 1..16); saturates per Rust 1.45.
            .map(|v| v as i32))
    }

    /// Get maximum vertical binning if `CCD_INFO/CCD_MAX_BIN_Y` is defined.
    /// See [`Self::try_get_max_bin_x`].
    pub async fn try_get_max_bin_y(&self) -> Result<Option<i32>, IndiError> {
        let client = self.client.read().await;
        Ok(client
            .get_number(&self.device_name, CCD_INFO, "CCD_MAX_BIN_Y")
            .await
            // Why: INDI wire f64 -> i32 max bin (typically 1..16); saturates per Rust 1.45.
            .map(|v| v as i32))
    }

    /// Get maximum horizontal binning, waiting up to `timeout` and falling
    /// back to [`Self::DEFAULT_MAX_BIN`] with a logged warning.
    pub async fn get_max_bin_x_or_default(&self, timeout: Duration) -> Result<i32, IndiError> {
        if let Some(value) = wait_for_optional(timeout, || self.try_get_max_bin_x()).await? {
            return Ok(value);
        }
        tracing::warn!(
            device = %self.device_name,
            // Why: Duration::as_millis() returns u128 wall-clock duration; in
            // practice a tracing timeout is seconds-scale and fits in u64.
            // u128 -> u64 saturates per Rust 1.45 spec.
            timeout_ms = timeout.as_millis() as u64,
            default = Self::DEFAULT_MAX_BIN,
            "INDI camera CCD_INFO/CCD_MAX_BIN_X not defined within timeout; falling back to default."
        );
        Ok(Self::DEFAULT_MAX_BIN)
    }

    /// Get maximum vertical binning, waiting up to `timeout` and falling back
    /// to [`Self::DEFAULT_MAX_BIN`] with a logged warning.
    pub async fn get_max_bin_y_or_default(&self, timeout: Duration) -> Result<i32, IndiError> {
        if let Some(value) = wait_for_optional(timeout, || self.try_get_max_bin_y()).await? {
            return Ok(value);
        }
        tracing::warn!(
            device = %self.device_name,
            // Why: Duration::as_millis() returns u128 wall-clock duration; in
            // practice a tracing timeout is seconds-scale and fits in u64.
            // u128 -> u64 saturates per Rust 1.45 spec.
            timeout_ms = timeout.as_millis() as u64,
            default = Self::DEFAULT_MAX_BIN,
            "INDI camera CCD_INFO/CCD_MAX_BIN_Y not defined within timeout; falling back to default."
        );
        Ok(Self::DEFAULT_MAX_BIN)
    }

    // Frame type

    /// Set frame type (Light, Bias, Dark, Flat).
    ///
    /// Forces a full `CCD_FRAME_TYPE` vector so only one frame switch is On (ND-).
    pub async fn set_frame_type(&self, frame_type: CcdFrameType) -> IndiResult<()> {
        let mut client = self.client.write().await;
        let element = match frame_type {
            CcdFrameType::Light => "FRAME_LIGHT",
            CcdFrameType::Bias => "FRAME_BIAS",
            CcdFrameType::Dark => "FRAME_DARK",
            CcdFrameType::Flat => "FRAME_FLAT",
        };
        client
            .set_switch_exclusive(&self.device_name, CCD_FRAME_TYPE, element)
            .await
    }

    /// Gain range from `CCD_GAIN` element limits, if advertised.
    pub async fn get_gain_range(&self) -> Option<(i32, i32)> {
        let client = self.client.read().await;
        let limits = if let Some(limits) = client
            .get_number_limits(&self.device_name, CCD_GAIN, "GAIN")
            .await
        {
            limits
        } else {
            client
                .get_number_limits(&self.device_name, "CCD_CONTROLS", "Gain")
                .await?
        };
        Some((
            limits.min.map(|v| v as i32).unwrap_or(0),
            limits.max.map(|v| v as i32).unwrap_or(0),
        ))
    }

    /// Maximum ADU from `CCD_MAX_PIXEL_VALUE` or `CCD_INFO/CCD_MAX_PIXEL`.
    pub async fn get_max_adu(&self) -> Option<i32> {
        let client = self.client.read().await;
        if let Some(v) = client
            .get_number(
                &self.device_name,
                CCD_MAX_PIXEL_VALUE,
                "CCD_MAX_PIXEL_VALUE",
            )
            .await
        {
            return Some(v as i32);
        }
        client
            .get_number(&self.device_name, CCD_INFO, "CCD_MAX_PIXEL")
            .await
            .map(|v| v as i32)
    }

    /// Sensor type from `CCD_SENSOR_TYPE` (first switch that is On).
    pub async fn get_sensor_type(&self) -> Option<String> {
        let client = self.client.read().await;
        let prop = client
            .get_property(&self.device_name, CCD_SENSOR_TYPE)
            .await?;
        for element in &prop.elements {
            if client
                .get_switch(&self.device_name, CCD_SENSOR_TYPE, element)
                .await
                .unwrap_or(false)
            {
                return Some(element.clone());
            }
        }
        None
    }

    /// Bayer pattern from `CCD_CFA` or legacy `CCD_BAYER_PATTERN`.
    pub async fn get_bayer_pattern(&self) -> Option<IndiBayerPattern> {
        let client = self.client.read().await;
        if client.has_property(&self.device_name, CCD_CFA).await {
            let pattern = client
                .get_property_value(&self.device_name, CCD_CFA, "CFA_TYPE")
                .await?;
            let offset_x = client
                .get_number(&self.device_name, CCD_CFA, "CFA_OFFSET_X")
                .await
                .map(|v| v as i32);
            let offset_y = client
                .get_number(&self.device_name, CCD_CFA, "CFA_OFFSET_Y")
                .await
                .map(|v| v as i32);
            return Some(IndiBayerPattern {
                pattern,
                offset_x,
                offset_y,
            });
        }
        client
            .get_property_value(&self.device_name, "CCD_BAYER_PATTERN", "BAYERPAT")
            .await
            .map(|pattern| IndiBayerPattern {
                pattern,
                offset_x: None,
                offset_y: None,
            })
    }

    /// Available readout modes from `CCD_READ_MODE` or `CCD_READOUT_MODE`.
    pub async fn get_readout_modes(&self) -> Vec<IndiReadoutMode> {
        let client = self.client.read().await;
        let property_name = if client.has_property(&self.device_name, CCD_READ_MODE).await {
            CCD_READ_MODE
        } else if client
            .has_property(&self.device_name, "CCD_READOUT_MODE")
            .await
        {
            "CCD_READOUT_MODE"
        } else {
            return Vec::new();
        };

        let prop = match client.get_property(&self.device_name, property_name).await {
            Some(p) => p,
            None => return Vec::new(),
        };

        prop.elements
            .iter()
            .map(|element| IndiReadoutMode {
                element: element.clone(),
                label: prop.label.clone(),
            })
            .collect()
    }

    /// Active readout mode element name, if any.
    pub async fn get_active_readout_mode(&self) -> Option<String> {
        let client = self.client.read().await;
        for property in [CCD_READ_MODE, "CCD_READOUT_MODE"] {
            if !client.has_property(&self.device_name, property).await {
                continue;
            }
            if let Some(prop) = client.get_property(&self.device_name, property).await {
                for element in &prop.elements {
                    if client
                        .get_switch(&self.device_name, property, element)
                        .await
                        .unwrap_or(false)
                    {
                        return Some(element.clone());
                    }
                }
            }
        }
        None
    }

    /// Select readout mode by switch element name.
    pub async fn set_readout_mode(&self, element: &str) -> IndiResult<()> {
        let client = self.client.read().await;
        let property = if client.has_property(&self.device_name, CCD_READ_MODE).await {
            CCD_READ_MODE
        } else {
            "CCD_READOUT_MODE"
        };
        let mut client = self.client.write().await;
        client
            .set_switch_exclusive(&self.device_name, property, element)
            .await
    }

    /// Get current frame type
    pub async fn get_frame_type(&self) -> CcdFrameType {
        let client = self.client.read().await;
        if client
            .get_switch(&self.device_name, CCD_FRAME_TYPE, "FRAME_BIAS")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false / Light.
            .unwrap_or(false)
        {
            CcdFrameType::Bias
        } else if client
            .get_switch(&self.device_name, CCD_FRAME_TYPE, "FRAME_DARK")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false / Light.
            .unwrap_or(false)
        {
            CcdFrameType::Dark
        } else if client
            .get_switch(&self.device_name, CCD_FRAME_TYPE, "FRAME_FLAT")
            .await
            // Why: see the module's `unwrap_or(false)` policy — INDI switch absent → status probe returns false / Light.
            .unwrap_or(false)
        {
            CcdFrameType::Flat
        } else {
            CcdFrameType::Light
        }
    }

    // Exposure state

    /// Check if camera is currently exposing
    pub async fn is_exposing(&self) -> bool {
        let client = self.client.read().await;
        client
            .is_property_busy(&self.device_name, CCD_EXPOSURE)
            .await
    }

    /// Get remaining exposure time in seconds (if available)
    pub async fn get_exposure_remaining(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_EXPOSURE, "CCD_EXPOSURE_VALUE")
            .await
    }

    // Reset to full frame

    /// Reset frame to full sensor size
    pub async fn reset_frame(&self) -> Result<(), String> {
        let width = self
            .get_sensor_width()
            .await
            .ok_or("Sensor width not available")?;
        let height = self
            .get_sensor_height()
            .await
            .ok_or("Sensor height not available")?;
        self.set_frame(0, 0, width, height)
            .await
            .map_err(|e| e.to_string())
    }

    // Cooler power

    /// Get cooler power percentage (if available)
    pub async fn get_cooler_power(&self) -> Option<f64> {
        let client = self.client.read().await;
        client
            .get_number(&self.device_name, CCD_COOLER_POWER, "CCD_COOLER_VALUE")
            .await
    }

    /// Capture an image
    pub async fn capture_image(&self, duration_secs: f64) -> Result<Vec<u8>, String> {
        self.capture_image_with_timeout(duration_secs, None).await
    }

    /// Capture an image with configurable timeout
    pub async fn capture_image_with_timeout(
        &self,
        duration_secs: f64,
        timeout_buffer: Option<Duration>,
    ) -> Result<Vec<u8>, String> {
        let buffer_secs = match timeout_buffer {
            Some(buffer) => buffer,
            None => {
                let client = self.client.read().await;
                Duration::from_secs(client.timeout_config().camera_exposure_buffer_secs)
            }
        };

        // Subscribe to events BEFORE starting exposure to avoid missing the event
        // and clear any stale cached BLOB from a previous exposure.
        let mut rx = {
            let client = self.client.read().await;
            client.clear_blob(&self.device_name, "CCD1", "CCD1").await;
            client.clear_blob(&self.device_name, "CCD2", "CCD2").await;
            client.subscribe()
        };

        // Start exposure
        self.start_exposure(duration_secs).await?;

        // Calculate total timeout: exposure time + buffer
        let timeout = Duration::from_secs_f64(duration_secs) + buffer_secs;
        let start_time = std::time::Instant::now();

        loop {
            if start_time.elapsed() > timeout {
                return Err(format!(
                    "Timeout waiting for image from device '{}' after exposure of {:.1}s + buffer of {:?}. \
                    The camera may have failed to complete the exposure or transfer the image.",
                    self.device_name, duration_secs, buffer_secs
                ));
            }

            match tokio::time::timeout(Duration::from_secs(1), rx.recv()).await {
                Ok(Ok(event)) => {
                    if let crate::IndiEvent::BlobReceived {
                        device,
                        element,
                        data,
                        ..
                    } = event
                    {
                        if device == self.device_name && (element == "CCD1" || element == "CCD2") {
                            return Ok(data);
                        }
                    }
                }
                Ok(Err(e)) => match e {
                    tokio::sync::broadcast::error::RecvError::Lagged(skipped) => {
                        tracing::warn!(
                                "INDI event channel lagged for device '{}' by {} messages; checking cached BLOB state",
                                self.device_name,
                                skipped
                            );
                    }
                    tokio::sync::broadcast::error::RecvError::Closed => {
                        return Err(format!(
                                "Event channel closed for device '{}'. The connection may have been lost.",
                                self.device_name
                            ));
                    }
                },
                Err(_) => {
                    // Timeout on recv (1 second), fall through and check cached BLOB state.
                }
            }

            let cached_blob = {
                let client = self.client.read().await;
                if let Some(data) = client.take_blob(&self.device_name, "CCD1", "CCD1").await {
                    Some(data)
                } else {
                    client.take_blob(&self.device_name, "CCD2", "CCD2").await
                }
            };
            if let Some(data) = cached_blob {
                return Ok(data);
            }
        }
    }

    /// Start exposure and wait for it to complete with timeout
    pub async fn start_exposure_with_timeout(
        &self,
        duration_secs: f64,
        timeout_buffer: Option<Duration>,
    ) -> Result<(), String> {
        let buffer_secs = match timeout_buffer {
            Some(buffer) => buffer,
            None => {
                let client = self.client.read().await;
                Duration::from_secs(client.timeout_config().camera_exposure_buffer_secs)
            }
        };

        // Start the exposure
        {
            let mut client = self.client.write().await;
            client
                .set_number(
                    &self.device_name,
                    CCD_EXPOSURE,
                    "CCD_EXPOSURE_VALUE",
                    duration_secs,
                )
                .await?;
        }

        // Wait for exposure to complete
        let timeout_duration = Duration::from_secs_f64(duration_secs) + buffer_secs;
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, CCD_EXPOSURE, timeout_duration)
            .await
            .map_err(|e| format!("Camera exposure of {:.1}s failed: {}", duration_secs, e))
    }
}

/// Poll `op` until it returns `Ok(Some(_))` or the deadline expires.
///
/// Why: INDI properties arrive asynchronously after the connection is up; the
/// bridge wants a single `await` that gives a deterministic answer within a
/// bound. We use a short polling interval rather than a one-shot read so a
/// late-arriving `defNumberVector` is picked up. A 0-duration timeout is
/// honored as "single-shot read".
async fn wait_for_optional<T, F, Fut>(timeout: Duration, mut op: F) -> Result<Option<T>, IndiError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<Option<T>, IndiError>>,
{
    let deadline = std::time::Instant::now() + timeout;
    let poll_interval = Duration::from_millis(50);
    loop {
        match op().await? {
            Some(value) => return Ok(Some(value)),
            None => {
                let now = std::time::Instant::now();
                if now >= deadline {
                    return Ok(None);
                }
                let remaining = deadline.saturating_duration_since(now);
                tokio::time::sleep(poll_interval.min(remaining)).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;

    /// When CCD_BINNING is undefined, try_get_binning returns Ok(None)
    /// instead of fabricating (1, 1).
    #[tokio::test]
    async fn try_get_binning_returns_none_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        // No connection, no defined property → Ok(None).
        let result = camera.try_get_binning().await;
        assert!(matches!(result, Ok(None)));
    }

    /// try_get_frame returns Ok(None) when CCD_FRAME has not been defined,
    /// rather than fabricating the (0, 0, 0, 0) ROI.
    #[tokio::test]
    async fn try_get_frame_returns_none_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        let result = camera.try_get_frame().await;
        assert!(matches!(result, Ok(None)));
    }

    /// try_get_max_bin_x/y return Ok(None) when CCD_INFO is undefined.
    #[tokio::test]
    async fn try_get_max_bin_returns_none_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        assert!(matches!(camera.try_get_max_bin_x().await, Ok(None)));
        assert!(matches!(camera.try_get_max_bin_y().await, Ok(None)));
    }

    /// get_binning_or_default returns the documented (1, 1) fallback after
    /// timeout, with the warning emitted via `tracing::warn!`. The test
    /// verifies the value path; warning emission is covered by the
    /// `tracing` infrastructure itself.
    #[tokio::test]
    async fn get_binning_or_default_falls_back_after_timeout() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        let value = camera
            .get_binning_or_default(Duration::from_millis(20))
            .await
            .expect("default-fallback path should not error");
        assert_eq!(value, (1, 1));
    }

    /// get_frame_or_default surfaces an explicit
    /// `IndiError::PropertyNotFound` when neither CCD_FRAME nor CCD_INFO is
    /// defined, rather than fabricating a 1×1 frame.
    #[tokio::test]
    async fn get_frame_or_default_errors_when_no_sensor_info() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        let result = camera.get_frame_or_default(Duration::from_millis(20)).await;
        assert!(matches!(result, Err(IndiError::PropertyNotFound { .. })));
    }

    /// get_max_bin_*_or_default returns DEFAULT_MAX_BIN with a logged
    /// warning when the property is missing.
    #[tokio::test]
    async fn get_max_bin_or_default_falls_back_after_timeout() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let camera = IndiCamera::new(client, "TestCamera");
        let bx = camera
            .get_max_bin_x_or_default(Duration::from_millis(20))
            .await
            .expect("default-fallback path should not error");
        let by = camera
            .get_max_bin_y_or_default(Duration::from_millis(20))
            .await
            .expect("default-fallback path should not error");
        assert_eq!(bx, IndiCamera::DEFAULT_MAX_BIN);
        assert_eq!(by, IndiCamera::DEFAULT_MAX_BIN);
    }
}
