//! What a trigger-fired autofocus does to the run when it fails, driven
//! through a whole executor.
//!
//! These live in their own test binary because a trigger-fired autofocus takes
//! the process-wide autofocus admission gate, and the library's unit tests
//! assert on that gate from other threads. A separate process keeps both
//! honest; the tests in this file serialize among themselves.

use async_trait::async_trait;
use nightshade_sequencer::{
    AutofocusConfig, DelayConfig, DeviceOps, DeviceResult, ExecutorEvent, ExecutorState,
    GuidingStatus, ImageData, NodeDefinition, NodeType, NullDeviceOps, PlateSolveResult,
    SequenceDefinition, SequenceExecutor, TriggerState,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// One autofocus at a time in this binary: they share the admission gate.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A rig whose guider loses its lock when stopped and never gets it back, the
/// state the 2026-09-14 run was in after its autofocus. Records the calls that
/// matter; everything else answers as `NullDeviceOps` does.
struct DeadGuiderRig {
    inner: NullDeviceOps,
    calls: Mutex<Vec<String>>,
    guiding: AtomicBool,
}

impl DeadGuiderRig {
    fn new() -> Self {
        Self {
            inner: NullDeviceOps,
            calls: Mutex::new(Vec::new()),
            guiding: AtomicBool::new(true),
        }
    }

    fn record(&self, call: impl Into<String>) {
        self.calls.lock().unwrap().push(call.into());
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl DeviceOps for DeadGuiderRig {
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let guiding = self.guiding.load(Ordering::SeqCst);
        self.record(format!("guider_get_status->{guiding}"));
        Ok(GuidingStatus {
            is_guiding: guiding,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }
    async fn guider_start(&self, _sp: f64, _st: f64, _sto: f64) -> DeviceResult<()> {
        self.record("guider_start");
        Ok(())
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.record("guider_stop");
        self.guiding.store(false, Ordering::SeqCst);
        Ok(())
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("mount_park:{id}"));
        Ok(())
    }
    async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("cover_close:{id}"));
        Ok(())
    }
    async fn dome_close(&self, id: &str) -> DeviceResult<()> {
        self.record(format!("dome_close:{id}"));
        Ok(())
    }
    async fn camera_start_exposure(
        &self,
        id: &str,
        d: f64,
        g: Option<i32>,
        o: Option<i32>,
        bx: i32,
        by: i32,
    ) -> DeviceResult<ImageData> {
        self.record(format!("camera_start_exposure:{id}"));
        self.inner.camera_start_exposure(id, d, g, o, bx, by).await
    }

    // Everything below answers as `NullDeviceOps`.

    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(id).await
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(id).await
    }
    async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(id).await
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(
        &self,
        id: &str,
    ) -> DeviceResult<nightshade_sequencer::meridian::PierSide> {
        self.inner.mount_side_of_pier(id).await
    }
    async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(id).await
    }
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(id, enabled).await
    }
    async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(id).await
    }
    async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.inner.camera_set_cooler(id, e, t).await
    }
    async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(id).await
    }
    async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(id).await
    }
    async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(id, p).await
    }
    async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.focuser_get_position(id).await
    }
    async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(id).await
    }
    async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(id).await
    }
    async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(id).await
    }
    async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(id, p).await
    }
    async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(id).await
    }
    async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(id).await
    }
    async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(id, n).await
    }
    async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(id, a).await
    }
    async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(id, d).await
    }
    async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(id).await
    }
    async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(id).await
    }
    async fn guider_dither(
        &self,
        p: f64,
        sp: f64,
        st: f64,
        sto: f64,
        ra: bool,
    ) -> DeviceResult<()> {
        self.inner.guider_dither(p, sp, st, sto, ra).await
    }
    async fn plate_solve(
        &self,
        d: &ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.inner.plate_solve(d, ra, dec, s).await
    }
    async fn save_fits(
        &self,
        d: &ImageData,
        f: &str,
        ctx: &nightshade_sequencer::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(d, f, ctx).await
    }
    async fn send_notification(
        &self,
        l: &str,
        t: &str,
        m: &str,
        x: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner.send_notification(l, t, m, x).await
    }
    fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
        self.inner.calculate_altitude(r, d, la, lo)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        r: &nightshade_sequencer::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_open(id).await
    }
    async fn dome_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_park(id).await
    }
    async fn dome_get_shutter_status(&self, id: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(id).await
    }
    async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(id).await
    }
    async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(d).await
    }
    async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(d).await
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(id).await
    }
    async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_on(id, b).await
    }
    async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(id).await
    }
    async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(id).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_calibrator_state(id).await
    }
    async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(id).await
    }
    async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_max_brightness(id).await
    }
}

/// What the run looked like once the arm had acted on the sweep's verdict.
struct Outcome {
    state: ExecutorState,
    calls: Vec<String>,
    messages: Vec<String>,
}

/// Start a long run on `rig` with the shipped autofocus failure policy, wait
/// for the monitor to see the guider guiding, apply `seed` to force a
/// trigger-fired autofocus, and report what the run did once it was judged.
async fn run_trigger_autofocus(
    rig: Arc<DeadGuiderRig>,
    seed: impl FnOnce(&mut TriggerState) + Send + 'static,
) -> Outcome {
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(rig.clone());
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        Some("focuser-1".to_string()),
        None,
        None,
    );
    // Library defaults except what keeps the test short. Guiding is stopped
    // for the sweep (the owner's setting); the failure action and the HFR
    // tolerance stay at their shipped defaults.
    executor
        .update_autofocus_config(AutofocusConfig {
            disable_guiding_during_af: true,
            number_of_attempts: 1,
            steps_out: 2,
            exposure_duration: 0.01,
            focuser_settle_time_ms: 0,
            ..AutofocusConfig::default()
        })
        .await;
    let mut sequence = SequenceDefinition::new("Trigger autofocus".to_string());
    sequence.nodes.push(NodeDefinition {
        id: "wait".to_string(),
        name: "Long wait".to_string(),
        node_type: NodeType::Delay(DelayConfig { seconds: 600.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("wait".to_string());
    executor.load_sequence(sequence).expect("sequence loads");
    let mut events = executor.subscribe();
    executor.start().await.expect("run starts");

    // The sweep only stops a guider the run has seen guiding.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while rig
        .calls()
        .iter()
        .filter(|c| c.starts_with("guider_get_status"))
        .count()
        < 2
    {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    executor.update_trigger_state(seed).await;

    let messages = Arc::new(Mutex::new(Vec::new()));
    let judged = Arc::new(AtomicBool::new(false));
    let listener = {
        let messages = messages.clone();
        let judged = judged.clone();
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(ExecutorEvent::NodeCompleted { id, .. })
                        if id.starts_with("trigger:") && id.ends_with(":autofocus") =>
                    {
                        judged.store(true, Ordering::SeqCst);
                    }
                    Ok(ExecutorEvent::Error { message }) => {
                        messages.lock().unwrap().push(message);
                    }
                    Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(_) => break,
                }
            }
        })
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while !judged.load(Ordering::SeqCst) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the trigger autofocus never finished; calls={:?}",
            rig.calls()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Let the arm act on the verdict.
    tokio::time::sleep(Duration::from_secs(3)).await;
    let state = executor.get_state().await;
    let calls = rig.calls();
    let _ = executor.stop().await;
    listener.abort();
    let messages = messages.lock().unwrap().clone();
    Outcome {
        state,
        calls,
        messages,
    }
}

/// A trigger autofocus that cannot restart the guider must hold the run, even
/// when focus itself is still acceptable. Every further frame would be
/// unguided; that is what trailed three 180 s lights on 2026-09-14.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dead_guider_after_trigger_autofocus_holds_the_run_even_when_focus_is_fine() {
    let _serial = SERIAL.lock().await;
    let rig = Arc::new(DeadGuiderRig::new());
    let outcome = run_trigger_autofocus(rig, |ts| {
        // Force the HFR trigger, then give it the reference an HFR-degraded
        // firing has: frames 1.2x soft, well inside the 1.6x keep-imaging
        // tolerance. (Invalidation clears the baseline, so it goes first.)
        ts.invalidate_autofocus("test: force a refocus");
        ts.baseline_hfr = Some(2.0);
        ts.current_hfr = Some(2.4);
    })
    .await;
    let Outcome {
        state,
        calls,
        messages,
    } = outcome;
    assert!(
        calls.iter().any(|c| c == "guider_stop"),
        "the sweep never stopped the guider, so this test proves nothing; messages={messages:?} \
         calls={calls:?}"
    );
    assert_eq!(
        state,
        ExecutorState::Paused,
        "the run kept imaging unguided; messages={messages:?} calls={calls:?}"
    );
}

/// The same failure with no HFR reference must hold, not park: a dead guider
/// says nothing about who is at the telescope, and the owner forbids parking
/// he did not ask for.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dead_guider_after_trigger_autofocus_never_parks() {
    let _serial = SERIAL.lock().await;
    let rig = Arc::new(DeadGuiderRig::new());
    let outcome = run_trigger_autofocus(rig, |ts| {
        ts.invalidate_autofocus("test: force a refocus");
    })
    .await;
    let Outcome {
        state,
        calls,
        messages,
    } = outcome;
    assert!(
        calls.iter().any(|c| c == "guider_stop"),
        "the sweep never stopped the guider, so this test proves nothing; messages={messages:?} \
         calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_park")
            || c.starts_with("cover_close")
            || c.starts_with("dome_close")),
        "a dead guider parked the rig; messages={messages:?} calls={calls:?}"
    );
    assert_eq!(
        state,
        ExecutorState::Paused,
        "messages={messages:?} calls={calls:?}"
    );
}
