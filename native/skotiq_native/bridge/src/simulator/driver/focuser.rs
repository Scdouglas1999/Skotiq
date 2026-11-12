use crate::device_capabilities::FocuserCapabilities;
use crate::device_manager::rig::focuser::Focuser;
use crate::device_manager::rig::RigDriver;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::simulator::{faults, gate, get_sim_focuser};
use async_trait::async_trait;
use skotiq_device::DriverError;

/// The simulated focuser singleton.
///
/// Written with braces because the binding generator stops on a unit struct
/// that implements a trait of this crate.
pub(crate) struct SimFocuser {}

fn sim_not_connected() -> DeviceOpError {
    DeviceOpError::not_connected(None, gate::not_connected_focuser())
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
        faults::check("focuser.move").await?;
        let mut f = get_sim_focuser().write().await;
        if !f.status.connected {
            return Err(sim_not_connected());
        }
        // Backlash: the mechanism lands short of the commanded position when
        // reversing direction. An autofocus routine that trusts the commanded
        // position instead of re-reading the reached one fits its V-curve
        // against positions the focuser was never at.
        let reached = match faults::backlash_steps("focuser.move") {
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
        if faults::is_stalled("focuser.move") {
            return Ok(());
        }
        if let Some(replay) = crate::simulator::replay::armed() {
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
        Ok(gate::read_focuser_status().await?.position)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(gate::read_focuser_status().await?.moving)
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(gate::read_focuser_status().await?.is_absolute)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        Ok(gate::read_focuser_status().await?.temperature)
    }

    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        let sim = gate::read_focuser_status().await?;
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
