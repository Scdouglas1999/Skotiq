//! The device manager's mount workflow against the ASCOM Alpaca simulator
//! (OmniSim): connect, frame, goto, sync, guide pulse, clock, home, park,
//! disconnect.
//!
//! Ignored by default: point `SKOTIQ_OMNISIM_URL` at a running OmniSim
//! (`http://127.0.0.1:32330`). The frame assertions follow whatever
//! `EquatorialSystem` the simulator is set to, so the scenario is run once
//! with the simulator topocentric (its default) and once set to J2000.

use super::*;
use crate::device::{DriverType, MountTimeInfo};
use crate::device_manager::epoch::MountFrame;
use std::time::{Duration, Instant};

const SLEW_LIMIT: Duration = Duration::from_secs(120);

async fn wait_for(what: &str, mut done: impl AsyncFnMut() -> bool) {
    let start = Instant::now();
    while !done().await {
        assert!(start.elapsed() < SLEW_LIMIT, "{what} did not happen");
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    println!("  {what} after {:.1} s", start.elapsed().as_secs_f64());
}

fn arcmin_apart((ra_a, dec_a): (f64, f64), (ra_b, dec_b): (f64, f64)) -> f64 {
    let mut dra = (ra_a - ra_b).rem_euclid(24.0);
    if dra > 12.0 {
        dra -= 24.0;
    }
    (dra * 15.0 * dec_a.to_radians().cos()).hypot(dec_a - dec_b) * 60.0
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs OmniSim at SKOTIQ_OMNISIM_URL"]
async fn the_mount_workflow_against_omnisim() {
    let url = std::env::var("SKOTIQ_OMNISIM_URL").expect("set SKOTIQ_OMNISIM_URL");
    let raw = skotiq_alpaca::AlpacaTelescope::from_server(&url, 0);
    let manager = build_device_manager();
    let device_id = format!("alpaca:{url}:telescope:0");
    let info = build_mount_info(&device_id, DriverType::Alpaca);
    manager.register_device(info.clone(), false).await;

    println!("connect");
    manager.connect_alpaca(&info).await.expect("connect");
    let declared = raw.equatorial_system().await.expect("EquatorialSystem");
    let frame = manager.mount_frame(&device_id).await.expect("registered");
    println!("  EquatorialSystem {declared} -> {frame}");
    assert_eq!(
        frame,
        MountFrame::from_equatorial_system(declared).unwrap_or(MountFrame::OfDate)
    );

    if manager.mount_get_status(&device_id).await.expect("status").parked {
        manager.mount_unpark(&device_id).await.expect("unpark");
        wait_for("unparked", async || {
            let s = manager.mount_get_status(&device_id).await.expect("status");
            !s.parked && !s.slewing
        })
        .await;
    }

    println!("goto a J2000 target");
    let sidereal = raw.sidereal_time().await.expect("SiderealTime");
    let target = ((sidereal - 1.5).rem_euclid(24.0), 35.0);
    manager
        .mount_slew(&device_id, target.0, target.1)
        .await
        .expect("slew");
    wait_for("arrived", async || {
        !manager.mount_get_status(&device_id).await.expect("status").slewing
    })
    .await;
    let status = manager.mount_get_status(&device_id).await.expect("status");
    assert!(status.tracking, "a goto leaves the mount tracking");
    let readback = (status.right_ascension, status.declination);
    let expected = frame.j2000_to_mount(target.0, target.1);
    let miss = arcmin_apart(readback, expected);
    println!("  read back {readback:?}, expected {expected:?} in the mount's frame, {miss:.3}'");
    assert!(miss < 0.5, "landed {miss}' from the target in the mount's frame");
    let j2000 = frame.mount_to_j2000(readback.0, readback.1);
    assert!(arcmin_apart(j2000, target) < 0.5, "read-back in J2000 is the target");
    if frame == MountFrame::OfDate {
        assert!(arcmin_apart(readback, target) > 5.0, "an of-date mount was sent precessed RA/Dec");
    }

    println!("sync a J2000 position");
    let synced = (target.0, target.1 + 0.05);
    manager
        .mount_sync(&device_id, synced.0, synced.1)
        .await
        .expect("sync");
    let status = manager.mount_get_status(&device_id).await.expect("status");
    let after = frame.mount_to_j2000(status.right_ascension, status.declination);
    assert!(arcmin_apart(after, synced) < 0.5, "synced to {after:?}");

    println!("guide pulse");
    let started = Instant::now();
    manager
        .mount_pulse_guide(&device_id, "north".to_string(), 800)
        .await
        .expect("pulse");
    assert!(started.elapsed() >= Duration::from_millis(800));
    assert!(
        !raw.is_pulse_guiding().await.expect("IsPulseGuiding"),
        "the pulse is over when mount_pulse_guide returns"
    );

    println!("clock");
    let caps = manager.mount_site_capabilities(&device_id).await.expect("site caps");
    assert!(caps.can_write_time);
    let now = chrono::Utc::now().timestamp();
    manager
        .mount_set_time(
            &device_id,
            MountTimeInfo {
                utc_unix_seconds: now,
                utc_offset_hours: 0.0,
            },
        )
        .await
        .expect("set the mount clock");
    let clock = manager.mount_get_time(&device_id).await.expect("read the clock");
    assert!((clock.utc_unix_seconds - now).abs() < 5, "{clock:?}");

    println!("capabilities");
    let capabilities = crate::device_capabilities::alpaca::get_alpaca_capabilities(&device_id)
        .await
        .expect("capabilities");
    let crate::device_capabilities::types::DeviceCapabilities::Mount(mount_caps) = capabilities else {
        panic!("not mount capabilities");
    };
    let alignment = raw.alignment_mode().await.expect("AlignmentMode");
    assert_eq!(mount_caps.is_equatorial, alignment != 0, "AlignmentMode {alignment}");
    assert!(mount_caps.can_park && mount_caps.can_find_home && mount_caps.can_pulse_guide);

    println!("home");
    manager.mount_find_home(&device_id).await.expect("find home");
    wait_for("homed", async || {
        let s = manager.mount_get_status(&device_id).await.expect("status");
        !s.slewing && s.at_home == Some(true)
    })
    .await;

    println!("park");
    manager.mount_park(&device_id).await.expect("park");
    wait_for("parked", async || {
        let s = manager.mount_get_status(&device_id).await.expect("status");
        s.parked && !s.slewing
    })
    .await;
    manager.mount_unpark(&device_id).await.expect("unpark");
    wait_for("unparked", async || {
        let s = manager.mount_get_status(&device_id).await.expect("status");
        !s.parked && !s.slewing
    })
    .await;

    println!("disconnect while someone else's slew runs");
    raw.set_tracking(true).await.expect("Tracking=true");
    raw.slew_to_coordinates_async((sidereal + 1.0).rem_euclid(24.0), 60.0)
        .await
        .expect("a slew Skotiq did not start");
    manager.disconnect_device(&device_id).await.expect("disconnect");
    raw.connect().await.expect("reconnect the raw client");
    assert!(
        raw.slewing().await.expect("Slewing"),
        "disconnecting Skotiq does not stop a slew it did not start"
    );
    wait_for("the other slew finished", async || {
        !raw.slewing().await.expect("Slewing")
    })
    .await;
}
