//! Filter wheel operations: the events and read-health bookkeeping around
//! the wheel's handle (see [`crate::device_manager::rig::filter_wheel`]).

use crate::device::*;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::event::EquipmentEvent;

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
