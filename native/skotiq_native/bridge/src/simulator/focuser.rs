use crate::device::FocuserStatus;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Instant;
use tokio::sync::RwLock;

pub(crate) static SIM_FOCUSER: OnceLock<Arc<RwLock<SimulatedFocuser>>> = OnceLock::new();

#[flutter_rust_bridge::frb]
pub struct SimulatedFocuser {
    pub status: FocuserStatus,
}

impl Default for SimulatedFocuser {
    fn default() -> Self {
        Self {
            status: FocuserStatus {
                connected: false,
                position: 25000,
                moving: false,
                temperature: Some(20.0),
                max_position: 50000,
                step_size: 1.0,
                is_absolute: true,
                has_temperature: true,
            },
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub fn get_sim_focuser() -> &'static Arc<RwLock<SimulatedFocuser>> {
    SIM_FOCUSER.get_or_init(|| Arc::new(RwLock::new(SimulatedFocuser::default())))
}

/// Environment switch for a cooling night: degrees Celsius per hour the
/// simulated focuser's temperature probe falls, from the first read on.
///
/// Unset (the default) keeps the probe at a constant 20 C, which also means a
/// `TemperatureShift` refocus trigger can never fire and focus never drifts —
/// fine for a unit test, and a night no real telescope has. A soak run sets it
/// so the temperature trigger, the HFR trigger and autofocus all have
/// something real to respond to.
pub(crate) const SIM_NIGHT_COOLING_ENV: &str = "SKOTIQ_SIM_NIGHT_COOLING_C_PER_HOUR";

/// Probe temperature at the start of the simulated night.
const SIM_FOCUSER_START_TEMP_C: f64 = 20.0;

/// How far best focus moves, in focuser steps, per degree the tube cools.
/// Sized against `sim_frame`'s 0.006 px sigma per step: two degrees of cooling
/// moves focus ~100 steps and widens stars by about a third, which is the size
/// of drift an HFR trigger exists to catch.
pub(crate) const SIM_FOCUS_STEPS_PER_C: f64 = 50.0;

fn sim_night_cooling_rate() -> Option<f64> {
    static RATE: OnceLock<Option<f64>> = OnceLock::new();
    *RATE.get_or_init(|| {
        let raw = std::env::var(SIM_NIGHT_COOLING_ENV).ok()?;
        match raw.trim().parse::<f64>() {
            Ok(rate) if rate.is_finite() => Some(rate),
            _ => {
                tracing::error!(
                    "{}={:?} is not a number of degrees per hour; the simulated night stays at a constant temperature",
                    SIM_NIGHT_COOLING_ENV,
                    raw
                );
                None
            }
        }
    })
}

fn sim_night_epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

/// Degrees the simulated tube has cooled since the night began; zero when no
/// cooling rate is configured.
pub(crate) fn sim_night_cooling_c() -> f64 {
    match sim_night_cooling_rate() {
        Some(rate) => rate * sim_night_epoch().elapsed().as_secs_f64() / 3600.0,
        None => 0.0,
    }
}

/// The simulated focuser's probe temperature now.
pub(crate) fn sim_focuser_temperature_c() -> f64 {
    SIM_FOCUSER_START_TEMP_C - sim_night_cooling_c()
}

/// Steps best focus has moved since the night began: a cooling tube shortens,
/// so the focuser has to travel outward to follow it.
pub(crate) fn sim_thermal_focus_shift_steps() -> i32 {
    (sim_night_cooling_c() * SIM_FOCUS_STEPS_PER_C).round() as i32
}

/// Environment switch: steps per second the simulated focuser travels.
///
/// Unset (the default), a move lands at once. Set, a move command returns as
/// soon as the move starts and the focuser then reports `moving` and the
/// positions it passes until it arrives, as the ZWO EAF does: whoever needs
/// the focuser at rest has to wait for it.
pub(crate) const SIM_FOCUSER_STEPS_PER_SEC_ENV: &str = "SKOTIQ_SIM_FOCUSER_STEPS_PER_SEC";

/// A simulated focuser move under way. Kept out of [`SimulatedFocuser`],
/// which is mirrored to Dart.
#[derive(Debug, Clone, Copy)]
struct Travel {
    start: Instant,
    from: i32,
    to: i32,
    steps_per_sec: f64,
}

impl Travel {
    /// The position passed so far, and whether the focuser still moves.
    fn now(&self) -> (i32, bool) {
        let span = self.to.abs_diff(self.from) as f64;
        let covered = self.start.elapsed().as_secs_f64() * self.steps_per_sec;
        if covered >= span {
            (self.to, false)
        } else {
            (
                self.from + (self.to - self.from).signum() * covered as i32,
                true,
            )
        }
    }
}

struct Motion {
    steps_per_sec: Option<f64>,
    travel: Option<Travel>,
}

fn motion() -> MutexGuard<'static, Motion> {
    static MOTION: OnceLock<Mutex<Motion>> = OnceLock::new();
    MOTION
        .get_or_init(|| {
            let steps_per_sec = std::env::var(SIM_FOCUSER_STEPS_PER_SEC_ENV)
                .ok()
                .and_then(|raw| raw.trim().parse::<f64>().ok())
                .filter(|rate| rate.is_finite() && *rate > 0.0);
            Mutex::new(Motion {
                steps_per_sec,
                travel: None,
            })
        })
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

/// Sets the travel rate a test needs; `None` makes moves land at once.
#[cfg(test)]
pub(crate) fn set_sim_focuser_steps_per_sec(steps_per_sec: Option<f64>) {
    let mut motion = motion();
    motion.steps_per_sec = steps_per_sec;
    motion.travel = None;
}

/// Starts a move from `from` to `to`. Without a travel rate it has already
/// landed.
pub(crate) fn begin_sim_focuser_travel(from: i32, to: i32) {
    let mut motion = motion();
    motion.travel = motion.steps_per_sec.map(|steps_per_sec| Travel {
        start: Instant::now(),
        from,
        to,
        steps_per_sec,
    });
}

/// Stops a move under way; the position it stopped at, or `None` when no
/// move was under way.
pub(crate) fn halt_sim_focuser_travel() -> Option<i32> {
    let (position, moving) = motion().travel.take()?.now();
    moving.then_some(position)
}

/// `status` as the focuser reads now: during a move, the position passed so
/// far, and moving. `status.position` holds where the move lands.
pub(crate) fn sim_focuser_status_now(status: &mut FocuserStatus) {
    let Some(travel) = motion().travel else {
        return;
    };
    let (position, moving) = travel.now();
    status.position = position;
    status.moving |= moving;
}
