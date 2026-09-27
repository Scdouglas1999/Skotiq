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
pub(crate) fn guiding_is_settled(status: &crate::device_ops::GuidingStatus) -> bool {
    status.is_guiding && status.rms_total <= REACQUIRE_SETTLE_PIXELS
}

/// Actively re-acquire the guide star after a `GuideStarLost` event.
///
/// Merely *querying* `is_guiding` never tells the guider to find a star again,
/// so once a star is lost the recovery could only succeed if the guider
/// happened to re-lock on its own. This mirrors the lock-on logic in
/// `execute_start_guiding`: it issues `guider_start` (which, for PHD2, performs
/// auto-select + calibrate-if-needed + guide, i.e. a real re-acquisition) and
/// then polls `guider_get_status` until guiding is confirmed within a bounded
/// deadline. Fails closed (returns `AttemptOutcome::Failed`) on start error or
/// if the lock never re-establishes — the recovery driver then escalates per
/// the configured retry policy rather than silently resuming exposures on an
/// unguided mount.
pub(crate) async fn recover_guide_star(
    device_ops: &SharedDeviceOps,
) -> crate::recovery::AttemptOutcome {
    use crate::recovery::AttemptOutcome;

    // Fast-path: maybe the guider already recovered on its own during the
    // recovery wait window. Issuing guider_start when already guiding can force
    // an unnecessary re-calibration on some setups, so honour an existing lock —
    // but only a lock that is actually holding the star.
    //
    // `is_guiding` alone is not that. PHD2 reports guiding for as long as it is
    // emitting GuideStep frames, including while it chases a star it has
    // effectively lost: measured on the owner's rig at RA/Dec offsets of
    // -56.8 / -54.4 px with SNR collapsed 126.7 → 11.8 and StarMass
    // 2,962,797 → 5,902, all of it reported as `is_guiding: true`. Accepting
    // that as recovered declares success, resumes the run and trails every
    // frame.
    //
    // The bar is the one this function already applies to its own
    // re-acquisition below — settled inside `REACQUIRE_SETTLE_PIXELS` — so the
    // fast path cannot hold a worse situation to a laxer standard than a fresh
    // start.
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

    // Issue a real re-acquisition. guider_start re-selects a guide star and
    // (re)starts guiding; it can return Ok before the lock is truly settled, so
    // we verify below.
    if let Err(e) = device_ops
        .guider_start(
            REACQUIRE_SETTLE_PIXELS,
            REACQUIRE_SETTLE_TIME_SECS,
            REACQUIRE_SETTLE_TIMEOUT_SECS,
        )
        .await
    {
        return AttemptOutcome::Failed {
            message: format!("Guide-star re-acquisition (guider_start) failed: {}", e),
        };
    }

    let deadline = tokio::time::Instant::now()
        + std::time::Duration::from_secs_f64(REACQUIRE_SETTLE_TIMEOUT_SECS);
    while tokio::time::Instant::now() < deadline {
        match device_ops.guider_get_status().await {
            // Settled, not merely stepping. `rms_total` is in guide-camera
            // PIXELS (PHD2 `RADistanceRaw`/`DECDistanceRaw`, quadrature-summed
            // — see `Phd2GuideStats`), which is the same unit
            // `REACQUIRE_SETTLE_PIXELS` and the GuidingFailed trigger's
            // threshold are in. The old log line called it arcseconds.
            Ok(status) if guiding_is_settled(&status) => {
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
        RecoveryCause::GuideStarLost => recover_guide_star(device_ops).await,
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
            // Fail-closed recovery gate. A weather abort can be tripped by EITHER the
            // hardware safety device (`safety_is_safe`) OR the Dart-side verdict (API
            // alert / configured threshold / park-before-dawn), so resuming requires
            // BOTH to be clear: the hardware poll must read safe AND the Dart verdict
            // must not be `Some(true)`. Re-checking the hardware boolean alone declares
            // a Dart-threshold-only abort "recovered" the instant the hardware reads
            // safe, resuming into API-unsafe weather. `Some(false)` (Dart explicitly
            // safe) and `None` (Dart abstains) both permit resume — they cannot pin the
            // sequence paused, so this only ever adds an unsafe source.
            let verdict_unsafe = {
                let state = trigger_manager.read().await.state();
                let guard = state.read().await;
                guard.weather_verdict_unsafe == Some(true)
            };
            if verdict_unsafe {
                AttemptOutcome::Failed {
                    message: "Weather still unsafe (Dart verdict reports unsafe)".to_string(),
                }
            } else {
                match device_ops.safety_is_safe(None).await {
                    Ok(true) => AttemptOutcome::Succeeded,
                    Ok(false) => AttemptOutcome::Failed {
                        message: "Weather still unsafe".to_string(),
                    },
                    Err(e) => AttemptOutcome::Failed {
                        message: format!("Weather poll failed: {}", e),
                    },
                }
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
