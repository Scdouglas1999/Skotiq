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
    pub const UNPARK_MEADE: &str = ":PO#";

    // OnStep-specific commands (used by Pegasus NYX, DIY OnStep mounts)
    pub const ONSTEP_GET_STATUS: &str = ":GU#";
    pub const ONSTEP_TRACK_ENABLE: &str = ":Te#";
    pub const ONSTEP_TRACK_DISABLE: &str = ":Td#";
    pub const ONSTEP_UNPARK: &str = ":hR#";
    pub const ONSTEP_FIND_HOME: &str = ":hF#";
    pub const ONSTEP_SET_PARK: &str = ":hQ#";

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
    pub fn vendor(&self) -> NativeVendor {
        match self {
            Lx200MountType::Meade => NativeVendor::Meade,
            Lx200MountType::OnStep => NativeVendor::Other("Pegasus/OnStep".to_string()),
            Lx200MountType::Losmandy | Lx200MountType::TenMicron | Lx200MountType::Generic => {
                NativeVendor::Other("LX200".to_string())
            }
        }
    }

    /// Check if this mount type uses OnStep command extensions
    pub fn is_onstep(&self) -> bool {
        matches!(self, Lx200MountType::OnStep)
    }
}

pub(crate) fn parse_ra(response: &str) -> Result<f64, NativeError> {
    let s = response.trim_end_matches('#');

    if let Some((h, rest)) = s.split_once(':') {
        let hours: f64 = h
            .parse()
            .map_err(|_| NativeError::SdkError("Invalid RA hours".into()))?;

        if let Some((m, sec)) = rest.split_once(':') {
            let minutes: f64 = m
                .parse()
                .map_err(|_| NativeError::SdkError("Invalid RA minutes".into()))?;
            let seconds: f64 = sec
                .parse()
                .map_err(|_| NativeError::SdkError("Invalid RA seconds".into()))?;
            return Ok(from_parts(hours, minutes, seconds));
        } else if let Some((m, t)) = rest.split_once('.') {
            let minutes: f64 = m
                .parse()
                .map_err(|_| NativeError::SdkError("Invalid RA minutes".into()))?;
            let tenths: f64 = t
                .parse()
                .map_err(|_| NativeError::SdkError("Invalid RA tenths".into()))?;
            return Ok(from_parts(hours, minutes + tenths / 10.0, 0.0));
        }
    }

    Err(NativeError::SdkError(format!("Invalid RA format: {}", s)))
}

pub(crate) fn parse_dec(response: &str) -> Result<f64, NativeError> {
    let s = response.trim_end_matches('#');

    let (sign, rest) = split_sign(s);

    let parts: Vec<&str> = rest.split(['*', '°', ':']).collect();

    if parts.len() >= 2 {
        let degrees: f64 = parts[0]
            .parse()
            .map_err(|_| NativeError::SdkError("Invalid Dec degrees".into()))?;
        let arcmin: f64 = parts[1]
            .parse()
            .map_err(|_| NativeError::SdkError("Invalid Dec arcmin".into()))?;

        let arcsec: f64 = if parts.len() >= 3 {
            parts[2]
                .parse()
                .map_err(|_| NativeError::SdkError("Invalid Dec arcsec".into()))?
        } else {
            0.0
        };

        return Ok(sign * from_parts(degrees, arcmin, arcsec));
    }

    Err(NativeError::SdkError(format!("Invalid Dec format: {}", s)))
}

pub(crate) fn format_ra(ra_hours: f64) -> String {
    let total_seconds = to_units(ra_hours, 3600).rem_euclid(24 * 3600);
    let (hours, minutes, seconds) = split_units(total_seconds, 3600);

    format!("{:02}:{:02}:{:02}", hours, minutes, seconds)
}

pub(crate) fn format_dec(dec_degrees: f64) -> String {
    let total_arcsec = to_units(dec_degrees.abs(), 3600);
    let (degrees, arcmin, arcsec) = split_units(total_arcsec, 3600);

    format!(
        "{}{}*{:02}:{:02}",
        sign_char(dec_degrees),
        degrees,
        arcmin,
        arcsec
    )
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
pub(crate) fn read_persisted_park_state(device_id: &str) -> Result<Option<bool>, NativeError> {
    let path = lx200_state_file_path();
    if !path.exists() {
        return Ok(None);
    }

    let raw = std::fs::read_to_string(&path).map_err(|e| {
        NativeError::Io(std::io::Error::new(
            e.kind(),
            format!("read park state: {}", e),
        ))
    })?;
    let map: HashMap<String, bool> = serde_json::from_str(&raw)
        .map_err(|e| NativeError::SdkError(format!("parse park state JSON: {}", e)))?;
    Ok(map.get(device_id).copied())
}

/// Atomically update the persisted park state for one device.
///
/// We re-read the full map, mutate the single entry, then write the whole
/// file back. The file is small (one bool per mount the user owns) so the
/// rewrite cost is negligible compared to a serial command round-trip.
pub(crate) fn write_persisted_park_state(device_id: &str, parked: bool) -> Result<(), NativeError> {
    let path = lx200_state_file_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            NativeError::Io(std::io::Error::new(
                e.kind(),
                format!("create park state dir {:?}: {}", parent, e),
            ))
        })?;
    }

    let mut map: HashMap<String, bool> = if path.exists() {
        let raw = std::fs::read_to_string(&path).map_err(|e| {
            NativeError::Io(std::io::Error::new(
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
                .map_err(|e| NativeError::SdkError(format!("parse park state JSON: {}", e)))?
        }
    } else {
        HashMap::new()
    };

    map.insert(device_id.to_string(), parked);

    let serialized = serde_json::to_string_pretty(&map)
        .map_err(|e| NativeError::SdkError(format!("serialize park state: {}", e)))?;
    std::fs::write(&path, serialized).map_err(|e| {
        NativeError::Io(std::io::Error::new(
            e.kind(),
            format!("write park state: {}", e),
        ))
    })?;
    Ok(())
}

/// Parse a Meade `:GW#` response. Returns `Some(true)` if the firmware
/// reports parked, `Some(false)` if it reports a non-parked alignment mode,
/// and `None` if the response shape is unrecognised (older LX200 firmware,
/// echo-only stub, garbage). The caller treats `None` as "no telemetry".
///
/// Meade Telescope Serial Command Protocol rev L (LX200GPS / LX200ACF /
/// RCX400) defines position 0 as the alignment mode: `A` Alt-Az,
/// `P` Polar/Parked, `L` Land, `G` German equatorial. On parked firmware,
/// `P` in position 0 with `T`/`N` tracking-off in position 1 is the parked
/// signal. On Polar-aligned-but-tracking firmware, `P` appears with `T`
/// tracking on; we disambiguate using position 1 `N` (not tracking) plus
/// position 2 == `0` (no alignment progress, mount idle).
pub(crate) fn parse_meade_gw_park(response: &str) -> Option<bool> {
    let s = response.trim().trim_end_matches('#');
    let bytes = s.as_bytes();
    if bytes.is_empty() {
        return None;
    }

    // Position 0 must be a recognised alignment mode for us to trust the
    // response at all. If the byte is something else we do not know what
    // firmware variant this is, so we return None (NotSupported upstream).
    let mode = bytes[0];
    if !matches!(mode, b'A' | b'P' | b'L' | b'G') {
        return None;
    }

    // If position 1 exists, it should be tracking on/off. Anything else =
    // unknown firmware shape.
    let tracking = bytes.get(1).copied();
    match tracking {
        Some(b'T') => Some(false), // tracking on → not parked
        Some(b'N') => {
            // Tracking off + Polar-mode position 0 == parked on the Meade
            // firmwares that report park via :GW#. On other firmwares we
            // see N with non-P mode (e.g., AN0# = Alt-Az, not tracking,
            // not aligned) — that is "idle but not parked".
            Some(mode == b'P')
        }
        Some(_) => None,
        None => None,
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

/// Codes 1 and 2 are the classic Meade LX200 refusals; 3-9 are OnStep's
/// extensions (MountGoto.cpp). A Meade-only firmware never sends 3-9, so
/// reading them with OnStep's meanings costs nothing and names the real
/// reason on the mounts that do.
pub(crate) fn slew_refusal_message(code: char, message: &str) -> String {
    let reason = match code {
        '1' => "target is below the horizon".to_string(),
        '2' => "target is below the altitude limit".to_string(),
        '3' => "mount is in standby".to_string(),
        '4' => "mount is parked".to_string(),
        '5' => "a goto is already in progress".to_string(),
        '6' => "target is outside the mount's limits".to_string(),
        '7' => "mount reported a hardware fault".to_string(),
        '8' => "mount is already in motion".to_string(),
        '9' => "mount refused the goto (unspecified error)".to_string(),
        other => format!("mount refused the goto with status {}", other),
    };

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
        assert!(slew_refusal_message('4', "").contains("parked"));
        assert!(slew_refusal_message('7', "").contains("hardware fault"));
        assert!(slew_refusal_message('1', "Below horizon").contains("Below horizon"));
        assert!(slew_refusal_message('x', "").contains("status x"));
    }
}

/// Site coordinates and clock as the mount holds them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountSite {
    /// Degrees north of the equator, negative south. Ordinary signed latitude.
    pub latitude_deg: f64,
    /// Degrees EAST of Greenwich, negative west — the convention the rest of
    /// this app uses. The LX200 wire format is the opposite; see
    /// [`format_lx200_longitude`].
    pub longitude_deg: f64,
}

/// LX200 reports longitude WEST-positive. Every other part of this app (and
/// ASCOM, and Alpaca) uses east-positive. Getting this backwards puts the site
/// on the wrong side of the planet and silently ruins pointing, so the
/// conversion lives in one named place with tests either side of it.
pub(crate) fn lx200_longitude_to_east_positive(lx200_value: f64) -> f64 {
    -lx200_value
}

pub(crate) fn east_positive_to_lx200_longitude(east_positive: f64) -> f64 {
    -east_positive
}

/// Parse `sDD*MM#`, `sDD*MM:SS#` or `sDDD*MM:SS#` into signed degrees.
pub(crate) fn parse_dms(response: &str) -> Result<f64, NativeError> {
    let cleaned = response.trim().trim_end_matches('#').trim();
    if cleaned.is_empty() {
        return Err(NativeError::SdkError("Empty DMS response".into()));
    }

    let (sign, rest) = split_sign(cleaned);

    // Degrees are separated from minutes by `*` (or `\xdf`, the degree sign
    // some firmware emits in high-precision mode).
    let rest: String = rest
        .chars()
        .map(|c| {
            if matches!(c, '\u{00df}' | '\u{00b0}') {
                '*'
            } else {
                c
            }
        })
        .collect();
    let mut parts = rest.split(['*', ':']);

    let degrees: f64 = parts
        .next()
        .ok_or_else(|| NativeError::SdkError("DMS missing degrees".into()))?
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad DMS degrees in {:?}", response)))?;
    let minutes: f64 = match parts.next() {
        Some(m) if !m.trim().is_empty() => m
            .trim()
            .parse()
            .map_err(|_| NativeError::SdkError(format!("Bad DMS minutes in {:?}", response)))?,
        _ => 0.0,
    };
    let seconds: f64 = match parts.next() {
        Some(s) if !s.trim().is_empty() => s
            .trim()
            .parse()
            .map_err(|_| NativeError::SdkError(format!("Bad DMS seconds in {:?}", response)))?,
        _ => 0.0,
    };

    if !(0.0..60.0).contains(&minutes) || !(0.0..60.0).contains(&seconds) {
        return Err(NativeError::SdkError(format!(
            "DMS minutes/seconds out of range in {:?}",
            response
        )));
    }

    Ok(sign * from_parts(degrees, minutes, seconds))
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

/// LX200 `:GG#` answers the offset that must be ADDED to local time to reach
/// UTC — the negative of the usual UTC-offset sign. A site at UTC-5 answers
/// `+05`. Returned here in the ordinary sense (UTC-5 → -5.0).
pub(crate) fn parse_utc_offset(response: &str) -> Result<f64, NativeError> {
    let cleaned = response.trim().trim_end_matches('#').trim();
    if cleaned.is_empty() {
        return Err(NativeError::SdkError("Empty UTC offset".into()));
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
            .map_err(|_| NativeError::SdkError(format!("Bad UTC offset {:?}", response)))?;
        let minutes: f64 = minutes_text
            .trim()
            .parse()
            .map_err(|_| NativeError::SdkError(format!("Bad UTC offset {:?}", response)))?;
        if !(0.0..60.0).contains(&minutes) {
            return Err(NativeError::SdkError(format!(
                "UTC offset minutes out of range: {:?}",
                response
            )));
        }
        sign * (hours + minutes / 60.0)
    } else {
        sign * magnitude
            .trim()
            .parse::<f64>()
            .map_err(|_| NativeError::SdkError(format!("Bad UTC offset {:?}", response)))?
    };

    if !(-14.0..=14.0).contains(&value) {
        return Err(NativeError::SdkError(format!(
            "UTC offset out of range: {:?}",
            response
        )));
    }
    Ok(-value)
}

/// Inverse of [`parse_utc_offset`]: ordinary offset in, LX200 wire value out.
pub(crate) fn format_utc_offset(hours_east_of_utc: f64) -> String {
    let wire = -hours_east_of_utc;
    if (wire - wire.round()).abs() < 0.01 {
        format!(
            "{}{:02}",
            if wire < 0.0 { '-' } else { '+' },
            wire.abs() as i64
        )
    } else {
        format!("{}{:04.1}", if wire < 0.0 { '-' } else { '+' }, wire.abs())
    }
}

/// Turn the mount's `MM/DD/YY` + `HH:MM:SS` local clock into a UTC instant.
///
/// The two-digit year is read as 20YY. LX200 firmware predates the question and
/// no mount in service is reporting the 1900s; guessing a century by threshold
/// would silently place the mount 100 years off in exactly the cases where the
/// operator cannot see it.
pub(crate) fn parse_mount_local_datetime(
    date_text: &str,
    time_text: &str,
    utc_offset_hours: f64,
) -> Result<(i64, chrono::NaiveDateTime), NativeError> {
    let date_clean = date_text.trim().trim_end_matches('#').trim();
    let time_clean = time_text.trim().trim_end_matches('#').trim();

    let date_parts: Vec<&str> = date_clean.split('/').collect();
    if date_parts.len() != 3 {
        return Err(NativeError::SdkError(format!(
            "Bad mount date {:?} (want MM/DD/YY)",
            date_text
        )));
    }
    let month: u32 = date_parts[0]
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad month in {:?}", date_text)))?;
    let day: u32 = date_parts[1]
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad day in {:?}", date_text)))?;
    let year_2digit: i32 = date_parts[2]
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad year in {:?}", date_text)))?;

    let time_parts: Vec<&str> = time_clean.split(':').collect();
    if time_parts.len() < 2 {
        return Err(NativeError::SdkError(format!(
            "Bad mount time {:?} (want HH:MM:SS)",
            time_text
        )));
    }
    let hour: u32 = time_parts[0]
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad hour in {:?}", time_text)))?;
    let minute: u32 = time_parts[1]
        .trim()
        .parse()
        .map_err(|_| NativeError::SdkError(format!("Bad minute in {:?}", time_text)))?;
    let second: u32 = match time_parts.get(2) {
        Some(value) => value
            .trim()
            .parse()
            .map_err(|_| NativeError::SdkError(format!("Bad second in {:?}", time_text)))?,
        None => 0,
    };

    let local = chrono::NaiveDate::from_ymd_opt(2000 + year_2digit, month, day)
        .and_then(|d| d.and_hms_opt(hour, minute, second))
        .ok_or_else(|| {
            NativeError::SdkError(format!(
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
) -> Result<(String, String), NativeError> {
    let offset_seconds = (utc_offset_hours * 3600.0).round() as i64;
    let local = chrono::DateTime::from_timestamp(utc_unix_seconds + offset_seconds, 0)
        .ok_or_else(|| {
            NativeError::SdkError(format!("Unrepresentable timestamp {}", utc_unix_seconds))
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
        assert!((parse_dms("+40*00#").unwrap() - 40.0).abs() < 1e-9);
        assert!((parse_dms("-33*52:11#").unwrap() + 33.869722).abs() < 1e-5);
        assert!((parse_dms("075*23#").unwrap() - 75.383333).abs() < 1e-5);
        // High-precision firmware substitutes the degree glyph for '*'.
        assert!((parse_dms("+40\u{00df}00:28#").unwrap() - 40.007778).abs() < 1e-5);
    }

    #[test]
    fn rejects_nonsense_rather_than_guessing_a_site() {
        assert!(parse_dms("").is_err());
        assert!(parse_dms("#").is_err());
        assert!(parse_dms("+40*99#").is_err(), "99 arcminutes is not a site");
        assert!(parse_dms("garbage#").is_err());
    }

    #[test]
    fn formats_round_trip_through_the_parser() {
        for value in [40.007714_f64, -33.869722, 0.0, -0.5, 89.9999] {
            let text = format_dms(value, 2, true);
            let parsed = parse_dms(&text).unwrap();
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
        assert_eq!(format_ra(1.0 - 0.1 / 3600.0), "01:00:00");
        assert_eq!(format_ra(24.0 - 0.1 / 3600.0), "00:00:00");
        assert_eq!(format_dec(10.0 - 0.1 / 3600.0), "+10*00:00");
        assert_eq!(format_dec(-(10.0 - 0.1 / 3600.0)), "-10*00:00");
        assert_eq!(format_ra(5.5), "05:30:00");
        assert_eq!(format_dec(-33.869722), "-33*52:11");
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
        assert_eq!(format_utc_offset(-5.0), "+05");
        assert!((parse_utc_offset("+05#").unwrap() + 5.0).abs() < 1e-9);
        // And the other hemisphere: UTC+10 is sent as "-10".
        assert_eq!(format_utc_offset(10.0), "-10");
        assert!((parse_utc_offset("-10#").unwrap() - 10.0).abs() < 1e-9);
        assert!(parse_utc_offset("+99#").is_err());
    }
}
