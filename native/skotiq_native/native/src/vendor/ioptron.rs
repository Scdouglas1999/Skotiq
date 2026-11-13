//! iOptron mounts over iOptron's RS-232 command language.
//!
//! Two dialects are in the field, and a mount shows which one it speaks by the
//! length of its `:GLS#` status reply:
//! - v2.5 ("iOptron Mount RS-232 Command Language 2014", Version 2.5,
//!   2019-01-15): CEM60, iEQ45 Pro, iEQ30 Pro, CEM25, SmartEQ Pro+, AZ Mount
//!   Pro, Cube II, and CEM40 / GEM45 before firmware 210101. Right ascension
//!   in milliseconds of time, the site in whole arc seconds, the clock as a
//!   local date and time.
//! - v3 (Version 3.10, 2021-01-04): CEM120, CEM70, GEM45 and CEM40 from
//!   firmware 210101, GEM28, CEM26 and the HAE, HEM and HAZ lines. Every angle
//!   in hundredths of an arc second, the clock as UTC milliseconds since J2000.
//!
//! Replies take the same shapes in both: a query answers up to `#`, a setting
//! or motion command answers one digit and no `#`, `:MountInfo#` answers four
//! digits and no `#`, and a pulse-guide command answers nothing. Both documents
//! are published at ioptron.com/v/ASCOM/.
//!
//! The mount works in coordinates of date; the bridge converts from J2000.

use super::serial_link::{
    self, Exchange, OnOpenFailure, Probe, ProbedPort, ReplyRule, ScanPlan, SerialLink,
    REPLY_DEADLINE,
};
use super::sexagesimal::sign_char;
use async_trait::async_trait;
use skotiq_device::Vendor;
use skotiq_device::*;
use std::sync::Mutex;
use std::time::Duration;

/// v2.5 mounts other than the CEM40.
const IOPTRON_BAUD_RATE: u32 = 9600;
/// v3 mounts and the CEM40.
const IOPTRON_BAUD_RATE_FAST: u32 = 115200;

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

/// Time the mount gets to answer a discovery probe. The longest probed reply,
/// the 24-byte v3 status, takes 25 ms at 9600 baud.
const PROBE_SETTLE: Duration = Duration::from_millis(100);
const PROBE_REPLY_CAPACITY: usize = 32;

const MODEL_CODE_LENGTH: usize = 4;

/// Hundredths of an arc second in a degree: the unit of every v3 angle and of
/// v2.5 declination, altitude and azimuth.
const CENTI_ARCSEC_PER_DEGREE: f64 = 360_000.0;
/// The v2.5 site unit.
const ARCSEC_PER_DEGREE: f64 = 3_600.0;
/// The v2.5 right ascension unit.
const MS_PER_HOUR: f64 = 3_600_000.0;

/// 2000-01-01 12:00:00 UTC, the J2000 instant the v3 clock counts from.
const J2000_UNIX_SECONDS: i64 = 946_728_000;

/// The pulse-guide duration field is five digits.
const MAX_PULSE_GUIDE_DURATION_MS: u32 = 99_999;

/// The UTC offset range `:SG` takes, in minutes.
const UTC_OFFSET_MINUTES: std::ops::RangeInclusive<i64> = -720..=780;

mod commands {
    pub const GET_MODEL: &str = ":MountInfo#";
    pub const GET_MAIN_AND_HC_FIRMWARE: &str = ":FW1#";
    pub const GET_MOTOR_BOARD_FIRMWARE: &str = ":FW2#";
    /// Site, system state, tracking rate, time source and hemisphere.
    pub const GET_STATUS: &str = ":GLS#";
    pub const GET_ALT_AZ: &str = ":GAC#";

    pub const SET_DEC: &str = ":Sd";
    pub const SYNC: &str = ":CM#";
    /// Stops a slew from any source; tracking carries on.
    pub const STOP_SLEW: &str = ":Q#";

    pub const STOP_TRACKING: &str = ":ST0#";
    pub const START_TRACKING: &str = ":ST1#";

    pub const SET_TRACKING_SIDEREAL: &str = ":RT0#";
    pub const SET_TRACKING_LUNAR: &str = ":RT1#";
    pub const SET_TRACKING_SOLAR: &str = ":RT2#";
    pub const SET_TRACKING_KING: &str = ":RT3#";

    /// Slew to the zero (home) position: counterweights down, pointing at
    /// the pole.
    pub const GOTO_ZERO_POSITION: &str = ":MH#";

    pub const PARK: &str = ":MP1#";
    pub const UNPARK: &str = ":MP0#";
    pub const SET_PARK_AZIMUTH: &str = ":SPA";
    pub const SET_PARK_ALTITUDE: &str = ":SPH";

    pub const SET_UTC_OFFSET: &str = ":SG";
    /// The offset written with `:SG` already carries daylight saving time.
    pub const DAYLIGHT_SAVING_OFF: &str = ":SDS0#";

    pub const SET_SOUTHERN_HEMISPHERE: &str = ":SHE0#";
    pub const SET_NORTHERN_HEMISPHERE: &str = ":SHE1#";
}

/// The command language a mount speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Dialect {
    V25,
    V3,
}

impl Dialect {
    /// The dialect whose `:GLS#` reply, without its `#`, is this long.
    fn from_status_length(length: usize) -> Option<Self> {
        [Dialect::V25, Dialect::V3]
            .into_iter()
            .find(|dialect| dialect.status_length() == length)
    }

    fn status_length(self) -> usize {
        1 + 2 * self.site_digits() + 6
    }

    /// Digits of each site field in `:GLS#` and the site setters.
    fn site_digits(self) -> usize {
        match self {
            Dialect::V25 => 6,
            Dialect::V3 => 8,
        }
    }

    fn site_units_per_degree(self) -> f64 {
        match self {
            Dialect::V25 => ARCSEC_PER_DEGREE,
            Dialect::V3 => CENTI_ARCSEC_PER_DEGREE,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Dialect::V25 => "v2.5",
            Dialect::V3 => "v3",
        }
    }

    fn get_coordinates(self) -> &'static str {
        match self {
            Dialect::V25 => ":GEC#",
            Dialect::V3 => ":GEP#",
        }
    }

    fn get_clock(self) -> &'static str {
        match self {
            Dialect::V25 => ":GLT#",
            Dialect::V3 => ":GUT#",
        }
    }

    /// Slew to the target last set. v3 also offers `:MS2#`, the
    /// counterweight-up solution, which nothing here asks for.
    fn slew(self) -> &'static str {
        match self {
            Dialect::V25 => ":MS#",
            Dialect::V3 => ":MS1#",
        }
    }

    fn set_target_ra(self, ra_hours: f64) -> String {
        let ra_hours = ra_hours.rem_euclid(24.0);
        match self {
            Dialect::V25 => {
                let ms = (ra_hours * MS_PER_HOUR).round() as i64 % (24 * 3_600_000);
                format!(":Sr{ms:08}#")
            }
            Dialect::V3 => {
                let units =
                    (ra_hours * 15.0 * CENTI_ARCSEC_PER_DEGREE).round() as i64 % (360 * 360_000);
                format!(":SRA{units:09}#")
            }
        }
    }

    fn pulse_guide(self, direction: GuideDirection, duration_ms: u32) -> String {
        let letter = match (self, direction) {
            (Dialect::V25, GuideDirection::North) => 'n',
            (Dialect::V25, GuideDirection::South) => 's',
            (Dialect::V25, GuideDirection::East) => 'e',
            (Dialect::V25, GuideDirection::West) => 'w',
            // v3.10 names the `:Z` commands by axis: E is Dec+, C Dec-, S RA+,
            // Q RA-. They supersede the deprecated `:Mn` family.
            (Dialect::V3, GuideDirection::North) => 'E',
            (Dialect::V3, GuideDirection::South) => 'C',
            (Dialect::V3, GuideDirection::East) => 'S',
            (Dialect::V3, GuideDirection::West) => 'Q',
        };
        let prefix = match self {
            Dialect::V25 => 'M',
            Dialect::V3 => 'Z',
        };
        format!(":{prefix}{letter}{duration_ms:05}#")
    }

    fn set_site(self, site: &MountSiteInfo) -> [String; 2] {
        let width = self.site_digits();
        let units = |degrees: f64| (degrees.abs() * self.site_units_per_degree()).round() as i64;
        let (longitude, latitude) = match self {
            Dialect::V25 => (":Sg", ":St"),
            Dialect::V3 => (":SLO", ":SLA"),
        };
        [
            format!(
                "{longitude}{}{:0width$}#",
                sign_char(site.longitude_deg),
                units(site.longitude_deg)
            ),
            format!(
                "{latitude}{}{:0width$}#",
                sign_char(site.latitude_deg),
                units(site.latitude_deg)
            ),
        ]
    }
}

/// What the mount is doing, the second status digit of `:GLS#`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SystemStatus {
    StoppedAwayFromZero,
    Tracking,
    Slewing,
    Guiding,
    MeridianFlipping,
    TrackingWithPec,
    Parked,
    StoppedAtZero,
}

impl SystemStatus {
    fn from_digit(digit: u8) -> Option<Self> {
        Some(match digit {
            b'0' => Self::StoppedAwayFromZero,
            b'1' => Self::Tracking,
            b'2' => Self::Slewing,
            b'3' => Self::Guiding,
            b'4' => Self::MeridianFlipping,
            b'5' => Self::TrackingWithPec,
            b'6' => Self::Parked,
            b'7' => Self::StoppedAtZero,
            _ => return None,
        })
    }

    fn tracking(self) -> bool {
        matches!(self, Self::Tracking | Self::Guiding | Self::TrackingWithPec)
    }

    fn slewing(self) -> bool {
        matches!(self, Self::Slewing | Self::MeridianFlipping)
    }
}

/// One `:GLS#` reply.
#[derive(Debug, Clone, PartialEq)]
struct Status {
    longitude_deg: f64,
    latitude_deg: f64,
    system: SystemStatus,
    tracking_rate: TrackingRate,
    gps: u8,
    time_source: u8,
    northern_hemisphere: bool,
}

impl Status {
    fn describe_sources(&self) -> String {
        let gps = match self.gps {
            b'0' => "no GPS",
            b'1' => "GPS without a fix",
            _ => "GPS fix",
        };
        let time = match self.time_source {
            b'1' => "time set over the serial or network port",
            b'2' => "time set at the hand controller",
            _ => "time from GPS",
        };
        let hemisphere = if self.northern_hemisphere {
            "northern"
        } else {
            "southern"
        };
        format!("{gps}, {time}, {hemisphere} hemisphere")
    }
}

/// Where the mount points, from `:GEC#` or `:GEP#`.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Pointing {
    ra_hours: f64,
    dec_deg: f64,
    /// Only v3 reports it.
    pier_side: PierSide,
}

fn malformed(what: &str, reply: &str) -> DriverError {
    DriverError::SdkError(format!(
        "iOptron {what} reply {reply:?} is not in the form the command language documents"
    ))
}

fn digits(field: &[u8]) -> Option<i64> {
    if field.is_empty() || !field.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(
        field
            .iter()
            .fold(0i64, |value, digit| value * 10 + i64::from(digit - b'0')),
    )
}

fn signed_digits(field: &[u8]) -> Option<i64> {
    let (sign, magnitude) = field.split_first()?;
    let magnitude = digits(magnitude)?;
    match sign {
        b'+' => Some(magnitude),
        b'-' => Some(-magnitude),
        _ => None,
    }
}

fn parse_status(dialect: Dialect, reply: &str) -> Result<Status, DriverError> {
    let bad = || malformed("status (:GLS#)", reply);
    let bytes = reply.as_bytes();
    if bytes.len() != dialect.status_length() {
        return Err(bad());
    }
    let width = dialect.site_digits();
    let units = dialect.site_units_per_degree();
    let longitude = signed_digits(&bytes[..=width]).ok_or_else(bad)?;
    let latitude_plus_90 = digits(&bytes[1 + width..1 + 2 * width]).ok_or_else(bad)?;
    let flags = &bytes[1 + 2 * width..];
    if !flags.iter().all(u8::is_ascii_digit) {
        return Err(bad());
    }
    let tracking_rate = match flags[2] {
        b'0' => TrackingRate::Sidereal,
        b'1' => TrackingRate::Lunar,
        b'2' => TrackingRate::Solar,
        b'3' => TrackingRate::King,
        b'4' => TrackingRate::Custom,
        _ => return Err(bad()),
    };
    Ok(Status {
        longitude_deg: longitude as f64 / units,
        latitude_deg: latitude_plus_90 as f64 / units - 90.0,
        system: SystemStatus::from_digit(flags[1]).ok_or_else(bad)?,
        tracking_rate,
        gps: flags[0],
        time_source: flags[4],
        northern_hemisphere: flags[5] == b'1',
    })
}

fn parse_pointing(dialect: Dialect, reply: &str) -> Result<Pointing, DriverError> {
    let bad = || malformed(&format!("position ({})", dialect.get_coordinates()), reply);
    let bytes = reply.as_bytes();
    let expected = match dialect {
        Dialect::V25 => 17,
        Dialect::V3 => 20,
    };
    if bytes.len() != expected {
        return Err(bad());
    }
    let dec_deg = signed_digits(&bytes[..9]).ok_or_else(bad)? as f64 / CENTI_ARCSEC_PER_DEGREE;
    let (ra_hours, pier_side) = match dialect {
        Dialect::V25 => (
            digits(&bytes[9..17]).ok_or_else(bad)? as f64 / MS_PER_HOUR,
            PierSide::Unknown,
        ),
        Dialect::V3 => {
            let ra_deg = digits(&bytes[9..18]).ok_or_else(bad)? as f64 / CENTI_ARCSEC_PER_DEGREE;
            let pier_side = match bytes[18] {
                b'0' => PierSide::East,
                b'1' => PierSide::West,
                _ => PierSide::Unknown,
            };
            (ra_deg / 15.0, pier_side)
        }
    };
    if dec_deg.abs() > 90.0 || !(0.0..=24.0).contains(&ra_hours) {
        return Err(bad());
    }
    Ok(Pointing {
        ra_hours: ra_hours % 24.0,
        dec_deg,
        pier_side,
    })
}

/// `:GAC#`, the same in both dialects: altitude then azimuth, in degrees.
fn parse_alt_az(reply: &str) -> Result<(f64, f64), DriverError> {
    let bad = || malformed("altitude and azimuth (:GAC#)", reply);
    let bytes = reply.as_bytes();
    if bytes.len() != 18 {
        return Err(bad());
    }
    let altitude = signed_digits(&bytes[..9]).ok_or_else(bad)? as f64 / CENTI_ARCSEC_PER_DEGREE;
    let azimuth = digits(&bytes[9..]).ok_or_else(bad)? as f64 / CENTI_ARCSEC_PER_DEGREE;
    if altitude.abs() > 90.0 || azimuth > 360.0 {
        return Err(bad());
    }
    Ok((altitude, azimuth % 360.0))
}

fn format_dec(dec_degrees: f64) -> Result<String, DriverError> {
    if !(-90.0..=90.0).contains(&dec_degrees) {
        return Err(DriverError::InvalidParameter(format!(
            "declination {dec_degrees} is outside -90..90"
        )));
    }
    let units = (dec_degrees.abs() * CENTI_ARCSEC_PER_DEGREE).round() as i64;
    Ok(format!(
        "{}{}{:08}#",
        commands::SET_DEC,
        sign_char(dec_degrees),
        units
    ))
}

/// `:GUT#` (v3) or `:GLT#` (v2.5). Both begin with the UTC offset in minutes
/// and a daylight-saving digit; the offset excludes daylight saving time.
fn parse_clock(dialect: Dialect, reply: &str) -> Result<MountClock, DriverError> {
    let bad = || malformed(&format!("clock ({})", dialect.get_clock()), reply);
    let bytes = reply.as_bytes();
    let expected = match dialect {
        Dialect::V25 => 17,
        Dialect::V3 => 18,
    };
    if bytes.len() != expected {
        return Err(bad());
    }
    let standard_offset = signed_digits(&bytes[..4]).ok_or_else(bad)?;
    let daylight_saving = match bytes[4] {
        b'0' => 0,
        b'1' => 60,
        _ => return Err(bad()),
    };
    let offset_minutes = standard_offset + daylight_saving;
    let utc_unix_seconds = match dialect {
        Dialect::V3 => {
            let ms_since_j2000 = digits(&bytes[5..]).ok_or_else(bad)?;
            J2000_UNIX_SECONDS + (ms_since_j2000 + 500).div_euclid(1000)
        }
        Dialect::V25 => {
            let field = |at: usize| digits(&bytes[at..at + 2]).ok_or_else(bad);
            let local = chrono::NaiveDate::from_ymd_opt(
                2000 + field(5)? as i32,
                field(7)? as u32,
                field(9)? as u32,
            )
            .and_then(|date| {
                date.and_hms_opt(
                    field(11).ok()? as u32,
                    field(13).ok()? as u32,
                    field(15).ok()? as u32,
                )
            })
            .ok_or_else(bad)?;
            local.and_utc().timestamp() - offset_minutes * 60
        }
    };
    Ok(MountClock {
        utc_unix_seconds,
        utc_offset_hours: offset_minutes as f64 / 60.0,
    })
}

/// The commands that set the clock, in the order to send them: the offset
/// first, so a local time is read against the offset it was computed with.
fn clock_commands(dialect: Dialect, clock: &MountClock) -> Result<Vec<String>, DriverError> {
    let offset_minutes = (clock.utc_offset_hours * 60.0).round() as i64;
    if !UTC_OFFSET_MINUTES.contains(&offset_minutes) {
        return Err(DriverError::InvalidParameter(format!(
            "UTC offset {} h is outside the -12..+13 h the mount takes",
            clock.utc_offset_hours
        )));
    }
    let mut sent = vec![
        format!(
            "{}{}{:03}#",
            commands::SET_UTC_OFFSET,
            if offset_minutes < 0 { '-' } else { '+' },
            offset_minutes.abs()
        ),
        commands::DAYLIGHT_SAVING_OFF.to_string(),
    ];
    match dialect {
        Dialect::V3 => {
            let ms_since_j2000 = (clock.utc_unix_seconds - J2000_UNIX_SECONDS) * 1000;
            if ms_since_j2000 < 0 {
                return Err(DriverError::InvalidParameter(format!(
                    "time {} is before 2000, which the mount cannot hold",
                    clock.utc_unix_seconds
                )));
            }
            sent.push(format!(":SUT{ms_since_j2000:013}#"));
        }
        Dialect::V25 => {
            use chrono::{Datelike, Timelike};
            let local =
                chrono::DateTime::from_timestamp(clock.utc_unix_seconds + offset_minutes * 60, 0)
                    .filter(|local| (2000..2100).contains(&local.year()))
                    .ok_or_else(|| {
                        DriverError::InvalidParameter(format!(
                            "time {} is outside 2000-2099, which the mount cannot hold",
                            clock.utc_unix_seconds
                        ))
                    })?;
            sent.push(format!(
                ":SC{:02}{:02}{:02}#",
                local.year() - 2000,
                local.month(),
                local.day()
            ));
            sent.push(format!(
                ":SL{:02}{:02}{:02}#",
                local.hour(),
                local.minute(),
                local.second()
            ));
        }
    }
    Ok(sent)
}

/// Model names by `:MountInfo#` code, from the two command language
/// documents and INDI's iOptron drivers. iOptron reused codes when it moved to
/// v3 (0025 was the CEM25 and is the HEM27), so each dialect has its own table.
const V25_MODELS: &[(&str, &str)] = &[
    ("0010", "Cube II EQ"),
    ("0011", "SmartEQ Pro+"),
    ("0025", "CEM25"),
    ("0026", "CEM25-EC"),
    ("0030", "iEQ30 Pro"),
    ("0040", "CEM40"),
    ("0041", "CEM40-EC"),
    ("0043", "GEM45"),
    ("0044", "GEM45-EC"),
    ("0045", "iEQ45 Pro EQ"),
    ("0046", "iEQ45 Pro AA"),
    ("0060", "CEM60"),
    ("0061", "CEM60-EC"),
    ("5010", "Cube II AA"),
    ("5035", "AZ Mount Pro"),
    ("5045", "iEQ45 Pro AA"),
];

const V3_MODELS: &[(&str, &str)] = &[
    ("0010", "SkyHunter EQ"),
    ("0011", "SkyHunter AA"),
    ("0012", "HAE16 EQ"),
    ("0013", "HAE16 AA"),
    ("0014", "HAE18 EQ"),
    ("0015", "HEM15"),
    ("0022", "HAE18 AA"),
    ("0025", "HEM27"),
    ("0026", "CEM26"),
    ("0027", "CEM26-EC"),
    ("0028", "GEM28"),
    ("0029", "GEM28-EC"),
    ("0030", "HEM27-EC"),
    ("0031", "HAE29 EQ"),
    // INDI names it "HAE29-EC AA"; iOptron's special-mode document gives
    // 0033 and 0034 as the HAE29 in alt-az mode.
    ("0032", "HAE29-EC EQ"),
    ("0033", "HAE29 AA"),
    ("0034", "HAE29-EC AA"),
    ("0035", "HAZ31"),
    ("0036", "HAE29C EQ"),
    ("0037", "HAE29C-EC EQ"),
    ("0038", "HAE29C AA"),
    // INDI repeats 0037's "HAE29C-EC EQ" here. Every other dual-mode block
    // runs EQ, EC EQ, AA, EC AA, and an alt-az mount must not be pulse guided.
    ("0039", "HAE29C-EC AA"),
    ("0040", "CEM40"),
    ("0041", "CEM40-EC"),
    ("0043", "GEM45"),
    ("0044", "GEM45-EC"),
    ("0045", "HEM44-EC"),
    ("0046", "HEM44A"),
    ("0047", "HEM44A-EC"),
    ("0048", "HAE43 EQ"),
    ("0049", "HAE43-EC EQ"),
    ("0050", "HAE43 AA"),
    ("0051", "HAE43-EC AA"),
    ("0052", "HAZ46"),
    ("0053", "HAE43C EQ"),
    ("0054", "HAE43C-EC EQ"),
    ("0055", "HAE43C AA"),
    ("0056", "HAE43C-EC AA"),
    ("0060", "CEM60"),
    ("0061", "CEM60-EC"),
    ("0062", "HAE69 EQ"),
    ("0063", "HAE69-EC EQ"),
    ("0064", "HAE69 AA"),
    ("0065", "HAE69-EC AA"),
    ("0066", "HAE69C EQ"),
    ("0067", "HAE69C-EC EQ"),
    ("0068", "HAE69C AA"),
    ("0069", "HAE69C-EC AA"),
    ("0070", "CEM70"),
    ("0071", "CEM70-EC"),
    ("0072", "CEM70-EC2"),
    ("0073", "HAZ71"),
    ("0120", "CEM120"),
    ("0121", "CEM120-EC"),
    ("0122", "CEM120-EC2"),
    ("5010", "Cube II AA"),
    ("5035", "AZ Mount Pro"),
    ("5045", "iEQ45 Pro AA"),
];

/// The mount's model as people know it, or its code when no table has it.
fn model_name(dialect: Option<Dialect>, code: &str) -> String {
    let table = match dialect {
        Some(Dialect::V25) => V25_MODELS,
        Some(Dialect::V3) => V3_MODELS,
        None => &[],
    };
    table
        .iter()
        .find(|(known, _)| *known == code)
        .map(|(_, name)| (*name).to_string())
        .unwrap_or_else(|| format!("mount with model code {code}"))
}

/// Alt-azimuth models and dual-mode mounts set up alt-azimuth. They take no
/// pulse guiding and report no side of pier.
fn is_alt_az(model: &str) -> bool {
    model.ends_with(" AA")
        || model.contains("AZ Mount")
        || (model.starts_with("HAZ") && !model.ends_with(" EQ"))
}

/// v2.5 gives `:MP1#`, `:MP0#`, `:SPA` and `:SPH` only to the CEM60, CEM40,
/// iEQ45 Pro and iEQ30 Pro (INDI adds the GEM45, which came after the
/// document). These are the v2.5 models it leaves out; v3.10 has no such limit.
const V25_CODES_WITHOUT_PARK: &[&str] = &["0010", "0011", "0025", "0026", "5010", "5035"];

fn parks(dialect: Dialect, code: &str) -> bool {
    dialect == Dialect::V3 || !V25_CODES_WITHOUT_PARK.contains(&code)
}

/// Four digits, the whole of a `:MountInfo#` reply.
fn model_code(reply: &str) -> Option<&str> {
    (reply.len() == MODEL_CODE_LENGTH && reply.bytes().all(|b| b.is_ascii_digit())).then_some(reply)
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

/// Reads the four digits `:MountInfo#` answers with.
fn read_model_code(io: &mut Exchange<'_>) -> Result<String, DriverError> {
    let mut reply = String::with_capacity(MODEL_CODE_LENGTH);
    for _ in 0..MODEL_CODE_LENGTH {
        reply.push(char::from(io.read_reply_byte(&IOPTRON_REPLY)?));
    }
    model_code(&reply).map(str::to_string).ok_or_else(|| {
        DriverError::SdkError(format!(
            "the device answered {} with {reply:?}, not an iOptron model code",
            commands::GET_MODEL
        ))
    })
}

/// What connect learned about the mount.
#[derive(Debug, Clone, Copy)]
struct Session {
    dialect: Dialect,
    alt_az: bool,
    parks: bool,
}

pub struct IOptronMount {
    device_id: String,
    name: String,
    port_name: String,
    baud_rate: u32,
    link: SerialLink,
    session: Mutex<Option<Session>>,
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
            session: Mutex::new(None),
        }
    }

    /// The session of a mount that has the park commands.
    fn parking_session(&self) -> Result<Session, DriverError> {
        let session = self.session()?;
        if session.parks {
            Ok(session)
        } else {
            Err(DriverError::NotSupported)
        }
    }

    fn session(&self) -> Result<Session, DriverError> {
        self.session
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .ok_or(DriverError::NotConnected)
    }

    /// Sends `command` with nothing stale ahead of its reply, then reads the
    /// reply with `read`.
    fn exchange<T>(
        &self,
        command: &str,
        read: impl FnOnce(&mut Exchange<'_>) -> Result<T, DriverError>,
    ) -> Result<T, DriverError> {
        self.link.exchange(|io| {
            io.discard_input()?;
            io.send(command.as_bytes())?;
            read(io)
        })
    }

    /// A query: the reply up to its `#`.
    fn query(&self, command: &str) -> Result<String, DriverError> {
        self.exchange(command, |io| io.read_reply(&IOPTRON_REPLY))
    }

    /// A setting or motion command: the digit it answers with.
    fn command_digit(&self, command: &str) -> Result<u8, DriverError> {
        self.exchange(command, |io| io.read_reply_byte(&IOPTRON_REPLY))
    }

    /// A command that answers `1` when the mount took it. `action` completes
    /// "the mount refused to ...".
    fn command_ok(&self, command: &str, action: &str) -> Result<(), DriverError> {
        match self.command_digit(command)? {
            b'1' => Ok(()),
            other => Err(DriverError::SdkError(format!(
                "The iOptron mount refused to {action} ({command} answered {:?})",
                char::from(other)
            ))),
        }
    }

    fn status(&self) -> Result<Status, DriverError> {
        let session = self.session()?;
        parse_status(session.dialect, &self.query(commands::GET_STATUS)?)
    }

    fn pointing(&self) -> Result<Pointing, DriverError> {
        let session = self.session()?;
        parse_pointing(
            session.dialect,
            &self.query(session.dialect.get_coordinates())?,
        )
    }

    fn set_target(
        &self,
        dialect: Dialect,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        let dec = format_dec(dec_degrees)?;
        self.command_ok(
            &dialect.set_target_ra(ra_hours),
            "take the target right ascension",
        )?;
        self.command_ok(&dec, "take the target declination")
    }

    fn open(&self, baud_rate: u32) -> Result<(), DriverError> {
        let serial = serial_link::open_port(&self.port_name, baud_rate)
            .map_err(|e| DriverError::SdkError(format!("Failed to open serial port: {}", e)))?;
        self.link.attach(serial)
    }

    fn open_and_read_model(&self, baud_rate: u32) -> Result<String, DriverError> {
        self.open(baud_rate)?;
        self.exchange(commands::GET_MODEL, read_model_code)
    }

    /// The firmware dates for the connect log line. A mount that does not
    /// answer them is still usable.
    fn firmware(&self) -> Option<String> {
        let fw1 = self.query(commands::GET_MAIN_AND_HC_FIRMWARE).ok();
        let fw2 = self.query(commands::GET_MOTOR_BOARD_FIRMWARE).ok();
        format_firmware_versions(fw1.as_deref(), fw2.as_deref())
    }

    /// The dialect the mount speaks, from its status reply.
    fn identify_dialect(&self, code: &str) -> Result<(Dialect, Status), DriverError> {
        let firmware_too_old = |why: String| {
            DriverError::SdkError(format!(
                "The iOptron mount on {} (model code {code}) {why}. Its firmware predates the 2016 command set Skotiq speaks: update the mount and hand controller firmware with iOptron's upgrade utility, then connect again.",
                self.port_name
            ))
        };
        let reply = self.query(commands::GET_STATUS).map_err(|e| {
            firmware_too_old(format!(
                "did not answer the status query {} ({e})",
                commands::GET_STATUS
            ))
        })?;
        let dialect = Dialect::from_status_length(reply.len())
            .ok_or_else(|| firmware_too_old(format!("answered the status query with {reply:?}")))?;
        Ok((dialect, parse_status(dialect, &reply)?))
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
        self.session
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some()
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }

        let _serial_access = serial_link::serial_mount_access().await;

        let code = match self.open_and_read_model(self.baud_rate) {
            Ok(code) => code,
            Err(first) => {
                // The mount did not answer at the configured rate. Close the
                // port and ask once more at the other one.
                self.link.detach()?;
                let other = if self.baud_rate == IOPTRON_BAUD_RATE_FAST {
                    IOPTRON_BAUD_RATE
                } else {
                    IOPTRON_BAUD_RATE_FAST
                };
                tracing::debug!(
                    "iOptron {}: no model code at {} baud ({}), trying {}",
                    self.port_name,
                    self.baud_rate,
                    first,
                    other
                );
                match self.open_and_read_model(other) {
                    Ok(code) => {
                        self.baud_rate = other;
                        code
                    }
                    Err(e) => {
                        self.link.detach()?;
                        return Err(e);
                    }
                }
            }
        };

        let (dialect, status) = match self.identify_dialect(&code) {
            Ok(found) => found,
            Err(e) => {
                self.link.detach()?;
                return Err(e);
            }
        };
        let model = model_name(Some(dialect), &code);
        let firmware = self.firmware();
        self.name = format!("iOptron {} ({})", model, self.port_name);
        tracing::info!(
            "Connected to iOptron {} (model code {}, command language {}, {} baud) on {}: {}; {}; site {:.4}, {:.4}",
            model,
            code,
            dialect.label(),
            self.baud_rate,
            self.port_name,
            firmware.as_deref().unwrap_or("firmware dates not reported"),
            status.describe_sources(),
            status.latitude_deg,
            status.longitude_deg,
        );

        *self.session.lock().unwrap_or_else(|e| e.into_inner()) = Some(Session {
            dialect,
            alt_az: is_alt_az(&model),
            parks: parks(dialect, &code),
        });
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
        if let Err(e) = self.command_ok(commands::STOP_SLEW, "stop the slew") {
            tracing::error!(
                "iOptron {}: stop-slew ({}) failed while disconnecting: {}. The mount may still be moving — stop it at the hand controller.",
                self.device_id,
                commands::STOP_SLEW,
                e
            );
        }

        self.link.detach()?;
        *self.session.lock().unwrap_or_else(|e| e.into_inner()) = None;

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
        let session = self.session()?;

        tracing::info!("Slewing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);
        self.set_target(session.dialect, ra_hours, dec_degrees)?;

        let slew = session.dialect.slew();
        match self.command_digit(slew)? {
            b'1' => Ok(()),
            b'0' => Err(DriverError::SdkError(
                "The iOptron mount refused the slew: the target is below its altitude limit or past its mechanical limits".into(),
            )),
            other => Err(DriverError::SdkError(format!(
                "The iOptron mount refused the slew ({slew} answered {:?})",
                char::from(other)
            ))),
        }
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        let pointing = self.pointing()?;
        Ok((pointing.ra_hours, pointing.dec_deg))
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        let session = self.session()?;

        tracing::info!("Syncing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);
        self.set_target(session.dialect, ra_hours, dec_degrees)?;
        self.command_ok(commands::SYNC, "sync")
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        self.parking_session()?;

        tracing::info!("Parking mount");
        self.command_ok(commands::PARK, "park")
    }

    async fn find_home(&mut self) -> Result<(), DriverError> {
        self.session()?;

        // iOptron's home is its zero position. The mount reports the motion
        // through the slewing state of `:GLS#` like any goto, so callers that
        // poll `is_slewing` wait for it to arrive.
        tracing::info!("Sending mount to its zero (home) position");
        self.command_ok(commands::GOTO_ZERO_POSITION, "slew to its zero position")
    }

    async fn at_home(&self) -> Result<bool, DriverError> {
        Ok(self.status()?.system == SystemStatus::StoppedAtZero)
    }

    async fn can_set_park(&self) -> Result<bool, DriverError> {
        Ok(self.session().map_or(true, |session| session.parks))
    }

    async fn set_park(&mut self) -> Result<(), DriverError> {
        self.parking_session()?;

        let (altitude, azimuth) = parse_alt_az(&self.query(commands::GET_ALT_AZ)?)?;
        if altitude < 0.0 {
            return Err(DriverError::InvalidParameter(format!(
                "the mount points {altitude:.2}° below the horizon; the park position must be above it"
            )));
        }
        tracing::info!(
            "Storing the current position (alt {:.4}°, az {:.4}°) as the park position",
            altitude,
            azimuth
        );
        let units = |degrees: f64| (degrees * CENTI_ARCSEC_PER_DEGREE).round() as i64;
        self.command_ok(
            &format!(
                "{}{:09}#",
                commands::SET_PARK_AZIMUTH,
                units(azimuth) % (360 * 360_000)
            ),
            "store the park azimuth",
        )?;
        self.command_ok(
            &format!("{}{:08}#", commands::SET_PARK_ALTITUDE, units(altitude)),
            "store the park altitude",
        )
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        self.parking_session()?;

        tracing::info!("Unparking mount");
        self.command_ok(commands::UNPARK, "unpark")
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        Ok(self.status()?.system.slewing())
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        self.parking_session()?;
        Ok(self.status()?.system == SystemStatus::Parked)
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        let session = self.session()?;
        if session.alt_az {
            return Err(DriverError::NotSupported);
        }
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

        tracing::debug!("iOptron pulse guide {:?} for {}ms", direction, duration_ms);
        self.exchange(&session.dialect.pulse_guide(direction, duration_ms), |_| {
            Ok(())
        })
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        self.session()?;

        tracing::info!("Aborting slew");
        self.command_ok(commands::STOP_SLEW, "stop the slew")
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        self.session()?;

        let (cmd, action) = if enabled {
            (commands::START_TRACKING, "start tracking")
        } else {
            (commands::STOP_TRACKING, "stop tracking")
        };
        self.command_ok(cmd, action)?;

        tracing::info!("Tracking {}", if enabled { "enabled" } else { "disabled" });

        Ok(())
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        Ok(self.status()?.system.tracking())
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        let session = self.session()?;
        // v2.5 has no side-of-pier report, and v3 says to ignore it on an
        // alt-azimuth mount.
        if session.dialect == Dialect::V25 || session.alt_az {
            return Ok(PierSide::Unknown);
        }
        Ok(self.pointing()?.pier_side)
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        self.session()?;
        parse_alt_az(&self.query(commands::GET_ALT_AZ)?)
    }

    /// Neither dialect has a sidereal-time query.
    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_site(&self) -> Result<MountSiteInfo, DriverError> {
        let status = self.status()?;
        if !(-90.0..=90.0).contains(&status.latitude_deg)
            || !(-180.0..=180.0).contains(&status.longitude_deg)
        {
            return Err(DriverError::SdkError(format!(
                "Mount reported site {:.4},{:.4}, which is out of range",
                status.latitude_deg, status.longitude_deg
            )));
        }
        Ok(MountSiteInfo {
            latitude_deg: status.latitude_deg,
            longitude_deg: status.longitude_deg,
            // The command language carries no elevation.
            elevation_m: None,
        })
    }

    async fn set_site(&mut self, site: MountSiteInfo) -> Result<(), DriverError> {
        let session = self.session()?;
        if !(-90.0..=90.0).contains(&site.latitude_deg)
            || !(-180.0..=180.0).contains(&site.longitude_deg)
        {
            return Err(DriverError::SdkError(format!(
                "Refusing to write site {:.4},{:.4} to the mount: out of range",
                site.latitude_deg, site.longitude_deg
            )));
        }
        let [longitude, latitude] = session.dialect.set_site(&site);
        tracing::info!(
            "Writing site to mount: lat {:.6} lon {:.6} ({} {})",
            site.latitude_deg,
            site.longitude_deg,
            longitude,
            latitude
        );
        self.command_ok(&longitude, "take the site longitude")?;
        self.command_ok(&latitude, "take the site latitude")?;

        // The mount keeps its hemisphere apart from the latitude, and both
        // documents give `:SHE` to set it. The site is written either way.
        let hemisphere = if site.latitude_deg < 0.0 {
            commands::SET_SOUTHERN_HEMISPHERE
        } else {
            commands::SET_NORTHERN_HEMISPHERE
        };
        if let Err(e) = self.command_ok(hemisphere, "set its hemisphere") {
            tracing::warn!(
                "iOptron {}: the site was written but the hemisphere was not: {}. Set the hemisphere at the hand controller.",
                self.port_name,
                e
            );
        }
        Ok(())
    }

    async fn get_clock(&self) -> Result<MountClock, DriverError> {
        let session = self.session()?;
        parse_clock(session.dialect, &self.query(session.dialect.get_clock())?)
    }

    async fn set_clock(&mut self, clock: MountClock) -> Result<(), DriverError> {
        let session = self.session()?;
        let sent = clock_commands(session.dialect, &clock)?;
        tracing::info!(
            "Writing clock to mount: UTC {} offset {} h ({})",
            clock.utc_unix_seconds,
            clock.utc_offset_hours,
            sent.join(" ")
        );
        for command in &sent {
            self.command_ok(command, "take the time")?;
        }
        Ok(())
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        self.session()?;

        let cmd = match rate {
            TrackingRate::Sidereal => commands::SET_TRACKING_SIDEREAL,
            TrackingRate::Lunar => commands::SET_TRACKING_LUNAR,
            TrackingRate::Solar => commands::SET_TRACKING_SOLAR,
            TrackingRate::King => commands::SET_TRACKING_KING,
            // `:RT4#` selects the stored custom rate, which nothing here sets.
            TrackingRate::Custom => {
                return Err(DriverError::NotSupported);
            }
        };

        self.command_ok(cmd, "change the tracking rate")?;
        tracing::info!("Set tracking rate to {:?}", rate);

        Ok(())
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        Ok(self.status()?.tracking_rate)
    }

    async fn can_slew(&self) -> bool {
        true
    }

    async fn can_sync(&self) -> bool {
        true
    }

    async fn can_pulse_guide(&self) -> bool {
        !self
            .session
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|session| session.alt_az)
    }

    /// `:RT4#`, the stored custom rate, is not offered: nothing sets it.
    async fn tracking_rates(&self) -> Vec<TrackingRate> {
        vec![
            TrackingRate::Sidereal,
            TrackingRate::Lunar,
            TrackingRate::Solar,
            TrackingRate::King,
        ]
    }

    async fn can_find_home(&self) -> Result<bool, DriverError> {
        Ok(true)
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

/// An iOptron mount answers the model query with four digits and nothing
/// after them; the length of its status reply names its model table.
fn identify_mount(port: &mut ProbedPort<'_>) -> Option<IOptronMountInfo> {
    let response = port.ask(&probe(commands::GET_MODEL))?;
    tracing::debug!(
        "iOptron response from {} at {} baud: {:?}",
        port.name,
        port.baud_rate,
        response
    );
    let code = model_code(&response)?.to_string();

    let dialect = query_hash_command(port, commands::GET_STATUS)
        .and_then(|status| Dialect::from_status_length(status.len()));
    let model = model_name(dialect, &code);
    let display_name = format!("iOptron {} ({})", model, port.name);
    let fw1 = query_hash_command(port, commands::GET_MAIN_AND_HC_FIRMWARE);
    let fw2 = query_hash_command(port, commands::GET_MOTOR_BOARD_FIRMWARE);
    let firmware_version = format_firmware_versions(fw1.as_deref(), fw2.as_deref());
    tracing::info!(
        "Found iOptron mount on {} at {} baud: {} (model code {}, command language {})",
        port.name,
        port.baud_rate,
        display_name,
        code,
        dialect.map_or("unknown", Dialect::label)
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
        assert!(mount.can_find_home().await.unwrap_or(false));
        assert!(
            matches!(mount.find_home().await, Err(DriverError::NotConnected)),
            "find_home should reach the connection check, not the trait default"
        );
        assert_eq!(commands::GOTO_ZERO_POSITION, ":MH#");
    }

    #[test]
    fn the_status_reply_length_names_the_dialect() {
        assert_eq!(Dialect::from_status_length(19), Some(Dialect::V25));
        assert_eq!(Dialect::from_status_length(23), Some(Dialect::V3));
        assert_eq!(Dialect::from_status_length(6), None);
    }

    #[test]
    fn a_v3_status_reply_reads_site_state_and_rate() {
        // 75.397448 W, 40.007714 N, GPS fix, slewing, lunar, 64x, GPS time, north.
        let status = parse_status(Dialect::V3, "-0271430810504027772521531").unwrap_err();
        assert!(
            matches!(status, DriverError::SdkError(_)),
            "26 bytes is no v3 status"
        );

        let status = parse_status(Dialect::V3, "-2714308146802777221531").unwrap();
        assert!((status.longitude_deg - -75.397448).abs() < 1e-6);
        assert!((status.latitude_deg - 40.007714).abs() < 1e-6);
        assert_eq!(status.system, SystemStatus::Slewing);
        assert_eq!(status.tracking_rate, TrackingRate::Lunar);
        assert!(status.system.slewing() && !status.system.tracking());
    }

    #[test]
    fn a_v25_status_reply_counts_whole_arc_seconds() {
        // 75.3975 W = 271431", 40.0077 N + 90 = 468028".
        let status = parse_status(Dialect::V25, "-271431468028260531").unwrap();
        assert!((status.longitude_deg - -75.39750).abs() < 1e-4);
        assert!((status.latitude_deg - 40.00778).abs() < 1e-4);
        assert_eq!(status.system, SystemStatus::Parked);
        assert_eq!(status.tracking_rate, TrackingRate::Sidereal);
    }

    #[test]
    fn every_documented_system_state_is_read() {
        let states: Vec<_> = (b'0'..=b'7').map(SystemStatus::from_digit).collect();
        assert!(states.iter().all(Option::is_some));
        assert_eq!(SystemStatus::from_digit(b'8'), None);
        let tracking: Vec<_> = states.iter().flatten().filter(|s| s.tracking()).collect();
        assert_eq!(
            tracking,
            [
                &SystemStatus::Tracking,
                &SystemStatus::Guiding,
                &SystemStatus::TrackingWithPec
            ]
        );
    }

    #[test]
    fn v3_positions_are_hundredths_of_an_arc_second_with_the_pier_side() {
        // Dec +20, RA 5.5 h = 82.5 deg, pier west, counterweight normal.
        let pointing = parse_pointing(Dialect::V3, "+0720000002970000011").unwrap();
        assert_eq!((pointing.ra_hours, pointing.dec_deg), (5.5, 20.0));
        assert_eq!(pointing.pier_side, PierSide::West);
        let east = parse_pointing(Dialect::V3, "-0720000002970000001").unwrap();
        assert_eq!((east.dec_deg, east.pier_side), (-20.0, PierSide::East));
        let unknown = parse_pointing(Dialect::V3, "+0720000002970000021").unwrap();
        assert_eq!(unknown.pier_side, PierSide::Unknown);
    }

    #[test]
    fn v25_positions_carry_right_ascension_in_milliseconds() {
        let pointing = parse_pointing(Dialect::V25, "+0720000019800000").unwrap();
        assert_eq!((pointing.ra_hours, pointing.dec_deg), (5.5, 20.0));
        assert_eq!(pointing.pier_side, PierSide::Unknown);
    }

    #[test]
    fn positions_outside_the_documented_ranges_are_refused() {
        assert!(parse_pointing(Dialect::V3, "+3240000102970000011").is_err());
        assert!(parse_pointing(Dialect::V3, "+072000000297000001").is_err());
        assert!(parse_pointing(Dialect::V25, "+0720000086400001").is_err());
        assert!(parse_pointing(Dialect::V25, "05300000+20000000").is_err());
    }

    #[test]
    fn altitude_and_azimuth_are_hundredths_of_an_arc_second() {
        assert_eq!(parse_alt_az("+16380000064890000").unwrap(), (45.5, 180.25));
        assert!(parse_alt_az("+45300000180150000").is_err());
    }

    #[test]
    fn targets_are_written_in_each_dialect_s_units() {
        assert_eq!(Dialect::V3.set_target_ra(5.5), ":SRA029700000#");
        assert_eq!(Dialect::V25.set_target_ra(5.5), ":Sr19800000#");
        // Rounding up to 24 h wraps to 0 instead of overflowing the field.
        assert_eq!(Dialect::V3.set_target_ra(24.0 - 1e-9), ":SRA000000000#");
        assert_eq!(Dialect::V25.set_target_ra(-1e-9), ":Sr00000000#");
        assert_eq!(format_dec(-20.2512).unwrap(), ":Sd-07290432#");
        assert_eq!(format_dec(90.0).unwrap(), ":Sd+32400000#");
        assert!(format_dec(90.5).is_err());
    }

    #[test]
    fn pulse_guide_commands_carry_five_digits() {
        assert_eq!(
            Dialect::V3.pulse_guide(GuideDirection::North, 40),
            ":ZE00040#"
        );
        assert_eq!(
            Dialect::V3.pulse_guide(GuideDirection::South, 40),
            ":ZC00040#"
        );
        assert_eq!(
            Dialect::V3.pulse_guide(GuideDirection::East, 40),
            ":ZS00040#"
        );
        assert_eq!(
            Dialect::V3.pulse_guide(GuideDirection::West, 99_999),
            ":ZQ99999#"
        );
        assert_eq!(
            Dialect::V25.pulse_guide(GuideDirection::North, 5),
            ":Mn00005#"
        );
        assert_eq!(
            Dialect::V25.pulse_guide(GuideDirection::West, 1500),
            ":Mw01500#"
        );
    }

    #[test]
    fn the_site_is_written_in_each_dialect_s_units() {
        let site = MountSiteInfo {
            latitude_deg: 40.007714,
            longitude_deg: -75.397448,
            elevation_m: None,
        };
        assert_eq!(
            Dialect::V3.set_site(&site),
            [":SLO-27143081#".to_string(), ":SLA+14402777#".to_string()]
        );
        assert_eq!(
            Dialect::V25.set_site(&site),
            [":Sg-271431#".to_string(), ":St+144028#".to_string()]
        );
    }

    #[test]
    fn the_v3_clock_counts_milliseconds_from_j2000() {
        // 2026-09-09 02:30:00 UTC; Eastern standard time with DST on.
        let clock = parse_clock(Dialect::V3, "-3001084219300000").unwrap_err();
        assert!(
            matches!(clock, DriverError::SdkError(_)),
            "17 bytes is no v3 clock"
        );
        let ms = (1_788_921_000 - J2000_UNIX_SECONDS) * 1000;
        let clock = parse_clock(Dialect::V3, &format!("-3001{ms:013}")).unwrap();
        assert_eq!(clock.utc_unix_seconds, 1_788_921_000);
        assert_eq!(clock.utc_offset_hours, -4.0);
    }

    #[test]
    fn the_v25_clock_is_local_time_with_its_offset_and_daylight_saving() {
        // 2026-09-08 22:30:00 local at UTC-5 with DST = 2026-09-09 02:30 UTC.
        let clock = parse_clock(Dialect::V25, "-3001260908223000").unwrap();
        assert_eq!(clock.utc_unix_seconds, 1_788_921_000);
        assert_eq!(clock.utc_offset_hours, -4.0);
        assert!(parse_clock(Dialect::V25, "-3001261308223000").is_err());
    }

    #[test]
    fn setting_the_clock_writes_the_whole_offset_and_clears_daylight_saving() {
        let clock = MountClock {
            utc_unix_seconds: 1_788_921_000,
            utc_offset_hours: -4.0,
        };
        let ms = (1_788_921_000 - J2000_UNIX_SECONDS) * 1000;
        assert_eq!(
            clock_commands(Dialect::V3, &clock).unwrap(),
            [
                ":SG-240#".to_string(),
                ":SDS0#".to_string(),
                format!(":SUT{ms:013}#")
            ]
        );
        assert_eq!(
            clock_commands(Dialect::V25, &clock).unwrap(),
            [":SG-240#", ":SDS0#", ":SC260908#", ":SL223000#"].map(String::from)
        );
        let read_back = parse_clock(Dialect::V3, &format!("-2400{ms:013}")).unwrap();
        assert_eq!(read_back, clock);
        let far_east = MountClock {
            utc_offset_hours: 14.0,
            ..clock
        };
        assert!(clock_commands(Dialect::V3, &far_east).is_err());
    }

    #[test]
    fn model_codes_are_read_from_the_table_of_the_dialect() {
        assert_eq!(model_name(Some(Dialect::V25), "0025"), "CEM25");
        assert_eq!(model_name(Some(Dialect::V3), "0025"), "HEM27");
        assert_eq!(model_name(Some(Dialect::V3), "0044"), "GEM45-EC");
        assert_eq!(model_name(None, "0040"), "mount with model code 0040");
        assert_eq!(
            model_name(Some(Dialect::V3), "9999"),
            "mount with model code 9999"
        );
    }

    #[test]
    fn alt_azimuth_models_are_recognized() {
        for model in [
            "iEQ45 Pro AA",
            "AZ Mount Pro",
            "HAZ31",
            "HAE43 AA",
            "Cube II AA",
        ] {
            assert!(is_alt_az(model), "{model}");
        }
        for model in ["CEM40", "HAE43 EQ", "iEQ45 Pro EQ", "HEM44A", "CEM120-EC2"] {
            assert!(!is_alt_az(model), "{model}");
        }
    }

    #[test]
    fn a_model_code_is_exactly_four_digits() {
        assert_eq!(model_code("0040"), Some("0040"));
        assert_eq!(model_code("CEM60#"), None);
        assert_eq!(model_code("004"), None);
        assert_eq!(model_code("00401"), None);
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
