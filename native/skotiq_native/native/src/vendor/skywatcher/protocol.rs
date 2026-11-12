//! The Sky-Watcher motor controller command set: how a command and its reply
//! are written and what a reply says.
//!
//! A command is `:`, a letter, the axis (`1` RA, `2` Dec) and optional hex
//! data, ended by CR. The controller answers `=` and hex data, or `!` and an
//! error digit, ended by CR. Numbers of 24 bits go low byte first.

use skotiq_device::DriverError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Axis {
    Ra,
    Dec,
}

impl Axis {
    pub(super) const BOTH: [Axis; 2] = [Axis::Ra, Axis::Dec];

    pub(super) fn digit(self) -> char {
        match self {
            Axis::Ra => '1',
            Axis::Dec => '2',
        }
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Axis::Ra => "RA",
            Axis::Dec => "Dec",
        }
    }
}

pub(super) mod command {
    pub const INITIALIZE: char = 'F';
    pub const MOTOR_BOARD_VERSION: char = 'e';
    pub const COUNTS_PER_REVOLUTION: char = 'a';
    pub const TIMER_FREQUENCY: char = 'b';
    pub const POSITION: char = 'j';
    pub const STATUS: char = 'f';
    pub const SET_POSITION: char = 'E';
    pub const SET_MOTION_MODE: char = 'G';
    pub const SET_STEP_PERIOD: char = 'I';
    pub const SET_GOTO_INCREMENT: char = 'H';
    pub const SET_BREAK_INCREMENT: char = 'M';
    pub const START: char = 'J';
    /// Stops with the deceleration ramp.
    pub const STOP: char = 'K';
}

pub(super) fn command_text(letter: char, axis: Axis, data: &str) -> String {
    format!(":{letter}{}{data}", axis.digit())
}

pub(super) fn encode_u24(value: u32) -> String {
    format!(
        "{:02X}{:02X}{:02X}",
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF
    )
}

pub(super) fn decode_u24(payload: &str) -> Result<u32, DriverError> {
    let bytes = hex_bytes(payload, 3)?;
    Ok(u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16))
}

fn hex_bytes(payload: &str, count: usize) -> Result<Vec<u8>, DriverError> {
    let wanted = count * 2;
    if payload.len() < wanted || !payload.is_char_boundary(wanted) {
        return Err(DriverError::SdkError(format!(
            "Sky-Watcher reply {payload:?} is shorter than {wanted} hex digits"
        )));
    }
    (0..count)
        .map(|i| {
            u8::from_str_radix(&payload[i * 2..i * 2 + 2], 16).map_err(|_| {
                DriverError::SdkError(format!("Sky-Watcher reply {payload:?} is not hex"))
            })
        })
        .collect()
}

/// What one line from the controller is.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ReplyLine {
    Data(String),
    Refused(char),
    /// Not a reply: an echo of the command (the old DC-motor controllers
    /// echo what they receive), line noise, or a garbled reply.
    Other,
}

pub(super) fn classify_reply(line: &str) -> ReplyLine {
    if let Some(data) = line.strip_prefix('=') {
        if data
            .chars()
            .all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c))
        {
            return ReplyLine::Data(data.to_string());
        }
        return ReplyLine::Other;
    }
    if let Some(code) = line.strip_prefix('!') {
        return ReplyLine::Refused(code.chars().next().unwrap_or('?'));
    }
    ReplyLine::Other
}

/// The controller's error digits, from the Sky-Watcher motor controller
/// command set.
pub(super) fn refusal_meaning(code: char) -> &'static str {
    match code {
        '0' => "unknown command",
        '1' => "command length error",
        '2' => "motor not stopped",
        '3' => "invalid character",
        '4' => "not initialized",
        '5' => "driver sleeping",
        '7' => "PEC training is running",
        '8' => "no valid PEC data",
        _ => "unrecognized error",
    }
}

/// One axis as `:f` reports it: three hex digits, most significant first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct AxisStatus {
    /// Constant-rate motion (tracking, guiding, manual moves) rather than a
    /// goto.
    pub constant_rate: bool,
    pub backward: bool,
    pub high_speed: bool,
    pub running: bool,
    pub initialized: bool,
}

impl AxisStatus {
    pub(super) fn parse(payload: &str) -> Result<Self, DriverError> {
        let digits: Vec<u32> = payload.chars().filter_map(|c| c.to_digit(16)).collect();
        if digits.len() < 3 {
            return Err(DriverError::SdkError(format!(
                "Sky-Watcher status reply {payload:?} is not three hex digits"
            )));
        }
        Ok(Self {
            constant_rate: digits[0] & 0x1 != 0,
            backward: digits[0] & 0x2 != 0,
            high_speed: digits[0] & 0x4 != 0,
            running: digits[1] & 0x1 != 0,
            initialized: digits[2] & 0x1 != 0,
        })
    }

    pub(super) fn in_goto(&self) -> bool {
        self.running && !self.constant_rate
    }

    pub(super) fn tracking_like(&self) -> bool {
        self.running && self.constant_rate
    }
}

/// The `:G` data: what kind of motion the next `:J` starts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct MotionMode {
    pub goto: bool,
    pub high_speed: bool,
    pub forward: bool,
}

impl MotionMode {
    pub(super) fn data(&self) -> String {
        let kind = match (self.goto, self.high_speed) {
            (true, true) => '0',
            (false, false) => '1',
            (true, false) => '2',
            (false, true) => '3',
        };
        let direction = if self.forward { '0' } else { '1' };
        format!("{kind}{direction}")
    }

    /// Whether a running axis in `status` is already moving this way, so a
    /// new step period is all a rate change needs.
    pub(super) fn matches(&self, status: &AxisStatus) -> bool {
        self.goto != status.constant_rate
            && self.high_speed == status.high_speed
            && self.forward != status.backward
    }
}

/// The controller as `:e` describes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct BoardVersion {
    pub major: u8,
    pub minor: u8,
    pub mount_code: u8,
}

impl BoardVersion {
    /// `:e` answers with the major version, the minor version and the mount
    /// code as three bytes, in that order.
    pub(super) fn parse(payload: &str) -> Result<Self, DriverError> {
        let bytes = hex_bytes(payload, 3)?;
        Ok(Self {
            major: bytes[0],
            minor: bytes[1],
            mount_code: bytes[2],
        })
    }

    /// The whole version as one number (`0x030700` for 3.07 on an EQ6),
    /// for the firmware quirks that are keyed on it.
    pub(super) fn number(&self) -> u32 {
        (u32::from(self.major) << 16) | (u32::from(self.minor) << 8) | u32::from(self.mount_code)
    }

    /// Mount names by code, as indi-eqmod lists them.
    pub(super) fn model(&self) -> &'static str {
        match self.mount_code {
            0x00 => "EQ6",
            0x01 => "HEQ5",
            0x02 => "EQ5",
            0x03 => "EQ3",
            0x04 => "EQ8",
            0x05 => "AZ-EQ6",
            0x06 => "AZ-EQ5",
            0x0A => "Star Adventurer",
            0x0C => "Star Adventurer GTi",
            0x20 => "EQ8-R Pro",
            0x22 => "AZ-EQ6 Pro",
            0x23 => "EQ6-R Pro",
            0x24 => "EQ6 Pro",
            0x25 => "CQ350 Pro",
            0x31 => "EQ5 Pro",
            0x44 => "Wave 100i",
            0x45 => "Wave 150i",
            0x80 => "GT",
            0x81 => "MF",
            0x82 => "114GT",
            0x90 => "Dobsonian",
            0xA5 => "AZ-GTi",
            _ => "mount",
        }
    }

    /// indi-eqmod refuses these: alt-azimuth GoTo bases with no equatorial
    /// mode.
    pub(super) fn is_alt_azimuth_only(&self) -> bool {
        matches!(self.mount_code, 0x80 | 0x81 | 0x90)
    }

    pub(super) fn describe(&self) -> String {
        format!(
            "Sky-Watcher {}, motor controller firmware {}.{:02}",
            self.model(),
            self.major,
            self.minor
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_go_low_byte_first() {
        assert_eq!(encode_u24(0x800000), "000080");
        assert_eq!(encode_u24(0x89B200), "00B289");
        assert_eq!(decode_u24("00B289").unwrap(), 9_024_000);
        assert_eq!(decode_u24("A7FD00").unwrap(), 64_935);
        assert!(decode_u24("00B2").is_err());
        assert!(decode_u24("00B2ZZ").is_err());
    }

    #[test]
    fn replies_echoes_and_refusals_are_told_apart() {
        assert_eq!(classify_reply("=000080"), ReplyLine::Data("000080".into()));
        assert_eq!(classify_reply("="), ReplyLine::Data(String::new()));
        assert_eq!(classify_reply("!2"), ReplyLine::Refused('2'));
        assert_eq!(classify_reply(":j1"), ReplyLine::Other);
        assert_eq!(classify_reply("=00b289"), ReplyLine::Other);
        assert_eq!(refusal_meaning('2'), "motor not stopped");
    }

    #[test]
    fn status_digits_read_most_significant_first() {
        let tracking = AxisStatus::parse("111").unwrap();
        assert!(tracking.tracking_like() && !tracking.in_goto() && tracking.initialized);
        let goto_back_fast = AxisStatus::parse("611").unwrap();
        assert!(goto_back_fast.in_goto() && goto_back_fast.backward && goto_back_fast.high_speed);
        let fresh = AxisStatus::parse("100").unwrap();
        assert!(!fresh.running && !fresh.initialized);
        assert!(AxisStatus::parse("1").is_err());
    }

    /// The first digit is the kind of motion, the second the direction.
    #[test]
    fn motion_modes_are_kind_then_direction() {
        let mode = |goto, high_speed, forward| MotionMode {
            goto,
            high_speed,
            forward,
        };
        assert_eq!(mode(true, true, true).data(), "00");
        assert_eq!(mode(false, false, true).data(), "10");
        assert_eq!(mode(true, false, false).data(), "21");
        assert_eq!(mode(false, true, false).data(), "31");
        assert!(mode(false, false, true).matches(&AxisStatus::parse("111").unwrap()));
        assert!(!mode(false, false, false).matches(&AxisStatus::parse("111").unwrap()));
        assert!(!mode(true, false, true).matches(&AxisStatus::parse("111").unwrap()));
    }

    #[test]
    fn the_board_version_names_the_mount() {
        let eq6r = BoardVersion::parse("032723").unwrap();
        assert_eq!(eq6r.number(), 0x032723);
        assert_eq!(
            eq6r.describe(),
            "Sky-Watcher EQ6-R Pro, motor controller firmware 3.39"
        );
        assert!(!eq6r.is_alt_azimuth_only());
        assert!(BoardVersion::parse("020780").unwrap().is_alt_azimuth_only());
    }
}
