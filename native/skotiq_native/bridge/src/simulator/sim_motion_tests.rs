use super::*;
use crate::simulator::camera::{
    begin_sim_exposure, begin_sim_exposure_for, clear_sim_exposure, get_sim_camera_for,
    next_sim_frame_seed, reset_sim_frame_seed, sim_camera_fault_prefix,
    sim_exposure_elapsed_is_complete, sim_exposure_is_complete, take_sim_exposure_for_download,
    SimExposureRequest, SIM_GUIDE_CAMERA_ID, SIM_IMAGING_CAMERA_ID,
};
use crate::simulator::guiding::{
    apply_offset_delta, drift_step_secs, sim_pulse_delta, SIM_DRIFT_PX_PER_SEC_X,
    SIM_MAX_DRIFT_STEP_SECS, SIM_MAX_OFFSET_PX,
};

/// Successive frames must draw different noise, and the sequence must be
/// resettable so a run can be reproduced exactly.
#[test]
fn frame_seed_sequence_is_reproducible_after_reset() {
    reset_sim_frame_seed(100);
    let first: Vec<u64> = (0..3).map(|_| next_sim_frame_seed()).collect();
    reset_sim_frame_seed(100);
    let second: Vec<u64> = (0..3).map(|_| next_sim_frame_seed()).collect();

    assert_eq!(first, second, "a reset seed must replay the same sequence");
    assert_eq!(
        first.len(),
        first.iter().collect::<std::collections::HashSet<_>>().len(),
        "successive frames must not reuse a seed, or a stack is identical frames"
    );
}

/// The four cardinal directions must map to distinct, opposed, axis-aligned
/// displacements. If east and north were parallel the guider's calibration
/// matrix would be singular and it would (correctly) refuse to guide with
/// "mount pulse responses were not distinct".
#[test]
fn pulse_directions_form_an_orthogonal_basis() {
    let east = sim_pulse_delta("east", 250);
    let west = sim_pulse_delta("west", 250);
    let north = sim_pulse_delta("north", 250);
    let south = sim_pulse_delta("south", 250);

    assert!(east.0 > 0.0 && east.1 == 0.0, "east: {east:?}");
    assert_eq!(west, (-east.0, 0.0), "west must oppose east");
    assert!(north.1 > 0.0 && north.0 == 0.0, "north: {north:?}");
    assert_eq!(south, (0.0, -north.1), "south must oppose north");

    let determinant = east.0 * north.1 - east.1 * north.0;
    assert!(
        determinant.abs() > 1e-3,
        "east/north basis is singular (det {determinant}); calibration would be rejected"
    );
}

/// Direction parsing has to accept what the device layer actually passes.
/// `mount_pulse_guide` lowercases before dispatching, and the guider sends
/// full words; a silent no-match would revert this to the old
/// "pulse does nothing" bug rather than failing loudly.
#[test]
fn pulse_accepts_the_directions_the_guider_sends() {
    for direction in ["north", "south", "east", "west", "n", "s", "e", "w"] {
        let (dx, dy) = sim_pulse_delta(direction, 250);
        assert!(
            dx != 0.0 || dy != 0.0,
            "direction {direction:?} produced no movement"
        );
    }
    assert_eq!(sim_pulse_delta("sideways", 250), (0.0, 0.0));
}

/// Travel is proportional to pulse width — that proportionality is what the
/// guider converts into its px/ms guide rate.
#[test]
fn pulse_travel_scales_with_duration() {
    let short = sim_pulse_delta("east", 250).0;
    let long = sim_pulse_delta("east", 1000).0;
    assert!(
        (long - short * 4.0).abs() < 1e-9,
        "{long} should be 4x {short}"
    );
    assert_eq!(sim_pulse_delta("east", 0), (0.0, 0.0));
}

/// The default 250 ms calibration pulse must clear the guider's 0.2 px
/// "response too small" floor with margin, and two of them must stay inside
/// its 20 px star-match radius.
#[test]
fn default_calibration_pulse_lands_in_the_guiders_usable_band() {
    let per_pulse = sim_pulse_delta("east", 250).0;
    assert!(
        per_pulse > 0.2,
        "per-pulse response {per_pulse}px is at or below the 0.2px floor"
    );
    assert!(
        per_pulse * 2.0 < 20.0,
        "two-pulse Dec forward leg {}px exceeds the 20px match radius",
        per_pulse * 2.0
    );
}

/// A simulated exposure must not report complete before its integration
/// time has elapsed. The unconditional "yes" this replaces gave a capture
/// loop nothing to wait on: guiding ran at ~40 fps and pinned nine cores.
#[test]
fn exposure_completes_only_after_its_integration_time() {
    assert!(!sim_exposure_elapsed_is_complete(0.0, 1.0));
    assert!(!sim_exposure_elapsed_is_complete(0.999, 1.0));
    assert!(sim_exposure_elapsed_is_complete(1.0, 1.0));
    assert!(sim_exposure_elapsed_is_complete(2.5, 1.0));
}

/// Degenerate durations must complete rather than wedge the capture loop.
/// A zero-second bias frame is a legitimate request, and a NaN duration is a
/// caller bug that must not hang capture forever.
#[test]
fn degenerate_exposure_durations_complete_immediately() {
    assert!(sim_exposure_elapsed_is_complete(0.0, 0.0));
    assert!(sim_exposure_elapsed_is_complete(0.0, -1.0));
    assert!(sim_exposure_elapsed_is_complete(0.0, f64::NAN));
    assert!(sim_exposure_elapsed_is_complete(0.0, f64::INFINITY));
}

/// Idle reads as complete, a started exposure does not, and abort releases
/// the caller. Anything else strands a polling loop.
#[tokio::test]
async fn exposure_clock_starts_and_clears() {
    let _serialized = sim_singleton_test_lock().lock().await;
    clear_sim_exposure().await;
    assert!(
        sim_exposure_is_complete(SIM_IMAGING_CAMERA_ID).await,
        "an idle simulator must not make a poller wait"
    );

    begin_sim_exposure(SimExposureRequest {
        secs: 30.0,
        ..Default::default()
    })
    .await;
    assert!(
        !sim_exposure_is_complete(SIM_IMAGING_CAMERA_ID).await,
        "a 30s exposure must not be complete the instant it starts"
    );

    clear_sim_exposure().await;
    assert!(
        sim_exposure_is_complete(SIM_IMAGING_CAMERA_ID).await,
        "abort/download must release a caller waiting on the exposure"
    );
}

#[test]
fn offset_is_clamped_to_the_sensor_excursion_limit() {
    let far = apply_offset_delta((0.0, 0.0), 10_000.0, -10_000.0);
    assert_eq!(far, (SIM_MAX_OFFSET_PX, -SIM_MAX_OFFSET_PX));
    // And a clamped offset must still be able to come back.
    let back = apply_offset_delta(far, -5.0, 5.0);
    assert!(back.0 < SIM_MAX_OFFSET_PX && back.1 > -SIM_MAX_OFFSET_PX);
}

#[test]
fn offset_accumulates_across_pulses() {
    let one = apply_offset_delta((0.0, 0.0), 1.5, 0.0);
    let two = apply_offset_delta(one, 1.5, 0.0);
    assert!((two.0 - 3.0).abs() < 1e-9, "two pulses should sum: {two:?}");
    // Reversing returns to the origin: without this, calibration's
    // "restore toward baseline" reverse pulses would never recentre.
    let back = apply_offset_delta(two, -3.0, 0.0);
    assert!(
        back.0.abs() < 1e-9,
        "reverse pulses should cancel: {back:?}"
    );
}

/// A long idle must not slam the field into its clamp on the next capture,
/// and the first read after launch must not drift at all.
#[test]
fn drift_step_is_capped_and_starts_from_a_baseline() {
    assert_eq!(drift_step_secs(None), 0.0);
    assert_eq!(drift_step_secs(Some(0.0)), 0.0);
    assert_eq!(drift_step_secs(Some(-1.0)), 0.0);
    assert_eq!(drift_step_secs(Some(f64::NAN)), 0.0);
    assert_eq!(drift_step_secs(Some(1.5)), 1.5);
    assert_eq!(drift_step_secs(Some(86_400.0)), SIM_MAX_DRIFT_STEP_SECS);
}

/// Drift has to be small enough for a guider to absorb within one cycle,
/// or closed-loop guiding would diverge against the simulator no matter how
/// correct the correction path is.
#[test]
fn drift_is_correctable_within_one_guide_cycle() {
    // A 2s guide exposure plus the default 200ms settle.
    let cycle_secs = 2.2;
    let drift = SIM_DRIFT_PX_PER_SEC_X * cycle_secs;
    let per_pulse = sim_pulse_delta("east", 250).0;
    assert!(
        drift < per_pulse,
        "drift {drift}px per cycle exceeds one calibration pulse of correction \
         ({per_pulse}px); guiding could never catch up"
    );
    assert!(
        drift > 0.0,
        "zero drift leaves the correction sign untested"
    );
}

/// The guide camera is a camera of its own: an exposure on it leaves the
/// imaging camera idle, and its sensor is the small guide sensor.
#[tokio::test]
async fn the_guide_camera_exposes_independently_of_the_imaging_camera() {
    let _serialized = sim_singleton_test_lock().lock().await;
    clear_sim_exposure().await;
    begin_sim_exposure_for(
        SIM_GUIDE_CAMERA_ID,
        SimExposureRequest {
            secs: 30.0,
            ..Default::default()
        },
    )
    .await;
    assert!(!sim_exposure_is_complete(SIM_GUIDE_CAMERA_ID).await);
    assert!(
        sim_exposure_is_complete(SIM_IMAGING_CAMERA_ID).await,
        "a guide frame must not occupy the imaging camera"
    );
    assert!(take_sim_exposure_for_download(SIM_IMAGING_CAMERA_ID)
        .await
        .is_err());
    clear_sim_exposure().await;

    let guide = get_sim_camera_for(SIM_GUIDE_CAMERA_ID)
        .read()
        .await
        .status
        .clone();
    let imaging = get_sim_camera_for(SIM_IMAGING_CAMERA_ID)
        .read()
        .await
        .status
        .clone();
    assert_eq!((guide.sensor_width, guide.sensor_height), (1280, 960));
    assert!(!guide.can_cool);
    assert_eq!(imaging.sensor_width, crate::simulator::frame::SIM_W as u32);
    assert_eq!(sim_camera_fault_prefix(SIM_GUIDE_CAMERA_ID), "guide_camera");
    assert_eq!(sim_camera_fault_prefix(SIM_IMAGING_CAMERA_ID), "camera");
}

/// On the guide scope the mount's offset is rescaled to guide pixels, and
/// seeing moves the whole field a little from frame to frame.
#[test]
fn the_guide_field_follows_the_mount_at_its_own_scale_with_seeing() {
    use crate::simulator::capture::{guide_camera_offset_px, SIM_OFFSET_REFERENCE_ARCSEC_PER_PX};
    let scale = 2.5;
    let draws: Vec<(f64, f64)> = (0..400)
        .map(|seed| guide_camera_offset_px((10.0, -4.0), scale, seed))
        .collect();
    let n = draws.len() as f64;
    let mean_x = draws.iter().map(|d| d.0).sum::<f64>() / n;
    let mean_y = draws.iter().map(|d| d.1).sum::<f64>() / n;
    let factor = SIM_OFFSET_REFERENCE_ARCSEC_PER_PX / scale;
    assert!((mean_x - 10.0 * factor).abs() < 0.05, "{mean_x}");
    assert!((mean_y + 4.0 * factor).abs() < 0.05, "{mean_y}");
    let rms_x = (draws.iter().map(|d| (d.0 - mean_x).powi(2)).sum::<f64>() / n).sqrt();
    let seeing_px = crate::simulator::capture::SIM_GUIDE_SEEING_ARCSEC_RMS / scale;
    assert!(
        rms_x > 0.6 * seeing_px && rms_x < 1.4 * seeing_px,
        "seeing rms {rms_x} vs {seeing_px}"
    );
    assert_eq!(
        guide_camera_offset_px((1.0, 1.0), scale, 7),
        guide_camera_offset_px((1.0, 1.0), scale, 7),
        "a frame seed reproduces its seeing"
    );
}
