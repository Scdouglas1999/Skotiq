//! The simulated mount speaks coordinates of date, like the rig does.
//!
//! These drive the real instruction code through the real device layer and the
//! simulator, so a J2000/of-date mix anywhere between a sequence node and the
//! mount shows up here the way it shows up under the sky. Before the simulator
//! was made an of-date mount, the slew-validation defect of 2026-09-14 (every
//! target slew "missed" by the precession offset) passed every one of them.

use super::*;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::epoch::{
    j2000_to_jnow, jnow_to_j2000, SimFrameGuard as FrameGuard, SimMountFrame,
};
use crate::simulator::mount::get_sim_mount;
use crate::simulator::sim_singleton_test_lock;
use skotiq_sequencer::instructions::InstructionContext;
use skotiq_sequencer::SlewConfig;
use std::sync::atomic::AtomicBool;

/// NGC 7380, the target of the night the defect was found, J2000.
const NGC7380_J2000: (f64, f64) = (22.7892, 58.1324);

async fn attach_sim_mount(device_id: &str) {
    let info = DeviceInfo {
        id: device_id.to_string(),
        name: "Simulated Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type: DriverType::Simulator,
        description: "Simulated mount".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Simulated Mount".to_string(),
    };
    crate::simulator::register_connected(get_device_manager(), info).await;
    crate::simulator::mount::cancel_sim_slew().await;
    let mut mount = get_sim_mount().write().await;
    mount.status.connected = true;
    mount.status.parked = false;
    mount.status.tracking = true;
    mount.status.slewing = false;
}

/// The context a TargetHeader hands a Slew node: J2000 target, mount only.
fn target_context(mount_id: &str, target: (f64, f64)) -> InstructionContext {
    let mut run = skotiq_sequencer::instructions::RunShared::new(create_unified_device_ops());
    run.rig.mount_id = Some(mount_id.to_string());
    InstructionContext {
        node_id: "frame-test-slew".to_string(),
        target_ra: Some(target.0),
        target_dec: Some(target.1),
        target_name: Some("NGC 7380".to_string()),
        ..InstructionContext::new(run, Arc::new(AtomicBool::new(false)))
    }
}

fn separation_arcmin(a: (f64, f64), b: (f64, f64)) -> f64 {
    let mut dra = (a.0 - b.0).rem_euclid(24.0);
    if dra > 12.0 {
        dra -= 24.0;
    }
    (dra * 15.0 * a.1.to_radians().cos()).hypot(a.1 - b.1) * 60.0
}

/// A Slew node aimed at a J2000 target lands, and validates, on an of-date
/// mount. This is the rig's 2026-09-14 failure run on the simulator: with the
/// validation fix in `execute_slew` reverted, this test fails with the same
/// "Slew position validation failed" miss of ~16' RA / ~8' Dec.
#[tokio::test]
async fn a_target_slew_validates_on_an_of_date_simulated_mount() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_slew";
    attach_sim_mount(mount_id).await;

    let ctx = target_context(mount_id, NGC7380_J2000);
    let result =
        skotiq_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        result.status == skotiq_sequencer::NodeStatus::Success,
        "a slew that landed on target was reported as a failure: {:?}",
        result.message
    );

    // The mount holds the target of date, ~22' from the J2000 numbers, exactly
    // as the owner's OnStep did (22.8070h/58.2738deg in September 2026).
    let status = get_sim_mount().read().await.status.clone();
    let stored = (status.right_ascension, status.declination);
    let expected = j2000_to_jnow(NGC7380_J2000.0, NGC7380_J2000.1);
    assert!(
        separation_arcmin(stored, expected) < 0.05,
        "the simulated mount stored {stored:?}, not the of-date target {expected:?}"
    );
    assert!(
        separation_arcmin(stored, NGC7380_J2000) > 10.0,
        "the simulated mount stored J2000 numbers {stored:?}; it is not behaving like a JNow mount"
    );
    // And the stars it is looking at are the J2000 target's.
    let seen = jnow_to_j2000(stored.0, stored.1);
    assert!(separation_arcmin(seen, NGC7380_J2000) < 0.05);
}

/// A sync with J2000 coordinates (what plate-solve centering sends) leaves the
/// simulator holding the of-date position, the same frame a slew uses — sync
/// and slew feeding the mount different frames would skew every centering pass.
#[tokio::test]
async fn a_sync_stores_the_same_frame_a_slew_does() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_sync";
    attach_sim_mount(mount_id).await;

    get_device_manager()
        .mount_sync(mount_id, NGC7380_J2000.0, NGC7380_J2000.1)
        .await
        .expect("sync");
    let (ra, dec) = get_device_manager()
        .mount_get_coordinates(mount_id)
        .await
        .expect("read back");
    let expected = j2000_to_jnow(NGC7380_J2000.0, NGC7380_J2000.1);
    assert!(
        separation_arcmin((ra, dec), expected) < 0.05,
        "sync stored ({ra}, {dec}), expected of-date {expected:?}"
    );
}

/// `SKOTIQ_SIM_MOUNT_FRAME=j2000` keeps the old behaviour: what is sent is
/// what reads back, and validation still agrees with the send path.
#[tokio::test]
async fn the_j2000_pin_round_trips_catalog_numbers() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::J2000);
    let mount_id = "sim_mount_frame_j2000";
    attach_sim_mount(mount_id).await;

    let ctx = target_context(mount_id, NGC7380_J2000);
    let result =
        skotiq_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        result.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        result.message
    );
    let status = get_sim_mount().read().await.status.clone();
    assert!(separation_arcmin((status.right_ascension, status.declination), NGC7380_J2000) < 0.05);
}

/// A light frame taken on target records the target's J2000 position in its
/// FITS `RA`/`DEC` cards, whatever frame the mount itself speaks. Stackers,
/// solvers and catalogue tools read those cards as J2000; before the read-back
/// was converted, every frame from a JNow mount carried coordinates ~20' off
/// in the header and in `captured_images` (found by the simulator soak).
#[tokio::test]
async fn a_light_frame_header_carries_j2000_pointing_from_an_of_date_mount() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_fits";
    attach_sim_mount(mount_id).await;
    let camera_id = "sim_camera_frame_fits";
    crate::simulator::register_connected(get_device_manager(), DeviceInfo {
                id: camera_id.to_string(),
                name: "Simulated Camera".to_string(),
                device_type: DeviceType::Camera,
                driver_type: DriverType::Simulator,
                description: "Simulated camera".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Simulated Camera".to_string(),
            }).await;
    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = true;
    crate::simulator::camera::clear_sim_exposure().await;

    let mut ctx = target_context(mount_id, NGC7380_J2000);
    let slewed =
        skotiq_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        slewed.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        slewed.message
    );

    let dir = tempfile::TempDir::new().unwrap();
    ctx.run.rig.camera_id = Some(camera_id.to_string());
    ctx.run.rig.save_path = Some(dir.path().to_path_buf());
    let config = skotiq_sequencer::ExposureConfig {
        duration_secs: 0.1,
        count: 1,
        dither_every: None,
        ..Default::default()
    };
    let exposed =
        skotiq_sequencer::instructions::execute_exposure(&config, &ctx, |_, _, _| {}).await;

    crate::simulator::camera::get_sim_camera()
        .write()
        .await
        .status
        .connected = false;
    assert!(
        exposed.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        exposed.message
    );

    let fits = walk_fits(dir.path());
    assert_eq!(fits.len(), 1, "expected one light frame, found {fits:?}");
    let header = skotiq_imaging::read_frame_header(&fits[0]).expect("header");
    let ra_hours = header.get_float("RA").expect("RA card") / 15.0;
    let dec = header.get_float("DEC").expect("DEC card");
    let off = separation_arcmin((ra_hours, dec), NGC7380_J2000);
    assert!(
        off < 0.1,
        "the header says RA={ra_hours:.4}h DEC={dec:.4}, {off:.1}' from the J2000 target: \
         the mount's of-date read-back was written as if it were J2000"
    );
}

/// A target slew leaves the mount tracking. A mount unparked without tracking
/// (the ASCOM simulator's behavior, and many drivers') used to be slewed and
/// then left standing still: on the rig every frame trails, and the meridian
/// flip trigger, which refuses to flip a mount that is not tracking, never
/// fires. The simulator soak reached transit that way and held the next
/// exposure for a flip that could not happen.
#[tokio::test]
async fn a_target_slew_leaves_the_mount_tracking() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_tracking";
    attach_sim_mount(mount_id).await;
    get_sim_mount().write().await.status.tracking = false;

    let ctx = target_context(mount_id, NGC7380_J2000);
    let result =
        skotiq_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        result.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        result.message
    );
    assert!(
        get_sim_mount().read().await.status.tracking,
        "the slew arrived on target and left the mount not tracking"
    );
}

/// A flip on a mount that does not report its pier side is verified by
/// checking the mount arrived back on the target. That check compared the
/// of-date read-back with the J2000 target against a 1' tolerance, so on any
/// JNow mount without pier-side telemetry every correct flip was reported as a
/// failure (the 2026-09-14 slew-validator defect, in the flip executor).
#[tokio::test]
async fn a_flip_without_pier_side_telemetry_verifies_on_an_of_date_mount() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    // No site: the simulated mount then has no hour angle to pick a pier side
    // from and keeps reporting Unknown, like a driver without SideOfPier.
    let previous_site = crate::state::get_state()
        .get_observer_location()
        .ok()
        .flatten();
    crate::state::get_state().set_observer_location(None).unwrap();
    let mount_id = "sim_mount_frame_flip";
    attach_sim_mount(mount_id).await;
    get_sim_mount().write().await.status.side_of_pier = Some(crate::device::PierSide::Unknown);

    let config = skotiq_sequencer::MeridianFlipConfig {
        pause_guiding: false,
        auto_center: false,
        refocus_after: false,
        resume_guiding: false,
        settle_time: 0.0,
        max_retries: 0,
        ..Default::default()
    };
    let ctx = skotiq_sequencer::FlipContext {
        target_name: "NGC 7380".to_string(),
        target_ra_hours: NGC7380_J2000.0,
        target_dec_degrees: NGC7380_J2000.1,
        mount_id: mount_id.to_string(),
        camera_id: None,
        focuser_id: None,
        cover_calibrator_id: None,
        cancellation_token: None,
        trigger_state: None,
        autofocus_config: None,
        simulate: false,
    };
    let mut executor =
        skotiq_sequencer::MeridianFlipExecutor::new(config, create_unified_device_ops());
    let result = executor.execute(&ctx).await;
    let _ = crate::state::get_state().set_observer_location(previous_site);

    assert!(
        matches!(result, skotiq_sequencer::FlipResult::Success { .. }),
        "a flip that landed on target was reported as {result:?}"
    );
}

fn walk_fits(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.is_dir() {
            found.extend(walk_fits(&path));
        } else if path.extension().is_some_and(|e| e == "fits" || e == "fit") {
            found.push(path);
        }
    }
    found
}

/// The cards that say a frame belongs to a sequence run, the only ones a
/// sequence's frame may carry that a manual capture of the same rig does not:
/// the run and the frame's place in its burst, the mosaic panel, the optical
/// train of a two-camera run, the run's plate solve of its target, the
/// photometry a science node measured, and the defect-map record.
const SEQUENCE_ONLY_CARDS: &[&str] = &[
    "SK-SESID", "SK-FIDX", "SK-NPLN", "MOSAIC", "SK-MOSNM", "PANELIDX", "SK-PIDX", "PANELROW",
    "SK-PROW", "PANELCOL", "SK-PCOL", "SK-NPAN", "SK-RIG", "SOLVRA", "SOLVDEC", "PIXSCALE",
    "CROTA1", "CROTA2", "OBJCAT", "REFSTARS", "INSTRMAG", "DIFFMAG", "FWHM", "SNR", "HISTORY",
];

/// Cards whose value is a reading or a time, so two exposures legitimately
/// differ in it. They are compared by key, position and value format.
const READING_CARDS: &[&str] = &[
    "DATE-OBS", "DATE-END", "MJD-OBS", "CCD-TEMP", "FOCTEMP", "OBJCTALT", "AIRMASS",
];

/// A header's 80-character cards up to END, trailing blanks trimmed.
fn raw_cards(path: &std::path::Path) -> Vec<String> {
    let bytes = std::fs::read(path).expect("read FITS");
    let mut cards = Vec::new();
    for card in bytes.chunks(80) {
        let text = String::from_utf8_lossy(card).trim_end().to_string();
        if text == "END" {
            return cards;
        }
        cards.push(text);
    }
    panic!("no END card in {}", path.display());
}

fn card_key(card: &str) -> &str {
    card[..card.len().min(8)].trim_end()
}

/// A card with every digit replaced, so two readings in one format compare
/// equal: same key, same quoting, same number of places, same comment.
fn card_format(card: &str) -> String {
    card.chars()
        .map(|c| if c.is_ascii_digit() { '0' } else { c })
        .collect()
}

async fn attach_sim_device(device_id: &str, device_type: DeviceType, name: &str) {
    crate::simulator::register_connected(get_device_manager(), DeviceInfo {
                id: device_id.to_string(),
                name: name.to_string(),
                device_type,
                driver_type: DriverType::Simulator,
                description: name.to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: name.to_string(),
            }).await;
}

/// The owner's rule: a frame saved from the Imaging screen and a frame saved
/// by a sequence carry the same header, card for card (keys, order, comments,
/// value formats), apart from the cards that tie a frame to a run. Both are
/// taken here on the simulated rig (mount of date, camera, focuser, filter
/// wheel, rotator) through the code each path runs in the app.
#[tokio::test]
async fn a_manual_frame_and_a_sequence_frame_carry_the_same_header() {
    use crate::simulator::camera::get_sim_camera_for;
    use crate::simulator::filter_wheel::get_sim_filterwheel;
    use crate::simulator::focuser::get_sim_focuser;
    use crate::simulator::rotator::get_sim_rotator;

    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_same_header";
    let camera_id = "sim_camera_same_header";
    let focuser_id = "sim_focuser_same_header";
    let wheel_id = "sim_wheel_same_header";
    let rotator_id = "sim_rotator_same_header";
    attach_sim_mount(mount_id).await;
    attach_sim_device(camera_id, DeviceType::Camera, "Simulated Camera").await;
    attach_sim_device(focuser_id, DeviceType::Focuser, "Simulated Focuser").await;
    attach_sim_device(wheel_id, DeviceType::FilterWheel, "Simulated Filter Wheel").await;
    attach_sim_device(rotator_id, DeviceType::Rotator, "Simulated Rotator").await;
    get_sim_camera_for(camera_id).write().await.status.connected = true;
    get_sim_focuser().write().await.status.connected = true;
    get_sim_filterwheel().write().await.status.connected = true;
    get_sim_rotator().write().await.status.connected = true;
    // Focuser, wheel and rotator are read through their driver handles, which
    // only a connect creates, as the Equipment screen's connect does.
    for id in [focuser_id, wheel_id, rotator_id] {
        get_device_manager()
            .connect_device(id)
            .await
            .unwrap_or_else(|e| panic!("connect {id}: {e}"));
    }
    crate::simulator::camera::clear_sim_exposure().await;

    // A site where it is night whenever the test runs: the daylight gate
    // refuses light frames under a Sun above -12 degrees.
    let now = chrono::Utc::now();
    let site = (0..24)
        .map(|hour| (39.9719, -180.0 + 15.0 * f64::from(hour)))
        .min_by(|a, b| {
            skotiq_sequencer::solar::sun_altitude_degrees(a.0, a.1, &now)
                .total_cmp(&skotiq_sequencer::solar::sun_altitude_degrees(b.0, b.1, &now))
        })
        .unwrap();
    // The simulated mount takes its hour angle, and so its pier side, from the
    // app's site.
    let previous_site = crate::state::get_state()
        .get_observer_location()
        .ok()
        .flatten();
    crate::state::get_state()
        .set_observer_location(Some(crate::storage::ObserverLocation {
            latitude: site.0,
            longitude: site.1,
            elevation: 120.0,
        }))
        .unwrap();
    let mut ctx = target_context(mount_id, NGC7380_J2000);
    let slewed =
        skotiq_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        slewed.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        slewed.message
    );

    // The sequence's frame.
    let sequence_dir = tempfile::TempDir::new().unwrap();
    ctx.run.rig.camera_id = Some(camera_id.to_string());
    ctx.run.rig.focuser_id = Some(focuser_id.to_string());
    ctx.run.rig.filterwheel_id = Some(wheel_id.to_string());
    ctx.run.rig.rotator_id = Some(rotator_id.to_string());
    ctx.run.rig.latitude = Some(site.0);
    ctx.run.rig.longitude = Some(site.1);
    ctx.run.rig.save_path = Some(sequence_dir.path().to_path_buf());
    ctx.run.identity.session_id = "same-header-run".to_string();
    ctx.run.identity.observer_name = Some("Test Observer".to_string());
    ctx.run.identity.site_elevation_m = Some(120.0);
    ctx.run.identity.camera_make = Some("ZWO".to_string());
    ctx.run.identity.camera_model = Some("ASI2600MM Pro".to_string());
    ctx.run.identity.telescope_name = Some("Askar 65PHQ".to_string());
    ctx.run.identity.telescope_focal_length_mm = Some(416.0);
    ctx.run.identity.telescope_aperture_mm = Some(65.0);
    let config = skotiq_sequencer::ExposureConfig {
        duration_secs: 0.1,
        count: 1,
        dither_every: None,
        ..Default::default()
    };
    let exposed =
        skotiq_sequencer::instructions::execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert!(
        exposed.status == skotiq_sequencer::NodeStatus::Success,
        "{:?}",
        exposed.message
    );
    let sequence_files = walk_fits(sequence_dir.path());
    assert_eq!(
        sequence_files.len(),
        1,
        "one sequence frame: {sequence_files:?}"
    );

    // The manual frame, as the Imaging screen takes and saves it.
    let manual_dir = tempfile::TempDir::new().unwrap();
    let manual_path = manual_dir.path().join("manual.fits");
    crate::api::imaging::camera_start_exposure_configured_opt(
        camera_id.to_string(),
        0.1,
        None,
        None,
        1,
        1,
        None,
        skotiq_device::FrameType::Light,
    )
    .await
    .expect("manual exposure");
    let saved = crate::api::imaging::api_save_fits_from_last_capture(
        camera_id.to_string(),
        manual_path.to_string_lossy().to_string(),
        crate::api::imaging::FitsWriteHeader {
            object_name: Some("NGC 7380".to_string()),
            exposure_time: 0.1,
            frame_type: "Light".to_string(),
            filter: None,
            gain: None,
            offset: None,
            bin_x: 1,
            bin_y: 1,
            telescope: Some("Askar 65PHQ".to_string()),
            instrument: Some("ZWO ASI2600MM Pro".to_string()),
            observer: Some("Test Observer".to_string()),
            focal_length: Some(416.0),
            aperture: Some(65.0),
            site_latitude: Some(site.0),
            site_longitude: Some(site.1),
            site_elevation: Some(120.0),
            mount_id: Some(mount_id.to_string()),
            focuser_id: Some(focuser_id.to_string()),
            filter_wheel_id: Some(wheel_id.to_string()),
            rotator_id: Some(rotator_id.to_string()),
        },
        false,
    )
    .await;

    get_sim_camera_for(camera_id).write().await.status.connected = false;
    get_sim_focuser().write().await.status.connected = false;
    get_sim_filterwheel().write().await.status.connected = false;
    for id in [focuser_id, wheel_id, rotator_id] {
        let _ = get_device_manager().disconnect_device(id).await;
    }
    get_sim_rotator().write().await.status.connected = false;
    for id in [camera_id, focuser_id, wheel_id, rotator_id, mount_id] {
        get_device_manager().unregister_device(id).await;
    }
    crate::last_frame::clear(camera_id).await;
    saved.expect("manual save");

    let sequence = raw_cards(&sequence_files[0]);
    let manual = raw_cards(&manual_path);
    let both = format!(
        "--- sequence\n{}\n--- manual\n{}",
        sequence.join("\n"),
        manual.join("\n")
    );

    // A manual frame carries no card that ties it to a run, and the rig's
    // cards are all there.
    for card in &manual {
        assert!(
            !SEQUENCE_ONLY_CARDS.contains(&card_key(card)),
            "a manual frame carries the sequence-only card {card:?}\n{both}"
        );
    }
    for key in [
        "FILTER", "FILTPOS", "CCD-TEMP", "XPIXSZ", "RA", "DEC", "OBJCTALT", "EQUINOX", "RADESYS",
        "PIERSIDE", "FOCUSPOS", "FOCTEMP", "ROTATPOS", "SITELAT", "INSTRUME",
    ] {
        assert!(
            manual.iter().any(|card| card_key(card) == key),
            "the manual frame has no {key} card\n{both}"
        );
    }
    let sequence_only: Vec<&str> = sequence
        .iter()
        .map(|card| card_key(card))
        .filter(|key| SEQUENCE_ONLY_CARDS.contains(key))
        .collect();
    assert_eq!(
        sequence_only,
        ["SK-SESID", "SK-FIDX", "SK-NPLN"],
        "the cards that tie this frame to its run\n{both}"
    );

    // Everything else is the same card in the same place.
    let shared: Vec<&String> = sequence
        .iter()
        .filter(|card| !SEQUENCE_ONLY_CARDS.contains(&card_key(card)))
        .collect();
    assert_eq!(
        shared.iter().map(|card| card_key(card)).collect::<Vec<_>>(),
        manual.iter().map(|card| card_key(card)).collect::<Vec<_>>(),
        "the two headers hold different keys or a different order\n{both}"
    );
    for (sequence_card, manual_card) in shared.iter().zip(&manual) {
        if READING_CARDS.contains(&card_key(sequence_card)) {
            assert_eq!(
                card_format(sequence_card),
                card_format(manual_card),
                "a reading is written in two formats\n{both}"
            );
        } else {
            assert_eq!(*sequence_card, manual_card, "a card differs\n{both}");
        }
    }
    let date_obs = manual
        .iter()
        .find(|card| card_key(card) == "DATE-OBS")
        .expect("DATE-OBS");
    assert!(
        !date_obs.contains('Z'),
        "DATE-OBS carries a zone suffix, which the FITS standard does not allow: {date_obs}"
    );
    let _ = crate::state::get_state().set_observer_location(previous_site);
}
