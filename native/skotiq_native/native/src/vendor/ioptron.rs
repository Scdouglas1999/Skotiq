//! iOptron Mount Protocol Implementation
//!
//! Implements the iOptron serial command protocol for iEQ, CEM, and GEM series mounts.
//! Protocol reference: iOptron Command Set v2.5/v3.0
//!
//! Communication: Serial 9600 or 115200 baud, terminated with #

use super::serial_link::{
    self, OnOpenFailure, Probe, ProbedPort, ReplyRule, ScanPlan, SerialLink, REPLY_DEADLINE,
};
use super::sexagesimal::{from_parts, sign_char, split_sign, split_units, to_units};
use async_trait::async_trait;
use skotiq_device::Vendor;
use skotiq_device::*;
use std::sync::Mutex;
use std::time::Duration;

const IOPTRON_BAUD_RATE: u32 = 9600;
const IOPTRON_BAUD_RATE_FAST: u32 = 115200;

/// Replies end in `#`; the mount sends nothing between them.
const IOPTRON_REPLY: ReplyRule = ReplyRule {
    terminator: b'#',
    leading_framing: &[],
    deadline: REPLY_DEADLINE,
    timeout_message: "iOptron command response timed out",
};

/// Unlike the other serial scans this one tries the second baud rate on a
/// port it could not open at the first.
const SCAN_PLAN: ScanPlan = ScanPlan {
    protocol: "iOptron",
    baud_rates: &[IOPTRON_BAUD_RATE, IOPTRON_BAUD_RATE_FAST],
    on_open_failure: OnOpenFailure::NextBaudRate,
};

/// Time the mount gets to answer a discovery probe.
const PROBE_SETTLE: Duration = Duration::from_millis(100);
const PROBE_REPLY_CAPACITY: usize = 32;

/// Positions are printed to a hundredth of a second (of time or of arc).
const HUNDREDTHS_PER_WHOLE: i64 = 360_000;

mod commands {
    pub const GET_MOUNT_VERSION: &str = ":MountInfo#";
    pub const GET_MAIN_AND_HC_FIRMWARE: &str = ":FW1#";
    pub const GET_MOTOR_BOARD_FIRMWARE: &str = ":FW2#";
    pub const GET_RA_DEC: &str = ":GEC#";
    pub const GET_ALT_AZ: &str = ":GAC#";
    pub const GET_SYSTEM_STATUS: &str = ":GAS#";
    pub const GET_SIDEREAL_TIME: &str = ":GLS#";
    pub const GET_GUIDE_RATE: &str = ":AG#";

    pub const SLEW_RA_DEC: &str = ":MS#";
    pub const SET_RA: &str = ":Sr";
    pub const SET_DEC: &str = ":Sd";
    pub const STOP_SLEW: &str = ":Q#";

    pub const SYNC: &str = ":CM#";

    pub const STOP_TRACKING: &str = ":ST0#";
    pub const START_TRACKING: &str = ":ST1#";

    // Tracking rate commands
    pub const SET_TRACKING_SIDEREAL: &str = ":RT0#";
    pub const SET_TRACKING_LUNAR: &str = ":RT1#";
    pub const SET_TRACKING_SOLAR: &str = ":RT2#";
    pub const SET_TRACKING_KING: &str = ":RT3#";

    /// Slew to the zero (home) position: counterweights down, pointing at
    /// the pole. Answers `1`.
    pub const GOTO_ZERO_POSITION: &str = ":MH#";

    pub const PARK: &str = ":MP1#";
    pub const UNPARK: &str = ":MP0#";

    pub const PULSE_GUIDE_NORTH: &str = ":Mn";
    pub const PULSE_GUIDE_SOUTH: &str = ":Ms";
    pub const PULSE_GUIDE_EAST: &str = ":Me";
    pub const PULSE_GUIDE_WEST: &str = ":Mw";
}

const MIN_GUIDE_RATE: f64 = 0.10;
const MAX_GUIDE_RATE: f64 = 1.00;
const MAX_PULSE_GUIDE_DURATION_MS: u32 = 32_767;

#[derive(Debug, Clone, Default)]
pub struct IOptronStatus {
    pub tracking: bool,
    pub slewing: bool,
    pub parked: bool,
    pub home: bool,
    pub pier_side_west: bool,
    pub gps_connected: bool,
    pub tracking_rate: u8, // 0=sidereal, 1=lunar, 2=solar, 3=king
}

fn parse_system_status(response: &str) -> Result<IOptronStatus, DriverError> {
    if response.len() < 8 {
        return Err(DriverError::SdkError(format!(
            "Invalid status response: {}",
            response
        )));
    }

    let chars: Vec<char> = response.chars().collect();

    // Parse tracking rate from character at position 2 (0-3 for sidereal/lunar/solar/king)
    // Why: the iOptron `:GLS#` reply is fixed-length
    // per the iOptron Mount Command Protocol Rev 3.10; a response that
    // truncates char[2] is a transport corruption that would have
    // already failed the length check at line 73. `0` = sidereal is the
    // documented "rate not specified" default in the iOptron spec.
    let tracking_rate = chars
        .get(2)
        .and_then(|c| c.to_digit(10))
        .map(|d| d as u8)
        .unwrap_or(0);

    Ok(IOptronStatus {
        tracking: chars.first() == Some(&'1'),
        slewing: chars.get(1) == Some(&'1'),
        parked: chars.get(5) == Some(&'1'),
        home: chars.get(4) == Some(&'1'),
        pier_side_west: chars.get(6) == Some(&'1'),
        gps_connected: chars.get(7) == Some(&'1'),
        tracking_rate,
    })
}

fn parse_guide_rate(response: &str) -> Result<f64, DriverError> {
    let rate = response
        .trim()
        .parse::<f64>()
        .map_err(|_| DriverError::SdkError(format!("Invalid guide rate response: {response}")))?;
    if !rate.is_finite() {
        return Err(DriverError::SdkError(format!(
            "Invalid non-finite guide rate response: {response}"
        )));
    }
    validate_guide_rate(rate)
}

fn validate_guide_rate(rate: f64) -> Result<f64, DriverError> {
    if !(MIN_GUIDE_RATE..=MAX_GUIDE_RATE).contains(&rate) {
        return Err(DriverError::SdkError(format!(
            "iOptron guide rate {:.2}x is outside the supported {:.2}x..{:.2}x sidereal range",
            rate, MIN_GUIDE_RATE, MAX_GUIDE_RATE
        )));
    }
    Ok(rate)
}

fn validate_pulse_guide_duration(duration_ms: u32) -> Result<(), DriverError> {
    if duration_ms == 0 {
        return Err(DriverError::InvalidParameter(
            "iOptron pulse guide duration 0ms requests continuous motion; use abort_slew to stop existing motion instead"
                .to_string(),
        ));
    }
    if duration_ms > MAX_PULSE_GUIDE_DURATION_MS {
        return Err(DriverError::InvalidParameter(format!(
            "iOptron pulse guide duration {}ms exceeds protocol maximum {}ms",
            duration_ms, MAX_PULSE_GUIDE_DURATION_MS
        )));
    }
    Ok(())
}

fn normalize_firmware_date(date: &str) -> Option<String> {
    let date = date.trim();
    if date.len() != 6 || !date.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }

    let yy: u16 = date[0..2].parse().ok()?;
    let month: u8 = date[2..4].parse().ok()?;
    let day: u8 = date[4..6].parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    Some(format!("20{:02}-{:02}-{:02}", yy, month, day))
}

fn normalize_firmware_pair(response: &str) -> Option<(String, String)> {
    let response = response.trim().trim_end_matches('#');
    if response.len() != 12 || !response.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }

    Some((
        normalize_firmware_date(&response[0..6])?,
        normalize_firmware_date(&response[6..12])?,
    ))
}

fn format_firmware_versions(fw1: Option<&str>, fw2: Option<&str>) -> Option<String> {
    let main_hc = fw1.and_then(normalize_firmware_pair);
    let motors = fw2.and_then(normalize_firmware_pair);

    match (main_hc, motors) {
        (Some((main, hc)), Some((ra, dec))) => Some(format!(
            "iOptron firmware mainboard {}, hand controller {}, RA motor {}, Dec motor {}",
            main, hc, ra, dec
        )),
        (Some((main, hc)), None) => Some(format!(
            "iOptron firmware mainboard {}, hand controller {}",
            main, hc
        )),
        (None, Some((ra, dec))) => Some(format!(
            "iOptron firmware RA motor {}, Dec motor {}",
            ra, dec
        )),
        (None, None) => None,
    }
}

fn probe(command: &str) -> Probe<'_> {
    Probe {
        command: command.as_bytes(),
        settle: PROBE_SETTLE,
        reply_capacity: PROBE_REPLY_CAPACITY,
    }
}

fn query_hash_command(port: &mut ProbedPort<'_>, command: &str) -> Option<String> {
    let response = port.ask(&probe(command))?;
    let trimmed = response.trim().trim_end_matches('#').trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn parse_ra(response: &str) -> Result<f64, DriverError> {
    if response.len() < 8 {
        return Err(DriverError::SdkError(format!(
            "Invalid RA response: {}",
            response
        )));
    }

    let hours: f64 = response[0..2]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid RA hours".into()))?;
    let minutes: f64 = response[2..4]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid RA minutes".into()))?;
    let centisecs: f64 = response[4..8]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid RA seconds".into()))?;

    Ok(from_parts(hours, minutes, centisecs / 100.0))
}

fn parse_dec(response: &str) -> Result<f64, DriverError> {
    if response.len() < 9 {
        return Err(DriverError::SdkError(format!(
            "Invalid Dec response: {}",
            response
        )));
    }

    let (sign, digits) = split_sign(response);

    let degrees: f64 = digits[0..2]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid Dec degrees".into()))?;
    let arcmin: f64 = digits[2..4]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid Dec arcmin".into()))?;
    let centiarcsec: f64 = digits[4..8]
        .parse()
        .map_err(|_| DriverError::SdkError("Invalid Dec arcsec".into()))?;

    Ok(sign * from_parts(degrees, arcmin, centiarcsec / 100.0))
}

fn format_ra(ra_hours: f64) -> String {
    let total = to_units(ra_hours, HUNDREDTHS_PER_WHOLE).rem_euclid(24 * HUNDREDTHS_PER_WHOLE);
    let (hours, minutes, centisecs) = split_units(total, HUNDREDTHS_PER_WHOLE);

    format!("{:02}{:02}{:04}", hours, minutes, centisecs)
}

fn format_dec(dec_degrees: f64) -> String {
    let total = to_units(dec_degrees.abs(), HUNDREDTHS_PER_WHOLE);
    let (degrees, arcmin, centiarcsec) = split_units(total, HUNDREDTHS_PER_WHOLE);

    format!(
        "{}{:02}{:02}{:04}",
        sign_char(dec_degrees),
        degrees,
        arcmin,
        centiarcsec
    )
}

pub struct IOptronMount {
    device_id: String,
    name: String,
    port_name: String,
    baud_rate: u32,
    link: SerialLink,
    connected: Mutex<bool>,
    status: Mutex<IOptronStatus>,
    mount_model: Mutex<String>,
}

impl std::fmt::Debug for IOptronMount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IOptronMount")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

impl IOptronMount {
    pub fn new(port: String, baud_rate: Option<u32>) -> Self {
        let device_id = format!("native:ioptron:{}", serial_link::sanitize_port_name(&port));
        Self {
            device_id,
            name: format!("iOptron ({})", port),
            port_name: port,
            baud_rate: baud_rate.unwrap_or(IOPTRON_BAUD_RATE),
            link: SerialLink::new(),
            connected: Mutex::new(false),
            status: Mutex::new(IOptronStatus::default()),
            mount_model: Mutex::new(String::new()),
        }
    }

    fn send_command(&self, command: &str) -> Result<String, DriverError> {
        self.link.command(command.as_bytes(), &IOPTRON_REPLY)
    }

    fn send_command_no_response(&self, command: &str) -> Result<(), DriverError> {
        self.link.command_no_reply(command.as_bytes())
    }

    fn open(&self, baud_rate: u32) -> Result<(), DriverError> {
        let serial = serial_link::open_port(&self.port_name, baud_rate)
            .map_err(|e| DriverError::SdkError(format!("Failed to open serial port: {}", e)))?;
        self.link.attach(serial)
    }

    fn update_status(&self) -> Result<(), DriverError> {
        let response = self.send_command(commands::GET_SYSTEM_STATUS)?;
        let new_status = parse_system_status(&response)?;
        *self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = new_status;
        Ok(())
    }

    fn guide_rate(&self) -> Result<f64, DriverError> {
        let response = self.send_command(commands::GET_GUIDE_RATE)?;
        parse_guide_rate(&response)
    }

    fn validate_pulse_guide_inputs(&self, duration_ms: u32) -> Result<f64, DriverError> {
        validate_pulse_guide_duration(duration_ms)?;
        self.guide_rate()
    }
}

#[async_trait]
impl DeviceDriver for IOptronMount {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::IOptron
    }

    fn is_connected(&self) -> bool {
        *self.connected.lock().unwrap_or_else(|e| e.into_inner())
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }

        let _serial_access = serial_link::serial_mount_access().await;

        self.open(self.baud_rate)?;

        match self.send_command(commands::GET_MOUNT_VERSION) {
            Ok(response) => {
                *self
                    .mount_model
                    .lock()
                    .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = response.clone();
                self.name = format!("iOptron {} ({})", response, self.port_name);
            }
            Err(_) => {
                // The mount did not answer at the configured rate. Close the
                // port and ask once more at the fast rate.
                self.link.detach()?;
                self.open(IOPTRON_BAUD_RATE_FAST)?;
                self.baud_rate = IOPTRON_BAUD_RATE_FAST;

                match self.send_command(commands::GET_MOUNT_VERSION) {
                    Ok(response) => {
                        *self
                            .mount_model
                            .lock()
                            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? =
                            response.clone();
                        self.name = format!("iOptron {} ({})", response, self.port_name);
                    }
                    Err(e) => {
                        self.link.detach()?;
                        return Err(e);
                    }
                }
            }
        }

        let _ = self.update_status();

        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;
        tracing::info!("Connected to iOptron mount");

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Ok(());
        }

        // Halt any motion before the port is dropped. The port is released either way,
        // but a mount that did not take the halt keeps slewing with nothing connected to
        // stop it, so the failure is reported rather than dropped (same rule as the LX200
        // driver's disconnect).
        if let Err(e) = self.send_command_no_response(commands::STOP_SLEW) {
            tracing::error!(
                "iOptron {}: stop-slew ({}) failed while disconnecting: {}. The mount may still be moving — stop it at the hand controller.",
                self.device_id,
                commands::STOP_SLEW,
                e
            );
        }

        self.link.detach()?;
        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        tracing::info!("Disconnected from iOptron mount");

        Ok(())
    }
}

#[async_trait]
impl MountDriver for IOptronMount {
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Slewing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        let ra_cmd = format!("{}{}#", commands::SET_RA, format_ra(ra_hours));
        let response = self.send_command(&ra_cmd)?;
        if response != "1" {
            return Err(DriverError::SdkError("Failed to set RA target".into()));
        }

        let dec_cmd = format!("{}{}#", commands::SET_DEC, format_dec(dec_degrees));
        let response = self.send_command(&dec_cmd)?;
        if response != "1" {
            return Err(DriverError::SdkError("Failed to set Dec target".into()));
        }

        let response = self.send_command(commands::SLEW_RA_DEC)?;
        if response != "1" {
            return Err(DriverError::SdkError(format!("Slew failed: {}", response)));
        }

        Ok(())
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let response = self.send_command(commands::GET_RA_DEC)?;

        if response.len() < 16 {
            return Err(DriverError::SdkError(format!(
                "Invalid coordinate response: {}",
                response
            )));
        }

        let ra = parse_ra(&response[0..8])?;
        let dec = parse_dec(&response[8..17])?;

        Ok((ra, dec))
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

        let ra_cmd = format!("{}{}#", commands::SET_RA, format_ra(ra_hours));
        self.send_command(&ra_cmd)?;

        let dec_cmd = format!("{}{}#", commands::SET_DEC, format_dec(dec_degrees));
        self.send_command(&dec_cmd)?;

        self.send_command(commands::SYNC)?;

        Ok(())
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Parking mount");
        self.send_command(commands::PARK)?;

        Ok(())
    }

    async fn find_home(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // iOptron's home is its zero position. The mount reports the motion
        // through the slewing flag of `:GAS#` like any goto, so callers that
        // poll `is_slewing` wait for it to arrive.
        tracing::info!("Sending mount to its zero (home) position");
        let response = self.send_command(commands::GOTO_ZERO_POSITION)?;
        if response != "1" {
            return Err(DriverError::SdkError(format!(
                "Mount refused the zero-position slew: {}",
                response
            )));
        }

        Ok(())
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Unparking mount");
        self.send_command(commands::UNPARK)?;

        Ok(())
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        self.update_status()?;
        let status = self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;

        Ok(status.slewing)
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        self.update_status()?;
        let status = self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;

        Ok(status.parked)
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let guide_rate = self.validate_pulse_guide_inputs(duration_ms)?;
        let cmd = match direction {
            GuideDirection::North => format!("{}{}#", commands::PULSE_GUIDE_NORTH, duration_ms),
            GuideDirection::South => format!("{}{}#", commands::PULSE_GUIDE_SOUTH, duration_ms),
            GuideDirection::East => format!("{}{}#", commands::PULSE_GUIDE_EAST, duration_ms),
            GuideDirection::West => format!("{}{}#", commands::PULSE_GUIDE_WEST, duration_ms),
        };

        tracing::debug!(
            "iOptron pulse guide {:?} for {}ms at {:.2}x sidereal guide rate",
            direction,
            duration_ms,
            guide_rate
        );
        self.send_command_no_response(&cmd)?;

        Ok(())
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Aborting slew");
        self.send_command_no_response(commands::STOP_SLEW)?;

        Ok(())
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let cmd = if enabled {
            commands::START_TRACKING
        } else {
            commands::STOP_TRACKING
        };

        self.send_command(cmd)?;

        tracing::info!("Tracking {}", if enabled { "enabled" } else { "disabled" });

        Ok(())
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        self.update_status()?;
        let status = self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;

        Ok(status.tracking)
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        self.update_status()?;
        let status = self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;

        Ok(if status.pier_side_west {
            PierSide::West
        } else {
            PierSide::East
        })
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let response = self.send_command(commands::GET_ALT_AZ)?;

        if response.len() < 17 {
            return Err(DriverError::SdkError("Invalid alt/az response".into()));
        }

        let alt = parse_dec(&response[0..9])?;
        let az_deg: f64 = response[9..12]
            .parse()
            .map_err(|_| DriverError::SdkError("Invalid azimuth".into()))?;
        let az_min: f64 = response[12..14]
            .parse()
            .map_err(|_| DriverError::SdkError("Invalid azimuth".into()))?;
        let az_sec: f64 = response[14..18]
            .parse()
            .map_err(|_| DriverError::SdkError("Invalid azimuth".into()))?;

        let az = from_parts(az_deg, az_min, az_sec / 100.0);

        Ok((alt, az))
    }

    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let response = self.send_command(commands::GET_SIDEREAL_TIME)?;
        parse_ra(&response)
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let cmd = match rate {
            TrackingRate::Sidereal => commands::SET_TRACKING_SIDEREAL,
            TrackingRate::Lunar => commands::SET_TRACKING_LUNAR,
            TrackingRate::Solar => commands::SET_TRACKING_SOLAR,
            TrackingRate::King => commands::SET_TRACKING_KING,
            TrackingRate::Custom => {
                return Err(DriverError::NotSupported);
            }
        };

        self.send_command(cmd)?;
        tracing::info!("Set tracking rate to {:?}", rate);

        Ok(())
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        self.update_status()?;
        let status = self
            .status
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;

        match status.tracking_rate {
            0 => Ok(TrackingRate::Sidereal),
            1 => Ok(TrackingRate::Lunar),
            2 => Ok(TrackingRate::Solar),
            3 => Ok(TrackingRate::King),
            value => Err(DriverError::SdkError(format!(
                "Unknown iOptron tracking rate value: {}",
                value
            ))),
        }
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
        true
    }

    fn can_find_home(&self) -> bool {
        true
    }
}

pub struct IOptronMountInfo {
    pub port: String,
    pub name: String,
    pub model: String,
    pub firmware_version: Option<String>,
    /// Baud rate that was successful during discovery
    pub baud_rate: u32,
}

pub async fn discover_mounts() -> Result<Vec<IOptronMountInfo>, DriverError> {
    serial_link::run_serial_scan("iOptron", scan_serial_ports).await
}

fn scan_serial_ports() -> Result<Vec<IOptronMountInfo>, DriverError> {
    serial_link::scan_ports(&SCAN_PLAN, identify_mount)
}

/// The same scan over ports a test supplies.
#[cfg(all(test, target_os = "linux"))]
pub(crate) fn scan_port_list(ports: Vec<serialport::SerialPortInfo>) -> Vec<IOptronMountInfo> {
    serial_link::scan_port_list(&SCAN_PLAN, ports, identify_mount)
}

/// An iOptron mount answers the model query with its series name.
fn identify_mount(port: &mut ProbedPort<'_>) -> Option<IOptronMountInfo> {
    let response = port.ask(&probe(commands::GET_MOUNT_VERSION))?;
    tracing::debug!(
        "iOptron response from {} at {} baud: {:?}",
        port.name,
        port.baud_rate,
        response
    );
    if !(response.contains("iEQ")
        || response.contains("CEM")
        || response.contains("GEM")
        || response.contains("AZ"))
    {
        return None;
    }

    let model = response.trim_end_matches('#').to_string();
    let display_name = format!("iOptron {} ({})", model, port.name);
    let fw1 = query_hash_command(port, commands::GET_MAIN_AND_HC_FIRMWARE);
    let fw2 = query_hash_command(port, commands::GET_MOTOR_BOARD_FIRMWARE);
    let firmware_version = format_firmware_versions(fw1.as_deref(), fw2.as_deref());
    tracing::info!(
        "Found iOptron mount on {} at {} baud: {}",
        port.name,
        port.baud_rate,
        display_name
    );
    Some(IOptronMountInfo {
        port: port.name.to_string(),
        name: display_name,
        model,
        firmware_version,
        baud_rate: port.baud_rate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// iOptron's home is the zero position (`:MH#`). The driver must
    /// implement it rather than inherit the trait's `NotSupported`, and the
    /// capability flag must say so.
    #[tokio::test]
    async fn find_home_is_implemented_and_advertised() {
        let mut mount = IOptronMount::new("TEST_PORT".to_string(), None);
        assert!(mount.can_find_home());
        assert!(
            matches!(mount.find_home().await, Err(DriverError::NotConnected)),
            "find_home should reach the connection check, not the trait default"
        );
        assert_eq!(commands::GOTO_ZERO_POSITION, ":MH#");
    }

    #[test]
    fn goto_targets_never_emit_sixty_seconds() {
        // 0.004 s short of 01:00:00; splitting first and rounding the
        // hundredths printed 00:59:60.00, which the mount refuses.
        assert_eq!(format_ra(1.0 - 0.004 / 3600.0), "01000000");
        assert_eq!(format_ra(24.0 - 0.004 / 3600.0), "00000000");
        assert_eq!(format_dec(10.0 - 0.004 / 3600.0), "+10000000");
        assert_eq!(format_dec(-(10.0 - 0.004 / 3600.0)), "-10000000");
        assert_eq!(format_ra(5.5), "05300000");
        assert_eq!(format_dec(-33.869722), "-33521100");
    }

    #[test]
    fn parse_guide_rate_accepts_documented_range() {
        assert_eq!(parse_guide_rate("0.10").unwrap(), 0.10);
        assert_eq!(parse_guide_rate("0.50").unwrap(), 0.50);
        assert_eq!(parse_guide_rate("1.00").unwrap(), 1.00);
    }

    #[test]
    fn parse_guide_rate_rejects_invalid_or_out_of_range_values() {
        assert!(parse_guide_rate("0.00").is_err());
        assert!(parse_guide_rate("1.25").is_err());
        assert!(parse_guide_rate("NaN").is_err());
        assert!(parse_guide_rate("not-a-rate").is_err());
    }

    #[test]
    fn validate_pulse_guide_duration_rejects_continuous_or_oversized_pulses() {
        validate_pulse_guide_duration(1).expect("minimum pulse");
        validate_pulse_guide_duration(MAX_PULSE_GUIDE_DURATION_MS).expect("maximum pulse");
        assert!(validate_pulse_guide_duration(0).is_err());
        assert!(validate_pulse_guide_duration(MAX_PULSE_GUIDE_DURATION_MS + 1).is_err());
    }

    #[test]
    fn normalize_ioptron_firmware_pair_formats_dates() {
        assert_eq!(
            normalize_firmware_pair("260525240101#"),
            Some(("2026-05-25".to_string(), "2024-01-01".to_string()))
        );
    }

    #[test]
    fn normalize_ioptron_firmware_pair_rejects_invalid_dates() {
        assert_eq!(normalize_firmware_pair("260025240101"), None);
        assert_eq!(normalize_firmware_pair("260525bad101"), None);
    }

    #[test]
    fn format_ioptron_firmware_versions_combines_main_and_motor_boards() {
        assert_eq!(
            format_firmware_versions(Some("260525240101"), Some("230201230202")).as_deref(),
            Some(
                "iOptron firmware mainboard 2026-05-25, hand controller 2024-01-01, RA motor 2023-02-01, Dec motor 2023-02-02"
            )
        );
    }
}
