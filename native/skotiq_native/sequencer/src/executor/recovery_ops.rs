//! The recovery operations the recovery driver performs: the horizontal →
//! equatorial transform used by `SlewToGapAndContinue`, guide-star
//! reacquisition, and the per-cause recovery attempt. Moved verbatim out of
//! `executor/mod.rs`.

use super::*;

/// convert horizontal coordinates (altitude / azimuth in
/// degrees) at the observer site to equatorial coordinates (RA in hours,
/// Dec in degrees) referenced to the current epoch. Used by
/// `RecoveryAction::SlewToGapAndContinue` to convert the cloud-motion
/// analyzer's "clear sky direction" into a slew destination.
///
/// `latitude` is observer latitude in degrees (+N, -S). `longitude` is
/// observer longitude in degrees (+E, -W).
///
/// References: Meeus, "Astronomical Algorithms", chapter 13 (horizontal
/// to equatorial transform). Uses the same `julian_day` /
/// `local_sidereal_time` primitives the rest of the crate uses so a
/// future ephemeris swap covers every site.
pub(crate) fn alt_az_to_ra_dec(
    alt_deg: f64,
    az_deg: f64,
    latitude: f64,
    longitude: f64,
) -> (f64, f64) {
    let alt_rad = alt_deg.to_radians();
    let az_rad = az_deg.to_radians();
    let lat_rad = latitude.to_radians();

    // Inverse of the standard horizontal-to-equatorial transform:
    //   sin(dec) = sin(alt) * sin(lat) + cos(alt) * cos(lat) * cos(az)
    //   tan(H)   = sin(az) / (cos(az) * sin(lat) - tan(alt) * cos(lat))
    let sin_dec = alt_rad.sin() * lat_rad.sin() + alt_rad.cos() * lat_rad.cos() * az_rad.cos();
    let dec_rad = sin_dec.asin();

    let y = -az_rad.sin();
    let x = lat_rad.cos() * alt_rad.tan() - lat_rad.sin() * az_rad.cos();
    let hour_angle_rad = y.atan2(x);
    let hour_angle_hours = hour_angle_rad.to_degrees() / 15.0;

    let now = chrono::Utc::now();
    let jd = crate::meridian::julian_day(&now);
    let lst_hours = crate::meridian::local_sidereal_time(jd, longitude);

    // RA = LST - HA; normalise to [0, 24).
    let mut ra_hours = lst_hours - hour_angle_hours;
    ra_hours = ra_hours.rem_euclid(24.0);

    (ra_hours, dec_rad.to_degrees())
}

/// Re-acquisition settle parameters. These mirror the conservative defaults
/// used by the guiding settle path: lock within 2 px, hold for 10 s, give up
/// after 120 s. A re-acquire that can't settle within 120 s is a genuine
/// failure the operator's retry policy should handle, not something to wait on
/// indefinitely while the target drifts.
pub(crate) const REACQUIRE_SETTLE_PIXELS: f64 = 2.0;
const REACQUIRE_SETTLE_TIME_SECS: f64 = 10.0;
const REACQUIRE_SETTLE_TIMEOUT_SECS: f64 = 120.0;
const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// Whether a guide status counts as GUIDING for recovery purposes: locked AND
/// settled inside [`REACQUIRE_SETTLE_PIXELS`].
///
/// `is_guiding` on its own does not mean that, and the difference cost the
/// owner a clear night. PHD2 reports guiding for as long as it is emitting
/// GuideStep frames, including while it chases a star it has effectively lost.
/// Measured on his rig on 2026-09-14: `is_guiding: true` throughout, with RA
/// offsets of -56.8 / -57.2 px and Dec -54.4 / -38.0 px (normal is under 2),
/// SNR collapsed 126.7 -> 17.3 -> 11.8 and StarMass 2,962,797 -> 7,991 ->
/// 5,902. Guiding was not working, and every 180 s light taken meanwhile
/// trailed to HFR 15.6 px.
///
/// `rms_total` is in guide-camera pixels — PHD2's `RADistanceRaw` /
/// `DECDistanceRaw` summed in quadrature — the same unit as the settle bound
/// and as the GuidingFailed trigger's threshold.
///
/// The bound is the one a fresh re-acquisition is already held to, so accepting
/// an existing lock cannot apply a laxer standard to the worse situation.
///
/// An RMS of exactly zero is no measurement at all. PHD2's statistics window
/// is emptied when guiding starts (so the old session's steps do not judge the
/// new one), and the built-in guider's starts empty too; until the first guide
/// step lands the window reads 0.0 while the guider already reports Guiding.
/// Every restart path polls straight after `guider_start`, so without this a
/// lock was accepted before one step had shown the star was held.
pub(crate) fn guiding_is_settled(status: &crate::device_ops::GuidingStatus) -> bool {
    status.is_guiding && status.rms_total > 0.0 && status.rms_total <= REACQUIRE_SETTLE_PIXELS
}

/// How far guiding may move the mount, from where a guide-star recovery
/// began, before the recovery stops restarting it. Guiding that locked on
/// noise behind trees dragged the mount about 0.9 degrees in Dec over a
/// night; a real star held through cloud moves it by arcseconds.
pub(crate) const RECOVERY_MAX_DISPLACEMENT_ARCMIN: f64 = 5.0;

/// The trigger state a recovery reads and records into, when it has one.
async fn recovery_trigger_state(
    trigger_manager: Option<&Arc<RwLock<TriggerManager>>>,
) -> Option<Arc<RwLock<crate::triggers::TriggerState>>> {
    match trigger_manager {
        Some(manager) => Some(manager.read().await.state()),
        None => None,
    }
}

/// How far, in arcminutes, the mount is from where this recovery began.
/// The first reading of a recovery is its origin.
async fn recovery_displacement_arcmin(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    trigger_state: Option<&Arc<RwLock<crate::triggers::TriggerState>>>,
) -> Option<f64> {
    let (id, state) = (mount_id?, trigger_state?);
    let position = bounded_poll(
        "mount_get_coordinates",
        device_ops.mount_get_coordinates(id),
    )
    .await
    .ok()?;
    let mut state = state.write().await;
    let origin = *state
        .guide_recovery
        .get_or_insert_with(Default::default)
        .origin
        .get_or_insert(position);
    Some(crate::slew_arrival::separation_deg(origin, position) * 60.0)
}

/// Record a failed attempt, with where the mount pointed, for the run and
/// the obstruction check.
async fn record_guide_recovery_failure(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    trigger_state: Option<&Arc<RwLock<crate::triggers::TriggerState>>>,
) {
    let Some(state) = trigger_state else {
        return;
    };
    let position = match mount_id {
        Some(id) => bounded_poll(
            "mount_get_coordinates",
            device_ops.mount_get_coordinates(id),
        )
        .await
        .ok(),
        None => None,
    };
    let now = chrono::Utc::now();
    let mut state = state.write().await;
    let site = state.observer_latitude.zip(state.observer_longitude);
    let alt_az_deg = position
        .zip(site)
        .map(|((ra, dec), (lat, lon))| crate::meridian::calculate_alt_az(ra, dec, lat, lon, now));
    state
        .guide_recovery
        .get_or_insert_with(Default::default)
        .failures
        .push(crate::triggers::GuideRecoveryFailure {
            at_unix: now.timestamp(),
            alt_az_deg,
        });
}

fn displaced_message(arcmin: f64) -> String {
    format!(
        "Guiding has moved the mount {arcmin:.1}' from where the guide-star recovery began \
         (limit {RECOVERY_MAX_DISPLACEMENT_ARCMIN:.0}'). Guiding is not restarted in this \
         recovery so it cannot drag the mount further; the target needs centering again."
    )
}

/// Actively re-acquire the guide star after a `GuideStarLost` event.
///
/// A mount that is not tracking cannot hold any star, so that is handed to
/// the tracking-loss recovery first instead of spending guide-star attempts
/// on it. Otherwise this restarts guiding on a star picked from a fresh frame
/// (refusing one far fainter than the run's guide star, which behind trees
/// or cloud is noise) and polls until guiding settles inside
/// [`REACQUIRE_SETTLE_PIXELS`]. Guiding that has moved the mount more than
/// [`RECOVERY_MAX_DISPLACEMENT_ARCMIN`] since the recovery began is stopped
/// and not restarted. Every failed attempt is recorded in the trigger state's
/// [`crate::triggers::GuideRecoveryStall`].
pub(crate) async fn recover_guide_star(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    trigger_manager: Option<&Arc<RwLock<TriggerManager>>>,
) -> crate::recovery::AttemptOutcome {
    use crate::recovery::AttemptOutcome;

    if let Some(id) = mount_id {
        let tracking = bounded_poll("mount_is_tracking", device_ops.mount_is_tracking(id)).await;
        let slewing = bounded_poll("mount_is_slewing", device_ops.mount_is_slewing(id)).await;
        if matches!(tracking, Ok(false)) && !matches!(slewing, Ok(true)) {
            return AttemptOutcome::HandOff {
                cause: crate::recovery::RecoveryCause::MountTrackingLost,
                message: format!(
                    "The guide star cannot be re-acquired: mount {id} is not tracking. \
                     Recovering tracking first; guiding restarts once the mount tracks."
                ),
            };
        }
    }

    let trigger_state = recovery_trigger_state(trigger_manager).await;
    let trigger_state = trigger_state.as_ref();
    let outcome = reacquire_guide_star(device_ops, mount_id, trigger_state).await;
    match (&outcome, trigger_state) {
        (AttemptOutcome::Succeeded, Some(state)) => state.write().await.guide_recovery = None,
        (AttemptOutcome::Failed { .. }, _) => {
            record_guide_recovery_failure(device_ops, mount_id, trigger_state).await;
        }
        _ => {}
    }
    outcome
}

async fn reacquire_guide_star(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    trigger_state: Option<&Arc<RwLock<crate::triggers::TriggerState>>>,
) -> crate::recovery::AttemptOutcome {
    use crate::recovery::AttemptOutcome;

    // Honour an existing lock, but only one that is holding the star:
    // `is_guiding` alone stays true while PHD2 chases a star it has lost.
    // Issuing guider_start when already guiding can force an unnecessary
    // re-calibration on some setups.
    if let Ok(status) = device_ops.guider_get_status().await {
        if guiding_is_settled(&status) {
            return AttemptOutcome::Succeeded;
        }
        if status.is_guiding {
            tracing::warn!(
                "[RECOVERY] Guider reports guiding but RMS is {:.1} px (limit {:.1} px) — \
                 treating it as not guiding and re-acquiring",
                status.rms_total,
                REACQUIRE_SETTLE_PIXELS
            );
        }
    }

    if let Some(arcmin) = recovery_displacement_arcmin(device_ops, mount_id, trigger_state).await {
        if arcmin > RECOVERY_MAX_DISPLACEMENT_ARCMIN {
            if let Err(e) = device_ops.guider_stop().await {
                tracing::warn!("[RECOVERY] The guider did not stop: {e}");
            }
            return AttemptOutcome::Failed {
                message: displaced_message(arcmin),
            };
        }
    }

    let reference = match trigger_state {
        Some(state) => state.read().await.guide_star_reference,
        None => None,
    };
    let floor = crate::GuideStarFloor::for_recovery(reference);

    // Issue a real re-acquisition on a star picked from a fresh frame: PHD2's
    // guide RPC keeps the lock position it had, which after a move is empty
    // sky. The start can return Ok before the lock is truly settled, so we
    // verify below.
    if let Err(e) = crate::instructions::start_guiding_on_fresh_star_above(
        device_ops,
        Some(floor),
        REACQUIRE_SETTLE_PIXELS,
        REACQUIRE_SETTLE_TIME_SECS,
        REACQUIRE_SETTLE_TIMEOUT_SECS,
    )
    .await
    {
        return AttemptOutcome::Failed {
            message: match e {
                crate::instructions::GuidingStartError::NoStar(e) => {
                    format!("Guide-star re-acquisition found no star: {}", e)
                }
                crate::instructions::GuidingStartError::Start(e) => {
                    format!("Guide-star re-acquisition (guider_start) failed: {}", e)
                }
            },
        };
    }

    let deadline = tokio::time::Instant::now()
        + std::time::Duration::from_secs_f64(REACQUIRE_SETTLE_TIMEOUT_SECS);
    while tokio::time::Instant::now() < deadline {
        if let Some(arcmin) =
            recovery_displacement_arcmin(device_ops, mount_id, trigger_state).await
        {
            if arcmin > RECOVERY_MAX_DISPLACEMENT_ARCMIN {
                if let Err(e) = device_ops.guider_stop().await {
                    tracing::warn!("[RECOVERY] The guider did not stop: {e}");
                }
                return AttemptOutcome::Failed {
                    message: displaced_message(arcmin),
                };
            }
        }
        match device_ops.guider_get_status().await {
            // Settled, not merely stepping. `rms_total` is in guide-camera
            // pixels, the unit of `REACQUIRE_SETTLE_PIXELS`.
            Ok(status) if guiding_is_settled(&status) => {
                if let Ok(Some(star)) = device_ops.guider_star_quality().await {
                    if !floor.accepts(&star) {
                        if let Err(e) = device_ops.guider_stop().await {
                            tracing::warn!("[RECOVERY] The guider did not stop: {e}");
                        }
                        return AttemptOutcome::Failed {
                            message: format!(
                                "The guider locked on a source far fainter than the run's guide \
                                 star (SNR {:.1}, mass {:.0}; the least accepted is SNR {:.1}, \
                                 mass {:.0}); guiding was stopped so it does not follow noise",
                                star.snr, star.star_mass, floor.min_snr, floor.min_star_mass
                            ),
                        };
                    }
                }
                tracing::info!(
                    "Guide star re-acquired: guiding settled (RMS total={:.2} px)",
                    status.rms_total
                );
                return AttemptOutcome::Succeeded;
            }
            Ok(_) => {
                // Not guiding, or guiding but not yet inside the settle bound;
                // keep polling until the deadline.
            }
            Err(e) => {
                // Transient status-read failure (e.g. PHD2 mid-calibration);
                // keep polling rather than aborting on a single bad read.
                tracing::warn!("Guide re-acquire status poll failed: {}", e);
            }
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }

    AttemptOutcome::Failed {
        message: format!(
            "Guiding did not settle within {:.1} px in the {:.0}s after re-acquisition",
            REACQUIRE_SETTLE_PIXELS, REACQUIRE_SETTLE_TIMEOUT_SECS
        ),
    }
}

/// Whether the sky reads safe right now for a weather hold: the app's verdict
/// is not acted on as UNSAFE and the hardware safety reading is safe. `Err`
/// carries what still reads unsafe.
///
/// A rig with no safety monitor answers the hardware poll with an error, which
/// is resolved through the fail mode exactly as the trigger monitor resolves
/// it; treating that error as "still unsafe" kept a run on a rig without a
/// monitor held for good once its verdict had cleared.
pub(crate) async fn weather_sky_check(
    device_ops: &SharedDeviceOps,
    trigger_manager: &Arc<RwLock<TriggerManager>>,
) -> Result<(), String> {
    let state = trigger_manager.read().await.state();
    let (verdict_unsafe, advisory, hardware_safe_before, fail_mode) = {
        let guard = state.read().await;
        (
            guard.weather_verdict_counts_unsafe(),
            guard.weather_verdict_advisory,
            guard.weather_safe,
            guard.safety_fail_mode,
        )
    };
    if verdict_unsafe {
        return Err(if advisory {
            "The weather forecast still reports clouds".to_string()
        } else {
            "The app's weather check still reports unsafe".to_string()
        });
    }
    let hardware_safe = match device_ops.safety_is_safe(None).await {
        Ok(safe) => safe,
        Err(error) => match safety_fail_mode_no_data_resolution(fail_mode) {
            NoDataResolution::Safe => true,
            NoDataResolution::Preserve => hardware_safe_before,
            NoDataResolution::Unsafe => {
                return Err(format!("Weather poll failed: {error}"));
            }
        },
    };
    if hardware_safe {
        Ok(())
    } else {
        Err("The safety monitor still reports unsafe".to_string())
    }
}

/// One check of a weather hold: the sky must have read safe without a break
/// for `resume_after_secs` before the hold ends, unless the operator has said
/// the sky is clear. `safe_since` carries the start of the current safe
/// stretch between checks.
pub(crate) async fn weather_hold_attempt(
    device_ops: &SharedDeviceOps,
    trigger_manager: &Arc<RwLock<TriggerManager>>,
    safe_since: &mut Option<std::time::Instant>,
    resume_after_secs: u64,
) -> crate::recovery::AttemptOutcome {
    use crate::recovery::AttemptOutcome;
    if let Err(message) = weather_sky_check(device_ops, trigger_manager).await {
        *safe_since = None;
        return AttemptOutcome::Failed { message };
    }
    let operator_clear = {
        let state = trigger_manager.read().await.state();
        let active = state.read().await.weather_operator_clear_active();
        active
    };
    let since = *safe_since.get_or_insert_with(std::time::Instant::now);
    let safe_for = since.elapsed().as_secs();
    if operator_clear || safe_for >= resume_after_secs {
        AttemptOutcome::Succeeded
    } else {
        AttemptOutcome::Failed {
            message: format!(
                "The sky reads safe; imaging resumes after it has stayed safe for {} min \
                 ({} s to go)",
                resume_after_secs.div_ceil(60).max(1),
                resume_after_secs - safe_for
            ),
        }
    }
}

/// Recovery Mode — execute a single recovery attempt for the given
/// cause and report the outcome. Stays out of the executor methods so the
/// recovery driver task can call it without holding the executor lock.
///
/// The dispatch is intentionally conservative: for `GuideStarLost`,
/// `MountTrackingLost`, and `WeatherUnsafe` we re-check the live device
/// status; for `SlewFailed` / `PlateSolveFailed` we re-issue the original
/// operation (the call site retains the necessary context). For now the
/// majority of failure modes use a status re-check as the recovery — the
/// underlying assumption is that the trigger only fired because the
/// condition became unsafe, so polling once after the wait window is the
/// right "try again" gesture. Future patches can expand each arm with
/// fully-blown recovery flows (e.g. re-slew + re-solve + re-acquire) when
/// the relevant context plumbing arrives.
pub(crate) async fn run_recovery_attempt(
    cause: &crate::recovery::RecoveryCause,
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    device_ids: &[String],
    trigger_manager: &Arc<RwLock<TriggerManager>>,
) -> crate::recovery::AttemptOutcome {
    use crate::recovery::AttemptOutcome;
    use crate::recovery::RecoveryCause;

    match cause {
        RecoveryCause::GuideStarLost => {
            recover_guide_star(device_ops, mount_id, Some(trigger_manager)).await
        }
        RecoveryCause::MountTrackingLost => match mount_id {
            // Parking stops tracking, so an operator who parks mid-run trips
            // this cause too. A park is a safe state someone chose; switching
            // tracking back on under the park latch and calling the run
            // recovered is exactly what `restore_tracking_after_recovery`
            // refuses to do, so hold the run for a human instead.
            Some(id) if matches!(device_ops.mount_is_parked(id).await, Ok(true)) => {
                AttemptOutcome::PauseForOperator {
                    message: format!(
                        "Mount {} is parked, so its tracking stopped. Recovery does not \
                         un-park a mount on its own; the run is paused. Un-park the mount \
                         and resume when you are ready.",
                        id
                    ),
                }
            }
            Some(id) => match device_ops.mount_is_tracking(id).await {
                Ok(true) => AttemptOutcome::Succeeded,
                Ok(false) => {
                    // Try to re-enable tracking. If the mount accepts the
                    // command we declare success and let the next loop
                    // iteration verify; if it errors, surface the error.
                    match device_ops.mount_set_tracking(id, true).await {
                        Ok(()) => {
                            // Verify the change took.
                            match device_ops.mount_is_tracking(id).await {
                                Ok(true) => AttemptOutcome::Succeeded,
                                Ok(false) => AttemptOutcome::Failed {
                                    message: "Mount tracking did not re-engage".to_string(),
                                },
                                Err(e) => AttemptOutcome::Failed {
                                    message: format!("Mount tracking re-check failed: {}", e),
                                },
                            }
                        }
                        Err(e) => AttemptOutcome::Failed {
                            message: format!("Mount tracking re-enable failed: {}", e),
                        },
                    }
                }
                Err(e) => AttemptOutcome::Failed {
                    message: format!("Mount tracking query failed: {}", e),
                },
            },
            None => AttemptOutcome::Failed {
                message: "No mount is configured; cannot recover tracking".to_string(),
            },
        },
        RecoveryCause::WeatherUnsafe => {
            match weather_sky_check(device_ops, trigger_manager).await {
                Ok(()) => AttemptOutcome::Succeeded,
                Err(message) => AttemptOutcome::Failed { message },
            }
        }
        RecoveryCause::FocusDriftCritical => {
            // Focus-drift recovery for now is "wait it out" — the next
            // periodic autofocus (already managed by the AutofocusInterval
            // trigger or the per-target Autofocus instruction) will lower
            // HFR if a real autofocus is due. We declare success after the
            // wait so the sequence resumes; the AutofocusInterval trigger
            // remains armed and will fire again if HFR is still high.
            AttemptOutcome::Succeeded
        }
        RecoveryCause::SlewFailed | RecoveryCause::PlateSolveFailed => {
            // Slew / plate-solve recovery is best handled by re-entering
            // the failed instruction. The driver releases `is_paused`
            // when it sees `Recovered`, and the node tree resumes from
            // where it stopped — the slew / center instruction will run
            // again. We return `Succeeded` after the wait so the driver
            // flips back to Running; the instruction's own retry logic
            // takes over.
            AttemptOutcome::Succeeded
        }
        RecoveryCause::ConsecutiveRejectsExceeded => {
            // A consecutive-reject storm (clouds rolling in, dew, focus
            // lost, vibration) is NOT something a fixed wait can prove
            // cleared — auto-resuming oscillated fail → wait →
            // "recovered" → fail on a fresh recovery budget, burning the
            // whole night capturing rejects and never converging. Escalate
            // to a real operator Pause instead: freeze the run and hand it
            // to the operator (matching the operator-pause / safe-state
            // path) rather than declaring an unverified success.
            AttemptOutcome::PauseForOperator {
                message: "Consecutive image-grading rejects exceeded the limit — \
                          sequence paused for inspection. Resume once conditions clear."
                    .to_string(),
            }
        }
        RecoveryCause::DeviceDisconnected => {
            if device_ids.is_empty() {
                // Terminal, not retryable. With no ids there is nothing to
                // reconnect and nothing to poll, so attempt 2 through 9 would
                // return this identical message — 90 minutes of an unattended
                // night spent in `recovering / Device disconnected` at
                // `progress 0.0`. Fail loudly on the first attempt instead.
                return AttemptOutcome::Unrecoverable {
                    message: "No devices are assigned to this run, so there is nothing to \
                              reconnect. The run cannot continue — assign the camera (and any \
                              other hardware the sequence uses) and start again."
                        .to_string(),
                };
            }

            // Actively drive a reconnect for each device. Polling
            // device_is_connected alone never recovers camera / focuser /
            // filter-wheel disconnects: those devices default to
            // auto_reconnect=false, so the background reconnection loop skips them
            // and the recovery budget burns reporting "still disconnected".
            // connect_device() flips auto_reconnect on AND issues an immediate
            // connect. A failed attempt is non-fatal — the is_connected
            // verification below decides the outcome.
            for device_id in device_ids {
                if let Err(e) = device_ops.connect_device(device_id).await {
                    tracing::warn!(
                        "[RECOVERY] connect_device('{}') attempt failed: {} (will verify state)",
                        device_id,
                        e
                    );
                }
            }

            for device_id in device_ids {
                match device_ops.device_is_connected(device_id).await {
                    Ok(true) => {}
                    Ok(false) => {
                        return AttemptOutcome::Failed {
                            message: format!("Device '{}' is still disconnected", device_id),
                        };
                    }
                    Err(e) => {
                        return AttemptOutcome::Failed {
                            message: format!(
                                "Device '{}' reconnect status query failed: {}",
                                device_id, e
                            ),
                        };
                    }
                }
            }

            AttemptOutcome::Succeeded
        }
        RecoveryCause::Custom(_) => {
            // Custom causes have no built-in recovery action — declare
            // success after the wait so the sequence resumes. Plugins /
            // scripts that surface custom causes are expected to handle
            // their own recovery upstream; the unified state machine
            // only provides the visible Recovering UX.
            AttemptOutcome::Succeeded
        }
    }
}

/// A guide-star retry cannot repair a mount stopped at its tracking limit.
/// Publish a hold for the monitor to adopt, using fresh driver telemetry even
/// when the ordinary tracking poll is deferring edges under recovery.
pub(crate) async fn hand_off_tracking_limit(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    manager: &Arc<RwLock<TriggerManager>>,
) -> bool {
    let Some(id) = mount_id else {
        return false;
    };
    if manager.read().await.active_meridian_flip_config().is_none() {
        return false;
    }
    if !matches!(
        bounded_poll("mount_is_tracking", device_ops.mount_is_tracking(id)).await,
        Ok(false)
    ) {
        return false;
    }
    let (Ok(false), Ok(false), Ok(crate::meridian::PierSide::West)) = (
        bounded_poll("mount_is_slewing", device_ops.mount_is_slewing(id)).await,
        bounded_poll("mount_is_parked", device_ops.mount_is_parked(id)).await,
        bounded_poll("mount_side_of_pier", device_ops.mount_side_of_pier(id)).await,
    ) else {
        return false;
    };
    let manager = manager.read().await;
    let lock = manager.state();
    let mut state = lock.write().await;
    // Never reinterpret tracking the run intentionally stopped as a limit.
    if state.run.is_held_by_run() || state.guiding.in_motion() {
        return false;
    }
    let mut candidate = state.clone();
    candidate.mount_is_tracking = Some(false);
    candidate.mount_slewing = Some(false);
    candidate.mount_parked = Some(false);
    candidate.pier_side = Some(crate::PierSide::West);
    candidate.mount_status_query_failed = false;
    candidate
        .tracking
        .record_loss(chrono::Utc::now().timestamp());
    if !crate::triggers::tracking_limit_recovery_candidate(&candidate) {
        return false;
    }
    *state = candidate;
    state
        .run
        .begin_hold(crate::triggers::RunHold::TrackingLimit);
    true
}
