//! Focuser operations: the events, heartbeat hold-off and read-health
//! bookkeeping around the focuser's handle (see
//! [`crate::device_manager::rig::focuser`]).

use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

impl DeviceManager {
    /// Move to an absolute position, publishing `FocuserMoveStarted` before
    /// the move and `FocuserMoveCompleted` with the position read back after
    /// it (see [`state_events`]). The read-back is what the focuser reached,
    /// which after backlash or a stall is not the commanded position.
    ///
    /// [`state_events`]: crate::device_manager::ops::state_events
    pub async fn focuser_move_abs(
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
        self.publish_state_event(EquipmentEvent::FocuserMoveStarted {
            device_id: device_id.to_string(),
            target_position: position,
        });
        let result = self.focuser_move_abs_dispatch(device_id, position).await;
        self.publish_focuser_move_end(device_id, result.is_ok().then_some(position))
            .await;
        result
    }

    /// Move by `steps`, with the same events as [`Self::focuser_move_abs`].
    /// `FocuserMoveStarted` needs a target, so it is published only when the
    /// starting position can be read.
    pub async fn focuser_move_rel(&self, device_id: &str, steps: i32) -> Result<(), DeviceOpError> {
        // An unknown id has nothing to report on; answer before announcing a
        // move that cannot start.
        if self.registered_driver_type(device_id).await.is_none() {
            return Err(DeviceOpError::device_not_found(device_id));
        }
        let _command = self.command_activity.begin(device_id);
        let target = self
            .focuser_get_position(device_id)
            .await
            .ok()
            .map(|from| from.saturating_add(steps));
        if let Some(target_position) = target {
            self.publish_state_event(EquipmentEvent::FocuserMoveStarted {
                device_id: device_id.to_string(),
                target_position,
            });
        }
        let result = self.focuser_move_rel_dispatch(device_id, steps).await;
        self.publish_focuser_move_end(device_id, target.filter(|_| result.is_ok()))
            .await;
        result
    }

    /// Stop the focuser and publish where it stopped.
    pub async fn focuser_halt(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let _command = self.command_activity.begin(device_id);
        let result = match self.focuser(device_id).await {
            Ok(focuser) => focuser.halt().await,
            Err(e) => Err(e),
        };
        if result.is_ok() {
            self.publish_focuser_move_end(device_id, None).await;
        }
        result
    }

    /// `FocuserMoveCompleted` with the position the focuser reads back, or
    /// `fallback` when it cannot be read. Published after a failed move too,
    /// so no UI is left showing the focuser as moving; with neither a reading
    /// nor a fallback there is nothing true to say and nothing is published.
    async fn publish_focuser_move_end(&self, device_id: &str, fallback: Option<i32>) {
        let reached = self.focuser_get_position(device_id).await.ok().or(fallback);
        if let Some(position) = reached {
            self.publish_state_event(EquipmentEvent::FocuserMoveCompleted {
                device_id: device_id.to_string(),
                position,
            });
        }
    }

    /// The focuser's heartbeat is held off while the move command runs: an
    /// ASCOM driver can block in it on the STA thread, and a status read
    /// queued behind it would be miscounted as a heartbeat failure.
    async fn focuser_move_abs_dispatch(
        &self,
        device_id: &str,
        position: i32,
    ) -> Result<(), DeviceOpError> {
        let focuser = self.focuser(device_id).await?;
        let _op = self.begin_operation(device_id);
        focuser.move_to(position).await
    }

    async fn focuser_move_rel_dispatch(
        &self,
        device_id: &str,
        steps: i32,
    ) -> Result<(), DeviceOpError> {
        let focuser = self.focuser(device_id).await?;
        let _op = self.begin_operation(device_id);
        focuser.move_by(steps).await
    }

    /// Read the focuser's position. The outcome feeds the device's read health (see
    /// [`crate::device_manager::read_health`]).
    pub async fn focuser_get_position(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let result = match self.focuser(device_id).await {
            Ok(focuser) => focuser.position().await,
            Err(e) => Err(e),
        };
        self.note_status_read(device_id, &result);
        result
    }

    pub async fn focuser_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        self.focuser(device_id).await?.is_moving().await
    }

    pub async fn focuser_is_absolute(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        self.focuser(device_id).await?.is_absolute().await
    }

    pub async fn focuser_get_temp(&self, device_id: &str) -> Result<Option<f64>, DeviceOpError> {
        self.focuser(device_id).await?.temperature().await
    }

    /// The largest position and the size of one step in microns.
    pub async fn focuser_get_details(&self, device_id: &str) -> Result<(i32, f64), DeviceOpError> {
        self.focuser(device_id).await?.travel().await
    }
}
