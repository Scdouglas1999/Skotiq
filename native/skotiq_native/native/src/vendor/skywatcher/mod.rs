//! Sky-Watcher equatorial mounts (EQ6-R, EQ8, AZ-EQ6, HEQ5, Star Adventurer
//! GTi, Wave and the rest) through their motor controller protocol, over USB
//! or an EQMOD cable.
//!
//! The motor controller counts microsteps and nothing else: it has no site,
//! no clock and no notion of RA or Dec. The driver points with the
//! application's observing site and the computer clock, in the encoder frame
//! of [`pointing`], and runs the gotos, tracking and guide pulses itself the
//! way indi-eqmod does (`refs/indi-3rdparty/indi-eqmod/skywatcher.cpp`,
//! `eqmodbase.cpp`).

mod pointing;
mod protocol;

use super::serial_link::{self, OnOpenFailure, Probe, ProbedPort, ReplyRule, ScanPlan, SerialLink};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use pointing::{
    alt_az, home, local_sidereal_hours, pier_side_for, AxisScale, AxisSteps, MountFrame,
    POWER_ON_STEP,
};
use protocol::{
    classify_reply, command, command_text, decode_u24, encode_u24, refusal_meaning, Axis,
    AxisStatus, BoardVersion, MotionMode, ReplyLine,
};
use skotiq_device::Vendor;
use skotiq_device::*;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::sync::Notify;

/// Baud rate of an EQMOD cable and of a hand controller in PC-direct mode.
const SYNSCAN_BAUD_RATE: u32 = 9600;

/// Baud rates discovery tries: the USB port of the newer mounts (EQ6-R Pro,
/// EQ8, AZ-EQ6) first, then the EQMOD cable.
const SYNSCAN_DISCOVERY_BAUD_RATES: &[u32] = &[115200, 9600];

/// One try of a command. indi-eqmod waits 200 ms and tries ten times; a
/// longer wait and fewer tries cover a slow USB-serial adapter as well.
const SYNSCAN_REPLY: ReplyRule = ReplyRule {
    terminator: b'\r',
    leading_framing: &[],
    deadline: Duration::from_secs(1),
    timeout_message: "Sky-Watcher mount did not answer",
};
const COMMAND_TRIES: usize = 3;
/// Lines that are not replies (echoes, noise) read before a try gives up.
const MAX_OTHER_LINES: usize = 4;

const SCAN_PLAN: ScanPlan = ScanPlan {
    protocol: "Sky-Watcher",
    baud_rates: SYNSCAN_DISCOVERY_BAUD_RATES,
    on_open_failure: OnOpenFailure::NextPort,
};

/// Time the motor controller gets to answer a discovery probe.
const PROBE_SETTLE: Duration = Duration::from_millis(100);
const PROBE_REPLY_CAPACITY: usize = 32;

/// Default address of the mounts with Wi-Fi.
const SYNSCAN_UDP_PORT: u16 = 11880;
const SYNSCAN_UDP_IP: &str = "192.168.4.1";

/// Seconds in a sidereal day, the length every step period is computed from.
const STELLAR_DAY_SECONDS: f64 = 86_164.098_903_691;
const SIDEREAL_ARCSEC_PER_SECOND: f64 = 1_296_000.0 / STELLAR_DAY_SECONDS;

/// Gotos longer than this run at high speed (indi-eqmod's margin).
const LOW_SPEED_GOTO_MARGIN: u32 = 20_000;
/// Step periods of a goto, in timer ticks per microstep.
const HIGH_SPEED_GOTO_PERIOD: u32 = 6;
const LOW_SPEED_GOTO_PERIOD: u32 = 18;
/// A goto ends with further passes until both axes are this close, at most
/// this many passes in all: the sky turns while the mount slews.
const GOTO_RESOLUTION_ARCSEC: f64 = 5.0;
const GOTO_PASSES: u32 = 5;

/// Guide pulses move the axis at this fraction of the sidereal rate.
const GUIDE_RATE: f64 = 0.5;

const STOP_POLL: Duration = Duration::from_millis(100);
/// Longest deceleration of a stopped high-speed goto.
const STOP_LIMIT: Duration = Duration::from_secs(20);
const PARK_POLL: Duration = Duration::from_millis(500);
const PARK_LIMIT: Duration = Duration::from_secs(600);
/// How close to the home position counts as at home.
const AT_HOME_ARCSEC: f64 = 180.0;

const NO_SITE: &str = "The Sky-Watcher mount points by the observing site and the computer clock: set the observing site in Settings > Location";
const PARKED: &str = "The mount is parked; unpark it first";

#[derive(Debug, Clone)]
pub enum SynScanConnection {
    Serial {
        port: String,
        baud_rate: u32,
    },
    /// UDP/WiFi connection
    Udp {
        ip: String,
        port: u16,
    },
}

impl Default for SynScanConnection {
    fn default() -> Self {
        SynScanConnection::Udp {
            ip: SYNSCAN_UDP_IP.to_string(),
            port: SYNSCAN_UDP_PORT,
        }
    }
}

/// What the controller said about itself at connect.
#[derive(Debug, Clone, Copy)]
struct Controller {
    version: BoardVersion,
    ra: AxisScale,
    dec: AxisScale,
    /// Stepper timer ticks per second, per axis.
    timer_hz: [u32; 2],
}

impl Controller {
    fn scale(&self, axis: Axis) -> AxisScale {
        match axis {
            Axis::Ra => self.ra,
            Axis::Dec => self.dec,
        }
    }

    /// Timer ticks per microstep for `rate` times the sidereal rate.
    fn step_period(&self, axis: Axis, rate: f64) -> u32 {
        let ticks_per_sidereal_step = STELLAR_DAY_SECONDS
            * f64::from(self.timer_hz[axis_index(axis)])
            / f64::from(self.scale(axis).counts);
        (ticks_per_sidereal_step / rate.abs()) as u32
    }
}

fn axis_index(axis: Axis) -> usize {
    match axis {
        Axis::Ra => 0,
        Axis::Dec => 1,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Motion {
    Idle,
    Goto(Goto),
    Parking,
    Homing,
}

/// A goto in progress, in the mount's frame (sync offset taken off).
#[derive(Debug, Clone, Copy, PartialEq)]
struct Goto {
    ra_hours: f64,
    dec_degrees: f64,
    pier_side: PierSide,
    passes: u32,
}

/// What the last sync found the mount to be off by. Kept in software, as
/// indi-eqmod does, so the encoders and with them the home and park
/// positions stay where the mount physically is.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct SyncOffset {
    ra_hours: f64,
    dec_degrees: f64,
}

#[derive(Debug)]
struct MountState {
    controller: Option<Controller>,
    /// Whether the RA axis should be tracking whenever it is not in a goto.
    tracking: bool,
    rate: TrackingRate,
    motion: Motion,
    parked: bool,
    sync: SyncOffset,
}

impl MountState {
    fn new() -> Self {
        Self {
            controller: None,
            tracking: false,
            rate: TrackingRate::Sidereal,
            motion: Motion::Idle,
            parked: false,
            sync: SyncOffset::default(),
        }
    }
}

/// The site and time a pointing calculation needs.
#[derive(Debug, Clone, Copy)]
struct Sky {
    frame: MountFrame,
    lst_hours: f64,
    latitude_deg: f64,
}

pub struct SkyWatcherMount {
    device_id: String,
    name: String,
    connection_config: SynScanConnection,
    link: SerialLink,
    site: SiteSource,
    clock: fn() -> DateTime<Utc>,
    state: Mutex<MountState>,
    pulse_guide_cancel: Arc<Notify>,
}

impl std::fmt::Debug for SkyWatcherMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SkyWatcherMount")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

/// Where a guide pulse leaves its axis: back at the tracking step period, or
/// stopped. Restores on drop too, so a pulse whose caller gave up does not
/// leave the axis running at the guide rate.
struct PulseRestore<'a> {
    mount: &'a SkyWatcherMount,
    axis: Axis,
    period: Option<u32>,
    armed: bool,
}

impl PulseRestore<'_> {
    fn restore(&self) -> Result<(), DriverError> {
        match self.period {
            Some(period) => self
                .mount
                .ask(command::SET_STEP_PERIOD, self.axis, &encode_u24(period))
                .map(drop),
            None => self.mount.ask(command::STOP, self.axis, "").map(drop),
        }
    }

    fn finish(mut self) -> Result<(), DriverError> {
        self.armed = false;
        self.restore()
    }
}

impl Drop for PulseRestore<'_> {
    fn drop(&mut self) {
        if self.armed {
            if let Err(err) = self.restore() {
                tracing::warn!(
                    "Sky-Watcher: could not end the guide pulse on the {} axis: {}",
                    self.axis.name(),
                    err
                );
            }
        }
    }
}

impl SkyWatcherMount {
    /// A mount on a serial port. `site` is read whenever the driver needs
    /// the observing site.
    pub fn new_serial(port: String, baud_rate: Option<u32>, site: SiteSource) -> Self {
        let device_id = format!(
            "native:skywatcher:{}",
            serial_link::sanitize_port_name(&port)
        );
        Self::new(
            device_id,
            format!("Sky-Watcher ({})", port),
            SynScanConnection::Serial {
                port,
                baud_rate: baud_rate.unwrap_or(SYNSCAN_BAUD_RATE),
            },
            site,
        )
    }

    /// A mount on Wi-Fi.
    pub fn new_udp(ip: Option<String>, port: Option<u16>, site: SiteSource) -> Self {
        let ip = ip.unwrap_or_else(|| SYNSCAN_UDP_IP.to_string());
        let port = port.unwrap_or(SYNSCAN_UDP_PORT);
        Self::new(
            format!("native:skywatcher:{}:{}", ip, port),
            format!("Sky-Watcher WiFi ({}:{})", ip, port),
            SynScanConnection::Udp { ip, port },
            site,
        )
    }

    fn new(
        device_id: String,
        name: String,
        connection_config: SynScanConnection,
        site: SiteSource,
    ) -> Self {
        Self {
            device_id,
            name,
            connection_config,
            link: SerialLink::new(),
            site,
            clock: Utc::now,
            state: Mutex::new(MountState::new()),
            pulse_guide_cancel: Arc::new(Notify::new()),
        }
    }

    /// The same mount on a fixed clock, for the serial wire tests.
    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn with_clock(mut self, clock: fn() -> DateTime<Utc>) -> Self {
        self.clock = clock;
        self
    }

    fn lock(&self) -> MutexGuard<'_, MountState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn state_mut(&mut self) -> &mut MountState {
        self.state.get_mut().unwrap_or_else(|e| e.into_inner())
    }

    fn controller(&self) -> Result<Controller, DriverError> {
        self.lock().controller.ok_or(DriverError::NotConnected)
    }

    fn sky(&self, controller: &Controller) -> Result<Sky, DriverError> {
        let site = (self.site)().ok_or_else(|| DriverError::InvalidParameter(NO_SITE.into()))?;
        Ok(Sky {
            frame: MountFrame {
                ra: controller.ra,
                dec: controller.dec,
                southern: site.latitude_deg < 0.0,
            },
            lst_hours: local_sidereal_hours((self.clock)(), site.longitude_deg),
            latitude_deg: site.latitude_deg,
        })
    }

    /// Sends one command and returns the data of its reply. A try whose
    /// reply does not come is sent again; a refusal is not.
    fn ask(&self, letter: char, axis: Axis, data: &str) -> Result<String, DriverError> {
        let text = command_text(letter, axis, data);
        let wire = format!("{text}\r");
        let mut last_error = None;
        for _ in 0..COMMAND_TRIES {
            let outcome = self.link.exchange(|io| {
                io.discard_input()?;
                io.send(wire.as_bytes())?;
                for _ in 0..MAX_OTHER_LINES {
                    match classify_reply(&io.read_reply(&SYNSCAN_REPLY)?) {
                        ReplyLine::Data(data) => return Ok(Ok(data)),
                        ReplyLine::Refused(code) => return Ok(Err(code)),
                        ReplyLine::Other => continue,
                    }
                }
                Err(DriverError::SdkError(format!(
                    "Sky-Watcher mount sent no reply to {text}"
                )))
            });
            match outcome {
                Ok(Ok(data)) => return Ok(data),
                Ok(Err(code)) => {
                    return Err(DriverError::SdkError(format!(
                        "Sky-Watcher mount refused {text}: {} (!{code})",
                        refusal_meaning(code)
                    )))
                }
                Err(err @ (DriverError::Timeout(_) | DriverError::SdkError(_))) => {
                    tracing::debug!("Sky-Watcher {text}: {err}; trying again");
                    last_error = Some(err);
                }
                Err(err) => return Err(err),
            }
        }
        Err(match last_error {
            Some(DriverError::Timeout(_)) | None => DriverError::Timeout(format!(
                "Sky-Watcher mount did not answer {text} ({COMMAND_TRIES} tries)"
            )),
            Some(other) => other,
        })
    }

    fn status(&self, axis: Axis) -> Result<AxisStatus, DriverError> {
        AxisStatus::parse(&self.ask(command::STATUS, axis, "")?)
    }

    fn position(&self, axis: Axis) -> Result<u32, DriverError> {
        decode_u24(&self.ask(command::POSITION, axis, "")?)
    }

    fn positions(&self) -> Result<AxisSteps, DriverError> {
        Ok(AxisSteps {
            ra: self.position(Axis::Ra)?,
            dec: self.position(Axis::Dec)?,
        })
    }

    /// The mount's own pointing and the sync offset applied to it.
    fn coordinates(&self, sky: &Sky, sync: SyncOffset) -> Result<(f64, f64), DriverError> {
        let pointing = sky.frame.pointing(self.positions()?, sky.lst_hours);
        Ok(offset(
            pointing.ra_hours,
            pointing.dec_degrees,
            sync.ra_hours,
            sync.dec_degrees,
        ))
    }

    /// Stops `axis` with its deceleration ramp and waits until it stands.
    async fn stop_and_wait(&self, axis: Axis) -> Result<AxisStatus, DriverError> {
        self.ask(command::STOP, axis, "")?;
        let started = tokio::time::Instant::now();
        loop {
            let status = self.status(axis)?;
            if !status.running {
                return Ok(status);
            }
            if started.elapsed() > STOP_LIMIT {
                return Err(DriverError::Timeout(format!(
                    "the {} axis of the Sky-Watcher mount was still moving {} s after the stop",
                    axis.name(),
                    STOP_LIMIT.as_secs()
                )));
            }
            tokio::time::sleep(STOP_POLL).await;
        }
    }

    async fn stop_both(&self) -> Result<(), DriverError> {
        self.stop_and_wait(Axis::Ra).await?;
        self.stop_and_wait(Axis::Dec).await?;
        Ok(())
    }

    /// Runs `axis` at `rate` times the sidereal rate (positive forward). A
    /// motion of the same kind and direction only gets the new step period;
    /// any other is stopped first.
    async fn drive(
        &self,
        controller: &Controller,
        axis: Axis,
        rate: f64,
    ) -> Result<(), DriverError> {
        let mut status = self.status(axis)?;
        let mode = constant_rate_mode(rate);
        if status.running && !mode.matches(&status) {
            status = self.stop_and_wait(axis).await?;
        }
        self.set_rate(controller, axis, rate, status)
    }

    /// [`Self::drive`] for an axis known to be stopped or already moving
    /// the right way.
    fn set_rate(
        &self,
        controller: &Controller,
        axis: Axis,
        rate: f64,
        status: AxisStatus,
    ) -> Result<(), DriverError> {
        let mode = constant_rate_mode(rate);
        let already_moving = status.running && mode.matches(&status);
        if !already_moving {
            self.ask(command::SET_MOTION_MODE, axis, &mode.data())?;
        }
        let period = controller.step_period(axis, rate);
        self.ask(command::SET_STEP_PERIOD, axis, &encode_u24(period))?;
        if !already_moving {
            self.ask(command::START, axis, "")?;
        }
        Ok(())
    }

    /// Tracking rate along the RA axis, signed for the hemisphere.
    fn tracking_rate(state: &MountState, sky: &Sky) -> f64 {
        let rate = sidereal_multiple(state.rate);
        if sky.frame.southern {
            -rate
        } else {
            rate
        }
    }

    /// Starts one goto pass of `axis` from `from` to `to`. The axis is
    /// stopped. The deceleration ramp and speeds are indi-eqmod's.
    fn start_goto_pass(&self, axis: Axis, from: u32, to: u32) -> Result<(), DriverError> {
        let delta = i64::from(to) - i64::from(from);
        if delta == 0 {
            return Ok(());
        }
        let distance = delta.unsigned_abs() as u32;
        let high_speed = distance > LOW_SPEED_GOTO_MARGIN;
        let mode = MotionMode {
            goto: true,
            high_speed,
            forward: delta > 0,
        };
        let (period, ramp) = if high_speed {
            (HIGH_SPEED_GOTO_PERIOD, (distance / 10).min(3200))
        } else {
            (LOW_SPEED_GOTO_PERIOD, (distance / 10).min(200))
        };
        self.ask(command::SET_MOTION_MODE, axis, &mode.data())?;
        self.ask(command::SET_STEP_PERIOD, axis, &encode_u24(period))?;
        self.ask(command::SET_GOTO_INCREMENT, axis, &encode_u24(distance))?;
        self.ask(command::SET_BREAK_INCREMENT, axis, &encode_u24(ramp))?;
        self.ask(command::START, axis, "")?;
        Ok(())
    }

    /// Starts both axes toward `target`. On a refusal both axes are stopped
    /// again, so the mount never runs half a goto.
    fn start_goto(&self, from: AxisSteps, target: AxisSteps) -> Result<(), DriverError> {
        let started = self
            .start_goto_pass(Axis::Ra, from.ra, target.ra)
            .and_then(|()| self.start_goto_pass(Axis::Dec, from.dec, target.dec));
        if let Err(err) = started {
            for axis in Axis::BOTH {
                if let Err(stop_err) = self.ask(command::STOP, axis, "") {
                    tracing::warn!(
                        "Sky-Watcher: could not stop the {} axis after a failed goto: {}",
                        axis.name(),
                        stop_err
                    );
                }
            }
            return Err(err);
        }
        Ok(())
    }

    /// Stops what is moving and sends both axes to the home position.
    async fn start_home_goto(&mut self, motion: Motion) -> Result<(), DriverError> {
        let controller = self.controller()?;
        self.pulse_guide_cancel.notify_waiters();
        self.stop_both().await?;
        let home = home(&controller.ra, &controller.dec);
        let state = self.state_mut();
        state.tracking = false;
        state.motion = Motion::Idle;
        self.start_goto(self.positions()?, home)?;
        self.state_mut().motion = motion;
        Ok(())
    }

    /// Reads the controller and brings it to the encoder frame of
    /// [`pointing`].
    fn handshake(&self) -> Result<(Controller, bool), DriverError> {
        let version =
            BoardVersion::parse(&self.ask(command::MOTOR_BOARD_VERSION, Axis::Ra, "")?)?;
        if version.is_alt_azimuth_only() {
            return Err(DriverError::InvalidDevice(format!(
                "{} is an alt-azimuth mount (mount code 0x{:02X}); Skotiq drives Sky-Watcher equatorial mounts",
                version.describe(),
                version.mount_code
            )));
        }
        let mut counts = [0u32; 2];
        let mut timer_hz = [0u32; 2];
        for axis in Axis::BOTH {
            let i = axis_index(axis);
            counts[i] = decode_u24(&self.ask(command::COUNTS_PER_REVOLUTION, axis, "")?)?;
            timer_hz[i] = firmware_timer_hz(
                &version,
                decode_u24(&self.ask(command::TIMER_FREQUENCY, axis, "")?)?,
            );
            if counts[i] == 0 || timer_hz[i] == 0 {
                return Err(DriverError::SdkError(format!(
                    "{} reported {} steps per turn and a {} Hz timer on the {} axis",
                    version.describe(),
                    counts[i],
                    timer_hz[i],
                    axis.name()
                )));
            }
        }

        let ra_status = self.status(Axis::Ra)?;
        let dec_status = self.status(Axis::Dec)?;
        let (zero, initialized_now) = if !ra_status.initialized && !dec_status.initialized {
            // Freshly powered: the mount stands at the pole with the
            // counterweight down, wherever its counters start.
            let zero = self.positions()?;
            self.ask(command::INITIALIZE, Axis::Ra, "")?;
            self.ask(command::INITIALIZE, Axis::Dec, "")?;
            let pole = zero.dec.wrapping_add(counts[1] / 4);
            self.ask(command::SET_POSITION, Axis::Dec, &encode_u24(pole))?;
            (zero, true)
        } else {
            (
                AxisSteps {
                    ra: POWER_ON_STEP,
                    dec: POWER_ON_STEP,
                },
                false,
            )
        };
        Ok((
            Controller {
                version,
                ra: AxisScale {
                    zero: zero.ra,
                    counts: counts[0],
                },
                dec: AxisScale {
                    zero: zero.dec,
                    counts: counts[1],
                },
                timer_hz,
            },
            initialized_now,
        ))
    }
}

/// `ra`, `dec` moved by an offset, folded back over the pole when the offset
/// carries the declination past it.
fn offset(ra_hours: f64, dec_degrees: f64, d_ra: f64, d_dec: f64) -> (f64, f64) {
    let mut ra = ra_hours + d_ra;
    let mut dec = dec_degrees + d_dec;
    if dec > 90.0 {
        dec = 180.0 - dec;
        ra += 12.0;
    } else if dec < -90.0 {
        dec = -180.0 - dec;
        ra += 12.0;
    }
    (ra.rem_euclid(24.0), dec)
}

fn constant_rate_mode(rate: f64) -> MotionMode {
    MotionMode {
        goto: false,
        high_speed: false,
        forward: rate >= 0.0,
    }
}

fn sidereal_multiple(rate: TrackingRate) -> f64 {
    let arcsec_per_second = match rate {
        TrackingRate::Sidereal | TrackingRate::Custom => SIDEREAL_ARCSEC_PER_SECOND,
        TrackingRate::Lunar => 14.511_415,
        TrackingRate::Solar => 1_296_000.0 / 86_400.0,
        // ASCOM's King rate.
        TrackingRate::King => 15.0369,
    };
    arcsec_per_second / SIDEREAL_ARCSEC_PER_SECOND
}

/// Timer frequencies indi-eqmod corrects because the firmware reports them
/// wrong: the 114GT, and the HEQ5 with firmware 1.06.
fn firmware_timer_hz(version: &BoardVersion, reported: u32) -> u32 {
    match (version.mount_code, version.number()) {
        (0x82, _) => 0x20_5318,
        (_, 0x01_0601) => 0xFC80,
        _ => reported,
    }
}

fn hours_between(a: f64, b: f64) -> f64 {
    let mut d = (a - b).rem_euclid(24.0);
    if d >= 12.0 {
        d -= 24.0;
    }
    d
}

#[async_trait]
impl DeviceDriver for SkyWatcherMount {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::SkyWatcher
    }

    fn is_connected(&self) -> bool {
        self.lock().controller.is_some()
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }

        let (port, baud_rate) = match &self.connection_config {
            SynScanConnection::Serial { port, baud_rate } => (port.clone(), *baud_rate),
            SynScanConnection::Udp { .. } => return Err(DriverError::NotSupported),
        };
        {
            let _serial_access = serial_link::serial_mount_access().await;
            let serial = serial_link::open_port(&port, baud_rate)
                .map_err(|e| DriverError::SdkError(format!("Failed to open serial port: {}", e)))?;
            self.link.attach(serial)?;
        }

        let (controller, initialized_now) = match self.handshake() {
            Ok(found) => found,
            Err(err) => {
                self.link.detach()?;
                return Err(err);
            }
        };
        let tracking = self
            .status(Axis::Ra)
            .map(|s| s.tracking_like() && !s.high_speed)
            .unwrap_or(false);
        let described = controller.version.describe();
        tracing::info!(
            "Connected to {described} on {port} at {baud_rate} baud: {} and {} steps per turn, {} Hz timer; {}",
            controller.ra.counts,
            controller.dec.counts,
            controller.timer_hz[0],
            if initialized_now {
                "initialized it at the power-on position (counterweight down, telescope at the pole)"
            } else {
                "it was already initialized, so its counters are read in the EQMOD frame"
            }
        );
        self.name = format!("Sky-Watcher {} ({})", controller.version.model(), port);
        let state = self.state_mut();
        *state = MountState::new();
        state.controller = Some(controller);
        state.tracking = tracking;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Ok(());
        }
        self.pulse_guide_cancel.notify_waiters();
        for axis in Axis::BOTH {
            if let Err(err) = self.ask(command::STOP, axis, "") {
                tracing::warn!(
                    "Sky-Watcher: could not stop the {} axis before disconnecting: {}",
                    axis.name(),
                    err
                );
            }
        }
        self.link.detach()?;
        *self.state_mut() = MountState::new();
        tracing::info!("Disconnected from the Sky-Watcher mount");
        Ok(())
    }
}

#[async_trait]
impl MountDriver for SkyWatcherMount {
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        let controller = self.controller()?;
        if self.lock().parked {
            return Err(DriverError::InvalidParameter(PARKED.into()));
        }
        let sky = self.sky(&controller)?;
        let sync = self.lock().sync;
        let (ra, dec) = offset(ra_hours, dec_degrees, -sync.ra_hours, -sync.dec_degrees);
        let pier_side = pier_side_for(ra, sky.lst_hours);
        tracing::info!(
            "Sky-Watcher goto to RA {ra_hours:.4} h, Dec {dec_degrees:.4} deg from the {pier_side} side of the pier"
        );

        self.pulse_guide_cancel.notify_waiters();
        self.state_mut().motion = Motion::Idle;
        self.stop_both().await?;
        let target = sky.frame.steps(ra, dec, pier_side, sky.lst_hours);
        self.start_goto(self.positions()?, target)?;
        self.state_mut().motion = Motion::Goto(Goto {
            ra_hours: ra,
            dec_degrees: dec,
            pier_side,
            passes: 1,
        });
        Ok(())
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        let controller = self.controller()?;
        let sky = self.sky(&controller)?;
        let sync = self.lock().sync;
        self.coordinates(&sky, sync)
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        let controller = self.controller()?;
        let sky = self.sky(&controller)?;
        let pointing = sky.frame.pointing(self.positions()?, sky.lst_hours);
        let sync = SyncOffset {
            ra_hours: hours_between(ra_hours, pointing.ra_hours),
            dec_degrees: dec_degrees - pointing.dec_degrees,
        };
        tracing::info!(
            "Sky-Watcher synced to RA {ra_hours:.4} h, Dec {dec_degrees:.4} deg: the mount was {:.1}\" off in RA and {:.1}\" in Dec",
            sync.ra_hours * 54_000.0,
            sync.dec_degrees * 3600.0
        );
        let state = self.state_mut();
        state.sync = sync;
        state.parked = false;
        Ok(())
    }

    /// Sends the mount to its home position (counterweight down, telescope
    /// at the pole) and waits for it to arrive.
    async fn park(&mut self) -> Result<(), DriverError> {
        self.controller()?;
        if self.lock().parked {
            return Ok(());
        }
        tracing::info!("Parking the Sky-Watcher mount at its home position");
        self.start_home_goto(Motion::Parking).await?;
        let started = tokio::time::Instant::now();
        while self.is_slewing().await? {
            if started.elapsed() > PARK_LIMIT {
                self.state_mut().motion = Motion::Idle;
                for axis in Axis::BOTH {
                    let _ = self.ask(command::STOP, axis, "");
                }
                return Err(DriverError::Timeout(format!(
                    "the Sky-Watcher mount had not reached its park position after {} s; stopped it",
                    PARK_LIMIT.as_secs()
                )));
            }
            tokio::time::sleep(PARK_POLL).await;
        }
        Ok(())
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        self.controller()?;
        self.state_mut().parked = false;
        self.set_tracking(true).await?;
        tracing::info!("Sky-Watcher mount unparked");
        Ok(())
    }

    /// Also where a goto is carried to its end: once both axes stand, a
    /// further pass corrects for the sky that turned during the slew, and
    /// tracking starts again.
    async fn is_slewing(&self) -> Result<bool, DriverError> {
        let mut state = self.lock();
        let controller = state.controller.ok_or(DriverError::NotConnected)?;
        let ra = self.status(Axis::Ra)?;
        let dec = self.status(Axis::Dec)?;
        match state.motion {
            Motion::Idle => Ok(ra.in_goto() || dec.in_goto()),
            _ if ra.running || dec.running => Ok(true),
            Motion::Parking => {
                state.motion = Motion::Idle;
                state.parked = true;
                tracing::info!("Sky-Watcher mount parked");
                Ok(false)
            }
            Motion::Homing => {
                state.motion = Motion::Idle;
                Ok(false)
            }
            Motion::Goto(goto) => {
                let sky = self.sky(&controller)?;
                let target = sky.frame.steps(
                    goto.ra_hours,
                    goto.dec_degrees,
                    goto.pier_side,
                    sky.lst_hours,
                );
                let at = self.positions()?;
                let off_by = |axis: Axis, from: u32, to: u32| {
                    from.abs_diff(to)
                        > controller
                            .scale(axis)
                            .steps_in_arcseconds(GOTO_RESOLUTION_ARCSEC)
                };
                let short =
                    off_by(Axis::Ra, at.ra, target.ra) || off_by(Axis::Dec, at.dec, target.dec);
                if short && goto.passes < GOTO_PASSES {
                    if let Err(err) = self.start_goto(at, target) {
                        state.motion = Motion::Idle;
                        return Err(err);
                    }
                    state.motion = Motion::Goto(Goto {
                        passes: goto.passes + 1,
                        ..goto
                    });
                    return Ok(true);
                }
                state.motion = Motion::Idle;
                if short {
                    tracing::warn!(
                        "Sky-Watcher goto ended {} RA and {} Dec steps from its target after {} passes",
                        i64::from(target.ra) - i64::from(at.ra),
                        i64::from(target.dec) - i64::from(at.dec),
                        goto.passes
                    );
                } else {
                    tracing::info!("Sky-Watcher goto arrived after {} pass(es)", goto.passes);
                }
                if state.tracking {
                    self.set_rate(&controller, Axis::Ra, Self::tracking_rate(&state, &sky), ra)?;
                }
                Ok(false)
            }
        }
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        Ok(self.lock().parked)
    }

    /// ASCOM directions on either side of the pier: north raises the
    /// declination, west speeds the RA axis up and east slows it down.
    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        let controller = self.controller()?;
        let (motion, tracking) = {
            let state = self.lock();
            (state.motion, state.tracking)
        };
        if motion != Motion::Idle {
            return Err(DriverError::InvalidParameter(
                "The Sky-Watcher mount cannot take a guide pulse during a goto or park".into(),
            ));
        }
        if duration_ms == 0 {
            return Ok(());
        }
        let sky = self.sky(&controller)?;

        let (axis, rate, restore_period) = match direction {
            GuideDirection::East | GuideDirection::West => {
                let hemisphere = if sky.frame.southern { -1.0 } else { 1.0 };
                let base = if tracking {
                    sidereal_multiple(self.lock().rate)
                } else {
                    0.0
                };
                let shift = if direction == GuideDirection::West {
                    GUIDE_RATE
                } else {
                    -GUIDE_RATE
                };
                let restore = tracking.then(|| controller.step_period(Axis::Ra, base));
                (Axis::Ra, hemisphere * (base + shift), restore)
            }
            GuideDirection::North | GuideDirection::South => {
                let forward_is_north = sky.frame.dec_forward_is_north(self.position(Axis::Dec)?);
                let north = direction == GuideDirection::North;
                let rate = if north == forward_is_north {
                    GUIDE_RATE
                } else {
                    -GUIDE_RATE
                };
                (Axis::Dec, rate, None)
            }
        };

        self.drive(&controller, axis, rate).await?;
        let started = tokio::time::Instant::now();
        let restore = PulseRestore {
            mount: self,
            axis,
            period: restore_period,
            armed: true,
        };
        let remaining =
            Duration::from_millis(u64::from(duration_ms)).saturating_sub(started.elapsed());
        let cancelled = serial_link::pulse_guide_wait(remaining, &self.pulse_guide_cancel).await;
        restore.finish()?;
        if cancelled {
            tracing::debug!(
                "Sky-Watcher guide pulse {direction:?} cancelled before {duration_ms} ms"
            );
        }
        Ok(())
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        let controller = self.controller()?;
        tracing::info!("Stopping the Sky-Watcher mount");
        self.pulse_guide_cancel.notify_waiters();
        self.state_mut().motion = Motion::Idle;
        self.stop_both().await?;
        if self.lock().tracking {
            let restarted = match self.sky(&controller) {
                Ok(sky) => {
                    let rate = Self::tracking_rate(&self.lock(), &sky);
                    self.drive(&controller, Axis::Ra, rate).await
                }
                Err(err) => Err(err),
            };
            if let Err(err) = restarted {
                tracing::warn!("Sky-Watcher: stopped, but could not restart tracking: {err}");
                self.state_mut().tracking = false;
            }
        }
        Ok(())
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        let controller = self.controller()?;
        let (parked, motion) = {
            let state = self.lock();
            (state.parked, state.motion)
        };
        if !enabled {
            self.state_mut().tracking = false;
            if motion == Motion::Idle {
                self.ask(command::STOP, Axis::Ra, "")?;
            }
            tracing::info!("Sky-Watcher tracking off");
            return Ok(());
        }
        if parked {
            return Err(DriverError::InvalidParameter(PARKED.into()));
        }
        let sky = self.sky(&controller)?;
        if motion == Motion::Idle {
            let rate = Self::tracking_rate(&self.lock(), &sky);
            self.drive(&controller, Axis::Ra, rate).await?;
        }
        self.state_mut().tracking = true;
        tracing::info!("Sky-Watcher tracking on");
        Ok(())
    }

    /// Read from the RA axis, so it fails when the mount stops answering.
    async fn get_tracking(&self) -> Result<bool, DriverError> {
        self.controller()?;
        let ra = self.status(Axis::Ra)?;
        let state = self.lock();
        Ok(match state.motion {
            Motion::Goto(_) => state.tracking,
            Motion::Idle => ra.tracking_like() && !ra.high_speed,
            Motion::Parking | Motion::Homing => false,
        })
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        let controller = self.controller()?;
        if rate == TrackingRate::Custom {
            return Err(DriverError::NotSupported);
        }
        self.state_mut().rate = rate;
        let (tracking, motion) = {
            let state = self.lock();
            (state.tracking, state.motion)
        };
        if tracking && motion == Motion::Idle {
            let sky = self.sky(&controller)?;
            let signed = Self::tracking_rate(&self.lock(), &sky);
            self.drive(&controller, Axis::Ra, signed).await?;
        }
        Ok(())
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        self.controller()?;
        Ok(self.lock().rate)
    }

    async fn can_slew(&self) -> bool {
        true
    }

    async fn can_sync(&self) -> bool {
        true
    }

    async fn can_pulse_guide(&self) -> bool {
        true
    }

    async fn can_set_tracking_rate(&self) -> bool {
        true
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        let controller = self.controller()?;
        let sky = self.sky(&controller)?;
        Ok(sky
            .frame
            .pointing(self.positions()?, sky.lst_hours)
            .pier_side)
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        let controller = self.controller()?;
        let sky = self.sky(&controller)?;
        let sync = self.lock().sync;
        let (ra, dec) = self.coordinates(&sky, sync)?;
        Ok(alt_az(ra, dec, sky.latitude_deg, sky.lst_hours))
    }

    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        let controller = self.controller()?;
        Ok(self.sky(&controller)?.lst_hours)
    }

    async fn can_find_home(&self) -> Result<bool, DriverError> {
        Ok(true)
    }

    /// Sends the mount to the power-on position without parking it.
    async fn find_home(&mut self) -> Result<(), DriverError> {
        self.controller()?;
        if self.lock().parked {
            return Err(DriverError::InvalidParameter(PARKED.into()));
        }
        tracing::info!("Sending the Sky-Watcher mount to its home position");
        self.start_home_goto(Motion::Homing).await
    }

    async fn at_home(&self) -> Result<bool, DriverError> {
        let controller = self.controller()?;
        let home = home(&controller.ra, &controller.dec);
        let at = self.positions()?;
        Ok(
            at.ra.abs_diff(home.ra) <= controller.ra.steps_in_arcseconds(AT_HOME_ARCSEC)
                && at.dec.abs_diff(home.dec) <= controller.dec.steps_in_arcseconds(AT_HOME_ARCSEC),
        )
    }
}

pub struct SkyWatcherMountInfo {
    pub port: String,
    pub name: String,
    pub firmware_version: Option<String>,
    /// Baud rate that was successful during discovery
    pub baud_rate: u32,
}

/// Discover Sky-Watcher mounts on serial ports
/// Tries multiple baud rates to support both older and newer mounts
pub async fn discover_mounts() -> Result<Vec<SkyWatcherMountInfo>, DriverError> {
    serial_link::run_serial_scan("Sky-Watcher", scan_serial_ports).await
}

fn scan_serial_ports() -> Result<Vec<SkyWatcherMountInfo>, DriverError> {
    serial_link::scan_ports(&SCAN_PLAN, identify_mount)
}

/// The same scan over ports a test supplies.
#[cfg(all(test, target_os = "linux"))]
pub(crate) fn scan_port_list(ports: Vec<serialport::SerialPortInfo>) -> Vec<SkyWatcherMountInfo> {
    serial_link::scan_port_list(&SCAN_PLAN, ports, identify_mount)
}

/// Asks for the motor board version: it changes nothing on the mount
/// (the initialization command would power the motors of whatever answers).
fn identify_mount(port: &mut ProbedPort<'_>) -> Option<SkyWatcherMountInfo> {
    let probe_command = format!(
        "{}\r",
        command_text(command::MOTOR_BOARD_VERSION, Axis::Ra, "")
    );
    let response = port.ask(&Probe {
        command: probe_command.as_bytes(),
        settle: PROBE_SETTLE,
        reply_capacity: PROBE_REPLY_CAPACITY,
    })?;
    tracing::debug!(
        "Sky-Watcher response from {} at {} baud: {:?}",
        port.name,
        port.baud_rate,
        response
    );
    let line = response.split('\r').next().unwrap_or_default();
    let ReplyLine::Data(data) = classify_reply(line) else {
        return None;
    };
    let version = BoardVersion::parse(&data).ok()?;
    tracing::info!(
        "Found {} on {} at {} baud",
        version.describe(),
        port.name,
        port.baud_rate
    );
    Some(SkyWatcherMountInfo {
        port: port.name.to_string(),
        name: format!("Sky-Watcher {} ({})", version.model(), port.name),
        firmware_version: Some(version.describe()),
        baud_rate: port.baud_rate,
    })
}

#[cfg(test)]
mod tests;
