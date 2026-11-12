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
    /// Classic Meade firmware.
    Meade,
    /// OnStep answering exactly what the driver reads.
    OnStep,
    /// OnStep the way the Pegasus NYX-101 speaks it: CRLF after every
    /// `#`-terminated reply, a `1` in answer to park, unpark and tracking
    /// on/off, and `+04:00` for the UTC offset.
    Nyx,
    Losmandy,
    TenMicron,
    Generic,
    /// A compatible mount that answers coordinates but no product name.
    CoordinatesOnly,
}

pub(super) fn lx200(flavor: Lx200Flavor, answer_baud: Option<u32>, knobs: Arc<Knobs>) -> Responder {
    use Lx200Flavor::*;
    let onstep = matches!(flavor, OnStep | Nyx);
    let mut tracking = true;
    let mut slew_polls_left = 0u32;
    let mut parked = false;
    let mut home = false;

    Box::new(move |command, baud| {
        if answer_baud.is_some_and(|wanted| wanted != baud) {
            return Vec::new();
        }
        let command = text(command);
        let nyx_ack = if flavor == Nyx { "1" } else { "" };

        let reply: String = match command.as_str() {
            ":GR#" => "05:30:00#".into(),
            ":GD#" => "+20*00:00#".into(),
            _ if flavor == CoordinatesOnly => String::new(),

            ":GVP#" => match flavor {
                Meade => "LX200 Classic#",
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

            ":GA#" => "+45*30:00#".into(),
            ":GZ#" => "180*15:00#".into(),
            ":GS#" => "03:15:42#".into(),

            ":MS#" => {
                if knobs.refuse_goto.load(Ordering::SeqCst) {
                    match flavor {
                        Meade => "1Object Below Horizon #",
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
            ":CM#" => {
                if onstep {
                    "N/A#".into()
                } else {
                    " M31 EX GAL MAG 3.5 SZ178.0'#".into()
                }
            }

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
            ":GW#" if flavor == Meade => {
                if parked {
                    "PN0#".into()
                } else {
                    "PT1#".into()
                }
            }

            ":hP#" => {
                parked = true;
                nyx_ack.into()
            }
            ":hR#" | ":PO#" => {
                parked = false;
                nyx_ack.into()
            }
            ":Te#" if onstep => {
                tracking = true;
                nyx_ack.into()
            }
            ":Td#" if onstep => {
                tracking = false;
                nyx_ack.into()
            }
            ":hF#" if onstep => {
                home = true;
                slew_polls_left = 1;
                String::new()
            }
            ":hQ#" if onstep => "1".into(),

            ":Gt#" => "+40*00#".into(),
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
                if flavor == Meade {
                    "1Updating Planetary Data#                              #".into()
                } else {
                    "1".into()
                }
            }
            other
                if [":Sr", ":Sd", ":St", ":Sg", ":SG", ":SL"]
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
