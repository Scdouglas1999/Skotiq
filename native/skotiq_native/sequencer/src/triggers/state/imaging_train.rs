//! The imaging train (main camera and filter wheel) as one exclusive claim
//! between the capture loop and the trigger actions.

use super::TriggerState;
use crate::RecoveryAction;
use chrono::Utc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Extra time past the end of an exposure during which the camera still counts
/// as busy, covering sensor readout and download. Generous on purpose: the
/// cost of over-waiting is that a trigger-fired autofocus starts a few seconds
/// late, and the cost of under-waiting is a destroyed frame and a dead run.
pub const CAMERA_BUSY_DOWNLOAD_SLACK_SECS: f64 = 20.0;

/// How far past its own expected finish an imaging-train claim survives before
/// the token self-heals back to free.
///
/// This is deliberately NOT the same number as
/// [`CAMERA_BUSY_DOWNLOAD_SLACK_SECS`], and keeping them apart is the fix for a
/// measured defect. The old claim had one deadline doing both jobs: `exposure
/// duration + 20 s` was simultaneously the estimate a waiter read AND the
/// instant the token became free. So a 180 s light whose readout ran a little
/// long handed the camera to a waiting trigger while the sensor was still
/// integrating. The trigger then started its own 5 s plate-solve exposure on a
/// busy camera and failed on a timeout of its own request plus margin —
/// `Exposure on native:zwo:1 did not complete within 65.0s timeout` — a number
/// with no relationship to the 180 s frame it was actually queued behind.
///
/// An estimate that is slightly wrong must not transfer ownership. So the
/// expected finish is what a waiter reads to size its wait, and the hard expiry
/// sits this much further out: long enough that no plausible readout, settle or
/// USB stall releases the devices under their holder, short enough that a
/// holder that panicked without releasing costs minutes rather than the night.
pub const IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS: f64 = 300.0;

/// An exclusive claim on the IMAGING TRAIN: the main camera and the filter
/// wheel, arbitrated as one resource.
///
/// The two devices are one claim because every operation that contends for
/// them takes both. The capture loop sets a filter and then exposes through it;
/// a trigger-fired autofocus sets its own filter and then exposes through that;
/// a meridian flip re-solves and restores the filter. Arbitrating the camera
/// alone is what produced the 2026-09-14 failure: the autofocus trigger held
/// the camera and commanded the wheel to "L" (position 0), the capture loop —
/// blocked on the camera but having already commanded the wheel for its own
/// frame — left it at "SII" (position 5), and autofocus then polled a healthy,
/// idle, responsive wheel for 120 s waiting for a position nothing was going to
/// move it to. The wheel was never broken; the arbitration was.
///
/// Borrowing is allowed and expected — an autofocus needs the wheel mid-burst —
/// but a holder that moves the wheel MUST put it back before releasing, because
/// the capture loop sets its filter once per burst and expects it to still be
/// there for the next frame. `execute_autofocus_once` does this; so does the
/// meridian-flip executor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImagingTrainClaim {
    /// Identity of this claim. A release only takes effect if it presents the
    /// token that is currently installed, so a late or duplicated release
    /// cannot free somebody else's claim — which would destroy exactly the
    /// frame the claim exists to protect.
    pub token: u64,
    /// Operator-facing name of the holder ("the capture loop", "autofocus"),
    /// used in the hold messages a waiter logs.
    pub holder: &'static str,
    /// When the holder expects to be done, as Unix millis. This is the number a
    /// waiter reads to size its wait and its own device timeouts; it is NOT
    /// when the claim lapses.
    pub expected_finish_ms: i64,
    /// When the claim lapses regardless, as Unix millis: `expected_finish_ms`
    /// plus [`IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`]. Only the backstop for a
    /// holder that died without releasing — see that constant for why it is not
    /// the same instant as the expected finish.
    pub expires_at_ms: i64,
}

/// What a waiter learns about a claim it could not take.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ImagingTrainHold {
    /// Operator-facing name of the current holder.
    pub holder: &'static str,
    /// Seconds until the holder expects to be finished. Zero once that instant
    /// has passed but the claim has not yet been released — the holder is
    /// overrunning its estimate, which is precisely when the token must NOT
    /// change hands.
    pub expected_remaining_secs: f64,
    /// Seconds until the claim lapses on its own. This is the bound on how long
    /// a wait for this claim can last, derived from the in-flight operation
    /// rather than fixed.
    pub max_remaining_secs: f64,
}

/// Who holds the imaging train. Lives on the trigger state so the capture
/// loop and the trigger actions test and set it under the one lock they
/// already share.
#[derive(Debug, Clone, Default)]
pub struct ImagingTrain {
    /// The live claim, or `None` when the train is free.
    pub claim: Option<ImagingTrainClaim>,
    /// A live trigger guard owns the claim even when its time estimate expires.
    owner: Option<(u64, std::sync::Weak<()>)>,
    /// Counter behind [`ImagingTrainClaim::token`]. Never reused within a
    /// process, so a stale guard can never release a claim that has since
    /// been taken by someone else.
    next_token: u64,
}

impl ImagingTrain {
    /// Take the imaging train (camera + filter wheel) for an operation the
    /// holder expects to take `expected_secs`, if nobody else holds it.
    ///
    /// Returns the claim token on success and `None` when it is already held.
    /// Test-and-set happens under the single write lock the caller already
    /// holds, which is what makes it safe: two independent "is the other one
    /// busy?" flags cannot be tested and set without a race, and losing that
    /// race is what destroys a frame.
    ///
    /// `expected_secs` is an estimate and is allowed to be wrong. Being wrong
    /// delays a waiter's log line; it never transfers ownership. See
    /// [`IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`].
    pub fn try_claim(&mut self, holder: &'static str, expected_secs: f64) -> Option<u64> {
        if self.hold().is_some() {
            return None;
        }
        // Readout and download are part of the operation: the frame is not safe
        // the instant the shutter closes, and the download is exactly when the
        // destroyed-frame failure appeared, because that is when the capture
        // loop asks the camera for an image something else has already taken.
        let expected = if expected_secs.is_finite() && expected_secs > 0.0 {
            expected_secs + CAMERA_BUSY_DOWNLOAD_SLACK_SECS
        } else {
            CAMERA_BUSY_DOWNLOAD_SLACK_SECS
        };
        let now_ms = Utc::now().timestamp_millis();
        let expected_finish_ms = now_ms + (expected * 1000.0) as i64;
        let token = self.next_token.wrapping_add(1);
        self.next_token = token;
        self.claim = Some(ImagingTrainClaim {
            token,
            holder,
            expected_finish_ms,
            expires_at_ms: expected_finish_ms
                + (IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS * 1000.0) as i64,
        });
        Some(token)
    }

    /// Hand the imaging train back. The operation is done (or gave up), so
    /// release immediately rather than letting the claim lapse, and a waiter
    /// starts now instead of sitting out the grace window.
    ///
    /// Identity-checked and therefore idempotent: a release presenting a token
    /// that is no longer installed does nothing.
    pub fn release(&mut self, token: u64) {
        if self
            .claim
            .as_ref()
            .is_some_and(|claim| claim.token == token)
        {
            self.claim = None;
        }
    }

    /// The live hold on the imaging train, or `None` when it is free.
    ///
    /// Expiry recovers abandoned claims. A live trigger guard retains ownership
    /// through overruns and cleanup; its time estimate cannot release capture.
    pub fn hold(&self) -> Option<ImagingTrainHold> {
        let claim = self.claim.as_ref()?;
        let now_ms = Utc::now().timestamp_millis();
        let max_remaining_ms = claim.expires_at_ms - now_ms;
        let guarded = self
            .owner
            .as_ref()
            .is_some_and(|(token, owner)| *token == claim.token && owner.strong_count() > 0);
        if max_remaining_ms <= 0 && !guarded {
            return None;
        }
        // i64 milliseconds -> f64 seconds; holds are seconds to minutes,
        // nowhere near the f64 mantissa limit.
        Some(ImagingTrainHold {
            holder: claim.holder,
            expected_remaining_secs: ((claim.expected_finish_ms - now_ms).max(0)) as f64 / 1000.0,
            max_remaining_secs: if guarded {
                f64::INFINITY
            } else {
                max_remaining_ms as f64 / 1000.0
            },
        })
    }

    /// Keep the claim under `token` alive for as long as `owner` is, whatever
    /// its time estimate says.
    pub(crate) fn guard_with(&mut self, token: u64, owner: &Arc<()>) {
        self.owner = Some((token, Arc::downgrade(owner)));
    }
}

/// How long a trigger-fired camera action expects to hold the imaging train.
/// Long enough for a full V-curve autofocus (15 points at several seconds each,
/// plus focuser travel). The action releases explicitly when it finishes, so
/// this is only an estimate a waiter reads. The live guard retains ownership
/// through overruns; expiry is only a fallback for an abandoned claim.
pub(crate) const TRIGGER_CAMERA_CLAIM_SECS: f64 = 10.0 * 60.0;

/// Which trigger actions drive the camera themselves, and the label each waits
/// under. `None` means the action never touches the sensor.
///
/// Autofocus, the meridian flip and `Recenter` all expose — the post-flip
/// recenter plate-solves, and a plate solve is an exposure. The capture loop's
/// pre-frame gate cannot stand in for the claim: it holds the NEXT frame, not
/// the one already exposing, so a flip firing a millisecond into a 15 s light
/// restarts the same sensor for its solve and the burst downloads the solve
/// frame and files it as that light.
pub(crate) fn camera_driving_trigger_action(action: &RecoveryAction) -> Option<&'static str> {
    match action {
        RecoveryAction::Autofocus => Some("autofocus"),
        RecoveryAction::MeridianFlip(_) => Some("meridian flip"),
        RecoveryAction::Recenter => Some("recenter"),
        _ => None,
    }
}

/// Hold a camera-using trigger action until the capture loop's in-flight
/// exposure has been downloaded.
///
/// Starting one mid-frame destroys that frame: the capture loop's download
/// finds the camera empty, the exposure node fails, and the sequential parent
/// takes the run down with it.
///
/// Waiting is bounded by the claim's own deadline (see
/// [`ImagingTrain::hold`]), so a hold that is never released
/// expires rather than blocking autofocus for the rest of the night. A cancel
/// releases immediately: an operator Stop must not wait out an exposure.
///
/// Returns the deadline (epoch ms) of the claim that was taken, or `None` when
/// the wait ended without one because the sequence was cancelled.
///
/// The distinction matters: a cancelled wait never holds the token, so a caller
/// that assumed "I waited, therefore I hold it" would go on to release a claim
/// belonging to whoever took it next — the capture loop — and reopen the
/// frame-destroying race this protocol exists to close.
pub(crate) async fn claim_camera_for_trigger_action(
    trigger_state: &Arc<RwLock<TriggerState>>,
    is_cancelled: &Arc<AtomicBool>,
    action: &'static str,
) -> Option<u64> {
    let mut announced = false;
    loop {
        if is_cancelled.load(Ordering::Relaxed) {
            tracing::info!(
                "Trigger-fired {} released early: sequence cancelled",
                action
            );
            return None;
        }

        let (hold, token) = {
            let mut state = trigger_state.write().await;
            match state
                .imaging_train
                .try_claim(action, TRIGGER_CAMERA_CLAIM_SECS)
            {
                Some(token) => (None, Some(token)),
                None => (state.imaging_train.hold(), None),
            }
        };

        let Some(hold) = hold else {
            if announced {
                tracing::info!("Imaging train free; running trigger-fired {} now", action);
            }
            return token;
        };

        if !announced {
            announced = true;
            // The bound is derived from the in-flight operation, not fixed: the
            // holder's own expected finish, and the claim's hard expiry as the
            // worst case. A 180 s light is waited out as 180 s; a 5 s one as
            // 5 s. The failure this replaces reported a 65 s timeout while
            // queued behind a 180 s frame, a number that came from the waiter's
            // own request and told the operator nothing.
            tracing::info!(
                "Holding trigger-fired {} for ~{:.0}s ({} holds the camera and filter wheel; \
                 at most {:.0}s): starting now would destroy the frame and fight for the wheel",
                action,
                hold.expected_remaining_secs,
                hold.holder,
                hold.max_remaining_secs
            );
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

/// The capture loop's camera claim, held on behalf of a trigger recovery
/// action and handed back on EVERY exit of the arm that took it.
///
/// Taking the claim is only half a protocol. Releasing it in exactly one place
/// — after the sweep, inside the `(Some, Some)` camera+focuser branch — leaves
/// the sibling branch (the rig whose focuser is absent or has disappeared
/// mid-run) logging "skipping the refocus and continuing the run" and falling
/// through with nothing released, so the hold sits until
/// [`TRIGGER_CAMERA_CLAIM_SECS`] expires. For those ten minutes the capture
/// loop's pre-frame gate in `instructions/expose.rs` blocks every frame while
/// the run goes on reporting itself as imaging: a night's worth of exposures
/// lost to a recovery that never ran.
///
/// A guard rather than another `clear_camera_busy()` call site because the
/// dispatch exits in three different ways — falling out of the match, a
/// `continue` in the trigger loop, and several `return terminate_with(...)`
/// early returns — and only `Drop` covers all of them, including the arms
/// nobody has written yet. Callers that finish with the camera mid-arm still
/// call [`TriggerCameraClaim::release`] explicitly, so the capture loop gets
/// its next frame the moment the sweep is done rather than at the end of the
/// dispatch.
///
/// Release is once-only and identity-checked: the token is a single shared
/// deadline, so clearing it twice — or clearing it after the capture loop has
/// taken it for its own frame — would destroy exactly the frame the claim
/// protects.
pub(crate) struct TriggerCameraClaim {
    trigger_state: Option<Arc<RwLock<TriggerState>>>,
    /// The token this guard installed. Only the claim still carrying it is ours
    /// to release.
    token: Option<u64>,
    label: &'static str,
    _owner: Option<Arc<()>>,
}

impl TriggerCameraClaim {
    /// Take the claim if `action` drives the camera, waiting out any frame in
    /// flight. A non-camera action (a dither, a park) returns an unheld guard
    /// rather than waiting — holding those behind a ten-minute sub would be
    /// its own defect.
    pub(crate) async fn acquire(
        trigger_state: &Arc<RwLock<TriggerState>>,
        is_cancelled: &Arc<AtomicBool>,
        action: &RecoveryAction,
    ) -> Self {
        let Some(label) = camera_driving_trigger_action(action) else {
            return Self::unheld();
        };
        let token = claim_camera_for_trigger_action(trigger_state, is_cancelled, label).await;
        if token.is_none() {
            // Cancelled before the token was ours; there is nothing to give
            // back and releasing anyway would steal someone else's claim.
            return Self::unheld();
        }
        let owner = Arc::new(());
        if let Some(token) = token {
            trigger_state
                .write()
                .await
                .imaging_train
                .guard_with(token, &owner);
        }
        Self {
            _owner: Some(owner),
            trigger_state: Some(trigger_state.clone()),
            token,
            label,
        }
    }

    pub(crate) fn unheld() -> Self {
        Self {
            trigger_state: None,
            token: None,
            label: "",
            _owner: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn is_held(&self) -> bool {
        self.trigger_state.is_some()
    }

    /// Hand the camera back now — the normal path, taken the moment the action
    /// is done with the sensor. Idempotent.
    pub(crate) async fn release(&mut self) {
        let (Some(state), Some(token)) = (self.trigger_state.take(), self.token.take()) else {
            return;
        };
        state.write().await.imaging_train.release(token);
    }
}

impl Drop for TriggerCameraClaim {
    fn drop(&mut self) {
        let (Some(state), Some(token)) = (self.trigger_state.take(), self.token.take()) else {
            return;
        };
        let label = self.label;
        // The lock is only ever held for a field write or two, so the
        // uncontended path is the normal one and the release is immediate.
        if let Ok(mut guard) = state.try_write() {
            guard.imaging_train.release(token);
            return;
        }
        // Contended: hand the release to the runtime rather than blocking a
        // drop. The identity check is what makes the delay safe.
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                handle.spawn(async move {
                    state.write().await.imaging_train.release(token);
                });
            }
            Err(_) => tracing::error!(
                "Trigger-fired {} could not hand the camera back (no runtime at drop); the \
                 capture loop will wait out the claim's expiry",
                label
            ),
        }
    }
}
