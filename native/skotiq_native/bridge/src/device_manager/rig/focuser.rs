//! The focuser behind its handle, once per protocol.
//!
//! A move is the driver's own move command under [`focuser_move_with_timeout`]
//! or [`with_timeout_str`]; whoever needs the focuser at rest polls
//! `is_moving` afterwards. `halt` is one command, so it waits only for the
//! driver call in flight.

use super::{Exclusive, RigDriver};
use crate::api::devices::simulation::get_sim_focuser;
use crate::device_capabilities::FocuserCapabilities;
use crate::device_manager::ops::{sim_faults, sim_gate};
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{focuser_move_with_timeout, with_timeout_str, Timeouts};
use async_trait::async_trait;
use skotiq_alpaca::AlpacaFocuser;
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

fn move_failed(protocol: &str, device: &str, position: i32, error: SkotiqError) -> String {
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
                    .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
            },
            device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::hardware(
                Some(device_id.clone()),
                move_failed("native", device_id, position, e),
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
        .map_err(DeviceOpError::driver)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.driver
            .write()
            .await
            .halt()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.driver
            .read()
            .await
            .get_position()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.driver
            .read()
            .await
            .is_moving()
            .await
            .map_err(DeviceOpError::driver)
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
            .map_err(DeviceOpError::driver)
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

/// An ASCOM focuser. Every call is a command on the wrapper's channel, run by
/// the STA worker.
#[cfg(windows)]
pub(crate) struct AscomFocuser {
    device_id: String,
    driver: Exclusive<crate::ascom_wrapper::focuser::AscomFocuserWrapper>,
}

#[cfg(windows)]
impl AscomFocuser {
    pub(crate) fn new(
        device_id: &str,
        wrapper: crate::ascom_wrapper::focuser::AscomFocuserWrapper,
    ) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Exclusive::new(wrapper),
        }
    }
}

#[cfg(windows)]
#[async_trait]
impl RigDriver for AscomFocuser {
    async fn disconnect(&self) -> Result<(), DriverError> {
        use skotiq_device::DeviceDriver;
        self.driver.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        match self.driver.read().await.heartbeat().await {
            Ok(()) => {
                tracing::trace!("ASCOM focuser {} heartbeat: healthy", self.device_id);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("ASCOM focuser {} heartbeat failed: {:?}", self.device_id, e);
                Ok(false)
            }
        }
    }
}

#[cfg(windows)]
#[async_trait]
impl Focuser for AscomFocuser {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        let mut focuser = self.driver.write().await;
        focuser_move_with_timeout(
            async {
                focuser
                    .move_to(position)
                    .await
                    .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
            },
            device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::hardware(
                Some(device_id.clone()),
                move_failed("ASCOM", device_id, position, e),
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
        .map_err(DeviceOpError::driver)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        let mut focuser = self.driver.write().await;
        focuser.halt().await.map_err(DeviceOpError::driver)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        let focuser = self.driver.read().await;
        focuser.get_position().await.map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        let focuser = self.driver.read().await;
        focuser.is_moving().await.map_err(DeviceOpError::driver)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        let focuser = self.driver.read().await;
        focuser.is_absolute().await.map_err(DeviceOpError::driver)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        let focuser = self.driver.read().await;
        focuser
            .get_temperature()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let focuser = self.driver.read().await;
        Ok((focuser.get_max_position(), focuser.get_step_size()))
    }

    async fn capabilities(&self, device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let readings = self
            .driver
            .read()
            .await
            .capability_readings()
            .await
            .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
        Ok(crate::device_capabilities::focuser_capabilities_from_ascom(
            readings,
        ))
    }
}

/// An Alpaca focuser.
pub(crate) struct AlpacaFocuserHandle {
    device_id: String,
    focuser: AlpacaFocuser,
}

impl AlpacaFocuserHandle {
    pub(crate) fn new(device_id: &str, focuser: AlpacaFocuser) -> Self {
        Self {
            device_id: device_id.to_string(),
            focuser,
        }
    }
}

#[async_trait]
impl RigDriver for AlpacaFocuserHandle {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self.focuser.disconnect().await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        match self.focuser.heartbeat().await {
            Ok(rtt_ms) => {
                tracing::trace!(
                    "Alpaca focuser {} heartbeat: {}ms RTT",
                    self.device_id,
                    rtt_ms
                );
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca focuser {} heartbeat failed: {}", self.device_id, e);
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl Focuser for AlpacaFocuserHandle {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        focuser_move_with_timeout(
            async {
                self.focuser
                    .move_to(position)
                    .await
                    .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
            },
            device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::hardware(
                Some(device_id.clone()),
                move_failed("Alpaca", device_id, position, e),
            )
        })
    }

    /// Alpaca focusers take absolute positions only, so the target is worked
    /// out from the position read first.
    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        let current_position = self.focuser.position().await?;
        let target_position = current_position + steps;
        focuser_move_with_timeout(
            async {
                self.focuser
                    .move_to(target_position)
                    .await
                    .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
            },
            &self.device_id,
            target_position,
            Some(current_position),
            1,
        )
        .await
        .map_err(DeviceOpError::driver)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.focuser.halt().await.map_err(DeviceOpError::driver)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.focuser.position().await.map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.focuser
            .is_moving()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        self.focuser.absolute().await.map_err(DeviceOpError::driver)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        self.focuser
            .temperature()
            .await
            .map(Some)
            .map_err(DeviceOpError::driver)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let max_step = self.focuser.max_step().await?;
        let step_size = match self.focuser.step_size().await {
            Ok(s) => s,
            Err(e) => {
                warn!(
                    "Failed to read Alpaca focuser step_size for {}: {}. Using default 1.0.",
                    self.device_id, e
                );
                1.0
            }
        };
        Ok((max_step, step_size))
    }

    /// The ASCOM `unwrap_or` defaults: an unanswered optional property means
    /// the feature is absent. IFocuserV3 has no CanHalt; Halt is a required
    /// method, so halt is always offered.
    async fn capabilities(&self, _device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let focuser = &self.focuser;
        Ok(FocuserCapabilities {
            max_position: focuser.max_step().await.unwrap_or(0),
            max_increment: focuser.max_increment().await.unwrap_or(0),
            step_size: focuser.step_size().await.ok(),
            absolute: focuser.absolute().await.unwrap_or(false),
            temp_comp_available: focuser.temp_comp_available().await.unwrap_or(false),
            temp_comp: focuser.temp_comp().await.unwrap_or(false),
            temperature: focuser.temperature().await.ok(),
            is_moving: focuser.is_moving().await.unwrap_or(false),
            position: focuser.position().await.ok(),
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
                    .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
            },
            &self.device_id,
            position,
            None,
            1,
        )
        .await
        .map_err(|e| {
            DeviceOpError::hardware(
                Some(self.device_id.clone()),
                move_failed("INDI", self.device_name(), position, e),
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
        .map_err(DeviceOpError::driver)
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.focuser
            .abort_motion()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.focuser
            .get_position()
            .await
            .map_err(DeviceOpError::driver)
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
                    return Err(DeviceOpError::driver(format!(
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
            .await
            .map_err(DeviceOpError::driver)?;
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
