//! `wait_time.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Wait time instruction

/// Execute wait for time
pub async fn execute_wait_time(
    config: &WaitTimeConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    // Wait until specific time
    if let Some(until) = config.wait_until {
        let now = chrono::Utc::now().timestamp();
        if now < until {
            // Why: `now < until` is checked above, so `until - now` is positive
            // i64 (no two-complement wrap risk). i64 -> u64 is then lossless for
            // any positive value.
            let total_wait_secs = u64::try_from(until - now).unwrap_or(0);
            let wait_until_str = chrono::DateTime::from_timestamp(until, 0)
                .map(|dt| dt.format("%H:%M:%S").to_string())
                // Why: `from_timestamp` only fails for out-of-range
                // i64 seconds (year ±5_400_000); user input here is bounded by the UI
                // datetime picker. Raw epoch seconds as the display fallback preserves
                // log traceability if a hypothetical extreme value sneaks in.
                .unwrap_or_else(|| until.to_string());

            tracing::info!(
                "Waiting until {} ({} seconds)",
                wait_until_str,
                total_wait_secs
            );

            // Emit initial progress
            if let Some(cb) = progress_callback {
                cb(0.0, format!("Waiting until {}", wait_until_str));
            }

            // Wait in 1-second increments to allow cancellation
            for elapsed in 0..total_wait_secs {
                if let Some(result) = ctx.check_cancelled() {
                    return result;
                }

                // Emit progress every 10 seconds
                if elapsed % 10 == 0 {
                    // Why: u64 -> f64. Wait durations under ~285k years fit
                    // losslessly in f64's 53-bit mantissa.
                    let progress = (elapsed as f64 / total_wait_secs as f64) * 100.0;
                    let remaining = total_wait_secs - elapsed;
                    if let Some(cb) = progress_callback {
                        cb(progress, format!("{}s remaining", remaining));
                    }
                }

                sleep(Duration::from_secs(1)).await;
            }

            if let Some(cb) = progress_callback {
                cb(100.0, "Target time reached".to_string());
            }
        }
        return InstructionResult::success_with_message("Wait time reached");
    }

    // Wait for twilight
    if let Some(twilight) = &config.wait_for_twilight {
        tracing::info!("Waiting for {:?} twilight", twilight);

        // Calculate twilight time based on observer location
        let observer_location = match (ctx.latitude, ctx.longitude) {
            (Some(lat), Some(lon)) => Some((lat, lon)),
            _ => ctx.device_ops.get_observer_location(),
        };
        let (lat, lon) = match observer_location {
            Some(loc) => loc,
            None => {
                return InstructionResult::failure(
                    "Cannot evaluate twilight trigger: observer location is unavailable. Set site latitude/longitude in settings.",
                );
            }
        };
        let twilight_time = calculate_twilight_time(lat, lon, twilight);

        let now = chrono::Utc::now().timestamp();
        if twilight_time == crate::solar::SUN_ALTITUDE_NEVER_REACHED {
            return InstructionResult::failure(format!(
                "{:?} twilight does not occur at latitude {:.3} and longitude {:.3} for the current date. \
Sequence cannot wait for an unreachable twilight state.",
                twilight, lat, lon
            ));
        }
        if now < twilight_time {
            // Why: `now < twilight_time` is checked above, so the difference is
            // positive i64. i64 -> u64 is then lossless via try_from.
            let total_wait_secs = u64::try_from(twilight_time - now).unwrap_or(0);
            tracing::info!(
                "Waiting {} seconds for {:?} twilight",
                total_wait_secs,
                twilight
            );

            // Emit initial progress
            if let Some(cb) = progress_callback {
                cb(0.0, format!("Waiting for {:?} twilight", twilight));
            }

            for elapsed in 0..total_wait_secs {
                if let Some(result) = ctx.check_cancelled() {
                    return result;
                }

                // Emit progress every 30 seconds
                if elapsed % 30 == 0 {
                    // Why: u64 -> f64. Twilight wait durations (~hours) fit
                    // losslessly in f64's 53-bit mantissa.
                    let progress = (elapsed as f64 / total_wait_secs as f64) * 100.0;
                    let remaining_mins = (total_wait_secs - elapsed) / 60;
                    if let Some(cb) = progress_callback {
                        cb(
                            progress,
                            format!("{:?}: {}m remaining", twilight, remaining_mins),
                        );
                    }
                }

                sleep(Duration::from_secs(1)).await;
            }

            if let Some(cb) = progress_callback {
                cb(100.0, format!("{:?} twilight reached", twilight));
            }
        }

        return InstructionResult::success_with_message(format!("{:?} twilight reached", twilight));
    }

    // Neither a target time nor a twilight condition was set. Returning Success
    // here made an unconfigured Wait node complete immediately without waiting
    // microseconds — and the canonical use of this node is "wait until
    // astronomical dark before imaging", so skipping it starts the run in
    // daylight. Fail instead: a wait that cannot wait has not been satisfied.
    InstructionResult::failure(
        "Wait node has no wait condition: set a target time or a twilight condition",
    )
}

/// Timestamp of the next EVENING crossing of the twilight type's Sun altitude.
///
/// The math lives in [`crate::solar`] so this and the `DawnApproaching`
/// trigger are calibrated against the same Sun.
pub(crate) fn calculate_twilight_time(
    latitude: f64,
    longitude: f64,
    twilight_type: &TwilightType,
) -> i64 {
    let altitude_threshold: f64 = match twilight_type {
        TwilightType::Civil => -6.0,
        TwilightType::Nautical => -12.0,
        TwilightType::Astronomical => -18.0,
    };
    crate::solar::time_of_sun_altitude(
        latitude,
        longitude,
        altitude_threshold,
        crate::solar::SunCrossing::Setting,
    )
}
