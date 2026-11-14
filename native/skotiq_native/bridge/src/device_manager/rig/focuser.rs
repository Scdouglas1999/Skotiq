//! The focuser behind its handle, once per protocol.
//!
//! A move is the driver's own move command under [`focuser_move_with_timeout`]
//! or [`with_timeout_str`]; whoever needs the focuser at rest polls
//! `is_moving` afterwards. `halt` is one command, so it waits only for the
//! driver call in flight. The ASCOM focuser, over Alpaca or COM, is
//! [`super::ascom::AscomFocuser`].

use super::{RigDriver, Slot};
use crate::device_capabilities::types::FocuserCapabilities;
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{focuser_move_with_timeout, with_timeout, Timeouts};
use async_trait::async_trait;
use skotiq_device::{DriverError, FocuserDriver};

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

type Driver = dyn FocuserDriver + Send + Sync;

/// A focuser behind a [`FocuserDriver`]: a vendor SDK focuser or an INDI
/// focuser.
pub(crate) struct DriverFocuser {
    device_id: String,
    driver: Slot<Driver>,
    /// "Native" or "INDI", in messages.
    protocol: &'static str,
    /// The protocol inside a sentence: "native", "INDI".
    in_sentence: &'static str,
}

impl DriverFocuser {
    /// A vendor SDK focuser: the driver keeps state between calls, so it is
    /// reached one call at a time.
    pub(crate) fn vendor(device_id: &str, driver: Box<Driver>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Slot::held(driver),
            protocol: "Native",
            in_sentence: "native",
        }
    }

    pub(crate) fn indi(
        device_id: &str,
        client: std::sync::Arc<tokio::sync::RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        let device_name = device_name.to_string();
        Self {
            device_id: device_id.to_string(),
            driver: Slot::per_call(move || {
                Box::new(skotiq_indi::IndiFocuser::new(client.clone(), &device_name)) as Box<Driver>
            }),
            protocol: "INDI",
            in_sentence: "INDI",
        }
    }

    fn gone(&self) -> DeviceOpError {
        DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            format!("{} focuser not connected", self.protocol),
        )
    }
}

#[async_trait]
impl RigDriver for DriverFocuser {
    async fn disconnect(&self) -> Result<(), DriverError> {
        match self.driver.take().await {
            Some(mut focuser) => focuser.disconnect().await,
            None => Ok(()),
        }
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let Some(focuser) = self.driver.read().await else {
            return Ok(false);
        };
        focuser
            .heartbeat()
            .await
            .map_err(|e| format!("{} focuser liveness probe failed: {}", self.protocol, e))
    }

    async fn identity(&self) -> Option<DeviceIdentity> {
        let Slot::Held(_) = self.driver else {
            return None;
        };
        let driver = self.driver.read().await?;
        Some(DeviceManager::identity_from_device(
            &self.device_id,
            &*driver,
        ))
    }
}

#[async_trait]
impl Focuser for DriverFocuser {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        let mut focuser = self.driver.write().await.ok_or_else(|| self.gone())?;
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
                move_failed(self.in_sentence, device_id, position, &e),
                e,
            )
        })
    }

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        let mut focuser = self.driver.write().await.ok_or_else(|| self.gone())?;
        with_timeout(
            async {
                focuser
                    .move_relative(steps)
                    .await
                    .map_err(|e| SkotiqError::from(DeviceOpError::from(e)))
            },
            Timeouts::focuser_move(),
            &self.device_id,
            "move_relative",
        )
        .await
        .map_err(DeviceOpError::from)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        let mut focuser = self.driver.write().await.ok_or_else(|| self.gone())?;
        focuser.halt().await.map_err(DeviceOpError::from)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        let focuser = self.driver.read().await.ok_or_else(|| self.gone())?;
        focuser.get_position().await.map_err(DeviceOpError::from)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        let focuser = self.driver.read().await.ok_or_else(|| self.gone())?;
        focuser.is_moving().await.map_err(DeviceOpError::from)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        let focuser = self.driver.read().await.ok_or_else(|| self.gone())?;
        Ok(focuser.is_absolute().await)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        let focuser = self.driver.read().await.ok_or_else(|| self.gone())?;
        focuser.get_temperature().await.map_err(DeviceOpError::from)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let focuser = self.driver.read().await.ok_or_else(|| self.gone())?;
        Ok((
            focuser.get_max_position().await,
            focuser.get_step_size().await,
        ))
    }

    /// Optional readings stay absent; movement-read failures remain errors.
    async fn capabilities(&self, device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let focuser = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(
                device_id,
                format!("{} focuser not connected", self.protocol),
            )
        })?;
        let max_position = focuser.get_max_position().await;
        let step_size = focuser.get_step_size().await;
        let temp_comp = focuser.temp_comp().await;
        Ok(FocuserCapabilities {
            max_position,
            max_increment: max_position,
            // 0.0 is a step size the driver does not know.
            step_size: (step_size > 0.0).then_some(step_size),
            absolute: focuser.is_absolute().await,
            temp_comp_available: temp_comp.is_some(),
            temp_comp: temp_comp.unwrap_or(false),
            position: focuser.get_position().await.ok(),
            temperature: focuser.get_temperature().await.ok().flatten(),
            is_moving: focuser.is_moving().await.map_err(DeviceOpError::from)?,
            can_halt: focuser.can_halt().await,
            ..Default::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_device::{DeviceDriver, Vendor};

    /// A focuser with no stop command, as a camera lens driven through its
    /// body is.
    #[derive(Debug)]
    struct Lens {
        motion_read_fails: bool,
    }

    #[async_trait]
    impl DeviceDriver for Lens {
        fn id(&self) -> &str {
            "native:test_lens:0"
        }
        fn name(&self) -> &str {
            "Lens"
        }
        fn vendor(&self) -> Vendor {
            Vendor::Fujifilm
        }
        fn is_connected(&self) -> bool {
            true
        }
        async fn connect(&mut self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn disconnect(&mut self) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FocuserDriver for Lens {
        async fn move_to(&mut self, _position: i32) -> Result<(), DriverError> {
            Ok(())
        }
        async fn move_relative(&mut self, _steps: i32) -> Result<(), DriverError> {
            Ok(())
        }
        async fn get_position(&self) -> Result<i32, DriverError> {
            Ok(100)
        }
        async fn is_moving(&self) -> Result<bool, DriverError> {
            if self.motion_read_fails {
                Err(DriverError::SdkError("motion read failed".to_string()))
            } else {
                Ok(false)
            }
        }
        async fn can_halt(&self) -> bool {
            false
        }
        async fn halt(&mut self) -> Result<(), DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
            Ok(None)
        }
        async fn get_max_position(&self) -> i32 {
            1000
        }
        async fn get_step_size(&self) -> f64 {
            0.0
        }
    }

    /// Every vendor focuser was offered a Halt, and the lens answered it
    /// with success although nothing stops a lens.
    #[tokio::test]
    async fn a_focuser_that_cannot_halt_offers_no_halt_and_refuses_one() {
        let focuser = DriverFocuser::vendor(
            "native:test_lens:0",
            Box::new(Lens {
                motion_read_fails: false,
            }),
        );
        let capabilities = focuser
            .capabilities("native:test_lens:0")
            .await
            .expect("capabilities");
        assert!(!capabilities.can_halt);
        assert!(matches!(
            focuser.halt().await,
            Err(DeviceOpError::Unsupported { .. })
        ));
    }

    #[tokio::test]
    async fn an_unreadable_focuser_is_not_reported_as_stopped() {
        let focuser = DriverFocuser::vendor(
            "native:test_lens:0",
            Box::new(Lens {
                motion_read_fails: true,
            }),
        );
        let error = focuser
            .capabilities("native:test_lens:0")
            .await
            .unwrap_err();
        assert!(error.to_string().contains("motion read failed"), "{error}");
    }
}
