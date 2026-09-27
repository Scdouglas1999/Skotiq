use super::*;
use crate::{PierSide, RecoveryAction, TriggerType};
use chrono::Utc;
use std::time::{Duration, Instant};

mod audit_and_wave_tests;

#[tokio::test]
async fn test_hfr_trigger_relative() {
    let mut trigger = Trigger::new(
        "test",
        "Test HFR Relative",
        TriggerType::HfrDegraded {
            threshold_percent: 20.0,
            absolute_threshold: 0.0,
            consecutive_frames: 1,
        },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    state.baseline_hfr = Some(2.0);

    // No change - should not trigger. update_hfr keeps the pre-set
    // baseline (only sets it when None) and advances the per-frame
    // sequence so the frame-gate lets each check count.
    state.update_hfr(2.0);
    assert!(!trigger.check(&state).await);

    // 10% increase - should not trigger
    state.update_hfr(2.2);
    assert!(!trigger.check(&state).await);

    // 25% increase - should trigger (consecutive_frames=1, so immediate)
    state.update_hfr(2.5);
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_guide_star_lost_requires_arming() {
    // `guiding_enabled` must be settable so the GuideStarLost trigger can
    // fire; left false it is permanently dead and the sequence takes
    // unguided subs after a star loss.
    let mut trigger = Trigger::new(
        "guide_star_lost",
        "Guide Star Lost",
        TriggerType::GuideStarLost,
        RecoveryAction::Pause,
    );

    let mut state = TriggerState::new();

    // Star lost but guiding never armed -> must NOT fire (idle guider).
    state.set_guide_star_lost(true);
    assert!(
        !trigger.check(&state).await,
        "GuideStarLost must not fire before guiding is armed"
    );

    // Arm guiding (as StartGuiding success / executor latch does).
    state.set_guiding_enabled(true);
    assert!(
        trigger.check(&state).await,
        "GuideStarLost must fire once armed and the star is lost"
    );

    // Star reacquired -> no longer fires.
    state.set_guide_star_lost(false);
    assert!(!trigger.check(&state).await);

    // Star lost again while still armed -> fires.
    state.set_guide_star_lost(true);
    assert!(trigger.check(&state).await);

    // Explicit StopGuiding disarms -> must not fire even though the
    // guider reports not-guiding (intentional stop, not a lost star).
    state.set_guiding_enabled(false);
    assert!(
        !trigger.check(&state).await,
        "GuideStarLost must not fire after an intentional StopGuiding"
    );
}

#[tokio::test]
async fn test_dawn_approaching_fires_only_within_upcoming_window() {
    // DawnApproaching fires when an UPCOMING dawn is within the window, and
    // must NOT fire when dawn_time is unset or already in the past.
    let mut trigger = Trigger::new(
        "dawn",
        "Dawn Approaching",
        TriggerType::DawnApproaching {
            minutes_before: 30.0,
        },
        RecoveryAction::ParkAndAbort,
    );
    let mut state = TriggerState::new();

    // No dawn_time seeded -> cannot fire.
    assert!(!trigger.check(&state).await);

    let now = chrono::Utc::now().timestamp();

    // Dawn 60 min out, 30 min window -> not yet.
    state.dawn_time = Some(now + 60 * 60);
    assert!(!trigger.check(&state).await);

    // Dawn 15 min out -> within the 30 min window -> fire.
    state.dawn_time = Some(now + 15 * 60);
    assert!(trigger.check(&state).await);

    // Dawn already passed -> must NOT fire (would otherwise fire all day).
    state.dawn_time = Some(now - 60);
    assert!(!trigger.check(&state).await);
}

#[tokio::test]
async fn test_hfr_trigger_absolute() {
    let mut trigger = Trigger::new(
        "test",
        "Test HFR Absolute",
        TriggerType::HfrDegraded {
            threshold_percent: 0.0, // disabled
            absolute_threshold: 3.5,
            consecutive_frames: 1,
        },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();

    // Below absolute threshold - should not trigger
    state.update_hfr(3.0);
    assert!(!trigger.check(&state).await);

    // Above absolute threshold - should trigger
    state.update_hfr(4.0);
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_hfr_trigger_consecutive_frames() {
    let mut trigger = Trigger::new(
        "test",
        "Test HFR Consecutive",
        TriggerType::HfrDegraded {
            threshold_percent: 0.0,
            absolute_threshold: 3.0,
            consecutive_frames: 3,
        },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();

    // Frame 1: bad - should not trigger yet (need 3)
    state.update_hfr(4.0);
    assert!(!trigger.check(&state).await);
    assert_eq!(trigger.hfr_bad_frame_count, 1);

    // A re-evaluation of the SAME frame (the ~1Hz monitor tick) must NOT
    // advance the counter — it counts frames, not ticks. Counting ticks bumps
    // the count toward firing within one sub.
    assert!(!trigger.check(&state).await);
    assert_eq!(
        trigger.hfr_bad_frame_count, 1,
        "same frame must not re-count"
    );

    // Frame 2: bad - still not enough
    state.update_hfr(4.0);
    assert!(!trigger.check(&state).await);
    assert_eq!(trigger.hfr_bad_frame_count, 2);

    // Frame 3: bad - now should trigger
    state.update_hfr(4.0);
    assert!(trigger.check(&state).await);
    assert_eq!(trigger.hfr_bad_frame_count, 3);

    // Reset: good frame resets counter
    state.update_hfr(2.0);
    trigger.hfr_bad_frame_count = 0; // Reset after trigger fired
    assert!(!trigger.check(&state).await);
    assert_eq!(trigger.hfr_bad_frame_count, 0);

    // One bad frame after reset - not enough
    state.update_hfr(4.0);
    assert!(!trigger.check(&state).await);
    assert_eq!(trigger.hfr_bad_frame_count, 1);
}

#[tokio::test]
async fn test_altitude_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Altitude",
        TriggerType::AltitudeLimit { min_altitude: 30.0 },
        RecoveryAction::NextTarget,
    );

    let mut state = TriggerState::new();

    // Above limit - should not trigger
    state.current_altitude = Some(45.0);
    assert!(!trigger.check(&state).await);

    // Below limit - should trigger
    state.current_altitude = Some(25.0);
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_guiding_failed_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Guiding Failed",
        TriggerType::GuidingFailed {
            rms_threshold: 2.0,
            duration_secs: 10.0,
            rms_retention_secs: 300,
        },
        RecoveryAction::Retry { max_attempts: 3 },
    );

    let mut state = TriggerState::new();
    state.guiding_rms_history = Some(Vec::new());

    // A single fresh spike is not evidence that guiding has been bad for
    // the configured ten-second debounce window.
    state
        .guiding_rms_history
        .as_mut()
        .unwrap()
        .push((Instant::now(), 2.8));
    assert!(
        !trigger.check(&state).await,
        "one recent high-RMS sample must not trip GuidingFailed"
    );

    // Two bad samples spanning the full window establish a sustained bad
    // run and must trip the trigger.
    let now = Instant::now();
    state.guiding_rms_history = Some(vec![
        (now - Duration::from_secs(11), 2.5),
        (now - Duration::from_secs(5), 2.7),
        (now, 2.8),
    ]);
    assert!(
        trigger.check(&state).await,
        "an uninterrupted bad-RMS run spanning duration_secs must trip"
    );
}

#[tokio::test]
async fn test_autofocus_interval_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Autofocus Interval",
        TriggerType::AutofocusInterval { every_n_frames: 10 },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();

    // No exposures completed - should not trigger
    assert!(!trigger.check(&state).await);

    // Complete some exposures
    for _ in 0..9 {
        state.increment_exposure_count();
    }

    // 9 exposures, should not trigger yet
    assert!(!trigger.check(&state).await);

    // 10th exposure - should trigger
    state.increment_exposure_count();
    assert!(trigger.check(&state).await);

    // Mark autofocus performed
    state.mark_autofocus_performed();

    // Should not trigger immediately after autofocus
    assert!(!trigger.check(&state).await);

    // Complete another 10 exposures
    for _ in 0..10 {
        state.increment_exposure_count();
    }

    // Should trigger again
    assert!(trigger.check(&state).await);
}

/// Owner decision (2026-08-14): a failed trigger autofocus continues the
/// run. The interval trigger carries no time cooldown, so unless the failed
/// ATTEMPT also moves the cadence anchor, `frames_since_af` stays at or
/// above the interval forever and every remaining exposure re-fires a sweep
/// that already failed — an unattended night spent focusing, not imaging.
#[tokio::test]
async fn a_failed_autofocus_attempt_defers_the_next_interval_by_a_full_cadence() {
    let mut trigger = Trigger::new(
        "test",
        "Test Autofocus Interval",
        TriggerType::AutofocusInterval { every_n_frames: 10 },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    state.invalidate_autofocus("filter changed to L");
    for _ in 0..10 {
        state.increment_exposure_count();
    }
    assert!(trigger.check(&state).await);

    // The sweep ran and missed its curve fit; the run keeps the last-good
    // focus and the anchor moves anyway.
    state.mark_autofocus_attempted();

    assert!(!state.autofocus_invalidated);
    for _ in 0..9 {
        state.increment_exposure_count();
        assert!(
            !trigger.check(&state).await,
            "a failed autofocus must not re-fire on every subsequent frame"
        );
    }

    state.increment_exposure_count();
    assert!(
        trigger.check(&state).await,
        "the next attempt is due one full cadence later"
    );
}

#[tokio::test]
async fn test_dither_interval_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Dither Interval",
        TriggerType::DitherInterval { every_n_frames: 5 },
        RecoveryAction::Continue,
    );

    let mut state = TriggerState::new();

    // Complete 5 exposures
    for _ in 0..5 {
        state.increment_exposure_count();
    }

    // Should trigger after 5 exposures
    assert!(trigger.check(&state).await);

    // Mark dither performed
    state.mark_dither_performed();

    // Complete another 5 exposures
    for _ in 0..5 {
        state.increment_exposure_count();
    }

    // Should trigger again
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_autofocus_interval_resume_counter_does_not_underflow() {
    let mut trigger = Trigger::new(
        "test",
        "Test Autofocus Interval Resume",
        TriggerType::AutofocusInterval { every_n_frames: 5 },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    state.completed_exposures = 3;
    state.last_autofocus_frame = 10;

    assert!(!trigger.check(&state).await);
}

#[tokio::test]
async fn test_dither_interval_resume_counter_does_not_underflow() {
    let mut trigger = Trigger::new(
        "test",
        "Test Dither Interval Resume",
        TriggerType::DitherInterval { every_n_frames: 5 },
        RecoveryAction::Continue,
    );

    let mut state = TriggerState::new();
    state.completed_exposures = 2;
    state.last_dither_frame = 8;

    assert!(!trigger.check(&state).await);
}

#[tokio::test]
async fn test_weather_unsafe_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Weather",
        TriggerType::WeatherUnsafe,
        RecoveryAction::ParkAndAbort,
    );

    let mut state = TriggerState::new();

    // Safe weather - should not trigger
    state.weather_safe = true;
    assert!(!trigger.check(&state).await);

    // Unsafe weather - should trigger
    state.weather_safe = false;
    assert!(trigger.check(&state).await);
}

/// Full-night audit 2026-06-04 (defense-in-depth): the Dart-side weather
/// verdict is an ADDITIONAL unsafe source. It must be able to abort a rig
/// whose hardware safety device reports SAFE (or has no device), but it
/// must never suppress a hardware-unsafe reading.
#[tokio::test]
async fn test_weather_unsafe_trigger_honours_dart_verdict() {
    let mut trigger = Trigger::new(
        "test",
        "Test Weather Verdict",
        TriggerType::WeatherUnsafe,
        RecoveryAction::ParkAndAbort,
    );

    let mut state = TriggerState::new();

    // Hardware reports SAFE, verdict abstains (None) -> overall SAFE.
    state.weather_safe = true;
    state.update_weather_verdict(None);
    assert!(
        !trigger.check(&state).await,
        "no unsafe source: should not fire"
    );

    // Hardware reports SAFE, but the Dart verdict computed UNSAFE -> the
    // trigger MUST fire (this is the rig-without-a-safety-device path).
    state.weather_safe = true;
    state.update_weather_verdict(Some(true));
    assert!(
        trigger.check(&state).await,
        "Some(true) verdict must abort even when hardware says safe"
    );

    // Hardware reports SAFE and the Dart verdict explicitly computed SAFE
    // -> overall SAFE (verdict never spuriously fires).
    state.weather_safe = true;
    state.update_weather_verdict(Some(false));
    assert!(
        !trigger.check(&state).await,
        "Some(false) verdict + device-safe must stay safe"
    );

    // Hardware reports UNSAFE and the Dart verdict says SAFE -> the verdict
    // must NOT make the rig less safe than the hardware reading.
    state.weather_safe = false;
    state.update_weather_verdict(Some(false));
    assert!(
        trigger.check(&state).await,
        "Some(false) verdict must never suppress a hardware-unsafe reading"
    );
}

/// The abstain
/// landmine. A disabled / snoozed / permissive-fail-mode weather toggle on
/// the Dart side pushes `None` (abstain), NOT `Some(false)`. This test pins
/// that abstaining MUST NOT suppress a hardware-unsafe abort — even though
/// the operator "turned weather safety off", a hardware safety device that
/// reads unsafe still aborts via the OR in `check`. This is the structural
/// guarantee that makes the disabled-toggle change safe.
#[tokio::test]
async fn test_weather_unsafe_abstain_does_not_suppress_hardware_abort() {
    let mut trigger = Trigger::new(
        "test",
        "Test Weather Abstain",
        TriggerType::WeatherUnsafe,
        RecoveryAction::ParkAndAbort,
    );

    let mut state = TriggerState::new();

    // Operator opted out of weather-driven aborts => Dart abstains (None).
    // The hardware safety device nonetheless reads UNSAFE. The trigger MUST
    // still fire: a disabled toggle can never gag a hardware-unsafe device.
    state.weather_safe = false;
    state.update_weather_verdict(None);
    assert!(
        trigger.check(&state).await,
        "abstain (None) must NOT suppress a hardware-unsafe abort"
    );

    // And when the hardware also reads safe under abstain, nothing fires —
    // abstain is genuinely non-asserting, not a stuck-unsafe.
    state.weather_safe = true;
    state.update_weather_verdict(None);
    assert!(
        !trigger.check(&state).await,
        "abstain (None) with safe hardware must not fire"
    );
}

/// EXHAUSTIVE gate matrix: Dart verdict {Some(true), Some(false), None} ×
/// hardware {safe, unsafe, unavailable}. "Unavailable" is what the executor's
/// safety poll resolves through the shared fail-mode truth table
/// (`safety_fail_mode_no_data_resolution`) BEFORE the gate sees
/// `weather_safe`, so the unavailable rows are exercised once per fail
/// mode here exactly the way the poll loop maps them.
///
/// Invariants pinned:
///   1. The gate is `!weather_safe || verdict == Some(true)` — a pure OR
///      of unsafe sources.
///   2. `None` (abstain) NEVER suppresses an unsafe: every row that fires
///      with `Some(false)` or `Some(true)` also fires with `None` swapped
///      in only if the hardware term alone fires — i.e. None contributes
///      nothing in either direction.
///   3. A Dart side that opts out (pushes `None`, never `Some(false)`)
///      cannot make any unsafe row go safe — the unavailable+FailClosed row
///      included — because there is no SAFE assertion to trust.
#[tokio::test]
async fn weather_unsafe_gate_full_matrix_verdict_x_hardware() {
    use crate::{safety_fail_mode_no_data_resolution, NoDataResolution, SafetyFailMode};

    let mut trigger = Trigger::new(
        "weather_unsafe",
        "Weather Unsafe",
        TriggerType::WeatherUnsafe,
        RecoveryAction::ParkAndAbort,
    );

    // Map the "unavailable" hardware axis through the shared fail-mode
    // truth table exactly as the executor poll loop does. `prior` is the
    // last good reading (the value WarnOnly preserves).
    fn resolve_unavailable(mode: SafetyFailMode, prior: bool) -> bool {
        match safety_fail_mode_no_data_resolution(mode) {
            NoDataResolution::Unsafe => false,
            NoDataResolution::Safe => true,
            NoDataResolution::Preserve => prior,
        }
    }

    let verdicts: [Option<bool>; 3] = [Some(true), Some(false), None];

    for verdict in verdicts {
        // Hardware safe
        let mut state = TriggerState::new();
        state.weather_safe = true;
        state.update_weather_verdict(verdict);
        assert_eq!(
            trigger.check(&state).await,
            verdict == Some(true),
            "hardware-safe: gate must fire iff verdict is Some(true) (verdict={verdict:?})"
        );

        // Hardware unsafe
        let mut state = TriggerState::new();
        state.weather_safe = false;
        state.update_weather_verdict(verdict);
        assert!(
            trigger.check(&state).await,
            "hardware-unsafe must ALWAYS fire; verdict={verdict:?} must never suppress it"
        );

        // Hardware unavailable (per fail mode)
        for (mode, prior) in [
            (SafetyFailMode::FailClosed, true),
            (SafetyFailMode::FailOpen, false),
            (SafetyFailMode::WarnOnly, true),
            (SafetyFailMode::WarnOnly, false),
        ] {
            let resolved = resolve_unavailable(mode, prior);
            let mut state = TriggerState::new();
            state.weather_safe = resolved;
            state.update_weather_verdict(verdict);
            let expected = !resolved || verdict == Some(true);
            assert_eq!(
                trigger.check(&state).await,
                expected,
                "hardware-unavailable mode={mode:?} prior={prior} verdict={verdict:?}: \
                 gate must be the pure OR of resolved-hardware-unsafe and Some(true)"
            );
        }
    }

    // Disabled safety + a hypothetical verdict-trusting Rust: the Dart
    // opt-out contract is `None`, never `Some(false)`. With
    // `None` pushed there is no SAFE assertion in the channel at all, so no
    // unsafe hardware state — including unavailable under FailClosed — can
    // be declared safe via the verdict.
    let mut state = TriggerState::new();
    state.weather_safe = resolve_unavailable(SafetyFailMode::FailClosed, true);
    state.update_weather_verdict(None);
    assert!(
        trigger.check(&state).await,
        "disabled-safety abstain must not clear a FailClosed unavailable device"
    );
}

/// (Subsystem 2 step 3 — stale-verdict
/// observability). A pushed `Some(true)`=UNSAFE verdict whose Dart feed goes
/// stale MUST stay unsafe (the `WeatherUnsafe` trigger keeps firing — the
/// sequence is held paused fail-closed) and the staleness predicate must
/// report stale so the executor can emit its loud warning. Staleness NEVER
/// resumes — there is no anti-safety auto-clear here.
#[tokio::test]
async fn weather_verdict_stale_unsafe_stays_unsafe_and_is_detected() {
    let mut trigger = Trigger::new(
        "weather_unsafe",
        "Weather Unsafe",
        TriggerType::WeatherUnsafe,
        RecoveryAction::ParkAndAbort,
    );
    let mut state = TriggerState::new();
    // Hardware reads safe; only the Dart verdict asserts UNSAFE (the
    // rig-without-a-safety-device path).
    state.weather_safe = true;
    state.update_weather_verdict(Some(true));

    // Immediately after the push it is fresh: not stale, but still unsafe.
    assert!(
        !state.is_weather_verdict_stale_unsafe(60),
        "a just-pushed unsafe verdict must not be considered stale"
    );
    assert!(
        trigger.check(&state).await,
        "fresh unsafe verdict must fire (hold paused)"
    );

    // Force the push timestamp into the past so the verdict is now stale.
    // We do NOT touch `weather_verdict_unsafe` — staleness must not clear it.
    state.weather_verdict_last_update = Some(stale_instant(std::time::Duration::from_secs(120)));

    // Stale-AND-unsafe: predicate true with a 60s window.
    assert!(
        state.is_weather_verdict_stale_unsafe(60),
        "an unsafe verdict 120s old with a 60s window must read stale"
    );
    // CRITICAL: the trigger STILL fires — staleness holds paused, never resumes.
    assert!(
        state.weather_verdict_unsafe == Some(true),
        "staleness must NOT clear the unsafe verdict"
    );
    assert!(
        trigger.check(&state).await,
        "stale unsafe verdict must keep firing — no auto-resume on staleness"
    );

    // A fresh push (even abstain) clears the stale-unsafe condition.
    state.update_weather_verdict(None);
    assert!(
        !state.is_weather_verdict_stale_unsafe(60),
        "a fresh abstain push must clear the stale-unsafe condition"
    );
}

/// An [`Instant`] `age` in the past, clamped to the oldest instant this
/// platform can represent. On Windows `Instant` is measured from boot, so
/// `Instant::now() - 10_000s` panics with "overflow when subtracting
/// duration from instant" on a freshly-booted CI runner; saturating keeps
/// the fixture "very stale" without assuming machine uptime.
fn stale_instant(age: std::time::Duration) -> Instant {
    let now = Instant::now();
    now.checked_sub(age).unwrap_or_else(|| {
        // Oldest representable instant: walk back as far as we can.
        let mut probe = std::time::Duration::from_secs(1);
        let mut oldest = now;
        while let Some(earlier) = now.checked_sub(probe) {
            oldest = earlier;
            probe *= 2;
        }
        oldest
    })
}

/// Subsystem 2 step 3: the staleness predicate is scoped to `Some(true)`
/// only. A stale SAFE / abstaining verdict is harmless (nothing is held), and
/// a never-pushed verdict has no feed to be stale — both must read NOT stale.
#[tokio::test]
async fn weather_verdict_staleness_only_applies_to_unsafe() {
    let mut state = TriggerState::new();

    // Never pushed -> no feed to be stale.
    assert!(
        !state.is_weather_verdict_stale_unsafe(0),
        "a never-pushed verdict cannot be stale"
    );

    // Stale SAFE verdict -> not stale-unsafe (nothing is being held).
    state.update_weather_verdict(Some(false));
    state.weather_verdict_last_update = Some(stale_instant(std::time::Duration::from_secs(10_000)));
    assert!(
        !state.is_weather_verdict_stale_unsafe(60),
        "a stale SAFE verdict must not read as stale-unsafe"
    );

    // Stale abstain -> not stale-unsafe.
    state.update_weather_verdict(None);
    state.weather_verdict_last_update = Some(stale_instant(std::time::Duration::from_secs(10_000)));
    assert!(
        !state.is_weather_verdict_stale_unsafe(60),
        "a stale abstain must not read as stale-unsafe"
    );
}

#[tokio::test]
async fn test_temperature_shift_trigger() {
    let mut trigger = Trigger::new(
        "test",
        "Test Temperature Shift",
        TriggerType::TemperatureShift { degrees: 2.0 },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    state.baseline_temperature = Some(10.0);

    // Small change - should not trigger
    state.current_temperature = Some(11.0);
    assert!(!trigger.check(&state).await);

    // Large change - should trigger
    state.current_temperature = Some(13.0);
    assert!(trigger.check(&state).await);

    // Negative change - should also trigger
    state.current_temperature = Some(7.5);
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_temperature_shift_needs_a_drifting_source() {
    // The temperature trigger is fed from the FOCUSER probe, not the
    // regulated camera sensor: a cooled camera holds a fixed setpoint, so its
    // reading never drifts and the trigger could never fire while focus walks
    // soft over the night. This test pins the underlying contract — a
    // constant feed never trips, a drifting (focuser/ambient) feed does once
    // the delta exceeds the configured degrees.
    let mut trigger = Trigger::new(
        "test",
        "Temp Shift Source",
        TriggerType::TemperatureShift { degrees: 2.0 },
        RecoveryAction::Autofocus,
    );

    // Regulated camera sensor: held at -10.0°C all night. update_temperature
    // seeds the baseline from the first reading, then every reading equals
    // it, so the trigger NEVER fires no matter how many ticks elapse.
    let mut regulated = TriggerState::new();
    for _ in 0..100 {
        regulated.update_temperature(-10.0);
        assert!(
            !trigger.check(&regulated).await,
            "a regulated (constant) temperature source must never trip refocus"
        );
    }

    // Focuser/ambient probe: tracks the night cooling down. Baseline seeds
    // at 8.0°C; once the optical train cools past the 2.0° threshold the
    // trigger fires, requesting the refocus the regulated feed could not.
    let mut drifting = TriggerState::new();
    drifting.update_temperature(8.0);
    assert!(!trigger.check(&drifting).await, "delta 0 must not fire");
    drifting.update_temperature(6.5);
    assert!(!trigger.check(&drifting).await, "delta 1.5 below threshold");
    drifting.update_temperature(5.5);
    assert!(
        trigger.check(&drifting).await,
        "delta 2.5 above threshold must fire refocus from a drifting source"
    );
}

#[tokio::test]
async fn test_trigger_cooldown() {
    let mut trigger = Trigger::new(
        "test",
        "Test Cooldown",
        TriggerType::HfrDegraded {
            threshold_percent: 20.0,
            absolute_threshold: 0.0,
            consecutive_frames: 1,
        },
        RecoveryAction::Autofocus,
    )
    .with_cooldown(2); // 2 second cooldown

    let mut state = TriggerState::new();
    state.baseline_hfr = Some(2.0);
    state.current_hfr = Some(2.5);

    // First check - should trigger
    assert!(trigger.check(&state).await);

    // Immediate second check - should not trigger (cooldown)
    assert!(!trigger.check(&state).await);

    // Wait for cooldown to expire
    tokio::time::sleep(Duration::from_secs(3)).await;

    // Should trigger again
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_trigger_manager() {
    let mut manager = TriggerManager::new();

    // Add some triggers
    manager.add_trigger(Trigger::new(
        "hfr",
        "HFR Monitor",
        TriggerType::HfrDegraded {
            threshold_percent: 25.0,
            absolute_threshold: 0.0,
            consecutive_frames: 1,
        },
        RecoveryAction::Autofocus,
    ));

    manager.add_trigger(Trigger::new(
        "altitude",
        "Altitude Limit",
        TriggerType::AltitudeLimit { min_altitude: 30.0 },
        RecoveryAction::NextTarget,
    ));

    // Set up trigger state
    {
        let state_lock = manager.state();
        let mut state = state_lock.write().await;
        state.baseline_hfr = Some(2.0);
        state.current_hfr = Some(2.6); // 30% increase - should trigger
        state.current_altitude = Some(25.0); // Below limit - should trigger
    }

    // Check all triggers
    let fired = manager.check_all().await;

    // Both triggers should have fired
    assert_eq!(fired.len(), 2);
    assert!(fired.iter().any(|(id, _)| id == "hfr"));
    assert!(fired.iter().any(|(id, _)| id == "altitude"));
}

#[tokio::test]
async fn test_exposure_count_tracking() {
    let mut state = TriggerState::new();

    assert_eq!(state.completed_exposures, 0);
    assert_eq!(state.last_autofocus_frame, 0);
    assert_eq!(state.last_dither_frame, 0);

    // Simulate completing 10 exposures
    for _ in 0..10 {
        state.increment_exposure_count();
    }
    assert_eq!(state.completed_exposures, 10);

    // Perform autofocus
    state.mark_autofocus_performed();
    assert_eq!(state.last_autofocus_frame, 10);

    // Complete more exposures
    for _ in 0..5 {
        state.increment_exposure_count();
    }
    assert_eq!(state.completed_exposures, 15);

    // Perform dither
    state.mark_dither_performed();
    assert_eq!(state.last_dither_frame, 15);
}

#[tokio::test]
async fn test_hfr_baseline_reset() {
    let mut state = TriggerState::new();

    // Initial HFR
    state.update_hfr(2.5);
    assert_eq!(state.baseline_hfr, Some(2.5));
    assert_eq!(state.current_hfr, Some(2.5));

    // HFR changes
    state.update_hfr(3.0);
    assert_eq!(state.baseline_hfr, Some(2.5)); // Baseline stays
    assert_eq!(state.current_hfr, Some(3.0));

    // Reset baseline
    state.reset_baseline_hfr();
    assert_eq!(state.baseline_hfr, Some(3.0)); // Baseline updated
    assert_eq!(state.current_hfr, Some(3.0));
}

// OnTrackingLimitHit trigger tests

/// Helper to create a TriggerState simulating a mount that hit its tracking limit
fn make_limit_hit_state() -> TriggerState {
    let mut state = TriggerState::new();
    // A mount only reaches its tracking limit while tracking a target, and
    // the flip trigger now requires one.
    state.set_target(270.0, 60.0);
    state.mount_tracking_expected = true;
    state.mount_tracking_lost = true;
    state.mount_is_tracking = Some(false);
    state.mount_status_query_failed = false;
    state.mount_slewing = Some(false);
    state.mount_parked = Some(false);
    state.current_hour_angle = Some(1.5); // 1.5h past meridian
    state.pier_side = Some(PierSide::West); // Pre-flip side
    state.tracking_limit_detected_at = Some(chrono::Utc::now().timestamp() - 600); // 10 min ago
    state
}

#[tokio::test]
async fn test_on_tracking_limit_hit_immediate_flip() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0, // Flip immediately
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Limit Hit",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let state = make_limit_hit_state();
    assert!(
        trigger.check(&state).await,
        "Should trigger immediately when wait is 0"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_with_wait_not_elapsed() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 5.0, // 5 min wait
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Limit Hit Wait",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    // Detected just 1 minute ago - wait hasn't elapsed
    state.tracking_limit_detected_at = Some(chrono::Utc::now().timestamp() - 60);
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - wait period not elapsed"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_with_wait_elapsed() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 5.0, // 5 min wait
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Limit Hit Wait Elapsed",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    // Detected 10 minutes ago - well past the 5 min wait
    state.tracking_limit_detected_at = Some(chrono::Utc::now().timestamp() - 600);
    assert!(
        trigger.check(&state).await,
        "Should trigger - wait period elapsed"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_not_tracking_lost() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Not Lost",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.mount_tracking_lost = false; // Tracking is fine
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - tracking not lost"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_connection_lost() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Disconnected",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.mount_status_query_failed = true; // Connection lost
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - mount disconnected"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_wrong_pier_side() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Wrong Pier",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.pier_side = Some(PierSide::East); // Already on post-flip side
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - already on East side"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_negative_ha() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Negative HA",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.current_hour_angle = Some(-2.0); // East of meridian
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - target east of meridian"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_mount_slewing() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Slewing",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.mount_slewing = Some(true); // Mount is slewing
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - mount is slewing"
    );
}

#[tokio::test]
async fn test_on_tracking_limit_hit_already_flipped() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Already Flipped",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = make_limit_hit_state();
    state.has_flipped_this_target = true; // Already flipped
    assert!(
        !trigger.check(&state).await,
        "Should NOT trigger - already flipped for target"
    );
}

#[tokio::test]
async fn test_mount_tracking_lost_defers_to_limit_hit() {
    let mut trigger = Trigger::new(
        "test",
        "Test Tracking Lost Defers",
        TriggerType::MountTrackingLost,
        RecoveryAction::Pause,
    );

    let mut state = make_limit_hit_state();
    // Set OnTrackingLimitHit as the active method
    state.meridian_trigger_method = Some(crate::MeridianTriggerMethod::OnTrackingLimitHit);

    // Heuristic matches limit hit → MountTrackingLost should NOT fire
    assert!(
        !trigger.check(&state).await,
        "MountTrackingLost should defer to MeridianFlip when limit-hit heuristic matches"
    );
}

#[tokio::test]
async fn test_mount_tracking_lost_fires_when_not_limit_hit() {
    let mut trigger = Trigger::new(
        "test",
        "Test Tracking Lost Fires",
        TriggerType::MountTrackingLost,
        RecoveryAction::Pause,
    );

    let mut state = TriggerState::new();
    state.mount_tracking_expected = true;
    state.mount_tracking_lost = true;
    state.meridian_trigger_method = Some(crate::MeridianTriggerMethod::OnTrackingLimitHit);
    // No HA data → heuristic fails → MountTrackingLost should fire
    assert!(
        trigger.check(&state).await,
        "MountTrackingLost should fire when heuristic doesn't match"
    );
}

#[tokio::test]
async fn test_mount_tracking_lost_fires_with_different_trigger_method() {
    let mut trigger = Trigger::new(
        "test",
        "Test Tracking Lost Normal",
        TriggerType::MountTrackingLost,
        RecoveryAction::Pause,
    );

    let mut state = make_limit_hit_state();
    // Not using OnTrackingLimitHit → MountTrackingLost should fire normally
    state.meridian_trigger_method = Some(crate::MeridianTriggerMethod::MinutesPastMeridian);

    assert!(
        trigger.check(&state).await,
        "MountTrackingLost should fire normally when OnTrackingLimitHit is not active"
    );
}

#[tokio::test]
async fn test_hfr_degraded_forces_autofocus_when_invalidated() {
    let mut trigger = Trigger::new(
        "test",
        "HFR Trigger",
        TriggerType::HfrDegraded {
            threshold_percent: 20.0,
            absolute_threshold: 0.0,
            consecutive_frames: 3,
        },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    state.invalidate_autofocus("binning changed");

    assert!(trigger.check(&state).await);
}

#[test]
fn test_target_change_invalidates_autofocus() {
    let mut state = TriggerState::new();
    state.current_target_name = Some("M31".to_string());
    state.baseline_hfr = Some(2.0);
    state.current_hfr = Some(2.2);

    state.set_meridian_target("M42".to_string());

    assert!(state.autofocus_invalidated);
    assert_eq!(state.baseline_hfr, None);
}

/// A filter change restarts the HFR baseline (filters do not share one) but
/// is not by itself a reason to refocus: that is the operator's "Auto focus
/// on filter change" setting, off by default, and filter focus offsets carry
/// the known per-filter shift. Forcing it here made the HFR trigger run a full
/// autofocus on "L" every time its 5-minute cooldown expired during a Smart
/// Exposure node cycling Ha/OIII/SII -- measured by the simulator soak, and the
/// same interleaving that cost the 2026-09-14 night.
#[test]
fn test_filter_change_restarts_the_hfr_baseline_without_forcing_autofocus() {
    let mut state = TriggerState::new();
    state.current_filter = Some("L".to_string());
    state.baseline_hfr = Some(2.0);
    state.current_hfr = Some(2.1);

    state.set_filter("Ha".to_string());

    assert!(state.filter_changed);
    assert!(!state.autofocus_invalidated);
    assert_eq!(state.baseline_hfr, None);
}

#[tokio::test]
async fn a_rotating_filter_plan_in_focus_does_not_fire_the_hfr_trigger() {
    let mut trigger = Trigger::new(
        "hfr_degraded",
        "HFR Degradation",
        TriggerType::HfrDegraded {
            threshold_percent: 20.0,
            absolute_threshold: 0.0,
            consecutive_frames: 3,
        },
        RecoveryAction::Autofocus,
    );
    let mut state = TriggerState::new();
    for filter in ["Ha", "OIII", "SII", "Ha", "OIII", "SII"] {
        state.set_filter(filter.to_string());
        state.update_hfr(2.0);
        assert!(
            !trigger.check(&state).await,
            "an in-focus frame after a change to {filter} fired a refocus"
        );
    }
}

#[tokio::test]
async fn test_on_tracking_limit_hit_uses_limit_time_without_hour_angle() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };
    let mut trigger = Trigger::new(
        "test",
        "Test Limit Time",
        TriggerType::MeridianFlip { config },
        RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
    );

    let mut state = TriggerState::new();
    state.set_target(270.0, 60.0);
    state.mount_tracking_expected = true;
    state.mount_tracking_lost = true;
    state.mount_is_tracking = Some(false);
    state.mount_status_query_failed = false;
    state.mount_slewing = Some(false);
    state.mount_parked = Some(false);
    state.mount_tracking_limit_time = Some(Utc::now().timestamp() - 5);

    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn test_tracking_limit_reset_on_tracking_resume() {
    let mut state = make_limit_hit_state();
    assert!(state.tracking_limit_detected_at.is_some());
    assert!(state.mount_tracking_lost);

    state.reset_tracking_limit_detection();
    assert!(state.tracking_limit_detected_at.is_none());
    assert!(!state.mount_tracking_lost);
}
