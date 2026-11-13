//! The scripted sessions and port scans, one golden transcript each.

use super::fakes::{self, IoptronDialect, Knobs, Lx200Flavor};
use super::skywatcher_sessions::{philadelphia, session_clock};
use super::{assert_waited, check_transcript, isolate_park_state, FakeMount};
use crate::vendor::ioptron::{self, IOptronMount};
use crate::vendor::lx200::{self, Lx200Mount, Lx200MountType};
use crate::vendor::skywatcher::{self, SkyWatcherMount};
use skotiq_device::*;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

const MISSING_PORT: &str = "/dev/skotiq-no-such-port";

/// The whole `MountDriver` surface, in an order a night would use it.
async fn full_session(fake: &FakeMount, knobs: &Knobs, mount: &mut dyn MountDriver) {
    let _ = step!(fake, "connect", mount.connect().await);
    fake.mark(&fake.scrub(&format!(
        "  id={} name={} vendor={:?} connected={}",
        mount.id(),
        mount.name(),
        mount.vendor(),
        mount.is_connected()
    )));
    fake.mark(&format!(
        "  can_slew={} can_sync={} can_pulse_guide={} can_set_tracking_rate={} can_find_home={} can_set_park={}",
        mount.can_slew().await,
        mount.can_sync().await,
        mount.can_pulse_guide().await,
        mount.can_set_tracking_rate().await,
        mount.can_find_home().await.unwrap_or(false),
        mount.can_set_park().await.unwrap_or(false)
    ));

    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(
        fake,
        "slew_to_coordinates(5.5, 20.0)",
        mount.slew_to_coordinates(5.5, 20.0).await
    );
    for _ in 0..3 {
        let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    }

    knobs.refuse_goto.store(true, Ordering::SeqCst);
    let _ = step!(
        fake,
        "slew_to_coordinates(1.25, -85.5) [mount refuses]",
        mount.slew_to_coordinates(1.25, -85.5).await
    );
    knobs.refuse_goto.store(false, Ordering::SeqCst);
    let _ = step!(fake, "is_slewing", mount.is_slewing().await);

    let _ = step!(
        fake,
        "sync_to_coordinates(5.5123, -20.2512)",
        mount.sync_to_coordinates(5.5123, -20.2512).await
    );

    let _ = step!(fake, "set_tracking(false)", mount.set_tracking(false).await);
    let _ = step!(fake, "get_tracking", mount.get_tracking().await);
    let _ = step!(fake, "set_tracking(true)", mount.set_tracking(true).await);
    let _ = step!(fake, "get_tracking", mount.get_tracking().await);

    for rate in [
        TrackingRate::Sidereal,
        TrackingRate::Lunar,
        TrackingRate::Solar,
        TrackingRate::King,
        TrackingRate::Custom,
    ] {
        let _ = step!(
            fake,
            format!("set_tracking_rate({rate:?})"),
            mount.set_tracking_rate(rate).await
        );
        let _ = step!(fake, "get_tracking_rate", mount.get_tracking_rate().await);
    }
    let _ = step!(
        fake,
        "set_tracking_rate(Sidereal)",
        mount.set_tracking_rate(TrackingRate::Sidereal).await
    );

    for direction in [
        GuideDirection::North,
        GuideDirection::South,
        GuideDirection::East,
        GuideDirection::West,
    ] {
        let _ = step!(
            fake,
            format!("pulse_guide({direction:?}, 40)"),
            mount.pulse_guide(direction, 40).await
        );
    }
    let _ = step!(
        fake,
        "pulse_guide(North, 5)",
        mount.pulse_guide(GuideDirection::North, 5).await
    );
    let _ = step!(fake, "abort_slew", mount.abort_slew().await);

    let _ = step!(fake, "get_side_of_pier", mount.get_side_of_pier().await);
    let _ = step!(fake, "get_alt_az", mount.get_alt_az().await);
    let _ = step!(fake, "get_sidereal_time", mount.get_sidereal_time().await);

    let _ = step!(fake, "get_site", mount.get_site().await);
    let _ = step!(
        fake,
        "set_site(40.007714, -75.397448)",
        mount
            .set_site(MountSiteInfo {
                latitude_deg: 40.007714,
                longitude_deg: -75.397448,
                elevation_m: None,
            })
            .await
    );
    let _ = step!(fake, "get_clock", mount.get_clock().await);
    let _ = step!(
        fake,
        "set_clock(1788921000, -4.0)",
        mount
            .set_clock(MountClock {
                utc_unix_seconds: 1_788_921_000,
                utc_offset_hours: -4.0,
            })
            .await
    );

    let _ = step!(fake, "find_home", mount.find_home().await);
    for _ in 0..2 {
        let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    }
    let _ = step!(fake, "at_home", mount.at_home().await);
    let _ = step!(fake, "set_park", mount.set_park().await);

    let _ = step!(fake, "park", mount.park().await);
    let _ = step!(fake, "is_parked", mount.is_parked().await);
    let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(fake, "unpark", mount.unpark().await);
    let _ = step!(fake, "is_parked", mount.is_parked().await);
    let _ = step!(fake, "get_tracking", mount.get_tracking().await);

    let _ = step!(fake, "disconnect", mount.disconnect().await);
    fake.mark(&format!("  connected={}", mount.is_connected()));
    let _ = step!(
        fake,
        "get_coordinates [disconnected]",
        mount.get_coordinates().await
    );
}

#[tokio::test]
async fn skywatcher_session() {
    let _park_state = isolate_park_state().await;
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(b'\r', fakes::synscan(None, knobs.clone()));
    let mut mount = SkyWatcherMount::new_serial(fake.path.clone(), None, philadelphia())
        .with_clock(session_clock);
    full_session(&fake, &knobs, &mut mount).await;
    check_transcript("skywatcher_session", &fake.lines());
}

async fn ioptron_session(name: &str, dialect: IoptronDialect, model_code: &'static str) {
    let _park_state = isolate_park_state().await;
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(
        b'#',
        fakes::ioptron(dialect, model_code, None, knobs.clone()),
    );
    let mut mount = IOptronMount::new(fake.path.clone(), None);
    full_session(&fake, &knobs, &mut mount).await;
    check_transcript(name, &fake.lines());
}

/// A CEM40 on firmware 210101 or later.
#[tokio::test]
async fn ioptron_v3_session() {
    ioptron_session("ioptron_v3_session", IoptronDialect::V3, "0040").await;
}

#[tokio::test]
async fn ioptron_v25_session() {
    ioptron_session("ioptron_v25_session", IoptronDialect::V25, "0060").await;
}

/// An alt-azimuth mount takes no pulse guiding and has no side of pier.
#[tokio::test]
async fn ioptron_alt_azimuth_mount() {
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(
        b'#',
        fakes::ioptron(IoptronDialect::V25, "5035", None, knobs),
    );
    let mut mount = IOptronMount::new(fake.path.clone(), None);
    let _ = step!(fake, "connect", mount.connect().await);
    fake.mark(&fake.scrub(&format!(
        "  name={} can_pulse_guide={}",
        mount.name(),
        mount.can_pulse_guide().await
    )));
    let _ = step!(
        fake,
        "pulse_guide(North, 40)",
        mount.pulse_guide(GuideDirection::North, 40).await
    );
    let _ = step!(fake, "get_side_of_pier", mount.get_side_of_pier().await);
    let _ = step!(fake, "disconnect", mount.disconnect().await);
    check_transcript("ioptron_alt_azimuth", &fake.lines());
}

async fn lx200_session(
    name: &str,
    flavor: Lx200Flavor,
    mount_type: Lx200MountType,
    baud_rate: Option<u32>,
) {
    let _park_state = isolate_park_state().await;
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(b'#', fakes::lx200(flavor, None, knobs.clone()));
    let mut mount = Lx200Mount::new(fake.path.clone(), mount_type, baud_rate);
    full_session(&fake, &knobs, &mut mount).await;
    check_transcript(name, &fake.lines());
}

#[tokio::test]
async fn lx200_meade_session() {
    lx200_session(
        "lx200_meade_session",
        Lx200Flavor::Meade,
        Lx200MountType::Meade,
        None,
    )
    .await;
}

#[tokio::test]
async fn lx200_onstep_session() {
    lx200_session(
        "lx200_onstep_session",
        Lx200Flavor::OnStep,
        Lx200MountType::OnStep,
        Some(115200),
    )
    .await;
}

#[tokio::test]
async fn lx200_onstep_nyx_session() {
    lx200_session(
        "lx200_onstep_nyx_session",
        Lx200Flavor::Nyx,
        Lx200MountType::OnStep,
        Some(115200),
    )
    .await;
}

#[tokio::test]
async fn lx200_losmandy_session() {
    lx200_session(
        "lx200_losmandy_session",
        Lx200Flavor::Losmandy,
        Lx200MountType::Losmandy,
        None,
    )
    .await;
}

#[tokio::test]
async fn lx200_tenmicron_session() {
    lx200_session(
        "lx200_tenmicron_session",
        Lx200Flavor::TenMicron,
        Lx200MountType::TenMicron,
        None,
    )
    .await;
}

#[tokio::test]
async fn lx200_generic_session() {
    lx200_session(
        "lx200_generic_session",
        Lx200Flavor::Generic,
        Lx200MountType::Generic,
        Some(19200),
    )
    .await;
}

/// Targets the firmware reads by position, in whatever precision the mount
/// was found in: a declination under ten degrees and a negative one under
/// one degree.
async fn targets_session(fake: &FakeMount, mount: &mut dyn MountDriver) {
    let _ = step!(fake, "connect", mount.connect().await);
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(fake, "get_alt_az", mount.get_alt_az().await);
    let _ = step!(
        fake,
        "slew_to_coordinates(5.5, 5.0)",
        mount.slew_to_coordinates(5.5, 5.0).await
    );
    let _ = step!(
        fake,
        "sync_to_coordinates(5.5123, -0.5)",
        mount.sync_to_coordinates(5.5123, -0.5).await
    );
    let _ = step!(
        fake,
        "slew_to_coordinates(5.5123, -20.2512)",
        mount.slew_to_coordinates(5.5123, -20.2512).await
    );
    let _ = step!(fake, "disconnect", mount.disconnect().await);
}

async fn lx200_targets(name: &str, flavor: Lx200Flavor, mount_type: Lx200MountType) {
    let _park_state = isolate_park_state().await;
    let fake = FakeMount::spawn(b'#', fakes::lx200(flavor, None, Arc::default()));
    let mut mount = Lx200Mount::new(fake.path.clone(), mount_type, None);
    targets_session(&fake, &mut mount).await;
    check_transcript(name, &fake.lines());
}

#[tokio::test]
async fn lx200_meade_targets() {
    lx200_targets(
        "lx200_meade_targets",
        Lx200Flavor::Meade,
        Lx200MountType::Meade,
    )
    .await;
}

#[tokio::test]
async fn lx200_onstep_targets() {
    lx200_targets(
        "lx200_onstep_targets",
        Lx200Flavor::OnStep,
        Lx200MountType::OnStep,
    )
    .await;
}

/// The mount starts in low precision and is switched to high precision.
#[tokio::test]
async fn lx200_meade_low_precision_targets() {
    lx200_targets(
        "lx200_meade_low_precision_targets",
        Lx200Flavor::MeadeLowPrecision,
        Lx200MountType::Meade,
    )
    .await;
}

/// The mount stays in low precision, so targets go out in low precision.
#[tokio::test]
async fn lx200_meade_low_precision_only_targets() {
    lx200_targets(
        "lx200_meade_low_precision_only_targets",
        Lx200Flavor::MeadeLowPrecisionOnly,
        Lx200MountType::Meade,
    )
    .await;
}

// Connections that do not go the easy way

#[tokio::test]
async fn skywatcher_connect_to_a_silent_port() {
    let fake = FakeMount::spawn(b'\r', fakes::silent());
    let mut mount = SkyWatcherMount::new_serial(fake.path.clone(), Some(115200), philadelphia());
    let _ = step!(fake, "connect", mount.connect().await);
    // Three tries of one second each, read in half-second slices.
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(3),
        "Sky-Watcher connect",
    );
    fake.mark(&format!("  connected={}", mount.is_connected()));
    check_transcript("skywatcher_connect_silent", &fake.lines());
}

#[tokio::test]
async fn ioptron_connect_to_a_silent_port() {
    let fake = FakeMount::spawn(b'#', fakes::silent());
    let mut mount = IOptronMount::new(fake.path.clone(), None);
    let _ = step!(fake, "connect", mount.connect().await);
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(10),
        "iOptron connect",
    );
    fake.mark(&format!("  connected={}", mount.is_connected()));
    check_transcript("ioptron_connect_silent", &fake.lines());
}

#[tokio::test]
async fn ioptron_connect_falls_back_to_the_fast_baud_rate() {
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(
        b'#',
        fakes::ioptron(IoptronDialect::V3, "0040", Some(115200), knobs),
    );
    let mut mount = IOptronMount::new(fake.path.clone(), None);
    let _ = step!(fake, "connect", mount.connect().await);
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(5),
        "iOptron fallback connect",
    );
    fake.mark(&fake.scrub(&format!(
        "  name={} connected={}",
        mount.name(),
        mount.is_connected()
    )));
    let _ = step!(fake, "is_slewing", mount.is_slewing().await);
    let _ = step!(fake, "disconnect", mount.disconnect().await);
    check_transcript("ioptron_connect_fast_baud_fallback", &fake.lines());
}

/// Firmware from before 2016 answers the model code but not `:GLS#`.
#[tokio::test]
async fn ioptron_connect_refuses_firmware_without_the_status_query() {
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(
        b'#',
        fakes::ioptron(IoptronDialect::Pre2016, "0045", None, knobs),
    );
    let mut mount = IOptronMount::new(fake.path.clone(), None);
    let _ = step!(fake, "connect", mount.connect().await);
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(5),
        "iOptron connect to old firmware",
    );
    fake.mark(&format!("  connected={}", mount.is_connected()));
    check_transcript("ioptron_connect_pre2016_firmware", &fake.lines());
}

#[tokio::test]
async fn lx200_connect_to_a_silent_port() {
    let _park_state = isolate_park_state().await;
    let fake = FakeMount::spawn(b'#', fakes::silent());
    let mut mount = Lx200Mount::new(fake.path.clone(), Lx200MountType::OnStep, Some(115200));
    let _ = step!(fake, "connect", mount.connect().await);
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(10),
        "LX200 connect",
    );
    fake.mark(&format!("  connected={}", mount.is_connected()));
    check_transcript("lx200_connect_silent", &fake.lines());
}

#[tokio::test]
async fn lx200_connect_to_a_mount_without_a_product_name() {
    let _park_state = isolate_park_state().await;
    let knobs = Arc::new(Knobs::default());
    let fake = FakeMount::spawn(
        b'#',
        fakes::lx200(Lx200Flavor::CoordinatesOnly, None, knobs),
    );
    let mut mount = Lx200Mount::new(fake.path.clone(), Lx200MountType::Generic, None);
    let _ = step!(fake, "connect", mount.connect().await);
    assert_waited(
        fake.time_on_the_wire(),
        Duration::from_secs(5),
        "LX200 fallback connect",
    );
    fake.mark(&fake.scrub(&format!(
        "  name={} connected={}",
        mount.name(),
        mount.is_connected()
    )));
    let _ = step!(fake, "get_coordinates", mount.get_coordinates().await);
    let _ = step!(fake, "disconnect", mount.disconnect().await);
    check_transcript("lx200_connect_without_product_name", &fake.lines());
}

#[tokio::test]
async fn connect_to_a_port_that_does_not_exist() {
    let _park_state = isolate_park_state().await;
    let mut lines = Vec::new();

    let mut mount = SkyWatcherMount::new_serial(MISSING_PORT.to_string(), None, philadelphia());
    lines.push(format!("skywatcher id={}", mount.id()));
    lines.push(format!("  -> {:?}", mount.connect().await));

    let mut mount = IOptronMount::new(MISSING_PORT.to_string(), None);
    lines.push(format!("ioptron id={}", mount.id()));
    lines.push(format!("  -> {:?}", mount.connect().await));

    let mut mount = Lx200Mount::new(MISSING_PORT.to_string(), Lx200MountType::OnStep, None);
    lines.push(format!("lx200 id={}", mount.id()));
    lines.push(format!("  -> {:?}", mount.connect().await));

    let mount = SkyWatcherMount::new_serial("COM4\\sub".to_string(), None, philadelphia());
    lines.push(format!("skywatcher windows-style id={}", mount.id()));

    check_transcript("connect_missing_port", &lines);
}

fn port(path: &str) -> serialport::SerialPortInfo {
    serialport::SerialPortInfo {
        port_name: path.to_string(),
        port_type: serialport::SerialPortType::Unknown,
    }
}

/// The scan order: a port that cannot be opened first, then the fakes.
fn scan_list(fakes: &[(&str, &FakeMount)]) -> Vec<serialport::SerialPortInfo> {
    let mut ports = vec![port(MISSING_PORT)];
    ports.extend(fakes.iter().map(|(_, fake)| port(&fake.path)));
    ports
}

/// One section per scanned port with what crossed it, then what the scan
/// reported, with each pty path replaced by the port's label.
fn scan_transcript(fakes: &[(&str, &FakeMount)], found: Vec<String>) -> Vec<String> {
    let mut lines = Vec::new();
    for (label, fake) in fakes {
        fake.mark("(scan over)");
        lines.push(format!("== port {label} =="));
        lines.extend(fake.lines());
    }

    // Longest path first: `/dev/pts/1` is a prefix of `/dev/pts/12`.
    let mut by_length: Vec<&(&str, &FakeMount)> = fakes.iter().collect();
    by_length.sort_by_key(|(_, fake)| std::cmp::Reverse(fake.path.len()));

    lines.push("== found ==".to_string());
    for mut entry in found {
        for (label, fake) in &by_length {
            entry = entry.replace(&fake.path, &format!("<{label}>"));
        }
        lines.push(entry);
    }
    lines
}

#[test]
fn skywatcher_scan() {
    let silent = FakeMount::spawn(b'\r', fakes::silent());
    let slow = FakeMount::spawn(b'\r', fakes::synscan(Some(9600), Arc::default()));
    let fakes = [("silent", &silent), ("answers-at-9600", &slow)];

    let started = Instant::now();
    let found = skywatcher::scan_port_list(scan_list(&fakes));
    // Silent port: two baud rates, each a 100 ms settle, a 500 ms read
    // timeout and a 50 ms release. Live port: one such miss, then one
    // 100 ms settle and a release.
    assert_waited(
        started.elapsed(),
        Duration::from_millis(2100),
        "Sky-Watcher scan",
    );

    let found = found
        .into_iter()
        .map(|info| {
            format!(
                "port={} name={} firmware={:?} baud={}",
                info.port, info.name, info.firmware_version, info.baud_rate
            )
        })
        .collect();
    check_transcript("skywatcher_scan", &scan_transcript(&fakes, found));
}

#[test]
fn ioptron_scan() {
    let silent = FakeMount::spawn(b'#', fakes::silent());
    let v3 = FakeMount::spawn(
        b'#',
        fakes::ioptron(IoptronDialect::V3, "0120", Some(115200), Arc::default()),
    );
    let v25 = FakeMount::spawn(
        b'#',
        fakes::ioptron(IoptronDialect::V25, "0045", Some(9600), Arc::default()),
    );
    let fakes = [
        ("silent", &silent),
        ("v3-at-115200", &v3),
        ("v25-at-9600", &v25),
    ];

    let started = Instant::now();
    let found = ioptron::scan_port_list(scan_list(&fakes));
    // Silent port: two baud rates, each a 100 ms settle, a 500 ms read
    // timeout and a 50 ms release. The v3 mount: one such miss, then four
    // 100 ms settles and a release. The v2.5 mount: four settles and a
    // release.
    assert_waited(
        started.elapsed(),
        Duration::from_millis(2850),
        "iOptron scan",
    );

    let found = found
        .into_iter()
        .map(|info| {
            format!(
                "port={} name={} model={} firmware={:?} baud={}",
                info.port, info.name, info.model, info.firmware_version, info.baud_rate
            )
        })
        .collect();
    check_transcript("ioptron_scan", &scan_transcript(&fakes, found));
}

fn lx200_found(found: Vec<lx200::Lx200MountInfo>) -> Vec<String> {
    found
        .into_iter()
        .map(|info| {
            format!(
                "port={} name={:?} type={:?} firmware={:?} baud={}",
                info.port, info.name, info.mount_type, info.firmware_version, info.baud_rate
            )
        })
        .collect()
}

#[test]
fn lx200_scan_tells_the_flavors_apart() {
    let spawn = |flavor| FakeMount::spawn(b'#', fakes::lx200(flavor, None, Arc::default()));
    let onstep = spawn(Lx200Flavor::OnStep);
    let nyx = spawn(Lx200Flavor::Nyx);
    let meade = spawn(Lx200Flavor::Meade);
    let losmandy = spawn(Lx200Flavor::Losmandy);
    let tenmicron = spawn(Lx200Flavor::TenMicron);
    let generic = spawn(Lx200Flavor::Generic);
    let coordinates_only = spawn(Lx200Flavor::CoordinatesOnly);
    let fakes = [
        ("onstep", &onstep),
        ("nyx", &nyx),
        ("meade", &meade),
        ("losmandy", &losmandy),
        ("tenmicron", &tenmicron),
        ("generic", &generic),
        ("coordinates-only", &coordinates_only),
    ];

    let started = Instant::now();
    let found = lx200::scan_port_list(scan_list(&fakes));
    // OnStep and NYX: five 200 ms settles each. The four named classic
    // mounts: a 200 ms settle and a 500 ms timeout on `:GU#`, then four
    // settles. Coordinates only: two such misses, a settle and a release.
    assert_waited(
        started.elapsed(),
        Duration::from_millis(9650),
        "LX200 flavor scan",
    );

    check_transcript(
        "lx200_scan_flavors",
        &scan_transcript(&fakes, lx200_found(found)),
    );
}

#[test]
fn lx200_scan_walks_the_baud_rates_down_to_9600() {
    let meade = FakeMount::spawn(
        b'#',
        fakes::lx200(Lx200Flavor::Meade, Some(9600), Arc::default()),
    );
    let fakes = [("meade-at-9600", &meade)];

    let started = Instant::now();
    let found = lx200::scan_port_list(scan_list(&fakes));
    // Three baud rates of three missed probes (200 ms settle + 500 ms
    // timeout) and a 50 ms release, then one miss and four settles at 9600.
    assert_waited(
        started.elapsed(),
        Duration::from_millis(7950),
        "LX200 baud scan",
    );

    check_transcript(
        "lx200_scan_bauds",
        &scan_transcript(&fakes, lx200_found(found)),
    );
}

#[test]
fn lx200_scan_of_a_silent_port() {
    let silent = FakeMount::spawn(b'#', fakes::silent());
    let fakes = [("silent", &silent)];

    let started = Instant::now();
    let found = lx200::scan_port_list(scan_list(&fakes));
    // Four baud rates of three missed probes and a release.
    assert_waited(
        started.elapsed(),
        Duration::from_millis(8600),
        "LX200 silent scan",
    );

    check_transcript(
        "lx200_scan_silent",
        &scan_transcript(&fakes, lx200_found(found)),
    );
}
