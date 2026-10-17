use super::*;

/// End-to-end travel time of the simulated dust cover, in seconds.
///
/// An Alnitak Flip-Flat takes two to four seconds to swing its lid. The
/// simulator is quicker so the motion still completes inside the sequencer's
/// 60 s cover budget and inside a test, but it must not be INSTANT: the only
/// reason `CoverState::Moving` exists is that a caller has to wait through it,
/// and a cover that reads `Open` on the same poll that commanded it means
/// `wait_for_cover_state` returns before real hardware would have started
/// moving. That is the same class of bug as a slew that completes in zero time.
pub(crate) const SIM_COVER_TRAVEL_SECS: f64 = 1.5;

/// How far past its expected travel time the simulated controller waits before
/// declaring the lid jammed.
///
/// Real cover controllers run their own move timeout and report
/// `CoverState::Error` when a lid does not arrive — which is why
/// `wait_for_cover_state` has an `Error` branch at all. Without this the branch
/// is unreachable without hardware: a stalled cover would read `Moving` until
/// the sequence node's own timeout and the driver-detected-jam path would ship
/// unexercised.
pub(crate) const SIM_COVER_JAM_TIMEOUT_MULTIPLE: f64 = 3.0;

/// Tolerance, in units of full travel, for calling the lid fully open/closed.
pub(crate) const SIM_COVER_ENDSTOP_EPS: f64 = 1e-6;

/// Time the simulated panel takes to settle after a full-scale brightness
/// change, in seconds.
///
/// Electroluminescent panels ramp; `CalibratorState::NotReady` exists precisely
/// because a flat taken before the panel settles is at the wrong level. A
/// simulator that jumped straight to `Ready` would leave both the wait in
/// `execute_calibrator_on` and the flat wizard's readiness handling unexercised.
pub(crate) const SIM_CALIBRATOR_SETTLE_SECS: f64 = 0.8;

/// Brightness ceiling the simulated panel advertises.
///
/// 255 is the ASCOM default that `ops/cover.rs` already falls back to when a
/// driver will not answer, and it is what an Alnitak reports. Deliberately not
/// 100: `CalibratorOnConfig` documents brightness as "0-max, typically 0-255"
/// while the instruction's own progress text renders the same number as a
/// percentage, and a panel whose scale is not 0-100 is the only way that
/// discrepancy can surface without hardware.
pub(crate) const SIM_CALIBRATOR_MAX_BRIGHTNESS: i32 = 255;

/// Backing state for the flat-panel-plus-dust-cover simulator.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SimulatedCoverCalibrator {
    pub connected: bool,
    /// Lid travel, 0.0 fully closed through 1.0 fully open.
    ///
    /// A position rather than a state so a halt mid-travel is representable at
    /// all: the lid is then genuinely neither open nor closed, which is exactly
    /// what `CoverState::Unknown` means and what a real controller reports after
    /// `HaltCover`. Storing only the state would have forced halt to be either a
    /// no-op or a lie about where the lid is.
    pub(crate) cover_position: f64,
    pub(crate) cover_travel: Option<SimRamp>,
    /// Latched jam: the controller gave up on a lid that stopped moving.
    pub(crate) cover_jammed: bool,
    /// Whether the panel has been commanded on. Kept separate from the
    /// brightness so `CalibratorOn(0)` — a legal ASCOM call — still reads
    /// `Ready` rather than being indistinguishable from `CalibratorOff`.
    pub(crate) calibrator_on: bool,
    pub(crate) brightness: f64,
    pub(crate) brightness_ramp: Option<SimRamp>,
}

impl Default for SimulatedCoverCalibrator {
    fn default() -> Self {
        // Starts closed and dark: that is where a flat panel sits at the start
        // of a night, and it means a sequence that forgets to open the cover
        // gets black frames rather than a simulator that was helpfully already
        // open.
        Self {
            connected: false,
            cover_position: 0.0,
            cover_travel: None,
            cover_jammed: false,
            calibrator_on: false,
            brightness: 0.0,
            brightness_ramp: None,
        }
    }
}

impl SimulatedCoverCalibrator {
    pub(crate) fn require_connected(&self) -> Result<(), SimDeviceError> {
        if self.connected {
            return Ok(());
        }
        Err(SimDeviceError::NotConnected(
            "Simulator cover calibrator is not connected. Call connect_device first.".to_string(),
        ))
    }

    pub(crate) fn cover_state(&self) -> CoverState {
        if self.cover_jammed {
            return CoverState::Error;
        }
        if self.cover_travel.is_some() {
            return CoverState::Moving;
        }
        if self.cover_position >= 1.0 - SIM_COVER_ENDSTOP_EPS {
            CoverState::Open
        } else if self.cover_position <= SIM_COVER_ENDSTOP_EPS {
            CoverState::Closed
        } else {
            // Stopped part-way. The controller knows the lid is not on either
            // endstop and cannot say which side it will end up on.
            CoverState::Unknown
        }
    }

    pub(crate) fn calibrator_state(&self) -> CalibratorState {
        if self.brightness_ramp.is_some() {
            // Also covers the way down: ASCOM keeps a calibrator `NotReady`
            // until it is safely off, not just while it is warming up.
            CalibratorState::NotReady
        } else if self.calibrator_on {
            CalibratorState::Ready
        } else {
            CalibratorState::Off
        }
    }

    pub(crate) fn reported_brightness(&self) -> i32 {
        self.brightness.round() as i32
    }

    /// Start the panel moving toward `target`, taking time proportional to how
    /// far it has to travel — a nudge from 200 to 210 settles far quicker than
    /// a jump from dark to full, as on a real panel.
    pub(crate) fn begin_brightness_ramp(&mut self, target: f64) {
        let span = f64::from(SIM_CALIBRATOR_MAX_BRIGHTNESS);
        let duration = SIM_CALIBRATOR_SETTLE_SECS * ((target - self.brightness).abs() / span);
        if duration <= 0.0 {
            self.brightness = target;
            self.brightness_ramp = None;
            return;
        }
        self.brightness_ramp = Some(SimRamp {
            start: Instant::now(),
            duration_secs: duration,
            from: self.brightness,
            to: target,
        });
    }
}

pub(crate) static SIM_COVER_CALIBRATOR: OnceLock<Arc<RwLock<SimulatedCoverCalibrator>>> =
    OnceLock::new();

pub(crate) fn get_sim_cover_calibrator() -> &'static Arc<RwLock<SimulatedCoverCalibrator>> {
    SIM_COVER_CALIBRATOR.get_or_init(|| Arc::new(RwLock::new(SimulatedCoverCalibrator::default())))
}

/// Return the panel to its start-of-night state.
///
/// The singleton is process-global, so a test that opened the lid would
/// otherwise hand the next one a cover that is already open — and "commanding
/// open when already open" is a legitimately different path from "opening a
/// closed cover", so the next test would silently stop testing what it names.
#[cfg(test)]
pub(crate) async fn reset_sim_cover_calibrator() {
    *get_sim_cover_calibrator().write().await = SimulatedCoverCalibrator::default();
}

/// Advance the lid and the panel to now.
///
/// Called from every simulated cover-calibrator op, which is what makes the
/// motion observable to a caller polling `cover_state` — the same arrangement
/// that drives `advance_sim_slew` from every mount status read.
pub(crate) async fn advance_sim_cover_calibrator() {
    // A stalled lid does not move. The command that stalled it still returned
    // `Ok`, so the only evidence is that the state never becomes `Open` — which
    // is precisely the failure mode a real jammed Flip-Flat presents.
    let stalled = crate::device_manager::ops::sim_faults::is_stalled("covercalibrator.cover");
    let mut cc = get_sim_cover_calibrator().write().await;

    if let Some(travel) = cc.cover_travel {
        if stalled {
            if travel.start.elapsed().as_secs_f64()
                > travel.duration_secs * SIM_COVER_JAM_TIMEOUT_MULTIPLE
            {
                cc.cover_travel = None;
                cc.cover_jammed = true;
            }
        } else if travel.is_complete() {
            cc.cover_position = travel.to;
            cc.cover_travel = None;
        } else {
            cc.cover_position = travel.value();
        }
    }

    if let Some(ramp) = cc.brightness_ramp {
        if ramp.is_complete() {
            cc.brightness = ramp.to;
            cc.brightness_ramp = None;
        } else {
            cc.brightness = ramp.value();
        }
    }
}

/// Read the simulated panel's combined status.
pub(crate) async fn sim_cover_status() -> Result<CoverCalibratorStatus, SimDeviceError> {
    sim_fault("covercalibrator.status").await?;
    advance_sim_cover_calibrator().await;
    let cc = get_sim_cover_calibrator().read().await;
    cc.require_connected()?;
    Ok(CoverCalibratorStatus {
        connected: true,
        cover_state: cc.cover_state(),
        calibrator_state: cc.calibrator_state(),
        brightness: cc.reported_brightness(),
        max_brightness: SIM_CALIBRATOR_MAX_BRIGHTNESS,
    })
}

/// Command the lid open (`open == true`) or closed.
///
/// Reversing mid-travel is honest about where the lid actually is: a half-open
/// cover takes half the travel time to close again, because the ramp starts
/// from the advanced position rather than from the endstop it last left.
pub(crate) async fn sim_cover_move(open: bool) -> Result<(), SimDeviceError> {
    sim_fault("covercalibrator.command").await?;
    // Arms the stall latch the advancer consults; see `sim_faults` for why a
    // stall returns `Ok` rather than an error.
    sim_fault("covercalibrator.cover").await?;
    advance_sim_cover_calibrator().await;

    let mut cc = get_sim_cover_calibrator().write().await;
    cc.require_connected()?;
    // Commanding the mechanism again re-arms the controller, exactly as
    // power-cycling a jammed lid or re-issuing the move does on real hardware.
    cc.cover_jammed = false;

    let target = if open { 1.0 } else { 0.0 };
    let distance = (target - cc.cover_position).abs();
    if distance <= SIM_COVER_ENDSTOP_EPS {
        // Already there. A real controller answers immediately rather than
        // driving the motor into the endstop for a second and a half.
        cc.cover_travel = None;
        return Ok(());
    }
    cc.cover_travel = Some(SimRamp {
        start: Instant::now(),
        duration_secs: SIM_COVER_TRAVEL_SECS * distance,
        from: cc.cover_position,
        to: target,
    });
    Ok(())
}

/// Stop the lid where it is.
pub(crate) async fn sim_cover_halt() -> Result<(), SimDeviceError> {
    sim_fault("covercalibrator.command").await?;
    advance_sim_cover_calibrator().await;
    let mut cc = get_sim_cover_calibrator().write().await;
    cc.require_connected()?;
    cc.cover_travel = None;
    Ok(())
}

/// Turn the panel on at `brightness`.
pub(crate) async fn sim_calibrator_on(brightness: i32) -> Result<(), SimDeviceError> {
    sim_fault("covercalibrator.command").await?;
    advance_sim_cover_calibrator().await;
    let mut cc = get_sim_cover_calibrator().write().await;
    cc.require_connected()?;

    // ASCOM requires a brightness outside 0..=MaxBrightness to raise
    // InvalidValueException. Clamping instead would hide the app sending a
    // 0-100 percentage to a 0-255 panel (or the reverse) — it would simply
    // produce the wrong flat level and nothing would say so.
    if !(0..=SIM_CALIBRATOR_MAX_BRIGHTNESS).contains(&brightness) {
        return Err(SimDeviceError::InvalidParameter(format!(
            "Calibrator brightness {} is outside the panel's 0-{} range",
            brightness, SIM_CALIBRATOR_MAX_BRIGHTNESS
        )));
    }

    cc.calibrator_on = true;
    cc.begin_brightness_ramp(f64::from(brightness));
    Ok(())
}

/// Turn the panel off.
pub(crate) async fn sim_calibrator_off() -> Result<(), SimDeviceError> {
    sim_fault("covercalibrator.command").await?;
    advance_sim_cover_calibrator().await;
    let mut cc = get_sim_cover_calibrator().write().await;
    cc.require_connected()?;
    cc.calibrator_on = false;
    cc.begin_brightness_ramp(0.0);
    Ok(())
}
