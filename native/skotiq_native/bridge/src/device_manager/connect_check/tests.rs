//! P8-9b: the read-only connect check, against fakes that lie.

use super::verdicts::{self, TrackingVerdict};
use super::*;
use crate::device::{CameraState, CameraStatus, MountSite, MountStatus, MountTimeInfo, PierSide};
use crate::event::bus::EventPayload;
use crate::event::equipment::EquipmentEvent;
use crate::event::system::SystemEvent;
use std::time::Duration;

fn mount_status(ra_hours: f64, tracking: bool, parked: bool) -> MountStatus {
    MountStatus {
        connected: true,
        tracking,
        slewing: false,
        parked,
        at_home: Some(false),
        side_of_pier: None,
        right_ascension: ra_hours,
        declination: 20.0,
        altitude: None,
        azimuth: None,
        sidereal_time: None,
        tracking_rate: None,
        can_park: true,
        can_slew: true,
        can_sync: true,
        can_pulse_guide: true,
        can_set_tracking_rate: true,
        availability: Default::default(),
    }
}

const GAP: Duration = verdicts::RA_SAMPLE_GAP;

/// RA hours after `seconds` of sidereal drift.
fn drifted(ra: f64, seconds: f64) -> f64 {
    ra + seconds * 1.002_737_909 / 3600.0
}

#[test]
fn a_mount_that_says_it_tracks_while_its_ra_drifts_is_caught() {
    let first = mount_status(5.0, true, false);
    let second = mount_status(drifted(5.0, 4.0), true, false);
    assert!(matches!(
        verdicts::tracking(&first, &second, GAP, false),
        TrackingVerdict::Disagrees(said) if said.contains("reports tracking")
    ));
    let steady = mount_status(5.0, true, false);
    assert_eq!(
        verdicts::tracking(&first, &steady, GAP, false),
        TrackingVerdict::Agrees
    );
}

#[test]
fn a_mount_that_says_it_does_not_track_while_its_ra_holds_is_looked_at_again_then_caught() {
    let first = mount_status(5.0, false, false);
    let held = mount_status(5.0, false, false);
    assert_eq!(
        verdicts::tracking(&first, &held, GAP, false),
        TrackingVerdict::LookAgain
    );
    assert!(matches!(
        verdicts::tracking(&first, &held, Duration::from_secs(10), true),
        TrackingVerdict::Disagrees(said) if said.contains("not tracking")
    ));
    // An LX200 at low precision: 6 s steps, one step in 10 s.
    let stepped = mount_status(5.0 + 6.0 / 3600.0, false, false);
    assert_eq!(
        verdicts::tracking(&first, &stepped, Duration::from_secs(10), true),
        TrackingVerdict::Agrees
    );
}

/// A fake that lies about park: parked and tracking at once. A parked mount's
/// RA is not judged (its park position is what it points at, and no driver
/// reports it).
#[test]
fn a_mount_that_lies_about_park_is_caught() {
    let first = mount_status(5.0, true, true);
    assert!(matches!(
        verdicts::tracking(&first, &first.clone(), GAP, false),
        TrackingVerdict::Disagrees(said) if said.contains("parked and tracking")
    ));
    let parked = mount_status(5.0, false, true);
    assert!(matches!(
        verdicts::tracking(&parked, &parked.clone(), Duration::from_secs(10), true),
        TrackingVerdict::Skip(_)
    ));
}

#[test]
fn reads_across_a_slew_or_a_change_of_state_are_not_judged() {
    let mut slewing = mount_status(5.0, true, false);
    slewing.slewing = true;
    let after = mount_status(7.0, true, false);
    assert!(matches!(
        verdicts::tracking(&slewing, &after, GAP, false),
        TrackingVerdict::Skip(_)
    ));
    let stopped = mount_status(5.0, false, false);
    assert!(matches!(
        verdicts::tracking(&after, &stopped, GAP, false),
        TrackingVerdict::Skip(_)
    ));
}

#[test]
fn the_pier_side_must_fit_the_hour_angle() {
    let mut status = mount_status(5.0, true, false);
    status.sidereal_time = Some(8.0); // hour angle +3 h: west of the meridian
    status.side_of_pier = Some(PierSide::East);
    assert_eq!(verdicts::pier_side(&status), None);
    status.side_of_pier = Some(PierSide::West);
    assert!(verdicts::pier_side(&status).is_some_and(|s| s.contains("+3.0 h")));
    // Near the meridian either side is plausible.
    status.sidereal_time = Some(6.0);
    assert_eq!(verdicts::pier_side(&status), None);
    // A parked mount or one with no sidereal time is not judged.
    status.sidereal_time = Some(8.0);
    status.parked = true;
    assert_eq!(verdicts::pier_side(&status), None);
}

#[test]
fn the_mount_clock_and_site_are_checked_against_the_computer_and_skotiq() {
    let time = |utc_unix_seconds| MountTimeInfo {
        utc_unix_seconds,
        utc_offset_hours: 0.0,
    };
    assert_eq!(verdicts::clock(&time(1_000_020), 1_000_000), None);
    assert!(verdicts::clock(&time(1_000_100), 1_000_000).is_some_and(|s| s.contains("+100 s")));

    let site = MountSite {
        latitude_deg: 40.0,
        longitude_deg: -75.0,
        elevation_m: None,
    };
    assert_eq!(verdicts::site(&site, 40.005, -75.005), None);
    assert!(verdicts::site(&site, 41.0, -75.0).is_some());
    // East-positive longitudes across the antimeridian.
    let pacific = MountSite {
        latitude_deg: -17.0,
        longitude_deg: 179.999,
        elevation_m: None,
    };
    assert_eq!(verdicts::site(&pacific, -17.0, -179.999), None);
}

#[test]
fn a_position_is_checked_against_the_last_one_recorded() {
    use Reading::*;
    assert_eq!(verdicts::position(Focuser(15005), Focuser(15000)), None);
    assert!(verdicts::position(Focuser(0), Focuser(15000))
        .is_some_and(|s| s.contains("position 0") && s.contains("position 15000")));
    assert!(verdicts::position(Filter(2), Filter(4)).is_some_and(|s| s.contains("slot 3")));
    assert_eq!(verdicts::position(Rotator(359.8), Rotator(0.1)), None);
    assert!(verdicts::position(Rotator(90.0), Rotator(180.0)).is_some());
}

fn camera_status(on: Option<bool>, power: f64, sensor: f64, target: f64) -> CameraStatus {
    CameraStatus {
        connected: true,
        state: CameraState::Idle,
        sensor_temp: Some(sensor),
        cooler_power: Some(power),
        target_temp: Some(target),
        cooler_on: on,
        gain: None,
        offset: None,
        bin_x: 1,
        bin_y: 1,
        sensor_width: 100,
        sensor_height: 100,
        pixel_size_x: 3.8,
        pixel_size_y: 3.8,
        max_adu: 65535,
        saturation_adu: None,
        can_cool: true,
        can_set_gain: true,
        can_set_offset: true,
    }
}

#[test]
fn a_cooler_report_that_does_not_hold_together_is_caught() {
    assert!(
        verdicts::cooler(&camera_status(Some(true), 0.0, 20.0, -10.0))
            .is_some_and(|s| s.contains("cooler on"))
    );
    assert_eq!(
        verdicts::cooler(&camera_status(Some(true), 60.0, 20.0, -10.0)),
        None
    );
    assert_eq!(
        verdicts::cooler(&camera_status(Some(true), 0.0, -9.8, -10.0)),
        None
    );
    assert!(
        verdicts::cooler(&camera_status(Some(false), 40.0, 5.0, -10.0))
            .is_some_and(|s| s.contains("cooler off"))
    );
    assert_eq!(
        verdicts::cooler(&camera_status(None, 40.0, 5.0, -10.0)),
        None
    );
}

fn notices(
    rx: &mut tokio::sync::broadcast::Receiver<crate::event::bus::SkotiqEvent>,
) -> Vec<String> {
    let mut said = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let EventPayload::System(SystemEvent::Notification { title, message, .. }) =
            &event.payload
        {
            said.push(format!("{title}: {message}"));
        }
    }
    said
}

fn unverified(
    rx: &mut tokio::sync::broadcast::Receiver<crate::event::bus::SkotiqEvent>,
) -> Vec<String> {
    let mut fields = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let EventPayload::Equipment(EquipmentEvent::PropertyChanged {
            property, value, ..
        }) = &event.payload
        {
            if property == property::UNVERIFIED {
                fields.push(value.clone());
            }
        }
    }
    fields
}

/// A focuser moved (or reset) while it was disconnected reads where it is
/// now: one warning names both positions, the field is marked unverified,
/// and nothing moves it.
#[tokio::test]
async fn a_focuser_that_moved_while_disconnected_is_reported_and_left_where_it_is() {
    use crate::simulator::focuser::get_sim_focuser;
    let _guard = crate::simulator::sim_singleton_test_lock().lock().await;
    let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
    let id = "sim_focuser_check";
    let info = crate::device::DeviceInfo {
        id: id.to_string(),
        name: "Simulated focuser".to_string(),
        device_type: crate::device::DeviceType::Focuser,
        driver_type: DriverType::Simulator,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "Simulated focuser".to_string(),
    };
    manager.register_device(info, false).await;
    manager.connect_device(id).await.expect("connect");
    manager.focuser_move_abs(id, 15000).await.expect("move");
    manager.disconnect_device(id).await.expect("disconnect");

    get_sim_focuser().write().await.status.position = 9000;
    let mut rx = manager.app_state.event_bus.subscribe();
    manager.connect_device(id).await.expect("reconnect");

    let said = notices(&mut rx);
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(
        said[0].contains("position 9000") && said[0].contains("position 15000"),
        "{said:?}"
    );
    assert_eq!(manager.focuser_get_position(id).await.ok(), Some(9000));
    manager.disconnect_device(id).await.expect("disconnect");

    // The next connect, with the focuser where it was: nothing to say.
    let mut rx = manager.app_state.event_bus.subscribe();
    manager.connect_device(id).await.expect("connect again");
    assert!(notices(&mut rx).is_empty());
    manager.disconnect_device(id).await.expect("disconnect");
}

/// A native mount that says it is tracking while its RA drifts with the sky.
#[derive(Debug)]
struct LyingMount {
    since: tokio::time::Instant,
}

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for LyingMount {
    fn id(&self) -> &str {
        "native:meade:liar"
    }
    fn name(&self) -> &str {
        "Meade LX200"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Meade
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_device::MountDriver for LyingMount {
    async fn slew_to_coordinates(
        &mut self,
        _ra: f64,
        _dec: f64,
    ) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never slews");
    }
    async fn get_coordinates(&self) -> Result<(f64, f64), skotiq_device::DriverError> {
        Ok((drifted(5.0, self.since.elapsed().as_secs_f64()), 20.0))
    }
    async fn sync_to_coordinates(
        &mut self,
        _ra: f64,
        _dec: f64,
    ) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never syncs");
    }
    async fn park(&mut self) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never parks");
    }
    async fn unpark(&mut self) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never unparks");
    }
    async fn is_slewing(&self) -> Result<bool, skotiq_device::DriverError> {
        Ok(false)
    }
    async fn is_parked(&self) -> Result<bool, skotiq_device::DriverError> {
        Ok(false)
    }
    async fn pulse_guide(
        &mut self,
        _direction: skotiq_device::GuideDirection,
        _duration_ms: u32,
    ) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never guides");
    }
    async fn abort_slew(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn set_tracking(&mut self, _enabled: bool) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never sets tracking");
    }
    async fn get_tracking(&self) -> Result<bool, skotiq_device::DriverError> {
        Ok(true)
    }
    async fn set_tracking_rate(
        &mut self,
        _rate: skotiq_device::TrackingRate,
    ) -> Result<(), skotiq_device::DriverError> {
        panic!("the connect check never sets a rate");
    }
    async fn get_tracking_rate(
        &self,
    ) -> Result<skotiq_device::TrackingRate, skotiq_device::DriverError> {
        Ok(skotiq_device::TrackingRate::Sidereal)
    }
    async fn can_slew(&self) -> bool {
        true
    }
    async fn can_sync(&self) -> bool {
        true
    }
    async fn can_pulse_guide(&self) -> bool {
        true
    }
    async fn get_side_of_pier(
        &self,
    ) -> Result<skotiq_device::PierSide, skotiq_device::DriverError> {
        Ok(skotiq_device::PierSide::Unknown)
    }
    async fn get_alt_az(&self) -> Result<(f64, f64), skotiq_device::DriverError> {
        Ok((45.0, 180.0))
    }
    async fn get_sidereal_time(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(3.0)
    }
}

#[tokio::test]
async fn a_mount_that_lies_about_tracking_is_reported_and_not_touched() {
    let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
    let id = "native:meade:liar";
    let info = crate::device::DeviceInfo {
        id: id.to_string(),
        name: "Meade LX200".to_string(),
        device_type: crate::device::DeviceType::Mount,
        driver_type: DriverType::Native,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "Meade LX200".to_string(),
    };
    manager.register_connected_device(info.clone()).await;
    manager.hold_vendor_mount(
        id,
        Box::new(LyingMount {
            since: tokio::time::Instant::now(),
        }),
    );
    let found = manager.check_mount(&info).await;
    assert!(found.iter().any(|d| d.field == "tracking"), "{found:?}");

    let mut rx = manager.app_state.event_bus.subscribe();
    manager.report_unverified(&info, &found);
    assert!(unverified(&mut rx)
        .iter()
        .any(|fields| fields.contains("tracking")));
}

#[test]
fn a_check_with_nothing_found_says_nothing() {
    let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
    let mut rx = manager.app_state.event_bus.subscribe();
    let info = crate::device::DeviceInfo {
        id: "x".into(),
        name: "x".into(),
        device_type: crate::device::DeviceType::Focuser,
        driver_type: DriverType::Simulator,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "x".into(),
    };
    manager.report_unverified(&info, &[]);
    assert!(rx.try_recv().is_err());
}

/// A wheel that cannot say its slot yet (-1) is neither checked nor
/// recorded.
#[test]
fn an_unknown_slot_is_not_recorded() {
    let positions = positions::Positions::default();
    positions.bind("wheel", "filter_wheel|wheel".to_string());
    positions.record("wheel", Reading::Filter(3));
    positions.record("wheel", Reading::Filter(-1));
    assert_eq!(positions.last("wheel"), Some(Reading::Filter(3)));
}

const WIRE_WORDS_FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../test_fixtures/wire_words/connect_check.json"
);

/// `test_fixtures/wire_words/connect_check.json`: the property the connect
/// check reports under and the field words its value lists, which the app
/// matches and shows. Regenerate with
/// `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_bridge connect_check_wire_words`.
#[test]
fn connect_check_wire_words_fixture() {
    let value = serde_json::json!({
        "property": property::UNVERIFIED,
        "fields": super::field::ALL,
    });
    if std::env::var_os("SKOTIQ_WRITE_FIXTURES").is_some() {
        let path = std::path::Path::new(WIRE_WORDS_FIXTURE);
        std::fs::create_dir_all(path.parent().expect("dir")).expect("fixture dir");
        let mut text = serde_json::to_string_pretty(&value).expect("pretty");
        text.push('\n');
        std::fs::write(path, text).expect("write fixture");
        return;
    }
    let committed: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(WIRE_WORDS_FIXTURE).expect("fixture"))
            .expect("JSON");
    assert_eq!(
        committed, value,
        "the connect check's words changed; regenerate the fixture and update the app"
    );
}
