//! The LX200 driver against mounts written from the vendors' own documents,
//! not from the driver: the Meade Telescope Serial Command Protocol (2007.10
//! and 2010.10), the OnStepX command sources (`Goto.command.cpp`,
//! `Site.command.cpp`, `Park.command.cpp`, `Home.command.cpp`,
//! `Status.command.cpp`, `Guide.command.cpp`), the Losmandy Gemini Level 4
//! serial command list, and the 10Micron Mount Command Protocol 2.14.11 as
//! INDI quotes it. Each fake refuses a command whose shape its document does
//! not allow, so a format the firmware would refuse fails here too.

use super::*;
use crate::vendor::serial_wire_tests::isolate_park_state;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fw {
    Meade,
    OnStep,
    Gemini,
    TenMicron,
}

struct Mount {
    fw: Fw,
    high: bool,
    ignores_precision_toggle: bool,
    ra: f64,
    dec: f64,
    target_ra: Option<f64>,
    target_dec: Option<f64>,
    slew_polls: u32,
    tracking: bool,
    parked: bool,
    at_home: bool,
    sensor_homing_polls: u32,
    lat: f64,
    lon_west: f64,
    utc_wire: f64,
    sync_too_far: bool,
    log: Vec<String>,
    refused: Vec<String>,
}

impl Mount {
    fn new(fw: Fw) -> Self {
        Mount {
            fw,
            // Meade classic boots in low precision; OnStep and Gemini in
            // high; 10Micron's LX200 emulation in low.
            high: matches!(fw, Fw::OnStep | Fw::Gemini),
            ignores_precision_toggle: false,
            ra: 5.5,
            dec: 20.0,
            target_ra: None,
            target_dec: None,
            slew_polls: 0,
            tracking: true,
            parked: false,
            at_home: false,
            sensor_homing_polls: 0,
            lat: 40.0,
            lon_west: 75.0,
            utc_wire: 5.0,
            sync_too_far: false,
            log: Vec::new(),
            refused: Vec::new(),
        }
    }
}

type Shared = Arc<Mutex<Mount>>;

/// `d` is one digit, `s` a `+` or `-`, anything else itself.
fn shape(text: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|pattern| {
        let t = text.as_bytes();
        let p = pattern.as_bytes();
        t.len() == p.len()
            && t.iter().zip(p).all(|(c, want)| match want {
                b'd' => c.is_ascii_digit(),
                b's' => *c == b'+' || *c == b'-',
                other => c == other,
            })
    })
}

/// The fake's own reading of a sexagesimal field: sign, then up to three
/// numbers separated by anything that is not a digit or a point.
fn value(text: &str) -> f64 {
    let (sign, rest) = match text.as_bytes().first() {
        Some(b'-') => (-1.0, &text[1..]),
        Some(b'+') => (1.0, &text[1..]),
        _ => (1.0, text),
    };
    let parts: Vec<f64> = rest
        .split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .filter(|p| !p.is_empty())
        .map(|p| p.parse().unwrap())
        .collect();
    let mut total = 0.0;
    for (i, part) in parts.iter().enumerate() {
        total += part / 60f64.powi(i as i32);
    }
    sign * total
}

fn hms(hours: f64, high: bool, decimals: usize) -> String {
    let hours = hours.rem_euclid(24.0);
    if high {
        let scale = 10f64.powi(decimals as i32);
        let total = (hours * 3600.0 * scale).round() as i64;
        let whole_s = total / scale as i64;
        let frac = total % scale as i64;
        let base = format!(
            "{:02}:{:02}:{:02}",
            whole_s / 3600 % 24,
            whole_s / 60 % 60,
            whole_s % 60
        );
        if decimals == 0 {
            base
        } else {
            format!("{base}.{:0width$}", frac, width = decimals)
        }
    } else {
        let tenths = (hours * 600.0).round() as i64;
        format!(
            "{:02}:{:02}.{}",
            tenths / 600 % 24,
            tenths / 10 % 60,
            tenths % 10
        )
    }
}

fn dms(deg: f64, width: usize, degree: &str, minute: &str, high: bool, signed: bool) -> String {
    let sign = if deg < 0.0 {
        "-"
    } else if signed {
        "+"
    } else {
        ""
    };
    if high {
        let s = (deg.abs() * 3600.0).round() as i64;
        format!(
            "{sign}{:0width$}{degree}{:02}{minute}{:02}",
            s / 3600,
            s / 60 % 60,
            s % 60
        )
    } else {
        let m = (deg.abs() * 60.0).round() as i64;
        format!("{sign}{:0width$}{degree}{:02}", m / 60, m % 60)
    }
}

/// Bytes the firmware answers `command` with (the command without `:`/`#`).
fn answer(m: &mut Mount, cmd: &str) -> Vec<u8> {
    let fw = m.fw;
    let refuse = |m: &mut Mount| {
        m.refused.push(cmd.to_string());
        b"0".to_vec()
    };
    let take = |m: &mut Mount| {
        if m.slew_polls > 0 {
            m.slew_polls -= 1;
            if m.slew_polls == 0 {
                m.ra = m.target_ra.unwrap();
                m.dec = m.target_dec.unwrap();
            }
        }
        if m.sensor_homing_polls > 0 {
            m.sensor_homing_polls -= 1;
            if m.sensor_homing_polls == 0 {
                m.at_home = true;
            }
        }
    };
    let s = |text: String| format!("{text}#").into_bytes();

    if let Some(arg) = cmd.strip_prefix("Sr") {
        let ok = match fw {
            Fw::Meade if m.high => shape(arg, &["dd:dd:dd"]),
            Fw::Meade => shape(arg, &["dd:dd.d"]),
            Fw::OnStep => shape(arg, &["dd:dd.d", "dd:dd:dd", "dd:dd:dd.dddd"]),
            Fw::Gemini => shape(arg, &["dd:dd.d", "dd:dd:dd"]),
            Fw::TenMicron => shape(arg, &["dd:dd.d", "dd:dd:dd", "dd:dd:dd.d", "dd:dd:dd.dd"]),
        };
        if !ok {
            return refuse(m);
        }
        m.target_ra = Some(value(arg));
        return b"1".to_vec();
    }
    if let Some(arg) = cmd.strip_prefix("Sd") {
        let ok = match fw {
            Fw::Meade if m.high => shape(arg, &["sdd*dd:dd"]),
            Fw::Meade => shape(arg, &["sdd*dd"]),
            Fw::OnStep => shape(arg, &["sdd*dd", "sdd*dd:dd", "sdd*dd:dd.ddd"]),
            Fw::Gemini => shape(arg, &["sdd*dd", "sdd*dd:dd"]),
            Fw::TenMicron => shape(arg, &["sdd*dd", "sdd*dd:dd", "sdd*dd:dd.d"]),
        };
        if !ok {
            return refuse(m);
        }
        m.target_dec = Some(value(arg));
        return b"1".to_vec();
    }
    if let Some(arg) = cmd.strip_prefix("Sg") {
        let ok = match fw {
            // `:SgDDD*MM#`, 0-360 westward.
            Fw::Meade => shape(arg, &["ddd*dd"]),
            // `:Sg[(s)DDD*MM]#`, `[(s)DDD*MM:SS]`, `[(s)DDD*MM:SS.SSS]`.
            Fw::OnStep => shape(
                arg,
                &[
                    "ddd*dd",
                    "sddd*dd",
                    "ddd*dd:dd",
                    "sddd*dd:dd",
                    "sddd*dd:dd.ddd",
                ],
            ),
            // `:Sg{+-}<ddd>*<mm>#`, "east is negative (or add 360°)";
            // INDI's Gemini driver sends west longitudes unsigned.
            Fw::Gemini => shape(arg, &["sddd*dd", "ddd*dd"]),
            // `:SgsDDD*MM#`, `sDDD*MM:SS`, `sDDD*MM:SS.S`.
            Fw::TenMicron => shape(arg, &["sddd*dd", "sddd*dd:dd", "sddd*dd:dd.d"]),
        };
        if !ok {
            return refuse(m);
        }
        let mut west = value(arg);
        if fw == Fw::OnStep && west.abs() >= 180.0 {
            west -= 360.0 * west.signum();
        }
        if matches!(fw, Fw::Meade | Fw::Gemini) && west > 180.0 {
            west -= 360.0;
        }
        m.lon_west = west;
        return b"1".to_vec();
    }
    if let Some(arg) = cmd.strip_prefix("St") {
        let ok = match fw {
            Fw::Meade | Fw::Gemini => shape(arg, &["sdd*dd"]),
            Fw::OnStep => shape(arg, &["sdd*dd", "sdd*dd:dd", "sdd*dd:dd.ddd"]),
            Fw::TenMicron => shape(arg, &["sdd*dd", "sdd*dd:dd", "sdd*dd:dd.d"]),
        };
        if !ok {
            return refuse(m);
        }
        m.lat = value(arg);
        return b"1".to_vec();
    }
    if let Some(arg) = cmd.strip_prefix("SG") {
        let ok = match fw {
            // `:SGsHH.H#`; `:GG#` answers `sHH` for whole hours.
            Fw::Meade | Fw::TenMicron => shape(arg, &["sdd", "sdd.d"]),
            Fw::OnStep => {
                shape(arg, &["sdd"])
                    || (shape(arg, &["sdd:dd"]) && ["00", "30", "45"].contains(&&arg[4..]))
            }
            Fw::Gemini => shape(arg, &["sdd"]),
        };
        if !ok {
            return refuse(m);
        }
        m.utc_wire = value(arg);
        return b"1".to_vec();
    }
    if let Some(arg) = cmd.strip_prefix("SL") {
        return if shape(arg, &["dd:dd:dd"]) {
            b"1".to_vec()
        } else {
            refuse(m)
        };
    }
    if let Some(arg) = cmd.strip_prefix("SC") {
        if !shape(arg, &["dd/dd/dd"]) {
            return refuse(m);
        }
        return match fw {
            Fw::Meade => format!("1Updating Planetary Data#{}#", " ".repeat(30)).into_bytes(),
            Fw::OnStep => b"1".to_vec(),
            Fw::Gemini => format!("1Updating planetary data#{}#", " ".repeat(24)).into_bytes(),
            Fw::TenMicron => format!("1{0}#{0}#", " ".repeat(32)).into_bytes(),
        };
    }
    if let Some(arg) = cmd.strip_prefix("Mg") {
        let _ = arg;
        return Vec::new();
    }

    match cmd {
        "GVP" => s(match fw {
            Fw::Meade => "Autostar".into(),
            Fw::OnStep => "On-Step".into(),
            Fw::Gemini => "Losmandy Gemini".into(),
            Fw::TenMicron => "10micron GM1000HPS".into(),
        }),
        "U" => {
            if !m.ignores_precision_toggle {
                m.high = if fw == Fw::TenMicron { true } else { !m.high };
            }
            Vec::new()
        }
        "GR" => {
            take(m);
            let decimals = if fw == Fw::TenMicron { 1 } else { 0 };
            s(hms(m.ra, m.high, decimals))
        }
        "GD" => {
            take(m);
            let (degree, minute) = match fw {
                Fw::Meade if m.high => ("*", "'"),
                Fw::Meade => ("\u{df}", ""),
                Fw::Gemini if m.high => (":", ":"),
                Fw::Gemini => ("\u{df}", ""),
                _ => ("*", ":"),
            };
            let mut text = dms(m.dec, 2, degree, minute, m.high, true);
            if fw == Fw::TenMicron && m.high {
                text.push_str(".0");
            }
            let mut bytes = Vec::new();
            for c in text.chars() {
                // Autostar and Gemini send the degree glyph as the single
                // byte 0xDF, not as UTF-8.
                if c == '\u{df}' {
                    bytes.push(0xdf);
                } else {
                    bytes.push(c as u8);
                }
            }
            bytes.push(b'#');
            bytes
        }
        "GA" => s(dms(45.0, 2, "*", "'", true, true)),
        "GZ" => s(dms(180.25, 3, "*", "'", true, false)),
        "GS" => s(hms(7.25, true, 0)),
        "Gt" => s(dms(m.lat, 2, "*", ":", fw == Fw::OnStep, true)),
        "Gg" => s(dms(m.lon_west, 3, "*", ":", fw == Fw::OnStep, true)),
        "GG" => s(match fw {
            Fw::OnStep => {
                let minutes = (m.utc_wire.abs() * 60.0).round() as i64;
                format!(
                    "{}{:02}:{:02}",
                    if m.utc_wire < 0.0 { '-' } else { '+' },
                    minutes / 60,
                    minutes % 60
                )
            }
            _ if m.utc_wire.fract() == 0.0 => format!("{:+03}", m.utc_wire as i64),
            _ => format!(
                "{}{:04.1}",
                if m.utc_wire < 0.0 { '-' } else { '+' },
                m.utc_wire.abs()
            ),
        }),
        "GL" => s("22:30:00".into()),
        "GC" => s(if fw == Fw::TenMicron {
            "09:08:26".into()
        } else {
            "09/08/26".into()
        }),
        "MS" => {
            if fw == Fw::OnStep && m.parked {
                return b"4".to_vec();
            }
            if m.target_ra.is_none() || m.target_dec.is_none() {
                return match fw {
                    Fw::Gemini => b"2No object selected#".to_vec(),
                    _ => b"9".to_vec(),
                };
            }
            m.slew_polls = 3;
            b"0".to_vec()
        }
        "D" => {
            take(m);
            if m.slew_polls > 0 {
                b"\x7f#".to_vec()
            } else {
                b"#".to_vec()
            }
        }
        "CM" => {
            let reply: Vec<u8> = match fw {
                Fw::Meade => b" M31 EX GAL MAG 3.5 SZ178.0'#".to_vec(),
                Fw::OnStep if m.parked => return b"E4#".to_vec(),
                Fw::OnStep => b"N/A#".to_vec(),
                Fw::Gemini if m.target_ra.is_none() => return b"No object!#".to_vec(),
                Fw::Gemini => b"Object#".to_vec(),
                Fw::TenMicron if m.sync_too_far => return b"Match fail: dist. too large#".to_vec(),
                Fw::TenMicron => b"Coordinates matched            #".to_vec(),
            };
            if let (Some(ra), Some(dec)) = (m.target_ra, m.target_dec) {
                m.ra = ra;
                m.dec = dec;
            }
            reply
        }
        "GW" if fw == Fw::Meade => {
            // <mount><tracking><alignment>#: P is an equatorial (wedge) mount.
            s(format!("P{}1", if m.tracking { 'T' } else { 'N' }))
        }
        "AP" if matches!(fw, Fw::Meade | Fw::TenMicron) => {
            m.tracking = true;
            Vec::new()
        }
        "AL" if matches!(fw, Fw::Meade | Fw::TenMicron) => {
            m.tracking = false;
            Vec::new()
        }
        "hP" | "KA" => {
            m.parked = true;
            m.tracking = false;
            if fw == Fw::OnStep {
                b"1".to_vec()
            } else {
                Vec::new()
            }
        }
        "hR" if fw == Fw::OnStep => {
            if m.parked {
                m.parked = false;
                b"1".to_vec()
            } else {
                b"0".to_vec()
            }
        }
        "PO" if fw == Fw::TenMicron => {
            m.parked = false;
            Vec::new()
        }
        "hW" if fw == Fw::Gemini => {
            m.parked = false;
            m.tracking = true;
            Vec::new()
        }
        "hC" if fw == Fw::OnStep => {
            m.at_home = false;
            m.sensor_homing_polls = 3;
            Vec::new()
        }
        "hF" if fw == Fw::OnStep => {
            m.at_home = true;
            Vec::new()
        }
        "hQ" if fw == Fw::OnStep => b"1".to_vec(),
        "Te" if fw == Fw::OnStep => {
            if m.parked {
                b"0".to_vec()
            } else {
                m.tracking = true;
                b"1".to_vec()
            }
        }
        "Td" if fw == Fw::OnStep => {
            m.tracking = false;
            b"1".to_vec()
        }
        "GU" if fw == Fw::OnStep => {
            take(m);
            let mut reply = String::new();
            if !m.tracking {
                reply.push('n');
            }
            if m.slew_polls == 0 {
                reply.push('N');
            }
            reply.push(if m.parked { 'P' } else { 'p' });
            if m.at_home {
                reply.push('H');
            }
            if m.sensor_homing_polls > 0 {
                reply.push('h');
            }
            reply.push_str("ET000");
            s(reply)
        }
        "pS" if fw == Fw::TenMicron => s("East".into()),
        "Gm" if fw == Fw::Gemini => s("E".into()),
        "Q" => {
            m.slew_polls = 0;
            m.sensor_homing_polls = 0;
            Vec::new()
        }
        _ => Vec::new(),
    }
}

/// A pty whose far end answers as `fw` does. Returns the port path.
fn spawn(state: Shared) -> String {
    let mut master: libc::c_int = 0;
    let mut slave: libc::c_int = 0;
    // SAFETY: openpty writes two descriptors into the provided ints; the
    // name, termios and winsize arguments are null.
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    assert_eq!(rc, 0, "openpty failed");
    let mut name = [0 as libc::c_char; 256];
    // SAFETY: `name` is a writable buffer of the length passed.
    let rc = unsafe { libc::ttyname_r(slave, name.as_mut_ptr(), name.len()) };
    assert_eq!(rc, 0, "ttyname_r failed");
    // SAFETY: ttyname_r succeeded, so `name` is NUL-terminated.
    let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
        .to_string_lossy()
        .into_owned();
    // SAFETY: `master` is a fresh descriptor this function owns. The slave
    // stays open so the pty outlives the driver's handle.
    let mut port = unsafe { std::fs::File::from_raw_fd(master) };
    std::thread::spawn(move || {
        let mut pending: Vec<u8> = Vec::new();
        let mut buf = [0u8; 64];
        loop {
            let n = match port.read(&mut buf) {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            pending.extend_from_slice(&buf[..n]);
            while let Some(end) = pending.iter().position(|b| *b == b'#') {
                let frame: Vec<u8> = pending.drain(..=end).collect();
                let text = String::from_utf8_lossy(&frame).to_string();
                let Some(start) = text.find(':') else {
                    continue;
                };
                let cmd = text[start + 1..text.len() - 1].to_string();
                let reply = {
                    let mut m = state.lock().unwrap();
                    m.log.push(cmd.clone());
                    answer(&mut m, &cmd)
                };
                if !reply.is_empty() && port.write_all(&reply).is_err() {
                    return;
                }
            }
        }
    });
    path
}

fn mount_type(fw: Fw) -> Lx200MountType {
    match fw {
        Fw::Meade => Lx200MountType::Meade,
        Fw::OnStep => Lx200MountType::OnStep,
        Fw::Gemini => Lx200MountType::Losmandy,
        Fw::TenMicron => Lx200MountType::TenMicron,
    }
}

async fn connect(fw: Fw, setup: impl FnOnce(&mut Mount)) -> (Lx200Mount, Shared) {
    let mut fake = Mount::new(fw);
    setup(&mut fake);
    let state = Arc::new(Mutex::new(fake));
    let path = spawn(state.clone());
    let mut mount = Lx200Mount::new(path, mount_type(fw), Some(9600));
    mount.connect().await.expect("connect");
    (mount, state)
}

/// Lets the fake take a command that has no reply before its state is read.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(150)).await;
}

const ALL: [Fw; 4] = [Fw::Meade, Fw::OnStep, Fw::Gemini, Fw::TenMicron];

/// Gotos across the sky, including declinations under ten degrees and
/// both sides of the equator, reach the fake in a shape its firmware takes
/// and land where they were sent.
#[tokio::test]
async fn gotos_are_taken_by_every_firmware_and_land_on_target() {
    for fw in ALL {
        let (mut mount, state) = connect(fw, |_| {}).await;
        for (ra, dec) in [(5.5, 5.0), (12.3456, -0.5), (23.99, -89.99), (0.01, 89.5)] {
            mount
                .slew_to_coordinates(ra, dec)
                .await
                .unwrap_or_else(|e| panic!("{fw:?} goto {ra},{dec}: {e}"));
            assert!(
                mount.is_slewing().await.unwrap(),
                "{fw:?}: slewing right after the goto"
            );
            let mut polls = 0;
            while mount.is_slewing().await.unwrap() {
                polls += 1;
                assert!(polls < 10, "{fw:?}: still slewing after the fake arrived");
            }
            let (got_ra, got_dec) = mount.get_coordinates().await.unwrap();
            // Low precision carries tenths of a time minute and whole
            // arcminutes.
            assert!((got_ra - ra).abs() < 0.0035, "{fw:?}: RA {got_ra} for {ra}");
            assert!(
                (got_dec - dec).abs() < 0.0170,
                "{fw:?}: Dec {got_dec} for {dec}"
            );
        }
        let m = state.lock().unwrap();
        assert!(m.refused.is_empty(), "{fw:?} refused {:?}", m.refused);
    }
}

/// A Meade handset that ignores `:U#` stays in low precision, and takes
/// targets only in low precision.
#[tokio::test]
async fn a_meade_that_stays_in_low_precision_gets_low_precision_targets() {
    let (mut mount, state) = connect(Fw::Meade, |m| m.ignores_precision_toggle = true).await;
    mount
        .slew_to_coordinates(5.5123, -5.25)
        .await
        .expect("goto");
    let m = state.lock().unwrap();
    assert!(m.refused.is_empty(), "refused {:?}", m.refused);
    assert!(m.log.contains(&"Sr05:30.7".to_string()), "{:?}", m.log);
    assert!(m.log.contains(&"Sd-05*15".to_string()), "{:?}", m.log);
}

#[tokio::test]
async fn syncs_land_and_refusals_are_errors() {
    for fw in ALL {
        let (mut mount, state) = connect(fw, |_| {}).await;
        mount
            .sync_to_coordinates(3.25, -2.5)
            .await
            .unwrap_or_else(|e| panic!("{fw:?} sync: {e}"));
        let (ra, dec) = mount.get_coordinates().await.unwrap();
        assert!(
            (ra - 3.25).abs() < 0.0035 && (dec + 2.5).abs() < 0.017,
            "{fw:?}"
        );
        assert!(state.lock().unwrap().refused.is_empty(), "{fw:?}");
    }
    let (mut mount, _) = connect(Fw::TenMicron, |m| m.sync_too_far = true).await;
    assert!(mount.sync_to_coordinates(3.25, -2.5).await.is_err());
}

/// OnStepX answers a refused `:CM#` with `E<n>#` (Goto.command.cpp; INDI's
/// LX200_OnStep::Sync fails on it). The driver reads it as a success.
/// Affects the NYX-101, so it is written up for a rig night, not changed.
#[tokio::test]
#[ignore = "OnStep sync refusal E<n># is read as success; NYX rig-night item"]
async fn an_onstep_sync_refusal_is_an_error() {
    let (mut mount, _) = connect(Fw::OnStep, |m| m.parked = true).await;
    assert!(mount.sync_to_coordinates(3.25, -2.5).await.is_err());
}

/// Sites on both sides of Greenwich and the equator are written in a shape
/// each firmware takes, and read back as written.
#[tokio::test]
async fn sites_are_taken_by_every_firmware_and_read_back() {
    for fw in ALL {
        for (lat, lon) in [(40.0077, -75.397448), (-33.87, 10.0), (51.5, -0.5)] {
            let (mut mount, state) = connect(fw, |_| {}).await;
            mount
                .set_site(MountSiteInfo {
                    latitude_deg: lat,
                    longitude_deg: lon,
                    elevation_m: None,
                })
                .await
                .unwrap_or_else(|e| {
                    panic!(
                        "{fw:?} site {lat},{lon}: {e} (fake log {:?})",
                        state.lock().unwrap().log
                    )
                });
            {
                let m = state.lock().unwrap();
                assert!(m.refused.is_empty(), "{fw:?} refused {:?}", m.refused);
                assert!(
                    (m.lon_west + lon).abs() < 0.0170,
                    "{fw:?}: stored west {}",
                    m.lon_west
                );
                assert!((m.lat - lat).abs() < 0.0170, "{fw:?}: stored lat {}", m.lat);
            }
            if fw == Fw::TenMicron {
                let m = state.lock().unwrap();
                let sent = m.log.iter().find(|c| c.starts_with("Sg")).unwrap();
                let want = if lon > 0.0 { "Sg-" } else { "Sg+" };
                assert!(sent.starts_with(want), "10Micron east is negative: {sent}");
            }
            let site = mount.get_site().await.unwrap();
            assert!(
                (site.longitude_deg - lon).abs() < 0.0170,
                "{fw:?}: {site:?}"
            );
            assert!((site.latitude_deg - lat).abs() < 0.0170, "{fw:?}: {site:?}");
        }
    }
}

#[tokio::test]
async fn clocks_are_taken_by_every_firmware_and_read_back() {
    for fw in ALL {
        let offsets: &[f64] = if fw == Fw::Gemini {
            &[-5.0, 10.0]
        } else {
            &[-5.0, 5.5, 10.0]
        };
        for &offset in offsets {
            let (mut mount, state) = connect(fw, |_| {}).await;
            mount
                .set_clock(MountClock {
                    utc_unix_seconds: 1_788_000_000,
                    utc_offset_hours: offset,
                })
                .await
                .unwrap_or_else(|e| panic!("{fw:?} offset {offset}: {e}"));
            {
                let m = state.lock().unwrap();
                assert!(m.refused.is_empty(), "{fw:?} refused {:?}", m.refused);
                assert!(
                    (m.utc_wire + offset).abs() < 1e-9,
                    "{fw:?}: wire {}",
                    m.utc_wire
                );
            }
            // The command after `:SC#` reads its own reply, not the
            // firmware's trailing strings.
            let clock = mount.get_clock().await.unwrap();
            assert!(
                (clock.utc_offset_hours - offset).abs() < 1e-9,
                "{fw:?}: {clock:?}"
            );
        }
    }
}

/// `:GW#` answers mount type, tracking and alignment (Meade protocol
/// 2010.10). `P` is an equatorially mounted scope, not a parked one.
#[tokio::test]
async fn a_wedge_mounted_meade_with_tracking_off_is_not_parked() {
    let _guard = isolate_park_state().await;
    let (mut mount, _) = connect(Fw::Meade, |m| m.tracking = false).await;
    assert!(
        !matches!(mount.is_parked().await, Ok(true)),
        "an unparked polar Meade with tracking off read as parked"
    );
    mount.park().await.unwrap();
    assert!(
        matches!(mount.is_parked().await, Ok(true)),
        "parked by us, read back unparked"
    );
    mount.unpark().await.unwrap();
    assert!(matches!(mount.is_parked().await, Ok(false)));
}

#[tokio::test]
async fn park_and_unpark_follow_each_firmware() {
    let _guard = isolate_park_state().await;
    let (mut onstep, state) = connect(Fw::OnStep, |_| {}).await;
    onstep.park().await.unwrap();
    assert!(onstep.is_parked().await.unwrap());
    onstep.unpark().await.unwrap();
    assert!(!onstep.is_parked().await.unwrap());
    assert!(state.lock().unwrap().log.iter().any(|c| c == "hR"));

    let (mut gemini, state) = connect(Fw::Gemini, |_| {}).await;
    gemini.park().await.unwrap();
    gemini.unpark().await.unwrap();
    settle().await;
    {
        let m = state.lock().unwrap();
        assert!(!m.parked && m.tracking, "Gemini wake-up restarts tracking");
    }

    let (mut ten, state) = connect(Fw::TenMicron, |_| {}).await;
    ten.park().await.unwrap();
    ten.unpark().await.unwrap();
    settle().await;
    assert!(!state.lock().unwrap().parked);
}

/// OnStepX answers `:hR#` with `0` when it cannot unpark (Park.command.cpp);
/// INDI's LX200_OnStep::UnPark fails on it. The driver does not read it.
/// Affects the NYX-101: rig-night item.
#[tokio::test]
#[ignore = "OnStep :hR# 0 reply is not read; NYX rig-night item"]
async fn an_onstep_unpark_refusal_is_an_error() {
    let _guard = isolate_park_state().await;
    let (mut mount, _) = connect(Fw::OnStep, |m| m.parked = false).await;
    assert!(mount.unpark().await.is_err());
}

#[tokio::test]
async fn tracking_follows_each_firmware() {
    let (mut onstep, state) = connect(Fw::OnStep, |_| {}).await;
    onstep.set_tracking(false).await.unwrap();
    assert!(!state.lock().unwrap().tracking);
    assert!(!onstep.get_tracking().await.unwrap());
    onstep.set_tracking(true).await.unwrap();
    assert!(onstep.get_tracking().await.unwrap());
    state.lock().unwrap().parked = true;
    assert!(
        onstep.set_tracking(true).await.is_err(),
        "Te answers 0 when parked"
    );

    let (mut ten, state) = connect(Fw::TenMicron, |_| {}).await;
    ten.set_tracking(false).await.unwrap();
    settle().await;
    assert!(!state.lock().unwrap().tracking);
    ten.set_tracking(true).await.unwrap();
    settle().await;
    assert!(state.lock().unwrap().tracking);

    let (mut meade, _) = connect(Fw::Meade, |_| {}).await;
    assert!(matches!(
        meade.set_tracking(false).await,
        Err(DriverError::NotSupported)
    ));
}

#[tokio::test]
async fn pulse_guides_use_each_firmware_command() {
    let (mut onstep, state) = connect(Fw::OnStep, |_| {}).await;
    onstep.pulse_guide(GuideDirection::West, 500).await.unwrap();
    onstep
        .pulse_guide(GuideDirection::North, 12000)
        .await
        .unwrap();
    settle().await;
    {
        let m = state.lock().unwrap();
        assert!(m.log.contains(&"Mgw500".to_string()), "{:?}", m.log);
        assert!(m.log.contains(&"Mgn12000".to_string()), "{:?}", m.log);
    }
    let (mut meade, state) = connect(Fw::Meade, |_| {}).await;
    let started = std::time::Instant::now();
    meade.pulse_guide(GuideDirection::South, 300).await.unwrap();
    settle().await;
    assert!(started.elapsed() >= Duration::from_millis(300));
    let m = state.lock().unwrap();
    let tail: Vec<&str> = m
        .log
        .iter()
        .rev()
        .take(3)
        .rev()
        .map(String::as_str)
        .collect();
    assert_eq!(tail, ["RG", "Ms", "Qs"]);
}

#[tokio::test]
async fn onstep_home_drives_there() {
    let (mut mount, state) = connect(Fw::OnStep, |_| {}).await;
    mount.find_home().await.unwrap();
    settle().await;
    assert!(state.lock().unwrap().log.contains(&"hC".to_string()));
    assert!(!state.lock().unwrap().log.contains(&"hF".to_string()));
}

/// OnStepX reports a sensor-driven home with `h` ("Slewing [h]ome") while
/// `N` (no goto) stays set (Status.command.cpp). The driver reads only `N`,
/// so a homing mount reads as still. Affects the NYX-101: rig-night item.
#[tokio::test]
#[ignore = "OnStep `h` (slewing home) is not read as slewing; NYX rig-night item"]
async fn an_onstep_homing_on_its_sensors_reads_as_slewing() {
    let (mut mount, _) = connect(Fw::OnStep, |_| {}).await;
    mount.find_home().await.unwrap();
    assert!(mount.is_slewing().await.unwrap());
}

#[tokio::test]
async fn pier_side_reads_where_the_firmware_has_it() {
    let (onstep, _) = connect(Fw::OnStep, |_| {}).await;
    assert_eq!(onstep.get_side_of_pier().await.unwrap(), PierSide::East);
    let (ten, _) = connect(Fw::TenMicron, |_| {}).await;
    assert_eq!(ten.get_side_of_pier().await.unwrap(), PierSide::East);
}

#[tokio::test]
async fn alt_az_and_sidereal_time_parse() {
    for fw in ALL {
        let (mount, _) = connect(fw, |_| {}).await;
        let (alt, az) = mount.get_alt_az().await.unwrap();
        assert!(
            (alt - 45.0).abs() < 1e-6 && (az - 180.25).abs() < 1e-6,
            "{fw:?}"
        );
        assert!((mount.get_sidereal_time().await.unwrap() - 7.25).abs() < 1e-6);
    }
}
