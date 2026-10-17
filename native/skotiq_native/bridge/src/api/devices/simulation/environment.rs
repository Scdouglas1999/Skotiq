use super::*;

// Observatory accessory simulators

/// Backing state for the dome simulator advertised by discovery.
pub(crate) static SIM_DOME: OnceLock<Arc<RwLock<SimulatedDome>>> = OnceLock::new();

pub(crate) struct SimulatedDome {
    pub status: DomeStatus,
}

impl Default for SimulatedDome {
    fn default() -> Self {
        Self {
            status: DomeStatus {
                connected: false,
                azimuth: 0.0,
                altitude: None,
                shutter_status: ShutterState::Closed,
                slewing: false,
                at_home: true,
                at_park: true,
                can_set_altitude: false,
                can_set_azimuth: true,
                can_set_shutter: true,
                can_slave: true,
                is_slaved: false,
            },
        }
    }
}

pub(crate) fn get_sim_dome() -> &'static Arc<RwLock<SimulatedDome>> {
    SIM_DOME.get_or_init(|| Arc::new(RwLock::new(SimulatedDome::default())))
}

/// Backing state for the observing-conditions simulator.
pub(crate) static SIM_WEATHER: OnceLock<Arc<RwLock<SimulatedWeather>>> = OnceLock::new();

pub(crate) struct SimulatedWeather {
    pub connected: bool,
    pub conditions: WeatherConditions,
}

impl Default for SimulatedWeather {
    fn default() -> Self {
        Self {
            connected: false,
            conditions: WeatherConditions {
                temperature: Some(10.0),
                humidity: Some(45.0),
                pressure: Some(1013.25),
                cloud_cover: Some(5.0),
                dew_point: Some(-1.5),
                wind_speed: Some(1.0),
                wind_direction: Some(180.0),
                sky_quality: Some(21.5),
                sky_temperature: Some(-18.0),
                rain_rate: Some(0.0),
            },
        }
    }
}

pub(crate) fn get_sim_weather() -> &'static Arc<RwLock<SimulatedWeather>> {
    SIM_WEATHER.get_or_init(|| Arc::new(RwLock::new(SimulatedWeather::default())))
}

/// Backing state for the safety-monitor simulator. It starts safe so routine
/// simulator smoke tests cannot trigger emergency actions accidentally.
pub(crate) static SIM_SAFETY_MONITOR: OnceLock<Arc<RwLock<SimulatedSafetyMonitor>>> =
    OnceLock::new();

pub(crate) struct SimulatedSafetyMonitor {
    pub status: SafetyStatus,
}

impl Default for SimulatedSafetyMonitor {
    fn default() -> Self {
        Self {
            status: SafetyStatus {
                connected: false,
                is_safe: true,
            },
        }
    }
}

pub(crate) fn get_sim_safety_monitor() -> &'static Arc<RwLock<SimulatedSafetyMonitor>> {
    SIM_SAFETY_MONITOR.get_or_init(|| Arc::new(RwLock::new(SimulatedSafetyMonitor::default())))
}
