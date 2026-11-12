//! Filter wheel operations: the events and read-health bookkeeping around
//! the wheel's handle (see [`crate::device_manager::rig::filter_wheel`]).

use crate::adaptive_polling::ConsecutiveFailureBackoff;
use crate::device::*;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::event::EquipmentEvent;
use std::collections::HashMap;
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

impl DeviceManager {
    /// Move the wheel to a 0-based slot, publishing `FilterChanging` before
    /// the move and `FilterChanged` once it ends (see [`state_events`]).
    ///
    /// A move that fails still publishes `FilterChanged` with the slot the
    /// wheel reads back, so no UI is left showing the wheel as moving; when
    /// the wheel cannot be read either, the disconnect handling takes over.
    ///
    /// [`state_events`]: crate::device_manager::ops::state_events
    pub async fn filter_wheel_set_position(
        &self,
        device_id: &str,
        position: i32,
    ) -> Result<(), DeviceOpError> {
        // An unknown id has nothing to report on; answer before announcing a
        // move that cannot start.
        if self.registered_driver_type(device_id).await.is_none() {
            return Err(DeviceOpError::device_not_found(device_id));
        }
        let _command = self.command_activity.begin(device_id);
        // `-1` is the documented "position unknown" sentinel of
        // `FilterChanging.from_position`, for a wheel that cannot say where it
        // is (mid-move, or not homed yet after a reconnect).
        let from_position = self
            .filter_wheel_get_position(device_id)
            .await
            .unwrap_or(-1);
        // The Log names slots by the profile's names ("R (2 of 8)"), not by
        // number.
        let names = self
            .filter_wheel_get_config(device_id)
            .await
            .map(|(_, names)| names)
            .unwrap_or_default();
        let slot_name = |slot: i32| crate::filter_matching::filter_slot_name(&names, slot);

        self.publish_state_event(EquipmentEvent::FilterChanging {
            device_id: device_id.to_string(),
            from_position,
            to_position: position,
            filter_name: slot_name(position),
            from_filter_name: slot_name(from_position),
        });

        let result = match self.filter_wheel(device_id).await {
            Ok(wheel) => wheel.move_to_slot(position).await,
            Err(e) => Err(e),
        };

        let reached = match &result {
            Ok(()) => Some(position),
            Err(_) => self.filter_wheel_get_position(device_id).await.ok(),
        };
        if let Some(reached) = reached {
            self.publish_state_event(EquipmentEvent::FilterChanged {
                device_id: device_id.to_string(),
                position: reached,
                filter_name: slot_name(reached),
            });
        }

        result
    }

    /// Read the filter wheel's position. The outcome feeds the device's read health (see
    /// [`crate::device_manager::read_health`]).
    pub async fn filter_wheel_get_position(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let result = match self.filter_wheel(device_id).await {
            Ok(wheel) => wheel.position().await,
            Err(e) => Err(e),
        };
        self.note_status_read(device_id, &result);
        result
    }

    /// The wheel's slot for a background status poll: a wheel that keeps
    /// failing to answer is asked less often (see
    /// [`poll_filter_wheel_position`]).
    pub async fn filter_wheel_poll_position(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        poll_filter_wheel_position(self, device_id).await
    }

    /// Whether the wheel is turning, for a background poll that has just read
    /// `position`.
    pub async fn filter_wheel_poll_is_moving(
        &self,
        device_id: &str,
        position: i32,
    ) -> Result<bool, DeviceOpError> {
        self.filter_wheel(device_id)
            .await?
            .is_moving_at(position)
            .await
    }

    pub async fn filter_wheel_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        self.filter_wheel(device_id).await?.is_moving().await
    }

    /// The number of slots and their names.
    pub async fn filter_wheel_get_config(
        &self,
        device_id: &str,
    ) -> Result<(i32, Vec<String>), DeviceOpError> {
        self.filter_wheel(device_id).await?.config().await
    }

    /// Push the equipment profile's filter names to the wheel.
    pub async fn filter_wheel_set_filter_names(
        &self,
        device_id: &str,
        names: Vec<String>,
    ) -> Result<(), DeviceOpError> {
        tracing::info!(
            "filter_wheel_set_filter_names: Setting filter names for '{}': {:?}",
            device_id,
            names
        );
        self.filter_wheel(device_id)
            .await?
            .set_names(names.clone())
            .await?;
        // What the wheel holds now, which for a simulator is fewer names than
        // were sent when the list was longer than the wheel.
        let stored = self
            .filter_wheel_get_config(device_id)
            .await
            .map(|(_, names)| names)
            .unwrap_or(names);
        self.publish_property_changed(
            DeviceType::FilterWheel,
            device_id,
            property::FILTER_NAMES,
            serde_json::to_string(&stored).unwrap_or_else(|_| "[]".to_string()),
        );
        Ok(())
    }
}

const FILTER_WHEEL_POSITION_FAILURE_THRESHOLD: u32 = 3;
const FILTER_WHEEL_POSITION_BACKOFF_BASE: Duration = Duration::from_secs(10);
const FILTER_WHEEL_POSITION_BACKOFF_MAX: Duration = Duration::from_secs(120);

#[derive(Debug)]
struct FilterWheelStatusPollState {
    position_backoff: ConsecutiveFailureBackoff,
    last_position: Option<i32>,
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

static FILTER_WHEEL_STATUS_POLL_STATES: OnceLock<
    StdMutex<HashMap<String, FilterWheelStatusPollState>>,
> = OnceLock::new();

fn filter_wheel_status_poll_states(
) -> &'static StdMutex<HashMap<String, FilterWheelStatusPollState>> {
    FILTER_WHEEL_STATUS_POLL_STATES.get_or_init(|| StdMutex::new(HashMap::new()))
}

/// Poll Position without hammering a driver that has demonstrated a sustained
/// failure. The first two consecutive errors propagate so real one-off failures
/// remain visible. From the third failure onward, status polling serves the
/// last good value (or the unknown sentinel) and retries with exponential
/// backoff.
async fn poll_filter_wheel_position(
    manager: &DeviceManager,
    device_id: &str,
) -> Result<i32, DeviceOpError> {
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
                Err(error)
            }
        }
    }
}
