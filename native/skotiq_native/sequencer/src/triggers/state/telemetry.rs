//! Live readings of the rig and the sky.

use super::part::state_part;
use crate::PierSide;
use std::time::Instant;

state_part! {
    /// What the rig and the sky read right now: mount status, weather, cloud
    /// motion, transparency. A property of the rig, not of a run, so starting
    /// a run does not reset it. Two exceptions, forgotten when a fresh (not
    /// resumed) run starts: `mount_is_tracking`, so that run arms its tracking
    /// baseline from its own readings, and `dome_shutter_open_expected`, which
    /// only that run's Open Dome step sets.
    pub struct RigTelemetry, checkpointed as TelemetrySnapshot {
        persisted {
            /// Current pier side of the mount
            pub pier_side: Option<PierSide>,
            /// Unix timestamp when mount will hit its tracking limit (if reported by mount)
            pub mount_tracking_limit_time: Option<i64>,
            pub mount_is_tracking: Option<bool>,
            /// Whether the mount is currently slewing (from status polling)
            pub mount_slewing: Option<bool>,
            /// Whether the mount is currently parked (from status polling)
            pub mount_parked: Option<bool>,
            /// Set to true when the most recent mount status query failed (connection lost / error).
            /// Defaults to false (no failure). The tracking-limit heuristic requires this to be false.
            pub mount_status_query_failed: bool,
            /// Current humidity percentage (0-100)
            pub current_humidity: Option<f64>,
            /// Hardware safety-monitor verdict: `true` when the connected safety/weather
            /// device reports safe (or, under `WarnOnly`, the last good reading). Fed by
            /// the executor's safety poll (`executor/mod.rs` `safety_is_safe`).
            pub weather_safe: bool,
            pub dome_shutter_status: Option<String>,
            /// Set by the run's Open Dome step once the shutter reads open,
            /// cleared by Close Dome and Park Dome before they close it.
            pub dome_shutter_open_expected: bool,
            pub dawn_time: Option<i64>,
        }
        transient {
            /// Defense-in-depth: the Dart-side `weatherSafetyProvider` overall verdict,
            /// composed from the user's configured thresholds + API/cloud sources (which
            /// the hardware `weather_safe` poll knows nothing about). `Some(true)` means
            /// the Dart side computed UNSAFE; `Some(false)` means it computed SAFE;
            /// `None` means the Dart side has not reported (e.g. provider disabled / no
            /// data) and this layer abstains. Folded into the `WeatherUnsafe` trigger as
            /// an ADDITIONAL unsafe source — it can only make the rig safer, never less
            /// safe than the hardware verdict ("fail closed"). Pushed via
            /// `ExecutorCommand::UpdateWeatherVerdict`.
            pub weather_verdict_unsafe: Option<bool>,
            /// The monotonic timestamp of the most recent `update_weather_verdict`
            /// push. `None` until the Dart side has pushed at least once.
            ///
            /// A pushed `Some(true)` (UNSAFE) verdict is FAIL-CLOSED: a silent Dart feed
            /// does NOT auto-clear it, because holding the sequence paused is the safe
            /// behaviour. An INDEFINITE hold must not be SILENT, though, so the safety
            /// poll loop uses this timestamp to detect a stale-AND-unsafe verdict and
            /// emit a loud warning: the operator learns the hold is sustained by a dead
            /// feed rather than fresh data. It is NEVER used to resume.
            pub weather_verdict_last_update: Option<Instant>,
            /// The pushed UNSAFE verdict comes only from advisory sources: an internet
            /// forecast or cloud model, not a sensor at the site. An advisory verdict
            /// may hold the run but never parks it or ends it.
            pub weather_verdict_advisory: bool,
            /// Until this instant the operator has said the sky is clear: the app's
            /// verdict is not acted on and a weather hold resumes without waiting for
            /// the safe period. A hardware safety monitor that reads unsafe still
            /// counts.
            pub weather_operator_clear_until: Option<Instant>,
            /// Current cloud coverage percentage (0-100). Source: Dart
            /// `cloudCoverPercentageProvider` (Open-Meteo) merged with analyzer.
            pub current_cloud_coverage_percent: Option<f64>,
            /// Predicted minutes until significant clouds reach the user location.
            /// `Some(n)` when the analyzer reports an approaching cloud bank;
            /// `None` when clouds are absent, stationary, or moving away.
            pub predicted_cloud_arrival_minutes: Option<f64>,
            /// Predicted minutes until a clear opening (gap in the cloud field)
            /// reaches the user. `Some(n)` while currently overcast and a hole
            /// is approaching; `None` when no opening is predicted.
            pub predicted_cloud_opening_minutes: Option<f64>,
            /// Predicted opening duration in seconds. Pairs with
            /// `predicted_cloud_opening_minutes`; the `CloudOpeningIn` trigger
            /// rejects openings shorter than the user's `minimum_duration_secs`.
            pub predicted_cloud_opening_duration_secs: Option<f64>,
            /// (alt, az) of a clear-sky direction reported by the analyzer. Used
            /// by `RecoveryAction::SlewToGapAndContinue` to choose where to
            /// re-point. `None` => no usable gap; the recovery action falls
            /// back to `PauseAndWaitForClear`.
            pub predicted_clear_sky_direction: Option<(f64, f64)>,
            /// Most recent timestamp at which we received a cloud-motion update.
            /// Surfaced to the run dashboard so the operator can tell whether the
            /// telemetry is fresh; also used by validation to flag stale data.
            pub cloud_motion_last_update: Option<Instant>,
            /// Live transparency reading (0.0..=1.0; 1.0 = clear). Consumed by
            /// `TransparencyDropped`.
            pub current_transparency: Option<f64>,
        }
    }
}
