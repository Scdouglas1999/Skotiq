//! Sky-Watcher SynScan Mount Protocol Implementation
//!
//! Implements the Sky-Watcher motor controller protocol for EQ and AltAz mounts.
//! Protocol reference: Sky-Watcher Motor Controller Command Set
//!
//! Communication: Serial 9600/115200 baud or UDP (192.168.4.1:11880)

use super::serial_link::{
    self, OnOpenFailure, Probe, ProbedPort, ReplyRule, ScanPlan, SerialLink, REPLY_DEADLINE,
};
use super::sexagesimal::{degrees_to_hours, hours_to_degrees};
use async_trait::async_trait;
use skotiq_device::Vendor;
use skotiq_device::*;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

// Constants

/// Default serial baud rate for SynScan protocol (older mounts, hand controller)
const SYNSCAN_BAUD_RATE: u32 = 9600;

/// Baud rates to try during discovery, in order of preference
/// - 115200: Newer mounts (EQ6-R Pro, EQ8, etc.) via USB
/// - 9600: Older mounts, hand controller connections
const SYNSCAN_DISCOVERY_BAUD_RATES: &[u32] = &[115200, 9600];

/// Replies end in CR; the motor controller sends nothing between them.
const SYNSCAN_REPLY: ReplyRule = ReplyRule {
    terminator: b'\r',
    leading_framing: &[],
    deadline: REPLY_DEADLINE,
    timeout_message: "SkyWatcher command response timed out",
};

const SCAN_PLAN: ScanPlan = ScanPlan {
    protocol: "Sky-Watcher",
    baud_rates: SYNSCAN_DISCOVERY_BAUD_RATES,
    on_open_failure: OnOpenFailure::NextPort,
};

/// Time the motor controller gets to answer a discovery probe.
const PROBE_SETTLE: Duration = Duration::from_millis(100);
const PROBE_REPLY_CAPACITY: usize = 32;

/// Default UDP port for WiFi-enabled mounts
const SYNSCAN_UDP_PORT: u16 = 11880;

/// Default UDP IP for WiFi-enabled mounts
const SYNSCAN_UDP_IP: &str = "192.168.4.1";

/// Position offset used in SynScan protocol (0x800000)
const POSITION_OFFSET: i64 = 0x800000;

/// Steps per full rotation (24-bit encoder)
const STEPS_PER_REVOLUTION: f64 = 16777216.0; // 2^24

/// Axis identifiers
const AXIS_RA: char = '1'; // RA or Azimuth
const AXIS_DEC: char = '2'; // Dec or Altitude

// SynScan commands

/// SynScan motor controller commands
mod commands {
    // Inquiry commands
    pub const GET_POSITION: char = 'j'; // Get axis position
    pub const GET_STATUS: char = 'f'; // Get axis status
    pub const GET_MOTOR_BOARD_VERSION: char = 'e'; // Inquire motor board version
    pub const INIT_CHECK: &str = ":F3"; // Check initialization

    // Motion commands
    pub const SET_GOTO_TARGET: char = 'S'; // Set goto target position
    pub const START_MOTION: char = 'J'; // Start motion to target
    pub const STOP_MOTION: char = 'K'; // Soft stop
    pub const SET_MOTION_MODE: char = 'G'; // Set motion mode (goto/tracking)

    // Position commands
    pub const SYNC_POSITION: char = 'E'; // Sync (set) axis position

    // Response indicators
    pub const RESPONSE_OK: char = '=';
    pub const RESPONSE_ERROR: char = '!';
}

// Motion mode flags

/// Motion mode byte construction.
///
/// Why: The SynScan motor protocol overloads bit `0x02` based on bit `0x01`
/// (the tracking/goto select bit):
/// - Bit `0x01 = 0` (goto mode):    bit `0x02 = 1` selects FAST slew speed
///                                   bit `0x04 = 1` selects CCW direction
/// - Bit `0x01 = 1` (tracking mode): bit `0x02 = 1` selects CCW direction
///                                   (fast/slow distinction is unused;
///                                    tracking is always slow)
///
/// This is a protocol-level overload, not a code bug. We deliberately keep
/// the `if is_tracking { 0x02 } else { 0x04 }` branch on the CCW bit to
/// preserve the wire-format semantics. Reference: Sky-Watcher Motor
/// Controller Command Set, "Set Motion Mode (G)" command, mode byte
/// description.
fn build_motion_mode(is_tracking: bool, is_fast: bool, is_ccw: bool) -> u8 {
    let mut mode: u8 = 0;
    if is_tracking {
        mode |= 0x01;
    }
    if is_fast {
        mode |= 0x02;
    }
    if is_ccw {
        mode |= if is_tracking { 0x02 } else { 0x04 };
    }
    mode
}

// Data encoding / decoding

/// Encode a 24-bit value to SynScan hex format (reversed byte pairs)
fn encode_24bit(value: i64) -> String {
    let bytes = [
        (value & 0xFF) as u8,
        ((value >> 8) & 0xFF) as u8,
        ((value >> 16) & 0xFF) as u8,
    ];
    format!("{:02X}{:02X}{:02X}", bytes[0], bytes[1], bytes[2])
}

/// Decode SynScan hex format to 24-bit value
fn decode_24bit(hex: &str) -> Result<i64, DriverError> {
    if hex.len() != 6 {
        return Err(DriverError::InvalidParameter(format!(
            "Expected 6 hex chars, got {}",
            hex.len()
        )));
    }

    let b0 = u8::from_str_radix(&hex[0..2], 16)
        .map_err(|_| DriverError::SdkError("Invalid hex".into()))?;
    let b1 = u8::from_str_radix(&hex[2..4], 16)
        .map_err(|_| DriverError::SdkError("Invalid hex".into()))?;
    let b2 = u8::from_str_radix(&hex[4..6], 16)
        .map_err(|_| DriverError::SdkError("Invalid hex".into()))?;

    Ok((b0 as i64) | ((b1 as i64) << 8) | ((b2 as i64) << 16))
}

/// Convert encoder steps to degrees
fn steps_to_degrees(steps: i64) -> f64 {
    (steps as f64 / STEPS_PER_REVOLUTION) * 360.0
}

/// Convert degrees to encoder steps
fn degrees_to_steps(degrees: f64) -> i64 {
    ((degrees / 360.0) * STEPS_PER_REVOLUTION) as i64
}

fn normalize_motor_board_version_response(response: &str) -> Option<String> {
    let version = response
        .trim()
        .trim_start_matches(commands::RESPONSE_OK)
        .trim_end_matches('\r')
        .trim();

    if version.len() < 4 || !version.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }

    Some(version.to_ascii_uppercase())
}

fn format_motor_board_versions(ra: Option<String>, dec: Option<String>) -> Option<String> {
    match (ra, dec) {
        (Some(ra), Some(dec)) if ra == dec => {
            Some(format!("Sky-Watcher motor board firmware {}", ra))
        }
        (Some(ra), Some(dec)) => Some(format!(
            "Sky-Watcher motor board firmware RA {}, Dec {}",
            ra, dec
        )),
        (Some(ra), None) => Some(format!("Sky-Watcher motor board firmware RA {}", ra)),
        (None, Some(dec)) => Some(format!("Sky-Watcher motor board firmware Dec {}", dec)),
        (None, None) => None,
    }
}

fn probe(command: &[u8]) -> Probe<'_> {
    Probe {
        command,
        settle: PROBE_SETTLE,
        reply_capacity: PROBE_REPLY_CAPACITY,
    }
}

fn query_motor_board_version(port: &mut ProbedPort<'_>, axis: char) -> Option<String> {
    let cmd = format!(":{}{}\r", commands::GET_MOTOR_BOARD_VERSION, axis);
    let response = port.ask(&probe(cmd.as_bytes()))?;
    normalize_motor_board_version_response(&response)
}

/// A reply is `=` and a payload, or `!` and an error code.
fn decode_reply(reply: String) -> Result<String, DriverError> {
    if reply.starts_with(commands::RESPONSE_ERROR) {
        return Err(DriverError::SdkError(format!("Mount error: {}", reply)));
    }

    Ok(match reply.strip_prefix(commands::RESPONSE_OK) {
        Some(payload) => payload.to_string(),
        None => reply,
    })
}

// Connection types

/// Connection type for SynScan mount
#[derive(Debug, Clone)]
pub enum SynScanConnection {
    /// Serial port connection
    Serial { port: String, baud_rate: u32 },
    /// UDP/WiFi connection
    Udp { ip: String, port: u16 },
}

impl Default for SynScanConnection {
    fn default() -> Self {
        SynScanConnection::Udp {
            ip: SYNSCAN_UDP_IP.to_string(),
            port: SYNSCAN_UDP_PORT,
        }
    }
}

// Sky-Watcher mount implementation

/// Sky-Watcher SynScan mount driver
pub struct SkyWatcherMount {
    device_id: String,
    name: String,
    connection_config: SynScanConnection,
    link: SerialLink,
    connected: Mutex<bool>,
    is_tracking: Mutex<bool>,
    is_slewing: Mutex<bool>,
    is_parked: Mutex<bool>,
    pulse_guide_cancel: Arc<Notify>,
}

struct AxisMotionStopGuard<'a> {
    mount: &'a SkyWatcherMount,
    axis: char,
    armed: bool,
}

impl<'a> AxisMotionStopGuard<'a> {
    fn new(mount: &'a SkyWatcherMount, axis: char) -> Self {
        Self {
            mount,
            axis,
            armed: true,
        }
    }

    fn stop(mut self) -> Result<(), DriverError> {
        self.armed = false;
        self.mount.stop_axis_motion(self.axis)
    }
}

impl Drop for AxisMotionStopGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            if let Err(err) = self.mount.stop_axis_motion(self.axis) {
                tracing::warn!(
                    "SkyWatcher pulse-guide stop guard failed to stop axis {}: {}",
                    self.axis,
                    err
                );
            }
        }
    }
}

impl std::fmt::Debug for SkyWatcherMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SkyWatcherMount")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

impl SkyWatcherMount {
    /// Create a new Sky-Watcher mount with serial connection
    pub fn new_serial(port: String, baud_rate: Option<u32>) -> Self {
        let device_id = format!(
            "native:skywatcher:{}",
            serial_link::sanitize_port_name(&port)
        );
        Self {
            device_id,
            name: format!("Sky-Watcher ({})", port),
            connection_config: SynScanConnection::Serial {
                port,
                baud_rate: baud_rate.unwrap_or(SYNSCAN_BAUD_RATE),
            },
            link: SerialLink::new(),
            connected: Mutex::new(false),
            is_tracking: Mutex::new(false),
            is_slewing: Mutex::new(false),
            is_parked: Mutex::new(false),
            pulse_guide_cancel: Arc::new(Notify::new()),
        }
    }

    /// Create a new Sky-Watcher mount with UDP/WiFi connection
    pub fn new_udp(ip: Option<String>, port: Option<u16>) -> Self {
        let ip = ip.unwrap_or_else(|| SYNSCAN_UDP_IP.to_string());
        let port = port.unwrap_or(SYNSCAN_UDP_PORT);
        let device_id = format!("native:skywatcher:{}:{}", ip, port);
        Self {
            device_id,
            name: format!("Sky-Watcher WiFi ({}:{})", ip, port),
            connection_config: SynScanConnection::Udp { ip, port },
            link: SerialLink::new(),
            connected: Mutex::new(false),
            is_tracking: Mutex::new(false),
            is_slewing: Mutex::new(false),
            is_parked: Mutex::new(false),
            pulse_guide_cancel: Arc::new(Notify::new()),
        }
    }

    /// Send a command (CR appended) and return the payload of its reply.
    fn send_command(&self, command: &str) -> Result<String, DriverError> {
        let reply = self
            .link
            .command(format!("{}\r", command).as_bytes(), &SYNSCAN_REPLY)?;
        decode_reply(reply)
    }

    /// Send axis command (format: :CMD{axis}{data})
    fn send_axis_command(
        &self,
        cmd: char,
        axis: char,
        data: Option<&str>,
    ) -> Result<String, DriverError> {
        let command = match data {
            Some(d) => format!(":{}{}{}", cmd, axis, d),
            None => format!(":{}{}", cmd, axis),
        };
        self.send_command(&command)
    }

    /// Get axis position in encoder steps
    fn get_axis_position(&self, axis: char) -> Result<i64, DriverError> {
        let response = self.send_axis_command(commands::GET_POSITION, axis, None)?;
        let raw = decode_24bit(&response)?;
        Ok(raw - POSITION_OFFSET)
    }

    /// Get axis status
    fn get_axis_status(&self, axis: char) -> Result<u16, DriverError> {
        let response = self.send_axis_command(commands::GET_STATUS, axis, None)?;
        u16::from_str_radix(&response, 16)
            .map_err(|_| DriverError::SdkError("Invalid status".into()))
    }

    /// Whether the axis is running a goto (from status).
    ///
    /// The `:f` status is three hex digits, most significant first: the mode
    /// (bit 0 set for tracking, clear for goto), the motion (bit 0 set while
    /// the motor runs) and the controller (bit 0 set once initialized). Bit 0
    /// of the whole value is the controller's "initialized", which read every
    /// initialized axis as slewing. A motor running in tracking mode is
    /// tracking or pulse guiding, not slewing.
    fn is_axis_slewing(&self, axis: char) -> Result<bool, DriverError> {
        let status = self.get_axis_status(axis)?;
        let running = (status >> 4) & 0x01 != 0;
        let goto_mode = (status >> 8) & 0x01 == 0;
        Ok(running && goto_mode)
    }

    /// Set axis goto target
    fn set_axis_target(&self, axis: char, steps: i64) -> Result<(), DriverError> {
        let encoded = encode_24bit(steps + POSITION_OFFSET);
        self.send_axis_command(commands::SET_GOTO_TARGET, axis, Some(&encoded))?;
        Ok(())
    }

    /// Start axis motion
    fn start_axis_motion(&self, axis: char) -> Result<(), DriverError> {
        self.send_axis_command(commands::START_MOTION, axis, None)?;
        Ok(())
    }

    /// Stop axis motion
    fn stop_axis_motion(&self, axis: char) -> Result<(), DriverError> {
        self.send_axis_command(commands::STOP_MOTION, axis, None)?;
        Ok(())
    }

    /// Set motion mode for axis
    fn set_axis_motion_mode(&self, axis: char, mode: u8) -> Result<(), DriverError> {
        let encoded = format!("{:02X}", mode);
        self.send_axis_command(commands::SET_MOTION_MODE, axis, Some(&encoded))?;
        Ok(())
    }

    /// Sync axis position
    fn sync_axis_position(&self, axis: char, steps: i64) -> Result<(), DriverError> {
        let encoded = encode_24bit(steps + POSITION_OFFSET);
        self.send_axis_command(commands::SYNC_POSITION, axis, Some(&encoded))?;
        Ok(())
    }
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
        *self.connected.lock().unwrap_or_else(|e| e.into_inner())
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }

        match &self.connection_config {
            SynScanConnection::Serial { port, baud_rate } => {
                let _serial_access = serial_link::serial_mount_access().await;
                let serial = serial_link::open_port(port, *baud_rate).map_err(|e| {
                    DriverError::SdkError(format!("Failed to open serial port: {}", e))
                })?;

                self.link.attach(serial)?;
            }
            SynScanConnection::Udp { ip: _, port: _ } => {
                return Err(DriverError::NotSupported);
            }
        }

        // Verify connection by querying position
        let _ = self.get_axis_position(AXIS_RA)?;

        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;
        tracing::info!("Connected to Sky-Watcher mount");

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Ok(());
        }

        // Stop any motion before disconnecting
        let _ = self.stop_axis_motion(AXIS_RA);
        let _ = self.stop_axis_motion(AXIS_DEC);

        self.link.detach()?;
        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        tracing::info!("Disconnected from Sky-Watcher mount");

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
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Slewing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        let ra_steps = degrees_to_steps(hours_to_degrees(ra_hours));
        let dec_steps = degrees_to_steps(dec_degrees);

        let goto_mode = build_motion_mode(false, true, false);
        self.set_axis_motion_mode(AXIS_RA, goto_mode)?;
        self.set_axis_motion_mode(AXIS_DEC, goto_mode)?;

        self.set_axis_target(AXIS_RA, ra_steps)?;
        self.set_axis_target(AXIS_DEC, dec_steps)?;

        self.start_axis_motion(AXIS_RA)?;
        self.start_axis_motion(AXIS_DEC)?;

        *self
            .is_slewing
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;

        // A commanded slew means the mount has left its parked position; clear
        // the software park flag so park/unpark state tracks physical reality.
        // Without this, a direct slew after a Park leaves is_parked() reporting
        // true while the mount is actually pointed elsewhere.
        *self.is_parked.lock().unwrap_or_else(|e| e.into_inner()) = false;

        Ok(())
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let ra_steps = self.get_axis_position(AXIS_RA)?;
        let dec_steps = self.get_axis_position(AXIS_DEC)?;

        let ra_hours = degrees_to_hours(steps_to_degrees(ra_steps));
        let dec_degrees = steps_to_degrees(dec_steps);

        let ra_normalized = ((ra_hours % 24.0) + 24.0) % 24.0;

        Ok((ra_normalized, dec_degrees))
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Syncing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        let ra_steps = degrees_to_steps(hours_to_degrees(ra_hours));
        let dec_steps = degrees_to_steps(dec_degrees);

        self.sync_axis_position(AXIS_RA, ra_steps)?;
        self.sync_axis_position(AXIS_DEC, dec_steps)?;

        // A sync redefines the mount's coordinate frame as part of active use;
        // clear the software park flag so it does not falsely report parked.
        *self.is_parked.lock().unwrap_or_else(|e| e.into_inner()) = false;

        Ok(())
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Parking mount");

        // LIMITATION: the SynScan axis protocol exposes no dedicated hardware
        // park/home primitive, so this parks to celestial RA=0h/Dec=0deg. For
        // a GEM that is an arbitrary mechanical orientation that depends on
        // local sidereal time — NOT a guaranteed counterweight-down safe stow.
        // A correct safe-stow requires a profile-configured park position
        // (alt/az or a home encoder step) plumbed from the equipment profile;
        // that coordinate is not available at this driver layer and must not be
        // guessed (a wrong hemisphere assumption could drive the OTA toward the
        // ground). Tracked as a follow-up requiring a park-position setting.
        self.slew_to_coordinates(0.0, 0.0).await?;

        while self.is_slewing().await? {
            tokio::time::sleep(Duration::from_millis(500)).await;
        }

        self.set_tracking(false).await?;

        *self
            .is_parked
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;

        Ok(())
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        *self
            .is_parked
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        self.set_tracking(true).await?;

        tracing::info!("Mount unparked");

        Ok(())
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let ra_slewing = self.is_axis_slewing(AXIS_RA)?;
        let dec_slewing = self.is_axis_slewing(AXIS_DEC)?;

        Ok(ra_slewing || dec_slewing)
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        Ok(*self.is_parked.lock().unwrap_or_else(|e| e.into_inner()))
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let (axis, is_positive) = match direction {
            GuideDirection::North => (AXIS_DEC, true),
            GuideDirection::South => (AXIS_DEC, false),
            GuideDirection::East => (AXIS_RA, false),
            GuideDirection::West => (AXIS_RA, true),
        };

        let mode = build_motion_mode(true, false, !is_positive);
        self.set_axis_motion_mode(axis, mode)?;

        let requested_duration = Duration::from_millis(u64::from(duration_ms));
        let started_at = tokio::time::Instant::now();
        self.start_axis_motion(axis)?;
        let stop_guard = AxisMotionStopGuard::new(self, axis);

        let remaining = requested_duration.saturating_sub(started_at.elapsed());
        let cancelled =
            serial_link::pulse_guide_wait(remaining, &stop_guard.mount.pulse_guide_cancel).await;

        stop_guard.stop()?;

        if cancelled {
            tracing::debug!(
                "SkyWatcher pulse_guide cancelled before {}ms elapsed; stopped axis {} immediately",
                duration_ms,
                axis
            );
        }

        Ok(())
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Aborting slew");

        self.pulse_guide_cancel.notify_waiters();
        self.stop_axis_motion(AXIS_RA)?;
        self.stop_axis_motion(AXIS_DEC)?;

        *self
            .is_slewing
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        Ok(())
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        if enabled {
            let mode = build_motion_mode(true, false, false);
            self.set_axis_motion_mode(AXIS_RA, mode)?;
            self.start_axis_motion(AXIS_RA)?;
        } else {
            self.stop_axis_motion(AXIS_RA)?;
        }

        *self
            .is_tracking
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = enabled;

        tracing::info!("Tracking {}", if enabled { "enabled" } else { "disabled" });

        Ok(())
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        Ok(*self.is_tracking.lock().unwrap_or_else(|e| e.into_inner()))
    }

    // Why: Pier-side derivation requires decoding the RA-axis encoder
    // position against the meridian crossing point. This SynScan driver does
    // not yet perform that decode, so reporting `Unknown` would let callers
    // (e.g. the sequencer's meridian-flip planner) treat the value as
    // authoritative. Returning `NotSupported` makes the missing capability
    // explicit so the status layer marks it unavailable and the sequencer
    // refuses to schedule a flip on this driver. Encoder-based decode is
    // tracked as a follow-up ( long-term).
    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        Err(DriverError::NotSupported)
    }

    // Why: Alt/Az is a derived quantity (RA/Dec + LST + observer location).
    // None of those inputs are tracked at the driver level here, and the
    // SynScan protocol exposes no native Alt/Az query. Surfacing
    // `NotSupported` is correct until the higher-level math is wired in.
    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        Err(DriverError::NotSupported)
    }

    // Why: Local sidereal time depends on system UTC + observer longitude;
    // the SynScan protocol has no LST query and this driver has no observer
    // context. Returning a fabricated value would silently corrupt any
    // downstream flip / pier-side / hour-angle calculation.
    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    // Why: The `:G` (set motion mode) command in this driver hard-codes
    // sidereal tracking via the motor-controller's default rate; there is no
    // path here to program lunar/solar/king/custom rates onto the axis. Even
    // for `Sidereal`, no per-rate configuration is sent — accepting the call
    // with `Ok(())` would lie to callers that "the rate is now sidereal".
    // Until per-rate programming is implemented, every variant must return
    // `NotSupported` so the status layer marks the rate unavailable and
    // callers (sequencer, UI) cannot rely on a fabricated value.
    async fn set_tracking_rate(&mut self, _rate: TrackingRate) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }
        Err(DriverError::NotSupported)
    }

    // Why: There is no SynScan query that reads back the active tracking-rate
    // selection. Returning a hardcoded `Sidereal` would falsely confirm a
    // rate that may never have been programmed. `NotSupported` is the honest
    // answer until the driver tracks rate state itself.
    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }
        Err(DriverError::NotSupported)
    }

    fn can_slew(&self) -> bool {
        true
    }

    fn can_sync(&self) -> bool {
        true
    }

    fn can_pulse_guide(&self) -> bool {
        true
    }

    fn can_set_tracking_rate(&self) -> bool {
        false
    }
}

// Discovery

/// Sky-Watcher mount discovery info
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

/// A motor controller answers the initialization check with `=` or `!`.
fn identify_mount(port: &mut ProbedPort<'_>) -> Option<SkyWatcherMountInfo> {
    let init_check = format!("{}\r", commands::INIT_CHECK);
    let response = port.ask(&probe(init_check.as_bytes()))?;
    tracing::debug!(
        "Sky-Watcher response from {} at {} baud: {:?}",
        port.name,
        port.baud_rate,
        response
    );
    if !(response.contains(commands::RESPONSE_OK) || response.contains(commands::RESPONSE_ERROR)) {
        return None;
    }

    let firmware_version = format_motor_board_versions(
        query_motor_board_version(port, AXIS_RA),
        query_motor_board_version(port, AXIS_DEC),
    );
    tracing::info!(
        "Found Sky-Watcher mount on {} at {} baud",
        port.name,
        port.baud_rate
    );
    Some(SkyWatcherMountInfo {
        port: port.name.to_string(),
        name: format!("Sky-Watcher ({})", port.name),
        firmware_version,
        baud_rate: port.baud_rate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a SkyWatcherMount instance forced into the "connected" state so
    /// trait methods skip the `NotConnected` guard and exercise their real
    /// branch. We never open a serial port — methods under test must reach
    /// their `NotSupported` return without performing any I/O.
    fn fake_connected_mount() -> SkyWatcherMount {
        let mount = SkyWatcherMount::new_serial("test-port".to_string(), Some(9600));
        *mount.connected.lock().unwrap() = true;
        mount
    }

    fn assert_not_supported<T: std::fmt::Debug>(result: Result<T, DriverError>) {
        match result {
            Err(DriverError::NotSupported) => {}
            other => panic!("expected Err(NotSupported), got {:?}", other),
        }
    }

    // Why: this driver reports "unavailable" for capabilities it cannot
    // actually provide, instead of returning fake values that mislead the
    // meridian-flip planner.
    #[tokio::test]
    async fn get_side_of_pier_returns_not_supported() {
        let mount = fake_connected_mount();
        assert_not_supported(mount.get_side_of_pier().await);
    }

    #[tokio::test]
    async fn get_alt_az_returns_not_supported() {
        let mount = fake_connected_mount();
        assert_not_supported(mount.get_alt_az().await);
    }

    #[tokio::test]
    async fn get_sidereal_time_returns_not_supported() {
        let mount = fake_connected_mount();
        assert_not_supported(mount.get_sidereal_time().await);
    }

    #[tokio::test]
    async fn set_tracking_rate_sidereal_returns_not_supported() {
        let mut mount = fake_connected_mount();
        // Sidereal must report not-supported, never a fake `Ok(())` no-op.
        assert_not_supported(mount.set_tracking_rate(TrackingRate::Sidereal).await);
    }

    #[tokio::test]
    async fn set_tracking_rate_non_sidereal_returns_not_supported() {
        let mut mount = fake_connected_mount();
        for rate in [
            TrackingRate::Lunar,
            TrackingRate::Solar,
            TrackingRate::King,
            TrackingRate::Custom,
        ] {
            assert_not_supported(mount.set_tracking_rate(rate).await);
        }
    }

    #[tokio::test]
    async fn get_tracking_rate_returns_not_supported() {
        let mount = fake_connected_mount();
        // The rate must report unavailable, never a hardcoded `Sidereal`.
        assert_not_supported(mount.get_tracking_rate().await);
    }

    /// The UDP transport is declared but not implemented: connecting says so
    /// and opens nothing. (A pseudo-terminal cannot stand in for it, so the
    /// wire transcripts do not cover it.)
    #[tokio::test]
    async fn a_udp_mount_reports_not_supported_on_connect() {
        let mut mount = SkyWatcherMount::new_udp(None, None);
        assert_eq!(mount.id(), "native:skywatcher:192.168.4.1:11880");
        assert_eq!(mount.name(), "Sky-Watcher WiFi (192.168.4.1:11880)");
        assert_not_supported(mount.connect().await);
        assert!(!mount.is_connected());
        assert!(matches!(
            mount.get_coordinates().await,
            Err(DriverError::NotConnected)
        ));
    }

    // Why: the motion-mode byte intentionally overloads bit `0x02`
    // with two meanings depending on bit `0x01`. Lock the encoding behavior
    // in tests so the protocol overload cannot be silently broken by a
    // refactor that "fixes" the apparent duplication.
    #[test]
    fn build_motion_mode_goto_uses_bit2_for_fast_and_bit4_for_ccw() {
        // Goto, slow, CW
        assert_eq!(build_motion_mode(false, false, false), 0x00);
        // Goto, fast, CW => bit 0x02 set as FAST
        assert_eq!(build_motion_mode(false, true, false), 0x02);
        // Goto, slow, CCW => bit 0x04 set as CCW (NOT bit 0x02)
        assert_eq!(build_motion_mode(false, false, true), 0x04);
        // Goto, fast, CCW => 0x02 (fast) | 0x04 (ccw)
        assert_eq!(build_motion_mode(false, true, true), 0x06);
    }

    #[test]
    fn build_motion_mode_tracking_uses_bit2_for_ccw() {
        // Tracking, slow, CW
        assert_eq!(build_motion_mode(true, false, false), 0x01);
        // Tracking, slow, CCW => bit 0x02 set as CCW (overloaded meaning)
        assert_eq!(build_motion_mode(true, false, true), 0x03);
        // Tracking, fast, CW => 0x01 | 0x02 (the encoder does not suppress
        // the fast bit in tracking mode; protocol ignores it on the wire).
        assert_eq!(build_motion_mode(true, true, false), 0x03);
    }

    #[test]
    fn normalize_motor_board_version_accepts_protocol_shape() {
        assert_eq!(
            normalize_motor_board_version_response("=030700\r").as_deref(),
            Some("030700")
        );
        assert_eq!(
            normalize_motor_board_version_response("=030701").as_deref(),
            Some("030701")
        );
    }

    #[test]
    fn normalize_motor_board_version_rejects_empty_or_non_hex() {
        assert_eq!(normalize_motor_board_version_response("="), None);
        assert_eq!(normalize_motor_board_version_response("=nothex"), None);
    }

    #[test]
    fn format_motor_board_versions_preserves_axis_specific_values() {
        assert_eq!(
            format_motor_board_versions(Some("030700".to_string()), Some("030701".to_string()))
                .as_deref(),
            Some("Sky-Watcher motor board firmware RA 030700, Dec 030701")
        );
    }

    /// A pseudo-terminal answering like a Sky-Watcher motor controller: the
    /// position query answers mid-travel and `:f1`/`:f2` answer the given
    /// three-digit status. Returns the slave path the mount opens.
    #[cfg(target_os = "linux")]
    fn spawn_synscan_pty(ra_status: &'static str, dec_status: &'static str) -> String {
        use std::io::{Read, Write};
        use std::os::fd::FromRawFd;

        let mut master: libc::c_int = 0;
        let mut slave: libc::c_int = 0;
        // SAFETY: openpty writes two descriptors into the provided ints; the
        // optional name, termios and winsize arguments are null.
        let rc = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        assert_eq!(rc, 0, "openpty failed");
        let mut name = [0 as libc::c_char; 256];
        // SAFETY: `name` is a writable buffer of the length passed.
        let rc = unsafe { libc::ttyname_r(slave, name.as_mut_ptr(), name.len()) };
        assert_eq!(rc, 0, "ttyname_r failed");
        // SAFETY: ttyname_r succeeded, so `name` is NUL-terminated.
        let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        // The slave stays open (leaked) so the pty outlives the driver's handle.

        // SAFETY: `master` is a fresh descriptor this function owns.
        let mut port = unsafe { std::fs::File::from_raw_fd(master) };
        std::thread::spawn(move || {
            let mut pending = String::new();
            let mut buf = [0u8; 64];
            loop {
                let n = match port.read(&mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                pending.push_str(&String::from_utf8_lossy(&buf[..n]));
                while let Some(end) = pending.find('\r') {
                    let command: String = pending.drain(..=end).collect();
                    let reply = if command.starts_with(":j") {
                        "=000080\r".to_string()
                    } else if command.starts_with(":f1") {
                        format!("={ra_status}\r")
                    } else if command.starts_with(":f2") {
                        format!("={dec_status}\r")
                    } else {
                        "=\r".to_string()
                    };
                    if port.write_all(reply.as_bytes()).is_err() {
                        return;
                    }
                }
            }
        });
        path
    }

    #[cfg(target_os = "linux")]
    async fn slewing_with_status(ra_status: &'static str, dec_status: &'static str) -> bool {
        let path = spawn_synscan_pty(ra_status, dec_status);
        let mut mount = SkyWatcherMount::new_serial(path, Some(9600));
        mount
            .connect()
            .await
            .expect("connect to the fake motor controller");
        mount.is_slewing().await.expect("slew state")
    }

    /// The `:f` status is three digits: the first is the mode (bit 0 set for
    /// tracking, clear for goto), the second the motion (bit 0 set while the
    /// motor runs), the third the controller (bit 0 set once initialized).
    /// Reading bit 0 of the whole value read "initialized" as "slewing", so an
    /// initialized mount read as slewing whether it was tracking, stopped or
    /// in a goto: every sequencer slew waited out its limit, and park never
    /// returned.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn only_a_running_goto_reads_as_slewing() {
        assert!(
            !slewing_with_status("111", "101").await,
            "a tracking mount is not slewing"
        );
        assert!(
            !slewing_with_status("001", "001").await,
            "a mount stopped at the end of a goto is not slewing"
        );
        assert!(
            slewing_with_status("011", "001").await,
            "an axis running in goto mode is a slew in progress"
        );
        assert!(
            slewing_with_status("101", "011").await,
            "either axis running in goto mode is a slew in progress"
        );
    }
}
