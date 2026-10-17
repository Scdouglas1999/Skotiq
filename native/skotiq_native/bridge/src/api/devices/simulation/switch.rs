use super::*;

/// How long a commanded switch change takes to appear in the device's own
/// telemetry, in seconds.
///
/// A Pegasus powerbox acknowledges a command immediately but reports state from
/// its own status poll, so a read issued straight after a write returns the
/// PREVIOUS value. That race is where a whole class of UI bugs lives — toggle a
/// port, re-read, see the old state, snap the control back — and a simulator
/// that applies writes instantly can never produce it.
pub(crate) const SIM_SWITCH_SETTLE_SECS: f64 = 0.25;

/// Draw of the controller itself with every output off, in amps.
pub(crate) const SIM_SWITCH_QUIESCENT_AMPS: f64 = 0.4;
/// Draw added by the switched 12 V bank (mount plus camera), in amps.
pub(crate) const SIM_SWITCH_QUAD_AMPS: f64 = 1.8;
/// Draw added by the DSLR output, in amps.
pub(crate) const SIM_SWITCH_DSLR_AMPS: f64 = 0.9;
/// Draw added per percent of dew-heater duty cycle, in amps. A dew strap at
/// full duty pulls about 3 A, which is what sizes this.
pub(crate) const SIM_SWITCH_DEW_AMPS_PER_PERCENT: f64 = 0.03;
/// Open-circuit supply voltage, in volts.
pub(crate) const SIM_SWITCH_SUPPLY_VOLTS: f64 = 13.8;
/// Supply sag per amp drawn, in volts. Real cabling has resistance, and the
/// voltage readout dropping under load is what makes an undersized supply
/// diagnosable from the app.
pub(crate) const SIM_SWITCH_SAG_VOLTS_PER_AMP: f64 = 0.05;

/// Indices of the simulated powerbox's channels. Named because the derived
/// sensor channels below read the controllable ones by position.
pub(crate) const SIM_SWITCH_QUAD: usize = 0;
pub(crate) const SIM_SWITCH_DSLR: usize = 1;
pub(crate) const SIM_SWITCH_DEW_A: usize = 3;
pub(crate) const SIM_SWITCH_DEW_B: usize = 4;
pub(crate) const SIM_SWITCH_VOLTAGE: usize = 5;
pub(crate) const SIM_SWITCH_CURRENT: usize = 6;

/// One channel of the simulated powerbox.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SimSwitchChannel {
    pub(crate) name: &'static str,
    pub(crate) description: &'static str,
    pub(crate) min: f64,
    pub(crate) max: f64,
    /// Resolution the controller can actually produce. A commanded value is
    /// quantised to this, because a real DAC/PWM register cannot hold 30.7 %.
    pub(crate) step: f64,
    pub(crate) writable: bool,
    pub(crate) value: f64,
    /// A commanded value that has not yet appeared in the device's telemetry.
    pub(crate) pending: Option<(f64, Instant)>,
}

impl SimSwitchChannel {
    /// Apply any commanded change that has had time to land, then report the
    /// value a read sees now.
    pub(crate) fn settle(&mut self) -> f64 {
        if let Some((value, at)) = self.pending {
            if at.elapsed().as_secs_f64() >= SIM_SWITCH_SETTLE_SECS {
                self.value = value;
                self.pending = None;
            }
        }
        self.value
    }

    pub(crate) fn quantise(&self, value: f64) -> f64 {
        if self.step <= 0.0 {
            return value;
        }
        self.min + ((value - self.min) / self.step).round() * self.step
    }
}

/// ASCOM `ISwitchV2` boolean projection: a multi-state switch reads `true` when
/// its value sits in the upper half of its range.
///
/// This coupling is not cosmetic. A dew heater set to 30 % reads back as
/// `false`, so an app that remembers "I turned it on" instead of re-reading the
/// device will disagree with the hardware — and against a simulator that kept
/// an independent boolean, it never would.
pub(crate) fn sim_switch_value_as_bool(value: f64, min: f64, max: f64) -> bool {
    value - min >= (max - min) / 2.0
}

/// Backing state for the switch simulator.
///
/// Shaped after a Pegasus Astro Ultimate Powerbox — switched outputs, PWM dew
/// channels, and read-only voltage/current sensors — because that is what a
/// switch device on this app actually is. The read-only channels are the point:
/// with every channel writable, `CanWrite == false` and the UI's read-only
/// rendering could never be exercised without hardware.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SimulatedSwitch {
    pub connected: bool,
    pub(crate) channels: Vec<SimSwitchChannel>,
}

impl Default for SimulatedSwitch {
    fn default() -> Self {
        Self {
            connected: false,
            channels: vec![
                SimSwitchChannel {
                    name: "Quad 12V Output",
                    description: "Switched 12 V bank (mount, camera, focuser)",
                    min: 0.0,
                    max: 1.0,
                    step: 1.0,
                    writable: true,
                    value: 1.0,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "DSLR Output",
                    description: "Switched auxiliary 12 V output",
                    min: 0.0,
                    max: 1.0,
                    step: 1.0,
                    writable: true,
                    value: 0.0,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "Adjustable Output",
                    description: "Variable output, volts",
                    min: 3.0,
                    max: 12.0,
                    step: 1.0,
                    writable: true,
                    value: 12.0,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "Dew Heater A",
                    description: "Dew heater duty cycle, percent",
                    min: 0.0,
                    max: 100.0,
                    step: 1.0,
                    writable: true,
                    value: 0.0,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "Dew Heater B",
                    description: "Dew heater duty cycle, percent",
                    min: 0.0,
                    max: 100.0,
                    step: 1.0,
                    writable: true,
                    value: 0.0,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "Input Voltage",
                    description: "Supply voltage, volts (read-only sensor)",
                    min: 0.0,
                    max: 15.0,
                    step: 0.1,
                    writable: false,
                    value: SIM_SWITCH_SUPPLY_VOLTS,
                    pending: None,
                },
                SimSwitchChannel {
                    name: "Total Current",
                    description: "Total draw, amps (read-only sensor)",
                    min: 0.0,
                    max: 20.0,
                    step: 0.1,
                    writable: false,
                    value: SIM_SWITCH_QUIESCENT_AMPS,
                    pending: None,
                },
            ],
        }
    }
}

impl SimulatedSwitch {
    pub(crate) fn require_connected(&self) -> Result<(), SimDeviceError> {
        if self.connected {
            return Ok(());
        }
        Err(SimDeviceError::NotConnected(
            "Simulator switch is not connected. Call connect_device first.".to_string(),
        ))
    }

    /// Resolve a caller-supplied switch id.
    ///
    /// Out of range is an error, not a clamp: ASCOM raises
    /// `InvalidValueException` for an id outside `0..MaxSwitch`, and an app that
    /// iterates one too far has an off-by-one that a clamping simulator would
    /// swallow.
    pub(crate) fn index_of(&self, switch_id: i32) -> Result<usize, SimDeviceError> {
        usize::try_from(switch_id)
            .ok()
            .filter(|i| *i < self.channels.len())
            .ok_or_else(|| {
                SimDeviceError::InvalidParameter(format!(
                    "Switch index {} is out of range for the simulated switch (0-{})",
                    switch_id,
                    self.channels.len() - 1
                ))
            })
    }

    /// Settle every channel and recompute the derived sensors.
    ///
    /// Voltage and current are DERIVED from what is switched on rather than
    /// stored, for the same reason the mount's altitude is derived from its
    /// RA/Dec: a stored constant is a reading that never responds to anything
    /// the app does, so a power dashboard wired to nothing still looks alive.
    pub(crate) fn advance(&mut self) {
        for channel in &mut self.channels {
            channel.settle();
        }

        let bool_at = |i: usize| {
            let c = &self.channels[i];
            sim_switch_value_as_bool(c.value, c.min, c.max)
        };
        let mut amps = SIM_SWITCH_QUIESCENT_AMPS;
        if bool_at(SIM_SWITCH_QUAD) {
            amps += SIM_SWITCH_QUAD_AMPS;
        }
        if bool_at(SIM_SWITCH_DSLR) {
            amps += SIM_SWITCH_DSLR_AMPS;
        }
        amps += (self.channels[SIM_SWITCH_DEW_A].value + self.channels[SIM_SWITCH_DEW_B].value)
            * SIM_SWITCH_DEW_AMPS_PER_PERCENT;

        self.channels[SIM_SWITCH_CURRENT].value = amps;
        self.channels[SIM_SWITCH_VOLTAGE].value =
            SIM_SWITCH_SUPPLY_VOLTS - amps * SIM_SWITCH_SAG_VOLTS_PER_AMP;
    }
}

pub(crate) static SIM_SWITCH: OnceLock<Arc<RwLock<SimulatedSwitch>>> = OnceLock::new();

pub(crate) fn get_sim_switch() -> &'static Arc<RwLock<SimulatedSwitch>> {
    SIM_SWITCH.get_or_init(|| Arc::new(RwLock::new(SimulatedSwitch::default())))
}

/// Return the powerbox to its power-on state; see
/// [`reset_sim_cover_calibrator`] for why a process-global singleton needs one.
#[cfg(test)]
pub(crate) async fn reset_sim_switch() {
    *get_sim_switch().write().await = SimulatedSwitch::default();
}

/// One switch channel as a caller sees it.
#[derive(Debug, Clone)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SimSwitchReading {
    pub name: String,
    pub description: String,
    pub value: f64,
    pub state: bool,
    pub min: f64,
    pub max: f64,
    pub writable: bool,
}

/// Number of channels the simulated switch device exposes.
pub(crate) async fn sim_switch_count() -> Result<i32, SimDeviceError> {
    sim_fault("switch.status").await?;
    let sw = get_sim_switch().read().await;
    sw.require_connected()?;
    // Why: channel count is a fixed, single-digit literal in `Default`.
    Ok(i32::try_from(sw.channels.len()).unwrap_or(i32::MAX))
}

/// Read one channel.
pub(crate) async fn sim_switch_read(switch_id: i32) -> Result<SimSwitchReading, SimDeviceError> {
    sim_fault("switch.status").await?;
    let mut sw = get_sim_switch().write().await;
    sw.require_connected()?;
    let index = sw.index_of(switch_id)?;
    sw.advance();
    let channel = &sw.channels[index];
    Ok(SimSwitchReading {
        name: channel.name.to_string(),
        description: channel.description.to_string(),
        value: channel.value,
        state: sim_switch_value_as_bool(channel.value, channel.min, channel.max),
        min: channel.min,
        max: channel.max,
        writable: channel.writable,
    })
}

/// What a caller asked a channel to become.
pub(crate) enum SimSwitchCommand {
    /// A numeric value, validated against the channel's own range.
    Value(f64),
    /// On or off. ASCOM defines these in terms of the numeric value — `true`
    /// drives the channel to its maximum and `false` to its minimum — so both
    /// commands land in the same place rather than a boolean living beside the
    /// value and drifting out of agreement with it.
    State(bool),
}

pub(crate) async fn sim_switch_apply(
    switch_id: i32,
    command: SimSwitchCommand,
) -> Result<(), SimDeviceError> {
    let mut sw = get_sim_switch().write().await;
    sw.require_connected()?;
    let index = sw.index_of(switch_id)?;
    sw.advance();

    let channel = &mut sw.channels[index];
    if !channel.writable {
        return Err(SimDeviceError::InvalidParameter(format!(
            "Switch '{}' is a read-only sensor and cannot be set",
            channel.name
        )));
    }

    let value = match command {
        SimSwitchCommand::Value(value) => value,
        SimSwitchCommand::State(true) => channel.max,
        SimSwitchCommand::State(false) => channel.min,
    };
    if !value.is_finite() || value < channel.min || value > channel.max {
        return Err(SimDeviceError::InvalidParameter(format!(
            "Value {} is outside switch '{}' range {}-{}",
            value, channel.name, channel.min, channel.max
        )));
    }

    // The write is accepted now and observable later; see SIM_SWITCH_SETTLE_SECS.
    let landed = channel.quantise(value);
    channel.pending = Some((landed, Instant::now()));
    Ok(())
}

/// Command a channel's numeric value.
pub(crate) async fn sim_switch_write_value(
    switch_id: i32,
    value: f64,
) -> Result<(), SimDeviceError> {
    sim_fault("switch.command").await?;
    sim_switch_apply(switch_id, SimSwitchCommand::Value(value)).await
}

/// Command a channel on or off.
pub(crate) async fn sim_switch_write_state(
    switch_id: i32,
    state: bool,
) -> Result<(), SimDeviceError> {
    sim_fault("switch.command").await?;
    sim_switch_apply(switch_id, SimSwitchCommand::State(state)).await
}
