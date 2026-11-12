//! Scripted mounts: each answers the commands its protocol's driver sends the
//! way that driver expects, and keeps just enough state (tracking, slewing,
//! parked) for the answers to follow the session.

use super::Responder;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

/// Switches a test flips while a session runs.
#[derive(Default)]
pub(super) struct Knobs {
    /// The next goto is refused.
    pub refuse_goto: AtomicBool,
    /// Sky-Watcher: each goto pass stops this many microsteps short.
    pub goto_shortfall: AtomicU32,
    /// Sky-Watcher: this many commands get no reply.
    pub swallow_replies: AtomicU32,
    /// Sky-Watcher: replies come after an echo of the command, as on the
    /// DC-motor controllers.
    pub echo: AtomicBool,
    /// Sky-Watcher: where the axes stand, RA then Dec.
    pub positions: Mutex<[u32; 2]>,
}

pub(super) fn silent() -> Responder {
    Box::new(|_, _| Vec::new())
}

fn text(command: &[u8]) -> String {
    String::from_utf8_lossy(command).into_owned()
}

// Sky-Watcher motor controller

/// Steps per turn and timer of an EQ6 (indi-eqmod's figures).
pub(super) const SYNSCAN_COUNTS: u32 = 9_024_000;
const SYNSCAN_TIMER_HZ: u32 = 64_935;
pub(super) const SYNSCAN_POWER_ON: u32 = 0x80_0000;

#[derive(Clone, Copy)]
struct SynScanAxis {
    initialized: bool,
    position: u32,
    running: bool,
    goto_mode: bool,
    high_speed: bool,
    backward: bool,
    increment: u32,
    target: u32,
    goto_polls_left: u32,
}

impl SynScanAxis {
    fn power_on(initialized: bool) -> Self {
        Self {
            initialized,
            position: SYNSCAN_POWER_ON,
            running: false,
            goto_mode: false,
            high_speed: false,
            backward: false,
            increment: 0,
            target: SYNSCAN_POWER_ON,
            goto_polls_left: 0,
        }
    }
}

fn synscan_u24(value: u32) -> String {
    format!(
        "{:02X}{:02X}{:02X}",
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF
    )
}

fn synscan_parse_u24(data: &str) -> Option<u32> {
    if data.len() != 6 {
        return None;
    }
    let byte = |i: usize| u32::from_str_radix(&data[i..i + 2], 16).ok();
    Some(byte(0)? | (byte(2)? << 8) | (byte(4)? << 16))
}

/// An EQ6 motor controller with firmware 3.07, freshly powered. A goto
/// arrives at the second status poll after it starts; constant-rate motion
/// runs without moving the counters.
///
/// `answer_baud`: answer only when the port is set to this baud rate.
pub(super) fn synscan(answer_baud: Option<u32>, knobs: Arc<Knobs>) -> Responder {
    synscan_controller(answer_baud, false, knobs)
}

/// The same controller, initialized by another program before the driver
/// connects.
pub(super) fn synscan_initialized(knobs: Arc<Knobs>) -> Responder {
    synscan_controller(None, true, knobs)
}

fn synscan_controller(answer_baud: Option<u32>, initialized: bool, knobs: Arc<Knobs>) -> Responder {
    let mut axes = [SynScanAxis::power_on(initialized); 2];
    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let raw = command;
        let command = text(command);
        let mut chars = command.chars().skip(1);
        let kind = chars.next().unwrap_or(' ');
        let axis_char = chars.next().unwrap_or('1');
        let data: String = chars.take_while(|c| *c != '\r').collect();
        let selected: Vec<usize> = match axis_char {
            '1' => vec![0],
            '2' => vec![1],
            '3' => vec![0, 1],
            _ => vec![],
        };
        let i = selected.first().copied().unwrap_or(0);

        let reply = if selected.is_empty() || !command.starts_with(':') {
            "!0".to_string()
        } else {
            match kind {
                'e' => "=030700".to_string(),
                'a' => format!("={}", synscan_u24(SYNSCAN_COUNTS)),
                'b' => format!("={}", synscan_u24(SYNSCAN_TIMER_HZ)),
                'F' => {
                    for &a in &selected {
                        axes[a].initialized = true;
                    }
                    "=".to_string()
                }
                'j' => format!("={}", synscan_u24(axes[i].position)),
                'f' => {
                    let axis = &mut axes[i];
                    if axis.running && axis.goto_mode {
                        if axis.goto_polls_left == 0 {
                            axis.position = axis.target;
                            axis.running = false;
                        } else {
                            axis.goto_polls_left -= 1;
                        }
                    }
                    let mode = u8::from(!axis.goto_mode)
                        | (u8::from(axis.backward) << 1)
                        | (u8::from(axis.high_speed) << 2);
                    format!(
                        "={}{}{}",
                        mode,
                        u8::from(axis.running),
                        u8::from(axis.initialized)
                    )
                }
                'E' => match synscan_parse_u24(&data) {
                    Some(step) => {
                        axes[i].position = step;
                        "=".to_string()
                    }
                    None => "!3".to_string(),
                },
                'G' => {
                    let mut mode = data.chars();
                    match (mode.next(), mode.next()) {
                        _ if axes[i].running => "!2".to_string(),
                        (Some(k @ '0'..='3'), Some(d @ ('0' | '1'))) => {
                            let axis = &mut axes[i];
                            axis.goto_mode = k == '0' || k == '2';
                            axis.high_speed = k == '0' || k == '3';
                            axis.backward = d == '1';
                            "=".to_string()
                        }
                        _ => "!3".to_string(),
                    }
                }
                'I' | 'M' => match synscan_parse_u24(&data) {
                    Some(_) => "=".to_string(),
                    None => "!3".to_string(),
                },
                'H' => match synscan_parse_u24(&data) {
                    Some(steps) => {
                        axes[i].increment = steps;
                        "=".to_string()
                    }
                    None => "!3".to_string(),
                },
                'J' => {
                    let axis = &mut axes[i];
                    if !axis.initialized {
                        "!4".to_string()
                    } else if axis.goto_mode && knobs.refuse_goto.load(Ordering::SeqCst) {
                        "!2".to_string()
                    } else {
                        if axis.goto_mode {
                            let travel = axis
                                .increment
                                .saturating_sub(knobs.goto_shortfall.load(Ordering::SeqCst));
                            axis.target = if axis.backward {
                                axis.position.wrapping_sub(travel) & 0xFF_FFFF
                            } else {
                                axis.position.wrapping_add(travel) & 0xFF_FFFF
                            };
                            axis.goto_polls_left = 1;
                        }
                        axis.running = true;
                        "=".to_string()
                    }
                }
                'K' | 'L' => {
                    for &a in &selected {
                        axes[a].running = false;
                    }
                    "=".to_string()
                }
                _ => "!0".to_string(),
            }
        };
        *knobs.positions.lock().unwrap() = [axes[0].position, axes[1].position];

        let swallowed = knobs
            .swallow_replies
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok();
        if swallowed {
            return Vec::new();
        }
        let mut out = if knobs.echo.load(Ordering::SeqCst) {
            raw.to_vec()
        } else {
            Vec::new()
        };
        out.extend_from_slice(format!("{reply}\r").as_bytes());
        out
    })
}

/// Which iOptron command language a fake mount speaks.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum IoptronDialect {
    /// "iOptron Mount RS-232 Command Language 2014", Version 2.5.
    V25,
    /// Version 3.10.
    V3,
    /// Firmware from before 2016: answers the model code, not `:GLS#`.
    Pre2016,
}

/// `field` is `digits` ASCII digits after an optional sign.
fn is_number(field: &str, signed: bool, digits: usize) -> bool {
    let field = if signed {
        match field.strip_prefix(['+', '-']) {
            Some(rest) => rest,
            None => return false,
        }
    } else {
        field
    };
    field.len() == digits && field.bytes().all(|b| b.is_ascii_digit())
}

/// `command` is `prefix`, a number in that shape, and `#`.
fn takes(command: &str, prefix: &str, signed: bool, digits: usize) -> bool {
    command
        .strip_prefix(prefix)
        .and_then(|rest| rest.strip_suffix('#'))
        .is_some_and(|field| is_number(field, signed, digits))
}

/// An iOptron mount as the two command language documents describe it. It
/// answers only commands in the documented form, with the documented reply
/// shapes: a query up to `#`, a setting or motion command one digit with no
/// `#`, the model code four digits with no `#`, pulse guiding nothing.
pub(super) fn ioptron(
    dialect: IoptronDialect,
    model_code: &'static str,
    answer_baud: Option<u32>,
    knobs: Arc<Knobs>,
) -> Responder {
    use IoptronDialect::*;
    let v3 = dialect == V3;
    let mut tracking = true;
    let mut slew_polls_left = 0u32;
    let mut parked = false;
    let mut at_zero = false;
    let mut rate = '0';
    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let command = text(command);
        if command == ":MountInfo#" {
            return model_code.as_bytes().to_vec();
        }
        if dialect == Pre2016 {
            return Vec::new();
        }

        let ok = || "1".to_string();
        let reply: String = match command.as_str() {
            ":FW1#" => "210607210329#".into(),
            ":FW2#" => "210105210106#".into(),
            ":GLS#" => {
                let system = if parked {
                    '6'
                } else if slew_polls_left > 0 {
                    slew_polls_left -= 1;
                    '2'
                } else if tracking {
                    '1'
                } else if at_zero {
                    '7'
                } else {
                    '0'
                };
                // 75.397448 W, 40.007714 N; GPS fix, 64x arrow speed, time
                // from GPS, northern hemisphere.
                let site = if v3 {
                    "-2714308146802777"
                } else {
                    "-271431468028"
                };
                format!("{site}2{system}{rate}531#")
            }
            // Dec +20, RA 5.5 h (82.5 deg); v3 adds pier west, counterweight down.
            ":GEP#" if v3 => "+0720000002970000011#".into(),
            ":GEC#" if !v3 => "+0720000019800000#".into(),
            // Alt 45.5, az 180.25.
            ":GAC#" => "+16380000064890000#".into(),
            // 2026-09-09 02:30:00 UTC, UTC-5 with daylight saving.
            ":GUT#" if v3 => "-30010842193000000#".into(),
            ":GLT#" if !v3 => "-3001260908223000#".into(),

            ":MS1#" if v3 => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    "0".into()
                } else {
                    slew_polls_left = 2;
                    tracking = true;
                    at_zero = false;
                    ok()
                }
            }
            ":MS#" if !v3 => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    "0".into()
                } else {
                    slew_polls_left = 2;
                    tracking = true;
                    at_zero = false;
                    ok()
                }
            }
            ":MH#" => {
                slew_polls_left = 1;
                tracking = false;
                at_zero = true;
                ok()
            }
            ":Q#" => {
                slew_polls_left = 0;
                ok()
            }
            ":CM#" => ok(),
            ":ST0#" => {
                tracking = false;
                ok()
            }
            ":ST1#" => {
                tracking = true;
                ok()
            }
            ":MP1#" => {
                parked = true;
                tracking = false;
                ok()
            }
            ":MP0#" => {
                parked = false;
                ok()
            }
            ":RT0#" | ":RT1#" | ":RT2#" | ":RT3#" | ":RT4#" => {
                rate = command.chars().nth(3).unwrap_or('0');
                ok()
            }
            ":SDS0#" | ":SDS1#" => ok(),
            ":SHE0#" | ":SHE1#" => ok(),

            other if v3 && takes(other, ":SRA", false, 9) => ok(),
            other if !v3 && takes(other, ":Sr", false, 8) => ok(),
            other if takes(other, ":Sd", true, 8) => ok(),
            other if takes(other, ":SG", true, 3) => ok(),
            other if takes(other, ":SPA", false, 9) => ok(),
            other if takes(other, ":SPH", false, 8) => ok(),
            other if v3 && takes(other, ":SUT", false, 13) => ok(),
            other if v3 && (takes(other, ":SLO", true, 8) || takes(other, ":SLA", true, 8)) => ok(),
            other if !v3 && (takes(other, ":Sg", true, 6) || takes(other, ":St", true, 6)) => ok(),
            other if !v3 && (takes(other, ":SC", false, 6) || takes(other, ":SL", false, 6)) => {
                ok()
            }
            // Pulse guiding answers nothing, in either form.
            _ => String::new(),
        };
        reply.into_bytes()
    })
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum Lx200Flavor {
    /// Meade firmware in high precision: `sDD*MM'SS` with an apostrophe
    /// before the arc seconds, an unsigned westward longitude.
    Meade,
    /// Meade firmware that starts in low precision (`HH:MM.T`, `sDD*MM`)
    /// and switches to high precision on `:U#`.
    MeadeLowPrecision,
    /// Meade-protocol firmware that stays in low precision whatever it is
    /// told.
    MeadeLowPrecisionOnly,
    /// OnStep as its command reference documents it: `1`/`0` in answer to
    /// park, unpark and tracking on/off.
    OnStep,
    /// OnStep the way the Pegasus NYX-101 speaks it: as OnStep, plus CRLF
    /// after every `#`-terminated reply and `+04:00` for the UTC offset.
    Nyx,
    Losmandy,
    TenMicron,
    Generic,
    /// A compatible mount that answers coordinates but no product name.
    CoordinatesOnly,
}

/// Whether a goto or sync target is in the shape this firmware reads: two
/// digit degrees always, and on Meade firmware the precision it is set to.
fn target_shape_accepted(command: &str, onstep: bool, high_precision: bool) -> bool {
    let shape = |text: &str, high: &str, low: &str| {
        let fits = |pattern: &str| {
            text.len() == pattern.len()
                && text.chars().zip(pattern.chars()).all(|(c, p)| match p {
                    'd' => c.is_ascii_digit(),
                    's' => c == '+' || c == '-',
                    other => c == other,
                })
        };
        if onstep {
            fits(high) || fits(low)
        } else if high_precision {
            fits(high)
        } else {
            fits(low)
        }
    };
    let body = command.trim_end_matches('#');
    if let Some(ra) = body.strip_prefix(":Sr") {
        shape(ra, "dd:dd:dd", "dd:dd.d")
    } else if let Some(dec) = body.strip_prefix(":Sd") {
        shape(dec, "sdd*dd:dd", "sdd*dd")
    } else {
        true
    }
}

pub(super) fn lx200(flavor: Lx200Flavor, answer_baud: Option<u32>, knobs: Arc<Knobs>) -> Responder {
    use Lx200Flavor::*;
    let onstep = matches!(flavor, OnStep | Nyx);
    let meade = matches!(flavor, Meade | MeadeLowPrecision | MeadeLowPrecisionOnly);
    let mut high_precision = !matches!(flavor, MeadeLowPrecision | MeadeLowPrecisionOnly);
    let mut tracking = true;
    let mut slew_polls_left = 0u32;
    let mut parked = false;
    let mut home = false;

    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let command = text(command);
        let onstep_ack = if onstep { "1" } else { "" };
        // Meade high precision puts an apostrophe before the arc seconds.
        let dms = |degrees: &str, minutes: &str, seconds: &str| {
            if !high_precision {
                format!("{degrees}*{minutes}#")
            } else if meade {
                format!("{degrees}*{minutes}'{seconds}#")
            } else {
                format!("{degrees}*{minutes}:{seconds}#")
            }
        };

        let reply: String = match command.as_str() {
            ":GR#" if high_precision => "05:30:00#".into(),
            ":GR#" => "05:30.0#".into(),
            ":GD#" => dms("+20", "00", "00"),
            _ if flavor == CoordinatesOnly => String::new(),

            ":U#" => {
                if flavor != MeadeLowPrecisionOnly {
                    high_precision = !high_precision;
                }
                String::new()
            }

            ":GVP#" => match flavor {
                Meade => "LX200 Classic#",
                MeadeLowPrecision | MeadeLowPrecisionOnly => "Autostar#",
                OnStep => "On-Step#",
                Nyx => "NYX-101#",
                Losmandy => "Losmandy Gemini#",
                TenMicron => "10micron GM1000HPS#",
                Generic | CoordinatesOnly => "EQ Controller#",
            }
            .into(),
            ":GVN#" => "4.2g#".into(),
            ":GVD#" => "Oct 10 2010#".into(),
            ":GVT#" => "12:34:56#".into(),

            ":GA#" => dms("+45", "30", "00"),
            ":GZ#" => dms("180", "15", "00"),
            ":GS#" => "03:15:42#".into(),

            ":MS#" => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    match flavor {
                        Meade | MeadeLowPrecision | MeadeLowPrecisionOnly => {
                            "1Object Below Horizon #"
                        }
                        // OnStep sends the bare status digit.
                        OnStep | Nyx => "6",
                        // Gemini Level 4: 6 is "Outside Limits".
                        Losmandy => "6Outside limits#",
                        _ => "2Below limit#",
                    }
                    .into()
                } else {
                    slew_polls_left = 2;
                    home = false;
                    "0".into()
                }
            }
            ":D#" => {
                let slewing = slew_polls_left > 0;
                slew_polls_left = slew_polls_left.saturating_sub(1);
                if slewing {
                    "\x7f#".into()
                } else {
                    "#".into()
                }
            }
            ":CM#" => match flavor {
                OnStep | Nyx => "N/A#".into(),
                TenMicron => "Coordinates     matched        #".into(),
                _ => " M31 EX GAL MAG 3.5 SZ178.0'#".into(),
            },

            ":GU#" if onstep => {
                let slewing = slew_polls_left > 0;
                slew_polls_left = slew_polls_left.saturating_sub(1);
                format!(
                    "{}{}{}{}ET250#",
                    if tracking { "" } else { "n" },
                    if slewing { "" } else { "N" },
                    if parked { "P" } else { "p" },
                    if home { "H" } else { "" },
                )
            }
            ":GW#" if meade => {
                if parked {
                    "PN0#".into()
                } else {
                    "PT1#".into()
                }
            }

            ":hP#" => {
                parked = true;
                tracking = false;
                onstep_ack.into()
            }
            ":hR#" if onstep => {
                parked = false;
                onstep_ack.into()
            }
            ":PO#" if matches!(flavor, TenMicron | Generic) || meade => {
                parked = false;
                String::new()
            }
            ":hW#" if flavor == Losmandy => {
                parked = false;
                tracking = true;
                String::new()
            }
            ":Te#" if onstep => {
                tracking = true;
                onstep_ack.into()
            }
            ":Td#" if onstep => {
                tracking = false;
                onstep_ack.into()
            }
            ":AP#" if flavor == TenMicron => {
                tracking = true;
                String::new()
            }
            ":AL#" if flavor == TenMicron => {
                tracking = false;
                String::new()
            }
            ":pS#" if flavor == TenMicron => "West#".into(),
            // Goes home.
            ":hC#" if onstep => {
                home = true;
                slew_polls_left = 1;
                String::new()
            }
            // Declares the mount at home where it stands; nothing moves.
            ":hF#" if onstep => {
                home = true;
                String::new()
            }
            ":hQ#" if onstep => "1".into(),

            ":Gt#" => "+40*00#".into(),
            ":Gg#" if meade => "075*23#".into(),
            ":Gg#" => "+075*23#".into(),
            ":GL#" => "22:30:00#".into(),
            ":GC#" => "09/08/26#".into(),
            ":GG#" => {
                if flavor == Nyx {
                    "+04:00#".into()
                } else {
                    "+04#".into()
                }
            }

            other if other.starts_with(":SC") => {
                if meade {
                    "1Updating Planetary Data#                              #".into()
                } else {
                    "1".into()
                }
            }
            other if other.starts_with(":Sr") || other.starts_with(":Sd") => {
                if target_shape_accepted(other, onstep, high_precision) {
                    "1".into()
                } else {
                    "0".into()
                }
            }
            // The Meade command set has no sign on the longitude.
            other if other.starts_with(":Sg") && meade && other[3..].starts_with(['+', '-']) => {
                "0".into()
            }
            other
                if [":St", ":Sg", ":SG", ":SL"]
                    .iter()
                    .any(|prefix| other.starts_with(prefix)) =>
            {
                "1".into()
            }
            _ => String::new(),
        };

        let mut bytes = reply.into_bytes();
        if flavor == Nyx && bytes.last() == Some(&b'#') {
            bytes.extend_from_slice(b"\r\n");
        }
        bytes
    })
}
