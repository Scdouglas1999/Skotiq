//! PHD2 protocol tests against a stateful PHD2 stand-in.
//!
//! The stand-in keeps the parts of PHD2's behavior the rig logs show the
//! guiding paths depend on: `stop_capture` answers at once while the capture
//! ends only when the guide pulse or exposure in flight does; a `guide` or
//! `dither` is refused while an earlier one is still settling; a `loop` sent
//! while a stop is still pending is lost (PHD2 reports a capture error and
//! stops); `find_star` runs on whatever image PHD2 last has; and looping
//! frames carry the selected star's SNR and mass.

use super::super::*;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex as StdMutex;
use std::time::Instant as StdInstant;

#[derive(Clone)]
struct SimConfig {
    /// How long a capture takes to end after `stop_capture`.
    stop_delay: Duration,
    stop_never_finishes: bool,
    /// Time between frames while capturing.
    frame_interval: Duration,
    /// How long a `guide` or `dither` takes to settle.
    settle_delay: Duration,
    /// The settle result a `guide` reports.
    guide_settle_status: i32,
    /// Whether PHD2 goes on guiding after a failed settle (a settle timeout).
    guides_after_failed_settle: bool,
    /// Calibration time before a `guide` starts guiding.
    calibration: Duration,
    /// What `get_exposure` answers; `None` answers an error.
    exposure_ms: Option<u64>,
    /// The star PHD2 measures once one is selected.
    star: (f64, f64),
    /// The capture PHD2 is running when the test starts.
    initial: Capture,
}

impl Default for SimConfig {
    fn default() -> Self {
        Self {
            stop_delay: Duration::from_millis(300),
            stop_never_finishes: false,
            frame_interval: Duration::from_millis(100),
            settle_delay: Duration::from_millis(200),
            guide_settle_status: 0,
            guides_after_failed_settle: false,
            calibration: Duration::ZERO,
            exposure_ms: Some(10),
            star: (230.0, 750_000.0),
            initial: Capture::Stopped,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Capture {
    Stopped,
    Looping,
    Calibrating,
    Guiding,
}

/// The guide star of the field before a move, still in PHD2's last image.
const STALE_STAR: (f64, f64) = (315.5, 1201.9);
/// A star in a frame taken after the selection was asked for.
const FRESH_STAR: (f64, f64) = (12.5, 34.0);

struct SimState {
    capture: Capture,
    stop_pending: bool,
    /// A guide or dither is settling.
    settling: bool,
    /// Frames exposed since the latest `loop`.
    fresh_frames: u64,
    frame: u64,
    star_selected: bool,
    methods: Vec<String>,
    /// `find_star` answered from an image taken before the latest `loop`.
    stale_selections: u32,
    refused_guides: u32,
}

struct Sim {
    config: SimConfig,
    state: StdMutex<SimState>,
    writer: StdMutex<TcpStream>,
}

impl Sim {
    fn send(&self, value: serde_json::Value) {
        let mut writer = self.writer.lock().unwrap();
        let _ = writeln!(writer, "{value}");
        let _ = writer.flush();
    }

    fn event(&self, name: &str, fields: serde_json::Value) {
        let mut event = serde_json::json!({ "Event": name });
        if let (Some(event), Some(fields)) = (event.as_object_mut(), fields.as_object()) {
            event.extend(fields.clone());
        }
        self.send(event);
    }

    /// One frame of whatever capture is running.
    fn tick(&self) {
        let mut state = self.state.lock().unwrap();
        if state.stop_pending {
            return;
        }
        let (snr, mass) = self.config.star;
        match state.capture {
            Capture::Looping => {
                state.frame += 1;
                state.fresh_frames += 1;
                let mut fields = serde_json::json!({ "Frame": state.frame });
                if state.star_selected {
                    fields["SNR"] = serde_json::json!(snr);
                    fields["StarMass"] = serde_json::json!(mass);
                }
                drop(state);
                self.event("LoopingExposures", fields);
            }
            Capture::Guiding => {
                state.frame += 1;
                let frame = state.frame;
                drop(state);
                self.event(
                    "GuideStep",
                    serde_json::json!({
                        "Frame": frame, "RADistanceRaw": 0.3, "DECDistanceRaw": 0.2,
                        "SNR": snr, "StarMass": mass,
                    }),
                );
            }
            Capture::Stopped | Capture::Calibrating => {}
        }
    }

    fn end_capture(self: &Arc<Self>) {
        if self.config.stop_never_finishes {
            return;
        }
        let sim = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(sim.config.stop_delay);
            let was_settling = {
                let mut state = sim.state.lock().unwrap();
                state.stop_pending = false;
                state.capture = Capture::Stopped;
                state.star_selected = false;
                std::mem::take(&mut state.settling)
            };
            if was_settling {
                sim.event(
                    "SettleDone",
                    serde_json::json!({"Status": 1, "Error": "Guiding stopped"}),
                );
            }
        });
    }

    fn settle(self: &Arc<Self>, status: i32, guiding: bool) {
        let sim = self.clone();
        std::thread::spawn(move || {
            if guiding && !sim.config.calibration.is_zero() {
                sim.event("StartCalibration", serde_json::json!({}));
                std::thread::sleep(sim.config.calibration);
                sim.event("CalibrationComplete", serde_json::json!({}));
                let mut state = sim.state.lock().unwrap();
                if state.capture == Capture::Calibrating {
                    state.capture = Capture::Guiding;
                }
            }
            if guiding {
                sim.event("StartGuiding", serde_json::json!({}));
            }
            std::thread::sleep(sim.config.settle_delay);
            let mut state = sim.state.lock().unwrap();
            if !state.settling {
                return;
            }
            state.settling = false;
            if status != 0 && guiding && !sim.config.guides_after_failed_settle {
                state.capture = Capture::Stopped;
            }
            drop(state);
            sim.event(
                "SettleDone",
                serde_json::json!({"Status": status, "Error": if status == 0 { "" } else { "timed-out waiting for guider to settle" }}),
            );
        });
    }

    fn answer(self: &Arc<Self>, method: &str) -> Result<serde_json::Value, &'static str> {
        let mut state = self.state.lock().unwrap();
        state.methods.push(method.to_string());
        match method {
            "get_app_state" => Ok(serde_json::json!(match state.capture {
                Capture::Stopped => "Stopped",
                Capture::Looping if state.star_selected => "Selected",
                Capture::Looping => "Looping",
                Capture::Calibrating => "Calibrating",
                Capture::Guiding => "Guiding",
            })),
            "get_exposure" => self
                .config
                .exposure_ms
                .map(|ms| serde_json::json!(ms))
                .ok_or("camera busy"),
            "stop_capture" => {
                if state.capture != Capture::Stopped && !state.stop_pending {
                    state.stop_pending = true;
                    drop(state);
                    self.end_capture();
                }
                Ok(serde_json::json!(0))
            }
            "loop" => {
                // A loop asked for while the stop is still pending is lost.
                if !state.stop_pending {
                    state.capture = Capture::Looping;
                    state.fresh_frames = 0;
                    state.star_selected = false;
                }
                Ok(serde_json::json!(0))
            }
            "find_star" => {
                if state.fresh_frames > 0 && state.capture == Capture::Looping {
                    state.star_selected = true;
                    Ok(serde_json::json!([FRESH_STAR.0, FRESH_STAR.1]))
                } else if state.frame > 0 {
                    state.stale_selections += 1;
                    Ok(serde_json::json!([STALE_STAR.0, STALE_STAR.1]))
                } else {
                    Err("no star found")
                }
            }
            "guide" | "dither" => {
                if state.settling {
                    state.refused_guides += 1;
                    return Err("Cannot initiate guide while guide is in progress");
                }
                state.settling = true;
                let guiding = method == "guide";
                if guiding {
                    state.capture = if self.config.calibration.is_zero() {
                        Capture::Guiding
                    } else {
                        Capture::Calibrating
                    };
                }
                let status = if guiding {
                    self.config.guide_settle_status
                } else {
                    0
                };
                drop(state);
                self.settle(status, guiding);
                Ok(serde_json::json!(0))
            }
            _ => Ok(serde_json::json!(0)),
        }
    }
}

async fn connect(config: SimConfig) -> (Arc<Sim>, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = std::sync::mpsc::channel();
    let done = Arc::new(AtomicBool::new(false));
    let thread_done = done.clone();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let initial = config.initial;
        let sim = Arc::new(Sim {
            config,
            state: StdMutex::new(SimState {
                capture: initial,
                stop_pending: false,
                settling: false,
                fresh_frames: 0,
                frame: 0,
                star_selected: initial != Capture::Stopped,
                methods: Vec::new(),
                stale_selections: 0,
                refused_guides: 0,
            }),
            writer: StdMutex::new(stream),
        });
        tx.send(sim.clone()).unwrap();
        let ticker = sim.clone();
        let ticker_done = thread_done.clone();
        std::thread::spawn(move || {
            while !ticker_done.load(Ordering::SeqCst) {
                std::thread::sleep(ticker.config.frame_interval);
                ticker.tick();
            }
        });
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let Ok(request) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            let method = request["method"].as_str().unwrap_or_default().to_string();
            let response = match sim.answer(&method) {
                Ok(result) => {
                    serde_json::json!({"jsonrpc": "2.0", "result": result, "id": request["id"]})
                }
                Err(message) => serde_json::json!({
                    "jsonrpc": "2.0", "error": {"code": 1, "message": message}, "id": request["id"],
                }),
            };
            sim.send(response);
        }
        thread_done.store(true, Ordering::SeqCst);
    });
    api_phd2_connect(Some("127.0.0.1".into()), Some(port))
        .await
        .expect("the PHD2 stand-in accepts the connect");
    let sim = rx.recv().unwrap();
    sim.state.lock().unwrap().methods.clear();
    (sim, done)
}

/// Disconnect and stop the stand-in's frame clock.
async fn finish(done: Arc<AtomicBool>) {
    let _ = api_phd2_disconnect().await;
    done.store(true, Ordering::SeqCst);
}

fn snapshot(sim: &Sim) -> (Vec<String>, u32, u32) {
    let state = sim.state.lock().unwrap();
    (
        state.methods.clone(),
        state.stale_selections,
        state.refused_guides,
    )
}

/// The rig on 2026-10-24 at 04:12:14 local: a re-acquisition found PHD2
/// still guiding, inside a 2.5 s Dec pulse. stop_capture was answered at
/// once, the loop that followed 2 ms later was lost when the capture ended,
/// find_star ran on the guiding frame from before, and the `guide` 2 ms
/// after it was refused because the earlier guide was still settling. A
/// restart must wait for the capture to end before it loops, and pick its
/// star from a frame taken after that.
#[tokio::test]
async fn a_restart_while_phd2_is_inside_a_guide_pulse_waits_for_the_capture_to_end() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (sim, done) = connect(SimConfig {
        stop_delay: Duration::from_millis(500),
        settle_delay: Duration::from_secs(30),
        ..SimConfig::default()
    })
    .await;
    // The earlier guide is still settling when its waiter is abandoned, as a
    // recovery attempt does when its own deadline passes.
    let started = tokio::time::timeout(
        Duration::from_millis(400),
        api_phd2_start_guiding(2.0, 10.0, 120.0),
    )
    .await;
    assert!(started.is_err(), "the first guide must still be settling");

    let selected = select_fresh_guide_star(PHD2_DEVICE_ID, None).await;
    let restarted = api_phd2_start_guiding(2.0, 0.1, 1.0).await;

    let (methods, stale, refused) = snapshot(&sim);
    finish(done).await;
    assert_eq!(selected.ok(), Some(FRESH_STAR), "{methods:?}");
    assert_eq!(
        stale, 0,
        "find_star ran on an image from before: {methods:?}"
    );
    assert_eq!(refused, 0, "PHD2 refused a guide: {methods:?}");
    assert!(restarted.is_ok(), "{restarted:?} {methods:?}");
}

/// PHD2 was looping (a recovery's earlier attempt) when the selection began.
/// The exposure in flight at stop_capture still lands as a looping frame and
/// must not count as a frame taken after the selection was asked for.
#[tokio::test]
async fn a_frame_already_exposing_when_capture_stops_is_not_fresh() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (sim, done) = connect(SimConfig {
        initial: Capture::Looping,
        stop_delay: Duration::from_millis(250),
        frame_interval: Duration::from_millis(100),
        ..SimConfig::default()
    })
    .await;
    // Let the looping capture produce an image to be stale.
    tokio::time::sleep(Duration::from_millis(250)).await;
    let selected = select_fresh_guide_star(PHD2_DEVICE_ID, None).await;
    let (methods, stale, _) = snapshot(&sim);
    finish(done).await;
    assert_eq!(selected.ok(), Some(FRESH_STAR), "{methods:?}");
    assert_eq!(stale, 0, "{methods:?}");
}

/// A PHD2 slow to answer get_exposure (busy with a capture under cloud) is
/// not a reason to give up on the selection.
#[tokio::test]
async fn an_unanswered_exposure_query_falls_back_to_a_default_exposure() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (_sim, done) = connect(SimConfig {
        exposure_ms: None,
        ..SimConfig::default()
    })
    .await;
    let selected = select_fresh_guide_star(PHD2_DEVICE_ID, None).await;
    finish(done).await;
    assert_eq!(selected.ok(), Some(FRESH_STAR));
}

/// Behind the trees at 03:33 the run's guide star measured SNR ~230 and mass
/// ~750,000; the stars recovery locked on measured SNR 41-98 and mass
/// 15,000-30,000 at HFD ~2 px. A star that far below the run's guide star
/// is refused, and the selection fails rather than guide on it.
#[tokio::test]
async fn a_star_far_fainter_than_the_runs_guide_star_is_refused() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (sim, done) = connect(SimConfig {
        star: (77.3, 29_612.0),
        ..SimConfig::default()
    })
    .await;
    let floor =
        skotiq_sequencer::GuideStarFloor::for_recovery(Some(skotiq_sequencer::GuideStarQuality {
            snr: 230.0,
            star_mass: 750_000.0,
        }));
    let selected = select_fresh_guide_star(PHD2_DEVICE_ID, Some(floor)).await;
    let (methods, _, _) = snapshot(&sim);
    finish(done).await;
    let error = selected
        .expect_err("a noise source must be refused")
        .to_string();
    assert!(error.contains("below the floor"), "{error}");
    assert_eq!(
        methods.iter().filter(|m| *m == "find_star").count(),
        FRESH_STAR_ATTEMPTS as usize,
        "it looks again in the next frames: {methods:?}"
    );
    assert!(!methods.iter().any(|m| m == "guide"), "{methods:?}");
}

#[tokio::test]
async fn a_star_like_the_runs_guide_star_is_accepted() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (_sim, done) = connect(SimConfig::default()).await;
    let floor =
        skotiq_sequencer::GuideStarFloor::for_recovery(Some(skotiq_sequencer::GuideStarQuality {
            snr: 238.5,
            star_mass: 741_004.0,
        }));
    let selected = select_fresh_guide_star(PHD2_DEVICE_ID, Some(floor)).await;
    finish(done).await;
    assert_eq!(selected.ok(), Some(FRESH_STAR));
}

/// A settle that runs out while PHD2 still guides is a star held but not
/// yet inside the bound. Stopping PHD2 there left the night unguided.
#[tokio::test]
async fn a_settle_timeout_leaves_a_guiding_phd2_guiding() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (sim, done) = connect(SimConfig {
        guide_settle_status: 1,
        guides_after_failed_settle: true,
        ..SimConfig::default()
    })
    .await;
    let started = api_phd2_start_guiding(2.0, 0.1, 1.0).await;
    let (methods, _, _) = snapshot(&sim);
    finish(done).await;
    assert!(started.is_ok(), "{started:?}");
    let guide = methods.iter().position(|m| m == "guide").unwrap();
    assert!(
        !methods[guide..].iter().any(|m| m == "stop_capture"),
        "a guiding PHD2 was stopped: {methods:?}"
    );
}

/// PHD2 starts its settle clock after calibration, so a start must not give
/// up while PHD2 is still calibrating.
#[tokio::test]
async fn a_start_waits_for_calibration_before_its_settle() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let settle_wait = skotiq_imaging::Phd2Client::settle_wait_duration(0.1, 1.0);
    let (_sim, done) = connect(SimConfig {
        calibration: settle_wait + Duration::from_secs(1),
        ..SimConfig::default()
    })
    .await;
    let started = api_phd2_start_guiding(2.0, 0.1, 1.0).await;
    finish(done).await;
    assert!(started.is_ok(), "{started:?}");
}

/// A stop ends a start that is waiting for its settle at once.
#[tokio::test]
async fn a_stop_ends_a_settle_wait_at_once() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (_sim, done) = connect(SimConfig {
        settle_delay: Duration::from_secs(60),
        ..SimConfig::default()
    })
    .await;
    let began = StdInstant::now();
    let (started, stopped) = tokio::join!(api_phd2_start_guiding(2.0, 10.0, 120.0), async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        api_phd2_stop_guiding().await
    });
    let elapsed = began.elapsed();
    finish(done).await;
    assert!(stopped.is_ok(), "{stopped:?}");
    assert!(started.is_err(), "a stopped start is not a started guider");
    assert!(elapsed < Duration::from_secs(5), "took {elapsed:?}");
}

/// A dither asked for while a restart is settling waits its turn instead of
/// being refused by PHD2, and the restart is not broken by it.
#[tokio::test]
async fn a_dither_during_a_restart_waits_for_its_settle() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (sim, done) = connect(SimConfig {
        settle_delay: Duration::from_millis(500),
        ..SimConfig::default()
    })
    .await;
    let (restarted, dithered) = tokio::join!(
        async {
            select_fresh_guide_star(PHD2_DEVICE_ID, None).await?;
            api_phd2_start_guiding(2.0, 0.1, 5.0).await
        },
        async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            api_phd2_dither(3.0, 0, 2.0, 0.1, 5.0).await
        }
    );
    let (methods, _, refused) = snapshot(&sim);
    finish(done).await;
    assert!(restarted.is_ok(), "{restarted:?} {methods:?}");
    assert!(dithered.is_ok(), "{dithered:?} {methods:?}");
    assert_eq!(refused, 0, "{methods:?}");
}

/// An acknowledgement is not proof that capture stopped. The flip must not
/// advance to moving the mount when PHD2 is still issuing guide pulses.
#[tokio::test]
async fn an_acknowledged_stop_that_never_finishes_is_an_error() {
    let _slot = PHD2_TEST_SLOT.lock().await;
    let (_sim, done) = connect(SimConfig {
        initial: Capture::Guiding,
        stop_never_finishes: true,
        ..SimConfig::default()
    })
    .await;
    let result = api_phd2_stop_guiding().await;
    finish(done).await;
    assert!(
        result.is_err(),
        "a still-guiding PHD2 must not report a successful stop"
    );
}
