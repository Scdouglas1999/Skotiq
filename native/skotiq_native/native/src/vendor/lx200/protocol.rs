//! LX200 serial protocol constants, parsing and park-state persistence.

use super::*;

/// Default baud rate for classic LX200 mounts
pub(crate) const LX200_BAUD_RATE: u32 = 9600;
pub(crate) const RESPONSE_TERM: u8 = b'#';

/// OnStep controllers such as the Pegasus NYX terminate a response with `#`
/// and then emit CRLF. The byte-oriented reader stops at `#`, so those trailing
/// bytes become the prefix of the next response unless they are discarded.
pub(crate) const INTER_RESPONSE_FRAMING: &[u8] = b"\r\n\0";

/// A `#`-terminated reply.
pub(crate) const REPLY: ReplyRule = ReplyRule {
    terminator: RESPONSE_TERM,
    leading_framing: INTER_RESPONSE_FRAMING,
    deadline: REPLY_DEADLINE,
    timeout_message: "LX200 command response timed out",
};

/// A one-character `1`/`0` answer with no terminator.
pub(crate) const BOOL_REPLY: ReplyRule = ReplyRule {
    timeout_message: "LX200 command bool response timed out",
    ..REPLY
};

/// The status character that answers `:MS#`.
pub(crate) const SLEW_ACK_REPLY: ReplyRule = ReplyRule {
    timeout_message: "LX200 slew acknowledgement timed out",
    ..REPLY
};

pub(crate) const SCAN_PLAN: ScanPlan = ScanPlan {
    protocol: "LX200",
    baud_rates: DISCOVERY_BAUD_RATES,
    on_open_failure: OnOpenFailure::NextPort,
};

/// Time a mount gets to answer a discovery probe.
pub(crate) const PROBE_SETTLE: Duration = Duration::from_millis(200);

pub(crate) const fn probe(command: &'static str, reply_capacity: usize) -> Probe<'static> {
    Probe {
        command: command.as_bytes(),
        settle: PROBE_SETTLE,
        reply_capacity,
    }
}

/// How long to wait for the trailing strings Meade firmware sends after `:SC#`.
pub(crate) const CALENDAR_CHATTER_WINDOW: Duration = Duration::from_millis(750);

/// Baud rates to try during discovery, in order of preference
/// - 115200: Pegasus NYX-101, modern OnStep builds
/// - 57600: Some OnStep configurations
/// - 19200: Some mounts use this
/// - 9600: Classic LX200, Meade, Losmandy Gemini
pub(crate) const DISCOVERY_BAUD_RATES: &[u32] = &[115200, 57600, 19200, 9600];

pub(crate) mod commands {
    // Standard LX200 commands
    pub const GET_RA: &str = ":GR#";
    pub const GET_DEC: &str = ":GD#";
    pub const GET_ALT: &str = ":GA#";
    pub const GET_AZ: &str = ":GZ#";
    pub const GET_SIDEREAL_TIME: &str = ":GS#";

    pub const SET_TARGET_RA: &str = ":Sr";
    pub const SET_TARGET_DEC: &str = ":Sd";

    pub const SLEW_TO_TARGET: &str = ":MS#";
    pub const STOP_SLEW: &str = ":Q#";
    /// Distance bar: one bar character while a goto is in progress, an empty
    /// string once it has finished. The standard LX200 slew-complete query,
    /// answered by Meade, Losmandy Gemini and 10Micron firmware.
    pub const DISTANCE_BARS: &str = ":D#";

    pub const SYNC: &str = ":CM#";

    pub const MOVE_NORTH: &str = ":Mn#";
    pub const MOVE_SOUTH: &str = ":Ms#";
    pub const MOVE_EAST: &str = ":Me#";
    pub const MOVE_WEST: &str = ":Mw#";
    pub const STOP_MOVE_NORTH: &str = ":Qn#";
    pub const STOP_MOVE_SOUTH: &str = ":Qs#";
    pub const STOP_MOVE_EAST: &str = ":Qe#";
    pub const STOP_MOVE_WEST: &str = ":Qw#";

    pub const SET_TRACK_SIDEREAL: &str = ":TQ#";
    pub const SET_TRACK_LUNAR: &str = ":TL#";
    pub const SET_TRACK_SOLAR: &str = ":TS#"; // OnStep: :TS# for solar rate
    pub const SET_RATE_GUIDE: &str = ":RG#";

    // OnStep tracking rate commands
    pub const ONSTEP_SET_RATE_KING: &str = ":TK#";

    pub const GET_PRODUCT_NAME: &str = ":GVP#";

    /// Meade alignment / status query.
    ///
    /// Returns 3-4 character status terminated by `#`. Position 0 reports
    /// alignment mode and may include `P` when the mount is parked on
    /// LX200GPS / LX200ACF / RCX400 firmware (Meade Telescope Serial
    /// Command Protocol rev L). Older Classic LX200 firmware does not
    /// expose park state via `:GW#`; if the response is non-empty but
    /// lacks a recognizable parked indicator we cannot infer state.
    pub const MEADE_GET_STATUS: &str = ":GW#";

    pub const PARK: &str = ":hP#";
    /// Unpark on Meade-compatible firmware that has one (10Micron, Astro-Physics).
    pub const UNPARK: &str = ":PO#";
    /// Losmandy Gemini leaves its park by waking up.
    pub const GEMINI_WAKE_UP: &str = ":hW#";

    /// Toggles between low (`HH:MM.T`, `sDD*MM`) and high precision
    /// (`HH:MM:SS`, `sDD*MM:SS`) coordinates. No reply.
    pub const TOGGLE_PRECISION: &str = ":U#";

    // OnStep-specific commands (used by Pegasus NYX, DIY OnStep mounts)
    pub const ONSTEP_GET_STATUS: &str = ":GU#";
    pub const ONSTEP_TRACK_ENABLE: &str = ":Te#";
    pub const ONSTEP_TRACK_DISABLE: &str = ":Td#";
    pub const ONSTEP_UNPARK: &str = ":hR#";
    /// Slews to the home position. Not `:hF#`, which tells the mount it is
    /// at home where it stands and moves nothing.
    pub const ONSTEP_GO_HOME: &str = ":hC#";
    pub const ONSTEP_SET_PARK: &str = ":hQ#";

    // 10Micron. Tracking on and off answer nothing; pier side answers
    // `East#` or `West#`.
    pub const TENMICRON_TRACK_ON: &str = ":AP#";
    pub const TENMICRON_TRACK_OFF: &str = ":AL#";
    pub const TENMICRON_PIER_SIDE: &str = ":pS#";

    // Site and clock. Latitude/longitude are DMS; longitude is WEST-positive
    // on the wire. `:GC#`/`:SC#` carry a two-digit year.
    pub const GET_SITE_LATITUDE: &str = ":Gt#";
    pub const GET_SITE_LONGITUDE: &str = ":Gg#";
    pub const SET_SITE_LATITUDE: &str = ":St";
    pub const SET_SITE_LONGITUDE: &str = ":Sg";
    pub const GET_LOCAL_TIME: &str = ":GL#";
    pub const GET_CALENDAR_DATE: &str = ":GC#";
    pub const GET_UTC_OFFSET: &str = ":GG#";
    pub const SET_LOCAL_TIME: &str = ":SL";
    pub const SET_CALENDAR_DATE: &str = ":SC";
    pub const SET_UTC_OFFSET: &str = ":SG";
    // OnStep pulse guide format: :Mgdnnnn# where d=n/s/e/w, nnnn=milliseconds
    pub const ONSTEP_PULSE_GUIDE_PREFIX: &str = ":Mg";

    // Meade/LX200 information commands. Compatible firmware may omit them, so
    // discovery treats these as optional metadata probes.
    pub const GET_FIRMWARE_DATE: &str = ":GVD#";
    pub const GET_FIRMWARE_NUMBER: &str = ":GVN#";
    pub const GET_FIRMWARE_TIME: &str = ":GVT#";
}

pub(crate) fn optional_discovery_response(
    port: &mut ProbedPort<'_>,
    command: &'static str,
) -> Option<String> {
    let response = port.ask(&probe(command, 64))?;
    let trimmed = response.trim().trim_end_matches('#').trim().to_string();
    if trimmed.is_empty() || trimmed == "\0" {
        None
    } else {
        Some(trimmed)
    }
}

pub(crate) fn format_firmware_version(
    number: Option<&str>,
    date: Option<&str>,
    time: Option<&str>,
) -> Option<String> {
    let number = number.filter(|value| value.chars().any(|c| c.is_ascii_alphanumeric()));
    let date = date.filter(|value| value.chars().any(|c| c.is_ascii_alphanumeric()));
    let time = time.filter(|value| value.chars().any(|c| c.is_ascii_alphanumeric()));

    match (number, date, time) {
        (Some(number), Some(date), Some(time)) => {
            Some(format!("LX200 firmware v{} ({} {})", number, date, time))
        }
        (Some(number), Some(date), None) => Some(format!("LX200 firmware v{} ({})", number, date)),
        (Some(number), None, Some(time)) => Some(format!("LX200 firmware v{} ({})", number, time)),
        (Some(number), None, None) => Some(format!("LX200 firmware v{}", number)),
        (None, Some(date), Some(time)) => Some(format!("LX200 firmware {} {}", date, time)),
        (None, Some(date), None) => Some(format!("LX200 firmware {}", date)),
        (None, None, Some(time)) => Some(format!("LX200 firmware {}", time)),
        (None, None, None) => None,
    }
}

/// Parse OnStep `:GU#` status reply into mount state fields.
///
/// OnStep firmware builds the reply in a fixed prefix order (`Command.ino`):
/// optional `n` (not tracking), optional `N` (no goto / not slewing), then exactly
/// one park-status letter from `pIPF`, followed by optional feature flags, mount
/// type (`E`/`K`/`A`), pier side (`o`/`T`/`W`), guide-rate digits, and an error digit.
///
/// Returns `(is_tracking, is_slewing, is_parked, is_at_home, pier_side)` using the
/// same semantics as OnStep's official `MountStatus.h` (positional prefix for `n`/`N`/park).
pub(crate) fn parse_onstep_status_fields(status: &str) -> (bool, bool, bool, bool, PierSide) {
    let s = status.trim_end_matches('#').trim();
    if s.is_empty() {
        return (false, false, false, false, PierSide::Unknown);
    }

    let bytes = s.as_bytes();
    let mut idx = 0usize;

    // Positional prefix per OnStep firmware append order.
    let has_not_tracking = bytes.get(idx) == Some(&b'n');
    if has_not_tracking {
        idx += 1;
    }
    let has_no_goto = bytes.get(idx) == Some(&b'N');
    if has_no_goto {
        idx += 1;
    }

    let park_char = bytes.get(idx).map(|b| *b as char);

    // Source `Command.ino`: leading `n` is the not-tracking indicator.
    // During a normal goto, OnStep can omit both `n` and `N`, so the mount is
    // both tracking and slewing.
    let is_slewing = !has_no_goto;
    let is_tracking = !has_not_tracking;

    // Park letter is always the third prefix slot when firmware follows the spec.
    let mut is_parked = park_char == Some('P');
    if park_char == Some('p') || s.contains('p') {
        is_parked = false;
    } else if park_char.is_none() {
        // Malformed / legacy replies: fall back to OnStep addon substring rules.
        is_parked = s.contains('P');
    }

    let is_homed = s.contains('H');

    // The final suffix is: mount type, pier side, pulse-guide rate, guide rate,
    // general error. Read pier side from that suffix instead of scanning for
    // `T`/`W`, because earlier optional flags can contain unrelated status bytes.
    let pier_side = parse_onstep_pier_side_suffix(bytes);

    (is_tracking, is_slewing, is_parked, is_homed, pier_side)
}

pub(crate) fn parse_onstep_pier_side_suffix(bytes: &[u8]) -> PierSide {
    if bytes.len() < 4 {
        return PierSide::Unknown;
    }

    match bytes[bytes.len() - 4] {
        b'T' => PierSide::East,
        b'W' => PierSide::West,
        b'o' => PierSide::Unknown,
        _ => PierSide::Unknown,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lx200MountType {
    /// Standard Meade LX200 protocol
    Meade,
    /// OnStep-based mounts (Pegasus NYX-101, DIY OnStep builds)
    /// Uses extended LX200 commands for tracking, status, pulse guiding
    OnStep,
    /// Losmandy Gemini in LX200 compatibility mode
    Losmandy,
    /// 10Micron mounts (extended LX200)
    TenMicron,
    /// Generic LX200-compatible mount
    Generic,
}

impl Lx200MountType {
    pub fn vendor(&self) -> Vendor {
        match self {
            Lx200MountType::Meade => Vendor::Meade,
            Lx200MountType::OnStep => Vendor::Other("Pegasus/OnStep".to_string()),
            Lx200MountType::Losmandy | Lx200MountType::TenMicron | Lx200MountType::Generic => {
                Vendor::Other("LX200".to_string())
            }
        }
    }

    /// Check if this mount type uses OnStep command extensions
    pub fn is_onstep(&self) -> bool {
        matches!(self, Lx200MountType::OnStep)
    }

    /// The command that ends a park, sent without waiting for a reply.
    pub(crate) fn unpark_command(&self) -> &'static str {
        match self {
            Lx200MountType::OnStep => commands::ONSTEP_UNPARK,
            Lx200MountType::Losmandy => commands::GEMINI_WAKE_UP,
            Lx200MountType::Meade | Lx200MountType::TenMicron | Lx200MountType::Generic => {
                commands::UNPARK
            }
        }
    }

    /// How this firmware turns sidereal tracking on or off, or `None` when it
    /// has no command for it. Classic Meade, Gemini (in LX200 mode) and
    /// generic firmware cannot stop tracking from the LX200 command set.
    pub(crate) fn tracking_command(&self, enabled: bool) -> Option<TrackingCommand> {
        match (self, enabled) {
            (Lx200MountType::OnStep, true) => Some(TrackingCommand {
                command: commands::ONSTEP_TRACK_ENABLE,
                answers: true,
            }),
            (Lx200MountType::OnStep, false) => Some(TrackingCommand {
                command: commands::ONSTEP_TRACK_DISABLE,
                answers: true,
            }),
            (Lx200MountType::TenMicron, true) => Some(TrackingCommand {
                command: commands::TENMICRON_TRACK_ON,
                answers: false,
            }),
            (Lx200MountType::TenMicron, false) => Some(TrackingCommand {
                command: commands::TENMICRON_TRACK_OFF,
                answers: false,
            }),
            (_, true) => Some(TrackingCommand {
                command: commands::SET_TRACK_SIDEREAL,
                answers: false,
            }),
            (_, false) => None,
        }
    }

    /// What a `:MS#` refusal code means on this firmware. Codes 1 and 2 are
    /// Meade's, and OnStep gives 2 the opposite meaning. 3-9 are OnStep's
    /// (MountGoto.cpp); Meade firmware never sends them, so reading them the
    /// OnStep way names the real reason on OnStep-derived mounts that are not
    /// recognized as OnStep.
    pub(crate) fn slew_refusal_reason(&self, code: char) -> String {
        // Losmandy Gemini Level 4 serial commands, `:MS#`.
        if matches!(self, Lx200MountType::Losmandy) {
            let gemini = match code {
                '1' => Some("target is below the horizon"),
                '2' => Some("no target is selected"),
                '3' => Some("the mount is under manual control"),
                '4' => Some("the target position is unreachable"),
                '5' => Some("the mount is not aligned"),
                '6' => Some("target is outside the mount's limits"),
                _ => None,
            };
            if let Some(reason) = gemini {
                return reason.to_string();
            }
        }
        match code {
            '1' => "target is below the horizon",
            '2' if self.is_onstep() => "target is above the overhead limit",
            '2' => "target is below the altitude limit",
            '3' => "mount is in standby (turn tracking on first)",
            '4' => "mount is parked",
            '5' => "a goto is already in progress",
            '6' => "target is outside the mount's limits",
            '7' => "mount reported a hardware fault",
            '8' => "mount is already in motion",
            '9' => "mount refused the goto (unspecified error)",
            other => return format!("mount refused the goto with status {}", other),
        }
        .to_string()
    }
}

/// A tracking on/off command and whether the firmware answers it with `1`/`0`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TrackingCommand {
    pub command: &'static str,
    pub answers: bool,
}

/// Which coordinate format the mount is set to. Meade firmware takes goto
/// targets only in the format it currently reports positions in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CoordinatePrecision {
    /// `HH:MM.T` and `sDD*MM`.
    Low,
    /// `HH:MM:SS` and `sDD*MM:SS` (or finer, on 10Micron).
    High,
}

impl CoordinatePrecision {
    /// Read from a `:GR#` reply: low precision puts a tenths-of-a-minute
    /// point where high precision has its second colon.
    pub(crate) fn of_ra_reply(reply: &str) -> Self {
        if reply.trim().as_bytes().get(5) == Some(&b'.') {
            CoordinatePrecision::Low
        } else {
            CoordinatePrecision::High
        }
    }
}

/// Signed hours or degrees from a sexagesimal reply.
///
/// Firmware disagrees about separators: OnStep answers `sDD*MM:SS`, Meade
/// high precision `sDD*MM'SS`, Autostar puts its own degree glyph (byte 0xDF,
/// not valid UTF-8, so it reaches this function as U+FFFD) where others put
/// `*`, 10Micron ultra precision `sDD:MM:SS.S`, and low precision RA is
/// `HH:MM.T`. Any character that cannot be part of a number separates fields.
pub(crate) fn parse_sexagesimal(response: &str) -> Result<f64, DriverError> {
    let cleaned = response.trim().trim_end_matches('#').trim();
    let unreadable = || DriverError::SdkError(format!("Unreadable mount reply {:?}", response));

    let (sign, rest) = split_sign(cleaned);
    let fields: Vec<&str> = rest
        .split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .filter(|field| !field.is_empty())
        .collect();
    if fields.is_empty() || fields.len() > 3 {
        return Err(unreadable());
    }
    let number = |field: &str| field.parse::<f64>().map_err(|_| unreadable());

    let whole = number(fields[0])?;
    let minutes = fields.get(1).map(|f| number(f)).transpose()?.unwrap_or(0.0);
    let seconds = fields.get(2).map(|f| number(f)).transpose()?.unwrap_or(0.0);
    if !(0.0..60.0).contains(&minutes) || !(0.0..60.0).contains(&seconds) {
        return Err(DriverError::SdkError(format!(
            "Minutes or seconds out of range in mount reply {:?}",
            response
        )));
    }

    Ok(sign * from_parts(whole, minutes, seconds))
}

pub(crate) fn format_ra(ra_hours: f64, precision: CoordinatePrecision) -> String {
    match precision {
        CoordinatePrecision::High => {
            let total = to_units(ra_hours, 3600).rem_euclid(24 * 3600);
            let (hours, minutes, seconds) = split_units(total, 3600);
            format!("{:02}:{:02}:{:02}", hours, minutes, seconds)
        }
        CoordinatePrecision::Low => {
            let total = to_units(ra_hours, 600).rem_euclid(24 * 600);
            let (hours, minutes, tenths) = split_units(total, 600);
            format!("{:02}:{:02}.{}", hours, minutes, tenths)
        }
    }
}

/// `sDD*MM:SS` or `sDD*MM`. The degrees are always two digits: firmware
/// reads the field by position and refuses `+5*00:00`.
pub(crate) fn format_dec(dec_degrees: f64, precision: CoordinatePrecision) -> String {
    let sign = sign_char(dec_degrees);
    match precision {
        CoordinatePrecision::High => {
            let total = to_units(dec_degrees.abs(), 3600);
            let (degrees, arcmin, arcsec) = split_units(total, 3600);
            format!("{}{:02}*{:02}:{:02}", sign, degrees, arcmin, arcsec)
        }
        CoordinatePrecision::Low => {
            let total = to_units(dec_degrees.abs(), 60);
            let (degrees, arcmin, _) = split_units(total, 60);
            format!("{}{:02}*{:02}", sign, degrees, arcmin)
        }
    }
}

// Park-state persistence
//
// Most LX200-family mounts (Losmandy Gemini in LX200 mode, generic clones,
// pre-LX200GPS Meade firmware, certain 10Micron firmware) provide no telemetry
// for "is the mount parked?". The protocol simply accepts `:hP#` and stops the
// motors — there is no echo. So we track our own park sends and persist them
// across app restarts, and a power-cycle does not silently erase the canonical
// state. When neither telemetry nor a persisted record exists we surface
// `NotSupported` rather than fabricate `false`.

/// Returns the path to the park-state JSON file in the user's app-data dir.
///
/// The file is intentionally kept outside the Drift database because this
/// crate does not depend on the Flutter app and must be writable from a
/// pure-Rust unit test. We resolve the dir in this priority order:
///   1. `SKOTIQ_HOME` env var (used by tests and headless runs)
///   2. `%APPDATA%\Skotiq` on Windows
///   3. `$XDG_CONFIG_HOME/skotiq` or `$HOME/.config/skotiq` elsewhere
///
/// On total failure we fall back to a temp-dir path so the binary never
/// panics on a read-only home dir; persistence is best-effort and the
/// caller surfaces `NotSupported` if the cache cannot be loaded.
pub(crate) fn lx200_state_file_path() -> PathBuf {
    let base: PathBuf = if let Ok(custom) = std::env::var("SKOTIQ_HOME") {
        PathBuf::from(custom)
    } else if cfg!(windows) {
        std::env::var("APPDATA")
            .map(|s| PathBuf::from(s).join("Skotiq"))
            .unwrap_or_else(|_| std::env::temp_dir().join("skotiq"))
    } else if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(xdg).join("skotiq")
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".config").join("skotiq")
    } else {
        std::env::temp_dir().join("skotiq")
    };

    base.join("lx200_park_state.json")
}

/// Read the persisted park-state map. `Ok(None)` for that device id means the
/// file does not exist or contains no entry for this mount; the caller must
/// then return `NotSupported` rather than guessing.
pub(crate) fn read_persisted_park_state(device_id: &str) -> Result<Option<bool>, DriverError> {
    let path = lx200_state_file_path();
    if !path.exists() {
        return Ok(None);
    }

    let raw = std::fs::read_to_string(&path).map_err(|e| {
        DriverError::Io(std::io::Error::new(
            e.kind(),
            format!("read park state: {}", e),
        ))
    })?;
    let map: HashMap<String, bool> = serde_json::from_str(&raw)
        .map_err(|e| DriverError::SdkError(format!("parse park state JSON: {}", e)))?;
    Ok(map.get(device_id).copied())
}

/// Atomically update the persisted park state for one device.
///
/// We re-read the full map, mutate the single entry, then write the whole
/// file back. The file is small (one bool per mount the user owns) so the
/// rewrite cost is negligible compared to a serial command round-trip.
pub(crate) fn write_persisted_park_state(device_id: &str, parked: bool) -> Result<(), DriverError> {
    let path = lx200_state_file_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            DriverError::Io(std::io::Error::new(
                e.kind(),
                format!("create park state dir {:?}: {}", parent, e),
            ))
        })?;
    }

    let mut map: HashMap<String, bool> = if path.exists() {
        let raw = std::fs::read_to_string(&path).map_err(|e| {
            DriverError::Io(std::io::Error::new(
                e.kind(),
                format!("read park state: {}", e),
            ))
        })?;
        // Tolerate an empty file (e.g., interrupted write) but surface real
        // JSON corruption — silent fallbacks hide bugs.
        if raw.trim().is_empty() {
            HashMap::new()
        } else {
            serde_json::from_str(&raw)
                .map_err(|e| DriverError::SdkError(format!("parse park state JSON: {}", e)))?
        }
    } else {
        HashMap::new()
    };

    map.insert(device_id.to_string(), parked);

    let serialized = serde_json::to_string_pretty(&map)
        .map_err(|e| DriverError::SdkError(format!("serialize park state: {}", e)))?;
    std::fs::write(&path, serialized).map_err(|e| {
        DriverError::Io(std::io::Error::new(
            e.kind(),
            format!("write park state: {}", e),
        ))
    })?;
    Ok(())
}

/// Whether a Meade `:GW#` reply says the mount is tracking, or `None` when
/// the reply is not in the documented shape.
///
/// Meade Telescope Serial Command Protocol 2010.10: `:GW#` answers
/// `<mount><tracking><alignment>#`, mount `A` alt-az, `P` equatorially
/// mounted (a fork on a wedge), `G` German equatorial; tracking `T` or `N`.
/// `L` (land, after `:AL#`) is read as well. Nothing in it says parked: `P`
/// is the mount type, so reading `PN` as parked put every wedge-mounted
/// Meade with tracking off into "parked".
pub(crate) fn parse_meade_gw_tracking(response: &str) -> Option<bool> {
    let bytes = response.trim().trim_end_matches('#').as_bytes();
    if !matches!(bytes.first(), Some(b'A' | b'P' | b'G' | b'L')) {
        return None;
    }
    match bytes.get(1) {
        Some(b'T') => Some(true),
        Some(b'N') => Some(false),
        _ => None,
    }
}

/// How the mount answered `:MS#`.
///
/// The goto acknowledgement is the one LX200 reply that does not follow the
/// `<payload>#` shape every other read command uses: an ACCEPTED goto answers
/// with a bare `0` and no terminator at all, while a REFUSED one answers with a
/// status code, an optional human-readable reason, and `#`. A reader that waits
/// for `#` therefore waits out its whole deadline on the success path — the
/// mount slews, and the app reports a timeout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SlewAck {
    Accepted,
    Refused { code: char, message: String },
}

/// Longest we wait for the reason text that follows a refusal code. A refusal
/// sends its message back-to-back with the code, so this only bounds the case
/// where the firmware sends the bare code and nothing else.
pub(crate) const SLEW_REFUSAL_TAIL: Duration = Duration::from_millis(500);

pub(crate) fn parse_slew_ack(code: u8, tail: &[u8]) -> SlewAck {
    if code == b'0' {
        return SlewAck::Accepted;
    }

    let message = String::from_utf8_lossy(tail)
        .trim_end_matches(RESPONSE_TERM as char)
        .trim()
        .to_string();

    SlewAck::Refused {
        code: code as char,
        message,
    }
}

pub(crate) fn slew_refusal_message(
    mount_type: &Lx200MountType,
    code: char,
    message: &str,
) -> String {
    let reason = mount_type.slew_refusal_reason(code);

    if message.is_empty() {
        format!("Slew refused: {}", reason)
    } else {
        format!("Slew refused: {} ({})", reason, message)
    }
}

#[cfg(test)]
mod slew_ack_tests {
    use super::*;

    #[test]
    fn bare_zero_is_an_accepted_goto() {
        // The reply that used to hang the reader for the full 5 s deadline:
        // one byte, no `#`, mount already moving.
        assert_eq!(parse_slew_ack(b'0', &[]), SlewAck::Accepted);
    }

    #[test]
    fn refusal_carries_its_code_and_reason() {
        assert_eq!(
            parse_slew_ack(b'1', b"Below horizon#"),
            SlewAck::Refused {
                code: '1',
                message: "Below horizon".to_string(),
            }
        );
    }

    #[test]
    fn refusal_without_reason_text_keeps_its_code() {
        assert_eq!(
            parse_slew_ack(b'4', &[]),
            SlewAck::Refused {
                code: '4',
                message: String::new(),
            }
        );
    }

    #[test]
    fn onstep_codes_read_as_their_documented_reasons() {
        let onstep = Lx200MountType::OnStep;
        assert!(slew_refusal_message(&onstep, '4', "").contains("parked"));
        assert!(slew_refusal_message(&onstep, '7', "").contains("hardware fault"));
        assert!(slew_refusal_message(&onstep, '1', "Below horizon").contains("Below horizon"));
        assert!(slew_refusal_message(&onstep, 'x', "").contains("status x"));
    }

    /// Code 2 is a low target on Meade firmware and a high one on OnStep.
    #[test]
    fn code_two_reads_by_dialect() {
        assert!(slew_refusal_message(&Lx200MountType::OnStep, '2', "").contains("overhead"));
        assert!(slew_refusal_message(&Lx200MountType::Meade, '2', "").contains("below"));
    }

    /// Gemini numbers its refusals its own way: 4 is an unreachable
    /// position, not a parked mount, and 3 manual control, not standby.
    #[test]
    fn gemini_codes_read_as_gemini_documents_them() {
        let gemini = Lx200MountType::Losmandy;
        assert!(slew_refusal_message(&gemini, '2', "").contains("no target"));
        assert!(slew_refusal_message(&gemini, '3', "").contains("manual control"));
        assert!(slew_refusal_message(&gemini, '4', "").contains("unreachable"));
        assert!(slew_refusal_message(&gemini, '5', "").contains("not aligned"));
        assert!(slew_refusal_message(&gemini, '1', "").contains("below the horizon"));
    }
}

#[cfg(test)]
mod meade_gw_tests {
    use super::*;

    /// `P` is an equatorially mounted scope (Meade protocol 2010.10), so
    /// `:GW#` tells tracking, never park.
    #[test]
    fn gw_reads_tracking_for_every_mount_letter() {
        assert_eq!(parse_meade_gw_tracking("PN1#"), Some(false));
        assert_eq!(parse_meade_gw_tracking("PT1#"), Some(true));
        assert_eq!(parse_meade_gw_tracking("AN0#"), Some(false));
        assert_eq!(parse_meade_gw_tracking("GT3#"), Some(true));
        assert_eq!(parse_meade_gw_tracking(""), None);
        assert_eq!(parse_meade_gw_tracking("1#"), None);
        assert_eq!(parse_meade_gw_tracking("PX1#"), None);
    }
}

/// LX200 reports longitude WEST-positive. Every other part of this app (and
/// ASCOM, and Alpaca) uses east-positive. Getting this backwards puts the site
/// on the wrong side of the planet and silently ruins pointing, so the
/// conversion lives in one named place with tests either side of it.
///
/// Classic Meade handsets count longitude 0-360 westward, so a site at 10 E
/// can come back as 350; the value is folded into -180..180 first.
pub(crate) fn lx200_longitude_to_east_positive(lx200_value: f64) -> f64 {
    let west = lx200_value.rem_euclid(360.0);
    if west > 180.0 {
        360.0 - west
    } else {
        -west
    }
}

pub(crate) fn east_positive_to_lx200_longitude(east_positive: f64) -> f64 {
    -east_positive
}

/// Format signed degrees as `sDD*MM:SS` (high precision) or `sDD*MM`.
/// `degree_width` is 2 for latitude, 3 for longitude, per the LX200 spec.
pub(crate) fn format_dms(value: f64, degree_width: usize, with_seconds: bool) -> String {
    let sign = sign_char(value);
    let magnitude = value.abs();

    // Without seconds the value is rounded to the minute it prints.
    let total_arcsec = if with_seconds {
        to_units(magnitude, 3600)
    } else {
        to_units(magnitude, 60) * 60
    };
    let (degrees, minutes, seconds) = split_units(total_arcsec, 3600);

    if with_seconds {
        format!(
            "{}{:0width$}*{:02}:{:02}",
            sign,
            degrees,
            minutes,
            seconds,
            width = degree_width
        )
    } else {
        format!(
            "{}{:0width$}*{:02}",
            sign,
            degrees,
            minutes,
            width = degree_width
        )
    }
}

/// Longitude for `:Sg` on Meade-protocol firmware: `DDD*MM`, unsigned,
/// counted 0-360 westward. The Meade command set defines no sign for this
/// field, and handsets that read it by position refuse `+075*24`.
pub(crate) fn format_meade_longitude(east_positive: f64) -> String {
    let west_arcmin =
        to_units(east_positive_to_lx200_longitude(east_positive), 60).rem_euclid(360 * 60);
    let (degrees, minutes, _) = split_units(west_arcmin, 60);
    format!("{:03}*{:02}", degrees, minutes)
}

/// LX200 `:GG#` answers the offset that must be ADDED to local time to reach
/// UTC — the negative of the usual UTC-offset sign. A site at UTC-5 answers
/// `+05`. Returned here in the ordinary sense (UTC-5 → -5.0).
pub(crate) fn parse_utc_offset(response: &str) -> Result<f64, DriverError> {
    let cleaned = response.trim().trim_end_matches('#').trim();
    if cleaned.is_empty() {
        return Err(DriverError::SdkError("Empty UTC offset".into()));
    }

    // Firmware disagrees about the shape. The spec says `sHH`, the Pegasus
    // NYX-101 answers `+05:00`, and half-hour zones show up as either `+05:30`
    // or `+05.5`. Parsing only the spec form made a real mount's clock
    // unreadable, so all three are accepted here.
    let (sign, magnitude) = split_sign(cleaned);

    let value = if let Some((hours_text, minutes_text)) = magnitude.split_once(':') {
        let hours: f64 = hours_text
            .trim()
            .parse()
            .map_err(|_| DriverError::SdkError(format!("Bad UTC offset {:?}", response)))?;
        let minutes: f64 = minutes_text
            .trim()
            .parse()
            .map_err(|_| DriverError::SdkError(format!("Bad UTC offset {:?}", response)))?;
        if !(0.0..60.0).contains(&minutes) {
            return Err(DriverError::SdkError(format!(
                "UTC offset minutes out of range: {:?}",
                response
            )));
        }
        sign * (hours + minutes / 60.0)
    } else {
        sign * magnitude
            .trim()
            .parse::<f64>()
            .map_err(|_| DriverError::SdkError(format!("Bad UTC offset {:?}", response)))?
    };

    if !(-14.0..=14.0).contains(&value) {
        return Err(DriverError::SdkError(format!(
            "UTC offset out of range: {:?}",
            response
        )));
    }
    Ok(-value)
}

/// Inverse of [`parse_utc_offset`]: ordinary offset in, LX200 wire value out.
/// Whole hours are `sHH` everywhere. A zone off the hour is `sHH.H` in the
/// Meade command set and `sHH:MM` on OnStep, which has no decimal form.
pub(crate) fn format_utc_offset(hours_east_of_utc: f64, mount_type: &Lx200MountType) -> String {
    let wire = -hours_east_of_utc;
    let sign = if wire < 0.0 { '-' } else { '+' };
    let wire_minutes = (wire.abs() * 60.0).round() as i64;
    if wire_minutes % 60 == 0 {
        format!("{}{:02}", sign, wire_minutes / 60)
    } else if mount_type.is_onstep() {
        format!("{}{:02}:{:02}", sign, wire_minutes / 60, wire_minutes % 60)
    } else {
        format!("{}{:04.1}", sign, wire.abs())
    }
}

/// Turn the mount's `MM/DD/YY` + `HH:MM:SS` local clock into a UTC instant.
/// 10Micron writes the date `MM:DD:YY` in its extended emulation and
/// `YYYY-MM-DD` in ultra precision; both are read too.
///
/// The two-digit year is read as 20YY. LX200 firmware predates the question and
/// no mount in service is reporting the 1900s; guessing a century by threshold
/// would silently place the mount 100 years off in exactly the cases where the
/// operator cannot see it.
pub(crate) fn parse_mount_local_datetime(
    date_text: &str,
    time_text: &str,
    utc_offset_hours: f64,
) -> Result<(i64, chrono::NaiveDateTime), DriverError> {
    let date_clean = date_text.trim().trim_end_matches('#').trim();
    let time_clean = time_text.trim().trim_end_matches('#').trim();

    let date_parts: Vec<&str> = date_clean
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .collect();
    if date_parts.len() != 3 {
        return Err(DriverError::SdkError(format!(
            "Bad mount date {:?} (want MM/DD/YY)",
            date_text
        )));
    }
    let field = |text: &str, what: &str| {
        text.parse::<u32>()
            .map_err(|_| DriverError::SdkError(format!("Bad {} in {:?}", what, date_text)))
    };
    let (year, month, day) = if date_parts[0].len() == 4 {
        (
            field(date_parts[0], "year")? as i32,
            field(date_parts[1], "month")?,
            field(date_parts[2], "day")?,
        )
    } else {
        (
            2000 + field(date_parts[2], "year")? as i32,
            field(date_parts[0], "month")?,
            field(date_parts[1], "day")?,
        )
    };

    let time_parts: Vec<&str> = time_clean.split(':').collect();
    if time_parts.len() < 2 {
        return Err(DriverError::SdkError(format!(
            "Bad mount time {:?} (want HH:MM:SS)",
            time_text
        )));
    }
    let hour: u32 = time_parts[0]
        .trim()
        .parse()
        .map_err(|_| DriverError::SdkError(format!("Bad hour in {:?}", time_text)))?;
    let minute: u32 = time_parts[1]
        .trim()
        .parse()
        .map_err(|_| DriverError::SdkError(format!("Bad minute in {:?}", time_text)))?;
    let second: u32 = match time_parts.get(2) {
        Some(value) => value
            .trim()
            .parse()
            .map_err(|_| DriverError::SdkError(format!("Bad second in {:?}", time_text)))?,
        None => 0,
    };

    let local = chrono::NaiveDate::from_ymd_opt(year, month, day)
        .and_then(|d| d.and_hms_opt(hour, minute, second))
        .ok_or_else(|| {
            DriverError::SdkError(format!(
                "Mount reported an impossible date/time {:?} {:?}",
                date_text, time_text
            ))
        })?;

    // local = utc + offset, so utc = local - offset.
    let offset_seconds = (utc_offset_hours * 3600.0).round() as i64;
    Ok((local.and_utc().timestamp() - offset_seconds, local))
}

/// Inverse of [`parse_mount_local_datetime`]: `(MM/DD/YY, HH:MM:SS)` in the
/// mount's own local time.
pub(crate) fn format_mount_local_datetime(
    utc_unix_seconds: i64,
    utc_offset_hours: f64,
) -> Result<(String, String), DriverError> {
    let offset_seconds = (utc_offset_hours * 3600.0).round() as i64;
    let local = chrono::DateTime::from_timestamp(utc_unix_seconds + offset_seconds, 0)
        .ok_or_else(|| {
            DriverError::SdkError(format!("Unrepresentable timestamp {}", utc_unix_seconds))
        })?
        .naive_utc();

    Ok((
        local.format("%m/%d/%y").to_string(),
        local.format("%H:%M:%S").to_string(),
    ))
}

#[cfg(test)]
mod clock_tests {
    use super::*;

    #[test]
    fn local_clock_converts_to_utc_using_the_offset() {
        // 2026-09-08 22:30:00 local at UTC-4 is 2026-09-09 02:30:00 UTC.
        let (utc, local) =
            parse_mount_local_datetime("09/08/26#", "22:30:00#", -4.0).expect("parse");
        assert_eq!(
            local.format("%Y-%m-%d %H:%M:%S").to_string(),
            "2026-09-08 22:30:00"
        );
        let as_utc = chrono::DateTime::from_timestamp(utc, 0).unwrap();
        assert_eq!(
            as_utc.format("%Y-%m-%d %H:%M:%S").to_string(),
            "2026-09-09 02:30:00"
        );
    }

    #[test]
    fn round_trips_through_the_formatter() {
        for offset in [-8.0_f64, -4.0, 0.0, 5.5, 10.0] {
            let (utc, _) =
                parse_mount_local_datetime("03/07/26#", "01:02:03#", offset).expect("parse");
            let (date, time) = format_mount_local_datetime(utc, offset).expect("format");
            assert_eq!(date, "03/07/26", "offset {}", offset);
            assert_eq!(time, "01:02:03", "offset {}", offset);
        }
    }

    #[test]
    fn refuses_impossible_dates_rather_than_wrapping_them() {
        assert!(parse_mount_local_datetime("13/01/26#", "00:00:00#", 0.0).is_err());
        assert!(parse_mount_local_datetime("02/30/26#", "00:00:00#", 0.0).is_err());
        assert!(parse_mount_local_datetime("09/08/26#", "25:00:00#", 0.0).is_err());
        assert!(parse_mount_local_datetime("nonsense", "00:00:00#", 0.0).is_err());
    }

    #[test]
    fn tenmicron_date_shapes_are_read() {
        for date in ["09:08:26#", "2026-09-08#"] {
            let (_, local) = parse_mount_local_datetime(date, "22:30:00#", 0.0)
                .unwrap_or_else(|e| panic!("{date}: {e}"));
            assert_eq!(local.format("%Y-%m-%d").to_string(), "2026-09-08", "{date}");
        }
    }

    #[test]
    fn two_digit_year_reads_as_this_century() {
        let (_, local) = parse_mount_local_datetime("01/01/26#", "00:00:00#", 0.0).unwrap();
        assert_eq!(local.format("%Y").to_string(), "2026");
    }
}

#[cfg(test)]
mod site_tests {
    use super::*;

    #[test]
    fn longitude_conversion_is_symmetric_and_flips_the_hemisphere() {
        // The rig's site: 75.397448 degrees WEST.
        let east_positive = -75.397448;
        let wire = east_positive_to_lx200_longitude(east_positive);
        assert!(wire > 0.0, "LX200 wants west-positive, got {}", wire);
        assert!((lx200_longitude_to_east_positive(wire) - east_positive).abs() < 1e-9);
    }

    #[test]
    fn parses_the_shapes_lx200_firmware_actually_sends() {
        assert!((parse_sexagesimal("+40*00#").unwrap() - 40.0).abs() < 1e-9);
        assert!((parse_sexagesimal("-33*52:11#").unwrap() + 33.869722).abs() < 1e-5);
        assert!((parse_sexagesimal("075*23#").unwrap() - 75.383333).abs() < 1e-5);
        // High-precision firmware substitutes the degree glyph for '*'.
        assert!((parse_sexagesimal("+40\u{00df}00:28#").unwrap() - 40.007778).abs() < 1e-5);
    }

    #[test]
    fn rejects_nonsense_rather_than_guessing_a_site() {
        assert!(parse_sexagesimal("").is_err());
        assert!(parse_sexagesimal("#").is_err());
        assert!(
            parse_sexagesimal("+40*99#").is_err(),
            "99 arcminutes is not a site"
        );
        assert!(parse_sexagesimal("garbage#").is_err());
    }

    #[test]
    fn formats_round_trip_through_the_parser() {
        for value in [40.007714_f64, -33.869722, 0.0, -0.5, 89.9999] {
            let text = format_dms(value, 2, true);
            let parsed = parse_sexagesimal(&text).unwrap();
            assert!(
                (parsed - value).abs() < 1.0 / 3600.0,
                "{} formatted as {} parsed back as {}",
                value,
                text,
                parsed
            );
        }
    }

    #[test]
    fn rounding_never_emits_sixty_minutes() {
        // 40.9999 deg is 40 deg 59.994 min: rounding the minutes field alone
        // would print 40*60, which the mount rejects.
        let text = format_dms(40.99999, 2, false);
        assert_eq!(text, "+41*00", "got {}", text);
        let text = format_dms(-40.99999, 2, false);
        assert_eq!(text, "-41*00", "got {}", text);
    }

    #[test]
    fn goto_targets_never_emit_sixty_seconds() {
        // 0.1 s short of 01:00:00; splitting first and rounding the seconds
        // printed 00:59:60, which firmware that validates the field refuses.
        let high = CoordinatePrecision::High;
        assert_eq!(format_ra(1.0 - 0.1 / 3600.0, high), "01:00:00");
        assert_eq!(format_ra(24.0 - 0.1 / 3600.0, high), "00:00:00");
        assert_eq!(format_dec(10.0 - 0.1 / 3600.0, high), "+10*00:00");
        assert_eq!(format_dec(-(10.0 - 0.1 / 3600.0), high), "-10*00:00");
        assert_eq!(format_ra(5.5, high), "05:30:00");
        assert_eq!(format_dec(-33.869722, high), "-33*52:11");
    }

    /// Firmware reads `sDD` by position. `+5*00:00` was refused by OnStep
    /// and Meade alike, so every goto and sync within 10 degrees of the
    /// celestial equator failed.
    #[test]
    fn declination_degrees_are_always_two_digits() {
        let high = CoordinatePrecision::High;
        assert_eq!(format_dec(5.0, high), "+05*00:00");
        assert_eq!(format_dec(-0.5, high), "-00*30:00");
        assert_eq!(format_dec(0.0, high), "+00*00:00");
        assert_eq!(format_dec(-9.999999, high), "-10*00:00");
        assert_eq!(format_dec(89.5, high), "+89*30:00");
    }

    #[test]
    fn low_precision_targets_are_tenths_of_a_minute_and_whole_arcminutes() {
        let low = CoordinatePrecision::Low;
        assert_eq!(format_ra(5.5, low), "05:30.0");
        assert_eq!(format_ra(5.5123, low), "05:30.7");
        assert_eq!(format_ra(24.0 - 1.0 / 3600.0, low), "00:00.0");
        assert_eq!(format_dec(-20.2512, low), "-20*15");
        assert_eq!(format_dec(5.0, low), "+05*00");
        assert_eq!(format_dec(40.99999, low), "+41*00");
    }

    #[test]
    fn precision_is_read_from_the_shape_of_the_ra_reply() {
        assert_eq!(
            CoordinatePrecision::of_ra_reply("05:30.0"),
            CoordinatePrecision::Low
        );
        assert_eq!(
            CoordinatePrecision::of_ra_reply("05:30:00"),
            CoordinatePrecision::High
        );
        // 10Micron ultra precision.
        assert_eq!(
            CoordinatePrecision::of_ra_reply("05:30:00.00"),
            CoordinatePrecision::High
        );
    }

    /// Meade high precision separates arc seconds with an apostrophe and
    /// Autostar writes byte 0xDF for the degree sign, which the reader turns
    /// into U+FFFD. Both failed to parse, so a Meade mount in high precision
    /// could not report where it pointed.
    #[test]
    fn coordinates_parse_with_every_separator_firmware_sends() {
        let close = |text: &str, want: f64| {
            let got = parse_sexagesimal(text).unwrap_or_else(|e| panic!("{text:?}: {e}"));
            assert!(
                (got - want).abs() < 1e-6,
                "{text:?} read as {got}, want {want}"
            );
        };
        close("+20*30'36#", 20.51);
        close("-05*30'00#", -5.5);
        close(&String::from_utf8_lossy(b"+20\xdf30:36#"), 20.51);
        close(&String::from_utf8_lossy(b"+40\xdf00#"), 40.0);
        close("180*15'00#", 180.25);
        close("05:30:00#", 5.5);
        close("05:30.5#", 5.0 + 30.5 / 60.0);
        close("+20:30:36.0#", 20.51);
        close("05:30:00.00#", 5.5);
    }

    /// Half-hour zones: the Meade command set has `sHH.H`, OnStep `sHH:MM`.
    #[test]
    fn a_zone_off_the_hour_is_written_the_way_each_firmware_reads_it() {
        assert_eq!(format_utc_offset(5.5, &Lx200MountType::Meade), "-05.5");
        assert_eq!(format_utc_offset(5.5, &Lx200MountType::OnStep), "-05:30");
        assert_eq!(format_utc_offset(-9.5, &Lx200MountType::OnStep), "+09:30");
        assert_eq!(format_utc_offset(5.75, &Lx200MountType::OnStep), "-05:45");
        assert_eq!(format_utc_offset(-4.0, &Lx200MountType::OnStep), "+04");
    }

    /// `:Sg` in the Meade command set is an unsigned `DDD*MM` counted
    /// westward; a sign in front was refused.
    #[test]
    fn meade_longitude_is_unsigned_and_westward() {
        assert_eq!(format_meade_longitude(-75.397448), "075*24");
        assert_eq!(format_meade_longitude(10.0), "350*00");
        assert_eq!(format_meade_longitude(0.0), "000*00");
        assert_eq!(format_meade_longitude(-179.9999), "180*00");
    }

    #[test]
    fn a_westward_0_to_360_longitude_reads_back_east_positive() {
        assert!((lx200_longitude_to_east_positive(350.0) - 10.0).abs() < 1e-9);
        assert!((lx200_longitude_to_east_positive(75.5) + 75.5).abs() < 1e-9);
        assert!((lx200_longitude_to_east_positive(-10.0) - 10.0).abs() < 1e-9);
        assert!((lx200_longitude_to_east_positive(180.0) + 180.0).abs() < 1e-9);
    }

    #[test]
    fn longitude_is_three_digits_wide() {
        assert_eq!(format_dms(75.383333, 3, false), "+075*23");
        assert_eq!(format_dms(5.5, 3, false), "+005*30");
    }

    #[test]
    fn utc_offset_accepts_the_shapes_real_firmware_sends() {
        // The Pegasus NYX-101 answers `:GG#` with `+05:00`, not the spec's
        // `+05`. Parsing only the spec form made its clock unreadable.
        assert!((parse_utc_offset("+05:00#").unwrap() + 5.0).abs() < 1e-9);
        assert!((parse_utc_offset("+05#").unwrap() + 5.0).abs() < 1e-9);
        // Half-hour zones, both spellings.
        assert!((parse_utc_offset("-05:30#").unwrap() - 5.5).abs() < 1e-9);
        assert!((parse_utc_offset("-05.5#").unwrap() - 5.5).abs() < 1e-9);
        // Still nonsense-proof.
        assert!(parse_utc_offset("+05:99#").is_err());
        assert!(parse_utc_offset("").is_err());
        assert!(parse_utc_offset("banana#").is_err());
    }

    #[test]
    fn utc_offset_sign_matches_the_lx200_convention() {
        // US Eastern Standard Time is UTC-5; the mount is told "+05".
        let meade = Lx200MountType::Meade;
        assert_eq!(format_utc_offset(-5.0, &meade), "+05");
        assert!((parse_utc_offset("+05#").unwrap() + 5.0).abs() < 1e-9);
        // And the other hemisphere: UTC+10 is sent as "-10".
        assert_eq!(format_utc_offset(10.0, &meade), "-10");
        assert!((parse_utc_offset("-10#").unwrap() - 10.0).abs() < 1e-9);
        assert!(parse_utc_offset("+99#").is_err());
    }
}
