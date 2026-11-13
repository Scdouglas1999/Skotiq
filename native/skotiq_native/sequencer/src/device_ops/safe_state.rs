//! Parking the mount and closing the cover and dome when a run abandons the rig.

use super::*;

/// Result of a park-with-retry attempt.
///
/// `attempts_made` counts the total invocations of `mount_park` (the initial
/// attempt plus retries), so callers can include the count in failure messages
/// surfaced to the operator.
#[derive(Debug, Clone)]
pub struct ParkRetryResult {
    /// Whether the mount was successfully parked.
    pub success: bool,
    /// Total number of park-call attempts made (initial + retries).
    pub attempts_made: u32,
    /// Last error reported by `mount_park`, present iff `success == false`.
    pub last_error: Option<String>,
}

/// Try to park the mount, retrying with a fixed delay between attempts.
///
/// The single source of truth for park retries, shared by the executor's
/// `RecoveryAction::ParkAndAbort` and `Recovery::ParkAndAbort` in `node.rs`,
/// so both report a park failure specifically in their failure events.
///
/// `max_retries` counts attempts AFTER the initial call — `0` means try once —
/// so the total number of park calls is `1 + max_retries`. `retry_delay_secs`
/// is slept with `tokio::time::sleep` so the caller's runtime cancellation
/// still works.
pub async fn try_park_with_retry(
    device_ops: &(impl MountOps + SiteOps + OperatorNotifyOps + ?Sized),
    mount_id: &str,
    max_retries: u32,
    retry_delay_secs: f64,
) -> ParkRetryResult {
    let total_attempts = max_retries.saturating_add(1);
    let mut last_error: Option<String> = None;

    for attempt in 1..=total_attempts {
        // Stop the axes before asking for the park. Some mounts refuse a park
        // while slewing (`meridian_flip_executor` already aborts first for
        // exactly this reason); this helper is the safety-abort path, so a park
        // issued mid-slew must not be allowed to fail all of its attempts and
        // leave the mount unparked. Best-effort: drivers that do not implement
        // abort, or that reject it when idle, still get their park attempt.
        if let Err(e) = device_ops.mount_abort_slew(mount_id).await {
            tracing::debug!(
                "mount_abort_slew({}) before park attempt {} failed: {} — parking anyway",
                mount_id,
                attempt,
                e
            );
        }
        let start = device_ops.mount_get_coordinates(mount_id).await.ok();
        match device_ops.mount_park(mount_id).await {
            Ok(()) => {
                // A mount stuck at an axis limit takes the park and stays put:
                // move it off the limit and park again.
                if !crate::limit_backoff::mount_responds(
                    device_ops,
                    mount_id,
                    start,
                    tokio::time::Instant::now(),
                    crate::limit_backoff::RESPONSE_WINDOW,
                    true,
                )
                .await
                {
                    let site_longitude = device_ops.get_observer_location().map(|(_, lon)| lon);
                    let freed =
                        crate::limit_backoff::back_off_limit(device_ops, mount_id, site_longitude)
                            .await;
                    crate::limit_backoff::notify(device_ops, "park", &freed).await;
                    if freed.is_ok() {
                        if let Err(e) = device_ops.mount_park(mount_id).await {
                            last_error = Some(e.to_string());
                            continue;
                        }
                    }
                }
                if attempt == 1 {
                    tracing::info!("mount_park({}) succeeded on initial attempt", mount_id);
                } else {
                    tracing::info!(
                        "mount_park({}) succeeded on attempt {}/{}",
                        mount_id,
                        attempt,
                        total_attempts
                    );
                }
                return ParkRetryResult {
                    success: true,
                    attempts_made: attempt,
                    last_error: None,
                };
            }
            Err(e) => {
                tracing::error!(
                    "mount_park({}) FAILED on attempt {}/{}: {}",
                    mount_id,
                    attempt,
                    total_attempts,
                    e
                );
                last_error = Some(e.to_string());
                if attempt < total_attempts && retry_delay_secs > 0.0 {
                    tokio::time::sleep(std::time::Duration::from_secs_f64(
                        retry_delay_secs.max(0.0),
                    ))
                    .await;
                }
            }
        }
    }

    tracing::error!(
        "mount_park({}) exhausted {} attempt{}; last error: {:?}. \
         Mount may be in an unsafe position!",
        mount_id,
        total_attempts,
        if total_attempts == 1 { "" } else { "s" },
        last_error
    );
    ParkRetryResult {
        success: false,
        attempts_made: total_attempts,
        last_error,
    }
}

/// Outcome of a [`park_and_close_safe_state`] sweep.
///
/// Each field captures the result of one safe-state step so the caller can
/// word its own event-stream message while the *sequence of device calls*
/// itself is centralised. A `None` cover/dome error
/// means "that device was absent or closed cleanly"; `Some(err)` means the
/// close was attempted and the driver returned an error.
#[derive(Debug, Clone)]
pub struct SafeStateOutcome {
    /// Park result, present iff a `mount_id` was supplied. `None` means no
    /// mount was configured, so the caller should surface its own
    /// "cannot park" message.
    pub park: Option<ParkRetryResult>,
    /// Error returned by `cover_calibrator_close_cover`, if a cover was
    /// configured and the close failed.
    pub cover_close_error: Option<String>,
    /// Error returned by `dome_close`, if a dome was configured and the
    /// close failed.
    pub dome_close_error: Option<String>,
}

/// Drive the rig into a SAFE end-state: park the mount, then close the
/// flat-panel cover, then close the dome shutter — in that order.
///
/// This is the single source of truth for the "abandon the rig safely"
/// sequence that fires from three executor paths:
///   1. `RecoveryAction::ParkAndAbort` (weather/safety trigger termination),
///   2. recovery loop give-up (attempts/time budget exhausted), and
///   3. meridian-flip `AbortAndPark` failure handling.
///
/// Why the strict order: parking first stops the OTA tracking toward a limit /
/// the Sun at dawn; closing the cover before the dome protects the optics; the
/// dome shutter closes last so the scope is never left exposed under an open
/// roof. Leaving any of these undone re-exposes the rig to the exact condition
/// (rain / cloud / dawn) that triggered the safe-state in the first place.
///
/// Each step is best-effort and independent: a park failure does NOT skip the
/// cover/dome closes (the roof must close even if the mount is stuck). The
/// returned [`SafeStateOutcome`] reports every step so the caller can emit its
/// own operator-facing error events.
///
/// # Arguments
/// * `device_ops` - Shared device operations handle.
/// * `mount_id` - The mount to park, or `None` if no mount is configured.
/// * `cover_id` - The cover-calibrator to close, or `None`.
/// * `dome_id` - The dome to close, or `None`.
/// * `park_max_retries` / `park_retry_delay_secs` - forwarded to
///   [`try_park_with_retry`]; the give-up path passes 2 retries, the
///   ParkAndAbort path 1.
pub async fn park_and_close_safe_state(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    cover_id: Option<&str>,
    dome_id: Option<&str>,
    park_max_retries: u32,
    park_retry_delay_secs: f64,
) -> SafeStateOutcome {
    let park = match mount_id {
        Some(id) => Some(
            try_park_with_retry(&**device_ops, id, park_max_retries, park_retry_delay_secs).await,
        ),
        None => None,
    };

    let cover_close_error = match cover_id {
        Some(id) => device_ops
            .cover_calibrator_close_cover(id)
            .await
            .err()
            .map(|e| e.to_string()),
        None => None,
    };

    // Closing the dome is the most safety-critical step of the sweep: it is the
    // last barrier between the optics and the open sky. Issuing `dome_close` and
    // returning would report the rig "safe" while the shutter sits jammed
    // half-open, so the close is followed by polling the shutter until it
    // confirms "Closed" (bounded timeout, mirroring
    // `instructions::wait_for_dome_shutter_state`). Any outcome that is not a
    // confirmed Closed records a `dome_close_error`, which the give-up path
    // surfaces to the operator.
    let dome_close_error = match dome_id {
        Some(id) => match device_ops.dome_close(id).await {
            Err(e) => Some(e.to_string()),
            Ok(()) => verify_dome_closed(&**device_ops, id).await.err(),
        },
        None => None,
    };

    SafeStateOutcome {
        park,
        cover_close_error,
        dome_close_error,
    }
}

/// Maximum time to wait for the dome shutter to confirm `Closed` during the
/// unattended safe-state sweep. Mirrors `DOME_SHUTTER_TIMEOUT_SECS` in
/// `instructions.rs` (observatory shutters are slow: 30–90 s is typical).
const SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS: f64 = 120.0;

/// Poll the dome shutter after a `dome_close` until it confirms `Closed`, or
/// return `Err` describing why the close could NOT be confirmed.
///
/// This mirrors `instructions::wait_for_dome_shutter_state` but is intentionally
/// STRICTER for the abandon-the-rig sweep: where the per-instruction path
/// tolerates a roll-off roof that cannot report shutter position (it degrades
/// loudly and proceeds), this path treats a never-confirmed close as unsafe.
/// When the rig is being abandoned for the night, "the roof might be open" is
/// not an acceptable end-state — the operator must be told.
///
/// * A read error (driver fault / disconnect) → unsafe (cannot verify).
/// * A definite state that never reaches `Closed` within the timeout → a real
///   motor/jam failure → unsafe.
/// * The dome never reports a definite state (cannot report position) →
///   unconfirmed → unsafe for this sweep.
async fn verify_dome_closed(
    device_ops: &(impl DomeOps + ?Sized),
    dome_id: &str,
) -> Result<(), String> {
    const POLL_SECS: f64 = 2.0;
    let mut elapsed = 0.0_f64;
    let mut saw_definite_state = false;

    loop {
        match device_ops.dome_get_shutter_status(dome_id).await {
            Ok(status) => {
                if status == "Closed" {
                    return Ok(());
                }
                if status == "Open"
                    || status == "Closed"
                    || status == "Opening"
                    || status == "Closing"
                {
                    saw_definite_state = true;
                }
            }
            Err(e) => {
                return Err(format!(
                    "could not read dome '{}' shutter status to confirm Closed: {} — \
                     scope may be exposed",
                    dome_id, e
                ));
            }
        }

        if elapsed >= SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS {
            if saw_definite_state {
                return Err(format!(
                    "dome '{}' shutter did not reach Closed within {:.0}s — \
                     shutter may be jammed; scope may be exposed",
                    dome_id, SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS
                ));
            }
            return Err(format!(
                "dome '{}' shutter status never reported a definite state — \
                 cannot confirm the roof is closed; scope may be exposed",
                dome_id
            ));
        }

        tokio::time::sleep(std::time::Duration::from_secs_f64(POLL_SECS)).await;
        elapsed += POLL_SECS;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc as StdArc;

    /// A DeviceOps wrapper that fails `mount_park` a configurable number of
    /// times before succeeding. Used by the retry-helper tests.
    struct FlakyParkOps {
        inner: StdArc<NullDeviceOps>,
        fail_count: AtomicU32,
        attempts: AtomicU32,
        fail_forever: bool,
        /// Models the driver class that rejects a park while the axes are still
        /// turning (ASCOM `InvalidOperationException`, INDI property reject).
        /// `mount_abort_slew` is the only thing that clears it.
        slewing: std::sync::atomic::AtomicBool,
    }

    impl FlakyParkOps {
        fn new(fail_count: u32, fail_forever: bool) -> Self {
            Self {
                inner: StdArc::new(NullDeviceOps),
                fail_count: AtomicU32::new(fail_count),
                attempts: AtomicU32::new(0),
                fail_forever,
                slewing: std::sync::atomic::AtomicBool::new(false),
            }
        }

        /// A mount that is mid-slew when the safety park arrives.
        fn slewing() -> Self {
            let ops = Self::new(0, false);
            ops.slewing.store(true, Ordering::SeqCst);
            ops
        }

        fn attempts(&self) -> u32 {
            self.attempts.load(Ordering::SeqCst)
        }
    }

    #[async_trait]
    impl MountOps for FlakyParkOps {
        async fn mount_abort_slew(&self, _mount_id: &str) -> DeviceResult<()> {
            self.slewing.store(false, Ordering::SeqCst);
            Ok(())
        }

        async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
            self.attempts.fetch_add(1, Ordering::SeqCst);
            if self.slewing.load(Ordering::SeqCst) {
                return Err(format!("{} cannot park while slewing", mount_id).into());
            }
            if self.fail_forever {
                return Err(format!("simulated park failure for {}", mount_id).into());
            }
            let remaining = self.fail_count.load(Ordering::SeqCst);
            if remaining > 0 {
                self.fail_count.fetch_sub(1, Ordering::SeqCst);
                return Err(format!(
                    "simulated park failure for {} ({} failures remaining)",
                    mount_id, remaining
                )
                .into());
            }
            Ok(())
        }

        async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
            self.inner.mount_slew_to_coordinates(id, ra, dec).await
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

    crate::forward_device_ops!(FlakyParkOps => inner: CameraOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

    /// A DeviceOps wrapper that accepts `dome_close` (returns Ok) but reports a
    /// configurable shutter status forever — used to prove the safe-state sweep
    /// VERIFIES the shutter actually reached Closed rather than trusting the
    /// fire-and-forget close. `mount_park`, `dome_close`, and
    /// `cover_calibrator_close_cover` all succeed so the dome step is the only
    /// variable under test.
    struct StuckShutterOps {
        inner: StdArc<NullDeviceOps>,
        /// Status returned by every `dome_get_shutter_status` poll. Set to
        /// "Open" to simulate a jam (definite state, never Closed) or "Unknown"
        /// to simulate a roof that cannot report position.
        shutter_status: String,
        /// When true, every `dome_get_shutter_status` poll returns Err to
        /// simulate a driver fault / disconnect during verification.
        read_fails: bool,
    }

    impl StuckShutterOps {
        fn new(shutter_status: &str, read_fails: bool) -> Self {
            Self {
                inner: StdArc::new(NullDeviceOps),
                shutter_status: shutter_status.to_string(),
                read_fails,
            }
        }
    }

    #[async_trait]
    impl MountOps for StuckShutterOps {
        // Park + cover close cleanly so the dome is the only failing step.
        async fn mount_park(&self, _id: &str) -> DeviceResult<()> {
            Ok(())
        }

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

    #[async_trait]
    impl DomeOps for StuckShutterOps {
        async fn dome_close(&self, _id: &str) -> DeviceResult<()> {
            // The command is "accepted" — exactly the deceptive case: the
            // driver says OK while the shutter never actually closes.
            Ok(())
        }
        async fn dome_get_shutter_status(&self, _id: &str) -> DeviceResult<String> {
            if self.read_fails {
                return Err("simulated shutter-status read failure".into());
            }
            Ok(self.shutter_status.clone())
        }
        async fn dome_open(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_open(id).await
        }
        async fn dome_park(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_park(id).await
        }
    }

    #[async_trait]
    impl CoverCalibratorOps for StuckShutterOps {
        async fn cover_calibrator_close_cover(&self, _id: &str) -> DeviceResult<()> {
            Ok(())
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

    crate::forward_device_ops!(StuckShutterOps => inner: CameraOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, SafetyOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

    /// The unattended safe-state sweep VERIFIES the dome shutter actually
    /// reached Closed: a shutter that accepts the close command but jams
    /// half-open (reports "Open" forever) must record a `dome_close_error`,
    /// otherwise the rig is reported safe while the scope sits under an open
    /// roof.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_on_jammed_shutter() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Open", false));
        let outcome = park_and_close_safe_state(
            &ops,
            Some("mount-1"),
            Some("cover-1"),
            Some("dome-1"),
            1,
            0.0,
        )
        .await;
        assert!(
            outcome.dome_close_error.is_some(),
            "a shutter that never reaches Closed must record a dome_close_error"
        );
        assert!(
            outcome
                .dome_close_error
                .as_deref()
                .unwrap()
                .contains("jammed")
                || outcome
                    .dome_close_error
                    .as_deref()
                    .unwrap()
                    .contains("did not reach Closed"),
            "the error must explain the shutter never closed: {:?}",
            outcome.dome_close_error
        );
        // The park + cover steps still succeeded — only the dome is unsafe.
        assert!(outcome.park.as_ref().map(|p| p.success).unwrap_or(false));
        assert!(outcome.cover_close_error.is_none());
    }

    /// A roof that can never report shutter position (every poll "Unknown")
    /// is also reported unsafe by the sweep — for an abandoned rig, "the roof
    /// might be open" is not an acceptable end-state. (The per-instruction
    /// path tolerates this and proceeds; the abandon sweep is intentionally
    /// stricter.)
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_on_unconfirmable_shutter() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Unknown", false));
        let outcome = park_and_close_safe_state(&ops, None, None, Some("dome-1"), 1, 0.0).await;
        assert!(
            outcome.dome_close_error.is_some(),
            "an unconfirmable shutter must record a dome_close_error"
        );
    }

    /// A shutter-status read fault during verification is also unsafe — we
    /// cannot confirm Closed, so we must not claim safety.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_when_shutter_read_fails() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("", true));
        let outcome = park_and_close_safe_state(&ops, None, None, Some("dome-1"), 1, 0.0).await;
        assert!(outcome.dome_close_error.is_some());
    }

    /// Control: a healthy shutter that reaches Closed records NO
    /// dome_close_error — the verification must not flag a working dome.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_healthy_shutter_reports_no_error() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Closed", false));
        let outcome = park_and_close_safe_state(
            &ops,
            Some("mount-1"),
            Some("cover-1"),
            Some("dome-1"),
            1,
            0.0,
        )
        .await;
        assert!(
            outcome.dome_close_error.is_none(),
            "a healthy shutter that reaches Closed must not record an error: {:?}",
            outcome.dome_close_error
        );
        assert!(outcome.park.as_ref().is_some_and(|p| p.success));
        assert!(outcome.cover_close_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_succeeds_first_attempt() {
        let ops: SharedDeviceOps = Arc::new(FlakyParkOps::new(0, false));
        let result = try_park_with_retry(&*ops, "mount-1", 3, 0.0).await;
        assert!(result.success);
        assert_eq!(result.attempts_made, 1);
        assert!(result.last_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_recovers_after_retries() {
        let ops_concrete = Arc::new(FlakyParkOps::new(2, false));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&*ops, "mount-1", 3, 0.0).await;
        assert!(result.success, "should succeed after 2 failures");
        assert_eq!(result.attempts_made, 3);
        assert_eq!(ops_concrete.attempts(), 3);
        assert!(result.last_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_gives_up_after_exhausting_attempts() {
        let ops_concrete = Arc::new(FlakyParkOps::new(0, true));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&*ops, "mount-1", 2, 0.0).await;
        assert!(!result.success);
        // max_retries=2 means total 3 attempts (initial + 2 retries).
        assert_eq!(result.attempts_made, 3);
        assert_eq!(ops_concrete.attempts(), 3);
        assert!(result.last_error.is_some());
    }

    #[tokio::test]
    async fn try_park_with_retry_zero_retries_means_one_attempt() {
        let ops_concrete = Arc::new(FlakyParkOps::new(0, true));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&*ops, "mount-1", 0, 0.0).await;
        assert!(!result.success);
        assert_eq!(result.attempts_made, 1);
        assert_eq!(ops_concrete.attempts(), 1);
    }

    /// The safety park must stop the axes before it asks for the park.
    ///
    /// This is the emergency-park path (weather abort, recovery
    /// `ParkAndAbort`), and it is routinely reached with a slew in flight.
    /// Mounts that refuse a park while slewing therefore rejected every
    /// attempt and the mount was left unparked — `meridian_flip_executor`
    /// already aborts first for exactly this reason, this path did not.
    /// Zero retries so the abort, not a lucky retry, is what makes it succeed.
    #[tokio::test]
    async fn try_park_with_retry_stops_the_slew_before_parking() {
        let ops_concrete = Arc::new(FlakyParkOps::slewing());
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&*ops, "mount-1", 0, 0.0).await;
        assert!(
            result.success,
            "a mount that refuses a park while slewing was left unparked by the \
             safety-park path: {:?}",
            result.last_error
        );
        assert_eq!(result.attempts_made, 1);
    }
}
