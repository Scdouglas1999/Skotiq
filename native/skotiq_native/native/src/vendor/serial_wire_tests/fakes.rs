//! Scripted mounts: each answers the commands its protocol's driver sends the
//! way that driver expects, and keeps just enough state (tracking, slewing,
//! parked) for the answers to follow the session.

use super::Responder;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Switches a test flips while a session runs.
#[derive(Default)]
pub(super) struct Knobs {
    /// The next goto is refused.
    pub refuse_goto: AtomicBool,
}

pub(super) fn silent() -> Responder {
    Box::new(|_, _| Vec::new())
}

fn text(command: &[u8]) -> String {
    String::from_utf8_lossy(command).into_owned()
}

// Sky-Watcher motor controller

#[derive(Default, Clone, Copy)]
struct SynScanAxis {
    tracking_mode: bool,
    running: bool,
    goto_polls_left: u32,
}

/// `answer_baud`: answer only when the port is set to this baud rate.
pub(super) fn synscan(answer_baud: Option<u32>, knobs: Arc<Knobs>) -> Responder {
    let mut axes = [SynScanAxis::default(); 2];
    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let command = text(command);
        let mut chars = command.chars().skip(1);
        let kind = chars.next().unwrap_or(' ');
        let axis_char = chars.next().unwrap_or('1');
        let data: String = chars.take_while(|c| *c != '\r').collect();
        let axis = &mut axes[if axis_char == '2' { 1 } else { 0 }];

        let reply = match kind {
            'F' => "=".to_string(),
            'e' => {
                if axis_char == '2' {
                    "=030701".to_string()
                } else {
                    "=030700".to_string()
                }
            }
            // 5.5 h on the RA axis, +20 degrees on Dec.
            'j' => {
                if axis_char == '2' {
                    "=E3388E".to_string()
                } else {
                    "=AAAABA".to_string()
                }
            }
            'f' => {
                let mut running = axis.running;
                if running && !axis.tracking_mode {
                    if axis.goto_polls_left == 0 {
                        axis.running = false;
                        running = false;
                    } else {
                        axis.goto_polls_left -= 1;
                    }
                }
                format!(
                    "={}{}1",
                    if axis.tracking_mode { 1 } else { 0 },
                    if running { 1 } else { 0 }
                )
            }
            'G' => {
                let mode = u8::from_str_radix(&data, 16).unwrap_or(0);
                axis.tracking_mode = mode & 0x01 != 0;
                "=".to_string()
            }
            'J' => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    "!4".to_string()
                } else {
                    axis.running = true;
                    axis.goto_polls_left = 1;
                    "=".to_string()
                }
            }
            'K' => {
                axis.running = false;
                "=".to_string()
            }
            _ => "=".to_string(),
        };
        format!("{reply}\r").into_bytes()
    })
}

pub(super) fn ioptron(answer_baud: Option<u32>, knobs: Arc<Knobs>) -> Responder {
    let mut tracking = true;
    let mut slew_polls_left = 0u32;
    let mut parked = false;
    let mut home = false;
    let mut rate = '0';
    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let command = text(command);
        let reply: String = match command.as_str() {
            ":MountInfo#" => "CEM60#".into(),
            ":FW1#" => "260525240101#".into(),
            ":FW2#" => "230201230202#".into(),
            ":GEC#" => "05300000+20000000#".into(),
            ":GAC#" => "+45300000180150000#".into(),
            ":GLS#" => "03154200#".into(),
            ":AG#" => "0.50#".into(),
            ":GAS#" => {
                let slewing = slew_polls_left > 0;
                slew_polls_left = slew_polls_left.saturating_sub(1);
                format!(
                    "{}{}{}0{}{}11#",
                    if tracking { 1 } else { 0 },
                    if slewing { 1 } else { 0 },
                    rate,
                    if home { 1 } else { 0 },
                    if parked { 1 } else { 0 },
                )
            }
            ":MS#" => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    "0#".into()
                } else {
                    slew_polls_left = 2;
                    home = false;
                    "1#".into()
                }
            }
            ":MH#" => {
                slew_polls_left = 1;
                home = true;
                "1#".into()
            }
            ":CM#" => "1#".into(),
            ":ST0#" => {
                tracking = false;
                "1#".into()
            }
            ":ST1#" => {
                tracking = true;
                "1#".into()
            }
            ":MP1#" => {
                parked = true;
                "1#".into()
            }
            ":MP0#" => {
                parked = false;
                "1#".into()
            }
            ":Q#" => String::new(),
            other if other.starts_with(":RT") => {
                rate = other.chars().nth(3).unwrap_or('0');
                "1#".into()
            }
            other if other.starts_with(":Sr") || other.starts_with(":Sd") => "1#".into(),
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
