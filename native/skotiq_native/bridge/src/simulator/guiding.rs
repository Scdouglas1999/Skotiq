use super::*;

// Simulated mount motion (guide pulses + tracking drift)

/// Sensor displacement, in pixels, produced by one second of guide pulse.
///
/// Derived rather than invented: a 0.5x-sidereal guide rate moves the sky at
/// 7.5 arcsec/sec, and the simulated guide train is taken to be ~1.25 arcsec per
/// pixel, giving 6 px/sec. At the built-in guider's default 250 ms calibration
/// pulse that is 1.5 px per pulse — comfortably above the routine's 0.2 px
/// "response too small" floor and far inside its 20 px star-match radius, so
/// calibration converges without the field jumping star-to-star.
pub(crate) const SIM_GUIDE_PX_PER_SEC: f64 = 6.0;

/// Uncorrected tracking drift, in pixels per second, on each sensor axis.
///
/// A perfectly still simulated sky would let a guider with an inverted
/// correction sign report a flawless 0.00 px RMS forever, because there would be
/// nothing for a correction to make worse. Giving the mount a slow, honest drift
/// means closed-loop guiding has to actually null it out, so the sign and
/// magnitude of the correction path are exercised end to end. Sized to be a
/// fraction of a pixel per guide cycle: a real guider absorbs this easily, and
/// an unguided sequence shows the gentle field walk you would expect.
pub(crate) const SIM_DRIFT_PX_PER_SEC_X: f64 = 0.05;
pub(crate) const SIM_DRIFT_PX_PER_SEC_Y: f64 = 0.02;

/// Ceiling on accumulated offset magnitude, per axis, in pixels.
///
/// Unbounded drift would eventually walk the whole field off the sensor and
/// leave the simulator producing starless frames after a long idle — a confusing
/// failure that looks like a detector bug. 60 px keeps the field recognisable
/// while still being a visible, correctable excursion.
pub(crate) const SIM_MAX_OFFSET_PX: f64 = 60.0;

/// Longest drift step applied in one advance, in seconds.
///
/// The app can sit idle for hours between simulated captures. Integrating that
/// whole gap at once would slam the offset into its clamp on the very first
/// frame; capping the step keeps the first capture after an idle period looking
/// like the last one.
pub(crate) const SIM_MAX_DRIFT_STEP_SECS: f64 = 5.0;

/// Accumulated sensor-plane offset of the simulated star field, in pixels.
///
/// Primitives in a lock rather than a field on [`SimulatedMount`] on purpose:
/// that struct is mirrored to Dart by flutter_rust_bridge and Dart has no use
/// for this.
pub(crate) static SIM_GUIDE_OFFSET: OnceLock<Arc<RwLock<(f64, f64)>>> = OnceLock::new();
pub(crate) static SIM_DRIFT_LAST_TICK: OnceLock<Arc<RwLock<Option<std::time::Instant>>>> =
    OnceLock::new();

pub(crate) fn sim_guide_offset() -> &'static Arc<RwLock<(f64, f64)>> {
    SIM_GUIDE_OFFSET.get_or_init(|| Arc::new(RwLock::new((0.0, 0.0))))
}

pub(crate) fn sim_drift_last_tick() -> &'static Arc<RwLock<Option<std::time::Instant>>> {
    SIM_DRIFT_LAST_TICK.get_or_init(|| Arc::new(RwLock::new(None)))
}

/// Pixel delta produced by pulsing `direction` for `duration_ms`.
///
/// East/west move the field along +x/-x and north/south along +y/-y. The axes are
/// deliberately orthogonal and axis-aligned: the guider derives its own rotation
/// matrix from the responses it measures, so a clean basis lets a calibration
/// failure be read as a guider bug rather than an artefact of a contrived
/// simulated camera angle.
pub(crate) fn sim_pulse_delta(direction: &str, duration_ms: u32) -> (f64, f64) {
    let travel = SIM_GUIDE_PX_PER_SEC * (duration_ms as f64) / 1000.0;
    match direction.to_lowercase().as_str() {
        "east" | "e" => (travel, 0.0),
        "west" | "w" => (-travel, 0.0),
        "north" | "n" => (0.0, travel),
        "south" | "s" => (0.0, -travel),
        _ => (0.0, 0.0),
    }
}

/// Accumulate a displacement onto the current offset, clamped to the sensor
/// excursion limit. Pure so the clamp behaviour is testable without the
/// process-global offset.
pub(crate) fn apply_offset_delta(current: (f64, f64), dx: f64, dy: f64) -> (f64, f64) {
    (
        (current.0 + dx).clamp(-SIM_MAX_OFFSET_PX, SIM_MAX_OFFSET_PX),
        (current.1 + dy).clamp(-SIM_MAX_OFFSET_PX, SIM_MAX_OFFSET_PX),
    )
}

/// Seconds of drift to integrate, given the gap since the last advance.
///
/// `None` (first read after launch) and non-positive/non-finite gaps contribute
/// nothing, so the baseline is established rather than jumped.
pub(crate) fn drift_step_secs(elapsed: Option<f64>) -> f64 {
    match elapsed {
        Some(secs) if secs.is_finite() && secs > 0.0 => secs.min(SIM_MAX_DRIFT_STEP_SECS),
        _ => 0.0,
    }
}

/// Apply a guide pulse to the simulated mount.
pub(crate) async fn advance_sim_guide_pulse(direction: &str, duration_ms: u32) {
    let (dx, dy) = sim_pulse_delta(direction, duration_ms);
    if dx == 0.0 && dy == 0.0 {
        return;
    }
    let mut guard = sim_guide_offset().write().await;
    *guard = apply_offset_delta(*guard, dx, dy);
}

/// Current star-field offset, after advancing tracking drift to now.
///
/// Called from the simulated download path, which is what makes the drift
/// observable frame to frame.
pub(crate) async fn sim_guide_offset_px() -> (f64, f64) {
    let now = std::time::Instant::now();
    let elapsed = {
        let mut last = sim_drift_last_tick().write().await;
        let gap = last.map(|t| now.duration_since(t).as_secs_f64());
        *last = Some(now);
        drift_step_secs(gap)
    };

    let mut guard = sim_guide_offset().write().await;
    if elapsed > 0.0 {
        *guard = apply_offset_delta(
            *guard,
            SIM_DRIFT_PX_PER_SEC_X * elapsed,
            SIM_DRIFT_PX_PER_SEC_Y * elapsed,
        );
    }
    *guard
}

/// Re-centre the simulated star field.
///
/// A slew or park repoints the scope entirely, so carrying the previous target's
/// accumulated drift across would be wrong — and would leave a long session's
/// offset pinned at its clamp with no way back.
pub(crate) async fn reset_sim_guide_offset() {
    *sim_guide_offset().write().await = (0.0, 0.0);
    *sim_drift_last_tick().write().await = None;
}
