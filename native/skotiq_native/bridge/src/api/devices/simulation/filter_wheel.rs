use super::*;

pub(crate) static SIM_FILTERWHEEL: OnceLock<Arc<RwLock<SimulatedFilterWheel>>> = OnceLock::new();

#[flutter_rust_bridge::frb]
pub struct SimulatedFilterWheel {
    pub status: FilterWheelStatus,
}

impl Default for SimulatedFilterWheel {
    fn default() -> Self {
        Self {
            status: FilterWheelStatus {
                connected: false,
                position: 1,
                moving: false,
                filter_count: 7,
                filter_names: vec![
                    "L".to_string(),
                    "R".to_string(),
                    "G".to_string(),
                    "B".to_string(),
                    "Ha".to_string(),
                    "OIII".to_string(),
                    "SII".to_string(),
                ],
            },
        }
    }
}

pub(crate) fn get_sim_filterwheel() -> &'static Arc<RwLock<SimulatedFilterWheel>> {
    SIM_FILTERWHEEL.get_or_init(|| Arc::new(RwLock::new(SimulatedFilterWheel::default())))
}

pub(crate) const FILTER_WHEEL_POSITION_FAILURE_THRESHOLD: u32 = 3;
pub(crate) const FILTER_WHEEL_POSITION_BACKOFF_BASE: Duration = Duration::from_secs(10);
pub(crate) const FILTER_WHEEL_POSITION_BACKOFF_MAX: Duration = Duration::from_secs(120);

#[derive(Debug)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FilterWheelStatusPollState {
    pub(crate) position_backoff: ConsecutiveFailureBackoff,
    pub(crate) last_position: Option<i32>,
}

impl Default for FilterWheelStatusPollState {
    fn default() -> Self {
        Self {
            position_backoff: ConsecutiveFailureBackoff::new(
                FILTER_WHEEL_POSITION_FAILURE_THRESHOLD,
                FILTER_WHEEL_POSITION_BACKOFF_BASE,
                FILTER_WHEEL_POSITION_BACKOFF_MAX,
                2.0,
            ),
            last_position: None,
        }
    }
}

pub(crate) static FILTER_WHEEL_STATUS_POLL_STATES: OnceLock<
    StdMutex<HashMap<String, FilterWheelStatusPollState>>,
> = OnceLock::new();

pub(crate) fn filter_wheel_status_poll_states(
) -> &'static StdMutex<HashMap<String, FilterWheelStatusPollState>> {
    FILTER_WHEEL_STATUS_POLL_STATES.get_or_init(|| StdMutex::new(HashMap::new()))
}

/// Poll Position without hammering a driver that has demonstrated a sustained
/// failure. The first two consecutive errors propagate so real one-off failures
/// remain visible. From the third failure onward, status polling serves the
/// last good value (or the unknown sentinel) and retries with exponential
/// backoff.
pub(crate) async fn poll_filter_wheel_position(
    manager: &DeviceManager,
    device_id: &str,
) -> Result<i32, SkotiqError> {
    let now = Instant::now();
    let backed_off = {
        let mut states = filter_wheel_status_poll_states()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let state = states.entry(device_id.to_string()).or_default();
        if state.position_backoff.should_attempt(now) {
            None
        } else {
            Some((
                state.last_position.unwrap_or(-1),
                state
                    .position_backoff
                    .retry_after(now)
                    .unwrap_or(Duration::ZERO),
            ))
        }
    };

    if let Some((position, retry_after)) = backed_off {
        tracing::trace!(
            "[filter-wheel poll] Position read for {} backed off for another {:?}",
            device_id,
            retry_after
        );
        return Ok(position);
    }

    match manager.filter_wheel_get_position(device_id).await {
        Ok(position) => {
            let recovered_after = {
                let mut states = filter_wheel_status_poll_states()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let state = states.entry(device_id.to_string()).or_default();
                let failures = state.position_backoff.consecutive_failures();
                state.position_backoff.record_success();
                state.last_position = Some(position);
                failures
            };
            if recovered_after >= FILTER_WHEEL_POSITION_FAILURE_THRESHOLD {
                tracing::info!(
                    "[filter-wheel poll] Position read for {} recovered after {} failures",
                    device_id,
                    recovered_after
                );
            }
            Ok(position)
        }
        Err(error) => {
            let (failures, delay, fallback) = {
                let mut states = filter_wheel_status_poll_states()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let state = states.entry(device_id.to_string()).or_default();
                let delay = state.position_backoff.record_failure(Instant::now());
                (
                    state.position_backoff.consecutive_failures(),
                    delay,
                    state.last_position.unwrap_or(-1),
                )
            };

            if let Some(delay) = delay {
                tracing::warn!(
                    "[filter-wheel poll] Position read for {} failed {} consecutive times; backing off for {:?}: {}",
                    device_id,
                    failures,
                    delay,
                    error
                );
                Ok(fallback)
            } else {
                Err(SkotiqError::from(error))
            }
        }
    }
}
