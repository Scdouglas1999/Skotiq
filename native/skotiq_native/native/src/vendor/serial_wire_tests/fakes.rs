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
