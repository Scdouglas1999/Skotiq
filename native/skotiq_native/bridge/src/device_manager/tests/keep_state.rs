//! P8-9 (owner 2026-11-22): a reconnect keeps the operating state the device
//! had at its last disconnect, and moves nothing. A mount that was tracking
//! and comes back without tracking tracks again at the rate it had; a first
//! connect, with nothing held, adopts what the device reports.

use super::*;
use crate::device::TrackingRate;
use crate::simulator::mount::get_sim_mount;

async fn sim_mount(manager: &DeviceManager, id: &str) {
    manager
        .register_device(build_sim_info(id, DeviceType::Mount), false)
        .await;
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.parked = false;
        mount.status.at_home = Some(false);
        mount.status.slewing = false;
        mount.status.tracking = false;
        mount.status.tracking_rate = Some(TrackingRate::Sidereal);
    }
    manager.connect_device(id).await.expect("connect");
}

async fn sim_mount_reads(tracking: bool, rate: TrackingRate) {
    let mut mount = get_sim_mount().write().await;
    mount.status.tracking = tracking;
    mount.status.tracking_rate = Some(rate);
}

async fn sim_mount_done() {
    let mut mount = get_sim_mount().write().await;
    mount.status.tracking = false;
    mount.status.tracking_rate = Some(TrackingRate::Sidereal);
    mount.status.at_home = Some(false);
    mount.status.connected = false;
}

/// The operator disconnects a tracking mount and connects it again; it came
/// back not tracking (power cycled, or the driver reset it). It tracks again,
/// at the lunar rate it had.
#[tokio::test]
async fn a_manual_reconnect_keeps_the_tracking_and_rate_the_mount_had() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_manual";
    sim_mount(&manager, id).await;
    // Tracking at the lunar rate, set outside Skotiq: only read here.
    sim_mount_reads(true, TrackingRate::Lunar).await;
    manager.mount_get_status(id).await.expect("status");

    manager.disconnect_device(id).await.expect("disconnect");
    sim_mount_reads(false, TrackingRate::Sidereal).await;
    manager.connect_device(id).await.expect("reconnect");

    let status = get_sim_mount().read().await.status.clone();
    assert!(
        status.tracking,
        "the mount tracks again after the reconnect"
    );
    assert_eq!(status.tracking_rate, Some(TrackingRate::Lunar));
    sim_mount_done().await;
}

/// A first connect has nothing to keep: the mount is left as it reports,
/// tracking or not.
#[tokio::test]
async fn a_first_connect_adopts_the_mounts_state() {
    let _guard = simulator_singleton_test_lock().lock().await;
    for (id, tracking) in [("sim_mount_adopt_off", false), ("sim_mount_adopt_on", true)] {
        let manager = build_device_manager();
        manager
            .register_device(build_sim_info(id, DeviceType::Mount), false)
            .await;
        {
            let mut mount = get_sim_mount().write().await;
            mount.status.parked = false;
            mount.status.tracking = tracking;
        }
        manager.connect_device(id).await.expect("connect");
        assert_eq!(
            get_sim_mount().read().await.status.tracking,
            tracking,
            "{id}"
        );
        let _ = manager.disconnect_device(id).await;
    }
    sim_mount_done().await;
}

/// Tracking the mount stopped by itself (its limit, a hand controller) is
/// what it held: a reconnect does not start it again, though tracking was
/// the last command Skotiq sent.
#[tokio::test]
async fn tracking_the_mount_stopped_itself_is_not_restarted() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_stopped";
    sim_mount(&manager, id).await;
    manager.mount_set_tracking(id, true).await.expect("track");
    sim_mount_reads(false, TrackingRate::Sidereal).await;
    manager.mount_get_status(id).await.expect("status");

    manager.mark_lost(id, true, "simulated drop").await;
    manager.connect_device(id).await.expect("reconnect");
    assert!(
        !get_sim_mount().read().await.status.tracking,
        "a mount that stopped tracking itself is not restarted"
    );
    sim_mount_done().await;
}

/// A mount that comes back at home, though it was not at home before, lost
/// its position (the NYX reboots into "at home"): it is not set tracking,
/// and the operator is told.
#[tokio::test]
async fn a_mount_that_came_back_at_home_is_not_set_tracking() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_home";
    sim_mount(&manager, id).await;
    sim_mount_reads(true, TrackingRate::Sidereal).await;
    manager.mount_get_status(id).await.expect("status");
    let mut rx = manager.app_state.event_bus.subscribe();

    manager.mark_lost(id, true, "simulated drop").await;
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.tracking = false;
        mount.status.at_home = Some(true);
    }
    manager.connect_device(id).await.expect("reconnect");
    assert!(!get_sim_mount().read().await.status.tracking);

    let mut told = false;
    while let Ok(event) = rx.try_recv() {
        if let crate::event::bus::EventPayload::System(
            crate::event::system::SystemEvent::Notification { level, message, .. },
        ) = &event.payload
        {
            told |= level == "warning" && message.contains("home");
        }
    }
    assert!(told, "the operator is told why tracking stayed off");
    sim_mount_done().await;
}

fn warnings(rx: &mut tokio::sync::broadcast::Receiver<crate::event::bus::SkotiqEvent>) -> usize {
    let mut count = 0;
    while let Ok(event) = rx.try_recv() {
        if let crate::event::bus::EventPayload::System(
            crate::event::system::SystemEvent::Notification { level, .. },
        ) = &event.payload
        {
            count += usize::from(level == "warning");
        }
    }
    count
}

/// A mount that comes back at home and tracking is left as it is, and
/// nothing says tracking stayed off.
#[tokio::test]
async fn a_mount_that_came_back_at_home_and_tracking_is_left_alone() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_home_tracking";
    sim_mount(&manager, id).await;
    sim_mount_reads(true, TrackingRate::Sidereal).await;
    manager.mount_get_status(id).await.expect("status");
    let mut rx = manager.app_state.event_bus.subscribe();

    manager.mark_lost(id, true, "simulated drop").await;
    get_sim_mount().write().await.status.at_home = Some(true);
    manager.connect_device(id).await.expect("reconnect");
    assert!(get_sim_mount().read().await.status.tracking);
    assert_eq!(warnings(&mut rx), 0);
    sim_mount_done().await;
}

/// A mount that was not tracking and comes back tracking is left tracking:
/// a reconnect only puts back tracking that was on.
#[tokio::test]
async fn a_mount_that_comes_back_tracking_is_left_tracking() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_left_on";
    sim_mount(&manager, id).await;
    manager.mount_get_status(id).await.expect("status");

    manager.disconnect_device(id).await.expect("disconnect");
    sim_mount_reads(true, TrackingRate::Sidereal).await;
    manager.connect_device(id).await.expect("reconnect");
    assert!(get_sim_mount().read().await.status.tracking);
    sim_mount_done().await;
}

/// A read during a slew is not what the mount holds: a link lost mid-slew
/// still resumes the tracking the mount had.
#[tokio::test]
async fn a_read_during_a_slew_is_not_held() {
    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = build_device_manager();
    let id = "sim_mount_keep_slew";
    sim_mount(&manager, id).await;
    sim_mount_reads(true, TrackingRate::Sidereal).await;
    manager.mount_get_status(id).await.expect("status");
    {
        let mut mount = get_sim_mount().write().await;
        mount.status.slewing = true;
        mount.status.tracking = false;
    }
    manager.mount_get_status(id).await.expect("status mid-slew");

    manager.mark_lost(id, true, "lost mid-slew").await;
    get_sim_mount().write().await.status.slewing = false;
    manager.connect_device(id).await.expect("reconnect");
    assert!(get_sim_mount().read().await.status.tracking);
    sim_mount_done().await;
}
