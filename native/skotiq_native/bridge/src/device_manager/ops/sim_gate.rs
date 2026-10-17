//! Simulator connection-gate helpers.
//!
//! `device_manager::connection::connect_simulator` flips the matching
//! `simulation.rs` singleton's `connected` flag. Every simulator op goes
//! through one of two policies here so that flag governs what the op answers,
//! rather than each dispatcher returning a constant a disconnected simulator
//! has no business producing:
//!
//! 1. **Gated read** (`with_*_status`): consult the singleton; if
//!    `connected == true`, hand the caller a snapshot of the status
//!    struct and let it project whatever field it needs. If
//!    `connected == false`, return a descriptive `Err` so the caller
//!    surfaces the same fail-loud signal as a real driver that lost
//!    its handle.
//! 2. **Gated write** (`require_*_connected`): used by mutating ops
//!    (set/move/park/halt) that the singleton does not literally model
//!    but which still need to refuse to "succeed" when the simulator
//!    isn't connected. Returns `Ok(())` on connected, `Err` otherwise.
//!
//! The gates cover the device types whose singleton exposes a status struct:
//! camera, mount, focuser, filter wheel and rotator. Dome, cover calibrator,
//! safety monitor, switch and weather have singletons of their own and their
//! `DriverType::Simulator` arms read them directly.
//!
//! Every error returned from this module names the simulator device type, so
//! the message says "connect first" rather than leaving the caller with an
//! `Ok(0)` it cannot distinguish from a real reading.

use crate::api::devices::simulation::{
    get_sim_camera, get_sim_filterwheel, get_sim_focuser, get_sim_mount, get_sim_rotator,
};
use crate::device::{CameraStatus, FilterWheelStatus, FocuserStatus, MountStatus, RotatorStatus};

/// Format the not-connected error message uniformly across all simulator
/// device types. Keeping the wording centralized means tests can match on
/// a single substring (`"is not connected"`) without coupling to the exact
/// phrasing of each device type.
pub(crate) fn not_connected(kind: &'static str) -> String {
    format!(
        "Simulator {} is not connected. Call connect_device first.",
        kind
    )
}

/// Message for a simulator device that was connected and then *lost its
/// handle* mid-session, as opposed to one that was never connected.
///
/// Worded to match [`not_connected`] on the substring tests match against
/// (`"is not connected"`) while still naming the injected fault, so a log from
/// a fault-injection run cannot be mistaken for a real disconnection.
pub(crate) fn not_connected_injected(key: &str) -> String {
    format!(
        "Simulator device for '{}' is not connected: the driver handle was lost \
         mid-session (injected fault).",
        key
    )
}

/// Consult the fault registry for `key`, mapping a fired fault to `Err`.
///
/// Every gate below calls this before doing its normal work, which is what lets
/// a test arm a fault without touching any call site. Keys are the
/// `"<device>.<operation>"` strings documented on [`sim_faults::arm`].
async fn faults(key: &str) -> Result<(), String> {
    super::sim_faults::check(key).await
}

/// Per-device-type convenience wrappers around `not_connected` for write-side
/// arms that take the singleton's write lock themselves (so they cannot use
/// `require_*_connected`, which would force two separate lock acquisitions).
#[inline]
pub(crate) fn not_connected_camera() -> String {
    not_connected("camera")
}

#[inline]
pub(crate) fn not_connected_focuser() -> String {
    not_connected("focuser")
}

#[inline]
pub(crate) fn not_connected_filterwheel() -> String {
    not_connected("filter wheel")
}

#[inline]
pub(crate) fn not_connected_rotator() -> String {
    not_connected("rotator")
}

/// Read-side helper for camera ops: clones the singleton status when
/// connected, otherwise returns `Err`.
///
/// Status fields not modelled by `SimulatedCamera` (e.g. sensor dimensions
/// match the singleton's defaults — see `SimulatedCamera::default`) are
/// covered by the singleton's defaults and need no special handling at
/// the call site.
pub(crate) async fn read_camera_status() -> Result<CameraStatus, String> {
    // Faults are consulted before anything else, including the connected gate,
    // so an armed fault is deterministic for the test that armed it rather than
    // depending on singleton state left behind by an earlier case.
    faults("camera.status").await?;
    // Let the simulated sensor temperature move toward its setpoint before the
    // caller samples it. Every simulated status read funnels through here, so
    // this is the one place the ramp needs driving.
    //
    // A stalled cooler is a real failure mode (the TEC never reaches setpoint
    // and the run silently uses warm darks), so the stall latch suppresses the
    // ramp while leaving every read succeeding.
    if !super::sim_faults::is_stalled("camera.cooler") {
        crate::api::devices::simulation::advance_sim_cooler().await;
    }
    let state = crate::api::devices::simulation::sim_camera_state().await;
    let cam = get_sim_camera().read().await;
    if !cam.status.connected {
        return Err(not_connected("camera"));
    }
    let mut status = cam.status.clone();
    // `state` is derived from the exposure clock rather than stored, because
    // nothing writes it as the exposure progresses. Reporting the stored
    // `Idle` left this call contradicting `camera_is_exposure_complete` on the
    // same polling cycle: one said the camera was idle, the other said the
    // frame was not ready.
    status.state = state;
    Ok(status)
}

/// What the last exposure the simulator camera was asked for actually was, so
/// the download path can report a truthful `EXPTIME` and frame type instead of
/// constants.
pub(crate) async fn read_camera_last_exposure(
) -> Result<crate::api::devices::simulation::SimExposureRequest, String> {
    // `camera.download` is the highest-value fault key in the file: the INDI
    // BLOB download timeout and the USB camera that stops answering mid-read
    // both land here, and both cost a whole frame on real hardware.
    faults("camera.download").await?;
    if !get_sim_camera().read().await.status.connected {
        return Err(not_connected("camera"));
    }
    Ok(crate::api::devices::simulation::get_sim_last_exposure()
        .read()
        .await
        .clone())
}

/// Write-side gate for camera ops: returns `Ok(())` only when the
/// simulator camera singleton is currently connected.
pub(crate) async fn require_camera_connected() -> Result<(), String> {
    faults("camera.command").await?;
    if !get_sim_camera().read().await.status.connected {
        return Err(not_connected("camera"));
    }
    Ok(())
}

/// Read-side helper for mount ops.
///
/// Altitude, azimuth and sidereal time are DERIVED from the mount's stored
/// RA/Dec, the configured observer location and the current time rather than
/// reported from storage: a stored value is stale the moment the sky moves, and
/// a mount that claims +45° altitude for a target 30° below the horizon makes
/// horizon limits and altitude safety-park untestable.
///
/// Pier side is NOT derived: it is mechanical state a slew leaves the mount in,
/// not a projection of where it is pointing. See
/// `simulation::pier_side_after_slew_to`.
///
/// With no site configured there is no honest answer, so the horizon-frame
/// fields report `Unsupported` and carry `None` instead of a fabricated default.
pub(crate) async fn read_mount_status() -> Result<MountStatus, String> {
    faults("mount.status").await?;
    if !get_sim_mount().read().await.status.connected {
        return Err(not_connected("mount"));
    }
    advance_mount_motion().await;
    let mut status = get_sim_mount().read().await.status.clone();
    apply_derived_mount_telemetry(&mut status, observer_site(), chrono::Utc::now());
    Ok(status)
}

/// Bring an in-flight simulated slew up to the present.
///
/// `simulation::advance_sim_slew` is interpolation, not a motor: nothing runs it
/// on a timer, so the mount is only ever as far along as the last caller that
/// asked. Both gates in this module run it, which is what makes "where is the
/// mount right now" the same answer whether the caller is reading status or
/// issuing a command.
///
/// A stalled mount keeps answering truthfully — it simply never gets closer to
/// the target. Suppressing the advance here (rather than failing the slew
/// command) is what makes the app's slew timeout the only thing that can detect
/// it, exactly as on real hardware.
async fn advance_mount_motion() {
    if super::sim_faults::is_stalled("mount.slew") {
        return;
    }
    crate::api::devices::simulation::advance_sim_slew().await;
}

/// Configured observer location as `(latitude, longitude)`, if the app has one.
fn observer_site() -> Option<(f64, f64)> {
    crate::api::get_state()
        .get_observer_location()
        .ok()
        .flatten()
        .map(|loc| (loc.latitude, loc.longitude))
}

/// Overwrite the horizon-frame fields of `status` with values computed from its
/// own RA/Dec at `now`, and set the matching availability entries.
///
/// `side_of_pier` is left exactly as stored — it is the one optional mount field
/// that is not a function of the current pointing.
pub(crate) fn apply_derived_mount_telemetry(
    status: &mut MountStatus,
    site: Option<(f64, f64)>,
    now: chrono::DateTime<chrono::Utc>,
) {
    use crate::device::{mount_status_field as field, FieldAvailability};
    use skotiq_sequencer::meridian::{calculate_alt_az, julian_day, local_sidereal_time};

    let Some((latitude, longitude)) = site else {
        let reason = FieldAvailability::Unsupported;
        status.altitude = None;
        status.azimuth = None;
        status.sidereal_time = None;
        for key in [field::ALTITUDE, field::AZIMUTH, field::SIDEREAL_TIME] {
            status.availability.insert(key.to_string(), reason.clone());
        }
        return;
    };

    let lst = local_sidereal_time(julian_day(&now), longitude);
    let (altitude, azimuth) = calculate_alt_az(
        status.right_ascension,
        status.declination,
        latitude,
        longitude,
        now,
    );

    status.altitude = Some(altitude);
    status.azimuth = Some(azimuth);
    status.sidereal_time = Some(lst);

    for key in [field::ALTITUDE, field::AZIMUTH, field::SIDEREAL_TIME] {
        status
            .availability
            .insert(key.to_string(), FieldAvailability::Available);
    }
}

/// Write-side gate for mount ops.
///
/// Advancing the motion here is what makes abort/stop/park/re-target truthful.
/// A command arrives at a real mount while the axes are still turning, so it
/// acts on wherever the tube has actually reached; the simulated one only moved
/// when someone read its status, so a command issued without polling first acted
/// on the pointing as of the last poll. Aborting a slew nobody had watched left
/// the mount reporting its exact START coordinates — the one position a real
/// abort can never leave you in — so "stopped part-way, pointing at neither end"
/// was unreachable, and code that assumes a failed slew means "still where it
/// was" passed here and lost the pointing on hardware.
pub(crate) async fn require_mount_connected() -> Result<(), String> {
    faults("mount.command").await?;
    if !get_sim_mount().read().await.status.connected {
        return Err(not_connected("mount"));
    }
    advance_mount_motion().await;
    Ok(())
}

/// Refuse a mount command that a real driver will not accept while the axes are
/// still moving.
///
/// ASCOM raises `InvalidOperationException` for a slew/sync issued mid-slew and
/// INDI rejects the coordinate set; the codebase already knows this — see
/// `meridian_flip_executor`'s "Some mounts will refuse a park while slewing",
/// which is why that path aborts before it parks. The simulator instead
/// accepted every one of them and silently discarded the in-flight slew, so
/// that abort-first handling, and every retry path behind it, had nothing to
/// react to and no no-hardware run could reach it.
///
/// Must be called AFTER [`require_mount_connected`], which is what advances the
/// motion (under the fault gate) so "is it still moving" is answered as of now
/// rather than as of the last status poll.
pub(crate) async fn refuse_while_mount_slewing(operation: &str) -> Result<(), String> {
    // Both signals, because they can disagree: `sim_slew_in_flight` covers a
    // goto (including its settle tail) even when a fault has frozen the
    // interpolation, while `status.slewing` also covers a manual axis move,
    // which has no interpolation cell at all.
    let moving = crate::api::devices::simulation::sim_slew_in_flight().await
        || get_sim_mount().read().await.status.slewing;
    if moving {
        return Err(format!(
            "Simulated mount is slewing and refused {}. Abort the slew or wait for it to finish.",
            operation
        ));
    }
    Ok(())
}

/// Read-side helper for focuser ops.
pub(crate) async fn read_focuser_status() -> Result<FocuserStatus, String> {
    faults("focuser.status").await?;
    let focuser = get_sim_focuser().read().await;
    if !focuser.status.connected {
        return Err(not_connected("focuser"));
    }
    let mut status = focuser.status.clone();
    if status.temperature.is_some() {
        status.temperature = Some(crate::api::devices::simulation::sim_focuser_temperature_c());
    }
    Ok(status)
}

/// Write-side gate for focuser ops.
///
/// Kept as part of the symmetric surface even when current callers all
/// take the singleton's write lock themselves (and therefore use
/// `not_connected_focuser` instead) — symmetry makes "did the simulator
/// arm forget the gate?" reviewable at a glance.
#[allow(dead_code)]
pub(crate) async fn require_focuser_connected() -> Result<(), String> {
    faults("focuser.command").await?;
    if !get_sim_focuser().read().await.status.connected {
        return Err(not_connected("focuser"));
    }
    Ok(())
}

/// Read-side helper for filter wheel ops.
pub(crate) async fn read_filterwheel_status() -> Result<FilterWheelStatus, String> {
    faults("filterwheel.status").await?;
    let fw = get_sim_filterwheel().read().await;
    if !fw.status.connected {
        return Err(not_connected("filter wheel"));
    }
    Ok(fw.status.clone())
}

/// Write-side gate for filter wheel ops.
///
/// See `require_focuser_connected` for why this stays in the API surface
/// even when not currently invoked.
#[allow(dead_code)]
pub(crate) async fn require_filterwheel_connected() -> Result<(), String> {
    faults("filterwheel.command").await?;
    if !get_sim_filterwheel().read().await.status.connected {
        return Err(not_connected("filter wheel"));
    }
    Ok(())
}

/// Read-side helper for rotator ops.
pub(crate) async fn read_rotator_status() -> Result<RotatorStatus, String> {
    faults("rotator.status").await?;
    let rotator = get_sim_rotator().read().await;
    if !rotator.status.connected {
        return Err(not_connected("rotator"));
    }
    Ok(rotator.status.clone())
}

/// Write-side gate for rotator ops.
///
/// See `require_focuser_connected` for why this stays in the API surface
/// even when not currently invoked.
#[allow(dead_code)]
pub(crate) async fn require_rotator_connected() -> Result<(), String> {
    faults("rotator.command").await?;
    if !get_sim_rotator().read().await.status.connected {
        return Err(not_connected("rotator"));
    }
    Ok(())
}

/// Loud-error helper for a simulator device type with no matching singleton in
/// `api::devices::simulation`.
///
/// Centralising the wording keeps the refusal identical across device types,
/// so a call site that gains a singleton swaps helpers rather than rewriting
/// its error message.
pub(crate) fn unsupported_simulator_device(kind: &'static str) -> String {
    format!(
        "Simulator {} devices are disabled (no simulator implementation). \
         Connect real hardware or use INDI/ASCOM/Alpaca simulators for testing.",
        kind
    )
}

/// End-to-end proof that an armed fault actually reaches the app.
///
/// The registry's own tests ([`super::sim_faults`]) prove the trigger/effect
/// bookkeeping. These prove the part that matters: that a fault armed by key
/// travels through the real gate a connected simulator uses, and that what comes
/// back out is a truthful error rather than synthetic data. Without this, the
/// registry could be perfect and still be wired to nothing.
#[cfg(test)]
mod fault_injection_tests {
    use super::*;
    use crate::device_manager::ops::sim_faults::{self, Effect, FaultSpec, Trigger};

    /// The simulator singletons are process-global, so these serialize against
    /// the same lock the other simulator tests use and clear the registry after
    /// themselves — a leaked fault would surface as an unrelated test failing.
    async fn connected_camera() -> tokio::sync::MutexGuard<'static, ()> {
        let guard = crate::api::devices::simulation::sim_singleton_test_lock()
            .lock()
            .await;
        sim_faults::clear_all();
        get_sim_camera().write().await.status.connected = true;
        guard
    }

    #[tokio::test]
    async fn an_armed_fault_reaches_the_camera_status_gate() {
        let _guard = connected_camera().await;
        sim_faults::arm("camera.status", FaultSpec::not_implemented());

        let err = read_camera_status()
            .await
            .expect_err("an armed fault must surface, not be swallowed");
        assert!(
            err.contains("0x80020009"),
            "the driver's own message must reach the app verbatim so the user is \
             not told something generic: {err}"
        );

        sim_faults::clear_all();
        assert!(
            read_camera_status().await.is_ok(),
            "clearing the registry must restore normal behaviour"
        );
    }

    /// A transient fault must not be sticky: the whole point of `Times(1)` is
    /// that the app's retry succeeds. If this failed, retry logic would be
    /// untestable.
    #[tokio::test]
    async fn a_transient_fault_lets_the_retry_through() {
        let _guard = connected_camera().await;
        sim_faults::arm("camera.status", FaultSpec::transient("USB stall"));

        assert!(read_camera_status().await.is_err(), "first call must fail");
        assert!(
            read_camera_status().await.is_ok(),
            "the retry must succeed, or 'retry once' can never be verified"
        );
        sim_faults::clear_all();
    }

    /// The failure that actually loses a night: the cooler never reaches
    /// setpoint. Every read keeps succeeding, so only comparing temperature
    /// against setpoint over time can detect it.
    #[tokio::test]
    async fn a_stalled_cooler_keeps_answering_while_never_cooling() {
        let _guard = connected_camera().await;
        {
            let mut cam = get_sim_camera().write().await;
            cam.status.target_temp = Some(-10.0);
            cam.status.sensor_temp = Some(20.0);
            cam.status.cooler_on = true;
        }
        sim_faults::arm(
            "camera.cooler",
            FaultSpec::new(Trigger::Always, Effect::Stall),
        );
        // Latch the stall (the effect arms on first consultation).
        sim_faults::check("camera.cooler")
            .await
            .expect("stall latching should not fail the status read");

        let first = read_camera_status().await.expect("reads keep succeeding");
        for _ in 0..5 {
            read_camera_status().await.expect("reads keep succeeding");
        }
        let last = read_camera_status().await.expect("reads keep succeeding");

        assert_eq!(
            first.sensor_temp, last.sensor_temp,
            "a stalled cooler must not drift toward setpoint; if it does, the \
             app can never be tested against warm darks"
        );
        let sensor = last
            .sensor_temp
            .expect("the sim reports a sensor temperature");
        let target = last.target_temp.expect("the sim reports a setpoint");
        assert!(
            (sensor - target).abs() > 1.0,
            "the sensor reached setpoint ({sensor}C vs {target}C) despite a stalled cooler"
        );
        sim_faults::clear_all();
    }

    /// A disconnect fault has to be distinguishable from an operation failure,
    /// because the app is supposed to react differently (reconnect, not retry).
    #[tokio::test]
    async fn a_mid_session_disconnect_is_reported_as_a_disconnect() {
        let _guard = connected_camera().await;
        sim_faults::arm(
            "camera.status",
            FaultSpec::new(Trigger::Always, Effect::NotConnected),
        );
        let err = read_camera_status().await.expect_err("must fail");
        assert!(
            err.contains("not connected"),
            "a lost handle must read as a disconnection: {err}"
        );
        sim_faults::clear_all();
    }
}

/// Proof that the simulated mount is somewhere real when a COMMAND lands on it,
/// not just when someone reads its status.
///
/// These drive the mount through the device manager rather than calling the
/// gate directly. The gate, `mount.rs`'s simulator arms and
/// `simulation::advance_sim_slew` can each be correct on their own and still
/// wire up to a mount only ever findable at the two endpoints of a slew, so
/// only the assembled path proves the behaviour.
#[cfg(test)]
mod mount_motion_tests {
    use crate::api::devices::simulation::{get_sim_mount, sim_singleton_test_lock, SimulatedMount};
    use crate::api::{get_device_manager, get_state};
    use crate::device::{DeviceInfo, DeviceType, DriverType, PierSide};
    use crate::device_manager::ops::sim_faults::{self, Effect, FaultSpec, Trigger};
    use crate::storage::ObserverLocation;
    use std::time::Duration;

    const TEST_LONGITUDE: f64 = -75.0;

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
        get_device_manager().register_device(info, false).await;
        get_state()
            .set_observer_location(Some(ObserverLocation {
                latitude: 40.0,
                longitude: TEST_LONGITUDE,
                elevation: 100.0,
            }))
            .expect("test site should be settable");
        sim_faults::clear_all();
        // The interpolation cell lives outside `SimulatedMount`, so resetting
        // the struct alone would leave the previous test's slew in flight and
        // this one's first command would be refused as "still moving".
        crate::api::devices::simulation::cancel_sim_slew().await;
        let mut mount = get_sim_mount().write().await;
        *mount = SimulatedMount::default();
        mount.status.connected = true;
    }

    /// The pier side to leave the mount on so that a slew to `ra` also has to
    /// cross it, which doubles the commanded slew's duration. Nothing about the
    /// contract under test needs the flip; it just buys a wide enough in-flight
    /// window that a scheduling hiccup cannot end the slew before the assertion.
    async fn park_on_the_far_side_of(ra: f64) {
        use skotiq_sequencer::meridian;
        let now = chrono::Utc::now();
        let lst = meridian::local_sidereal_time(meridian::julian_day(&now), TEST_LONGITUDE);
        let opposite = match meridian::expected_pier_side(meridian::hour_angle(ra, lst)) {
            meridian::PierSide::West => PierSide::East,
            _ => PierSide::West,
        };
        get_sim_mount().write().await.status.side_of_pier = Some(opposite);
    }

    /// The state a real abort leaves you in: pointing at neither the target nor
    /// the coordinates the slew started from.
    ///
    /// The simulator could not produce it. Motion only advanced on a status
    /// read, so an abort issued without polling first froze the mount on its
    /// exact start coordinates — and anything that reads "not slewing, still at
    /// the origin" as "the slew never began, the pointing is still good" was
    /// only ever tested against a state a mount cannot be in.
    #[tokio::test]
    async fn an_unpolled_abort_stops_the_mount_between_start_and_target() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_unpolled_abort";
        // Raw J2000 keeps the 0h -> 12h geometry exact: precessed, 12h becomes
        // 12.02h and the short way round is backwards through 0h.
        let _frame = crate::device_manager::epoch::SimFrameGuard::pin(
            crate::device_manager::epoch::SimMountFrame::J2000,
        );
        attach_sim_mount(device_id).await;
        park_on_the_far_side_of(12.0).await;
        let mgr = get_device_manager();

        // 0h -> 12h is the longest slew on the sky, and it also crosses the
        // pier, so the mount is still well short of the target after the sleep.
        mgr.mount_slew(device_id, 12.0, 0.0).await.unwrap();
        // Deliberately no status read in here: a caller that polls would hide
        // the defect by advancing the motion as a side effect.
        tokio::time::sleep(Duration::from_millis(300)).await;
        mgr.mount_abort(device_id).await.unwrap();

        let stopped = mgr.mount_get_status(device_id).await.unwrap();
        assert!(!stopped.slewing, "abort must stop the motion");
        assert!(
            stopped.right_ascension > 0.05,
            "the mount reported RA {:.4}h — it was aborted on its start \
             coordinates, which is the one place a real abort cannot leave it",
            stopped.right_ascension
        );
        assert!(
            stopped.right_ascension < 11.95,
            "the mount reported RA {:.4}h — an aborted slew still arrived",
            stopped.right_ascension
        );
    }

    /// Re-targeting after an abort must not teleport the mount backwards.
    ///
    /// `begin_sim_slew` interpolates from wherever the mount is when the command
    /// lands, so feeding it a stale sample made the tube jump back to the
    /// coordinates of the slew it had already partly completed and abandoned.
    /// A mount that reports a pointing it demonstrably left is the exact shape
    /// of bug that makes plate-solve-and-centre loops chase their own tail.
    ///
    /// The abort is not incidental: a real driver refuses a slew issued while
    /// the axes are still turning (see
    /// `a_slew_sync_or_park_is_refused_while_the_mount_is_moving`), so
    /// "change of mind" is always abort-then-slew.
    #[tokio::test]
    async fn re_targeting_after_an_abort_resumes_from_where_the_mount_actually_is() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_retarget";
        attach_sim_mount(device_id).await;
        park_on_the_far_side_of(12.0).await;
        let mgr = get_device_manager();

        mgr.mount_slew(device_id, 12.0, 0.0).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        // Change of mind, with no intervening poll. The new target is chosen so
        // the short way round runs the same direction as the first slew: a
        // mount that resumed from the stale start would report ~0h, one that
        // resumed from where it is reports where it had got to.
        mgr.mount_abort(device_id).await.unwrap();
        mgr.mount_slew(device_id, 6.0, 0.0).await.unwrap();

        let redirected = mgr.mount_get_status(device_id).await.unwrap();
        assert!(redirected.slewing, "the re-target must still be in flight");
        assert!(
            redirected.right_ascension > 1.0,
            "the mount jumped back to RA {:.4}h, the start of the slew it had \
             already abandoned",
            redirected.right_ascension
        );
    }

    /// A real driver refuses a pointing command issued mid-motion.
    ///
    /// ASCOM raises `InvalidOperationException` and INDI rejects the property
    /// set, so the simulator must refuse slew, sync and park while the axes are
    /// turning too — otherwise the app's abort-then-retry handling
    /// (`meridian_flip_executor`, `try_park_with_retry`) has nothing to react
    /// to on a no-hardware run.
    #[tokio::test]
    async fn a_slew_sync_or_park_is_refused_while_the_mount_is_moving() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_busy";
        attach_sim_mount(device_id).await;
        park_on_the_far_side_of(12.0).await;
        let mgr = get_device_manager();

        mgr.mount_slew(device_id, 12.0, 0.0).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;

        for (label, result) in [
            ("slew", mgr.mount_slew(device_id, 6.0, 0.0).await),
            ("sync", mgr.mount_sync(device_id, 6.0, 0.0).await),
            ("park", mgr.mount_park(device_id).await),
        ] {
            let error = result.expect_err(&format!(
                "{} was accepted while the mount was still slewing",
                label
            ));
            assert!(
                error.to_string().contains("is slewing"),
                "{} refusal must say the mount is moving, got: {}",
                label,
                error
            );
        }

        // Still travelling: a refused command must not have cancelled it.
        assert!(
            mgr.mount_get_status(device_id).await.unwrap().slewing,
            "a refused command silently stopped the slew it refused"
        );

        // And the same commands are accepted once the motion is stopped.
        mgr.mount_abort(device_id).await.unwrap();
        mgr.mount_park(device_id).await.unwrap();
    }

    /// The axes arrive before the driver reports idle.
    ///
    /// `slewing` must hold through a settle after the target coordinates first
    /// read back, so "arrived" and "stopped moving" stay separate events. Fuse
    /// them and every wait-for-motion path is satisfied on its first poll, and
    /// no settle-ordering bug can reproduce without hardware.
    #[tokio::test]
    async fn the_mount_holds_slewing_through_a_settle_after_it_arrives() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_settle";
        // The shortest move is the one onto the mount's own position, which
        // needs the target and the read-back in one frame.
        let _frame = crate::device_manager::epoch::SimFrameGuard::pin(
            crate::device_manager::epoch::SimMountFrame::J2000,
        );
        attach_sim_mount(device_id).await;
        let mgr = get_device_manager();

        // Shortest possible move so the interpolation is over almost at once
        // and what remains is the settle tail on its own.
        mgr.mount_slew(device_id, 0.0, 0.0).await.unwrap();
        tokio::time::sleep(Duration::from_millis(350)).await;

        let settling = mgr.mount_get_status(device_id).await.unwrap();
        assert!(
            settling.right_ascension.abs() < 1e-9 && settling.declination.abs() < 1e-9,
            "the axes should already be on target during the settle, got RA {:.6}h Dec {:.6}",
            settling.right_ascension,
            settling.declination
        );
        assert!(
            settling.slewing,
            "the mount reported idle the instant its axes arrived — a real \
             driver holds Slewing through the mechanical settle"
        );

        tokio::time::sleep(Duration::from_millis(600)).await;
        assert!(
            !mgr.mount_get_status(device_id).await.unwrap().slewing,
            "the settle never ended"
        );
    }

    /// Every mutating simulated mount op runs the shared write gate.
    ///
    /// `mount_unpark`, `mount_set_tracking`, `mount_set_tracking_rate` and
    /// `mount_move_axis` each did their own inline `connected` read instead, so
    /// they bypassed the gate's fault injector and its motion advance: a
    /// no-hardware run could not make any of them fail, and they acted on the
    /// pointing as of the last status poll rather than as of now.
    #[tokio::test]
    async fn every_mutating_mount_op_goes_through_the_command_gate() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_command_gate";
        attach_sim_mount(device_id).await;
        let mgr = get_device_manager();

        sim_faults::arm(
            "mount.command",
            FaultSpec::new(
                Trigger::Always,
                Effect::Error("mount driver rejected the command".to_string()),
            ),
        );

        for (label, result) in [
            ("unpark", mgr.mount_unpark(device_id).await),
            (
                "set_tracking",
                mgr.mount_set_tracking(device_id, true).await,
            ),
            (
                "set_tracking_rate",
                mgr.mount_set_tracking_rate(device_id, 1).await,
            ),
            ("move_axis", mgr.mount_move_axis(device_id, 0, 0.5).await),
        ] {
            assert!(
                result.is_err(),
                "{} succeeded against a driver that rejects every command — it \
                 is not going through require_mount_connected",
                label
            );
        }

        sim_faults::clear_all();
    }

    /// A stalled mount has to be stalled for commands too.
    ///
    /// A stall's entire signature is "it never gets closer to the target". If
    /// the command path advanced the motion anyway, aborting a stalled slew
    /// would report the mount part-way down a track it never travelled, and the
    /// slew timeout — the only thing that can detect a stall — would be
    /// contradicted by the position it reads back.
    #[tokio::test]
    async fn a_stalled_mount_does_not_creep_forward_when_a_command_arrives() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_gate_mount_stalled_abort";
        attach_sim_mount(device_id).await;
        let mgr = get_device_manager();

        sim_faults::arm("mount.slew", FaultSpec::new(Trigger::Always, Effect::Stall));
        // The effect latches on first consultation.
        sim_faults::check("mount.slew")
            .await
            .expect("stall latching should not fail the slew command");

        mgr.mount_slew(device_id, 12.0, 0.0).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        mgr.mount_abort(device_id).await.unwrap();

        let stopped = mgr.mount_get_status(device_id).await.unwrap();
        assert!(
            stopped.right_ascension.abs() < 1e-9,
            "a stalled mount reported RA {:.4}h: the abort path moved axes that \
             were jammed",
            stopped.right_ascension
        );
        sim_faults::clear_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::{mount_status_field as field, FieldAvailability, PierSide};
    use chrono::TimeZone;

    fn parked_status() -> MountStatus {
        crate::api::devices::simulation::SimulatedMount::default().status
    }

    /// Altitude and azimuth have to follow the mount's own RA/Dec and the clock.
    /// They were stored constants: after a slew to RA 5.5h / Dec +30° the mount
    /// reported altitude 0.0, azimuth 0.0 and sidereal time 0.0 while marking all
    /// three `Available`. Independently computed truth at that instant was
    /// +72.83° / 239.76° / 6.642 h.
    #[test]
    fn derived_telemetry_tracks_ra_dec_and_time() {
        let latitude = 40.0;
        let longitude = -75.0;
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();

        let mut status = parked_status();
        status.right_ascension = 5.5;
        status.declination = 30.0;
        apply_derived_mount_telemetry(&mut status, Some((latitude, longitude)), now);

        let expected =
            skotiq_sequencer::meridian::calculate_alt_az(5.5, 30.0, latitude, longitude, now);
        let altitude = status.altitude.expect("altitude derived");
        let azimuth = status.azimuth.expect("azimuth derived");
        assert!((altitude - expected.0).abs() < 1e-9);
        assert!((azimuth - expected.1).abs() < 1e-9);
        assert!(
            altitude != 0.0 && azimuth != 0.0,
            "the stubbed 0.0/0.0 pair survived"
        );

        let lst = status.sidereal_time.expect("LST derived");
        let expected_lst = skotiq_sequencer::meridian::local_sidereal_time(
            skotiq_sequencer::meridian::julian_day(&now),
            longitude,
        );
        assert!((lst - expected_lst).abs() < 1e-9);
    }

    /// The same pointing at two different times must give two different
    /// altitudes, or a horizon limit can never trip.
    #[test]
    fn derived_altitude_moves_with_the_clock() {
        let site = Some((40.0, -75.0));
        let mut early = parked_status();
        early.right_ascension = 5.5;
        early.declination = 30.0;
        let mut late = early.clone();

        apply_derived_mount_telemetry(
            &mut early,
            site,
            chrono::Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap(),
        );
        apply_derived_mount_telemetry(
            &mut late,
            site,
            chrono::Utc.with_ymd_and_hms(2026, 7, 28, 6, 17, 0).unwrap(),
        );

        let delta = (early.altitude.unwrap() - late.altitude.unwrap()).abs();
        assert!(
            delta > 1.0,
            "three hours of sky rotation moved the reported altitude by only {delta:.4}°"
        );
    }

    /// A target that can never rise must never be reported above the horizon.
    /// Dec −80° from latitude +40° peaks at −30°, yet the simulator reported it
    /// at +45°, which is what made altitude safety-park untestable.
    #[test]
    fn permanently_invisible_target_is_reported_below_the_horizon() {
        let base = chrono::Utc.with_ymd_and_hms(2026, 7, 28, 0, 0, 0).unwrap();
        for hour in 0..24 {
            let mut status = parked_status();
            status.right_ascension = 5.5;
            status.declination = -80.0;
            apply_derived_mount_telemetry(
                &mut status,
                Some((40.0, -75.0)),
                base + chrono::Duration::hours(hour),
            );
            let altitude = status.altitude.expect("altitude derived");
            assert!(
                altitude < 0.0,
                "Dec -80 from lat +40 reported altitude {altitude} at hour {hour}"
            );
        }
    }

    /// Pier side is mechanical state the mount is left in by a slew, NOT a
    /// function of where it happens to be pointing. Deriving it here made it
    /// change as the sky turned, with no mount command — and made a meridian
    /// flip, whose whole signature is "the side changed", impossible to detect:
    /// re-slewing to the same RA/Dec re-derived the same answer, so
    /// `verify_pier_side_changed` failed every simulated flip.
    #[test]
    fn pier_side_is_left_alone_by_the_derived_telemetry() {
        let site = Some((40.0, -75.0));
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap();
        let lst = skotiq_sequencer::meridian::local_sidereal_time(
            skotiq_sequencer::meridian::julian_day(&now),
            -75.0,
        );

        for stored in [PierSide::East, PierSide::West, PierSide::Unknown] {
            for hour_angle in [-3.0, 3.0] {
                let mut status = parked_status();
                status.right_ascension = (lst - hour_angle).rem_euclid(24.0);
                status.side_of_pier = Some(stored);
                apply_derived_mount_telemetry(&mut status, site, now);
                assert_eq!(
                    status.side_of_pier,
                    Some(stored),
                    "the reported pier side was recomputed from the pointing \
                     (hour angle {hour_angle}h) instead of reporting the side \
                     the mount was actually left on"
                );
            }
        }
    }

    /// With no site there is no honest answer, so the fields must report
    /// `Unsupported` and carry `None` rather than a fabricated default — the
    /// exact distinction `FieldAvailability` exists to preserve.
    #[test]
    fn without_a_site_the_horizon_fields_are_unsupported() {
        let mut status = parked_status();
        status.right_ascension = 5.5;
        status.declination = 30.0;
        apply_derived_mount_telemetry(
            &mut status,
            None,
            chrono::Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap(),
        );

        assert_eq!(status.altitude, None);
        assert_eq!(status.azimuth, None);
        assert_eq!(status.sidereal_time, None);
        // SIDE_OF_PIER is deliberately absent: it is stored mechanical state,
        // not a horizon-frame projection, so a missing site does not make it
        // unknowable.
        for key in [field::ALTITUDE, field::AZIMUTH, field::SIDEREAL_TIME] {
            assert_eq!(
                status.availability.get(key),
                Some(&FieldAvailability::Unsupported),
                "{key} must not advertise itself available without a site"
            );
        }
    }

    /// A derived field must advertise itself available, so the UI renders the
    /// value rather than a dash.
    #[test]
    fn derived_fields_are_marked_available() {
        let mut status = parked_status();
        status.right_ascension = 5.5;
        status.declination = 30.0;
        apply_derived_mount_telemetry(
            &mut status,
            Some((40.0, -75.0)),
            chrono::Utc.with_ymd_and_hms(2026, 7, 28, 3, 17, 0).unwrap(),
        );
        for key in [field::ALTITUDE, field::AZIMUTH, field::SIDEREAL_TIME] {
            assert_eq!(
                status.availability.get(key),
                Some(&FieldAvailability::Available)
            );
        }
    }
}
