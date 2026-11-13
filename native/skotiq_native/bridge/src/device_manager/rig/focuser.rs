//! The focuser behind its handle, once per protocol.
//!
//! A move is the driver's own move command under [`focuser_move_with_timeout`]
//! or [`with_timeout_str`]; whoever needs the focuser at rest polls
//! `is_moving` afterwards. `halt` is one command, so it waits only for the
//! driver call in flight. The ASCOM focuser, over Alpaca or COM, is
//! [`super::ascom::AscomFocuser`].

use super::{RigDriver, Slot};
use crate::api::devices::simulation::get_sim_focuser;
use crate::device_capabilities::FocuserCapabilities;
use crate::device_manager::ops::{sim_faults, sim_gate};
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
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
                Box::new(skotiq_indi::IndiFocuser::new(client.clone(), &device_name))
                    as Box<Driver>
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
        Some(DeviceManager::identity_from_device(&self.device_id, &*driver))
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

    /// A read the driver refuses reads as absent or at rest; the status poll
    /// corrects it within one tick.
    async fn capabilities(&self, device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let focuser = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(device_id, format!("{} focuser not connected", self.protocol))
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
            is_moving: focuser.is_moving().await.unwrap_or(false),
            can_halt: focuser.can_halt().await,
            ..Default::default()
        })
    }
}

/// The simulated focuser singleton.
///
/// Written with braces because the binding generator stops on a unit struct
/// that implements a trait of this crate.
pub(crate) struct SimFocuser {}

fn sim_not_connected() -> DeviceOpError {
    DeviceOpError::not_connected(None, sim_gate::not_connected_focuser())
}

#[async_trait]
impl RigDriver for SimFocuser {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_focuser().write().await.status.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        Ok(get_sim_focuser().read().await.status.connected)
    }
}

#[async_trait]
impl Focuser for SimFocuser {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        sim_faults::check("focuser.move")
            .await?;
        let mut f = get_sim_focuser().write().await;
        if !f.status.connected {
            return Err(sim_not_connected());
        }
        // Backlash: the mechanism lands short of the commanded position when
        // reversing direction. An autofocus routine that trusts the commanded
        // position instead of re-reading the reached one fits its V-curve
        // against positions the focuser was never at.
        let reached = match sim_faults::backlash_steps("focuser.move") {
            Some(backlash) if backlash != 0 => {
                let reversing = position < f.status.position;
                if reversing {
                    position + backlash
                } else {
                    position - backlash
                }
            }
            _ => position,
        };
        // A stalled focuser accepts the move and stays put.
        if sim_faults::is_stalled("focuser.move") {
            return Ok(());
        }
        if let Some(replay) = crate::sim_replay::armed() {
            replay.note_focuser_move(f.status.position, reached);
        }
        f.status.position = reached;
        Ok(())
    }

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        let mut f = get_sim_focuser().write().await;
        if !f.status.connected {
            return Err(sim_not_connected());
        }
        f.status.position += steps;
        Ok(())
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        let mut f = get_sim_focuser().write().await;
        if !f.status.connected {
            return Err(sim_not_connected());
        }
        f.status.moving = false;
        Ok(())
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        Ok(sim_gate::read_focuser_status().await?.position)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(sim_gate::read_focuser_status().await?.moving)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(sim_gate::read_focuser_status().await?.is_absolute)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        Ok(sim_gate::read_focuser_status().await?.temperature)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let sim = sim_gate::read_focuser_status().await?;
        Ok((sim.max_position, sim.step_size))
    }

    /// The travel and step the simulated focuser moves within; the position,
    /// motion and temperature are left to the live readings, as the
    /// capability cache refreshes them.
    async fn capabilities(&self, _device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let sim = get_sim_focuser().read().await.status.clone();
        Ok(FocuserCapabilities {
            max_position: sim.max_position,
            max_increment: 50000,
            step_size: Some(sim.step_size),
            absolute: sim.is_absolute,
            temp_comp_available: true,
            can_halt: true,
            can_reverse: true,
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
    struct Lens;

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
            Ok(false)
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
        let focuser = DriverFocuser::vendor("native:test_lens:0", Box::new(Lens));
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
}
