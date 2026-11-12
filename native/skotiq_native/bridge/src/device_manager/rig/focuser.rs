//! The focuser behind its handle, once per protocol.
//!
//! A move is the driver's own move command under [`focuser_move_with_timeout`]
//! or [`with_timeout_str`]; whoever needs the focuser at rest polls
//! `is_moving` afterwards. `halt` is one command, so it waits only for the
//! driver call in flight. The ASCOM focuser, over Alpaca or COM, is
//! [`super::ascom::AscomFocuser`].

use super::{Exclusive, RigDriver};
use crate::device_capabilities::FocuserCapabilities;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{focuser_move_with_timeout, with_timeout_str, Timeouts};
use async_trait::async_trait;
use skotiq_device::{DriverError, FocuserDriver};
use skotiq_indi::names as indi;
use skotiq_indi::IndiFocuser;
use tracing::warn;

#[async_trait]
pub(crate) trait Focuser: RigDriver {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError>;

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError>;

    async fn halt(&self) -> Result<(), DeviceOpError>;

    async fn position(&self) -> Result<i32, DeviceOpError>;

    async fn is_moving(&self) -> Result<bool, DeviceOpError>;

    /// Whether the focuser takes absolute positions.
    async fn is_absolute(&self) -> Result<bool, DeviceOpError>;

    /// Degrees Celsius; `None` for a focuser without a sensor.
    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError>;

    /// The largest position and the size of one step in microns.
    async fn travel(&self) -> Result<(i32, f64), DeviceOpError>;

    /// What the focuser supports, with its position, motion and temperature
    /// now. A property the driver does not answer is reported absent.
    async fn capabilities(&self, device_id: &str) -> Result<FocuserCapabilities, SkotiqError>;
}

fn move_failed(protocol: &str, device: &str, position: i32, error: &SkotiqError) -> String {
    format!(
        "Failed to move {} focuser {} to position {}: {}",
        protocol, device, position, error
    )
}

/// A vendor SDK focuser.
pub(crate) struct VendorFocuser {
    device_id: String,
    driver: Exclusive<Box<dyn FocuserDriver + Send + Sync>>,
}

impl VendorFocuser {
    pub(crate) fn new(device_id: &str, driver: Box<dyn FocuserDriver + Send + Sync>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Exclusive::new(driver),
        }
    }
}

#[async_trait]
impl RigDriver for VendorFocuser {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.driver.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let focuser = self.driver.read().await;
        if !focuser.is_connected() {
            return Ok(false);
        }
        focuser
            .get_position()
            .await
            .map(|_| true)
            .map_err(|e| format!("Native focuser liveness probe failed: {}", e))
    }
}

#[async_trait]
impl Focuser for VendorFocuser {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        let mut focuser = self.driver.write().await;
        focuser_move_with_timeout(
            async {
                focuser
                    .move_to(position)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.clone()),
                move_failed("native", device_id, position, &e),
                e,
            )
        })
    }

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        let mut focuser = self.driver.write().await;
        with_timeout_str(
            async {
                focuser
                    .move_relative(steps)
                    .await
                    .map_err(|e| e.to_string())
            },
            Timeouts::focuser_move(),
            &self.device_id,
            "move_relative",
        )
        .await
        .map_err(DeviceOpError::from)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.driver
            .write()
            .await
            .halt()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.driver
            .read()
            .await
            .get_position()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.driver
            .read()
            .await
            .is_moving()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(true)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        self.driver
            .read()
            .await
            .get_temperature()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let focuser = self.driver.read().await;
        Ok((focuser.get_max_position(), focuser.get_step_size()))
    }

    /// A busy SDK reads as a focuser at rest; the status poll corrects it
    /// within one tick.
    async fn capabilities(&self, _device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let position = self.driver.read().await.get_position().await.ok();
        let temperature = self
            .driver
            .read()
            .await
            .get_temperature()
            .await
            .ok()
            .flatten();
        let is_moving = self.driver.read().await.is_moving().await.unwrap_or(false);
        let (max_position, step_size) = {
            let focuser = self.driver.read().await;
            (focuser.get_max_position(), focuser.get_step_size())
        };
        Ok(FocuserCapabilities {
            max_position,
            step_size: Some(step_size),
            absolute: true,
            position,
            temperature,
            is_moving,
            can_halt: true,
            ..Default::default()
        })
    }
}

/// An INDI focuser on its server's shared connection.
pub(crate) struct IndiFocuserHandle {
    device_id: String,
    focuser: IndiFocuser,
    client: std::sync::Arc<tokio::sync::RwLock<skotiq_indi::IndiClient>>,
}

impl IndiFocuserHandle {
    pub(crate) fn new(
        device_id: &str,
        client: std::sync::Arc<tokio::sync::RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        Self {
            device_id: device_id.to_string(),
            focuser: IndiFocuser::new(client.clone(), device_name),
            client,
        }
    }

    fn device_name(&self) -> &str {
        self.focuser.device_name()
    }
}

#[async_trait]
impl RigDriver for IndiFocuserHandle {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self.focuser.disconnect().await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        self.focuser.check().await.map_err(|e| e.to_string())
    }
}

#[async_trait]
impl Focuser for IndiFocuserHandle {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        focuser_move_with_timeout(
            async {
                self.focuser
                    .move_to(position)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            &self.device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::caused_by(
                Some(self.device_id.clone()),
                move_failed("INDI", self.device_name(), position, &e),
                e,
            )
        })
    }

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        with_timeout_str(
            async {
                self.focuser
                    .move_relative(steps)
                    .await
                    .map_err(|e| e.to_string())
            },
            Timeouts::focuser_move(),
            &self.device_id,
            "move_relative",
        )
        .await
        .map_err(DeviceOpError::from)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.focuser
            .abort_motion()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.focuser
            .get_position()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(self.focuser.is_moving().await)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(self
            .client
            .read()
            .await
            .get_property_state(self.device_name(), indi::ABS_FOCUS_POSITION)
            .await
            .is_some())
    }

    /// A focuser that advertises a temperature sensor and fails the read has
    /// a problem; one without the property has no sensor.
    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        match self.focuser.get_temperature().await {
            Ok(temp) => Ok(Some(temp)),
            Err(e) => {
                let has_sensor = self
                    .client
                    .read()
                    .await
                    .has_property(self.device_name(), indi::FOCUS_TEMPERATURE)
                    .await;
                if has_sensor {
                    return Err(DeviceOpError::from(format!(
                        "INDI focuser {} advertises a temperature sensor but the read failed: {}",
                        self.device_name(),
                        e
                    )));
                }
                Ok(None)
            }
        }
    }

    /// A value the focuser does not publish is reported as 0.
    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let client = self.client.read().await;
        let max_position = match client
            .get_number(self.device_name(), indi::FOCUS_MAX, indi::FOCUS_MAX_VALUE)
            .await
        {
            // Why: INDI wire f64 -> i32 step count.
            Some(v) => v as i32,
            None => {
                warn!(
                    "Failed to read INDI focuser max position for {}: property not available. Reporting unknown max position.",
                    self.device_id
                );
                0
            }
        };
        let step_size = match client
            .get_number(self.device_name(), indi::FOCUS_STEP, indi::FOCUS_STEP_VALUE)
            .await
        {
            Some(s) => s,
            None => {
                warn!(
                    "Failed to read INDI focuser step size for {}: property not available. Reporting unknown step size.",
                    self.device_id
                );
                0.0
            }
        };
        Ok((max_position, step_size))
    }

    async fn capabilities(&self, _device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let properties = self
            .client
            .read()
            .await
            .get_properties(self.device_name())
            .await;
        let has = |name: &str| properties.iter().any(|p| p.name == name);
        let max_position = self.focuser.get_max_step().await.unwrap_or(0);
        Ok(FocuserCapabilities {
            max_position,
            max_increment: max_position,
            step_size: self.focuser.get_step_size().await,
            absolute: has(indi::ABS_FOCUS_POSITION),
            temp_comp_available: has(indi::FOCUS_TEMPERATURE_COMP) || has(indi::FOCUS_TEMP_COMP),
            temp_comp: self.focuser.is_temp_comp_enabled().await.unwrap_or(false),
            temperature: self.focuser.get_temperature().await.ok(),
            is_moving: self.focuser.is_moving().await,
            position: self.focuser.get_position().await.ok(),
            can_halt: has(indi::FOCUS_ABORT_MOTION),
            ..Default::default()
        })
    }
}
