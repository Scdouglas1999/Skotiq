//! How each place that waits for a slew to end answers the same mount: the
//! outcome, when it came, how many slewing reads it took and whether the slew
//! was aborted.

use super::*;
use crate::meridian_flip_executor::{FLIP_CENTERING_SLEW, FLIP_SLEW};
use crate::slew_arrival::{SlewArrivalTimings, SlewSample};

const FROM: (f64, f64) = (0.0, 0.0);
const TO: (f64, f64) = (6.0, 60.0);

/// A mount scripted against the paused clock: whether it reports slewing
/// (`None` is a failed read) and where it points.
type Script = fn(Duration) -> (Option<bool>, (f64, f64));

struct TimedMount {
    inner: Arc<NullDeviceOps>,
    started: tokio::time::Instant,
    script: Script,
    reads: AtomicU32,
    aborts: AtomicU32,
}

#[async_trait]
impl MountOps for TimedMount {
    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, _id: &str) -> DeviceResult<()> {
        self.aborts.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn mount_get_coordinates(&self, _id: &str) -> DeviceResult<(f64, f64)> {
        Ok((self.script)(self.started.elapsed()).1)
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_park(id).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, _id: &str) -> DeviceResult<bool> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        (self.script)(self.started.elapsed())
            .0
            .ok_or_else(|| "scripted read failure".to_string().into())
    }
    async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(id).await
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(id).await
    }
    async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(id).await
    }
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(id, enabled).await
    }
}

crate::forward_device_ops!(TimedMount => inner: CameraOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

fn toward(to: (f64, f64), f: f64) -> (f64, f64) {
    (FROM.0 + (to.0 - FROM.0) * f, FROM.1 + (to.1 - FROM.1) * f)
}

/// Idle for 1.5 s after the command, then slewing for 20 s, then idle on the
/// target.
fn lagging(t: Duration) -> (Option<bool>, (f64, f64)) {
    let lag = Duration::from_millis(1500);
    if t < lag {
        return (Some(false), FROM);
    }
    let f = ((t - lag).as_secs_f64() / 20.0).min(1.0);
    (Some(f < 1.0), toward(TO, f))
}

/// Reports moving at once, slews for 10 s, then idle on the target.
fn prompt(t: Duration) -> (Option<bool>, (f64, f64)) {
    let f = (t.as_secs_f64() / 10.0).min(1.0);
    (Some(f < 1.0), toward(TO, f))
}

fn never_moves(_: Duration) -> (Option<bool>, (f64, f64)) {
    (Some(false), FROM)
}

fn already_there(_: Duration) -> (Option<bool>, (f64, f64)) {
    (Some(false), TO)
}

/// [`prompt`], with every read failing between 3 and 6 s.
fn reads_fail_for_a_while(t: Duration) -> (Option<bool>, (f64, f64)) {
    if t >= Duration::from_secs(3) && t < Duration::from_secs(6) {
        return (None, prompt(t).1);
    }
    prompt(t)
}

fn every_read_fails(t: Duration) -> (Option<bool>, (f64, f64)) {
    (None, prompt(t).1)
}

fn never_stops(_: Duration) -> (Option<bool>, (f64, f64)) {
    (Some(true), FROM)
}

#[derive(Clone, Copy, Debug)]
enum Site {
    FlipSlew,
    FlipCentering,
    CenterCorrection,
    CenterInProgress,
    SlewInstruction,
    Wizard,
    BridgeWatch,
}

/// The bridge's background slew-completed watch: a 1 s poll, ten failed
/// reads in a row end it, nothing cancels or aborts it.
const BRIDGE_WATCH: SlewArrivalTimings = SlewArrivalTimings {
    poll_interval: Duration::from_secs(1),
    max_consecutive_failures: 10,
    ..SlewArrivalTimings::goto(Duration::from_secs(300))
};

async fn run(site: Site, script: Script, stop_at: Option<Duration>) -> String {
    let mount = Arc::new(TimedMount {
        inner: Arc::new(NullDeviceOps),
        started: tokio::time::Instant::now(),
        script,
        reads: AtomicU32::new(0),
        aborts: AtomicU32::new(0),
    });
    let mut ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    ec.run.device_ops = mount.clone();
    let ctx = ec.to_instruction_context("test-node").await;
    if let Some(at) = stop_at {
        let token = ctx.cancellation_token.clone();
        tokio::spawn(async move {
            tokio::time::sleep(at).await;
            token.store(true, Ordering::SeqCst);
        });
    }
    let ops: SharedDeviceOps = mount.clone();
    let cancelled = || ctx.cancellation_token.load(Ordering::SeqCst);
    let started = tokio::time::Instant::now();
    let outcome = match site {
        Site::FlipSlew | Site::FlipCentering => {
            let bounds = match site {
                Site::FlipSlew => FLIP_SLEW,
                _ => FLIP_CENTERING_SLEW,
            };
            match wait_for_slew(&ops, "mount-1", bounds, &|| cancelled().then_some(())).await {
                SlewWait::Done => "done".to_string(),
                SlewWait::Stopped { phase, abort, .. } => {
                    format!("stopped {phase:?} abort {}", abort.is_ok())
                }
                SlewWait::NeverStarted { abort } => {
                    format!("never started abort {}", abort.is_ok())
                }
                SlewWait::Overran { abort } => format!("overran abort {}", abort.is_ok()),
                SlewWait::ReadFailed(error) => format!("read failed: {error}"),
            }
        }
        Site::CenterCorrection | Site::CenterInProgress => {
            let result = match site {
                Site::CenterCorrection => wait_for_centering_correction_slew("mount-1", &ctx).await,
                _ => wait_until_mount_stops("mount-1", &ctx).await,
            };
            match result {
                Ok(()) => "done".to_string(),
                Err(result) => format!("{:?}: {:?}", result.status, result.message),
            }
        }
        Site::SlewInstruction => {
            match crate::instructions::wait::wait_for_mount_arrival(
                "mount-1",
                &ctx,
                Some(TO),
                Duration::from_secs(300),
                None,
            )
            .await
            {
                Ok(progress) => format!("arrived near {}", progress.near_target),
                Err(error) => format!("{error}"),
            }
        }
        Site::Wizard => {
            match crate::wizard::wait_for_slew_complete(&ctx, "mount-1", 300, "Slew").await {
                Ok(()) => "done".to_string(),
                Err(error) => error,
            }
        }
        Site::BridgeWatch => {
            match crate::slew_arrival::wait_for_slew_arrival(
                Some(TO),
                &BRIDGE_WATCH,
                || {
                    let ops = ops.clone();
                    async move {
                        match ops.mount_is_slewing("mount-1").await {
                            Ok(slewing) => SlewSample {
                                slewing: Some(slewing),
                                position: ops.mount_get_coordinates("mount-1").await.ok(),
                            },
                            Err(_) => SlewSample {
                                slewing: None,
                                position: None,
                            },
                        }
                    }
                },
                || false,
                |_| {},
            )
            .await
            {
                Ok(progress) => format!("arrived near {}", progress.near_target),
                Err(error) => format!("{error}"),
            }
        }
    };
    format!(
        "{outcome} | {} ms | {} reads | {} aborts",
        started.elapsed().as_millis(),
        mount.reads.load(Ordering::SeqCst),
        mount.aborts.load(Ordering::SeqCst)
    )
}

const SITES: [Site; 7] = [
    Site::FlipSlew,
    Site::FlipCentering,
    Site::CenterCorrection,
    Site::CenterInProgress,
    Site::SlewInstruction,
    Site::Wizard,
    Site::BridgeWatch,
];

const SCRIPTS: [(&str, Script, Option<Duration>); 8] = [
    ("lagging flag", lagging, None),
    ("reports moving at once", prompt, None),
    ("never moves", never_moves, None),
    ("already on target", already_there, None),
    ("reads fail for 3 s", reads_fail_for_a_while, None),
    ("every read fails", every_read_fails, None),
    ("stopped at 5 s", lagging, Some(Duration::from_secs(5))),
    ("never stops", never_stops, None),
];

const EXPECTED: &[&str] = &[
    "FlipSlew / lagging flag: done | 21600 ms | 50 reads | 0 aborts",
    "FlipCentering / lagging flag: done | 21500 ms | 45 reads | 0 aborts",
    "CenterCorrection / lagging flag: done | 21500 ms | 45 reads | 0 aborts",
    "CenterInProgress / lagging flag: done | 0 ms | 1 reads | 0 aborts",
    "SlewInstruction / lagging flag: arrived near true | 22000 ms | 45 reads | 0 aborts",
    "Wizard / lagging flag: done | 23000 ms | 24 reads | 0 aborts",
    "BridgeWatch / lagging flag: arrived near true | 23000 ms | 24 reads | 0 aborts",
    "FlipSlew / reports moving at once: done | 10000 ms | 22 reads | 0 aborts",
    "FlipCentering / reports moving at once: done | 10000 ms | 22 reads | 0 aborts",
    "CenterCorrection / reports moving at once: done | 10000 ms | 22 reads | 0 aborts",
    "CenterInProgress / reports moving at once: done | 10000 ms | 21 reads | 0 aborts",
    "SlewInstruction / reports moving at once: arrived near true | 10500 ms | 22 reads | 0 aborts",
    "Wizard / reports moving at once: done | 11000 ms | 12 reads | 0 aborts",
    "BridgeWatch / reports moving at once: arrived near true | 11000 ms | 12 reads | 0 aborts",
    "FlipSlew / never moves: done | 15200 ms | 78 reads | 0 aborts",
    "FlipCentering / never moves: never started abort true | 5500 ms | 12 reads | 1 aborts",
    "CenterCorrection / never moves: Failure: Some(\"Centering correction slew did not report startup within 5s\") | 5000 ms | 11 reads | 1 aborts",
    "CenterInProgress / never moves: done | 0 ms | 1 reads | 0 aborts",
    "SlewInstruction / never moves: The mount's driver accepted the slew but the mount didn't move | 15000 ms | 31 reads | 0 aborts",
    "Wizard / never moves: done | 2000 ms | 3 reads | 0 aborts",
    "BridgeWatch / never moves: The mount's driver accepted the slew but the mount didn't move | 15000 ms | 16 reads | 0 aborts",
    "FlipSlew / already on target: done | 15200 ms | 78 reads | 0 aborts",
    "FlipCentering / already on target: never started abort true | 5500 ms | 12 reads | 1 aborts",
    "CenterCorrection / already on target: Failure: Some(\"Centering correction slew did not report startup within 5s\") | 5000 ms | 11 reads | 1 aborts",
    "CenterInProgress / already on target: done | 0 ms | 1 reads | 0 aborts",
    "SlewInstruction / already on target: arrived near true | 2000 ms | 5 reads | 0 aborts",
    "Wizard / already on target: done | 2000 ms | 3 reads | 0 aborts",
    "BridgeWatch / already on target: arrived near true | 2000 ms | 3 reads | 0 aborts",
    "FlipSlew / reads fail for 3 s: read failed: scripted read failure | 3000 ms | 8 reads | 0 aborts",
    "FlipCentering / reads fail for 3 s: read failed: scripted read failure | 3000 ms | 8 reads | 0 aborts",
    "CenterCorrection / reads fail for 3 s: done | 10000 ms | 22 reads | 0 aborts",
    "CenterInProgress / reads fail for 3 s: done | 10000 ms | 21 reads | 0 aborts",
    "SlewInstruction / reads fail for 3 s: arrived near true | 10500 ms | 22 reads | 0 aborts",
    "Wizard / reads fail for 3 s: done | 4000 ms | 5 reads | 0 aborts",
    "BridgeWatch / reads fail for 3 s: arrived near true | 11000 ms | 12 reads | 0 aborts",
    "FlipSlew / every read fails: read failed: scripted read failure | 0 ms | 1 reads | 0 aborts",
    "FlipCentering / every read fails: read failed: scripted read failure | 0 ms | 1 reads | 0 aborts",
    "CenterCorrection / every read fails: Failure: Some(\"Centering correction slew did not report startup within 5s\") | 5000 ms | 11 reads | 1 aborts",
    "CenterInProgress / every read fails: Failure: Some(\"The mount was still slewing after 300s; centering stopped instead of taking a frame while it moved\") | 300000 ms | 601 reads | 1 aborts",
    "SlewInstruction / every read fails: Mount slew timed out after 300 seconds | 300000 ms | 601 reads | 1 aborts",
    "Wizard / every read fails: done | 2000 ms | 3 reads | 0 aborts",
    "BridgeWatch / every read fails: Lost contact with the mount during the slew (10 status reads failed) | 9000 ms | 10 reads | 0 aborts",
    "FlipSlew / stopped at 5 s: stopped Moving abort true | 5100 ms | 16 reads | 1 aborts",
    "FlipCentering / stopped at 5 s: stopped Moving abort true | 5500 ms | 12 reads | 1 aborts",
    "CenterCorrection / stopped at 5 s: Cancelled: Some(\"Operation cancelled\") | 5500 ms | 12 reads | 1 aborts",
    "CenterInProgress / stopped at 5 s: done | 0 ms | 1 reads | 0 aborts",
    "SlewInstruction / stopped at 5 s: Operation cancelled | 5500 ms | 11 reads | 1 aborts",
    "Wizard / stopped at 5 s: Operation cancelled during slew | 6000 ms | 6 reads | 0 aborts",
    "BridgeWatch / stopped at 5 s: arrived near true | 23000 ms | 24 reads | 0 aborts",
    "FlipSlew / never stops: overran abort true | 600500 ms | 1203 reads | 1 aborts",
    "FlipCentering / never stops: overran abort true | 300500 ms | 603 reads | 1 aborts",
    "CenterCorrection / never stops: Failure: Some(\"The mount was still slewing after 300s; centering stopped instead of taking a frame while it moved\") | 300000 ms | 602 reads | 1 aborts",
    "CenterInProgress / never stops: Failure: Some(\"The mount was still slewing after 300s; centering stopped instead of taking a frame while it moved\") | 300000 ms | 601 reads | 1 aborts",
    "SlewInstruction / never stops: Mount slew timed out after 300 seconds | 300000 ms | 601 reads | 1 aborts",
    "Wizard / never stops: Slew timed out after 300 seconds | 300000 ms | 301 reads | 0 aborts",
    "BridgeWatch / never stops: Mount slew timed out after 300 seconds | 300000 ms | 301 reads | 0 aborts",
];

#[tokio::test(start_paused = true)]
async fn every_slew_wait_answers_the_same_mounts_as_before() {
    let mut actual = Vec::new();
    for (name, script, stop_at) in SCRIPTS {
        for site in SITES {
            actual.push(format!(
                "{site:?} / {name}: {}",
                run(site, script, stop_at).await
            ));
        }
    }
    assert_eq!(actual, EXPECTED, "\n{}", actual.join("\n"));
}
