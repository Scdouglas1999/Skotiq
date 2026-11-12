//! The Sky-Watcher driver against a motor controller emulated from the
//! Sky-Watcher Motor Controller Command Set (skywatcher.com, application
//! development downloads, dated 2021-08-25), not from the driver.
//!
//! The emulator moves its axes in real time the way the document describes:
//! in Tracking mode at `TMR_Freq / T1_Preset` microsteps per second (times
//! the high-speed ratio in fast mode), in Goto mode to the target increment
//! and then back to Tracking mode; it refuses what the document says needs a
//! stopped motor (`:E`, `:G`) or an initialized one (`:J`, error 4).
//!
//! Where the telescope points is worked out from the axis angles with a
//! rigid-body model of a German equatorial mount, not with the driver's (or
//! indi-eqmod's) piecewise encoder formulas. The only conventions taken from
//! indi-eqmod are the ones the document leaves open and real mounts settle:
//! at power-on the counterweight is down and the tube at the pole, a forward
//! RA step turns the axis with the sky in the northern hemisphere, and with
//! the counterweight down a forward Dec step from the pole tilts the tube
//! west. The southern hemisphere is the same mechanism with its polar axis on
//! the south pole.

use super::FakeMount;
use crate::vendor::skywatcher::SkyWatcherMount;
use chrono::{DateTime, TimeZone, Utc};
use skotiq_device::{
    DeviceDriver, GuideDirection, MountDriver, MountSiteInfo, PierSide, SiteSource,
};
use std::f64::consts::PI;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// An EQ6-R Pro: 9,024,000 counts per turn on both axes, 64,935 Hz timer.
const CPR: u32 = 9_024_000;
const TIMER_HZ: u32 = 64_935;
const HIGH_SPEED_RATIO: u32 = 32;
const POWER_ON: u32 = 0x80_0000;
/// The emulator's own goto speed (the controller chooses it, per the document).
const GOTO_STEPS_PER_SECOND: f64 = 4_000_000.0;
const SIDEREAL_ARCSEC_PER_SECOND: f64 = 15.041_067;

fn epoch() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

fn seconds() -> f64 {
    epoch().elapsed().as_secs_f64()
}

fn clock() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, 12, 3, 0, 0).unwrap()
        + chrono::Duration::microseconds((seconds() * 1e6) as i64)
}

/// Local sidereal time, hours, from the USNO approximation (not the
/// driver's Meeus series).
fn lst_hours(utc: DateTime<Utc>, longitude_east: f64) -> f64 {
    let jd = utc.timestamp_micros() as f64 / 86_400e6 + 2_440_587.5;
    let gmst = 18.697_374_558 + 24.065_709_824_419_08 * (jd - 2_451_545.0);
    (gmst + longitude_east / 15.0).rem_euclid(24.0)
}

#[derive(Debug, Clone, Copy)]
struct SimAxis {
    position: f64,
    initialized: bool,
    running: bool,
    goto: bool,
    fast: bool,
    backward: bool,
    period: u32,
    increment: u32,
    target: f64,
    updated: f64,
}

impl SimAxis {
    fn new(position: u32, initialized: bool) -> Self {
        Self {
            position: f64::from(position),
            initialized,
            running: false,
            goto: false,
            fast: false,
            backward: false,
            period: 0,
            increment: 0,
            target: 0.0,
            updated: seconds(),
        }
    }

    fn advance(&mut self, now: f64) {
        let dt = now - self.updated;
        self.updated = now;
        if !self.running {
            return;
        }
        if self.goto {
            let left = self.target - self.position;
            let step = GOTO_STEPS_PER_SECOND * dt;
            if left.abs() <= step {
                self.position = self.target;
                self.running = false;
                // "Channel will always be set to Tracking Mode after stopped."
                self.goto = false;
            } else {
                self.position += step * left.signum();
            }
        } else {
            let multiplier = if self.fast { HIGH_SPEED_RATIO } else { 1 };
            let speed = f64::from(TIMER_HZ) * f64::from(multiplier) / f64::from(self.period.max(1));
            let signed = if self.backward { -speed } else { speed };
            self.position += signed * dt;
        }
    }

    fn step(&self) -> u32 {
        (self.position.round() as i64).rem_euclid(1 << 24) as u32
    }

    /// Microsteps per second along the axis, signed forward.
    fn speed(&self) -> f64 {
        if !self.running || self.goto {
            return 0.0;
        }
        let multiplier = if self.fast { HIGH_SPEED_RATIO } else { 1 };
        let speed = f64::from(TIMER_HZ) * f64::from(multiplier) / f64::from(self.period.max(1));
        if self.backward {
            -speed
        } else {
            speed
        }
    }
}

#[derive(Debug)]
struct Controller {
    axes: [SimAxis; 2],
    /// `:e` data: major, minor, mount code.
    version: &'static str,
    commands: Vec<String>,
    refusals: Vec<String>,
}

fn u24(value: u32) -> String {
    format!(
        "{:02X}{:02X}{:02X}",
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF
    )
}

fn parse_u24(data: &str) -> Option<u32> {
    if data.len() != 6
        || !data
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase())
    {
        return None;
    }
    let byte = |i: usize| u32::from_str_radix(&data[i..i + 2], 16).ok();
    Some(byte(0)? | (byte(2)? << 8) | (byte(4)? << 16))
}

impl Controller {
    fn new(initialized: bool, ra: u32, dec: u32) -> Self {
        Self {
            axes: [
                SimAxis::new(ra, initialized),
                SimAxis::new(dec, initialized),
            ],
            version: "032723",
            commands: Vec::new(),
            refusals: Vec::new(),
        }
    }

    fn advance(&mut self) {
        let now = seconds();
        for axis in &mut self.axes {
            axis.advance(now);
        }
    }

    fn answer(&mut self, wire: &[u8]) -> Vec<u8> {
        let text = String::from_utf8_lossy(wire).to_string();
        self.commands.push(text.trim_end_matches('\r').to_string());
        self.advance();
        let reply = match self.reply(text.trim_end_matches('\r')) {
            Ok(data) => format!("={data}\r"),
            Err(code) => {
                self.refusals
                    .push(format!("{} -> !{code}", text.trim_end()));
                format!("!{code}\r")
            }
        };
        reply.into_bytes()
    }

    fn reply(&mut self, text: &str) -> Result<String, char> {
        let mut chars = text.chars();
        if chars.next() != Some(':') {
            return Err('3');
        }
        let letter = chars.next().ok_or('1')?;
        let channel = chars.next().ok_or('1')?;
        let data: String = chars.collect();
        let channels: Vec<usize> = match channel {
            '1' => vec![0],
            '2' => vec![1],
            '3' if letter == 'F' => vec![0, 1],
            _ => return Err('3'),
        };
        let first = channels[0];
        let need_stopped = |axes: &[SimAxis; 2]| channels.iter().any(|&i| axes[i].running);
        match letter {
            'e' => Ok(self.version.to_string()),
            'a' => Ok(u24(CPR)),
            'b' => Ok(u24(TIMER_HZ)),
            'g' => Ok(format!("{HIGH_SPEED_RATIO:02X}")),
            'j' => Ok(u24(self.axes[first].step())),
            'f' => {
                let a = &self.axes[first];
                let d0 = u8::from(!a.goto) | (u8::from(a.backward) << 1) | (u8::from(a.fast) << 2);
                Ok(format!(
                    "{:X}{:X}{:X}",
                    d0,
                    u8::from(a.running),
                    u8::from(a.initialized)
                ))
            }
            'F' => {
                for &i in &channels {
                    self.axes[i].initialized = true;
                }
                Ok(String::new())
            }
            'E' => {
                let value = parse_u24(&data).ok_or('1')?;
                if need_stopped(&self.axes) {
                    return Err('2');
                }
                self.axes[first].position = f64::from(value);
                Ok(String::new())
            }
            'G' => {
                let digits: Vec<u32> = data.chars().filter_map(|c| c.to_digit(16)).collect();
                if digits.len() != 2 {
                    return Err('1');
                }
                if need_stopped(&self.axes) {
                    return Err('2');
                }
                let a = &mut self.axes[first];
                let tracking = digits[0] & 1 != 0;
                let b1 = digits[0] & 2 != 0;
                a.goto = !tracking;
                a.fast = if tracking { b1 } else { !b1 };
                a.backward = digits[1] & 1 != 0;
                Ok(String::new())
            }
            'I' => {
                let value = parse_u24(&data).ok_or('1')?;
                let a = &mut self.axes[first];
                if a.running && a.fast && !a.goto {
                    return Err('2');
                }
                a.period = value;
                Ok(String::new())
            }
            'H' => {
                self.axes[first].increment = parse_u24(&data).ok_or('1')?;
                Ok(String::new())
            }
            'M' => {
                parse_u24(&data).ok_or('1')?;
                Ok(String::new())
            }
            'J' => {
                let a = &mut self.axes[first];
                if !a.initialized {
                    return Err('4');
                }
                if a.goto {
                    let distance = f64::from(a.increment);
                    a.target = a.position + if a.backward { -distance } else { distance };
                }
                a.running = true;
                Ok(String::new())
            }
            'K' | 'L' => {
                let a = &mut self.axes[first];
                a.running = false;
                a.goto = false;
                Ok(String::new())
            }
            'P' => Ok(String::new()),
            _ => Err('0'),
        }
    }
}

/// Where a rigid German equatorial mount points for these axis positions.
#[derive(Debug, Clone, Copy)]
struct Physical {
    ra_hours: f64,
    dec_degrees: f64,
    /// The tube is east of the pier (ASCOM `pierEast`, looking west).
    tube_east_of_pier: bool,
    counterweight_below_horizontal: bool,
}

fn physical(ra_step: u32, dec_step: u32, latitude: f64, lst: f64) -> Physical {
    let turns = |step: u32| (f64::from(step) - f64::from(POWER_ON)) / f64::from(CPR);
    // Mechanical frame: Z up the polar axis to the elevated pole, X toward
    // the meridian on the equator, Y = Z x X. Counterweight shaft at angle a
    // (pi at power-on, counterweight down), tube tilted r from the equator
    // toward the pole.
    let a = PI + 2.0 * PI * turns(ra_step);
    let r = 2.0 * PI * turns(dec_step);
    let u = (a + PI / 2.0).sin_cos();
    let (mx, my, mz) = (r.cos() * u.1, r.cos() * u.0, r.sin());
    // Sky frame: x meridian, y west (hour angle +6 h), z north pole.
    let southern = latitude < 0.0;
    let (x, y, z) = if southern {
        (mx, -my, -mz)
    } else {
        (mx, my, mz)
    };
    let dec = z.clamp(-1.0, 1.0).asin().to_degrees();
    let hour_angle = y.atan2(x).to_degrees() / 15.0;
    // East is -Y in the north (Y is west) and +Y in the south. The tube sits
    // opposite the counterweight shaft.
    let shaft_y = a.sin();
    let tube_east_of_pier = if southern {
        shaft_y < 0.0
    } else {
        shaft_y > 0.0
    };
    Physical {
        ra_hours: (lst - hour_angle).rem_euclid(24.0),
        dec_degrees: dec,
        tube_east_of_pier,
        counterweight_below_horizontal: a.cos() < 0.0,
    }
}

fn separation_arcsec(ra1: f64, dec1: f64, ra2: f64, dec2: f64) -> f64 {
    let (r1, d1, r2, d2) = (
        (ra1 * 15.0).to_radians(),
        dec1.to_radians(),
        (ra2 * 15.0).to_radians(),
        dec2.to_radians(),
    );
    let c = d1.sin() * d2.sin() + d1.cos() * d2.cos() * (r1 - r2).cos();
    c.clamp(-1.0, 1.0).acos().to_degrees() * 3600.0
}

struct Rig {
    fake: FakeMount,
    sim: Arc<Mutex<Controller>>,
    mount: SkyWatcherMount,
    latitude: f64,
    longitude: f64,
}

impl Rig {
    async fn connect(latitude: f64, longitude: f64, sim: Controller) -> Self {
        let sim = Arc::new(Mutex::new(sim));
        let responder_sim = sim.clone();
        let fake = FakeMount::spawn(
            b'\r',
            Box::new(move |wire, _baud| responder_sim.lock().unwrap().answer(wire)),
        );
        let site: SiteSource = Arc::new(move || {
            Some(MountSiteInfo {
                latitude_deg: latitude,
                longitude_deg: longitude,
                elevation_m: None,
            })
        });
        let mut mount =
            SkyWatcherMount::new_serial(fake.path.clone(), Some(9600), site).with_clock(clock);
        mount.connect().await.expect("connect");
        Self {
            fake,
            sim,
            mount,
            latitude,
            longitude,
        }
    }

    fn lst(&self) -> f64 {
        lst_hours(clock(), self.longitude)
    }

    fn sky(&self) -> Physical {
        let mut sim = self.sim.lock().unwrap();
        sim.advance();
        physical(
            sim.axes[0].step(),
            sim.axes[1].step(),
            self.latitude,
            self.lst(),
        )
    }

    fn axis(&self, i: usize) -> SimAxis {
        let mut sim = self.sim.lock().unwrap();
        sim.advance();
        sim.axes[i]
    }

    fn assert_no_refusals(&self) {
        let sim = self.sim.lock().unwrap();
        assert!(
            sim.refusals.is_empty(),
            "the controller refused {:?}",
            sim.refusals
        );
    }

    async fn goto(&mut self, ra: f64, dec: f64) {
        self.mount.slew_to_coordinates(ra, dec).await.expect("slew");
        let started = Instant::now();
        while self.mount.is_slewing().await.expect("is_slewing") {
            assert!(
                started.elapsed() < Duration::from_secs(30),
                "goto never ended"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

fn tracking_period() -> f64 {
    86_164.098_903_691 * f64::from(TIMER_HZ) / f64::from(CPR)
}

/// A freshly powered controller is initialized without moving: the version,
/// gear train, timer and status are read, the axes are initialized and the
/// Dec counter is set to the pole. The mount then reads as the pole.
#[tokio::test]
async fn independent_connect_initializes_without_moving() {
    for (lat, lon) in [(40.0, -75.0), (-33.9, 151.2)] {
        let rig = Rig::connect(lat, lon, Controller::new(false, POWER_ON, POWER_ON)).await;
        let commands = rig.sim.lock().unwrap().commands.clone();
        for c in &commands {
            let letter = c.chars().nth(1).unwrap();
            assert!("eabfjFE".contains(letter), "connect sent {c}: {commands:?}");
        }
        let ra = rig.axis(0);
        let dec = rig.axis(1);
        assert!(ra.initialized && dec.initialized && !ra.running && !dec.running);
        assert_eq!(dec.step(), POWER_ON + CPR / 4);
        assert_eq!(ra.step(), POWER_ON);
        let sky = rig.sky();
        assert!(
            (sky.dec_degrees.abs() - 90.0).abs() < 1e-6 && (sky.dec_degrees > 0.0) == (lat > 0.0)
        );
        let (_, dec_read) = rig.mount.get_coordinates().await.unwrap();
        assert!(
            (dec_read - sky.dec_degrees).abs() < 1.0 / 3600.0,
            "{dec_read} vs {sky:?}"
        );
        rig.assert_no_refusals();
        drop(rig.fake);
    }
}

/// Gotos on both sides of the meridian, near it, near the poles and at the
/// equator, in both hemispheres: the tube physically ends on the target,
/// with the counterweight down, on the pier side ASCOM names for that side of
/// the meridian, and then holds the target while tracking.
#[tokio::test]
async fn independent_gotos_land_track_and_report_the_physical_pier_side() {
    let cases = [
        (40.0, -75.0, [30.0, 85.0, -10.0, 0.0]),
        (-33.9, 151.2, [-30.0, -85.0, 10.0, 0.0]),
    ];
    for (lat, lon, decs) in cases {
        let mut rig = Rig::connect(lat, lon, Controller::new(false, POWER_ON, POWER_ON)).await;
        rig.mount.set_tracking(true).await.unwrap();
        for dec in decs {
            for hours_east in [-4.0, -0.3, 0.3, 4.0] {
                let target_ra = (rig.lst() + hours_east).rem_euclid(24.0);
                rig.goto(target_ra, dec).await;
                let sky = rig.sky();
                let off = separation_arcsec(sky.ra_hours, sky.dec_degrees, target_ra, dec);
                let label = format!("lat {lat} dec {dec} {hours_east:+} h east of the meridian");
                assert!(off < 15.0, "{label}: landed {off:.1}\" away at {sky:?}");
                assert!(
                    sky.counterweight_below_horizontal,
                    "{label}: counterweight up {sky:?}"
                );
                // West of the meridian (hours_east < 0) is reached from the east side.
                assert_eq!(sky.tube_east_of_pier, hours_east < 0.0, "{label}: {sky:?}");
                let reported = rig.mount.get_side_of_pier().await.unwrap();
                let physical_side = if sky.tube_east_of_pier {
                    PierSide::East
                } else {
                    PierSide::West
                };
                assert_eq!(reported, physical_side, "{label}");
                let (ra_read, dec_read) = rig.mount.get_coordinates().await.unwrap();
                let read_off = separation_arcsec(ra_read, dec_read, sky.ra_hours, sky.dec_degrees);
                assert!(
                    read_off < 2.0,
                    "{label}: reads {ra_read} {dec_read}, is at {sky:?}"
                );

                let ra_axis = rig.axis(0);
                assert!(
                    ra_axis.running && !ra_axis.goto && !ra_axis.fast,
                    "{label}: {ra_axis:?}"
                );
                assert_eq!(ra_axis.backward, lat < 0.0, "{label}: tracking direction");
                let want = tracking_period();
                assert!(
                    (f64::from(ra_axis.period) - want).abs() <= 1.0,
                    "{label}: period {} vs {want}",
                    ra_axis.period
                );
                assert!(!rig.axis(1).running, "{label}: Dec left running");

                let before = rig.sky();
                tokio::time::sleep(Duration::from_millis(600)).await;
                let after = rig.sky();
                let drift = separation_arcsec(
                    before.ra_hours,
                    before.dec_degrees,
                    after.ra_hours,
                    after.dec_degrees,
                );
                assert!(
                    drift < 1.0,
                    "{label}: drifted {drift:.2}\" in 0.6 s while tracking"
                );
            }
        }
        rig.assert_no_refusals();
    }
}

/// A guide pulse moves the tube in the sky direction it names, at about half
/// the sidereal rate, on either side of the pier in either hemisphere, and
/// leaves RA tracking and Dec stopped.
#[tokio::test]
async fn independent_guide_pulses_move_the_named_sky_direction() {
    for (lat, lon, dec) in [(40.0, -75.0, 20.0), (-33.9, 151.2, -20.0)] {
        let mut rig = Rig::connect(lat, lon, Controller::new(false, POWER_ON, POWER_ON)).await;
        rig.mount.set_tracking(true).await.unwrap();
        for hours_east in [-2.0, 2.0] {
            let target_ra = (rig.lst() + hours_east).rem_euclid(24.0);
            rig.goto(target_ra, dec).await;
            for direction in [
                GuideDirection::North,
                GuideDirection::South,
                GuideDirection::East,
                GuideDirection::West,
            ] {
                let before = rig.sky();
                rig.mount.pulse_guide(direction, 1000).await.unwrap();
                let after = rig.sky();
                let d_dec = (after.dec_degrees - before.dec_degrees) * 3600.0;
                let mut d_ra = (after.ra_hours - before.ra_hours).rem_euclid(24.0);
                if d_ra > 12.0 {
                    d_ra -= 24.0;
                }
                let d_east = d_ra * 15.0 * 3600.0 * before.dec_degrees.to_radians().cos();
                let (along, across) = match direction {
                    GuideDirection::North => (d_dec, d_east),
                    GuideDirection::South => (-d_dec, d_east),
                    GuideDirection::East => (d_east, d_dec),
                    GuideDirection::West => (-d_east, d_dec),
                };
                let label = format!(
                    "lat {lat} {direction:?} pulse, tube {} of the pier",
                    if before.tube_east_of_pier {
                        "east"
                    } else {
                        "west"
                    }
                );
                let expected = 0.5 * SIDEREAL_ARCSEC_PER_SECOND;
                assert!(
                    along > 0.5 * expected && along < 1.5 * expected,
                    "{label}: moved {along:.2}\" along (want about {expected:.1}\"), {across:.2}\" across"
                );
                assert!(across.abs() < 1.0, "{label}: {across:.2}\" across");
                let ra = rig.axis(0);
                assert!(ra.running && !ra.goto, "{label}: RA after the pulse {ra:?}");
                assert!(
                    (f64::from(ra.period) - tracking_period()).abs() <= 1.0,
                    "{label}: RA period {} after the pulse",
                    ra.period
                );
                assert_eq!(
                    ra.speed() < 0.0,
                    lat < 0.0,
                    "{label}: RA direction after the pulse"
                );
                tokio::time::sleep(Duration::from_millis(300)).await;
                assert!(!rig.axis(1).running, "{label}: Dec still moving");
            }
        }
        rig.assert_no_refusals();
    }
}

/// Park goes to the power-on position (counterweight down, tube at the pole)
/// and stops there; nothing moves until unpark.
#[tokio::test]
async fn independent_park_returns_to_the_power_on_position() {
    for (lat, lon) in [(40.0, -75.0), (-33.9, 151.2)] {
        let mut rig = Rig::connect(lat, lon, Controller::new(false, POWER_ON, POWER_ON)).await;
        rig.mount.set_tracking(true).await.unwrap();
        let ra = (rig.lst() - 3.0).rem_euclid(24.0);
        rig.goto(ra, lat.signum() * 50.0).await;
        rig.mount.park().await.unwrap();
        assert!(rig.mount.is_parked().await.unwrap());
        let (ra_axis, dec_axis) = (rig.axis(0), rig.axis(1));
        assert_eq!(ra_axis.step(), POWER_ON, "{ra_axis:?}");
        assert_eq!(dec_axis.step(), POWER_ON + CPR / 4, "{dec_axis:?}");
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!rig.axis(0).running && !rig.axis(1).running);
        assert!(rig.mount.slew_to_coordinates(ra, 10.0).await.is_err());
        assert!(rig.mount.at_home().await.unwrap());
        rig.assert_no_refusals();
    }
}

/// A controller another program already initialized is read in its frame:
/// nothing is reinitialized and no counter is rewritten.
#[tokio::test]
async fn independent_an_initialized_controller_is_left_alone() {
    let rig = Rig::connect(
        40.0,
        -75.0,
        Controller::new(true, POWER_ON + 1000, POWER_ON + CPR / 4 - 2000),
    )
    .await;
    let commands = rig.sim.lock().unwrap().commands.clone();
    assert!(
        commands
            .iter()
            .all(|c| !c.starts_with(":F") && !c.starts_with(":E")),
        "{commands:?}"
    );
    assert_eq!(rig.axis(0).step(), POWER_ON + 1000);
}

/// Discovery writes only the read-only version query to a port.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn independent_discovery_sends_only_the_version_query() {
    let sim = Arc::new(Mutex::new(Controller::new(false, POWER_ON, POWER_ON)));
    let responder_sim = sim.clone();
    let fake = FakeMount::spawn(
        b'\r',
        Box::new(move |wire, baud| {
            if baud == 9600 {
                responder_sim.lock().unwrap().answer(wire)
            } else {
                responder_sim
                    .lock()
                    .unwrap()
                    .commands
                    .push(String::from_utf8_lossy(wire).trim_end().to_string());
                Vec::new()
            }
        }),
    );
    let path = fake.path.clone();
    let found = tokio::task::spawn_blocking(move || {
        crate::vendor::skywatcher::scan_port_list(vec![serialport::SerialPortInfo {
            port_name: path,
            port_type: serialport::SerialPortType::Unknown,
        }])
    })
    .await
    .unwrap();
    assert_eq!(found.len(), 1);
    let commands = sim.lock().unwrap().commands.clone();
    assert!(commands.iter().all(|c| c == ":e1"), "{commands:?}");
    let ra = sim.lock().unwrap().axes[0];
    assert!(!ra.initialized && !ra.running);
}
