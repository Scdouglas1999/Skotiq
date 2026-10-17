use super::*;

/// Golden angle (radians) — successive multiples spread points evenly around the
/// circle without ever repeating, the basis of the sunflower/spiral dither.
pub(crate) const DITHER_GOLDEN_ANGLE: f64 = 2.399_963_229_728_653;

/// Number of points in the dither pattern before it wraps. The pattern is a
/// Vogel disc: `DITHER_PATTERN_POINTS` points spread over a disc of radius
/// `amount`, so the pattern index is bounded and so is the offset it produces.
pub(crate) const DITHER_PATTERN_POINTS: u32 = 16;

/// Largest single move a dither may command, in guide-camera pixels. A jump
/// larger than the star-matching window ([`GUIDE_MAX_MATCH_DISTANCE_PX`]) moves
/// every reference star's expected position beyond its detection, so the next
/// frame matches nothing and the loop dies with "Unable to match guide stars".
/// A dither that would exceed this is applied partially — it still lands inside
/// the (convex) dither disc, just closer to where it started.
pub(crate) const DITHER_MAX_JUMP_PX: f64 = GUIDE_MAX_MATCH_DISTANCE_PX * 0.75;

/// Consecutive unmatched frames tolerated while a dither is in flight before the
/// dither is abandoned and rolled back.
pub(crate) const DITHER_MATCH_GRACE_FRAMES: u32 = 3;

/// Compute the dither POSITION for pattern index `step`, as an offset from the
/// guiding reference — not an increment to the current offset.
///
/// Uses a Vogel (sunflower) disc of [`DITHER_PATTERN_POINTS`] points: index `n`
/// sits at angle `n * golden_angle` and radius `amount * sqrt((n+1)/N)`, so the
/// points spread evenly over the disc, consecutive dithers land on fresh pixels,
/// and the radius never exceeds `amount` — the configured dither amplitude is a
/// bound on the offset, not a step size that compounds. The index wraps at `N`,
/// so an all-night run re-treads the same bounded pattern instead of walking off
/// the target. The radius is scaled up when `recent_rms` shows poor seeing
/// (adaptive: a bigger move stays distinguishable from guiding noise), still
/// clamped to `amount`. `ra_only` collapses the move to the RA (x) axis with a
/// deterministic sign alternation so it still walks both ways.
pub(crate) fn dither_offset(
    amount: f64,
    ra_only: bool,
    step: u32,
    recent_rms: Option<f64>,
) -> Vec2 {
    let limit = amount.abs();
    // Adaptive scale: 1.0 in good seeing, growing with recent RMS up to ~2x.
    let rms = recent_rms.unwrap_or(0.0).max(0.0);
    let adaptive = (1.0 + rms.min(amount.max(1.0)) / amount.max(1.0)).clamp(1.0, 2.0);
    let base = limit * adaptive;
    let index = step % DITHER_PATTERN_POINTS;

    if ra_only {
        // Alternate sign each dither and step out along the axis, wrapping with
        // the pattern so the excursion stays inside `amount`.
        let sign = if index % 2 == 0 { 1.0 } else { -1.0 };
        let rings = (DITHER_PATTERN_POINTS / 2) as f64;
        let radius = (base * (((index / 2) as f64 + 1.0) / rings).sqrt()).min(limit);
        return Vec2 {
            x: sign * radius,
            y: 0.0,
        };
    }

    let n = index as f64;
    let angle = n * DITHER_GOLDEN_ANGLE;
    let radius = (base * ((n + 1.0) / DITHER_PATTERN_POINTS as f64).sqrt()).min(limit);
    Vec2 {
        x: radius * angle.cos(),
        y: radius * angle.sin(),
    }
}

/// Give up on the in-flight dither: restore the offset it started from, clear the
/// settle bookkeeping, and flag it so the waiting [`dither`] call reports failure.
/// Guiding is deliberately left running — the target offset is back where guiding
/// was already locked, so the loop resumes against a known-good position.
pub(crate) fn abandon_dither(guard: &mut BuiltinGuiderState) {
    guard.desired_offset = guard.dither_origin;
    guard.dither_pending = false;
    guard.dither_misses = 0;
    guard.dither_abandoned = true;
    guard.settle_deadline = None;
    guard.settle_timeout_deadline = None;
    guard.settling = false;
}

/// Move `from` toward the pattern position `to`, capped at [`DITHER_MAX_JUMP_PX`].
/// Returns the offset to command. The disc is convex, so a partial move is still
/// inside the dither disc.
pub(crate) fn dither_target_within_jump(from: Vec2, to: Vec2) -> Vec2 {
    let delta = Vec2 {
        x: to.x - from.x,
        y: to.y - from.y,
    };
    let distance = delta.magnitude();
    if distance <= DITHER_MAX_JUMP_PX || distance <= f64::EPSILON {
        return to;
    }
    let scale = DITHER_MAX_JUMP_PX / distance;
    Vec2 {
        x: from.x + delta.x * scale,
        y: from.y + delta.y * scale,
    }
}

pub async fn dither(
    amount: f64,
    ra_only: bool,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    ensure_connected().await?;

    let timeout_secs = settle_timeout.max(settle_time + 1.0);
    let offset;
    {
        let mut guard = state().write().await;
        // A dither only settles if the guiding loop is actually running to drive
        // `apply_settle_state`; otherwise nothing ever clears `dither_pending`
        // and we would block forever. Fail closed.
        if !guard.guiding {
            return Err(SkotiqError::OperationFailed(
                "Built-in guider dither requires active guiding; not guiding".to_string(),
            ));
        }
        // Advance the bounded pattern so each dither walks to fresh pixels
        // instead of re-treading the same spot (a fixed/random small jump
        // re-walks the same neighbourhood). Adaptive: scale by recent RMS so the
        // dither moves further when seeing is poor, keeping it distinguishable
        // from guiding noise.
        //
        // `dither_offset` returns the POSITION for this pattern index, so the
        // offset is assigned, never accumulated: the star stays inside a disc of
        // radius `amount` around the guiding reference for the whole session.
        let step = guard.dither_step;
        guard.dither_step = step.wrapping_add(1);
        let rms = recent_rms(&guard.rms_history);
        let origin = guard.desired_offset;
        let target = dither_target_within_jump(origin, dither_offset(amount, ra_only, step, rms));
        offset = Vec2 {
            x: target.x - origin.x,
            y: target.y - origin.y,
        };

        guard.desired_offset = target;
        guard.dither_origin = origin;
        guard.dither_misses = 0;
        guard.dither_abandoned = false;
        guard.dither_pending = true;
        // Reset settle state and arm the timeout for this dither settle.
        guard.settle_deadline = None;
        guard.settling = true;
        guard.settle_timeout_deadline =
            Some(Instant::now() + Duration::from_secs_f64(timeout_secs));
        // Install THIS dither's settle spec. The guiding loop used to judge every
        // settle by the tolerance captured when guiding started, so the
        // sequencer's per-dither `settle_pixels`/`settle_time` — passed all the
        // way down from the Dither instruction through `guider_dither` — were
        // dropped on the floor while the log line claimed "settle: <Xpx in Ys".
        guard.settle_spec = SettleSpec {
            pixels: settle_pixels,
            time: settle_time,
            timeout: timeout_secs,
        };
    }
    get_state().publish_guiding_event(
        GuidingEvent::DitherStarted {
            pixels: offset.magnitude(),
        },
        EventSeverity::Info,
    );

    // BLOCK until the guiding loop reports the dither settled, mirroring the
    // PHD2 path. Without this, the sequencer resumed exposing immediately after
    // arming the offset and trailed the sub. Fail closed on settle failure or
    // timeout: the loop clears `dither_pending` (and emits Settled) on success,
    // and on a settle timeout the loop task aborts and clears `guiding`.
    //
    // Bound the wait by the settle timeout plus a grace margin so a stalled
    // loop (no frames arriving) cannot hang the caller indefinitely.
    let deadline = Instant::now() + Duration::from_secs_f64(timeout_secs + 10.0);
    loop {
        {
            let guard = state().read().await;
            if !guard.dither_pending {
                // Rolled back by the guiding loop: the move could not be made,
                // but guiding survived it. Report the failed dither without
                // claiming the settle succeeded.
                if guard.dither_abandoned {
                    return Err(SkotiqError::OperationFailed(
                        "Built-in guider dither was abandoned and rolled back; guiding continues"
                            .to_string(),
                    ));
                }
                // Cleared by apply_settle_state on a successful settle.
                if guard.guiding {
                    return Ok(());
                }
                // Loop is no longer guiding: the dither settle could not be
                // completed (loop aborted / was stopped). Fail closed.
                return Err(SkotiqError::OperationFailed(
                    "Built-in guider dither did not settle: guiding stopped before settle completed"
                        .to_string(),
                ));
            }
            if !guard.guiding {
                return Err(SkotiqError::OperationFailed(
                    "Built-in guider dither did not settle: guiding loop stopped".to_string(),
                ));
            }
        }
        if Instant::now() >= deadline {
            // Clear the dangling dither flag so a later operation isn't confused.
            let mut guard = state().write().await;
            guard.dither_pending = false;
            guard.settle_deadline = None;
            guard.settle_timeout_deadline = None;
            guard.settling = false;
            return Err(SkotiqError::OperationFailed(format!(
                "Built-in guider dither did not settle within {:.0}s",
                timeout_secs + 10.0
            )));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
