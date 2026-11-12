//! PHD2, reached over its JSON-RPC event socket. The PHD2 half of
//! [`super::Guider`], plus what only PHD2 has: its guide algorithm settings,
//! its calibration store, its exposure and its profile.

use super::stop_reason;
use super::{GuideStarImage, GuiderCalibration, GuiderStatus};
use crate::api::{get_device_manager, get_state};
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::error::SkotiqError;
use crate::event::{EventSeverity, GuidingEvent};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::{Mutex, RwLock};

/// The event for PHD2's SettleDone. A failed settle (non-zero status) must
/// not masquerade as a clean "Settled" event, and it is not a lost star
/// either: PHD2 reports a settle that ran out of time while it still holds
/// the star.
fn settle_done_event(status: i32, error: &str) -> GuidingEvent {
    if status == 0 {
        return GuidingEvent::Settled { rms: 0.0 };
    }
    GuidingEvent::SettleTimedOut {
        error: if error.is_empty() {
            "the guider did not settle in time".to_string()
        } else {
            error.to_string()
        },
    }
}

/// Turn PHD2's `get_pixel_scale` answer into a scale the UI can convert with.
///
/// PHD2 answers JSON null when its profile has no focal length or pixel size,
/// which the client reports as an error; a zero or negative number is no scale
/// either. Both read as unknown.
fn known_pixel_scale(reply: Result<f64, String>) -> Option<f64> {
    reply.ok().filter(|scale| scale.is_finite() && *scale > 0.0)
}

/// PHD2's device id. PHD2 is listed in two registries that join on it: the
/// client slot below ("can an RPC be sent now") and the device registries
/// ("is a guider connected"). The Dart side spells the same value
/// `kPhd2CanonicalId` (`packages/skotiq_core/lib/src/utils/device_id.dart`).
pub(crate) const DEVICE_ID: &str = "phd2_guider";

/// Whether `device_id` names PHD2, in any spelling a saved profile may hold.
pub(crate) fn is_device_id(device_id: &str) -> bool {
    device_id == DEVICE_ID
        || device_id == "phd2"
        || device_id.starts_with("phd2:")
        || device_id.starts_with("phd2://")
}

/// The state [`status`] reports for a connected PHD2 that did not
/// answer in time.
pub(crate) const PHD2_NOT_RESPONDING: &str = "NotResponding";

static CLIENT: OnceLock<Arc<RwLock<Option<skotiq_phd2::Phd2Client>>>> = OnceLock::new();

fn client_slot() -> &'static Arc<RwLock<Option<skotiq_phd2::Phd2Client>>> {
    CLIENT.get_or_init(|| Arc::new(RwLock::new(None)))
}

/// The live client under the slot's write lock, or `NotConnected("PHD2")`.
/// The guard holds the lock while it lives; drop it before a long wait so
/// status reads and a stop are not stalled (see [`dither`]).
async fn phd2_client(
) -> Result<tokio::sync::RwLockMappedWriteGuard<'static, skotiq_phd2::Phd2Client>, SkotiqError> {
    let storage = client_slot().write().await;
    tokio::sync::RwLockWriteGuard::try_map(storage, |slot| slot.as_mut())
        .map_err(|_| SkotiqError::NotConnected("PHD2".to_string()))
}

/// Connect to PHD2 and list it as the connected guider.
pub(crate) async fn connect(host: Option<String>, port: Option<u16>) -> Result<(), SkotiqError> {
    // Why: localhost + PHD2 default port 4400 are the
    // documented PHD2 defaults from the PHD2 EventMonitoring wiki and the
    // Skotiq PHD2-settings UI placeholder values.
    let host =
        skotiq_phd2::normalize_phd2_tcp_host(&host.unwrap_or_else(|| "127.0.0.1".to_string()));
    let port = port.unwrap_or(skotiq_phd2::PHD2_DEFAULT_PORT);

    tracing::info!("Connecting to PHD2 at {}:{}", host, port);

    {
        let mut storage = client_slot().write().await;
        if let Some(mut existing) = storage.take() {
            existing.disconnect();
        }
    }

    let mut client = skotiq_phd2::Phd2Client::new(&host, port);

    // Set up event callback to forward PHD2 events to the main event stream.
    // This callback runs on the PHD2 reader std::thread, NOT on the tokio runtime.
    // It publishes to the broadcast channel which is picked up by api_event_stream.
    client.set_event_callback(move |event| {
        let subscriber_count = get_state().event_bus.subscriber_count();
        // Per-event plumbing trace — fires on every looping frame (~1 Hz), so
        // keep it at debug to avoid flooding the log during normal guiding.
        tracing::debug!(
            "PHD2 event callback received: {:?} (event bus subscribers: {})",
            std::mem::discriminant(&event),
            subscriber_count
        );

        let guiding_event = match event {
            skotiq_phd2::Phd2Event::GuideStep(ref frame) => {
                tracing::debug!(
                    "PHD2 GuideStep: RA={:.3}, Dec={:.3}, SNR={:.1}",
                    frame.ra_distance,
                    frame.dec_distance,
                    frame.snr
                );
                // Forward guide step correction data
                let event_id = get_state().publish_guiding_event(
                    GuidingEvent::Correction {
                        ra: frame.ra_distance,
                        dec: frame.dec_distance,
                        ra_raw: frame.ra_distance,
                        dec_raw: frame.dec_distance,
                    },
                    EventSeverity::Info,
                );
                tracing::debug!("PHD2: Published Correction event (id={})", event_id);
                // Also forward guide stats (SNR and star mass)
                let stats_id = get_state().publish_guiding_event(
                    GuidingEvent::GuideStats {
                        snr: frame.snr,
                        star_mass: frame.star_mass,
                    },
                    EventSeverity::Info,
                );
                tracing::debug!("PHD2: Published GuideStats event (id={})", stats_id);
                return;
            }
            skotiq_phd2::Phd2Event::StateChanged(state) => {
                // PHD2 re-emits its state on every looping frame, so this would
                // log "Looping" once a second. The meaningful transitions are
                // surfaced to the UI as GuidingEvents; keep the raw log at debug.
                tracing::debug!("PHD2 state changed: {:?}", state);
                match state {
                    skotiq_phd2::Phd2State::Guiding => GuidingEvent::GuidingStarted,
                    skotiq_phd2::Phd2State::Connected => GuidingEvent::GuidingStopped,
                    skotiq_phd2::Phd2State::Disconnected => GuidingEvent::Disconnected,
                    skotiq_phd2::Phd2State::Paused => GuidingEvent::Paused,
                    skotiq_phd2::Phd2State::LostLock => GuidingEvent::LostStar,
                    skotiq_phd2::Phd2State::Looping => GuidingEvent::Looping,
                    skotiq_phd2::Phd2State::Calibrating => GuidingEvent::Calibrating,
                    skotiq_phd2::Phd2State::Settling => GuidingEvent::Settling,
                    // Why: PHD2 occasionally introduces new app-states; we
                    // forward the raw name as a generic `Disconnected` event
                    // (the safest superset for sequencer logic) but the
                    // warning is already emitted upstream in
                    // `parse_phd2_app_state`. Surfacing the literal string in
                    // the GuidingEvent stream would require extending the
                    // FFI enum, which is out of scope here.
                    skotiq_phd2::Phd2State::Unknown(raw) => {
                        tracing::warn!(
                            "PHD2: unrecognised state {:?} bubbled into bridge — \
                             treating as Disconnected for guiding-event mapping",
                            raw
                        );
                        GuidingEvent::Disconnected
                    }
                }
            }
            skotiq_phd2::Phd2Event::StarLost => GuidingEvent::LostStar,
            skotiq_phd2::Phd2Event::StarSelected { x, y } => GuidingEvent::StarSelected { x, y },
            skotiq_phd2::Phd2Event::SettleBegin => GuidingEvent::Settling,
            skotiq_phd2::Phd2Event::SettleDone {
                status,
                ref error,
                total_frames: _,
                dropped_frames: _,
            } => {
                // The dither path waits on SettleDone explicitly (see
                // `dither`); this stream mapping is for UI/telemetry.
                if status != 0 {
                    tracing::warn!(
                        "PHD2: settle failed (status {}): {}",
                        status,
                        if error.is_empty() { "no detail" } else { error }
                    );
                }
                settle_done_event(status, error)
            }
            skotiq_phd2::Phd2Event::CalibrationComplete => {
                tracing::info!("PHD2: Calibration complete");
                GuidingEvent::CalibrationComplete
            }
            skotiq_phd2::Phd2Event::Disconnected => GuidingEvent::Disconnected,
            skotiq_phd2::Phd2Event::Alert {
                message,
                alert_type,
            } => {
                tracing::warn!("PHD2 Alert [{}]: {}", alert_type, message);
                return; // Alerts are not forwarded as GuidingEvent
            }
            skotiq_phd2::Phd2Event::Error(msg) => {
                tracing::error!("PHD2 Error: {}", msg);
                return; // Errors are not forwarded as GuidingEvent
            }
        };

        let severity = match &guiding_event {
            GuidingEvent::LostStar
            | GuidingEvent::Disconnected
            | GuidingEvent::SettleTimedOut { .. } => EventSeverity::Warning,
            _ => EventSeverity::Info,
        };

        let event_id = get_state().publish_guiding_event(guiding_event.clone(), severity);
        tracing::debug!(
            "PHD2: Published {:?} to event bus (event_id={}, subscribers={})",
            guiding_event,
            event_id,
            subscriber_count
        );
    });

    client
        .connect()
        .map_err(|e| SkotiqError::connection_failed(DEVICE_ID, format!("PHD2: {}", e)))?;

    client
        .wait_until_ready(Duration::from_secs(10))
        .map_err(|e| {
            client.disconnect();
            SkotiqError::connection_failed(DEVICE_ID, format!("PHD2: {}", e))
        })?;

    let mut storage = client_slot().write().await;
    *storage = Some(client);

    // PHD2 owns its own socket (opened above), so it registers as
    // already-connected rather than going through `connect_device`.
    let phd2_device_info = DeviceInfo {
        id: DEVICE_ID.to_string(),
        name: "PHD2".to_string(),
        device_type: DeviceType::Guider,
        driver_type: DriverType::Native,
        description: format!("PHD2 Guiding at {}:{}", host, port),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: "PHD2 Guiding".to_string(),
    };
    get_device_manager()
        .register_connected_device(phd2_device_info)
        .await;

    get_state().publish_guiding_event(GuidingEvent::Connected, EventSeverity::Info);

    Ok(())
}

pub(crate) async fn disconnect() -> Result<(), SkotiqError> {
    PHD2_STOP_GENERATION.fetch_add(1, Ordering::SeqCst);
    let mut storage = client_slot().write().await;
    if let Some(mut client) = storage.take() {
        client.disconnect();
    }

    // `unregister_device` (a plain map removal), never `disconnect_device`,
    // which routes PHD2 ids back here and would recurse.
    get_device_manager().unregister_device(DEVICE_ID).await;

    get_state().publish_guiding_event(GuidingEvent::Disconnected, EventSeverity::Info);

    Ok(())
}

/// Serializes the PHD2 operations that start guiding or move the guide star:
/// a fresh star selection, a start with its settle, and a dither with its
/// settle. PHD2 refuses a `guide` while an earlier guide or dither is still
/// settling ("Cannot initiate guide while guide is in progress"), and a
/// selection that stops capture under a running start breaks both. A stop
/// never waits for this lock: it is how a running settle is ended.
static PHD2_GUIDE_OPS: Mutex<()> = Mutex::const_new(());

/// Bumped by every stop and disconnect. A settle wait that sees it change
/// ends at once instead of running out its timeout.
static PHD2_STOP_GENERATION: AtomicU64 = AtomicU64::new(0);

/// How long a start waits for calibration on top of its settle. PHD2 starts
/// the settle clock only after calibration, and a calibration of both axes
/// with backlash clearing takes several minutes on a long-focal-length rig.
const CALIBRATION_ALLOWANCE: Duration = Duration::from_secs(600);

/// The guide exposure assumed when PHD2 does not answer `get_exposure`. It
/// only sizes timeouts, so it errs long.
const FALLBACK_GUIDE_EXPOSURE: Duration = Duration::from_secs(5);

/// How long past one guide exposure PHD2 may take to end a capture it was
/// asked to stop: the download and a guide pulse of up to a few seconds.
const STOP_GRACE: Duration = Duration::from_secs(15);

/// PHD2's guide exposure, or [`FALLBACK_GUIDE_EXPOSURE`] when it does not
/// answer. A slow PHD2 is not a reason to give up on guiding.
async fn guide_exposure() -> Result<Duration, SkotiqError> {
    let reply = phd2_client().await?.get_exposure();
    Ok(match reply {
        Ok(ms) if ms > 0 => Duration::from_millis(u64::from(ms)),
        Ok(_) => FALLBACK_GUIDE_EXPOSURE,
        Err(e) => {
            tracing::warn!(
                "PHD2 did not report its guide exposure ({e}); assuming {} s",
                FALLBACK_GUIDE_EXPOSURE.as_secs()
            );
            FALLBACK_GUIDE_EXPOSURE
        }
    })
}

/// Stop PHD2's capture and wait until PHD2 reports "Stopped". Ok(false)
/// when it was still capturing after one exposure and [`STOP_GRACE`].
///
/// `stop_capture` returns as soon as PHD2 has the request, while its worker
/// is still inside a guide pulse or an exposure. Until that ends PHD2 keeps
/// the earlier guide's settle open and refuses a new `guide`, and a looping
/// frame from the old capture can still arrive.
async fn stop_capture_and_wait(exposure: Duration) -> Result<bool, SkotiqError> {
    phd2_client()
        .await?
        .stop_capture()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to stop PHD2 capture: {e}")))?;
    let deadline = tokio::time::Instant::now() + exposure + STOP_GRACE;
    loop {
        let state = {
            let mut client = phd2_client().await?;
            if !client.is_connected() {
                return Err(SkotiqError::NotConnected("PHD2".into()));
            }
            client.get_app_state_name()
        };
        if matches!(state.as_deref(), Ok("Stopped")) {
            return Ok(true);
        }
        if tokio::time::Instant::now() >= deadline {
            tracing::warn!(
                "[GUIDING] PHD2 was still capturing {} s after it was asked to stop ({})",
                (exposure + STOP_GRACE).as_secs(),
                state.unwrap_or_else(|e| e)
            );
            return Ok(false);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// [`stop_capture_and_wait`] for a caller that must not go on while PHD2 is
/// still capturing.
async fn stop_capture_completely(exposure: Duration) -> Result<(), SkotiqError> {
    if stop_capture_and_wait(exposure).await? {
        Ok(())
    } else {
        Err(SkotiqError::OperationFailed(
            "PHD2 did not stop its capture".to_string(),
        ))
    }
}

/// Wait for the settle `waiter` tracks without blocking a thread, so the
/// wait ends when its future is dropped, when guiding is stopped, or when
/// PHD2 reports the settle. Time PHD2 spends calibrating does not count
/// against `settle_wait`, up to [`CALIBRATION_ALLOWANCE`].
async fn await_settle(
    waiter: skotiq_phd2::SettleWaiter,
    settle_wait: Duration,
    stop_generation: u64,
) -> Result<(), String> {
    let started = tokio::time::Instant::now();
    let cap = started + settle_wait + CALIBRATION_ALLOWANCE;
    let mut deadline = started + settle_wait;
    loop {
        if let Some(result) = waiter.check() {
            return result.map(|_| ());
        }
        if PHD2_STOP_GENERATION.load(Ordering::SeqCst) != stop_generation {
            return Err("guiding was stopped while it settled".to_string());
        }
        let now = tokio::time::Instant::now();
        if waiter.is_calibrating() {
            deadline = deadline.max(now + settle_wait).min(cap);
        }
        if now >= deadline {
            return Err(format!(
                "PHD2 settle did not complete within {:.0}s",
                (deadline - started).as_secs_f64()
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// End a settle this client is still waiting on before a new guide or dither.
async fn finish_pending_settle() -> Result<(), SkotiqError> {
    if !phd2_client().await?.settle_pending() {
        return Ok(());
    }
    tracing::warn!(
        "[GUIDING] PHD2 is still settling an earlier guide or dither; stopping its capture first"
    );
    stop_capture_completely(guide_exposure().await?).await
}

/// Start guiding in PHD2 and wait for it to settle.
///
/// A settle that runs out while PHD2 is still guiding leaves it guiding and
/// returns Ok: the star is held, only not yet inside the settle bound, and
/// every caller judges the guiding RMS itself. Stopping it there left the
/// rest of the night unguided. Any other failure is an error, and a PHD2
/// that is not guiding is stopped so it does not keep looking for a star.
pub(crate) async fn start_guiding(
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    let _ops = PHD2_GUIDE_OPS.lock().await;
    finish_pending_settle().await?;
    let stop_generation = PHD2_STOP_GENERATION.load(Ordering::SeqCst);
    let waiter = phd2_client()
        .await?
        .guide_arm(settle_pixels, settle_time, settle_timeout)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to start guiding: {}", e)))?;
    let settle_wait = skotiq_phd2::Phd2Client::settle_wait_duration(settle_time, settle_timeout);
    if let Err(error) = await_settle(waiter, settle_wait, stop_generation).await {
        if PHD2_STOP_GENERATION.load(Ordering::SeqCst) != stop_generation {
            return Err(SkotiqError::OperationFailed(format!(
                "Guiding did not settle: {error}"
            )));
        }
        let mut client = phd2_client().await?;
        if matches!(client.get_app_state_name().as_deref(), Ok("Guiding")) {
            tracing::warn!(
                "[GUIDING] Guiding did not settle within {settle_pixels:.1} px ({error}); \
                 PHD2 is still guiding, so it is left guiding"
            );
            drop(client);
            stop_reason::set(None);
            get_state().publish_guiding_event(GuidingEvent::GuidingStarted, EventSeverity::Info);
            return Ok(());
        }
        client.stop_capture().map_err(|stop| {
            SkotiqError::OperationFailed(format!(
                "Guiding did not settle: {error}; stopping guiding also failed: {stop}"
            ))
        })?;
        return Err(SkotiqError::OperationFailed(format!(
            "Guiding did not settle: {error}"
        )));
    }

    stop_reason::set(None);
    get_state().publish_guiding_event(GuidingEvent::GuidingStarted, EventSeverity::Info);

    Ok(())
}

/// Stop guiding in PHD2 and wait until its capture has ended, so the mount
/// is not moved under a guide pulse and the next start is not refused. A
/// settle another call is waiting on ends at once.
pub(crate) async fn stop_guiding() -> Result<(), SkotiqError> {
    PHD2_STOP_GENERATION.fetch_add(1, Ordering::SeqCst);
    // Acknowledging stop_capture is not enough: callers may move the mount
    // once this returns, so capture must actually have ended.
    stop_capture_completely(guide_exposure().await?)
        .await
        .map_err(|e| match e {
            SkotiqError::OperationFailed(message) => {
                SkotiqError::OperationFailed(format!("Failed to stop guiding: {message}"))
            }
            other => other,
        })?;

    get_state().publish_guiding_event(GuidingEvent::GuidingStopped, EventSeverity::Info);

    Ok(())
}

pub(crate) async fn dither(
    amount: f64,
    ra_only: bool,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    let _ops = PHD2_GUIDE_OPS.lock().await;
    finish_pending_settle().await?;
    let stop_generation = PHD2_STOP_GENERATION.load(Ordering::SeqCst);

    // Issue the dither RPC and arm settle tracking under the client lock, then
    // release it for the settle wait so status polls and stop are not stalled.
    let waiter = phd2_client()
        .await?
        .dither_arm(
            amount,
            ra_only,
            settle_pixels,
            settle_time,
            settle_timeout,
        )
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to dither: {}", e)))?;

    get_state().publish_guiding_event(
        GuidingEvent::DitherStarted { pixels: amount },
        EventSeverity::Info,
    );

    // Fail closed: a non-zero PHD2 settle status, a settle timeout, a stop or
    // a disconnect all surface as an error so the sequencer never resumes
    // exposing mid-settle (which trailed every dithered sub).
    let wait = skotiq_phd2::Phd2Client::settle_wait_duration(settle_time, settle_timeout);
    await_settle(waiter, wait, stop_generation)
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Dither did not settle: {}", e)))?;

    get_state().publish_guiding_event(GuidingEvent::Settled { rms: 0.0 }, EventSeverity::Info);

    Ok(())
}

/// PHD2's state and its rolling guide statistics. The stop reason is the
/// guider service's to fill in.
pub(crate) async fn status() -> Result<GuiderStatus, SkotiqError> {
    let mut client = phd2_client().await?;

    // The client retries a stalled status request on a fresh connection.
    // If an RPC error arrives on a live socket, report it as unknown state;
    // exhausted transport recovery is a connection failure.
    let state = match client.get_app_state() {
        Ok(state) => state,
        Err(e) if client.is_connected() => {
            tracing::warn!("PHD2 did not answer get_app_state: {}", e);
            skotiq_phd2::Phd2State::Unknown(PHD2_NOT_RESPONDING.to_string())
        }
        Err(e) => {
            return Err(SkotiqError::OperationFailed(format!(
                "Failed to get PHD2 state: {}",
                e
            )))
        }
    };

    let pixel_scale = known_pixel_scale(client.get_pixel_scale());

    // Why: forward the raw PHD2 state name when unrecognised so the desktop
    // UI can render "PHD2 says: GuidingPaused" instead of pretending
    // everything is fine. Known variants stay as &'static str literals;
    // Unknown owns its String, so we convert to String at the join point.
    let state_str: String = match state {
        skotiq_phd2::Phd2State::Disconnected => "Disconnected".to_string(),
        skotiq_phd2::Phd2State::Connected => "Connected".to_string(),
        skotiq_phd2::Phd2State::Calibrating => "Calibrating".to_string(),
        skotiq_phd2::Phd2State::Guiding => "Guiding".to_string(),
        skotiq_phd2::Phd2State::Looping => "Looping".to_string(),
        skotiq_phd2::Phd2State::Paused => "Paused".to_string(),
        skotiq_phd2::Phd2State::Settling => "Settling".to_string(),
        skotiq_phd2::Phd2State::LostLock => "LostLock".to_string(),
        skotiq_phd2::Phd2State::Unknown(raw) => raw,
    };

    // Report the real rolling guide statistics accumulated from the PHD2
    // GuideStep event stream. Returning hardcoded 0.0 here is a silent
    // fallback that disables the sequencer's GuidingFailed safety trigger
    // (it fires only when sustained RMS exceeds a threshold, and 0.0 can
    // never exceed it) and blinds the per-exposure guiding-quality gate.
    // The Phd2Client already computes rms_total = sqrt(rms_ra^2 + rms_dec^2)
    // per guide frame; surface it.
    let stats = client.get_rolling_stats();

    Ok(GuiderStatus {
        device_id: DEVICE_ID.to_string(),
        connected: client.is_connected(),
        state: state_str,
        rms_ra: stats.rms_ra,
        rms_dec: stats.rms_dec,
        rms_total: stats.rms_total,
        snr: stats.snr,
        star_mass: stats.star_mass,
        pixel_scale,
        stop_reason: None,
        tracked_stars: Vec::new(),
    })
}

pub(crate) async fn star_image(size: u32) -> Result<GuideStarImage, SkotiqError> {
    let mut client = phd2_client().await?;

    let image_data = client
        .get_star_image_data(size)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get star image: {}", e)))?;

    Ok(GuideStarImage {
        frame: image_data.frame,
        width: image_data.width,
        height: image_data.height,
        star_x: image_data.star_x,
        star_y: image_data.star_y,
        pixels: image_data.pixels,
    })
}

pub(crate) async fn algo_param_names(axis: &str) -> Result<Vec<String>, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_algo_param_names(axis)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get algo param names: {}", e)))
}

pub(crate) async fn algo_param(axis: &str, name: &str) -> Result<f64, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_algo_param(axis, name)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get algo param: {}", e)))
}

pub(crate) async fn set_algo_param(axis: &str, name: &str, value: f64) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_algo_param(axis, name, value)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set algo param: {}", e)))
}

pub(crate) async fn set_paused(paused: bool) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_paused(paused)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set paused: {}", e)))?;

    get_state().publish_guiding_event(
        if paused {
            GuidingEvent::Paused
        } else {
            GuidingEvent::Resumed
        },
        EventSeverity::Info,
    );

    Ok(())
}

pub(crate) async fn clear_calibration(which: &str) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .clear_calibration(which)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to clear calibration: {}", e)))
}

pub(crate) async fn flip_calibration() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .flip_calibration()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to flip calibration: {}", e)))
}

pub(crate) async fn calibration() -> Result<GuiderCalibration, SkotiqError> {
    let mut client = phd2_client().await?;

    // PHD2's get_calibration_data `which` param only accepts "Mount" or "AO"
    // (default "Mount") — there is no "both", and passing it makes PHD2 reject
    // the request with `invalid 'which' param`, spamming the log with calibration
    // fetch errors. Query the mount calibration (the guide-scope axes); AO is
    // only relevant to adaptive-optics rigs, which report through a separate
    // device.
    let result = client.get_calibration_data("Mount").map_err(|e| {
        SkotiqError::OperationFailed(format!("Failed to get calibration data: {}", e))
    })?;

    // PHD2's get_calibration_data returns a JSON object with a `calibrated`
    // boolean (and, when true, the xAngle/yAngle/xRate/yRate details). It does
    // NOT return null when the mount is uncalibrated — it returns
    // {"calibrated": false}. A `!result.is_null()` test is therefore ALWAYS
    // true on any successful RPC, which reports the mount as calibrated when
    // it is not. Read the actual flag.
    let is_calibrated = result
        .get("calibrated")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Extract calibration parameters if available
    let (ra_angle, dec_angle, ra_rate, dec_rate) = if is_calibrated {
        let xangle = result.get("xAngle").and_then(|v| v.as_f64());
        let yangle = result.get("yAngle").and_then(|v| v.as_f64());
        let xrate = result.get("xRate").and_then(|v| v.as_f64());
        let yrate = result.get("yRate").and_then(|v| v.as_f64());
        (xangle, yangle, xrate, yrate)
    } else {
        (None, None, None, None)
    };

    Ok(GuiderCalibration {
        is_calibrated,
        ra_angle,
        dec_angle,
        ra_rate,
        dec_rate,
    })
}

pub(crate) async fn find_star() -> Result<(f64, f64), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .find_star()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to find star: {}", e)))
}

pub(crate) async fn set_lock_position(x: f64, y: f64, exact: bool) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_lock_position(x, y, exact)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set lock position: {}", e)))
}

pub(crate) async fn lock_position() -> Result<(f64, f64), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_lock_position()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get lock position: {}", e)))
}

pub(crate) async fn loop_exposures() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .loop_exposures()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to start looping: {}", e)))
}

pub(crate) async fn deselect_star() -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .deselect_star()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to deselect star: {}", e)))
}

pub(crate) async fn exposure_ms() -> Result<u32, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_exposure()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get exposure: {}", e)))
}

pub(crate) async fn set_exposure_ms(exposure_ms: u32) -> Result<(), SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .set_exposure(exposure_ms)
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to set exposure: {}", e)))
}

pub(crate) async fn profile() -> Result<String, SkotiqError> {
    let mut client = phd2_client().await?;

    client
        .get_profile()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to get profile: {}", e)))
}

/// How many guide frames a fresh star selection waits for before giving up.
const FRESH_STAR_ATTEMPTS: u32 = 3;

/// Wait for a looping frame counted after `after`, and return its count.
/// The exposure length sets the timeout, never proof that a frame arrived.
async fn wait_for_looping_frame(after: u64, exposure: Duration) -> Result<u64, SkotiqError> {
    // Exposure time does not include the download. Waiting for PHD2's frame
    // event is what keeps find_star off the image taken before the move.
    let deadline = tokio::time::Instant::now() + exposure + STOP_GRACE;
    loop {
        let frame = {
            let client = phd2_client().await?;
            if !client.is_connected() {
                return Err(SkotiqError::NotConnected("PHD2".into()));
            }
            client.looping_frame_count()
        };
        if frame > after {
            return Ok(frame);
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(SkotiqError::OperationFailed(
                "PHD2 did not deliver a fresh guide frame".into(),
            ));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Make PHD2 pick a guide star afresh before the sequencer (re)starts guiding:
/// stop capture and wait until it has stopped, loop, wait for a frame taken
/// after that, then auto-select a star.
///
/// PHD2's `guide` RPC keeps the star it has selected. After a slew or a target
/// change that is the lock position from the previous field, and PHD2 then
/// guides on empty sky.
///
/// With a `floor`, the selected star is measured on the next frame and one
/// below the floor is refused; the search goes on in the following frames.
/// A PHD2 that does not report the star's measurements is taken at its word.
pub(crate) async fn select_fresh_star(
    floor: Option<skotiq_sequencer::GuideStarFloor>,
) -> Result<(f64, f64), SkotiqError> {
    let _ops = PHD2_GUIDE_OPS.lock().await;
    let exposure = guide_exposure().await?;
    tracing::info!(
        "[GUIDING] Selecting a fresh guide star: stopping PHD2's capture, then looping \
         {:.1} s frames",
        exposure.as_secs_f64()
    );
    stop_capture_completely(exposure).await?;
    let selected = find_fresh_star(exposure, floor).await;
    if selected.is_err() {
        // PHD2 found nothing to guide on; left looping it exposes the guide
        // camera until someone stops it (rig, 2026-11-03: still looping after
        // the run parked).
        let stopped = phd2_client().await.and_then(|mut client| {
            client
                .stop_capture()
                .map_err(|e| SkotiqError::OperationFailed(e.to_string()))
        });
        if let Err(error) = stopped {
            tracing::warn!(
                "[GUIDING] Could not stop PHD2's looping after the star search: {error}"
            );
        }
    }
    selected
}

/// Loop PHD2 and auto-select a star in a frame taken after the capture
/// [`select_fresh_star`] stopped.
async fn find_fresh_star(
    exposure: Duration,
    floor: Option<skotiq_sequencer::GuideStarFloor>,
) -> Result<(f64, f64), SkotiqError> {
    // Counted only once PHD2 has stopped, so every later frame was exposed
    // after this request.
    let mut last_frame = {
        let mut client = phd2_client().await?;
        let frame = client.looping_frame_count();
        client.loop_exposures().map_err(|e| {
            SkotiqError::OperationFailed(format!("Failed to start PHD2 looping: {}", e))
        })?;
        frame
    };
    let mut last_error = String::new();
    for attempt in 1..=FRESH_STAR_ATTEMPTS {
        last_frame = wait_for_looping_frame(last_frame, exposure).await?;
        let (x, y) = match phd2_client().await?.find_star() {
            Ok(found) => found,
            Err(e) => {
                tracing::warn!(
                    "[GUIDING] No guide star found in frame {attempt}/{FRESH_STAR_ATTEMPTS}: {e}"
                );
                last_error = e;
                continue;
            }
        };
        if let Some(floor) = floor {
            // PHD2 measures the selected star in the frames that follow.
            last_frame = wait_for_looping_frame(last_frame, exposure).await?;
            let star = phd2_client()
                .await?
                .looping_star()
                .filter(|star| star.frame >= last_frame);
            match star {
                Some(star)
                    if !floor.accepts(&skotiq_sequencer::GuideStarQuality {
                        snr: star.snr,
                        star_mass: star.star_mass,
                    }) =>
                {
                    let refused = format!(
                        "the star at ({x:.1}, {y:.1}) px measures SNR {:.1}, mass {:.0}, \
                         below the floor of SNR {:.1}, mass {:.0}",
                        star.snr, star.star_mass, floor.min_snr, floor.min_star_mass
                    );
                    tracing::warn!(
                        "[GUIDING] Refused a guide star in frame {attempt}/{FRESH_STAR_ATTEMPTS}: \
                         {refused}"
                    );
                    last_error = refused;
                    continue;
                }
                Some(_) => {}
                None => tracing::info!(
                    "[GUIDING] PHD2 did not report the selected star's SNR; it is used unchecked"
                ),
            }
        }
        tracing::info!(
            "[GUIDING] Fresh guide star selected at ({x:.1}, {y:.1}) px \
             (attempt {attempt}/{FRESH_STAR_ATTEMPTS})"
        );
        return Ok((x, y));
    }
    Err(SkotiqError::OperationFailed(format!(
        "PHD2 found no guide star in {FRESH_STAR_ATTEMPTS} fresh frames ({last_error})"
    )))
}

#[cfg(test)]
use super::TEST_SLOT as PHD2_TEST_SLOT;

#[cfg(test)]
mod client_slot_tests {
    use super::*;

    #[test]
    fn the_device_id_is_the_one_dart_holds() {
        // `kPhd2CanonicalId` on the Dart side; both registries join on it.
        assert_eq!(DEVICE_ID, "phd2_guider");
        assert!(is_device_id(DEVICE_ID));
    }

    #[tokio::test]
    async fn no_client_is_not_connected_phd2() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        assert!(client_slot().read().await.is_none());
        match phd2_client().await {
            Ok(_) => panic!("expected NotConnected with no PHD2 client stored"),
            Err(SkotiqError::NotConnected(who)) => assert_eq!(who, "PHD2"),
            Err(other) => panic!("unexpected error variant: {:?}", other),
        }
    }

    #[tokio::test]
    async fn a_failed_client_read_releases_the_slot() {
        // `try_map` hands the guard back inside its Err, which is dropped with
        // the error. If it leaked, this second acquisition would deadlock.
        let _slot = PHD2_TEST_SLOT.lock().await;
        let _ = phd2_client().await;
        let guard = tokio::time::timeout(std::time::Duration::from_secs(2), client_slot().write())
            .await
            .expect("write lock must be free after a failed phd2_client()");
        assert!(guard.is_none());
    }
}

// A PHD2 connect must be visible to the connected-devices API: PHD2 owns its
// socket, so nothing registers it unless `connect` does, and every surface
// would report "no guider connected" while the sequencer guided through it all
// night.
//
// These tests drive the real `connect` against a mock PHD2 socket, so they
// exercise the production connect path end to end rather than a helper.
#[cfg(test)]
mod connected_devices_registry_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    /// A PHD2 stand-in that answers `get_app_state` (all `wait_until_ready`
    /// needs) and hangs up when the client disconnects.
    fn spawn_mock_phd2() -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock PHD2");
        let port = listener.local_addr().expect("mock PHD2 addr").port();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept the PHD2 client");
            let mut reader = BufReader::new(stream.try_clone().expect("clone mock stream"));
            let mut writer = stream;
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(request) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                    continue;
                };
                let response = serde_json::json!({
                    "jsonrpc": "2.0",
                    "result": "Stopped",
                    "id": request["id"],
                });
                if writeln!(writer, "{}", response).is_err() || writer.flush().is_err() {
                    break;
                }
            }
        });
        (port, handle)
    }

    async fn phd2_in_connected_devices() -> bool {
        crate::api::connection::api_get_connected_devices()
            .await
            .iter()
            .any(|d| d.id == DEVICE_ID && d.device_type == DeviceType::Guider)
    }

    #[tokio::test]
    async fn a_connected_phd2_is_visible_to_the_connected_devices_api() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, server) = spawn_mock_phd2();

        connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");

        // Sample every answer BEFORE asserting, then always disconnect: an
        // assertion that unwound here would leave a live client in the process-
        // global slot and fail the client-registry tests instead of this one.
        let listed = phd2_in_connected_devices().await;
        let listed_ids = crate::api::connection::api_get_connected_devices()
            .await
            .iter()
            .map(|d| d.id.clone())
            .collect::<Vec<_>>();
        let is_connected = crate::api::connection::api_is_device_connected(
            DeviceType::Guider,
            DEVICE_ID.to_string(),
        )
        .await;

        disconnect().await.expect("disconnect PHD2");

        let listed_after = phd2_in_connected_devices().await;
        let is_connected_after = crate::api::connection::api_is_device_connected(
            DeviceType::Guider,
            DEVICE_ID.to_string(),
        )
        .await;

        server.join().expect("mock PHD2 server thread finished");

        assert!(
            listed,
            "api_get_connected_devices must list the connected PHD2 guider; it listed {:?}",
            listed_ids
        );
        assert!(
            is_connected,
            "api_is_device_connected must agree that PHD2 is connected"
        );

        assert!(
            !listed_after,
            "a disconnected PHD2 must leave the connected-devices list"
        );
        assert!(
            !is_connected_after,
            "api_is_device_connected must report a disconnected PHD2 as gone"
        );
    }

    /// `device_manager/connection.rs:912` special-cases PHD2 ids so the generic
    /// disconnect route tears the PHD2 socket down. That branch was
    /// **unreachable**: `disconnect_device` bails with "Device not found"
    /// before it, because PHD2 was never in the DeviceManager registry. The
    /// existing `disconnect_phd2_via_generic_route_calls_phd2_disconnect` test
    /// pins the id list structurally; this one drives the route.
    #[tokio::test]
    async fn the_generic_disconnect_route_reaches_a_connected_phd2() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, server) = spawn_mock_phd2();

        connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");

        let result = get_device_manager().disconnect_device(DEVICE_ID).await;

        // The client slot proves the socket was actually torn down, not just
        // the bookkeeping cleared.
        let client_slot_empty = client_slot().read().await.is_none();
        let still_listed = phd2_in_connected_devices().await;

        // Belt and braces: leave no client behind for the next test even if the
        // route failed to disconnect.
        let _ = disconnect().await;
        server.join().expect("mock PHD2 server thread finished");

        assert_eq!(
            result,
            Ok(()),
            "disconnect_device must find the registered PHD2 guider"
        );
        assert!(
            client_slot_empty,
            "the generic route must run the PHD2 disconnect and drop the client"
        );
        assert!(!still_listed, "PHD2 must leave the connected-devices list");
    }
}

#[cfg(test)]
mod fresh_guide_star_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    type RecordedMethods = Arc<Mutex<Vec<String>>>;

    /// A PHD2 stand-in that records every method it is asked for. Its first
    /// `find_star` fails, as PHD2's does before a frame has arrived; with
    /// `no_star` every one fails.
    fn spawn_recording_phd2(no_star: bool) -> (u16, RecordedMethods, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock PHD2");
        let port = listener.local_addr().expect("mock PHD2 addr").port();
        let methods = RecordedMethods::default();
        let recorded = methods.clone();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept the PHD2 client");
            let mut reader = BufReader::new(stream.try_clone().expect("clone mock stream"));
            let mut writer = stream;
            let mut line = String::new();
            let mut find_star_calls = 0;
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(request) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                    continue;
                };
                let method = request["method"].as_str().unwrap_or_default().to_string();
                recorded.lock().unwrap().push(method.clone());
                let response = match method.as_str() {
                    "get_exposure" => serde_json::json!({
                        "jsonrpc": "2.0", "result": 10, "id": request["id"],
                    }),
                    "find_star" => {
                        find_star_calls += 1;
                        if find_star_calls == 1 || no_star {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "error": {"code": 1, "message": "no star found"},
                                "id": request["id"],
                            })
                        } else {
                            serde_json::json!({
                                "jsonrpc": "2.0", "result": [12.5, 34.0], "id": request["id"],
                            })
                        }
                    }
                    _ => serde_json::json!({
                        "jsonrpc": "2.0", "result": "Stopped", "id": request["id"],
                    }),
                };
                if method == "loop" {
                    let mut events = writer.try_clone().unwrap();
                    std::thread::spawn(move || {
                        for frame in 1..=50 {
                            std::thread::sleep(Duration::from_millis(100));
                            if writeln!(
                                events,
                                "{}",
                                serde_json::json!({"Event":"LoopingExposures", "Frame":frame})
                            )
                            .is_err()
                            {
                                break;
                            }
                        }
                    });
                }
                if writeln!(writer, "{}", response).is_err() || writer.flush().is_err() {
                    break;
                }
            }
        });
        (port, methods, handle)
    }

    /// On the rig a StartGuiding after slew and center guided on the previous
    /// field's lock position. A fresh selection stops capture, loops, and asks
    /// PHD2 to find a star in a new frame, retrying until one has arrived.
    #[tokio::test]
    async fn a_fresh_star_is_found_in_a_new_frame_after_capture_restarts() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, methods, server) = spawn_recording_phd2(false);
        connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");
        methods.lock().unwrap().clear();

        let selected = select_fresh_star(None).await;

        let _ = disconnect().await;
        server.join().expect("mock PHD2 server thread finished");
        let methods = methods.lock().unwrap().clone();
        let star = selected.expect("the second frame has a star");
        assert_eq!(star, (12.5, 34.0));
        let position = |name: &str| methods.iter().position(|m| m == name);
        let (stop, looping, find) = (
            position("stop_capture"),
            position("loop"),
            position("find_star"),
        );
        assert!(
            stop.is_some() && stop < looping && looping < find,
            "stop_capture, then loop, then find_star: {methods:?}"
        );
        assert_eq!(
            methods.iter().filter(|m| *m == "find_star").count(),
            2,
            "{methods:?}"
        );
        assert!(
            !methods.iter().any(|m| m == "guide"),
            "selecting a star must not start guiding: {methods:?}"
        );
        assert_eq!(
            methods.iter().filter(|m| *m == "stop_capture").count(),
            1,
            "a star was found, so PHD2 is left looping on it: {methods:?}"
        );
    }

    /// On the rig (2026-11-03) a search that found no star left PHD2 looping,
    /// and it was still looping after the run had parked.
    #[tokio::test]
    async fn a_search_that_finds_no_star_stops_the_looping() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, methods, server) = spawn_recording_phd2(true);
        connect(Some("127.0.0.1".to_string()), Some(port))
            .await
            .expect("mock PHD2 must accept the connect");
        methods.lock().unwrap().clear();

        let selected = select_fresh_star(None).await;

        let _ = disconnect().await;
        server.join().expect("mock PHD2 server thread finished");
        let methods = methods.lock().unwrap().clone();
        assert!(selected.is_err(), "no frame had a star");
        let last_find = methods.iter().rposition(|m| m == "find_star");
        let last_stop = methods.iter().rposition(|m| m == "stop_capture");
        assert!(
            last_find.is_some() && last_stop > last_find,
            "the looping is stopped after the last search: {methods:?}"
        );
    }
}

#[cfg(test)]
mod tests {
    mod sim;
    mod transport;
}

#[cfg(test)]
mod post_flip_protocol_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::atomic::AtomicBool;

    fn server(settle_status: i32, deliver_frame: bool) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let task = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let reader = BufReader::new(stream.try_clone().unwrap());
            let writer = Arc::new(std::sync::Mutex::new(stream));
            let fresh = Arc::new(AtomicBool::new(false));
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                let method = request["method"].as_str().unwrap();
                let result = match method {
                    "get_app_state" => serde_json::json!("Stopped"),
                    "get_exposure" => serde_json::json!(10),
                    "find_star" if fresh.load(Ordering::SeqCst) => serde_json::json!([12.5, 34.0]),
                    "find_star" => serde_json::json!([315.5, 1201.9]),
                    _ => serde_json::json!(0),
                };
                writeln!(
                    writer.lock().unwrap(),
                    "{}",
                    serde_json::json!({"result": result, "id": request["id"]})
                )
                .unwrap();
                if method == "loop" && deliver_frame {
                    let writer = writer.clone();
                    let fresh = fresh.clone();
                    std::thread::spawn(move || {
                        // The old image remains selectable throughout the download.
                        std::thread::sleep(Duration::from_millis(1200));
                        fresh.store(true, Ordering::SeqCst);
                        let _ = writeln!(
                            writer.lock().unwrap(),
                            "{}",
                            serde_json::json!({"Event":"LoopingExposures", "Frame":1})
                        );
                    });
                }
                if method == "loop" && !deliver_frame {
                    break;
                }
                if method == "guide" {
                    writeln!(
                        writer.lock().unwrap(),
                        "{}",
                        serde_json::json!({"Event":"SettleDone", "Status":settle_status,"Error":"timed out"})
                    )
                    .unwrap();
                }
            }
        });
        (port, task)
    }

    #[tokio::test]
    async fn post_flip_selection_waits_for_download_even_when_old_star_is_selectable() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, task) = server(1, true);
        connect(Some("127.0.0.1".into()), Some(port))
            .await
            .unwrap();
        let selected = select_fresh_star(None).await;
        disconnect().await.unwrap();
        task.join().unwrap();
        assert_eq!(
            selected.unwrap(),
            (12.5, 34.0),
            "must not select the pre-flip star"
        );
    }

    #[tokio::test]
    async fn guide_rpc_accepted_but_settle_failed_is_not_success() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, task) = server(1, true);
        connect(Some("127.0.0.1".into()), Some(port))
            .await
            .unwrap();
        let result = start_guiding(0.5, 0.1, 1.0).await;
        disconnect().await.unwrap();
        task.join().unwrap();
        assert!(
            result.is_err(),
            "an accepted guide command is not a settled guider"
        );
    }
    #[tokio::test]
    async fn successful_settle_allows_guiding_to_start() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, task) = server(0, true);
        connect(Some("127.0.0.1".into()), Some(port))
            .await
            .unwrap();
        let result = start_guiding(0.5, 0.1, 1.0).await;
        disconnect().await.unwrap();
        task.join().unwrap();
        assert!(result.is_ok(), "{result:?}");
    }

    #[tokio::test]
    async fn disconnect_before_new_frame_cannot_select_the_old_star() {
        let _slot = PHD2_TEST_SLOT.lock().await;
        let (port, task) = server(0, false);
        connect(Some("127.0.0.1".into()), Some(port))
            .await
            .unwrap();
        let result = select_fresh_star(None).await;
        disconnect().await.unwrap();
        task.join().unwrap();
        assert!(result.is_err());
    }
}

#[cfg(test)]
mod settle_event_tests {
    use super::*;

    /// PHD2's "timed-out waiting for guider to settle" is not a lost star:
    /// read as one it raised "Guide star lost" while the star stayed locked.
    #[test]
    fn a_failed_settle_is_a_settle_timeout_not_a_lost_star() {
        match settle_done_event(1, "timed-out waiting for guider to settle") {
            GuidingEvent::SettleTimedOut { error } => {
                assert_eq!(error, "timed-out waiting for guider to settle")
            }
            other => panic!("expected SettleTimedOut, got {other:?}"),
        }
        assert!(matches!(
            settle_done_event(0, ""),
            GuidingEvent::Settled { .. }
        ));
    }
}
