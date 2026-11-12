//! The iOptron driver against a mount emulated from iOptron's own documents
//! alone: "iOptron Mount RS-232 Command Language 2014" Version 2.5
//! (2019-01-15) and "iOptron Mount RS-232 Command Language" Version 3.10
//! (2021-01-04), both at ioptron.com/v/ASCOM/. Section names below refer to
//! those documents.
//!
//! The emulator decodes every command into what it means (a target in hours
//! and degrees, an axis and sign for a guide pulse, a UTC instant for a clock)
//! and the tests check those meanings, so a unit, sign or field-width mistake
//! fails here even when the bytes look plausible. A command the document does
//! not give for the dialect, or a malformed one, gets no reply.

use super::FakeMount;
use crate::vendor::ioptron::{self, IOptronMount};
use skotiq_device::*;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Language {
    V25,
    V3,
}

/// A guide pulse as the document describes its effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pulse {
    /// v3.10 `:ZS` / `:ZQ` / `:ZE` / `:ZC`: axis and sign.
    RaPlus(u32),
    RaMinus(u32),
    DecPlus(u32),
    DecMinus(u32),
    /// The `:Mn` family (v2.5, deprecated in v3.10): the compass letter.
    Compass(char, u32),
}

struct DocMount {
    language: Language,
    code: &'static str,
    baud: u32,
    equatorial: bool,
    ra_hours: f64,
    dec_deg: f64,
    alt_deg: f64,
    az_deg: f64,
    /// v3 `:GEP#` 18th digit.
    pier_digit: u8,
    target_ra_hours: Option<f64>,
    target_dec_deg: Option<f64>,
    /// `:GLS#` system digit.
    system: u8,
    /// Status digits still to report before a slew ends.
    slew_polls_left: u8,
    tracking: bool,
    rate_digit: u8,
    longitude_deg: f64,
    latitude_deg: f64,
    hemisphere_digit: u8,
    /// Minutes, daylight saving excluded.
    utc_offset_minutes: i64,
    daylight_saving: bool,
    utc_unix_seconds: i64,
    park_alt_deg: Option<f64>,
    park_az_deg: Option<f64>,
    slew_reply: u8,
    pulses: Vec<Pulse>,
    unanswered: Vec<String>,
}

const J2000_UNIX: i64 = 946_728_000;

impl DocMount {
    fn new(language: Language, code: &'static str, baud: u32, equatorial: bool) -> Self {
        Self {
            language,
            code,
            baud,
            equatorial,
            ra_hours: 3.25,
            dec_deg: -12.5,
            alt_deg: 41.5,
            az_deg: 201.25,
            pier_digit: b'1',
            target_ra_hours: None,
            target_dec_deg: None,
            system: b'1',
            slew_polls_left: 0,
            tracking: true,
            rate_digit: b'0',
            longitude_deg: -75.25,
            latitude_deg: 40.0,
            hemisphere_digit: b'1',
            utc_offset_minutes: -300,
            daylight_saving: false,
            utc_unix_seconds: 1_794_000_000,
            park_alt_deg: None,
            park_az_deg: None,
            slew_reply: b'1',
            pulses: Vec::new(),
            unanswered: Vec::new(),
        }
    }

    fn signed(text: &str, digits: usize) -> Option<i64> {
        let (sign, rest) = text.split_at_checked(1)?;
        let magnitude = Self::unsigned(rest, digits)?;
        match sign {
            "+" => Some(magnitude),
            "-" => Some(-magnitude),
            _ => None,
        }
    }

    fn unsigned(text: &str, digits: usize) -> Option<i64> {
        (text.len() == digits && text.bytes().all(|b| b.is_ascii_digit()))
            .then(|| text.parse().ok())
            .flatten()
    }

    fn sign(value: f64) -> char {
        if value < 0.0 {
            '-'
        } else {
            '+'
        }
    }

    fn cas(degrees: f64) -> i64 {
        (degrees.abs() * 360_000.0).round() as i64
    }

    fn status_digit(&mut self) -> u8 {
        if self.system == b'2' {
            if self.slew_polls_left == 0 {
                self.system = if self.tracking { b'1' } else { b'0' };
            } else {
                self.slew_polls_left -= 1;
            }
        }
        self.system
    }

    fn local_offset_minutes(&self) -> i64 {
        self.utc_offset_minutes + if self.daylight_saving { 60 } else { 0 }
    }

    fn answer(&mut self, command: &str) -> Option<String> {
        let v3 = self.language == Language::V3;
        let one = || Some("1".to_string());
        match command {
            ":MountInfo#" => return Some(self.code.to_string()),
            ":FW1#" => return Some("210105210105#".into()),
            ":FW2#" => return Some("210105210105#".into()),
            ":GLS#" => {
                let system = self.status_digit();
                let (units, width) = if v3 { (360_000.0, 8) } else { (3_600.0, 6) };
                let lon = (self.longitude_deg.abs() * units).round() as i64;
                let lat = ((self.latitude_deg + 90.0) * units).round() as i64;
                return Some(format!(
                    "{}{lon:0width$}{lat:0width$}0{}{}51{}#",
                    Self::sign(self.longitude_deg),
                    system as char,
                    self.rate_digit as char,
                    self.hemisphere_digit as char
                ));
            }
            ":GEC#" if !v3 => {
                let ms = (self.ra_hours * 3_600_000.0).round() as i64;
                return Some(format!(
                    "{}{:08}{ms:08}#",
                    Self::sign(self.dec_deg),
                    Self::cas(self.dec_deg)
                ));
            }
            ":GEP#" if v3 => {
                return Some(format!(
                    "{}{:08}{:09}{}1#",
                    Self::sign(self.dec_deg),
                    Self::cas(self.dec_deg),
                    Self::cas(self.ra_hours * 15.0),
                    self.pier_digit as char
                ));
            }
            ":GAC#" => {
                return Some(format!(
                    "{}{:08}{:09}#",
                    Self::sign(self.alt_deg),
                    Self::cas(self.alt_deg),
                    Self::cas(self.az_deg)
                ));
            }
            ":GLT#" if !v3 => {
                let local = chrono::DateTime::from_timestamp(
                    self.utc_unix_seconds + self.local_offset_minutes() * 60,
                    0,
                )?;
                return Some(format!(
                    "{}{:03}{}{}#",
                    if self.utc_offset_minutes < 0 {
                        '-'
                    } else {
                        '+'
                    },
                    self.utc_offset_minutes.abs(),
                    if self.daylight_saving { '1' } else { '0' },
                    local.format("%y%m%d%H%M%S")
                ));
            }
            ":GUT#" if v3 => {
                return Some(format!(
                    "{}{:03}{}{:013}#",
                    if self.utc_offset_minutes < 0 {
                        '-'
                    } else {
                        '+'
                    },
                    self.utc_offset_minutes.abs(),
                    if self.daylight_saving { '1' } else { '0' },
                    (self.utc_unix_seconds - J2000_UNIX) * 1000
                ));
            }
            ":MS#" if !v3 => return self.slew(),
            ":MS1#" | ":MS2#" if v3 => return self.slew(),
            ":CM#" => {
                if let (Some(ra), Some(dec)) = (self.target_ra_hours, self.target_dec_deg) {
                    self.ra_hours = ra;
                    self.dec_deg = dec;
                }
                return one();
            }
            ":Q#" => {
                if self.system == b'2' {
                    self.system = if self.tracking { b'1' } else { b'0' };
                }
                return one();
            }
            ":ST0#" => {
                self.tracking = false;
                if matches!(self.system, b'1' | b'3' | b'5') {
                    self.system = b'0';
                }
                return one();
            }
            ":ST1#" => {
                self.tracking = true;
                if matches!(self.system, b'0' | b'7') {
                    self.system = b'1';
                }
                return one();
            }
            ":RT0#" | ":RT1#" | ":RT2#" | ":RT3#" | ":RT4#" => {
                self.rate_digit = command.as_bytes()[3];
                return one();
            }
            ":MP1#" => {
                self.system = b'6';
                self.tracking = false;
                return one();
            }
            ":MP0#" => {
                if self.system == b'6' {
                    self.system = b'0';
                }
                return one();
            }
            ":MH#" => {
                self.system = b'2';
                self.slew_polls_left = 1;
                self.tracking = false;
                // Ends stopped at zero.
                self.ra_hours = 0.0;
                return one();
            }
            ":SDS0#" => {
                self.daylight_saving = false;
                return one();
            }
            ":SDS1#" => {
                self.daylight_saving = true;
                return one();
            }
            ":SHE0#" => {
                self.hemisphere_digit = b'0';
                return one();
            }
            ":SHE1#" => {
                self.hemisphere_digit = b'1';
                return one();
            }
            _ => {}
        }

        let field = |prefix: &str| command.strip_prefix(prefix)?.strip_suffix('#');
        if let Some(units) = field(":SRA")
            .filter(|_| v3)
            .and_then(|f| Self::unsigned(f, 9))
        {
            self.target_ra_hours = Some(units as f64 / 360_000.0 / 15.0);
            return one();
        }
        if let Some(ms) = field(":Sr")
            .filter(|_| !v3)
            .and_then(|f| Self::unsigned(f, 8))
        {
            self.target_ra_hours = Some(ms as f64 / 3_600_000.0);
            return one();
        }
        if let Some(units) = field(":Sd").and_then(|f| Self::signed(f, 8)) {
            self.target_dec_deg = Some(units as f64 / 360_000.0);
            return one();
        }
        if let Some(units) = field(":SPA").and_then(|f| Self::unsigned(f, 9)) {
            self.park_az_deg = Some(units as f64 / 360_000.0);
            return one();
        }
        if let Some(units) = field(":SPH").and_then(|f| Self::unsigned(f, 8)) {
            self.park_alt_deg = Some(units as f64 / 360_000.0);
            return one();
        }
        if let Some(minutes) = field(":SG").and_then(|f| Self::signed(f, 3)) {
            if !(-720..=780).contains(&minutes) {
                return Some("0".into());
            }
            self.utc_offset_minutes = minutes;
            return one();
        }
        if v3 {
            if let Some(ms) = field(":SUT").and_then(|f| Self::unsigned(f, 13)) {
                self.utc_unix_seconds = J2000_UNIX + ms / 1000;
                return one();
            }
            if let Some(units) = field(":SLO").and_then(|f| Self::signed(f, 8)) {
                self.longitude_deg = units as f64 / 360_000.0;
                return one();
            }
            if let Some(units) = field(":SLA").and_then(|f| Self::signed(f, 8)) {
                self.latitude_deg = units as f64 / 360_000.0;
                return one();
            }
            for (prefix, pulse) in [
                (":ZS", Pulse::RaPlus as fn(u32) -> Pulse),
                (":ZQ", Pulse::RaMinus),
                (":ZE", Pulse::DecPlus),
                (":ZC", Pulse::DecMinus),
            ] {
                if let Some(ms) = field(prefix).and_then(|f| Self::unsigned(f, 5)) {
                    if self.equatorial {
                        self.pulses.push(pulse(ms as u32));
                    }
                    return None;
                }
            }
        } else {
            if let Some(date) = field(":SC").and_then(|f| Self::unsigned(f, 6)) {
                let local = chrono::DateTime::from_timestamp(
                    self.utc_unix_seconds + self.local_offset_minutes() * 60,
                    0,
                )?;
                let date = chrono::NaiveDate::from_ymd_opt(
                    2000 + (date / 10_000) as i32,
                    (date / 100 % 100) as u32,
                    (date % 100) as u32,
                )?;
                let local = date.and_time(local.time());
                self.utc_unix_seconds =
                    local.and_utc().timestamp() - self.local_offset_minutes() * 60;
                return one();
            }
            if let Some(time) = field(":SL").and_then(|f| Self::unsigned(f, 6)) {
                let local = chrono::DateTime::from_timestamp(
                    self.utc_unix_seconds + self.local_offset_minutes() * 60,
                    0,
                )?;
                let local = local.date_naive().and_hms_opt(
                    (time / 10_000) as u32,
                    (time / 100 % 100) as u32,
                    (time % 100) as u32,
                )?;
                self.utc_unix_seconds =
                    local.and_utc().timestamp() - self.local_offset_minutes() * 60;
                return one();
            }
            if let Some(arcsec) = field(":Sg").and_then(|f| Self::signed(f, 6)) {
                self.longitude_deg = arcsec as f64 / 3_600.0;
                return one();
            }
            if let Some(arcsec) = field(":St").and_then(|f| Self::signed(f, 6)) {
                self.latitude_deg = arcsec as f64 / 3_600.0;
                return one();
            }
        }
        for letter in ['n', 's', 'e', 'w'] {
            if let Some(ms) = field(&format!(":M{letter}")).and_then(|f| Self::unsigned(f, 5)) {
                if self.equatorial {
                    self.pulses.push(Pulse::Compass(letter, ms as u32));
                }
                return None;
            }
        }
        self.unanswered.push(command.to_string());
        None
    }

    fn slew(&mut self) -> Option<String> {
        let (Some(ra), Some(dec)) = (self.target_ra_hours, self.target_dec_deg) else {
            return Some("0".into());
        };
        if self.slew_reply != b'1' {
            return Some((self.slew_reply as char).to_string());
        }
        self.ra_hours = ra;
        self.dec_deg = dec;
        self.system = b'2';
        self.slew_polls_left = 1;
        self.tracking = true;
        Some("1".into())
    }
}

type Shared = Arc<Mutex<DocMount>>;

fn spawn(mount: DocMount) -> (FakeMount, Shared) {
    let state = Arc::new(Mutex::new(mount));
    let serving = state.clone();
    let fake = FakeMount::spawn(
        b'#',
        Box::new(move |command, baud| {
            let mut mount = serving.lock().unwrap();
            if baud != mount.baud {
                return Vec::new();
            }
            let command = String::from_utf8_lossy(command).into_owned();
            mount
                .answer(&command)
                .map(String::into_bytes)
                .unwrap_or_default()
        }),
    );
    (fake, state)
}

/// Connects at the mount's own rate; the fallback to the other rate costs a
/// reply deadline and has a test of its own.
async fn connected(fake: &FakeMount, state: &Shared) -> IOptronMount {
    let baud = state.lock().unwrap().baud;
    let mut mount = IOptronMount::new(fake.path.clone(), Some(baud));
    mount
        .connect()
        .await
        .expect("connect to the documented mount");
    mount
}

fn close(a: f64, b: f64, tolerance: f64) -> bool {
    (a - b).abs() <= tolerance
}

/// 0.01 arc second in degrees, the finest unit either document uses.
const CAS: f64 = 1.0 / 360_000.0;

#[tokio::test]
async fn models_are_named_from_the_table_of_the_language_the_mount_speaks() {
    // "0026" is the CEM25-EC in v2.5 and the CEM26 in v3.10 (`:MountInfo#`).
    for (language, baud, code, expected) in [
        (Language::V25, 9600, "0026", "CEM25-EC"),
        (Language::V3, 115200, "0026", "CEM26"),
        (Language::V25, 115200, "0040", "CEM40"),
        (Language::V3, 115200, "0122", "CEM120-EC2"),
        (Language::V25, 9600, "0060", "CEM60"),
    ] {
        let (fake, state) = spawn(DocMount::new(language, code, baud, true));
        let mount = connected(&fake, &state).await;
        assert!(
            mount.name().contains(&format!("iOptron {expected} (")),
            "{language:?} code {code}: named {:?}",
            mount.name()
        );
    }
}

#[tokio::test]
async fn gotos_and_syncs_send_the_target_in_each_languages_units() {
    for (language, baud) in [(Language::V25, 9600), (Language::V3, 115200)] {
        let (fake, state) = spawn(DocMount::new(language, "0045", baud, true));
        let mut mount = connected(&fake, &state).await;
        for (ra, dec) in [
            (5.5, -20.25),
            (23.999_99, 89.5),
            (0.0, -0.000_1),
            (12.345_678, 45.678_9),
        ] {
            mount.slew_to_coordinates(ra, dec).await.expect("slew");
            let target = {
                let s = state.lock().unwrap();
                (s.target_ra_hours.unwrap(), s.target_dec_deg.unwrap())
            };
            let ra_tolerance = match language {
                Language::V25 => 0.5 / 3_600_000.0,
                Language::V3 => 0.5 * CAS / 15.0,
            };
            assert!(
                close(target.0, ra, ra_tolerance) || close(target.0 + 24.0, ra, ra_tolerance),
                "{language:?}: RA {ra} reached the mount as {}",
                target.0
            );
            assert!(
                close(target.1, dec, 0.5 * CAS),
                "{language:?}: Dec {dec} reached the mount as {}",
                target.1
            );
            while mount.is_slewing().await.expect("slew state") {}
            let (read_ra, read_dec) = mount.get_coordinates().await.expect("read back");
            assert!(
                close(read_dec, dec, CAS),
                "{language:?}: Dec read back {read_dec}"
            );
            assert!(
                close(read_ra, ra, 0.001 / 3600.0) || close(read_ra + 24.0, ra, 0.001 / 3600.0),
                "{language:?}: RA read back {read_ra}"
            );
        }

        mount.sync_to_coordinates(7.125, 33.5).await.expect("sync");
        let (ra, dec) = mount.get_coordinates().await.expect("read back");
        assert!(
            close(ra, 7.125, 1e-6) && close(dec, 33.5, 1e-6),
            "{language:?}: sync landed at {ra} {dec}"
        );
        assert!(
            state.lock().unwrap().unanswered.is_empty(),
            "{:?}",
            state.lock().unwrap().unanswered
        );
    }
}

#[tokio::test]
async fn a_refused_goto_is_an_error() {
    let (fake, state) = spawn(DocMount::new(Language::V3, "0120", 115200, true));
    let mut mount = connected(&fake, &state).await;
    state.lock().unwrap().slew_reply = b'0';
    assert!(mount.slew_to_coordinates(1.0, 1.0).await.is_err());
}

#[tokio::test]
async fn guide_pulses_move_the_axis_the_documents_name() {
    // v3.10: ZS is RA+, ZQ RA-, ZE Dec+, ZC Dec-. East raises RA (ASCOM
    // guideEast), north raises Dec.
    let (fake, state) = spawn(DocMount::new(Language::V3, "0071", 115200, true));
    let mut mount = connected(&fake, &state).await;
    assert!(mount.can_pulse_guide());
    for (direction, ms) in [
        (GuideDirection::North, 120),
        (GuideDirection::South, 250),
        (GuideDirection::East, 99_999),
        (GuideDirection::West, 7),
    ] {
        mount.pulse_guide(direction, ms).await.expect("pulse");
    }
    // A query after the pulses makes sure the fake has read them.
    mount.get_tracking().await.expect("status");
    assert_eq!(
        state.lock().unwrap().pulses,
        [
            Pulse::DecPlus(120),
            Pulse::DecMinus(250),
            Pulse::RaPlus(99_999),
            Pulse::RaMinus(7)
        ]
    );

    let (fake, state) = spawn(DocMount::new(Language::V25, "0060", 9600, true));
    let mut mount = connected(&fake, &state).await;
    for direction in [
        GuideDirection::North,
        GuideDirection::South,
        GuideDirection::East,
        GuideDirection::West,
    ] {
        mount.pulse_guide(direction, 500).await.expect("pulse");
    }
    mount.get_tracking().await.expect("status");
    assert_eq!(
        state.lock().unwrap().pulses,
        [
            Pulse::Compass('n', 500),
            Pulse::Compass('s', 500),
            Pulse::Compass('e', 500),
            Pulse::Compass('w', 500)
        ]
    );
}

#[tokio::test]
async fn alt_azimuth_mounts_take_no_guide_pulses_and_report_no_pier_side() {
    // "Only available in equatorial mounts" (v3.10 `:Z`). The AA codes come
    // from the `:MountInfo#` tables, iOptron's special-mode document
    // (2023-05-08: 0033/0034 HAE29 AA, 0050/0051 HAE43 AA, 0035 HAZ31,
    // 0052 HAZ46) and, for the other dual-mode heads, the EQ, EC EQ, AA,
    // EC AA order every documented block follows (0038/0039, 0055/0056,
    // 0068/0069).
    for (language, baud, code) in [
        (Language::V25, 9600, "0046"),
        (Language::V25, 9600, "5035"),
        (Language::V3, 115200, "0011"),
        (Language::V3, 115200, "0033"),
        (Language::V3, 115200, "0034"),
        (Language::V3, 115200, "0035"),
        (Language::V3, 115200, "0050"),
        (Language::V3, 115200, "0051"),
        (Language::V3, 115200, "0052"),
        (Language::V3, 115200, "0038"),
        (Language::V3, 115200, "0039"),
        (Language::V3, 115200, "0055"),
        (Language::V3, 115200, "0056"),
        (Language::V3, 115200, "0068"),
        (Language::V3, 115200, "0069"),
    ] {
        let (fake, state) = spawn(DocMount::new(language, code, baud, false));
        let mut mount = connected(&fake, &state).await;
        assert!(
            !mount.can_pulse_guide(),
            "{code} ({}) offers pulse guiding",
            mount.name()
        );
        assert!(mount.pulse_guide(GuideDirection::North, 100).await.is_err());
        assert_eq!(
            mount.get_side_of_pier().await.expect("pier side"),
            PierSide::Unknown,
            "{code} ({})",
            mount.name()
        );
        assert!(state.lock().unwrap().pulses.is_empty());
    }
}

#[tokio::test]
async fn the_side_of_pier_is_the_v3_position_digit() {
    let (fake, state) = spawn(DocMount::new(Language::V3, "0120", 115200, true));
    let mount = connected(&fake, &state).await;
    for (digit, side) in [
        (b'0', PierSide::East),
        (b'1', PierSide::West),
        (b'2', PierSide::Unknown),
    ] {
        state.lock().unwrap().pier_digit = digit;
        assert_eq!(mount.get_side_of_pier().await.unwrap(), side);
    }

    let (fake, state) = spawn(DocMount::new(Language::V25, "0060", 9600, true));
    let mount = connected(&fake, &state).await;
    assert_eq!(mount.get_side_of_pier().await.unwrap(), PierSide::Unknown);
}

#[tokio::test]
async fn park_home_and_tracking_follow_the_status_digit() {
    for (language, baud, code) in [
        (Language::V25, 9600, "0045"),
        (Language::V3, 115200, "0043"),
    ] {
        let (fake, state) = spawn(DocMount::new(language, code, baud, true));
        let mut mount = connected(&fake, &state).await;
        assert!(mount.get_tracking().await.unwrap());
        mount.set_tracking(false).await.unwrap();
        assert!(!mount.get_tracking().await.unwrap());
        mount.set_tracking(true).await.unwrap();
        assert!(mount.get_tracking().await.unwrap());

        for (rate, digit) in [
            (TrackingRate::Lunar, b'1'),
            (TrackingRate::Solar, b'2'),
            (TrackingRate::King, b'3'),
            (TrackingRate::Sidereal, b'0'),
        ] {
            mount.set_tracking_rate(rate).await.unwrap();
            assert_eq!(state.lock().unwrap().rate_digit, digit);
            assert_eq!(mount.get_tracking_rate().await.unwrap(), rate);
        }

        mount.park().await.unwrap();
        assert!(mount.is_parked().await.unwrap());
        assert!(!mount.get_tracking().await.unwrap());
        mount.unpark().await.unwrap();
        assert!(!mount.is_parked().await.unwrap());

        mount.find_home().await.unwrap();
        assert!(mount.is_slewing().await.unwrap());
        // The status digit after the goto: stopped at zero.
        state.lock().unwrap().slew_polls_left = 0;
        state.lock().unwrap().system = b'7';
        assert!(mount.at_home().await.unwrap());
        assert!(!mount.is_slewing().await.unwrap());

        state.lock().unwrap().alt_deg = 12.345;
        state.lock().unwrap().az_deg = 359.999_99;
        mount.set_park().await.unwrap();
        let s = state.lock().unwrap();
        assert!(close(s.park_alt_deg.unwrap(), 12.345, CAS));
        assert!(
            close(s.park_az_deg.unwrap(), 359.999_99, CAS)
                || close(s.park_az_deg.unwrap(), 0.0, CAS)
        );
        assert!(s.unanswered.is_empty(), "{:?}", s.unanswered);
    }
}

#[tokio::test]
async fn the_site_round_trips_east_positive_in_each_languages_units() {
    for (language, baud) in [(Language::V25, 9600), (Language::V3, 115200)] {
        let (fake, state) = spawn(DocMount::new(language, "0045", baud, true));
        let mut mount = connected(&fake, &state).await;
        let tolerance = match language {
            Language::V25 => 0.5 / 3600.0,
            Language::V3 => 0.5 * CAS,
        };
        for (lat, lon) in [
            (-33.865_1, 151.209_3),
            (40.007_7, -75.397_4),
            (0.0, -0.000_1),
            (89.9, 179.999),
        ] {
            mount
                .set_site(MountSiteInfo {
                    latitude_deg: lat,
                    longitude_deg: lon,
                    elevation_m: None,
                })
                .await
                .unwrap();
            {
                let s = state.lock().unwrap();
                assert!(
                    close(s.latitude_deg, lat, tolerance),
                    "{language:?}: lat {lat} -> {}",
                    s.latitude_deg
                );
                assert!(
                    close(s.longitude_deg, lon, tolerance),
                    "{language:?}: lon {lon} -> {}",
                    s.longitude_deg
                );
            }
            let site = mount.get_site().await.unwrap();
            assert!(
                close(site.latitude_deg, lat, 2.0 * tolerance),
                "{language:?}: read lat {}",
                site.latitude_deg
            );
            assert!(
                close(site.longitude_deg, lon, 2.0 * tolerance),
                "{language:?}: read lon {}",
                site.longitude_deg
            );
        }
    }
}

#[tokio::test]
async fn the_clock_round_trips_as_the_same_utc_instant() {
    for (language, baud) in [(Language::V25, 9600), (Language::V3, 115200)] {
        let (fake, state) = spawn(DocMount::new(language, "0045", baud, true));
        let mut mount = connected(&fake, &state).await;

        // The mount's own clock, read with daylight saving on.
        {
            let mut s = state.lock().unwrap();
            s.utc_offset_minutes = -300;
            s.daylight_saving = true;
            s.utc_unix_seconds = 1_790_000_123;
        }
        let read = mount.get_clock().await.unwrap();
        assert_eq!(read.utc_unix_seconds, 1_790_000_123, "{language:?}");
        assert!(
            close(read.utc_offset_hours, -4.0, 1e-9),
            "{language:?}: {}",
            read.utc_offset_hours
        );

        for (unix, offset) in [
            (1_794_456_789, -5.0),
            (1_794_400_000, 10.5),
            (1_794_399_999, -9.5),
            (1_800_000_000, 13.0),
        ] {
            mount
                .set_clock(MountClock {
                    utc_unix_seconds: unix,
                    utc_offset_hours: offset,
                })
                .await
                .unwrap();
            {
                let s = state.lock().unwrap();
                assert_eq!(
                    s.utc_unix_seconds, unix,
                    "{language:?}: wrote {unix} at {offset} h"
                );
                assert_eq!(
                    s.local_offset_minutes(),
                    (offset * 60.0) as i64,
                    "{language:?}"
                );
            }
            let read = mount.get_clock().await.unwrap();
            assert_eq!(read.utc_unix_seconds, unix, "{language:?}");
            assert!(close(read.utc_offset_hours, offset, 1e-9), "{language:?}");
        }
        assert!(
            state.lock().unwrap().unanswered.is_empty(),
            "{:?}",
            state.lock().unwrap().unanswered
        );
    }
}

#[tokio::test]
async fn connect_finds_the_baud_rate_the_document_gives() {
    // v3.10: 115200 for every mount. v2.5: 115200 for the CEM40, 9600 for
    // the rest.
    for (language, baud, code) in [
        (Language::V3, 115200, "0028"),
        (Language::V25, 115200, "0041"),
        (Language::V25, 9600, "0030"),
    ] {
        let (fake, _) = spawn(DocMount::new(language, code, baud, true));
        for configured in [None, Some(9600), Some(115200)] {
            let mut mount = IOptronMount::new(fake.path.clone(), configured);
            mount.connect().await.expect("connect");
            mount.get_coordinates().await.expect("query after connect");
            mount.disconnect().await.unwrap();
        }
    }
}

#[tokio::test]
async fn a_scan_finds_mounts_of_both_languages() {
    for (language, baud, code, expected) in [
        (Language::V3, 115200, "0026", "CEM26"),
        (Language::V25, 9600, "0026", "CEM25-EC"),
    ] {
        let (fake, _) = spawn(DocMount::new(language, code, baud, true));
        let found = ioptron::scan_port_list(vec![serialport::SerialPortInfo {
            port_name: fake.path.clone(),
            port_type: serialport::SerialPortType::Unknown,
        }]);
        assert_eq!(found.len(), 1, "{language:?}");
        assert_eq!(found[0].baud_rate, baud);
        assert_eq!(found[0].model, expected);
    }
}
