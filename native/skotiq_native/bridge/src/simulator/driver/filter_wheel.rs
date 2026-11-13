use crate::device_capabilities::types::FilterWheelCapabilities;
use crate::device_manager::rig::filter_wheel::FilterWheel;
use crate::device_manager::rig::RigDriver;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::simulator::filter_wheel::get_sim_filterwheel;
use crate::simulator::{faults, gate};
use async_trait::async_trait;
use skotiq_device::DriverError;

/// The simulated filter wheel singleton.
///
/// Written with braces because the binding generator stops on a unit struct
/// that implements a trait of this crate.
pub(crate) struct SimFilterWheel {}

#[async_trait]
impl RigDriver for SimFilterWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_filterwheel().write().await.status.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        Ok(get_sim_filterwheel().read().await.status.connected)
    }
}

#[async_trait]
impl FilterWheel for SimFilterWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        // Injected driver errors fire before the connected gate; see
        // `sim_faults` for the key grammar.
        faults::check("filterwheel.set_position").await?;
        let mut fw = get_sim_filterwheel().write().await;
        if !fw.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                gate::not_connected_filterwheel(),
            ));
        }
        // A stalled wheel accepts the move and never arrives: the command
        // returns `Ok` and `position` keeps reporting where the wheel is.
        // This is the failure that labels every later frame with the wrong
        // filter, invisible to a check that only looks at the return value.
        if faults::is_stalled("filterwheel.set_position") {
            return Ok(());
        }
        fw.status.position = slot;
        Ok(())
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        Ok(gate::read_filterwheel_status().await?.position)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(gate::read_filterwheel_status().await?.moving)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let sim = gate::read_filterwheel_status().await?;
        Ok((sim.filter_count, sim.filter_names))
    }

    /// Names past the wheel's slot count are dropped, as
    /// `api::devices::simulation::api_filterwheel_set_filter_names` does.
    async fn set_names(&self, names: Vec<String>) -> Result<(), DeviceOpError> {
        let mut fw = get_sim_filterwheel().write().await;
        if !fw.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                gate::not_connected_filterwheel(),
            ));
        }
        let count = fw.status.filter_names.len().min(names.len());
        for (slot, name) in names.into_iter().take(count).enumerate() {
            fw.status.filter_names[slot] = name;
        }
        Ok(())
    }

    /// The slots and names the simulated wheel turns between; where it is
    /// now is left to the live readings, as the capability cache refreshes
    /// them.
    async fn capabilities(&self, _device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        let sim = get_sim_filterwheel().read().await.status.clone();
        Ok(FilterWheelCapabilities {
            position_count: sim.filter_count,
            filter_names: sim.filter_names,
            focus_offsets: vec![0, 10, 20, 30, 100, 120, 140],
            can_set_filter_names: true,
            can_set_focus_offsets: true,
            ..Default::default()
        })
    }
}
