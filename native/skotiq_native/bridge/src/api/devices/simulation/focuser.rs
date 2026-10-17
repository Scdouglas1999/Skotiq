use super::*;

/// Simulated focuser state
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

/// Get focuser status
pub async fn api_get_focuser_status(device_id: String) -> Result<FocuserStatus, SkotiqError> {
    let mgr = get_device_manager();

    // Get all focuser status components
    let position = mgr
        .focuser_get_position(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let moving = mgr
        .focuser_is_moving(&device_id)
        .await
        .map_err(SkotiqError::from)?;
    let temperature = mgr.focuser_get_temp(&device_id).await.unwrap_or(None);
    let (max_position, step_size) = match mgr.focuser_get_details(&device_id).await {
        Ok(details) => details,
        Err(e) => {
            tracing::warn!(
                "Failed to get focuser details for {}: {:?}. Returning unknown max/step values.",
                device_id,
                e
            );
            (0, 0.0)
        }
    };
    let is_absolute = mgr
        .focuser_is_absolute(&device_id)
        .await
        .map_err(SkotiqError::from)?;

    Ok(FocuserStatus {
        connected: true,
        position,
        moving,
        temperature,
        max_position,
        step_size,
        is_absolute,
        has_temperature: temperature.is_some(),
    })
}

/// Move focuser to position
pub async fn api_focuser_move_to(device_id: String, position: i32) -> Result<(), SkotiqError> {
    // Real device - use DeviceManager for proper driver routing
    let mgr = get_device_manager();
    mgr.focuser_move_abs(&device_id, position)
        .await
        .map_err(SkotiqError::from)
}

/// Move focuser by relative amount
pub async fn api_focuser_move_relative(
    device_id: String,
    delta: i32,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_move_rel(&device_id, delta)
        .await
        .map_err(SkotiqError::from)
}

/// Halt focuser
pub async fn api_focuser_halt(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.focuser_halt(&device_id)
        .await
        .map_err(SkotiqError::from)
}
